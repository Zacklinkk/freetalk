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


class SegmentBoundaryTests(unittest.TestCase):
    """Dictation is transcribed in pause-delimited pieces, and the recognizer
    ends every piece with a terminal mark even when the pause fell mid-sentence."""

    FIXED = [
        # A sentence-final particle said after the pause.
        ('之前必须要写入配置，但现在已经不需要写入配置。或者不写入配置，效果会更好。的',
         '之前必须要写入配置，但现在已经不需要写入配置。或者不写入配置，效果会更好的。'),
        ('这个版本能今天发出去。吗', '这个版本能今天发出去吗？'),
        ('我已经测完。了，可以合并。', '我已经测完了，可以合并。'),
        ('先跑一遍回归。吧！', '先跑一遍回归吧！'),
        # A connective left alone between two marks.
        ('新链接也要做对应的修改。或者。旧的表格应该也能改吧。', '新链接也要做对应的修改。或者，旧的表格应该也能改吧。'),
        ('先保留日志。而且。不要覆盖原件。', '先保留日志。而且，不要覆盖原件。'),
    ]

    KEPT = [
        '这是他写的。的确如此。',
        '我说完了。了解一下背景再决定。',
        '去吧台点单。吧台在左边。',
        '他说“好的。吧”是错字，原样保留。',
        '或者。',
    ]

    def test_stranded_pieces_rejoin(self):
        for raw, expected in self.FIXED:
            with self.subTest(raw=raw):
                self.assertEqual(preclean(raw)[0], expected)

    def test_real_sentence_starts_are_kept(self):
        for raw in self.KEPT:
            with self.subTest(raw=raw):
                self.assertEqual(preclean(raw)[0], raw)


class StrayPunctuationTests(unittest.TestCase):
    """Deleting a filler next to a comma must not leave the comma behind."""

    FIXED = [
        ('，那个，你看一下日志有没有报错。', '那个，你看一下日志有没有报错。'),
        ('，我觉得这个方案可以再简化一点。', '我觉得这个方案可以再简化一点。'),
        ('我们先这样，。然后再说。', '我们先这样。然后再说。'),
        ('先这样，，再看。', '先这样，再看。'),
        ('保存文件。，下一步。', '保存文件。下一步。'),
    ]
    KEPT = ['一、先跑测试。二、再看结果。', '他说“，好的”。', '代码 `a,,b` 原样。', '问题是：为什么？', '今天：开会。', '先保存，然后关闭。']

    def test_orphaned_marks_are_removed(self):
        from edits import tidy_punctuation
        for raw, expected in self.FIXED:
            with self.subTest(raw=raw):
                self.assertEqual(tidy_punctuation(raw)[0], expected)
        for raw in self.KEPT:
            with self.subTest(raw=raw):
                self.assertEqual(tidy_punctuation(raw)[0], raw)

    def test_a_deleted_leading_filler_takes_its_comma(self):
        # The plan the local model actually produced for these sentences.
        for raw, old in [('就是，我觉得这个方案可以再简化一点。', '就是'), ('那个，明天的会改到下午三点。', '那个')]:
            with self.subTest(raw=raw):
                text, _ = apply_plan(raw, {'repairs': [], 'edits': [{'old': old, 'new': '', 'kind': 'filler'}], 'breaks': [], 'bullets': []}, {})
                from edits import tidy_punctuation
                self.assertFalse(tidy_punctuation(text)[0].startswith('，'))


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