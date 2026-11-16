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


    def test_new_rules_are_adopted_only_when_nothing_got_worse(self):
        from prompt_tuning import decide
        row = lambda i, ok: {'id': i, 'exact': ok, 'checks': ok, 'group': 'g'}
        before = [row('a', True), row('b', False)]
        good = {'improved': 2, 'worse': 0, 'same': 1, 'accepted_changed': 0, 'accepted_total': 3}
        self.assertTrue(decide(good, before, [row('a', True), row('b', True)])[0])
        self.assertTrue(decide(good, before, before)[0])
        # A case that matched before fails now, even if another one is fixed.
        adopt, reason = decide(good, before, [row('a', False), row('b', True)])
        self.assertFalse(adopt); self.assertIn('测试集', reason)
        for change in [{'worse': 1}, {'accepted_changed': 1}]:
            with self.subTest(change=change):
                self.assertFalse(decide({**good, **change}, before, before)[0])
        # Not worse is enough, as the user asked: a merge that changes nothing is adopted.
        self.assertTrue(decide({**good, 'improved': 0, 'same': 3}, before, before)[0])

    def test_a_rewrite_keeps_the_plan_format(self):
        from prompt_tuning import consolidate, rewrite_problem
        rules = prompt_files_source('edit-rules.txt')
        self.assertIsNone(rewrite_problem(rules, rules + '\n- 保留句末语气词。'))
        self.assertEqual(rewrite_problem(rules, ''), 'empty_rewrite')
        self.assertEqual(rewrite_problem(rules, rules[:200]), 'rewrite_length')
        self.assertEqual(rewrite_problem(rules, rules.replace('cue', '线索')), 'rewrite_drops_fields')
        sent = []
        def complete(messages, max_tokens, timeout):
            sent.append(json.loads(messages[1]['content']))
            return json.dumps({'rules': rules + '\n- 保留句末语气词。'}, ensure_ascii=False)
        self.assertTrue(consolidate(complete, rules, ['保留句末语气词。']).endswith('保留句末语气词。\n'))
        self.assertEqual(sent[0]['preferences'], ['保留句末语气词。'])
        with self.assertRaises(CloudUnavailable):
            consolidate(lambda *a: json.dumps({'rules': '只删口水词。'}), rules, ['x'])

    def test_enough_preferences_are_merged_into_the_rules(self):
        """At the cap the strong model rewrites the rules; the replay and the eval
        set run with the rewrite active, and nothing stays applied afterwards."""
        from types import SimpleNamespace
        from unittest.mock import patch
        import prompt_files
        import worker
        from cleanup_eval import load
        gt = {c['raw']: c['gt'] for c in load()}
        preferences = [f'偏好{i}：保留原文语气' for i in range(8)]
        calls = []
        class Editor:
            preferences, remote = [], None
            def set_preferences(self, rules):
                self.preferences = list(rules)
            def edit(self, raw, context, timeout, policy):
                rewritten = 'REWRITTEN' in prompt_files.source('edit-rules.txt')
                calls.append((rewritten, tuple(self.preferences)))
                return (gt.get(raw, raw + '吧') if rewritten else raw), {}
        def client(messages, max_tokens, timeout):
            if 'preferences' in json.loads(messages[1]['content']) and 'rules' in json.loads(messages[1]['content']):
                return json.dumps({'rules': prompt_files.builtin('edit-rules.txt') + '\nREWRITTEN'})
            return json.dumps({'preferences': preferences}, ensure_ascii=False)
        engine = SimpleNamespace(editor=Editor(), config={})
        cases = [{'raw': '然后再看看结果', 'inserted': '再看看结果', 'final': '然后再看看结果吧'}]
        with patch('cloud_client.chat_client', return_value=client):
            result = worker.tune_prompt(engine, {'cloud': {}, 'cases': cases, 'accepted': []}, lambda value: None)
        self.assertEqual((result['rules'], result['merged']), ([], preferences))
        self.assertTrue(result['prompt'].endswith('REWRITTEN\n'))
        self.assertTrue(result['adopt'], result['reason'])
        self.assertEqual(result['eval']['after'], result['eval']['total'])
        # The rewrite ran without the appended preferences, and was removed afterwards.
        self.assertIn((True, ()), calls)
        self.assertNotIn((True, tuple(preferences)), calls)
        self.assertEqual(prompt_files.pending, {})
        self.assertEqual(engine.editor.preferences, [])


def prompt_files_source(name):
    import prompt_files
    return prompt_files.builtin(name)


if __name__ == '__main__':
    unittest.main()
