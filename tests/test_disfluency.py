import sys, unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from disfluency import inspect
from edits import preclean, apply_plan, simple_layout

def repair(raw,old,new,cue):
    return apply_plan(raw,{'repairs':[{'old':old,'new':new,'cue':cue}],'edits':[],'breaks':[],'bullets':[]},{})

class DisfluencyTests(unittest.TestCase):
    def test_repeated_fillers_and_literals(self):
        self.assertEqual(preclean('呃，我我想，呃，先检查，呃，再处理。')[0],'我想，先检查，再处理。')
        self.assertEqual(preclean('示例：“呃，呃，我我”。`um` 和 album。')[0],'示例：“呃，呃，我我”。`um` 和 album。')
    def test_mid_clause_pause_not_acknowledgement(self):
        self.assertEqual(preclean('我们，嗯，先检查。')[0],'我们，先检查。')
        for text in ['嗯。我们先检查。','嗯，好的。','哦，原来如此。','啊？','额度和额外的预算。','这种病叫呃逆。']:
            self.assertEqual(preclean(text)[0],text)
    def test_restarts_not_emphasis(self):
        self.assertEqual(preclean('语语义和模模型，在使用使用教学里。')[0],'语义和模型，在使用教学里。')
        self.assertEqual(preclean('我想先测试一下，我想先测试一下，然后发布。')[0],'我想先测试一下，然后发布。')
        for text in ['我一定要保留，我一定要保留。','非常非常重要。','先测试一下，再测试中文。']:
            self.assertEqual(preclean(text)[0],text)
    def test_cross_sentence_repair(self):
        text,meta=repair('会议九点开始。不对，不对，刚才说错了。会议十点开始。','会议九点开始','会议十点开始','不对，不对，刚才说错了。会议十点开始。')
        self.assertEqual(text,'会议十点开始。');self.assertEqual(meta['repair_count'],1)
    def test_only_corrected_slot_changes(self):
        self.assertEqual(repair('先用十个样本，不对，改成十二个。','十个','十二个','不对，改成十二个。')[0],'先用十二个样本。')
        self.assertEqual(repair('先用十个样本，保留日志。刚才样本数说错了，改成十二个样本。','十个样本','十二个样本','刚才样本数说错了，改成十二个样本。')[0],'先用十二个样本，保留日志。')
    def test_broad_proposal_narrows_without_deleting_reason(self):
        text,_=repair('周一上线。不对，改成周三上线，因为周二还要验收。','周一上线','周三上线','不对，改成周三上线，因为周二还要验收。')
        self.assertEqual(text,'周三上线，因为周二还要验收。')
        text,_=repair('明天九点开会，不对，九点半开会，记得带报告。','明天九点开会','明天九点半开会','明天九点开会，不对，九点半开会，记得带报告。')
        self.assertEqual(text,'明天九点半开会，记得带报告。')
    def test_no_repair_without_literal_evidence(self):
        raw='周一上线。刚才说错了。'
        self.assertEqual(repair(raw,'周一','周三','刚才说错了。')[0],raw)
        raw='周一上线。用户会说：“不对，周三上线。”'
        self.assertEqual(repair(raw,'周一上线','周三上线','不对，周三上线。')[0],raw)
    def test_repair_preserves_constraints(self):
        raw='如果测试通过，就部署到线上。不对，部署到预发。不要删除日志。'
        self.assertEqual(repair(raw,'部署到线上','部署到预发','不对，部署到预发。')[0],'如果测试通过，就部署到预发。不要删除日志。')
        self.assertEqual(repair(raw,'如果测试通过，就部署到线上','部署到预发','不对，部署到预发。')[0],raw)
    def test_duplicate_source_does_not_guess(self):
        raw='第一组十个样本。第二组十个样本。不对，十二个样本。'
        self.assertEqual(repair(raw,'十个样本','十二个样本','不对，十二个样本。')[0],raw)
    def test_literal_punctuation_survives_other_repair(self):
        raw='保留“。。。”。周一上线。不对，周三上线。'
        self.assertEqual(repair(raw,'周一上线','周三上线','不对，周三上线。')[0],'保留“。。。”。周三上线。')
    def test_triage_is_not_semantic_deletion(self):
        self.assertIn('self_correction',inspect('九点开会。不对，十点开会。'))
        for text in ['用户会说：“不对，刚才说错了。”','如果用户说不对，就处理。','这个结果不对，需要检查。']:
            self.assertNotIn('self_correction',inspect(text))
        self.assertIn('possible_repeat',inspect('第一组用十个样本，第二组用十二个样本。'))
    def test_repeated_predicate_and_unit_are_grounded(self):
        raw='我们联系李明。不对，刚才名字说错了，联系李敏。记得附说明。'
        self.assertEqual(repair(raw,'李明','李敏','不对，刚才名字说错了，联系李敏。')[0],'我们联系李敏。记得附说明。')
        raw='预算是1500元。不对，预算是1800元。包含运费。'
        self.assertEqual(repair(raw,'1500','1800','不对，预算是1800元。')[0],'预算是1800元。包含运费。')
    def test_new_predicate_cannot_be_silently_swallowed(self):
        raw='联系小王。不对，暂缓联系小李。'
        self.assertEqual(repair(raw,'小王','小李','不对，暂缓联系小李。')[0],raw)
    def test_quoted_lists_are_not_split(self):
        raw='示例：“第一，保存。第二，校验。”'
        self.assertEqual(simple_layout(raw),raw)
    def test_unrelated_cue_does_not_disable_number_guard(self):
        from engine import guard_edit
        self.assertEqual(guard_edit('不对，预算是100，保留12个样本。','不对，预算是100，保留99个样本。'),'number_change')
    def test_intro_colon_list_is_structured(self):
        raw='我想测试：第一，保留原意；第二，不要删掉细节。好吧，你觉得可以吗？'
        self.assertEqual(simple_layout(raw),'我想测试：\n- 第一，保留原意；\n- 第二，不要删掉细节。\n好吧，你觉得可以吗？')

    def test_clear_parallel_layout(self):
        self.assertEqual(simple_layout('第一，保留原意。第二，保留细节。好吗？'),'- 第一，保留原意。\n- 第二，保留细节。\n好吗？')

    def test_number_only_broad_model_plan_keeps_original_noun(self):
        raw='先保留十个测试样本。不对，刚才说错了。改成十二个样本。不要删掉日志。'
        text,meta=repair(raw,'先保留十个测试样本','先保留十二个测试样本','不对，刚才说错了。改成十二个样本。')
        self.assertEqual(text,'先保留十二个测试样本。不要删掉日志。')
        self.assertEqual(meta['repair_count'],1)
    def test_elliptical_quantity_keeps_noun_and_following_instruction(self):
        cases = [
            ('先用十个样本。不对，改成十二个，保留所有日志。', '十个样本', '十二个，保留所有日志', '不对，改成十二个，保留所有日志。', '先用十二个样本，保留所有日志。'),
            ('复制五份会议记录。不对，改成六份，别覆盖原件。', '五份会议记录', '六份，别覆盖原件', '不对，改成六份，别覆盖原件。', '复制六份会议记录，别覆盖原件。'),
            ('保留3个低风险样本。不对，改成4个。', '3个低风险样本', '4个', '不对，改成4个。', '保留4个低风险样本。'),
        ]
        for raw, old, new, cue, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(repair(raw, old, new, cue)[0], expected)
    def test_explicit_new_noun_is_not_changed_back(self):
        raw = '先用十个样本。不对，改成十二个文件。'
        self.assertEqual(repair(raw, '十个样本', '十二个文件', '不对，改成十二个文件。')[0], '先用十二个文件。')
    def test_numeric_narrowing_rejects_changed_objects_or_polarity(self):
        for suffix,spoken in [('个测试样本','条日志'),('个低风险样本','个风险样本'),('个测试样本','个生产样本')]:
            raw='保留十'+suffix+'。不对，十二'+spoken+'。'
            self.assertEqual(repair(raw,'保留十'+suffix,'保留十二'+suffix,'不对，十二'+spoken+'。')[0],raw)
    def test_explicit_list_does_not_turn_every_sentence_into_a_bullet(self):
        raw='先说明背景。第1，保存草稿。第2，保留细节。最后再确认。'
        text,_=apply_plan(raw,{'edits':[],'breaks':[],'bullets':[0,1,2,3]}, {})
        self.assertEqual(text,'先说明背景。\n- 第1，保存草稿。\n- 第2，保留细节。\n最后再确认。')

if __name__=='__main__':unittest.main()
