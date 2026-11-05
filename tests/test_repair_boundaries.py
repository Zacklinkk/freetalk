import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from disfluency import inspect, unresolved_correction
from edits import apply_plan, repetition_candidates
from engine import guard_edit


def repair(raw, old, new, cue):
    return apply_plan(raw, {'repairs':[dict(old=old, new=new, cue=cue)], 'edits':[], 'breaks':[], 'bullets':[]}, {})


class RepairBoundaryTests(unittest.TestCase):
    def test_missing_punctuation_and_broad_model_cue(self):
        for raw in ['复制八份文件不对，改成九份。保存原件。', '复制八份文件不对改成九份。保存原件。']:
            text, meta = repair(raw, '八份', '九份', raw)
            self.assertEqual(text, '复制九份文件。保存原件。')
            self.assertEqual(meta['repair_count'], 1)
            self.assertIn('self_correction', inspect(raw))

    def test_partial_cue_consumes_connected_markers(self):
        for raw in ['复制八份文件不对，改成九份。保存原件。', '复制八份文件，不对，不对。改成九份。保存原件。']:
            self.assertEqual(repair(raw, '八份文件', '九份', '改成九份。')[0], '复制九份文件。保存原件。')

    def test_partial_cue_does_not_swallow_another_judgment(self):
        raw = '定在八点。这个结论不对，改成九点。'
        text, _ = repair(raw, '八点', '九点', '改成九点。')
        self.assertIn('这个结论不对', text)

    def test_cue_expansion_does_not_match_inside_english_words(self):
        from edits import complete_repair_cue
        raw = 'ten piano, make that twelve'
        self.assertEqual(complete_repair_cue(raw, 3, raw.index('make that')), raw.index('make that'))

    def test_elliptical_copied_noun_preserves_modifier(self):
        raw = '如果审核通过，复制八份脱敏文件，不对，改成九份。不要覆盖原件。'
        text, _ = repair(raw, '八份脱敏文件', '九份脱敏文件', raw)
        self.assertEqual(text, '如果审核通过，复制九份脱敏文件。不要覆盖原件。')

    def test_partial_repeated_noun_cannot_silently_change_modifier(self):
        raw = '复制八份非公开文件，不对，改成九份公开文件。'
        self.assertEqual(repair(raw, '八份非公开文件', '九份非公开文件', raw)[0], raw)

    def test_adjacent_prefix_is_reviewed_and_exactly_collapsed(self):
        for raw, expected in [('保存，保存所有文件。','保存所有文件。'), ('请检查一下，检查一下所有文件。','请检查一下所有文件。'), ('不要，不要覆盖原件。','不要覆盖原件。'), ('统一，统一这些设置。','统一这些设置。')]:
            with self.subTest(raw=raw):
                self.assertIn('adjacent_restart', inspect(raw))
                plan = {'edits':repetition_candidates(raw), 'breaks':[], 'bullets':[]}
                text, meta = apply_plan(raw, plan, {})
                self.assertEqual(text, expected)
                self.assertIsNone(guard_edit(meta['guard_source'], text))

    def test_repetition_deletion_can_leave_the_second_prefix_outside_edit(self):
        raw = '保存，保存所有文件。'
        plan = {'edits':[{'old':'保存，','new':'','kind':'stutter'}], 'breaks':[], 'bullets':[]}
        self.assertEqual(apply_plan(raw, plan, {})[0], '保存所有文件。')

    def test_repetitions_with_information_or_emphasis_stay(self):
        for raw in ['保存草稿，保存附件。', '必须保存，保存所有文件，这是重点。', '这个很重要，重要的事情说两次。', '一年，一年地增长。', '保留“保存，保存所有文件”这个例子。', '非常，非常开心。']:
            with self.subTest(raw=raw):
                self.assertEqual(repetition_candidates(raw), [])
                self.assertNotIn('adjacent_restart', inspect(raw))

    def test_no_license_for_paraphrase_or_losing_negation(self):
        for old, new in [('保存，保存所有文件','删除所有文件'), ('不要，不要覆盖原件','覆盖原件')]:
            raw = old+'。'
            plan = {'edits':[{'old':old,'new':new,'kind':'stutter'}], 'breaks':[], 'bullets':[]}
            self.assertEqual(apply_plan(raw,plan,{})[0], raw)

    def test_no_correction_value_or_quoted_cue_stays(self):
        for raw, old, new, cue in [('复制八份文件。不对。','八份','九份','不对。'), ('例子：“复制八份文件不对，改成九份。”','八份','九份','不对，改成九份。')]:
            self.assertEqual(repair(raw,old,new,cue)[0], raw)

    def test_unresolved_warning_is_not_a_warning_on_every_change_command(self):
        for text in ['复制九份文件。不对。', '复制九份文件。不对，保存原件。']:
            self.assertTrue(unresolved_correction(text))
        for text in ['改成九份。', '这个结果不对，需要检查。', '例子：“不对，改成九份。”']:
            self.assertFalse(unresolved_correction(text))


if __name__ == '__main__':
    unittest.main()
