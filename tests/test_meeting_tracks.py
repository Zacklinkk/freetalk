"""Two-track meetings: sound regions, track labels and echo removal (python/meeting_tracks.py)."""
import json
import sys
import tempfile
import unittest
from importlib.util import find_spec
from pathlib import Path
from types import ModuleType, SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))

from meeting_tracks import LOCAL, REMOTE, label_turns, merge, own_turns, regions, speech_windows, strip_bleed, track_turns


def row(start, end, text, speaker):
    return {'start': start, 'end': end, 'text': text, 'speaker_ids': [speaker], 'speaker_status': 'track'}


class RegionTests(unittest.TestCase):
    def test_speech_regions_skip_silence_and_keep_short_pauses(self):
        # 30 ms frames: 0.3 s silence, 0.6 s speech, 0.3 s pause, 0.15 s speech, 3 s silence.
        levels = [0] * 10 + [.05] * 20 + [0] * 10 + [.05] * 5 + [0] * 100
        spans = regions(levels, LOCAL)
        self.assertEqual(len(spans), 1)
        self.assertAlmostEqual(spans[0]['start'], .05)
        self.assertAlmostEqual(spans[0]['end'], 1.6)
        self.assertEqual(spans[0]['speaker'], LOCAL)

    def test_threshold_follows_the_noise_floor_but_keeps_soft_speech(self):
        noisy = [.004] * 50 + [.009] * 30 + [.004] * 50
        self.assertEqual(len(regions(noisy, LOCAL)), 1)
        self.assertEqual(regions([0] * 100, REMOTE), [])
        self.assertEqual(regions([], REMOTE), [])
        # A click shorter than 0.3 s is not speech.
        self.assertEqual(regions([0] * 50 + [.2] * 3 + [0] * 50, LOCAL), [])

    def test_remote_speakers_are_numbered_by_first_turn(self):
        turns = [{'start': 5, 'end': 6, 'speaker': 'speaker_3'}, {'start': 1, 'end': 2, 'speaker': 'speaker_1'}]
        self.assertEqual([t['speaker'] for t in label_turns(turns, REMOTE)], ['远端2', '远端1'])
        self.assertEqual([t['speaker'] for t in label_turns(turns[:1], REMOTE)], ['远端'])


class WindowTests(unittest.TestCase):
    def turn(self, start, end, speaker=LOCAL):
        return {'start': start, 'end': end, 'speaker': speaker}

    def test_windows_cover_speech_only_and_cut_at_speaker_changes(self):
        turns = [self.turn(0, 2), self.turn(2.5, 4), self.turn(10, 12), self.turn(12.2, 14, '远端2')]
        self.assertEqual(list(speech_windows(turns)), [(0, 4, [LOCAL]), (10, 12, [LOCAL]), (12.2, 14, ['远端2'])])

    def test_overlapping_turns_share_one_window_and_long_turns_split(self):
        self.assertEqual(list(speech_windows([self.turn(0, 3, '远端1'), self.turn(2, 5, '远端2')])), [(0, 5, ['远端1', '远端2'])])
        self.assertEqual(list(speech_windows([self.turn(0, 30)])), [(0, 15, [LOCAL]), (15, 30, [LOCAL])])
        # A turn that overlaps a full window starts where that window ends; nothing is heard twice.
        windows = list(speech_windows([self.turn(0, 20), self.turn(19, 25)]))
        self.assertEqual(windows, [(0, 20, [LOCAL]), (20, 25, [LOCAL])])

    def test_the_echo_of_the_speakers_is_not_the_other_side(self):
        system = [self.turn(0, 3, REMOTE), self.turn(3.3, 6, REMOTE)]
        mic = [self.turn(.05, 3.05, '本机1'), self.turn(3.35, 6.05, '本机1'), self.turn(7, 9, '本机2')]
        self.assertEqual(own_turns(mic, system), [mic[2]])
        # Without the echo the remote sentence stays one window.
        self.assertEqual(list(speech_windows(system, other=own_turns(mic, system))), [(0, 6, [REMOTE])])
        self.assertEqual(len(list(speech_windows(system, other=mic))), 2)

    def test_speaker_model_turns_keep_sound_it_missed(self):
        levels = [0] * 10 + [.05] * 20 + [0] * 100 + [.05] * 20 + [0] * 10
        turns = track_turns(levels, REMOTE, [{'start': .3, 'end': .9, 'speaker': 'speaker_2'}])
        self.assertEqual([t['speaker'] for t in turns], [REMOTE, REMOTE])
        self.assertEqual(round(turns[1]['start'], 2), 3.65)


