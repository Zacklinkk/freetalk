"""Habits learned from the user's edits after insertion (python/style_learning.py)."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))

from style_learning import StyleStore, apply, describe, kept_words, lessons_from_edit


def learned(inserted, current, raw=None, scope='general'):
    lessons, _ = lessons_from_edit(raw or inserted, inserted, current, scope)
    return [describe(l) for l in lessons]


class LessonTests(unittest.TestCase):
    def test_deleted_fillers_and_particles(self):
        self.assertEqual(learned('就是我们先测试一下。', '我们先测试一下。'), ['删除句首的“就是”'])
        self.assertEqual(learned('那个，你看一下日志。', '你看一下日志。'), ['删除句首的“那个”'])
        self.assertEqual(learned('我们先这样，就是，明天再说。', '我们先这样，明天再说。'), ['删除逗号后的“就是”'])
        self.assertEqual(learned('然后起一个服务。', '起一个服务。'), ['删除开头的“然后”'])
        self.assertEqual(learned('好的啊，明天见。', '好的，明天见。', scope='email'), ['邮件里删除句末的“啊”'])

    def test_punctuation_and_spacing(self):
        self.assertEqual(learned('明天见。', '明天见', scope='chat'), ['聊天应用里句末不加句号'])
        self.assertEqual(learned('先测一遍但是别发布。', '先测一遍，但是别发布。'), ['在“但是”前加逗号'])
        self.assertEqual(learned('你看呢。', '你看呢？'), ['“呢”结尾的句子用问号'])
        self.assertEqual(learned('用SFT训练。', '用 SFT 训练。'), ['中文和英文之间加空格'])

    def test_words_put_back(self):
        self.assertEqual(learned('好的，明天见。', '好的呀，明天见。', raw='好的呀，明天见。', scope='chat'), ['聊天应用里保留“呀”'])
        # A word the dictation never had is new content, not a kept word.
        self.assertEqual(learned('好的，明天见。', '好的呀，明天见。', raw='好的，明天见。'), [])

    def test_content_edits_teach_nothing(self):
        for inserted, current in [('答案就是这个。', '答案这个。'), ('选择那个文件。', '选择文件。'), ('先这样。然后再说。', '先这样。再说。'),
                                  ('今天天气很好，我们出去玩。', '今天下雨了，我们在家看电影吧。')]:
            with self.subTest(inserted=inserted):
                self.assertEqual(learned(inserted, current), [])


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = StyleStore(self.directory.name)

    def test_a_change_needs_two_sessions_and_a_reverted_edit_counts_nothing(self):
        first = self.store.learn('s1', '就是我们先测。', '就是我们先测。', '我们先测。')
        self.assertEqual([(l['count'], l['active']) for l in first], [(1, False)])
        self.assertEqual(self.store.active(), [])
        # The user put the word back in the same session: nothing was learned.
        self.store.learn('s1', '就是我们先测。', '就是我们先测。', '就是我们先测。')
        self.assertEqual(self.store.load(), [])
        self.store.learn('s1', '就是我们先测。', '就是我们先测。', '我们先测。')
        second = self.store.learn('s2', '就是你看一下。', '就是你看一下。', '你看一下。')
        self.assertEqual([(l['count'], l['active']) for l in second], [(2, True)])
        self.assertEqual([l['word'] for l in self.store.active()], ['就是'])

    def test_undo_takes_back_only_this_session(self):
        self.store.learn('s1', '就是我们先测。', '就是我们先测。', '我们先测。')
        self.store.learn('s2', '就是你看一下。', '就是你看一下。', '你看一下。')
        self.assertTrue(self.store.undo('s2'))
        self.assertEqual([r['count'] for r in self.store.load()], [1])
        self.assertFalse(self.store.undo('s2'))
        # The field is still watched after undo; the same edit must not come back.
        self.assertEqual(self.store.learn('s2', '就是你看一下。', '就是你看一下。', '你看一下。'), [])
        self.assertEqual([(r['count'], r['status']) for r in self.store.listing()], [(1, '再出现 1 次后生效')])

    def test_an_opposite_edit_retires_a_lesson_and_undo_restores_it(self):
        for session in ('s1', 's2'):
            self.store.learn(session, '明天见。', '明天见。', '明天见', scope='chat')
        self.assertEqual(len(self.store.active('chat')), 1)
        self.store.learn('s3', '好的', '好的', '好的。', scope='chat')
        self.assertEqual([describe(r) for r in self.store.load()], ['聊天应用里句末加句号'])
        self.store.undo('s3')
        self.assertEqual([describe(r) for r in self.store.load()], ['聊天应用里句末不加句号'])

    def test_lessons_fade_and_stay_private(self):
        now = 1_800_000_000
        for session in ('s1', 's2'):
            self.store.learn(session, '就是我们先测。', '就是我们先测。', '我们先测。', now=now)
        self.assertTrue(self.store.active(now=now))
        self.assertFalse(self.store.active(now=now + 90 * 86400))
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)

    def test_scope_limits_tone_lessons_to_their_kind_of_app(self):
        for session in ('s1', 's2'):
            self.store.learn(session, '明天见。', '明天见。', '明天见', scope='chat')
        self.assertTrue(self.store.active('chat'))
        self.assertFalse(self.store.active('email'))


class ApplyTests(unittest.TestCase):
    def run_lessons(self, text, *lessons):
        return apply(text, {'style': list(lessons)})[0]

    def test_drops_only_in_the_learned_position(self):
        drop = {'kind': 'drop', 'word': '就是', 'where': 'start', 'scope': 'all'}
        self.assertEqual(self.run_lessons('就是我们明天上线。', drop), '我们明天上线。')
        for text in ['就是这个。', '答案就是这个。', '我觉得就是不行。', '代码 `就是我们` 原样。']:
            with self.subTest(text=text):
                self.assertEqual(self.run_lessons(text, drop), text)
        demonstrative = {'kind': 'drop', 'word': '那个', 'where': 'start', 'scope': 'all'}
        self.assertEqual(self.run_lessons('那个，你看一下。那个文件也发我。', demonstrative), '你看一下。那个文件也发我。')

    def test_punctuation_lessons(self):
        no_period = {'kind': 'final_mark', 'mark': '', 'scope': 'chat'}
        self.assertEqual(self.run_lessons('好的，明天见。', no_period), '好的，明天见')
        self.assertEqual(self.run_lessons('版本是 v2.3.', no_period), '版本是 v2.3.')
        self.assertEqual(self.run_lessons('要做：\n1. 补齐单测\n2. 更新文档', no_period), '要做：\n1. 补齐单测\n2. 更新文档')
        comma = {'kind': 'comma_before', 'word': '但是', 'scope': 'all'}
        self.assertEqual(self.run_lessons('我们先测一遍但是别发布。', comma), '我们先测一遍，但是别发布。')
        self.assertEqual(self.run_lessons('但是别发布。', comma), '但是别发布。')
        space = {'kind': 'spacing', 'value': 'space', 'scope': 'all'}
        self.assertEqual(self.run_lessons('用SFT训练。', space), '用 SFT 训练。')

    def test_kept_words(self):
        self.assertEqual(kept_words([{'kind': 'keep', 'word': '呀', 'scope': 'chat'}, {'kind': 'drop', 'word': '就是', 'where': 'start', 'scope': 'all'}]), ['呀'])


class CleanupRespectsKeptWordsTests(unittest.TestCase):
    def test_kept_particle_survives_preclean_fillers_and_model_edits(self):
        from edits import apply_plan, preclean
        from filler_selection import candidates
        raw = '这个方案我觉得挺好的呀，我们明天再定。'
        self.assertEqual(preclean(raw)[0], '这个方案我觉得挺好的，我们明天再定。')
        self.assertEqual(preclean(raw, {'keep_words': ['呀']})[0], raw)
        self.assertTrue(candidates('就是我们先测试，然后上线。'))
        self.assertFalse(any(r['old'] == '就是' for r in candidates('就是我们先测试，然后上线。', keep=('就是',))))
        plan = {'repairs': [], 'edits': [{'old': '的呀', 'new': '的', 'kind': 'filler'}], 'breaks': [], 'bullets': []}
        text, meta = apply_plan(raw, plan, {'keep_words': ['呀']})
        self.assertEqual((text, [r['reason'] for r in meta['rejected_edits']]), (raw, ['kept_word']))

    def test_the_eval_contexts_carry_no_habits(self):
        from cleanup_eval import context, load
        self.assertFalse(any(context(case).get('style') or context(case).get('keep_words') for case in load()))


if __name__ == '__main__':
    unittest.main()
