import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from context import normalize_context
from vocabulary import normalize_aliases
from edits import apply_plan,split_units
from engine import fallback_layout

class LayoutAliasTests(unittest.TestCase):
    def test_sentence_per_paragraph_is_rejected(self):
        raw='这个段落需要保留。标题暂时不改。正文稍后再检查。附件准备好了吗？请把说明放在结尾。版本号是多少？文件保存在本机吗？还需要多少空间？'
        plan={'edits':[],'breaks':list(range(len(split_units(raw)))),'bullets':[]}
        self.assertEqual(apply_plan(raw,plan,{})[0],raw)
        self.assertEqual(apply_plan(raw,plan,{'layout_policy':'paragraphs'})[0],raw)
    def test_fake_lists_and_length_based_breaks_are_rejected(self):
        raw='请先分析这个问题。再保留所有细节。最后给出结果。'
        self.assertEqual(apply_plan(raw,{'edits':[],'breaks':[],'bullets':[0,1,2]}, {})[0],raw)
        self.assertEqual(fallback_layout(raw*15),raw*15)
    def test_explicit_list_kept(self):
        raw='第一，保留原意。第二，保留细节。'
        self.assertEqual(apply_plan(raw,{'edits':[],'breaks':[0,1],'bullets':[]},{})[0],'- 第一，保留原意。\n- 第二，保留细节。')
    def test_previous_correction_is_not_a_replacement_rule(self):
        ctx=normalize_context({'personal_terms':['星河知识库'],'personal_aliases':[{'heard':'星禾知识库','term':'星河知识库'}]})
        raw='打开星禾知识库。保留“星禾知识库”和 `星禾知识库`。'
        self.assertEqual(normalize_aliases(raw,ctx),(raw,0))
        self.assertEqual(normalize_aliases('没有这个词。',ctx),('没有这个词。',0))
    def test_unconfirmed_removed_and_numeric_aliases_are_ignored(self):
        ctx=normalize_context({'personal_terms':['SFT','版本13'],'personal_aliases':[{'heard':'星禾知识库','term':'星河知识库'},{'heard':'版本12','term':'版本13'}]})
        self.assertEqual(ctx['personal_aliases'],[])
    def test_aliases_do_not_chain_or_replace_inside_english_word(self):
        ctx=normalize_context({'personal_terms':['SFT','STT'],'personal_aliases':[{'heard':'SFY','term':'SFT'},{'heard':'SFT','term':'STT'}]})
        self.assertEqual(normalize_aliases('SFY 和 SFYmodel。',ctx)[0],'SFY 和 SFYmodel。')
    def test_valid_words_survive_learned_homophones_in_pipeline(self):
        from engine import Editor
        editor=Editor.__new__(Editor)
        for raw,heard,term in [('Please get the file.','get','git'),('这件服装很好看。','服装','浮窗')]:
            ctx=normalize_context({'initial':term,'personal_terms':[term],'personal_aliases':[{'heard':heard,'term':term}]})
            text,meta=editor.edit(raw,ctx,policy='fast')
            self.assertEqual(text,raw)
            self.assertEqual(meta['confirmed_corrections'],0)
    def test_learned_alias_applies_when_utterance_is_unambiguous(self):
        # The correction the user taught should take effect. Refusing every
        # learned pair dropped the fix the user asked for.
        ctx=normalize_context({'personal_terms':['星河知识库'],'personal_aliases':[{'heard':'星禾知识库','term':'星河知识库'}]})
        plan={'edits':[{'old':'星禾知识库','new':'星河知识库','kind':'spelling'}],'breaks':[],'bullets':[]}
        text,meta=apply_plan('打开星禾知识库查一下。',plan,ctx)
        self.assertEqual(text,'打开星河知识库查一下。')
        self.assertEqual(meta.get('rejected_edits',[]),[])
        # The learned pair reaches the model as context rather than being absent.
        from vocabulary import spelling_hints
        self.assertIn(['星禾知识库','星河知识库'],spelling_hints('打开星禾知识库查一下。',ctx))

    def test_model_cannot_force_a_previous_correction(self):
        ctx=normalize_context({'personal_terms':['浮窗'],'personal_aliases':[{'heard':'服装','term':'浮窗'}]})
        raw='这件服装挺合适，浮窗的样式之后再讨论。'
        plan={'edits':[{'old':'这件服装挺合适','new':'这件浮窗挺合适','kind':'spelling'}],'breaks':[],'bullets':[]}
        text,meta=apply_plan(raw,plan,ctx)
        self.assertEqual(text,raw)
        self.assertEqual(meta['rejected_edits'][0]['reason'],'learned_alias_requires_audio')
        raw='修改服装。不对，我是说浮窗。'
        plan={'repairs':[{'old':'服装','new':'浮窗','cue':'不对，我是说浮窗。'}],'edits':[],'breaks':[],'bullets':[]}
        self.assertEqual(apply_plan(raw,plan,ctx)[0],'修改浮窗。')


    def test_asr_and_cleanup_lessons_are_used_differently(self):
        from vocabulary import hotwords, spelling_hints, cleanup_guards
        ctx=normalize_context({'personal_terms':['A1','A2','星河知识库','发布'],'personal_aliases':[
            {'heard':'星禾知识库','term':'星河知识库','stage':'asr','count':3},
            {'heard':'上线','term':'发布','stage':'cleanup','count':1}]})
        # A recognizer mishearing earns a hotword slot ahead of unrelated vocabulary.
        self.assertEqual(hotwords(ctx)[0],'星河知识库')
        self.assertIn(['星禾知识库','星河知识库'],spelling_hints('打开星禾知识库。',ctx))
        # An editor rewrite the user reverted is never a spelling hint ...
        self.assertNotIn(['上线','发布'],spelling_hints('周三上线。',ctx))
        # ... it is a constraint, and the same rewrite is refused.
        self.assertEqual(cleanup_guards('周三发布。',ctx),[['发布','上线']])
        plan={'edits':[{'old':'周三发布','new':'周三上线','kind':'spelling'}],'breaks':[],'bullets':[]}
        text,meta=apply_plan('周三发布。',plan,ctx)
        self.assertEqual(text,'周三发布。')
        self.assertEqual(meta['rejected_edits'][0]['reason'],'reverted_by_user')

    def test_old_alias_files_still_load(self):
        ctx=normalize_context({'personal_terms':['星河知识库'],'personal_aliases':[{'heard':'星禾知识库','term':'星河知识库'}]})
        self.assertEqual(ctx['personal_aliases'],[{'heard':'星禾知识库','term':'星河知识库','stage':'asr','count':1}])

if __name__=='__main__':unittest.main()
