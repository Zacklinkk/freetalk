#!/usr/bin/env python3
"""Run the cleanup eval set (evals/cleanup-cases.json) through an editor.

Run this before adopting a prompt or rule change: the change is worse if a
case that matched before no longer matches, or if fewer cases match. With
--baseline the script compares and exits 1 when the new run is worse.

Backends:
  --model DIR                 the local MLX editor, the same code path as the app
                              (quit freetalk first on a 16 GB Mac)
  --cloud-protocol/--cloud-base-url/--cloud-model
                              a cloud editor; the key comes from the
                              FREETALK_CLOUD_KEY environment variable and optional
                              gateway headers (a JSON object) from FREETALK_CLOUD_HEADERS
Nothing is uploaded except to the cloud editor you name, and only the case text.

usage: python scripts/eval-cleanup.py --model <dir> --output new.json [--baseline old.json] [--ids a,b]
                                     [--prompts <dir with edited prompt copies>]
"""
import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from cleanup_eval import load, run, summary, regressions, worse  # noqa: E402

EMPTY = '{"repairs":[],"edits":[],"breaks":[],"bullets":[]}'


def cloud_editor(args):
    from engine import Editor
    from transformers import AutoTokenizer

    class CloudOnly(Editor):
        """The app's cloud path with the local model removed, so a cloud failure shows as one."""
        def __init__(self, settings, tokenizer):
            self.emit, self.mode = (lambda value: None), 'edits'
            self.tokenizer = AutoTokenizer.from_pretrained(tokenizer)
            self.set_preferences(())
            self.set_remote(settings)

        def prepare_prefix(self, base):
            return None, None

        def _local_plan(self, base, prefix, cache, user, max_tokens, timeout):
            return EMPTY, 'stop', None

    headers = json.loads(os.environ.get('FREETALK_CLOUD_HEADERS') or '{}')
    settings = {'protocol': args.cloud_protocol, 'base_url': args.cloud_base_url, 'model': args.cloud_model,
                'api_key': os.environ.get('FREETALK_CLOUD_KEY', ''), 'headers': headers, 'timeout_seconds': 20}
    return CloudOnly(settings, args.tokenizer)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--model', help='local MLX editor model directory')
    parser.add_argument('--cloud-protocol', choices=['openai', 'anthropic'])
    parser.add_argument('--cloud-base-url')
    parser.add_argument('--cloud-model')
    parser.add_argument('--tokenizer', help='tokenizer directory for the cloud backend (the local editor model)')
    parser.add_argument('--cases', type=Path, help='another case file')
    parser.add_argument('--prompts', type=Path, help='edited prompt copies to try, like <support>/prompts')
    parser.add_argument('--ids', help='comma-separated case ids to run')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, help='an earlier --output to compare with')
    args = parser.parse_args()
    cases = load(args.cases) if args.cases else load()
    if args.ids:
        wanted = set(args.ids.split(','))
        cases = [c for c in cases if c['id'] in wanted]
    if args.prompts:
        import prompt_files
        prompt_files.overrides = args.prompts
    if args.model:
        from engine import Editor
        editor = Editor(args.model)
        # Warm up generation too, so the first case is not timed with it.
        editor.edit('嗯，你好。', {}, timeout=30, policy='always')
    elif args.cloud_model:
        if not (args.cloud_protocol and args.cloud_base_url and args.tokenizer):
            parser.error('the cloud backend needs --cloud-protocol, --cloud-base-url and --tokenizer')
        editor = cloud_editor(args)
    else:
        parser.error('choose --model or --cloud-model')

    def show(done, total, row):
        mark = 'OK' if row['exact'] else 'ok' if row['checks'] else 'XX'
        print(f"{mark} {row['seconds']:5.1f}s {row['id']:24} {row['text']!r}", flush=True)

    rows = run(lambda raw, context: editor.edit(raw, context, timeout=6, policy='auto'), cases, show)
    result = {'summary': summary(rows), 'rows': rows}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n')
    print(json.dumps(result['summary'], ensure_ascii=False))
    if args.baseline:
        before = json.loads(args.baseline.read_text())['rows']
        ids = {r['id'] for r in rows}
        before = [r for r in before if r['id'] in ids]
        lost = regressions(before, rows)
        print(f"baseline {summary(before)['exact']} → now {summary(rows)['exact']} exact" + (f"; no longer matching: {', '.join(lost)}" if lost else ''))
        if worse(before, rows):
            sys.exit(1)


if __name__ == '__main__':
    main()
