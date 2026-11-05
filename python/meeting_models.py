"""Explicit local/cloud generators. Cloud receives text only and never follows redirects."""
import gc
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Match the resident app worker when running the CLI or evaluation process.
# Otherwise idle Metal residency eviction can dominate generation on macOS.
os.environ.setdefault('MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS', '1000')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')


def local_generator(model, tokenizer):
    def generate(system, user, max_tokens=2200):
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        import mlx.core as mx
        prompt = tokenizer.apply_chat_template([{'role': 'system', 'content': system}, {'role': 'user', 'content': user}],
                                               tokenize=True, add_generation_prompt=True, enable_thinking=False)
        if len(prompt) > 12000:
            raise ValueError('Meeting extraction input exceeds the bounded context budget')
        start, output, last = time.monotonic(), [], None
        events = stream_generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, sampler=make_sampler(temp=0))
        try:
            for event in events:
                output.append(event.text); last = event
                if time.monotonic() - start > 150:
                    raise TimeoutError('Meeting summary generation timed out')
        finally:
            events.close()
            mx.synchronize()
        if not last or last.finish_reason != 'stop':
            raise ValueError('Meeting summary exceeded output budget')
        return ''.join(output)
    return generate


def validate_endpoint(base_url):
    parsed = urllib.parse.urlsplit(base_url)
    local = parsed.hostname in {'localhost', '127.0.0.1', '::1'}
    if (parsed.scheme != 'https' and not (local and parsed.scheme == 'http')) or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('Cloud endpoint must be HTTPS (HTTP allowed only on loopback), without credentials or query parameters')
    return base_url.rstrip('/')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('Cloud endpoint redirected; configure its final HTTPS API address explicitly')


def cloud_generator(base_url, model, api_key):
    endpoint = validate_endpoint(base_url) + '/chat/completions'
    if not api_key or not model:
        raise ValueError('Cloud summary requires a model and API key')
    opener = urllib.request.build_opener(NoRedirect())
    def generate(system, user, max_tokens=2200):
        body = {'model': model, 'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}],
                'temperature': 0, 'max_tokens': max_tokens, 'response_format': {'type': 'json_object'}}
        request = urllib.request.Request(endpoint, data=json.dumps(body).encode(),
                    headers={'Authorization': 'Bearer ' + api_key, 'Content-Type': 'application/json'})
        try:
            with opener.open(request, timeout=150) as response:
                data = response.read(2 * 1024 * 1024 + 1)
            if len(data) > 2 * 1024 * 1024:
                raise RuntimeError('Cloud response exceeded size limit')
            result = json.loads(data)
            choice = result['choices'][0]
            if choice.get('finish_reason') not in (None, 'stop'):
                raise ValueError('Cloud summary was truncated')
            content = choice['message']['content']
            if not isinstance(content, str):
                raise ValueError('Cloud response is not text')
            return content
        except urllib.error.HTTPError as exc:
            # API response bodies can echo credentials or transcripts; never log them.
            raise RuntimeError(f'Cloud summary HTTP {exc.code}; check endpoint, model and key') from None
        except urllib.error.URLError:
            raise RuntimeError('Cloud summary network connection failed') from None
    return generate


def diarize(path, model_path, emit):
    import mlx.core as mx
    import soundfile as sf
    from mlx_audio.vad import load
    if not model_path or not Path(model_path).is_dir():
        raise ValueError('说话人模型尚未下载，请先在会议设置中下载，或关闭说话人区分。')
    model = load(model_path, strict=True)
    model.set_streaming_config('offline')
    turns = []
    with sf.SoundFile(path) as audio:
        total = len(audio) / audio.samplerate
        def blocks():
            while True:
                block = audio.read(16000 * 30, dtype='float32')
                if len(block) == 0:
                    return
                yield block
                emit(stage='diarization', completed=audio.tell() / 16000, total=total, message='正在区分本场说话人（最多 8 人）')
        for result in model.generate_stream(blocks(), sample_rate=16000, min_duration=.15, merge_gap=.15):
            for s in result.segments:
                turns.append({'start': float(s.start), 'end': min(total, float(s.end)), 'speaker': 'speaker_' + str(int(s.speaker)+1)})
    del model
    gc.collect(); mx.clear_cache()
    # Join chunk-edge fragments without renumbering each chunk's speaker channels.
    merged = []
    for speaker in sorted({t['speaker'] for t in turns}):
        group = []
        for t in sorted((x for x in turns if x['speaker'] == speaker), key=lambda x: x['start']):
            if group and t['start'] - group[-1]['end'] <= .2:
                group[-1]['end'] = max(group[-1]['end'], t['end'])
            else:
                group.append(dict(t))
        merged.extend(group)
    return sorted(merged, key=lambda x: (x['start'], x['end']))
