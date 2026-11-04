"""Optional local model check using an explicitly supplied, non-private WAV.

Run with the Python executable from freetalk's config.json. Quit freetalk first
to avoid two model processes competing for unified memory. Does not write history.
"""
import argparse
import json
import sys
import time
import wave
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--audio', type=Path, required=True, help='16 kHz, mono, 16-bit PCM WAV')
    parser.add_argument('--expect', help='Optional exact expected result; mismatch exits with code 2')
    args = parser.parse_args()
    with wave.open(str(args.audio), 'rb') as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth(), audio.getcomptype()) != (16000, 1, 2, 'NONE'):
            parser.error('Audio must be 16 kHz mono 16-bit PCM WAV')
        if audio.getnframes() > 16000 * 90:
            parser.error('Use a sample of at most 90 seconds')
        pcm = audio.readframes(audio.getnframes())
    config = json.loads(args.config.read_text())
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
    from engine import Engine
    started = time.perf_counter()
    print('Loading local models...', file=sys.stderr, flush=True)
    engine = Engine(config)
    load_seconds = time.perf_counter() - started
    started = time.perf_counter()
    engine.reset({})
    # Feed chunks just like the app, without recording or targeting an input field.
    for offset in range(0, len(pcm), 16000 * 2):
        engine.push(pcm[offset:offset + 16000 * 2])
    result = engine.finish()
    result['model_load_seconds'] = load_seconds
    result['total_processing_seconds'] = time.perf_counter() - started
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if args.expect is None or result['text'] == args.expect else 2


if __name__ == '__main__':
    raise SystemExit(main())
