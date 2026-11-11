import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from context import normalize_context
from edits import preclean
from vocabulary import normalize_spelling, spelling_context, hotwords
from engine import Editor

SYNTHETIC_RAW = '这次有240个样例，都都先检查输入格式。随后比较 S F T 与SFT的输出，保留完整日志。'
SYNTHETIC_EXPECTED = '这次有240个样例，都先检查输入格式。随后比较 SFT 与SFT的输出，保留完整日志。'

class VocabularyTests(unittest.TestCase):
    def normalize(self, raw, **context):
        ctx = spelling_context(raw, normalize_context(context))
        return normalize_spelling(raw, ctx)[0]

    def test_same_utterance_spelling_without_any_dictionary(self):
        self.assertEqual(self.normalize('比较 S F T 和SFT。'), '比较 SFT 和SFT。')

    def test_explicit_dictionary_and_context_spellings(self):
        self.assertEqual(self.normalize('测试 s f t。', personal_terms=['SFT']), '测试 SFT。')
        self.assertEqual(self.normalize('用 A P I。', latest='API 的调用'), '用 API。')
        self.assertEqual(self.normalize('用 O p e n A I。', personal_terms=['OpenAI']), '用 OpenAI。')

    def test_unknown_and_partial_acronyms_are_not_guessed(self):
        for text in ['版本 A B C。', '测试 S F X。', '测试 S F T R。', '编号1 2 3。', '测试 S\nF\nT。']:
            self.assertEqual(self.normalize(text, personal_terms=['SFT']), text)

    def test_quotes_code_and_urls_are_literal(self):
        raw='示例“ S F T ”，代码 `S F T`，网址 https://test/SFT。然后用 S F T。'
        self.assertEqual(self.normalize(raw, personal_terms=['SFT']), '示例“ S F T ”，代码 `S F T`，网址 https://test/SFT。然后用 SFT。')

    def test_function_stutters_and_legitimate_repetition(self):
        self.assertEqual(preclean('都都先验证，我们我们也也先检查，就就用这版。')[0], '都先验证，我们也先检查，就用这版。')
        for text in ['成都都测试过，首都都可以，京都都去过。', '这点成就就够了。', '人人都要看看，非常非常重要。', '对对，我知道。', '示例：“都都先跑”。']:
            self.assertEqual(preclean(text)[0], text)

    def test_personal_name_protected_from_stutter_cleanup(self):
        ctx=normalize_context({'personal_terms':['都都']})
        self.assertEqual(preclean('都都先跑步。',ctx)[0],'都都先跑步。')

    def test_personal_terms_are_bounded_and_hotwords_prioritize_context(self):
        ctx=normalize_context({'personal_terms':['SFT', 'sft', '', 7, 'bad\nword'] + ['Token'+str(i) for i in range(250)], 'latest':'Token190 和 API'})
        self.assertLessEqual(len(ctx['terms']),224)
        self.assertEqual([r['term'] for r in ctx['terms']].count('SFT'),1)
        self.assertNotIn('bad\nword',[r['term'] for r in ctx['terms']])
        self.assertLessEqual(len(hotwords(ctx)),48)
        self.assertIn('Token190',hotwords(ctx));self.assertIn('API',hotwords(ctx))

    def test_context_terms_rank_ahead_of_unrelated_vocabulary(self):
        # The backend appends the list to the prompt as plain text, so order is
        # the only weight. A term visible in the context must outrank earlier
        # vocabulary entries that appear nowhere.
        ctx=normalize_context({'personal_terms':['Token0','Token1','Token2','我的密码']})
        ctx.update({'initial':'Token12','latest':'Token13','window_title':'我的密码','nearby':'Token14'})
        ranked=hotwords(ctx)
        self.assertEqual(ranked[0],'我的密码')
        self.assertLess(ranked.index('我的密码'),ranked.index('Token0'))

    def test_latin_context_match_requires_a_word_boundary(self):
        # "API" must not match inside "CAPITAL".
        inside=normalize_context({'personal_terms':['API'],'initial':'CAPITAL 大写'})
        self.assertNotIn('API',[r for r in hotwords(inside) if r in ('CAPITAL',)])
        standalone=normalize_context({'personal_terms':['zzz','API'],'initial':'调用 API 接口'})
        self.assertEqual(hotwords(standalone)[0],'API')

    def test_long_personal_terms_are_hintable(self):
        # A fixed 2-4 character window can never surface a 5-character term.
        from vocabulary import spelling_hints
        ctx=normalize_context({'personal_terms':['星河知识库']})
        self.assertEqual(spelling_hints('打开星禾知识库。',ctx),[['星禾知识库','星河知识库']])
        self.assertEqual(spelling_hints('打开星河知识库。',ctx),[])

    def test_hints_reach_errors_after_the_scan_prefix(self):
        from vocabulary import spelling_hints
        ctx=normalize_context({'personal_terms':['星河知识库']})
        raw='前'*500+'打开星禾知识库。'
        self.assertEqual(spelling_hints(raw,ctx),[['星禾知识库','星河知识库']])

    def test_fast_policy_preserves_sft_cleanup(self):
        editor=Editor.__new__(Editor)
        text,meta=editor.edit(SYNTHETIC_RAW,{},policy='fast')
        self.assertEqual(text,SYNTHETIC_EXPECTED)
        self.assertFalse(meta['model_used'])
        self.assertEqual(meta['preclean_edits'],1)
        self.assertEqual(meta['term_formats'],1)

if __name__=='__main__': unittest.main()
