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

    def test_a_word_ending_where_the_next_begins_is_not_a_stutter(self):
        # 一下|下周 lost 下 and turned next Tuesday into this Tuesday.
        for raw in ['我想跟您确认一下下周二的答辩时间。', '我们马上上线。', '没想到到底这么难。', '为了了解用户需求。',
                    '每个月月初发工资。', '我现在在开会。', '这次变更更新了三个接口。', '早上上班前看一下。',
                    '我整整等了一个小时。', '你好好想想。', '我们一步步来。', '上上周的版本有问题。',
                    '这个功能能不能用？', '大规模模型训练要多久？', '部分分区还没迁移。', '写教学讲解等等。',
                    '房间要干干净净的。', '排着长长的队。']:
            with self.subTest(raw=raw):
                self.assertEqual(preclean(raw)[0], raw)

    def test_stutters_next_to_those_words_still_collapse(self):
        for raw, expected in [('我们上上线了吗？', '我们上线了吗？'), ('默认的整整理日日常的整理', '默认的整理日常的整理'),
                              ('整整个下午都在开会。', '整个下午都在开会。'), ('帮你登登录一下。', '帮你登录一下。')]:
            with self.subTest(raw=raw):
                self.assertEqual(preclean(raw)[0], expected)


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


class PunctuationEditTests(unittest.TestCase):
    """The editor may move, add or remove punctuation, within limits."""

    def edit(self, raw, old, new):
        plan = {'repairs': [], 'edits': [{'old': old, 'new': new, 'kind': 'punctuation'}], 'breaks': [], 'bullets': []}
        text, details = apply_plan(raw, plan, {})
        return text, [e['reason'] for e in details.get('rejected_edits', [])]

    def test_accepted(self):
        for raw, old, new, expected in [
            ('我们先把这个接口。改成异步的。', '接口。改成', '接口改成', '我们先把这个接口改成异步的。'),      # a pause cut the sentence
            ('你觉得这样可以吗。我先发给他。', '吗。', '吗？', '你觉得这样可以吗？我先发给他。'),            # question particle
            ('为什么这个接口会超时。先查日志。', '超时。', '超时？', '为什么这个接口会超时？先查日志。'),      # question word earlier in the clause
            ('先跑测试然后再看结果。', '测试然后', '测试，然后', '先跑测试，然后再看结果。'),                # missing comma
            ('不需要写入配置。或者不写入，效果更好。', '配置。或者', '配置，或者', '不需要写入配置，或者不写入，效果更好。'),
        ]:
            with self.subTest(raw=raw):
                self.assertEqual(self.edit(raw, old, new), (expected, []))

    def test_refused(self):
        for raw, old, new, reason in [
            ('他说“好的。”然后就走了。', '“好的。”', '“好的”', 'literal_span'),
            ('这个方案可行吗？我觉得可以。', '可行吗？', '可行吗。', 'question_removed'),
            ('明天开会。记得带电脑。', '开会。', '开会？', 'question_added_without_question'),
            ('太好了！终于跑通了。', '太好了！', '太好了。', 'exclamation_changed'),
            ('先看（附录）再说。', '（附录）', '附录', 'paired_mark_changed'),
            # The model quoted a span that is not in the dictation. Applying it
            # at offset -1 used to delete the first characters of the text.
            ('我们先把登录接口。改成异步的，然后再压测。', '异步的然后', '异步的，然后', 'source_not_unique'),
        ]:
            with self.subTest(raw=raw):
                text, reasons = self.edit(raw, old, new)
                self.assertEqual((text, reasons), (raw, [reason]))

    def test_an_edit_at_the_end_keeps_the_final_mark(self):
        # Local models drop the closing 。 when a merge reaches the end.
        self.assertEqual(self.edit('我们先把登录接口。改成异步的，然后再压测。', '接口。改成异步的，然后再压测。', '接口改成异步的，然后再压测'),
                         ('我们先把登录接口改成异步的，然后再压测。', []))


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