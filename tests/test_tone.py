"""The tone chosen per kind of app (python/tone.py) and how cleanup respects it."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))

from tone import apply


def toned(text, tone, **context):
    return apply(text, {'tone': tone, **context})[0]


class FormalTests(unittest.TestCase):
    def test_drops_chatty_particles_and_ends_with_a_mark(self):
        self.assertEqual(toned('好的呀，我明天发给你啦', 'formal'), '好的，我明天发给你了。')
        self.assertEqual(toned('收到，我看一下哦。', 'formal'), '收到，我看一下。')
        self.assertEqual(toned('请查看第三节', 'formal'), '请查看第三节。')
        self.assertEqual(toned('你明天来吗', 'formal'), '你明天来吗？')
        self.assertEqual(toned('Thanks for the update', 'formal'), 'Thanks for the update.')

    def test_keeps_words_that_only_look_like_particles(self):
        for text in ['好啦。', '得嘞。', '哈哈哈，太好了。', '哎呀，忘了。', '我们走吧。', '真的吗？']:
            with self.subTest(text=text):
                self.assertEqual(toned(text, 'formal'), text)

    def test_a_particle_the_user_put_back_stays(self):
        self.assertEqual(toned('好的呀，明天见', 'formal', keep_words=['呀']), '好的呀，明天见。')

    def test_leaves_lists_links_and_quotes_alone(self):
        for text in ['要做：\n1. 补齐单测\n2. 更新文档', '文档在 https://example.com/a', '他说“好的呀”。', '“呀”是语气词。']:
            with self.subTest(text=text):
                self.assertEqual(toned(text, 'formal'), text)


class CasualTests(unittest.TestCase):
    def test_drops_the_full_stop_of_a_one_sentence_message(self):
        self.assertEqual(toned('好的，我马上过来。', 'casual'), '好的，我马上过来')
        self.assertEqual(toned('OK.', 'casual'), 'OK')

    def test_keeps_marks_that_carry_meaning_or_structure(self):
        for text in ['好的。我马上过来。', '真的吗？', '等一下……', '版本是 v2.3.', '要做：\n1. 补齐单测',
                     '这个方案需要再评估一下，我们周三之前给出完整的结论，然后同步到各个团队和相关负责人。']:
            with self.subTest(text=text):
                self.assertEqual(toned(text, 'casual'), text)

    def test_keeps_particles_like_a_chat(self):
        from edits import preclean
        raw = '这个方案我觉得挺好的呀，我们明天再定。'
        self.assertEqual(preclean(raw)[0], '这个方案我觉得挺好的，我们明天再定。')
        self.assertEqual(preclean(raw, {'tone': 'casual'})[0], raw)
        self.assertEqual(preclean(raw, {'scene': 'conversation'})[0], raw)


class NaturalTests(unittest.TestCase):
    def test_natural_and_unknown_tones_change_nothing(self):
        for tone in ['natural', '', 'loud']:
            with self.subTest(tone=tone):
                self.assertEqual(apply('好的呀，明天见。', {'tone': tone}), ('好的呀，明天见。', 0))

    def test_the_eval_contexts_choose_no_tone(self):
        from cleanup_eval import context, load
        self.assertFalse(any(context(case).get('tone') for case in load()))


if __name__ == '__main__':
    unittest.main()
