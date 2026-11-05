"""Long recordings use bounded audio windows and checkpointed transcript segments."""
import fcntl
import hashlib
import json
import math
import os
import subprocess
import time
from pathlib import Path
from meeting_store import MeetingStore, atomic_json, atomic_text, render_bundle, render_transcript
from meeting_summary import summarize


def normalize_audio(source, target):
    source, target = Path(source).resolve(), Path(target)
    if not source.is_file():
        raise ValueError('录音文件不存在')
    if source == target.resolve():
        import soundfile as sf
        info = sf.info(str(source))
        if info.samplerate != 16000 or info.channels != 1:
            raise ValueError('录音缓存必须为 16 kHz 单声道')
        return
    # macOS's decoder handles common meeting exports including m4a without ffmpeg downloads.
    command = ['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(source), str(target)]
    try:
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
    except (OSError, subprocess.SubprocessError):
        raise ValueError('无法解码录音；请使用 WAV、M4A、MP3 或 FLAC 文件。') from None
    os.chmod(target, 0o600)


def intervals(duration, turns, maximum=20.0):
    points = {0., duration}
    for row in turns:
        points.update((max(0., min(duration, row['start'])), max(0., min(duration, row['end']))))
    points = sorted(points)
    spans = []
    for a, b in zip(points, points[1:]):
        if b <= a:
            continue
        active = sorted({r['speaker'] for r in turns if r['start'] < b and r['end'] > a})
        if spans and spans[-1][2] == active:
            spans[-1][1] = b
        else:
            spans.append([a, b, active])
    # Very short changes cannot reliably be transcribed alone; preserve uncertainty.
    compact = []
    for a, b, active in spans:
        if compact and b - a < .4 and b - compact[-1][0] < maximum:
            compact[-1][1] = b
            compact[-1][2] = sorted(set(compact[-1][2]) | set(active))
        else:
            compact.append([a, b, active])
    for a, b, active in compact:
        n = max(1, math.ceil((b-a) / maximum))
        for i in range(n):
            yield a + (b-a)*i/n, a + (b-a)*(i+1)/n, active


def validate_segments(rows):
    if not isinstance(rows, list) or len(rows) > 100000:
        raise ValueError('转写须为片段数组，最多 100000 个片段')
    result, seen = [], set()
    last_start = -1
    for i, r in enumerate(rows):
        if not isinstance(r, dict) or not isinstance(r.get('text'), str) or len(r['text']) > 5000:
            raise ValueError('每个片段需要 text，单段不超过 5000 字')
        sid = f's{i+1:06}'
        a, b = r.get('start', 0), r.get('end', 0)
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)) or not math.isfinite(a) or not math.isfinite(b) or a < 0 or b < a or a < last_start:
            raise ValueError('片段时间必须为有效、递增的秒数')
        last_start = a
        speakers = r.get('speaker_ids', [])
        if not isinstance(speakers, list) or not all(isinstance(x, str) and 0 < len(x) <= 80 for x in speakers):
            raise ValueError('speaker_ids 必须是字符串数组')
        result.append(dict(id=sid, start=a, end=b, text=r['text'], speaker_ids=speakers,
                           speaker_status='provided' if speakers else 'unknown', timestamp_precision='segment'))
    return result


