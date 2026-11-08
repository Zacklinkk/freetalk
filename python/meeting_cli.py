"""CLI for local, versioned meeting data; read commands never load an ML model."""
import argparse
import json
import os
import sys
from pathlib import Path
from meeting_store import DEFAULT_SUPPORT, EXPORT_FILES, MeetingStore, atomic_json


def main(argv=None):
    parser = argparse.ArgumentParser(prog='freetalk', description='Local meeting bundles for humans and agents. No background network service.')
    parser.add_argument('--support', type=Path, default=DEFAULT_SUPPORT)
    root = parser.add_subparsers(dest='command', required=True)
    meeting = root.add_parser('meetings')
    sub = meeting.add_subparsers(dest='action', required=True)
    sub.add_parser('list')
    show = sub.add_parser('show'); show.add_argument('id')
    show.add_argument('--format', choices=['json', 'minutes', 'transcript', 'mindmap', 'agent', 'deep'], default='json')
    search = sub.add_parser('search'); search.add_argument('query'); search.add_argument('--id'); search.add_argument('--limit', type=int, default=30)
    segments = sub.add_parser('segments'); segments.add_argument('id'); segments.add_argument('--offset', type=int, default=0); segments.add_argument('--limit', type=int, default=30)
    segments.add_argument('--from-seconds', type=float, default=0); segments.add_argument('--to-seconds', type=float, default=float('inf'))
    export = sub.add_parser('export'); export.add_argument('id'); export.add_argument('--to', type=Path, required=True)
    settings = sub.add_parser('config'); settings.add_argument('--enable', action='store_true'); settings.add_argument('--disable', action='store_true')
    for command in ('transcribe', 'import-text'):
        create = sub.add_parser(command); create.add_argument('file', type=Path); create.add_argument('--title', default='会议')
        create.add_argument('--api-key-env', default='FREETALK_MEETING_API_KEY')
    resume = sub.add_parser('resume'); resume.add_argument('id'); resume.add_argument('--api-key-env', default='FREETALK_MEETING_API_KEY')
    args = parser.parse_args(argv)
    store = MeetingStore(args.support)
    if args.action == 'list':
        result = store.list()
    elif args.action == 'show':
        files = {'minutes': 'minutes.md', 'transcript': 'transcript.md', 'mindmap': 'mindmap.mmd', 'agent': 'agent-context.md', 'deep': 'deep.md'}
        if args.format == 'deep' and store.read(args.id).get('deep') is None:
            raise ValueError('该会议尚无有效的深度整理版本')
        if args.format in files:
            print((store.directory(args.id) / files[args.format]).read_text()); return 0
        result = store.read(args.id)
    elif args.action == 'search':
        ids = [args.id] if args.id else [x['id'] for x in store.list()]
        result = []
        for mid in ids:
            for s in store.segments(mid):
                if args.query.casefold() in s['text'].casefold():
                    result.append({'meeting_id': mid, **s})
                    if len(result) >= max(1, min(500, args.limit)):
                        break
            if len(result) >= max(1, min(500, args.limit)):
                break
    elif args.action == 'export':
        result = {'directory': str(store.export(args.id, args.to))}
    elif args.action == 'segments':
        rows = [s for s in store.segments(args.id) if s['end'] >= args.from_seconds and s['start'] <= args.to_seconds]
        offset, limit = max(0,args.offset), max(1,min(500,args.limit))
        result = {'meeting_id': args.id, 'segments': rows[offset:offset+limit], 'total': len(rows),
                  'next_offset': offset+limit if offset+limit < len(rows) else None}
    elif args.action == 'config':
        path = args.support / 'meeting-settings.json'
        result = json.loads(path.read_text()) if path.exists() else {'enabled': False, 'diarization': False, 'summary_mode': 'local', 'retain_audio': False}
        if args.enable and args.disable:
            raise ValueError('Choose enable or disable, not both')
        if args.enable or args.disable:
            result['enabled'] = args.enable
            atomic_json(path, result)
        # Never read or print API keys; the UI uses macOS Keychain.
        result = {k: v for k, v in result.items() if k not in {'api_key', 'token', 'sk'}}
    else:
        path = args.support / 'meeting-settings.json'
        settings = json.loads(path.read_text()) if path.exists() else {}
        if settings.get('enabled') is not True:
            raise ValueError('Enable the optional module in the app, or run: freetalk meetings config --enable')
        config = json.loads((args.support / 'config.json').read_text())
        payload = {'support': str(args.support), 'api_key': os.environ.get(args.api_key_env, '')}
        if args.action == 'resume':
            payload['meeting_id'] = args.id
        else:
            if not args.file.is_file():
                raise ValueError('Input file does not exist')
            payload['meeting_id'] = store.create(args.title, 'transcript' if args.action == 'import-text' else 'file')['id']
            payload['transcript_path' if args.action == 'import-text' else 'audio_path'] = str(args.file.resolve())
        from meeting_pipeline import run_meeting
        result = run_meeting(config, payload, emit=lambda event: print(json.dumps(event, ensure_ascii=False), file=sys.stderr, flush=True))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    os.umask(0o077)
    try:
        raise SystemExit(main())
    except (ValueError, OSError, RuntimeError, KeyError) as exc:
        print(json.dumps({'error': str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
