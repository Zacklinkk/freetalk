import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from disfluency import inspect
from edits import apply_plan, restart_candidates
from engine import guard_edit
from numerals import normalize


def restart(raw, drop, keep, cue):
    return apply_plan(raw, {'restarts': [{'drop': drop, 'keep': keep, 'cue': cue}],
                           'repairs': [], 'edits': [], 'breaks': [], 'bullets': []}, {})


class SpokenRestartTests(unittest.TestCase):
    def test_restatement_retains_final_conditional_request(self):
        raw = '先检查没有通过的样例。哎，算了，所有样例都重新测试。先确认 Nova 三能用，能用的话，这二十道题目都用 Nova 三重新测试。'
        text, meta = restart(raw, [0, 1], [2], '哎，算了')
        self.assertEqual(normalize(text)[0], '先确认 Nova 3能用，能用的话，这20道题目都用 Nova 3重新测试。')
        self.assertEqual(meta['restart_count'], 1)
        self.assertIsNone(guard_edit(meta['guard_source'], text))

    def test_independent_budget_survives(self):
        raw = '预算上限五百元。只重跑失败的题。哎，算了，全部重新跑。你先确认有没有资源，有资源的话，这三十道题都重新跑一遍。'
        text, _ = restart(raw, [1, 2], [3], '哎，算了')
        self.assertEqual(text, '预算上限五百元。你先确认有没有资源，有资源的话，这三十道题都重新跑一遍。')
        self.assertEqual(restart(raw, [0, 1, 2], [3], '算了')[0], raw)
        self.assertEqual(restart_candidates(raw)[0]['drop'], [1, 2])

    def test_explicit_edit_command_is_consumed(self):
        raw = '先用十个样本测试。刚才这句不要了，我重新说。先用十二个样本测试，保留所有日志。'
        self.assertEqual(restart(raw, [0, 1], [2], '刚才这句不要了，我重新说')[0], '先用十二个样本测试，保留所有日志。')

    def test_transition_reason_number_and_condition_are_not_discarded(self):
        for detail in ['因为测试环境升级了', '预算上限五百元', '必须保留错误日志', '用十二个测试节点']:
            raw = '只重跑失败的题。算了，全部重跑，' + detail + '。请把所有题都重新跑一遍。'
            with self.subTest(detail=detail):
                self.assertEqual(restart(raw, [0, 1], [2], '算了')[0], raw)
                self.assertEqual(restart_candidates(raw), [])

    def test_valid_condition_in_earlier_sentence_cannot_disappear(self):
        raw = '如果资源可用，只重跑失败的题。算了，全部重新跑。所有题都重新跑一遍。'
        self.assertEqual(restart(raw, [0, 1], [2], '算了')[0], raw)

    def test_unfinished_unrelated_and_quoted_cues_are_not_deletions(self):
        for raw, drop, keep, cue in [
            ('只重跑失败的题。哎，算了。', [0, 1], [2], '算了'),
            ('只重跑失败的题。哎，算了。明天下午记得去医院复查。', [0, 1], [2], '算了'),
            ('保留原稿。用户说“算了，全部重新跑”。全部题目重新跑一遍。', [0, 1], [2], '算了'),
            ('保留原稿。如果用户说算了，全部重新跑。全部题目重新跑一遍。', [0, 1], [2], '算了'),
        ]:
            with self.subTest(raw=raw):
                self.assertEqual(restart(raw, drop, keep, cue)[0], raw)

    def test_bad_or_nonadjacent_source_ids_are_rejected(self):
        raw = '只重跑失败题。算了，全部重跑。检查资源。全部题目重跑。'
        for drop, keep in [([0, 1], [3]), ([True, 1], [2]), ([0, 1], [-1]), ([0, 1], [2, 2]), ([0, 0], [1])]:
            self.assertEqual(restart(raw, drop, keep, '算了')[0], raw)

    def test_short_restart_routes_to_model_but_quoted_discussion_does_not(self):
        self.assertIn('spoken_restart', inspect('用旧模型。算了，重新测试。请用新模型重新测试。'))
        self.assertIn('spoken_restart', inspect('文档周五提交。刚才这句不要了，我重新说。文档周六提交。'))
        for raw in ['他说“算了，重说一遍”。', '如果用户说算了，需要处理。', '请删除报告中的上一段。']:
            self.assertNotIn('spoken_restart', inspect(raw))

    def test_model_versions_quantities_and_ordinary_words(self):
        cases = {
            'Opus 五，Claude 四点五，Qwen 三，Nova 一，v五。': 'Opus 5，Claude 4.5，Qwen 3，Nova 1，v5。',
            '三十道题，只有一道题，做一道题。': '30道题，只有1道题，做一道题。',
            'Opus 一直能用，统一格式，先看一下，第一，三思而后行。': 'Opus 一直能用，统一格式，先看一下，第一，三思而后行。',
            'Opus 一步到位。': 'Opus 一步到位。',
            'AI 一清二楚，AI 一帆风顺。': 'AI 一清二楚，AI 一帆风顺。',
            '“Opus 五”与 `Qwen 三`。': '“Opus 五”与 `Qwen 三`。',
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(normalize(raw)[0], expected)
        self.assertEqual(normalize('保留品牌名称 Nova 五。', ['Nova 五'])[0], '保留品牌名称 Nova 五。')


if __name__ == '__main__':
    unittest.main()
