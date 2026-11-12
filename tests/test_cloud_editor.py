"""Cloud cleanup: protocol handling, privacy boundary and local fallback.

No real network: a loopback HTTP server stands in for the provider, and the
local model is stubbed, so this runs in CI without MLX or credentials.
"""
import json
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))

from cloud_client import CloudUnavailable, chat_client, json_object, probe
from engine import Editor

PLAN = {"repairs": [{"old": "十个", "new": "十二个", "cue": "不对，改成十二个。"}], "edits": [], "breaks": [], "bullets": []}


class Provider(BaseHTTPRequestHandler):
    """Records each request; replies according to the class-level `mode`."""
    mode, requests = 'openai', []

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        Provider.requests.append({'path': self.path, 'headers': {k.lower(): v for k, v in self.headers.items()}, 'body': body})
        mode = Provider.mode
        if mode == 'slow':
            time.sleep(1.5)
        if mode == 'error':
            self.send_response(503); self.end_headers(); self.wfile.write(b'{"secret":"echoed key"}'); return
        if mode == 'redirect':
            self.send_response(302); self.send_header('Location', 'https://example.invalid/'); self.end_headers(); return
        if mode == 'no_sampling' and 'temperature' in body or mode == 'bad_request':
            # Newer models reject a non-default temperature.
            self.send_response(400); self.end_headers(); self.wfile.write(b'{"error":"bad request"}'); return
        text = json.dumps(PLAN, ensure_ascii=False) if mode != 'prose' else '我觉得不需要修改。'
        if body.get('max_tokens') == 32:
            text = '{"ok":true}'
        reply = ({'content': [{'type': 'text', 'text': text}], 'stop_reason': 'end_turn'}
                 if self.path.endswith('/v1/messages') else
                 {'choices': [{'message': {'content': text}, 'finish_reason': 'stop'}]})
        data = json.dumps(reply, ensure_ascii=False).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)


class CloudClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), Provider)
        cls.base = f'http://127.0.0.1:{cls.server.server_address[1]}'
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Provider.mode, Provider.requests = 'openai', []

    def messages(self):
        return [{'role': 'system', 'content': '只返回 JSON'}, {'role': 'user', 'content': '原稿'}]

    def test_openai_protocol(self):
        client = chat_client('openai', self.base + '/v1', 'small', 'k-test')
        self.assertEqual(json_object(client(self.messages(), 100, 5)), PLAN)
        sent = Provider.requests[-1]
        self.assertEqual(sent['path'], '/v1/chat/completions')
        self.assertEqual(sent['headers']['authorization'], 'Bearer k-test')
        self.assertEqual(sent['body']['messages'][0], {'role': 'system', 'content': '只返回 JSON'})

    def test_anthropic_protocol_and_gateway_headers(self):
        client = chat_client('anthropic', self.base, 'small', 'k-test', {'x-gateway': '{"user":"u"}'})
        self.assertEqual(json_object(client(self.messages(), 100, 5)), PLAN)
        sent = Provider.requests[-1]
        self.assertEqual(sent['path'], '/v1/messages')
        self.assertEqual(sent['headers']['x-api-key'], 'k-test')
        self.assertEqual(sent['headers']['x-gateway'], '{"user":"u"}')
        self.assertEqual(sent['body']['system'], '只返回 JSON')
        self.assertEqual([m['role'] for m in sent['body']['messages']], ['user'])

    def test_failures_are_reason_codes_without_response_bodies(self):
        client = chat_client('openai', self.base, 'small', 'k-test')
        for mode, reason in [('error', 'http_503'), ('redirect', 'redirect')]:
            Provider.mode = mode
            with self.subTest(mode=mode), self.assertRaises(CloudUnavailable) as caught:
                client(self.messages(), 100, 5)
            self.assertEqual(caught.exception.reason, reason)
            self.assertNotIn('secret', str(caught.exception))
        Provider.mode = 'slow'
        with self.assertRaises(CloudUnavailable) as caught:
            client(self.messages(), 100, 1)
        self.assertEqual(caught.exception.reason, 'timeout')

    def test_configuration_is_validated_before_any_request(self):
        for args in [('gopher', self.base, 'm', 'k'), ('openai', 'http://example.com', 'm', 'k'),
                     ('openai', self.base, '', 'k'), ('openai', self.base, 'm', '')]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                chat_client(*args)
        with self.assertRaises(ValueError):
            chat_client('openai', self.base, 'm', 'k', {'x-bad': 'a\r\nInjected: 1'})
        self.assertEqual(Provider.requests, [])

    def test_probe(self):
        self.assertGreaterEqual(probe(chat_client('anthropic', self.base, 'small', 'k-test'), 5), 0)

    def test_model_that_rejects_temperature_is_retried_once_without_it(self):
        Provider.mode = 'no_sampling'
        client = chat_client('anthropic', self.base, 'new-model', 'k-test')
        self.assertEqual(json_object(client(self.messages(), 100, 5)), PLAN)
        self.assertEqual(['temperature' in r['body'] for r in Provider.requests], [True, False])
        # The next utterance builds a new client; the refusal is remembered, so
        # it does not pay a 400 again.
        chat_client('anthropic', self.base, 'new-model', 'k-test')(self.messages(), 100, 5)
        self.assertEqual(['temperature' in r['body'] for r in Provider.requests], [True, False, False])
        # A 400 for another reason is retried at most once per model, then reported.
        Provider.mode, Provider.requests = 'bad_request', []
        other = chat_client('anthropic', self.base, 'other-model', 'k-test')
        for expected in (2, 3):
            with self.assertRaises(CloudUnavailable) as caught:
                other(self.messages(), 100, 5)
            self.assertEqual((caught.exception.reason, len(Provider.requests)), ('http_400', expected))

    def test_json_object_tolerates_a_fence_only(self):
        self.assertEqual(json_object('```json\n{"a":1}\n```'), {'a': 1})
        for reply in ['我觉得不需要修改。', '{"a":1} 另外', '[1]']:
            with self.subTest(reply=reply), self.assertRaises(ValueError):
                json_object(reply)


