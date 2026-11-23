import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
import personal_learning as learn
from learning_augmentation import checked_plan, parse_gemini, prompt, propose, training_practice
from edits import contextual_layout
from meeting_pipeline import intervals, overlap_duration
from meeting_tracks import window_turns
from numerals import normalize


class PersonalLearningTests(unittest.TestCase):
    def test_only_reviewed_changed_sent_text(self):
        def label(final, inserted='会议改到周三，保留所有日志。'):
            return learn.label(dict(raw=inserted,text=inserted,editedText='没有提交的草稿',reviewedFinal=final))
        self.assertNotEqual(label(None),'accepted')
        self.assertEqual(label('会议改到周三，保留所有日志。'),'未改动')
        self.assertEqual(label('会议改到周四，保留所有日志。'),'accepted')
        self.assertNotEqual(label('改。'),'accepted')
        self.assertNotEqual(label('这个算法运行起来非常快速！'),'accepted')
        self.assertNotEqual(label('会议改到周三，保留所有日志。另外订票。'),'accepted')

    def test_real_edit_plan_can_be_recovered_without_a_loaded_model(self):
        from cleanup_eval import load
        rows=[dict(raw=r['raw'],reviewedFinal=r['gt']) for r in load()]
        examples=learn.training_examples(rows)
        self.assertGreaterEqual(len(examples),8)
        for item in examples:
            self.assertEqual(item['messages'][-1]['role'],'assistant')
            self.assertIsInstance(json.loads(item['messages'][-1]['content']),dict)

    def test_ground_truth_is_forward_split_and_deduplicated(self):
        rows=[dict(raw=raw,createdAt=date,id=str(i)) for i,(raw,date) in enumerate([
            ('内部电话','2026-01-01'),('内部，电话！','2026-01-03'),('另一个样本','2026-01-03')])]
        train,test=learn.split(rows)
        self.assertEqual(([r['id'] for r in train],[r['id'] for r in test]),(['0'],['2']))
        self.assertEqual(learn.quality('统一用SFT','统一使用SFT'),(1,1))
        self.assertEqual(learn.p95(list(range(1,21))),19)

    def test_rollback_is_sticky_and_cloud_timings_do_not_promote(self):
        with tempfile.TemporaryDirectory() as temp:
            s=Path(temp); config={'cleanupModel':str(s)}; key='a'*24
            base=learn.model_key(config)
            report=dict(passed=True,base=base,candidate=[{'real':True}]*20)
            learn.write(learn.candidate_dir(s,key)/'report.json',report)
            (learn.candidate_dir(s,key)/'adapters.safetensors').touch()
            learn.write(s/'learning/latest.json',{'id':key})
            self.assertTrue(learn.activate(s,config))
            hist=[dict(cleanupAdapter=g,modelUsed=True,cleanupEngine='cloud',cleanupBase=base,stopToInputSeconds=1) for g in ('base',key) for _ in range(20)]
            learn.write(s/'history.json',hist)
            self.assertFalse(learn.activate(s,config,automatic=True))
            for row in hist: row['cleanupEngine']='local'
            learn.write(s/'history.json',hist)
            self.assertTrue(learn.activate(s,config,automatic=True))
            learn.write(s/'learning/active.json',{'phase':'rollback'})
            self.assertFalse(learn.activate(s,config,automatic=True))
            (s/'learning/active.json').write_text('oops')
            self.assertIsNone(learn.active_adapter(s,config))

    def test_practice_approval_is_bound_to_the_exact_topic(self):
        with tempfile.TemporaryDirectory() as temp:
            s=Path(temp)
            for i in range(3):
                r=dict(id=str(i),createdAt=f'2026-01-0{i+1}',raw=f'实际私人原话{i}',text='周三交付所有日志',reviewedFinal='周四交付所有日志')
                learn.write(s/'learning/samples'/str(i)/'record.json',r)
            key=propose(s,'英文缩写','SFT', '0',4)
            folder,plan=checked_plan(s/'learning/practice',key)
            self.assertNotIn('实际私人原话',prompt(plan))
            self.assertFalse((folder/'approved.json').exists())
            with self.assertRaises(ValueError): propose(s,'英文缩写','SFT','2',4)
            plan['count']=12;learn.write(folder/'proposal.json',plan)
            with self.assertRaises(ValueError): checked_plan(s/'learning/practice',key)
            with self.assertRaises(ValueError): parse_gemini(json.dumps({'type':'result','is_error':False,'modelUsage':{'engine':{}},'result':'[]'}),0)

    def test_practice_is_capped_and_cannot_leak_into_holdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            s=Path(tmp);folder=s/'learning/practice'/'test'/'synthetic'
            train=[dict(id=str(i),raw=f'原音{i}',reviewedFinal=f'原稿{i}') for i in range(8)]
            held=[dict(id='other',raw='单独留着验收',reviewedFinal='永远保留这句话')]
            for i,(purpose,target) in enumerate([('challenge','考题'),('train','永远保留这句话'),('train','允许一'),('train','允许二'),('train','允许三')]):
                base=f'clip-{i:02}';audio=base+'-16k.wav'
                learn.write(folder/(base+'-review.json'),dict(id=base,source='0',synthetic=True,
                    raw=f'练习口述{i}',reviewedFinal=target,purpose=purpose,audio=audio))
                (folder/audio).touch()
            rows=training_practice(s,train,held)
            self.assertEqual([r['reviewedFinal'] for r in rows],['允许一','允许二'])
            self.assertTrue(all(r['synthetic'] for r in rows))

    def test_optional_layout_and_comparison_operand(self):
        raw='这次先把采购的材料列一个表给我看看。供应商具体来自哪里？每种规格分别花多少钱？'
        self.assertEqual(contextual_layout(raw,'minimal'),raw)
        self.assertIn('\n2. 每种规格',contextual_layout(raw,'paragraphs'))
        prose='你明天方便吗？能帮我看一下吗？回家的时候你还需要我带什么东西吗？'
        self.assertEqual(contextual_layout(prose,'paragraphs'),prose)
        self.assertEqual(normalize('得分小于K三的模型，统一再跑一遍。')[0],'得分小于K3的模型，统一再跑一遍。')

    def test_sweep_handles_nested_and_equal_boundaries(self):
        turns=[dict(start=a,end=b,speaker=s) for a,b,s in [(0,15,'A'),(1,2,'A'),(2,5,'B'),(6,8,'C')]]
        self.assertEqual(overlap_duration(turns),5)
        windows=list(intervals(14400,turns))
        self.assertEqual((windows[0][0],windows[-1][1]),(0,14400))
        self.assertLessEqual(max(b-a for a,b,_ in windows),20.000001)
        nearby=[len(x) for _,x in window_turns([(0,10),(1,3),(13,16),(20,21)],turns)]
        self.assertEqual(nearby,[4,3,1,0])
