import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from filler_selection import candidates,apply_selection
class FillerSelectionTests(unittest.TestCase):
 def test_only_source_ids_can_change_text(self):
  raw='我们会就是先检查。对，然后我们继续测试。'
  rows=candidates(raw);self.assertTrue(rows)
  out,n=apply_selection(raw,rows,{'drop':[r['id'] for r in rows]})
  self.assertEqual(out,'我们会先检查。我们继续测试。');self.assertEqual(n,2)
  with self.assertRaises(ValueError):apply_selection(raw,rows,{'drop':['invented']})
 def test_lexical_quotes_code_and_referents_have_no_candidate(self):
  for raw in ['选择那个文件。','选择那个文件，然后上传。','答案就是这个。','保留“嗯，啊”。','代码 `就是`。','这里的啊是语气词。','啊？']:
   self.assertEqual(candidates(raw),[],raw)
 def test_empty_selection_and_original_offsets(self):
  raw='我们就是要保留条件，然后再运行。';rows=candidates(raw)
  self.assertEqual(apply_selection(raw,rows,{'drop':[]})[0],raw)
  self.assertEqual(apply_selection('修改'+raw,rows,{'drop':[r['id'] for r in rows]})[0],'修改'+raw)