class BleedTests(unittest.TestCase):
    system = [row(0, 10, '我们下周三之前把评测报告发出来，然后再安排复盘会议。', REMOTE)]

    def test_the_microphone_echo_of_the_speakers_is_removed(self):
        mic = row(1, 11, '我们下周三之前把评测报告发出来，然后在安排复盘会议。好的，我这边没问题，我来写报告。', LOCAL)
        self.assertEqual(strip_bleed(mic, self.system), ('好的，我这边没问题，我来写报告。', 2))

    def test_a_short_clause_goes_with_the_echo_next_to_it(self):
        system = [row(0, 6, '另外，记得把新加的样本也放进测试集，别漏了。', REMOTE)]
        self.assertEqual(strip_bleed(row(0, 6, '另外，记得把新加的样本也放进测试集，别漏了。', LOCAL), system), ('', 3))
        # Said on this side: not in the system track, or not next to an echo.
        self.assertEqual(strip_bleed(row(0, 6, '对，记得把新加的样本也放进测试集。', LOCAL), system), ('对', 1))
        self.assertEqual(strip_bleed(row(0, 6, '另外，我下午有空。', LOCAL), system), ('另外，我下午有空。', 0))

    @unittest.skipUnless(find_spec('pypinyin'), 'needs pypinyin')
    def test_an_echo_heard_as_homophones_is_removed(self):
        system = [row(0, 6, '另外记得把新加的样本也放进测试集，别漏了。', REMOTE)]
        self.assertEqual(strip_bleed(row(5, 6, '别露了。', LOCAL), system), ('', 1))
        # Same sounds said later, or different sounds now, stay.
        self.assertEqual(strip_bleed(row(30, 31, '别露了。', LOCAL), system)[1], 0)
        self.assertEqual(strip_bleed(row(5, 6, '我也看过了。', LOCAL), system)[1], 0)

    def test_own_speech_and_later_repeats_stay(self):
        for mic in [row(1, 11, '我觉得这个方案可以，我们先试一下。', LOCAL),
                    row(30, 40, '我们下周三之前把评测报告发出来。', LOCAL)]:
            with self.subTest(text=mic['text']):
                self.assertEqual(strip_bleed(mic, self.system), (mic['text'], 0))

    def test_local_speakers_are_named_after_echo_removal(self):
        mic = [{**row(1, 11, '我们下周三之前把评测报告发出来，然后在安排复盘会议。', '本机1'), 'speaker_turns': [{'start': 1, 'end': 11, 'speaker': '本机1'}]},
               {**row(12, 15, '好的，我来写。', '本机2'), 'speaker_turns': [{'start': 12, 'end': 15, 'speaker': '本机2'}]}]
        merged, _ = merge(mic, self.system)
        self.assertEqual([(r['speaker_ids'], r['speaker_turns'][0]['speaker']) for r in merged if r['speaker_ids'][0].startswith(LOCAL)], [([LOCAL], LOCAL)])
        two = merge([row(12, 13, '好的。', '本机2'), row(14, 15, '我来写。', '本机3')], self.system)[0]
        self.assertEqual([r['speaker_ids'] for r in two if r['speaker_ids'][0].startswith(LOCAL)], [['本机1'], ['本机2']])

    def test_merge_orders_by_time_and_renumbers(self):
        mic = [row(1, 11, '我们下周三之前把评测报告发出来，然后在安排复盘会议。', LOCAL), row(12, 15, '好的，我来写。', LOCAL)]
        system = self.system + [row(11, 14, '那就这么定了。', REMOTE)]
        merged, dropped = merge(mic, system)
        self.assertEqual(dropped, 2)
        self.assertEqual([(r['id'], r['speaker_ids'][0], r['text']) for r in merged],
                         [('s000001', REMOTE, self.system[0]['text']), ('s000002', REMOTE, '那就这么定了。'), ('s000003', LOCAL, '好的，我来写。')])


