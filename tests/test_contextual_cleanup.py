import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from disfluency import inspect
from edits import apply_plan,grounded_spelling,preclean
from context import normalize_context
from numerals import normalize
from vocabulary import spelling_hints
class ContextualCleanupTests(unittest.TestCase):
 def test_model_routes_beyond_120_character_threshold(self):
  self.assertIn('dictation_review',inspect('我们来讨论文档导出的方案。先检查标题格式，再检查每一段的标点。那个，导出以后要保留原来的排版。然后如果文件超过限制，就给一个明确的提示，让使用者选择其他位置。不要直接覆盖已有文件，也不要自动删除旧的版本。最后显示保存的位置，方便再次打开。'))
  self.assertTrue(inspect('对呀，然后我们继续检查一下。'))
  self.assertEqual(inspect('提交十二个样本。'),[])
 def test_contextual_particles_and_literal_mentions(self):
  for raw,old,new,expected in [('这个操作啊，需要确认。','操作啊','操作','这个操作，需要确认。'),('对，然后继续检查。','对，然后','', '继续检查。'),('“啊”是语气词。','啊','','“啊”是语气词。'),('对呀','','','对呀')]:
   plan={'edits':[{'old':old,'new':new,'kind':'filler'}] if old else [],'breaks':[],'bullets':[]}
   self.assertEqual(apply_plan(raw,plan,{})[0],expected)
 def test_grounded_spelling_not_unbounded_rewriting(self):
  self.assertTrue(grounded_spelling('服装太大了，缩小浮窗。','服装','浮窗',{}))
  self.assertFalse(grounded_spelling('服装太大了。','服装','浮窗',{}))
  self.assertFalse(grounded_spelling('不用改界面。','不用','需要',{'latest':'需要'}))
 def test_personal_terms_reach_numeral_guard(self):
  ctx=normalize_context({'personal_terms':['三六零']})
  self.assertEqual(normalize('三六零行也保留五十条。',ctx['personal_terms'])[0],'三六零行也保留50条。')
 def test_indefinite_one_and_lexical_ordinals_are_not_numbers(self):
  raw='下一步，把窗口改窄一点。第三方遵循第一性原理。'
  self.assertEqual(normalize(raw)[0],raw)
 def test_near_sound_hints_are_source_pairs(self):
  self.assertIn(['星禾','星河'],spelling_hints('打开星禾。',{'terms':[{'term':'星河','source':'personal'}]}))
  self.assertEqual(spelling_hints('买服装。',{}),[])
  self.assertEqual(spelling_hints('然后但是，然后大概。',{}),[])
 def test_chained_repair_retains_last_spoken_value(self):
  raw='改成十个，不对，十二个，不对，十五个。'
  plan={'repairs':[{'old':'十个','new':'十二个','cue':raw},{'old':'十二个','new':'十五个','cue':raw}],'edits':[],'breaks':[],'bullets':[]}
  self.assertEqual(apply_plan(raw,plan,{})[0],'改成十五个。')
 def test_copied_suffix_is_not_duplicated(self):
  plan={'edits':[{'old':'嗯，','new':'可以继续测试。','kind':'filler'}],'breaks':[],'bullets':[]}
  self.assertEqual(apply_plan('嗯，可以继续测试。',plan,{})[0],'可以继续测试。')
 def test_pause_before_content_and_grounded_word_with_shared_suffix(self):
  self.assertEqual(preclean('我觉得可以默认。嗯，可以学习。')[0],'我觉得可以默认。可以学习。')
  raw='界面显示有问题。有没有更好的现实方式？'
  plan={'edits':[{'old':'现实方式','new':'显示方式','kind':'spelling'}],'breaks':[],'bullets':[]}
  self.assertEqual(apply_plan(raw,plan,{})[0],'界面显示有问题。有没有更好的显示方式？')
 def test_model_category_does_not_block_valid_filler_deletion(self):
  raw='用你的那个常用词库。'
  plan={'edits':[{'old':'你的那个常用词库','new':'你的常用词库','kind':'spelling'}],'breaks':[],'bullets':[]}
  self.assertEqual(apply_plan(raw,plan,{})[0],'用你的常用词库。')
if __name__=='__main__':unittest.main()
