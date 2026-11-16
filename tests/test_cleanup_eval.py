"""Replay the cleanup eval set without a model.

Each case in evals/cleanup-cases.json may record the plan a correct editor
returns (`plan`, or `drop` for filler selection) and plans models actually
proposed that must be refused (`refused`). The editor's own code runs end to
end with the model replaced by those replies, so a rule or validator change
that breaks a fixed case fails here, in CI. The real model runs with
scripts/eval-cleanup.py.

Run with:  python -m unittest tests.test_cleanup_eval -v
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))

from cleanup_eval import load, context, flat
from edits import core
from engine import Editor

EMPTY = {'repairs': [], 'edits': [], 'restarts': [], 'breaks': [], 'bullets': []}


class Tokenizer:
    def encode(self, text):
        return list(text)


def replay(case, reply=None):
    """Run the case with the model replaced by `reply`: {'plan': ...} or {'drop': [...]}.

    `drop` lists the filler words to remove by their text, or "*" for every
    candidate offered. With no reply the model returns nothing to change.
    """
    reply = reply or {}
    plan = {**EMPTY, **reply.get('plan', {})}
    def remote(messages, max_tokens, timeout):
        if messages[0]['content'] == 'filler':
            offered = json.loads(messages[-1]['content'])['candidates']
            drop = reply.get('drop', [])
            return json.dumps({'drop': [c['id'] for c in offered if drop == '*' or core(c['old']) in {core(d) for d in drop}]})
        return json.dumps(plan, ensure_ascii=False)
    remote.model = 'replay'
    e = Editor.__new__(Editor)
    e.mode, e.emit, e.tokenizer = 'edits', lambda value: None, Tokenizer()
    e.base, e.prefix, e.cache = [{'role': 'system', 'content': 'edit'}], [], None
    e.restart_base, e.restart_prefix, e.restart_cache = [{'role': 'system', 'content': 'restart'}], [], None
    e.filler_base = [{'role': 'system', 'content': 'filler'}]
    e._local_plan = lambda *args: (json.dumps(EMPTY), 'stop', None)
    e.remote, e.remote_timeout = remote, 5
    return e.edit(case['raw'], context(case), timeout=6, policy='auto')


class CleanupEvalReplayTests(unittest.TestCase):
    cases = load()

    def test_case_ids_are_unique_and_variants_name_their_case(self):
        ids = [c['id'] for c in self.cases]
        self.assertEqual(len(ids), len(set(ids)))
        for case in self.cases:
            if 'variant_of' in case:
                self.assertIn(case['variant_of'], ids)

    def test_the_correct_reply_gives_the_expected_text(self):
        # `also_correct`: other shapes of a right plan that a model returned.
        for case in self.cases:
            for reply in [case.get('reply')] + case.get('also_correct', []):
                with self.subTest(case=case['id'], reply=reply):
                    text, meta = replay(case, reply)
                    self.assertEqual(flat(text), flat(case['gt']), meta.get('rejected_edits'))

    def test_wrong_replies_change_nothing(self):
        # Plans a model proposed (or could propose) that the checks must refuse:
        # the output is what it would be had the model proposed nothing.
        for case in self.cases:
            unchanged = replay(case)[0]
            for reply in case.get('refused', []):
                with self.subTest(case=case['id'], reply=reply):
                    self.assertEqual(replay(case, reply)[0], unchanged)


if __name__ == '__main__':
    unittest.main()