class Tokenizer:
    def encode(self, text):
        return list(text)


def editor(remote=None, local_plan=None):
    """An Editor wired for routing tests: no model weights, local plan stubbed."""
    e = Editor.__new__(Editor)
    e.mode, e.emit, e.tokenizer = 'edits', lambda value: None, Tokenizer()
    e.base, e.prefix, e.cache = [{'role': 'system', 'content': 'edit'}], [], None
    e.restart_base, e.restart_prefix, e.restart_cache = e.base, [], None
    e.filler_base = [{'role': 'system', 'content': 'filler'}]
    e.local_calls = []
    def local(base, prefix, cache, user, max_tokens, timeout):
        e.local_calls.append(user)
        return json.dumps(local_plan or PLAN, ensure_ascii=False), 'stop', None
    e._local_plan = local
    e.remote, e.remote_timeout = remote, 5
    return e


def remote(reply=None, error=None):
    sent = []
    def complete(messages, max_tokens, timeout):
        sent.append(messages[-1]['content'])
        if error:
            raise CloudUnavailable(error)
        return reply
    complete.model, complete.sent = 'small', sent
    return complete


RAW = '先用十个样本，不对，改成十二个。保留所有日志。'


class CloudRoutingTests(unittest.TestCase):
    def test_cloud_plan_is_validated_like_a_local_one(self):
        cloud = remote(json.dumps(PLAN, ensure_ascii=False))
        text, meta = editor(cloud).edit(RAW, {}, policy='always')
        self.assertEqual(text, '先用12个样本。保留所有日志。')
        self.assertEqual(meta['engine'], 'cloud')
        self.assertNotIn('cloud_fallback', meta)

    def test_outage_falls_back_to_local_and_says_why(self):
        e = editor(remote(error='timeout'))
        text, meta = e.edit(RAW, {}, policy='always')
        self.assertEqual(text, '先用12个样本。保留所有日志。')
        self.assertEqual((meta['engine'], meta['cloud_fallback']), ('local', 'timeout'))
        self.assertEqual(len(e.local_calls), 1)

    def test_unusable_reply_falls_back_to_local(self):
        for reply, reason in [('我觉得不需要修改。', 'invalid_json'), ('{"repairs": "nope"}', 'invalid_plan')]:
            with self.subTest(reply=reply):
                text, meta = editor(remote(reply)).edit(RAW, {}, policy='always')
                self.assertEqual((meta['engine'], meta['cloud_fallback']), ('local', reason))
                self.assertEqual(text, '先用12个样本。保留所有日志。')

    def test_cloud_safety_checks_still_apply(self):
        # A cloud plan that silently changes a number is rejected, not trusted.
        bad = {"repairs": [], "edits": [{"old": "十个样本", "new": "二十个样本", "kind": "spelling"}], "breaks": [], "bullets": []}
        text, meta = editor(remote(json.dumps(bad, ensure_ascii=False))).edit(RAW, {}, policy='always')
        self.assertEqual(meta['engine'], 'cloud')
        self.assertNotIn('二十', text)

    def test_visible_window_text_never_leaves_the_mac(self):
        cloud = remote(json.dumps(PLAN, ensure_ascii=False))
        e = editor(cloud)
        context = {'nearby': 'VISIBLE-WINDOW-SECRET', 'window_title': '周报', 'latest': '光标前文字'}
        e.edit(RAW, context, policy='always')
        self.assertNotIn('VISIBLE-WINDOW-SECRET', cloud.sent[0])
        self.assertIn('周报', cloud.sent[0])
        # The local model still receives it for disambiguation.
        e = editor(remote(error='network'))
        e.edit(RAW, context, policy='always')
        self.assertIn('VISIBLE-WINDOW-SECRET', e.local_calls[0])

    def test_fast_routes_never_call_the_cloud(self):
        cloud = remote(json.dumps(PLAN, ensure_ascii=False))
        text, meta = editor(cloud).edit('保存文件。', {}, policy='auto')
        self.assertFalse(meta['model_used'])
        self.assertEqual(cloud.sent, [])


if __name__ == '__main__':
    unittest.main()
