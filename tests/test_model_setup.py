import hashlib
import importlib.util
import json
import shutil
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('model_setup', Path(__file__).resolve().parents[1] / 'setup/models.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ModelSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.data = b'a model fixture, not real weights\n' * 500
        self.row = {'name': 'model.safetensors', 'size': len(self.data), 'sha256': hashlib.sha256(self.data).hexdigest()}

    def tearDown(self):
        self.temp.cleanup()

    def serve(self, ignore_range=False, corrupt=False, incorrect_range=False, truncate_first=0):
        data = self.data
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.headers.get('Range'))
                offset = int(self.headers['Range'][6:-1]) if self.headers.get('Range') and not ignore_range else 0
                self.send_response(206 if offset else 200)
                if offset:
                    self.send_header('Content-Range', f'bytes {offset + int(incorrect_range)}-{len(data)-1}/{len(data)}')
                payload = data[offset:] if not corrupt else b'x' * (len(data)-offset)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload[:truncate_first] if truncate_first and len(requests)==1 else payload)
            def log_message(self, *_):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f'http://127.0.0.1:{server.server_port}/model', requests

    def test_download_and_valid_file_are_idempotent(self):
        url, requests = self.serve()
        target = self.root / self.row['name']
        setup.fetch(url, target, self.row)
        setup.fetch(url, target, self.row)
        self.assertEqual(target.read_bytes(), self.data)
        self.assertEqual(len(requests), 1)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_resume_only_confirmed_range(self):
        url, requests = self.serve()
        target = self.root / self.row['name']
        target.with_suffix('.safetensors.partial').write_bytes(self.data[:413])
        setup.fetch(url, target, self.row)
        self.assertEqual(requests, ['bytes=413-'])
        self.assertEqual(target.read_bytes(), self.data)

    def test_server_ignoring_range_restarts_instead_of_appending(self):
        url, _ = self.serve(ignore_range=True)
        target = self.root / self.row['name']
        target.with_suffix('.safetensors.partial').write_bytes(self.data[:413])
        setup.fetch(url, target, self.row)
        self.assertEqual(target.read_bytes(), self.data)

    def test_bad_hash_does_not_replace_existing_file(self):
        url, _ = self.serve(corrupt=True)
        target = self.root / self.row['name']
        target.write_bytes(b'previous file')
        with self.assertRaises(setup.SetupError):
            setup.fetch(url, target, self.row, attempts=1)
        self.assertEqual(target.read_bytes(), b'previous file')
        self.assertFalse(target.with_suffix('.safetensors.partial').exists())

    def test_bad_resume_range_is_rejected(self):
        url, _ = self.serve(incorrect_range=True)
        target = self.root / self.row['name']
        partial = target.with_suffix('.safetensors.partial')
        partial.write_bytes(self.data[:413])
        with self.assertRaises(setup.SetupError):
            setup.fetch(url, target, self.row, attempts=1)
        self.assertEqual(partial.read_bytes(), self.data[:413])
        self.assertFalse(target.exists())

    def test_source_choice_keeps_revision_and_filename(self):
        model = {'repo':'test/model', 'revision':'a'*40}
        official = setup.model_url(model, 'model.safetensors')
        mirror = setup.model_url(model, 'model.safetensors', 'mirror')
        self.assertEqual(official.replace('https://huggingface.co','https://hf-mirror.com'), mirror)
        self.assertIn('/resolve/'+'a'*40+'/model.safetensors', mirror)
        with self.assertRaises(setup.SetupError):
            setup.model_url(model, 'model.safetensors', 'unknown')

    def test_partial_download_can_continue_from_another_source(self):
        first, _ = self.serve(truncate_first=413)
        second, requests = self.serve()
        target = self.root / self.row['name']
        with self.assertRaises(setup.SetupError):
            setup.fetch(first, target, self.row, attempts=1)
        self.assertEqual(target.with_suffix('.safetensors.partial').stat().st_size, 413)
        setup.fetch(second, target, self.row, attempts=1)
        self.assertEqual(requests, ['bytes=413-'])
        self.assertEqual(target.read_bytes(), self.data)

    def test_disconnected_transfer_emits_retry_and_resumes(self):
        url, requests = self.serve(truncate_first=413)
        events = []
        with patch.object(setup.time, 'sleep'):
            setup.fetch(url, self.root/self.row['name'], self.row, attempts=2, status=lambda **event: events.append(event))
        self.assertEqual(requests, [None,'bytes=413-'])
        self.assertIn('retry', [e['stage'] for e in events])
        self.assertEqual([e['received'] for e in events if e['stage']=='connecting'], [0,413])
        self.assertEqual(events[-1]['stage'], 'verify')

    def test_progress_arrives_before_a_large_file_finishes(self):
        self.data *= 30
        row = {**self.row, 'size':len(self.data), 'sha256':hashlib.sha256(self.data).hexdigest()}
        url, _ = self.serve()
        amounts=[]
        setup.fetch(url, self.root/row['name'], row, amounts.append)
        self.assertEqual(amounts[0],0)
        self.assertTrue(any(0 < amount < len(self.data) for amount in amounts))
        self.assertEqual(amounts[-1],len(self.data))

    def test_http_protocol_failure_is_retried(self):
        url, _ = self.serve()
        real_open = setup.urllib.request.urlopen
        calls=[]
        def flaky(*args, **kwargs):
            calls.append(1)
            if len(calls)==1: raise setup.http.client.IncompleteRead(b'',1)
            return real_open(*args,**kwargs)
        with patch.object(setup.urllib.request,'urlopen',side_effect=flaky), patch.object(setup.time,'sleep'):
            setup.fetch(url,self.root/self.row['name'],self.row)
        self.assertEqual(len(calls),2)

    def catalog(self, filename='model.safetensors'):
        model = {'key': 'asrModel', 'name': 'test-model', 'title': '测试模型', 'repo': 'test/model',
                 'revision': 'a'*40, 'bytes': len(self.data), 'files': [{**self.row, 'name': filename}]}
        path = self.root / 'catalog.json'
        path.write_text(json.dumps({'schema': 1, 'models': [model]}))
        return path

    def test_catalog_rejects_traversal_and_unpinned_version(self):
        with self.assertRaises(setup.SetupError):
            setup.load_catalog(self.catalog('../config.json'))
        path = self.catalog()
        data = json.loads(path.read_text()); data['models'][0]['revision'] = 'main'; path.write_text(json.dumps(data))
        with self.assertRaises(setup.SetupError):
            setup.load_catalog(path)

    def test_failed_install_preserves_config(self):
        config = self.root / 'config.json'
        original = '{"python":"/existing/python","cleanupTimeoutSeconds":9}'
        config.write_text(original)
        with patch.object(setup, 'fetch', side_effect=setup.SetupError('offline')):
            with self.assertRaises(setup.SetupError):
                setup.install(self.root, Path('/new/python'), self.catalog(), notify=lambda **_: None)
        self.assertEqual(config.read_text(), original)

    def test_existing_verified_model_is_reused_without_network(self):
        model = self.root / 'existing'; model.mkdir()
        (model/self.row['name']).write_bytes(self.data)
        (self.root/'config.json').write_text(json.dumps({'asrModel': str(model), 'cleanupTimeoutSeconds': 9}))
        with patch.object(setup, 'fetch', side_effect=AssertionError('unexpected network')):
            config = setup.install(self.root, Path('/new/python'), self.catalog(), notify=lambda **_: None)
        self.assertEqual(config['asrModel'], str(model))
        self.assertEqual(config['cleanupTimeoutSeconds'], 9)
        self.assertEqual((self.root/'config.json').stat().st_mode & 0o777, 0o600)

    def test_corrupt_config_is_not_overwritten(self):
        config = self.root / 'config.json'; config.write_text('{broken')
        with self.assertRaises(setup.SetupError):
            setup.install(self.root, Path('/new/python'), self.catalog(), notify=lambda **_: None)
        self.assertEqual(config.read_text(), '{broken')

    def test_catalog_rejects_unsafe_model_name_and_wrong_total(self):
        for key, value in [('name', '../outside'), ('bytes', 1)]:
            path = self.catalog()
            data = json.loads(path.read_text())
            data['models'][0][key] = value
            path.write_text(json.dumps(data))
            with self.assertRaises(setup.SetupError):
                setup.load_catalog(path)

    def test_corrupt_existing_model_requires_replacement_space(self):
        catalog = self.catalog()
        directory = self.root / 'runtime/models/test-model' / ('a' * 40)
        directory.mkdir(parents=True)
        target = directory / self.row['name']
        target.write_bytes(b'x' * len(self.data))
        disk = shutil.disk_usage(self.root)._replace(free=256 * 1024 * 1024)
        with patch.object(setup.shutil, 'disk_usage', return_value=disk), patch.object(setup, 'fetch') as fetch:
            with self.assertRaisesRegex(setup.SetupError, '磁盘空间不足'):
                setup.install(self.root, Path('/new/python'), catalog, notify=lambda **_: None)
            fetch.assert_not_called()
        self.assertFalse((self.root / 'config.json').exists())
        self.assertEqual(target.read_bytes(), b'x' * len(self.data))


if __name__ == '__main__':
    unittest.main()
