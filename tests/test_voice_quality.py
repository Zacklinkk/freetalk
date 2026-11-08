import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from numerals import normalize
from edits import preclean, apply_plan, completed_edits
from vocabulary import normalize_spelling
from context import normalize_context

class VoiceQualityTests(unittest.TestCase):
 def test_version_and_spoken_code_scope(self):
  cases={'版本V五点三。':'版本V5.3。','V五点3':'V5.3','型号AB杠CD零幺杠。二三零二。':'型号AB-CD01-2302。','Opus 五有三十道题。':'Opus 5有30道题。'}
  for raw,want in cases.items():
   with self.subTest(raw=raw):self.assertEqual(normalize(raw)[0],want)
  for raw in ['统一规范，同一条规则，下一步。','张三周五有一个想法。','“V五点三”是原文。','型号AB杠CD']:
   want=raw if raw!='型号AB杠CD' else '型号AB-CD'
   self.assertEqual(normalize(raw)[0],want)
 def test_false_stops_do_not_merge_complete_sentences(self):
  self.assertEqual(preclean('我希望的效果是。先跑验证集。')[0],'我希望的效果是先跑验证集。')
  for raw in ['这一版是错误的。不要用。','你认为可以吗？不要直接发布。','他说“我希望的效果是。原样保留。”','我的答案不是。下一题。','保留原文的句号。下一句也保留。']:
   self.assertEqual(preclean(raw)[0],raw)
 def test_partial_stutters_and_meaningful_reduplication(self):
  self.assertEqual(preclean('系统系系统能能不能操操控？')[0],'系统能不能操控？')
  for raw in ['人人都能看看，想想办法。','非常非常重要。','成都都可以，成就就很大。']:
   self.assertEqual(preclean(raw)[0],raw)
 def test_spoken_version_requires_exact_context(self):
  raw='DeepSeek R One和K 一点五，保留“R One”。'
  ctx=normalize_context({'initial':'DeepSeek-R1 K1.5'})
  self.assertEqual(normalize_spelling(raw,ctx)[0],'DeepSeek-R1和K1.5，保留“R One”。')
  self.assertEqual(normalize_spelling('R one和K一点五。',{})[0],'R one和K一点五。')
  self.assertEqual(normalize_spelling('K一点六。',ctx)[0],'K一点六。')
 def test_context_bounded_and_not_injected_into_output(self):
  ctx=normalize_context({'app':'x'*200,'nearby':'SFT '*1000,'window_title':'RL training'})
  self.assertEqual(len(ctx['app']),100);self.assertEqual(len(ctx['nearby']),1800)
  self.assertIn('SFT',[x['term'] for x in ctx['terms']])
  self.assertEqual(preclean('请保留所有原文。',ctx)[0],'请保留所有原文。')

 def test_partial_plan_accepts_only_complete_edit_objects(self):
  plan=completed_edits('{"repairs":[],"edits":[{"old":"对，然后","new":"","kind":"filler"},{"old":"其他')
  self.assertEqual(len(plan['edits']),1)
  self.assertEqual(apply_plan('对，然后继续检查。',plan,{})[0],'继续检查。')
  for partial in ['{"repairs":[{"old":"10",', '{"edits":[{"old":"不要","new":"', 'nonsense {"edits":[]', '{"note":"edits\": [", "missing":']:
   self.assertIsNone(completed_edits(partial))
