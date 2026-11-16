"""The cleanup eval set: run it through an editor and compare with a baseline.

The cases (evals/cleanup-cases.json) are the 22 dictations the user approved
plus held-out variants of each failure type. A prompt or rule change is
adopted only if no case that passed before fails afterwards and the number of
exact matches does not drop. scripts/eval-cleanup.py runs them on a real
model; tests/test_cleanup_eval.py replays a recorded plan per case in CI.
"""
import json
import re
import time
from pathlib import Path

CASES = Path(__file__).resolve().parents[1] / 'evals' / 'cleanup-cases.json'


def load(path=CASES):
    return json.loads(Path(path).read_text())['cases']


def context(case):
    from context import normalize_context
    return normalize_context({'layout_policy': 'minimal', **case.get('context', {})})


def flat(text):
    """Compare text, not CJK/Latin spacing."""
    text = re.sub(r'(?<=[一-鿿，。！？：；、“”])[ \t]+|[ \t]+(?=[一-鿿，。！？：；、“”])', '', text.strip())
    return re.sub(r'[ \t]+', ' ', text)


def score(case, text):
    exact = flat(text) == flat(case['gt'])
    checks = all(m in text for m in case.get('must', [])) and not any(m in text for m in case.get('must_not', []))
    return exact, checks


def run(edit, cases, progress=lambda done, total, row: None):
    """`edit(raw, context)` returns (text, meta) the way Editor.edit does.

    A case whose model call timed out runs once more: the eval measures the
    cleanup, and a busy machine should not decide whether a change is adopted.
    """
    rows = []
    for case in cases:
        started = time.perf_counter()
        text, meta = edit(case['raw'], context(case))
        retried = meta.get('reason') == 'timeout' or bool(meta.get('partial_plan'))
        if retried:
            started = time.perf_counter()
            text, meta = edit(case['raw'], context(case))
        exact, checks = score(case, text)
        rows.append({'id': case['id'], 'group': case.get('group', ''), 'text': text, 'exact': exact, 'checks': checks,
                     'seconds': round(time.perf_counter() - started, 2), 'model_used': bool(meta.get('model_used')), 'retried': retried,
                     'engine': meta.get('engine'), 'status': meta.get('status'), 'reason': meta.get('reason'),
                     'cloud_fallback': meta.get('cloud_fallback'), 'candidate': meta.get('candidate'),
                     'rejected': [[r.get('old'), r.get('new'), r.get('reason')] for r in meta.get('rejected_edits', []) if isinstance(r, dict)]})
        progress(len(rows), len(cases), rows[-1])
    return rows


def summary(rows):
    groups = {}
    for row in rows:
        group = groups.setdefault(row['group'], {'exact': 0, 'total': 0})
        group['exact'] += row['exact']; group['total'] += 1
    return {'exact': sum(r['exact'] for r in rows), 'checks': sum(r['checks'] for r in rows), 'total': len(rows), 'groups': groups}


def regressions(before, after):
    """Ids of cases that matched before and do not match now."""
    passed = {r['id'] for r in before if r['exact']}
    return [r['id'] for r in after if r['id'] in passed and not r['exact']]


def worse(before, after):
    return bool(regressions(before, after)) or summary(after)['exact'] < summary(before)['exact']