def run_meeting(config, payload, engine=None, emit=lambda value: None):
    from meeting_models import local_generator, cloud_generator, diarize
    store = MeetingStore(payload['support'])
    meeting_id = payload['meeting_id']
    directory = store.directory(meeting_id)
    manifest = store.manifest(meeting_id)
    settings_path = store.support / 'meeting-settings.json'
    settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    if settings.get('enabled') is not True:
        raise ValueError('会议功能尚未启用；不会下载模型或调用云端。')
    inference_lock = None
    if engine is None:
        inference_lock = (store.support / 'inference.lock').open('a')
        try:
            fcntl.flock(inference_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            inference_lock.close()
            raise ValueError('本地模型正在使用。CLI 推理前请退出 freetalk；读取、搜索和导出不受影响。') from None
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1')
    def progress(**event):
        emit({'event': 'meeting-progress', 'meeting_id': meeting_id, **event})
    lock = (directory / '.job.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        if inference_lock: inference_lock.close()
        raise ValueError('该会议正在处理中') from None
    started = time.monotonic(); timings = {}
    audio_path = directory / 'audio.wav'
    retain = bool(settings.get('retain_audio', False))
    summary_mode = settings.get('summary_mode', 'local')
    try:
        if summary_mode == 'cloud':
            # Explicit settings, no auto-fallback that uploads local work on failure.
            generate = cloud_generator(settings.get('base_url', ''), settings.get('model', ''), payload.get('api_key', ''))
            summary_model = settings.get('model', '')
        elif summary_mode == 'local':
            if engine is None:
                from mlx_lm import load
                model, tokenizer = load(config['cleanupModel'], tokenizer_config={'trust_remote_code': False})
                generate = local_generator(model, tokenizer)
            else:
                generate = local_generator(engine.editor.model, engine.editor.tokenizer)
            summary_model = Path(config['cleanupModel']).name
        else:
            raise ValueError('不支持的会议整理方式')
        timings['summary_model_setup_seconds'] = round(time.monotonic()-started,3)
        store.update(meeting_id, status='processing', stage='preparing', error=None,
                     summary_provider=summary_mode, summary_model=summary_model,
                     requested_audio_retention=retain)
        if payload.get('transcript_path'):
            progress(stage='import', message='导入带时间戳的转写')
            raw = json.loads(Path(payload['transcript_path']).read_text())
            segments = validate_segments(raw.get('segments') if isinstance(raw, dict) else raw)
            existing = store.segments(meeting_id)
            if existing and existing != segments:
                raise ValueError('已有会议的转写原稿不能替换，请新建会议。')
            atomic_text(directory / 'transcript.jsonl', ''.join(json.dumps(s, ensure_ascii=False)+'\n' for s in segments))
            store.update(meeting_id, transcript_complete=True, duration_seconds=max((s['end'] for s in segments), default=0), transcription_model='provided transcript', diarization_model='provided labels')
        elif manifest.get('transcript_complete') and (directory / 'transcript.jsonl').exists():
            segments = store.segments(meeting_id)
            progress(stage='resume',message='复用完整原稿，重新生成纪要与脑图')
        else:
            import numpy as np
            import soundfile as sf
            import mlx.core as mx
            progress(stage='decode', message='准备录音文件')
            stage_start = time.monotonic()
            source = payload.get('audio_path')
            if source:
                if manifest.get('audio_sha256') and Path(source).resolve() != audio_path.resolve():
                    raise ValueError('已有会议的原始录音不能替换，请新建会议。')
                normalize_audio(source, audio_path)
            if not audio_path.exists():
                raise ValueError('找不到可处理的录音')
            info = sf.info(str(audio_path))
            if info.samplerate != 16000 or info.channels != 1 or info.duration <= 0:
                raise ValueError('录音须为有效的 16 kHz 单声道音频')
            digest = hashlib.sha256()
            with audio_path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024*1024), b''):
                    digest.update(block)
            audio_digest = digest.hexdigest()
            old_digest = manifest.get('audio_sha256')
            if old_digest and old_digest != audio_digest:
                raise ValueError('录音内容已变化，请新建会议以保留原有引用')
            store.update(meeting_id, audio_retained=True, audio_sha256=audio_digest, duration_seconds=info.duration)
            timings['decode_seconds'] = round(time.monotonic()-stage_start,3)
            stage_start = time.monotonic()
            diarization = settings.get('diarization') is True
            turns_path = directory / 'speaker-turns.json'
            if diarization:
                if turns_path.exists() and old_digest == audio_digest:
                    turns = json.loads(turns_path.read_text())
                else:
                    turns = diarize(str(audio_path), config.get('meetingDiarizationModel'), progress)
                    atomic_json(turns_path, turns)
            else:
                turns = []
            timings['diarization_seconds'] = round(time.monotonic()-stage_start,3)
            stage_start = time.monotonic()
            segments = store.segments(meeting_id) if old_digest == audio_digest else []
            completed_until = max(manifest.get('processed_until_seconds', 0), segments[-1]['end'] if segments else 0) if old_digest == audio_digest else 0
            if engine is None:
                from mlx_audio.stt.utils import load_model
                asr = load_model(config['asrModel'])
            else:
                asr = engine.asr
            with sf.SoundFile(str(audio_path)) as audio:
                for a, b, speakers in intervals(info.duration, turns):
                    if b <= completed_until + .001:
                        continue
                    audio.seek(round(a*16000))
                    samples = audio.read(round((b-a)*16000), dtype='float32')
                    if len(samples) >= 1600 and float(np.sqrt(np.mean(samples*samples))) >= .0015:
                        hotwords = list(dict.fromkeys(x for x in settings.get('terms', []) + payload.get('hotwords', []) if isinstance(x, str) and len(x) <= 80))[:80]
                        result = asr.generate(samples, language=None, hotwords=hotwords, temperature=0, repetition_penalty=1.05,
                            max_tokens=min(1024, max(128, int((b-a)*22)+64)))
                        mx.synchronize()
                        text = result.text.strip()
                        if text:
                            row = dict(id=f's{len(segments)+1:06}', start=round(a,3), end=round(b,3), text=text,
                                       speaker_ids=speakers, speaker_status='multiple_or_overlap' if len(speakers)>1 else 'model' if speakers else 'unknown', timestamp_precision='segment')
                            store.append_segment(meeting_id, row); segments.append(row)
                    store.update(meeting_id, stage='transcribe', processed_until_seconds=b, segment_count=len(segments))
                    progress(stage='transcribe', completed=b, total=info.duration, message=f'转写 {int(b)} / {int(info.duration)} 秒')
            store.update(meeting_id, transcript_complete=True, transcription_model=Path(config['asrModel']).name,
                         diarization_model=Path(config['meetingDiarizationModel']).name if diarization else None)
            timings['transcribe_seconds'] = round(time.monotonic()-stage_start,3)
        source_digest = render_transcript(store, meeting_id)
        store.update(meeting_id, stage='summarize', segment_count=len(segments), source_digest=source_digest)
        progress(stage='transcript-ready', message='原稿已可查看与读取，继续生成纪要和脑图')
        stage_start = time.monotonic()
        minutes, tree = summarize(segments, generate, progress, manifest['title'])
        timings['summary_and_mindmap_seconds'] = round(time.monotonic()-stage_start,3)
        if not segments:
            minutes['warnings'].append('未得到有效语音转写；请检查录音内容和输入设备。')
        if any(s.get('speaker_status') == 'multiple_or_overlap' for s in segments):
            minutes['warnings'].append('部分片段包含多个说话人或重叠，未把每个词强行分配给某个人。')
        source_digest = render_bundle(store, meeting_id, minutes, tree)
        if audio_path.exists() and not retain:
            audio_path.unlink()
        store.update(meeting_id, status='complete', stage='complete', source_digest=source_digest,
                     warnings=minutes['warnings'], audio_retained=audio_path.exists(),
                     processing_seconds=round(time.monotonic()-started,3), timings=timings)
        progress(stage='complete', completed=1, total=1, message='会议资料已生成')
        return {'meeting_id': meeting_id, 'directory': str(directory), 'segments': len(segments), 'facts': len(minutes['facts'])}
    except Exception as exc:
        # No API key, prompt or remote response body in failure records.
        message = str(exc)[:400]
        if payload.get('api_key'):
            message = message.replace(payload['api_key'], '[redacted]')
        store.update(meeting_id, status='failed', error=message, audio_retained=audio_path.exists())
        raise
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN); lock.close()
        if inference_lock: inference_lock.close()
