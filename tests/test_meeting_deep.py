import json,sys,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from meeting_deep import configured,deepen,render_deep
from meeting_pipeline import run_meeting,validate_segments
from meeting_store import MeetingStore,atomic_json

class DeepTests(unittest.TestCase):
 def test_migration_never_enables_saved_unused_cloud_config(self):
  cfg={'base_url':'https://example.test/v1','model':'fast'}
  self.assertFalse(configured(cfg));self.assertTrue(configured(dict(cfg,summary_mode='cloud')))
  self.assertFalse(configured(dict(cfg,summary_mode='cloud',cloud_enabled=False)))
 def test_citations_numbers_and_html_safety(self):
  facts=[dict(id='f1',evidence=[dict(segment_id='s1',quote='只有通过才发12份。')])]
  response={'sections':[dict(heading='<script>',body='只有通过才发12份。',fact_ids=['f1']),dict(heading='bad',body='发30份',fact_ids=['f1']),dict(heading='bad',body='无引用',fact_ids=['invented'])]}
  result=deepen({'facts':facts,'source_digest':'abc'},lambda *a,**kw:json.dumps(response))
  self.assertEqual(result['rejected_sections'],2);self.assertEqual(result['sections'][0]['fact_ids'],['f1'])
  with tempfile.TemporaryDirectory() as d:
   render_deep(Path(d),result);self.assertNotIn('<script>',(Path(d)/'deep.html').read_text())
 def test_cloud_failure_preserves_local_bundle_and_raw(self):
  with tempfile.TemporaryDirectory() as d:
   store=MeetingStore(d);mid=store.create('test')['id']
   for row in validate_segments([dict(start=0,end=5,text='只有验收通过才发布。')]):store.append_segment(mid,row)
   store.update(mid,transcript_complete=True)
   before=(store.directory(mid)/'transcript.jsonl').read_bytes()
   atomic_json(Path(d)/'meeting-settings.json',dict(enabled=True,cloud_enabled=True,base_url='https://example.test/v1',model='fast'))
   engine=SimpleNamespace(editor=SimpleNamespace(model=None,tokenizer=None))
   with patch('meeting_models.local_generator',return_value=lambda *a,**kw:'{}'),patch('meeting_models.cloud_generator',side_effect=RuntimeError('secret response')):
    run_meeting({'cleanupModel':'local'},dict(support=d,meeting_id=mid),engine=engine)
   bundle=store.read(mid)
   self.assertEqual(bundle['manifest']['status'],'complete');self.assertEqual(bundle['manifest']['deep_status'],'failed')
   self.assertTrue(bundle['minutes']);self.assertIsNone(bundle['deep'])
   self.assertNotIn('secret response',json.dumps(bundle));self.assertEqual((store.directory(mid)/'transcript.jsonl').read_bytes(),before)
 def test_cloud_output_is_separate_and_exported(self):
  with tempfile.TemporaryDirectory() as d:
   store=MeetingStore(d);mid=store.create('test')['id']
   for row in validate_segments([dict(start=0,end=5,text='保留12份报告。')]):store.append_segment(mid,row)
   store.update(mid,transcript_complete=True)
   atomic_json(Path(d)/'meeting-settings.json',dict(enabled=True,cloud_enabled=True,base_url='https://example.test/v1',model='fast'))
   def cloud(system,user,**kw):
    facts=json.loads(user)['facts'];return json.dumps({'sections':[dict(heading='资料',body='保留12份报告。',fact_ids=[facts[0]['id']])]})
   with patch('meeting_models.local_generator',return_value=lambda *a,**kw:'{}'),patch('meeting_models.cloud_generator',return_value=cloud):
    run_meeting({'cleanupModel':'local'},dict(support=d,meeting_id=mid),engine=SimpleNamespace(editor=SimpleNamespace(model=None,tokenizer=None)))
   self.assertEqual(store.read(mid)['manifest']['summary_provider'],'local')
   self.assertTrue(store.read(mid)['deep']);self.assertTrue((store.export(mid,Path(d)/'out')/'deep.md').exists())
   store.update(mid,deep_status='failed')
   self.assertIsNone(store.read(mid)['deep']);self.assertFalse((store.export(mid,Path(d)/'out2')/'deep.md').exists())
