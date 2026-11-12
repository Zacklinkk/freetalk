"""Prompt tuning: cases go to a strong model, rules come back bounded, and
nothing is adopted without a local replay that compares old and new rules."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))

from cloud_client import CloudUnavailable
from engine import load_preferences, prompt, with_preferences
from prompt_tuning import clean_rules, evaluate, propose, request

CASES = [{'raw': '嗯，我们先测试一下这个接口。', 'inserted': '我们先测试接口。', 'final': '我们先测试一下这个接口。'},
         {'raw': '然后再看看结果吧。', 'inserted': '再看看结果。', 'final': '再看看结果吧。'}]


class PromptTuningTests(unittest.TestCase):
    def test_rules_are_bounded_single_lines(self):
        rules = clean_rules(['- 保留“一下”“这个”等口语缓和词。', '保留句末语气词。', '保留句末语气词。', 'x', '换\n行也算一行', 42, 'a' * 200]
                            + [f'规则{i}：保留原文语气' for i in range(20)])
        self.assertEqual(rules[:3], ['保留“一下”“这个”等口语缓和词。', '保留句末语气词。', '换 行也算一行'])
        self.assertEqual(clean_rules(['1. 10秒以上的停顿可以分段。']), ['10秒以上的停顿可以分段。'])
        self.assertEqual(len(rules), 10)
        self.assertTrue(all(len(r) <= 80 for r in rules))

    def test_request_numbers_cases_and_bounds_text(self):
        long = dict(CASES[0], raw='长' * 2000)
        body = json.loads(request([long, CASES[1]], 'RULES', ['旧偏好']))
        self.assertEqual([c['case'] for c in body['cases']], [0, 1])
        self.assertLessEqual(len(body['cases'][0]['raw']), 801)
        self.assertEqual((body['current_rules'], body['current_preferences']), ('RULES', ['旧偏好']))

    def test_propose_parses_or_reports_an_unusable_reply(self):
        sent = []
        def complete(messages, max_tokens, timeout):
            sent.append(messages)
            return '```json\n{"preferences":["保留“一下”等缓和语气。"],"evidence":[{"preference":0,"cases":[0]}],"ignored":[]}\n```'
        rules, detail = propose(complete, CASES, 'RULES', [])
        self.assertEqual(rules, ['保留“一下”等缓和语气。'])
        self.assertEqual(detail['evidence'][0]['cases'], [0])
        self.assertIn('raw', sent[0][1]['content'])
        with self.assertRaises(CloudUnavailable):
            propose(lambda *a: '我认为应该保留语气词。', CASES, 'RULES', [])

    def test_evaluate_compares_old_and_new_rules(self):
        def edit(raw, rules):
            # The stub editor strips 嗯/然后 and, without a preference, also 一下/这个/吧.
            text = raw.replace('嗯，', '').replace('然后', '')
            return text if rules else text.replace('一下', '').replace('这个', '').replace('吧', '')
        scores, examples = evaluate(edit, CASES, ['保存文件吧。', '打开设置。'], [], ['保留缓和语气'])
        self.assertEqual((scores['improved'], scores['worse'], scores['same']), (2, 0, 0))
        self.assertEqual((scores['accepted_changed'], scores['accepted_total']), (1, 2))
        self.assertEqual([e['result'] for e in examples], ['improved', 'improved', 'accepted_changed'])
        self.assertEqual((examples[-1]['before'], examples[-1]['after']), ('保存文件。', '保存文件吧。'))

    def test_preferences_follow_the_built_in_rules_and_load_safely(self):
        base = prompt('edit-plan.txt')
        self.assertEqual(prompt('edit-plan.txt', []), base)
        extended = prompt('edit-plan.txt', ['保留句末语气词。'])
        self.assertTrue(extended.startswith(base.rstrip('\n')))
        self.assertTrue(extended.endswith('- 保留句末语气词。\n'))
        self.assertEqual(with_preferences('X', []), 'X')
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(load_preferences(d), [])
            (Path(d) / 'cleanup-preferences.json').write_text('{broken')
            self.assertEqual(load_preferences(d), [])
            (Path(d) / 'cleanup-preferences.json').write_text(json.dumps({'rules': ['保留句末语气词。', 7, '\x00坏']}))
            self.assertEqual(load_preferences(d), ['保留句末语气词。'])
        self.assertEqual(load_preferences(None), [])


if __name__ == '__main__':
    unittest.main()
