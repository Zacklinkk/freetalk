"""Opt-in cloud chat for dictation cleanup.

Text only: the caller decides what leaves the machine. Requests never follow
redirects, responses are size-bounded, and errors carry a short reason code
instead of a response body (bodies can echo credentials or transcripts).
"""
import json
import re
import time
import urllib.error
import urllib.request

from meeting_models import NoRedirect, validate_endpoint

PROTOCOLS = ('openai', 'anthropic')
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
# (endpoint, model) pairs that answered HTTP 400 to temperature=0. A client is
# rebuilt for every utterance, so the memory lives for the worker process.
NO_TEMPERATURE = set()


class CloudUnavailable(Exception):
    """The cloud editor could not produce a usable answer; `reason` is a short code."""
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def _headers(extra):
    """Extra headers are for gateways that need them; they cannot inject lines."""
    if not extra:
        return {}
    if not isinstance(extra, dict):
        raise ValueError('Extra headers must be a JSON object')
    clean = {}
    for name, value in extra.items():
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', name):
            raise ValueError('Invalid extra header name')
        if not isinstance(value, str) or len(value) > 2048 or any(c in value for c in '\r\n\0'):
            raise ValueError('Invalid extra header value')
        clean[name] = value
    return clean


def chat_client(protocol, base_url, model, api_key, headers=None):
    """Return complete(messages, max_tokens, timeout) -> text, raising CloudUnavailable."""
    if protocol not in PROTOCOLS:
        raise ValueError('Unsupported cloud protocol')
    if not isinstance(model, str) or not model.strip() or not isinstance(api_key, str) or not api_key:
        raise ValueError('Cloud cleanup requires a model and API key')
    base = validate_endpoint(base_url)
    extra = _headers(headers)
    if protocol == 'openai':
        endpoint = base + '/chat/completions'
        auth = {'Authorization': 'Bearer ' + api_key}
    else:
        endpoint = base + ('/messages' if base.endswith('/v1') else '/v1/messages')
        auth = {'x-api-key': api_key, 'anthropic-version': '2023-06-01'}
    opener = urllib.request.build_opener(NoRedirect())
    # Newer models (Claude Haiku/Sonnet/Opus 5.5, OpenAI reasoning models)
    # reject a non-default temperature with HTTP 400; older ones accept 0.
    # After one such refusal the worker stops sending it to that model.
    key = (endpoint, model)

    def send(body, timeout):
        request = urllib.request.Request(endpoint, data=json.dumps(body, ensure_ascii=False).encode(),
                                         headers={**extra, **auth, 'Content-Type': 'application/json'})
        try:
            with opener.open(request, timeout=max(1.0, float(timeout))) as response:
                return response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as exc:
            exc.close()
            raise CloudUnavailable(f'http_{exc.code}') from None
        except (TimeoutError, OSError) as exc:
            # socket.timeout is an OSError; URLError wraps both.
            reason = getattr(exc, 'reason', exc)
            raise CloudUnavailable('timeout' if isinstance(reason, TimeoutError) or 'timed out' in str(reason) else 'network') from None
        except RuntimeError:
            raise CloudUnavailable('redirect') from None

    def complete(messages, max_tokens, timeout):
        system = '\n\n'.join(m['content'] for m in messages if m['role'] == 'system')
        turns = [{'role': m['role'], 'content': m['content']} for m in messages if m['role'] != 'system']
        if protocol == 'openai':
            body = {'model': model, 'max_tokens': max_tokens,
                    'messages': ([{'role': 'system', 'content': system}] if system else []) + turns}
        else:
            body = {'model': model, 'max_tokens': max_tokens, 'messages': turns}
            if system:
                body['system'] = system
        try:
            data = send(body if key in NO_TEMPERATURE else {**body, 'temperature': 0}, timeout)
        except CloudUnavailable as error:
            if error.reason != 'http_400' or key in NO_TEMPERATURE:
                raise
            NO_TEMPERATURE.add(key)
            data = send(body, timeout)
        if len(data) > MAX_RESPONSE_BYTES:
            raise CloudUnavailable('response_too_large')
        try:
            result = json.loads(data)
            if protocol == 'openai':
                choice = result['choices'][0]
                if choice.get('finish_reason') not in (None, 'stop'):
                    raise CloudUnavailable('truncated')
                text = choice['message']['content']
            else:
                if result.get('stop_reason') not in (None, 'end_turn', 'stop_sequence'):
                    raise CloudUnavailable('truncated')
                text = ''.join(block.get('text', '') for block in result['content'] if block.get('type') == 'text')
        except CloudUnavailable:
            raise
        except (ValueError, KeyError, IndexError, TypeError, AttributeError):
            raise CloudUnavailable('invalid_response') from None
        if not isinstance(text, str) or not text.strip():
            raise CloudUnavailable('empty_response')
        return text

    complete.model = model
    return complete


def json_object(text):
    """The first JSON object in a reply, tolerating a Markdown fence around it."""
    text = text.strip()
    if text.startswith('```'):
        text = re.sub(r'^```(?:json)?\s*|\s*```$', '', text)
    start = text.find('{')
    if start < 0:
        raise ValueError('No JSON object in reply')
    value, end = json.JSONDecoder().raw_decode(text[start:])
    if text[start + end:].strip():
        raise ValueError('Unexpected content after JSON object')
    if not isinstance(value, dict):
        raise ValueError('Reply is not a JSON object')
    return value


def probe(client, timeout=10):
    """A tiny round trip for the settings page: proves endpoint, key and model."""
    started = time.perf_counter()
    reply = client([{'role': 'system', 'content': '只返回 JSON。'},
                    {'role': 'user', 'content': '返回 {"ok":true}'}], 32, timeout)
    json_object(reply)
    return time.perf_counter() - started
