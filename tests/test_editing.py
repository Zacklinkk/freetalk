import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from edits import apply_plan, preclean
from engine import guard_edit
from context import normalize_context

class EditingTests(unittest.TestCase):
    def edit(self, raw, old, new, context=None):
        return apply_plan(raw, {'edits':[{'old':old,'new':new}], 'breaks':[], 'bullets':[]}, context or {})[0]

    def test_hesitation(self):
        self.assertEqual(self.edit('呃，我想先测试。','呃，',''), '我想先测试。')
        self.assertEqual(self.edit('嗯，我想先测试。','嗯，',''), '我想先测试。')
        self.assertEqual(self.edit('um, please test it.','um, ',''), 'please test it.')

    def test_fast_cleanup(self):
        self.assertEqual(preclean('呃，我我想先测试一下，可能还没完成。')[0], '我想先测试一下，可能还没完成。')
        for raw in ['嗯，好的。', '啊？', '好吧，你觉得可以吗？', '这个功能非常非常重要。', '保留“我我”这个例子。']:
            self.assertEqual(preclean(raw)[0], raw)

    def test_acknowledgements(self):
        for raw, old, new in [('嗯，好的。','嗯，',''), ('嗯，好的。','嗯，好的','好的'), ('啊？','啊',''), ('很好啊。','啊',''), ('嗯。','嗯。',''), ('这是额度。','额','')]:
            self.assertEqual(self.edit(raw,old,new), raw)

    def test_particles_and_qualifiers(self):
        for word in ['好吧','可能','我觉得','不要','不能','如果','还没','已经','吗','呢','就是','然后','那个']:
            raw = '测试' + word + '这个功能。'
            self.assertEqual(self.edit(raw,word,''), raw)

    def test_repair_keeps_whole_corrected_suffix(self):
        raw='先用十个样本，不对，改成十二个。'
        self.assertEqual(self.edit(raw,'十个样本，不对，改成十二个','十二个'), '先用十二个。')
        raw='先用3条不对用1条但不要删除。'
        self.assertEqual(self.edit(raw,raw,'用1条'),raw)
        raw='我觉得应该是12个。'
        self.assertEqual(self.edit(raw,raw,'12个'),raw)

    def test_stutters_but_not_emphasis(self):
        self.assertEqual(self.edit('我我希望先测试。','我我','我'),'我希望先测试。')
        self.assertEqual(self.edit('前端和前端和调度。','前端和前端和','前端和'),'前端和调度。')
        self.assertEqual(self.edit('非常非常重要。','非常非常','非常'),'非常非常重要。')

    def test_code_quotes_and_english_words(self):
        for raw,old in [('输出“嗯”。','嗯'), ('保留 `um` 变量。','um'), ('the album','um'), ('human voice','hum')]:
            self.assertEqual(self.edit(raw,old,''),raw)

    def test_context_not_a_license_to_invent(self):
        ctx={'terms':[{'term':'DSH'}]}
        self.assertEqual(self.edit('用 d s h。','d s h','DSH',ctx),'用 DSH。')
        self.assertEqual(self.edit('写邮件。','写邮件','DSH',ctx),'写邮件。')

    def test_layout_retains_every_sentence(self):
        raw='第一，保留意思。第二，不删除细节。最后再确认。'
        text,_=apply_plan(raw,{'edits':[],'breaks':[],'bullets':[0,1]}, {})
        self.assertEqual(text,'- 第一，保留意思。\n- 第二，不删除细节。\n最后再确认。')

    def test_numbers_and_conditions(self):
        self.assertEqual(guard_edit('上限90秒，预算15分钟','上限90秒，预算50分钟'),'number_change')
        self.assertEqual(guard_edit('我觉得可能能完成','可能能完成'),'qualifier_removed')

    def test_context_is_bounded_and_grounded(self):
        ctx=normalize_context({'initial':'Typeless 与 Qwen3-ASR，'+'中'*800,'latest':'API 和 LocalVoice。'})
        self.assertEqual(len(ctx['initial']),500)
        self.assertEqual([r['term'] for r in ctx['terms']],['Typeless','Qwen3-ASR','API','LocalVoice'])
        self.assertEqual(normalize_context({})['terms'],[])

if __name__=='__main__': unittest.main()
