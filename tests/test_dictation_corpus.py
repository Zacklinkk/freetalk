"""Regression corpus distilled from real dictation failures.

Each case is a de-identified sentence kept verbatim in shape: names, product
names and paths are replaced with placeholders, but the disfluency pattern that
broke the old implementation is preserved. These are not new features; they pin
down behaviour that regressed before, so a change to the cleanup rules fails
here instead of in a user's transcript.

Run with:  python -m unittest tests.test_dictation_corpus -v
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))

from edits import preclean, apply_plan
from disfluency import inspect


class DoubledCharacterTests(unittest.TestCase):
    """A doubled single character is a stutter unless it spells a real word."""

    STUTTERS = [
        ('给我们，这这个方案已经脱敏了。', '给我们，这个方案已经脱敏了。'),
        ('比如说，我我们和朋友聊到这个话题。', '比如说，我们和朋友聊到这个话题。'),
        ('看一下它是能能不能装一个本地模型。', '看一下它是能不能装一个本地模型。'),
        ('突破这个设备本身的系统限制。', '突破这个设备本身的系统限制。'),
        ('我们看到有有，而不是没有。', '我们看到有，而不是没有。'),
        ('这个方案由团队中一员，他他应该站在客户角度。', '这个方案由团队中一员，他应该站在客户角度。'),
        ('有没有更更好看的方式？', '有没有更好看的方式？'),
        ('然后你你要找到合适的文件。', '然后你要找到合适的文件。'),
        ('这一批都都先跑验证集。', '这一批都先跑验证集。'),
        ('替换成新版本文档的在线链接。', '替换成新版本文档的在线链接。'),
    ]

    LEGITIMATE = [
        '大家看看这个结果。',
        '而不仅仅是一个助手。',
        '编号是零一。',
        '星星很亮。',
        '谢谢你的帮助。',
        '我刚刚才看到。',
    ]

    def test_stutters_collapse(self):
        for raw, expected in self.STUTTERS:
            with self.subTest(raw=raw):
                self.assertEqual(preclean(raw)[0], expected)

    def test_reduplicated_words_survive(self):
        for raw in self.LEGITIMATE:
            with self.subTest(raw=raw):
                self.assertEqual(preclean(raw)[0], raw)

    def test_word_boundary_doubles_are_not_stutters(self):
        # 成都/都 and 成就/就 are legitimate word boundaries.
        for raw in ['成都可以，成就就很大。', '首都能不能满足要求？']:
            with self.subTest(raw=raw):
                self.assertEqual(preclean(raw)[0], raw)

    def test_compound_stutter_prefers_the_whole_word(self):
        # 系统系系统 collapses to 系统, not 系统系统.
        self.assertEqual(preclean('系统系系统能能不能操操控？')[0], '系统能不能操控？')


class RepairBoundaryTests(unittest.TestCase):
    """Spoken self-corrections keep the reason and drop only the old value."""

    CASES = [
        '呃，先用十个样本，不对，改成十二个。保留所有日志。',
        '周一上线。不对，改成周三上线，因为周二还要验收。',
    ]

    def test_routes_to_correction_path(self):
        for raw in self.CASES:
            with self.subTest(raw=raw):
                self.assertIn('self_correction', inspect(raw))

    def test_unresolved_correction_is_flagged(self):
        # A correction marker with no replacement must not silently delete text.
        from disfluency import unresolved_correction
        self.assertTrue(unresolved_correction('先用十个样本，不对，保留所有日志。'))
        self.assertFalse(unresolved_correction('先用十二个样本。保留所有日志。'))


class AliasHygieneTests(unittest.TestCase):
    """Aliases with punctuation or whitespace can never match a transcript."""

    def test_punctuation_bearing_aliases_are_dropped(self):
        from context import normalize_context
        ctx = normalize_context({
            'personal_terms': ['插话'],
            'personal_aliases': [
                {'heard': '插话。', 'term': '插话'},
                {'heard': 'cha hua', 'term': '插话'},
            ],
        })
        self.assertEqual(ctx['personal_aliases'], [])

    def test_clean_alias_is_kept(self):
        from context import normalize_context
        ctx = normalize_context({
            'personal_terms': ['插话'],
            'personal_aliases': [{'heard': '插画', 'term': '插话'}],
        })
        self.assertEqual([(a['heard'], a['term']) for a in ctx['personal_aliases']], [('插画', '插话')])


class LayoutSafetyTests(unittest.TestCase):
    """A cleanup pass must never invent structure the speaker did not use."""

    def test_no_break_without_paragraph_policy(self):
        raw = '先检查标题格式。再检查每一段的标点。最后确认保存位置。'
        plan = {'edits': [], 'breaks': [0, 1], 'bullets': []}
        self.assertEqual(apply_plan(raw, plan, {})[0], raw)

    def test_bullets_require_explicit_enumeration(self):
        raw = '先分析这个问题。再保留所有细节。最后给出结果。'
        plan = {'edits': [], 'breaks': [], 'bullets': [0, 1, 2]}
        self.assertEqual(apply_plan(raw, plan, {})[0], raw)


if __name__ == '__main__':
    unittest.main()