@unittest.skipUnless(find_spec('numpy') and find_spec('soundfile'), 'needs numpy and soundfile (the app runtime)')
class PipelineTests(unittest.TestCase):
    """transcribe_tracks with a fake recognizer: each tone stands for one sentence.

    mlx is stubbed, so later tests still see it unloaded (test_meetings checks that).
    """
    def setUp(self):
        core = ModuleType('mlx.core'); core.synchronize = lambda: None
        package = ModuleType('mlx'); package.core = core
        # Only these two entries: restoring all of sys.modules would unload numpy,
        # which cannot be imported twice in one process.
        saved = {name: sys.modules.get(name) for name in ('mlx', 'mlx.core')}
        sys.modules.update({'mlx': package, 'mlx.core': core})
        def restore():
            for name, module in saved.items():
                if module is None: sys.modules.pop(name, None)
                else: sys.modules[name] = module
        self.addCleanup(restore)

    SENTENCES = {300: '本机第一句话说完了。', 500: '远端说的这一句会漏进麦克风。', 700: '本机第二句话也说完了。', 900: '远端最后补充一句。'}

    @staticmethod
    def tone(np, hz, seconds, level=.3):
        t = np.arange(int(seconds * 16000)) / 16000
        return (level * np.sin(2 * np.pi * hz * t)).astype(np.float32)

    def recognizer(self, np, calls):
        def generate(samples, **_):
            calls.append(len(samples))
            said, last = [], None
            for frame in np.array_split(samples, max(1, len(samples) // 1600)):
                if np.sqrt(np.mean(frame ** 2)) < .01:
                    last = None; continue
                hz = min(self.SENTENCES, key=lambda f: abs(f - np.argmax(np.abs(np.fft.rfft(frame))) * 16000 / len(frame)))
                if hz != last:
                    said.append(self.SENTENCES[hz]); last = hz
            return SimpleNamespace(text=''.join(said))
        return SimpleNamespace(generate=generate)

    def test_two_tracks_are_labelled_interleaved_and_resumable(self):
        import numpy as np
        import soundfile as sf
        from meeting_pipeline import transcribe_tracks
        from meeting_store import MeetingStore
        silence = lambda seconds: np.zeros(int(seconds * 16000), np.float32)
        # Microphone: local 300 Hz, the speakers' 500 Hz leaking in, local 700 Hz.
        mic = np.concatenate([self.tone(np, 300, 2), silence(1.5), self.tone(np, 500, 2, .05), silence(1.5), self.tone(np, 700, 2), silence(4)])
        # The Mac's sound starts 0.5 s later: 500 Hz at the same moment, 900 Hz at the end.
        system = np.concatenate([silence(3), self.tone(np, 500, 2), silence(5), self.tone(np, 900, 2)])
        with tempfile.TemporaryDirectory() as temp:
            store = MeetingStore(temp)
            meeting = store.create('双轨')['id']
            folder = store.directory(meeting)
            sf.write(folder / 'audio.wav', mic, 16000, subtype='PCM_16'); sf.write(folder / 'system.wav', system, 16000, subtype='PCM_16')
            store.update(meeting, system_offset_seconds=.5)
            calls = []
            run = lambda resume: transcribe_tracks(store, meeting, [folder / 'audio.wav', folder / 'system.wav'], [], False, {}, resume,
                                                   lambda: self.recognizer(np, calls), lambda **_: None, {})
            segments, dropped = run(False)
            self.assertEqual([(s['speaker_ids'], s['text']) for s in segments],
                             [([LOCAL], self.SENTENCES[300]), ([REMOTE], self.SENTENCES[500]), ([LOCAL], self.SENTENCES[700]), ([REMOTE], self.SENTENCES[900])])
            self.assertEqual(dropped, 1)
            self.assertAlmostEqual(segments[1]['start'], 3.25, places=2)
            self.assertEqual([s['id'] for s in segments], ['s000001', 's000002', 's000003', 's000004'])
            self.assertEqual([json.loads(l)['text'] for l in (folder / 'transcript.jsonl').read_text().splitlines()], [s['text'] for s in segments])
            # Resuming a finished run transcribes nothing again and merges to the same transcript.
            before = len(calls)
            self.assertEqual(run(True), (segments, dropped))
            self.assertEqual(len(calls), before)


if __name__ == '__main__':
    unittest.main()
