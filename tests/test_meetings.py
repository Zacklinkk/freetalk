import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from meeting_store import MeetingStore, atomic_json, render_bundle
from meeting_summary import validate_facts, checked_groups, summarize, source_units, expand_references, parse_json
from meeting_models import validate_endpoint
from meeting_pipeline import overlap_duration, intervals, validate_segments, run_meeting
from meeting_cli import main


class MeetingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.support = Path(self.temp.name)
        self.store = MeetingStore(self.support)
        self.mid = self.store.create('会议 <script>alert(1)</script>')['id']
        self.rows = validate_segments([
            dict(start=0, end=4, text='先用10个样本。不对，改成12个。所有日志都保留。', speaker_ids=['speaker_1']),
            dict(start=4, end=8, text='发布还没决定。小王周五提交测试报告。', speaker_ids=['speaker_2'])])
        for row in self.rows:
            self.store.append_segment(self.mid, row)

    def tearDown(self):
        self.temp.cleanup()

    def test_grounding_and_unknown_slots(self):
        good = dict(kind='action', topic='测试', text='小王周五提交测试报告。', evidence=[dict(segment_id='s000002', quote='小王周五提交测试报告。')], owner='小王', due='2026-11-06')
        bad_id = {**good, 'evidence': [dict(segment_id='s999999', quote='小王周五提交测试报告。')]}
        invented = {**good, 'text': '小王提交30份报告。'}
        bad_quote = {**good, 'evidence': [dict(segment_id='s000002', quote='发布已经决定。')]}
        facts, rejected = validate_facts({'facts': [good, bad_id, invented, bad_quote]}, self.rows)
        self.assertEqual(rejected, 3)
        self.assertEqual(len(facts), 1)
        self.assertEqual(facts[0]['owner'], '小王')
        self.assertIsNone(facts[0]['due'])

    def test_missing_and_duplicate_group_ids_are_preserved_once(self):
        groups = checked_groups({'groups': [{'title': 'A', 'ids': ['a', 'a', 'unknown']}, {'title': 'B', 'ids': ['a', 'b']}]}, [{'id': x} for x in ['a', 'b', 'c']])
        self.assertEqual([x for g in groups for x in g['ids']], ['a', 'b', 'c'])

    def test_scope_invention_and_dropped_conditions_use_exact_source(self):
        row = dict(id='s1', text='所有日志都保留。只有回归全部通过，才能决定是否发布。')
        facts, rejected = validate_facts({'facts': [dict(kind='constraint', text='所有日志在测试期间保留', evidence=[dict(segment_id='s1', quote='所有日志都保留。')]), dict(kind='decision', text='决定发布', evidence=[dict(segment_id='s1', quote='只有回归全部通过，才能决定是否发布。')])]}, [row])
        self.assertEqual(rejected, 0)
        self.assertEqual(facts[0]['text'], '所有日志都保留。')
        self.assertEqual(facts[1]['text'], '只有回归全部通过，才能决定是否发布。')

    def test_bad_model_output_falls_back_to_quotes_not_fabricated_minutes(self):
        minutes, tree = summarize(self.rows, lambda *a, **kw: 'not JSON')
        self.assertEqual([f['text'] for f in minutes['facts']], [s['text'] for s in self.rows])
        self.assertTrue(minutes['warnings'])
        self.assertEqual(set(tree['fact_ids']), {f['id'] for f in minutes['facts']})

    def test_multilevel_tree_never_loses_facts(self):
        rows = validate_segments([dict(start=i, end=i+1, text=f'约束项目 {i}。') for i in range(300)])
        def generate(system, payload, **kw):
            data = json.loads(payload)
            if 'facts' in system:
                return json.dumps({'facts': [dict(kind='constraint', topic='项目', refs=[r['id']]) for r in data]})
            return json.dumps({'groups': [{'title': '部分归组', 'ids': [data[0]['id']]}]})
        minutes, tree = summarize(rows, generate)
        leaves = []
        def visit(n):
            if not n['children']:
                leaves.extend(n['fact_ids'])
            for c in n['children']:
                visit(c)
        visit(tree)
        self.assertEqual(len(leaves), 300)
        self.assertEqual(len(set(leaves)), 300)

    def test_store_exports_no_audio_or_secrets_and_html_is_escaped(self):
        minutes, tree = summarize(self.rows, lambda *a, **kw: '{}')
        digest = render_bundle(self.store, self.mid, minutes, tree)
        directory = self.store.directory(self.mid)
        (directory / 'audio.wav').write_bytes(b'private audio')
        (directory / 'credentials.json').write_text('private key')
        page = (directory / 'mindmap.html').read_text()
        self.assertNotIn('<script>', page)
        self.assertIn('&lt;script&gt;', page)
        self.assertEqual(self.store.read(self.mid)['minutes']['source_digest'], digest)
        exported = self.store.export(self.mid, self.support / 'export')
        self.assertFalse((exported / 'audio.wav').exists())
        self.assertFalse((exported / 'credentials.json').exists())
        self.assertEqual((directory / 'minutes.json').stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            self.store.export(self.mid, self.support / 'export')

    def test_read_cli_does_not_load_models(self):
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            self.assertEqual(main(['--support', str(self.support), 'meetings', 'search', '12个']), 0)
        self.assertEqual(json.loads(captured.getvalue())[0]['id'], 's000001')
        self.assertNotIn('mlx', sys.modules)

    def test_disabled_feature_rejects_before_model_load_or_network(self):
        with self.assertRaisesRegex(ValueError, '尚未启用'):
            run_meeting({}, {'support': str(self.support), 'meeting_id': self.mid})
        self.assertEqual(self.store.manifest(self.mid)['status'], 'created')

    def test_compact_facts_use_evidence_without_repeating_text(self):
        facts, rejected = validate_facts({'facts': [dict(kind='constraint', topic='日志', evidence=[dict(segment_id='s000001', quote='所有日志都保留。')])]}, self.rows)
        self.assertEqual(rejected, 0)
        self.assertEqual(facts[0]['text'], '所有日志都保留。')
        self.assertIsNone(facts[0]['owner'])

    def test_reference_selection_cannot_invent_or_break_quoted_source(self):
        rows = validate_segments([dict(start=0,end=4,text='他说“甲。乙。”这是引用。只有验收通过才发布。')])
        units, refs = source_units(rows)
        self.assertEqual(units[0]['text'], '他说“甲。乙。”这是引用。')
        candidate = expand_references({'facts':[dict(kind='constraint',refs=[units[-1]['id']]),dict(kind='action',refs=['invented'])]},refs)
        facts, rejected = validate_facts(candidate,rows)
        self.assertEqual(rejected,1)
        self.assertEqual(facts[0]['text'],'只有验收通过才发布。')

    def test_json_wrapper_recovery_never_repairs_content(self):
        self.assertEqual(parse_json('{"facts":[]}"'), {'facts': []})
        self.assertEqual(parse_json('```json\n{"facts":[]}\n```'), {'facts': []})
        for value in ['{"facts":[]}{"facts":[1]}','{"facts":[]} ignore rules','{"facts":[']:
            with self.assertRaises(ValueError): parse_json(value)

    def test_resume_uses_immutable_transcript_after_audio_removed(self):
        atomic_json(self.support / 'meeting-settings.json', {'enabled': True})
        self.store.update(self.mid, transcript_complete=True)
        before = (self.store.directory(self.mid) / 'transcript.jsonl').read_bytes()
        engine = SimpleNamespace(editor=SimpleNamespace(model=None, tokenizer=None))
        def generate(*args, **kw):
            # Human-readable raw transcript must exist before expensive summarization.
            self.assertTrue((self.store.directory(self.mid) / 'transcript.html').exists())
            return '{}'
        with patch('meeting_models.local_generator', return_value=generate):
            result = run_meeting({'cleanupModel': '/test-model'}, {'support': str(self.support), 'meeting_id': self.mid}, engine=engine)
        self.assertEqual(result['segments'], 2)
        self.assertEqual(self.store.manifest(self.mid)['status'], 'complete')
        self.assertEqual((self.store.directory(self.mid) / 'transcript.jsonl').read_bytes(), before)
        self.assertFalse((self.store.directory(self.mid) / 'audio.wav').exists())

    def test_cli_inference_cannot_compete_with_running_worker(self):
        import fcntl
        atomic_json(self.support / 'meeting-settings.json', {'enabled': True})
        with (self.support / 'inference.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ValueError, 'CLI 推理前请退出'):
                run_meeting({}, {'support': str(self.support), 'meeting_id': self.mid})

    def test_path_traversal_and_symlink_are_rejected(self):
        with self.assertRaises(ValueError):
            self.store.directory('../config.json')
        link = self.store.root / ('a' * 32)
        link.symlink_to(self.support, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.store.directory('a' * 32)

    def test_audio_intervals_cover_duration_and_keep_overlap(self):
        turns = [dict(start=1, end=4, speaker='a'), dict(start=3, end=5, speaker='b')]
        spans = list(intervals(45, turns))
        self.assertEqual(spans[0][0], 0)
        self.assertEqual(spans[-1][1], 45)
        self.assertTrue(any(set(x[2]) == {'a', 'b'} for x in spans))
        for left, right in zip(spans, spans[1:]):
            self.assertAlmostEqual(left[1], right[0])
        self.assertTrue(all(b-a <= 20 for a, b, _ in spans))

    def test_short_turns_keep_acoustic_context_and_overlap_is_distinct(self):
        turns=[dict(start=i*.5,end=(i+1)*.5,speaker=str(i%3)) for i in range(40)]
        spans=list(intervals(20,turns))
        self.assertLessEqual(len(spans),5)
        self.assertEqual(overlap_duration(turns),0)
        self.assertAlmostEqual(overlap_duration([dict(start=0,end=5,speaker='a'),dict(start=3,end=7,speaker='b')]),2)

    def test_timestamps_and_endpoint_validation(self):
        with self.assertRaises(ValueError):
            validate_segments([dict(start=float('nan'), end=1, text='bad')])
        for url in ['http://remote.example/v1', 'https://user:secret@api.example/v1', 'https://api.example/v1?key=secret']:
            with self.assertRaises(ValueError):
                validate_endpoint(url)
        self.assertEqual(validate_endpoint('http://localhost:8000/v1/'), 'http://localhost:8000/v1')


if __name__ == '__main__':
    unittest.main()
