"""Where streaming dictation is cut into ASR segments (Engine.push), for loud and quiet speech."""
import sys
import unittest
from importlib.util import find_spec
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))


@unittest.skipUnless(find_spec('numpy'), 'needs numpy (the app runtime)')
class SegmentationTests(unittest.TestCase):
    def cuts(self, amplitude):
        """Seconds where 14 s of speech at `amplitude` is cut; the pause is 9.4–10.2 s."""
        import numpy as np
        from engine import Engine
        engine = Engine.__new__(Engine)
        engine.config, engine.emit = {}, lambda event: None
        engine.reset({})
        engine.transcribe = lambda audio, offset: ('', 0.0)
        t = np.arange(14 * 16000) / 16000
        audio = amplitude * np.sin(2 * np.pi * 220 * t) * (1 + .5 * np.sin(2 * np.pi * 3 * t))
        audio[int(9.4 * 16000):int(10.2 * 16000)] = 0
        pcm = (audio * 32767).astype('<i2').tobytes()
        for start in range(0, len(pcm), 32000):   # one-second chunks, as the recorder sends them
            engine.push(pcm[start:start + 32000])
        return [s['end_sample'] / 16000 for s in engine.segments]

    def test_normal_speech_is_cut_at_the_pause(self):
        self.assertEqual(self.cuts(.2), [10.0])

    def test_quiet_speech_is_cut_at_the_pause_too(self):
        # Speech around -50 dBFS sits below the configured 0.008 everywhere.
        self.assertEqual(self.cuts(.004), [10.0])

    def test_the_threshold_follows_quiet_speakers_only(self):
        from engine import pause_threshold
        self.assertEqual(pause_threshold([]), .008)
        self.assertEqual(pause_threshold([.2] * 50 + [0] * 50), .008)
        self.assertAlmostEqual(pause_threshold([.004] * 50 + [0] * 50), .001)
        self.assertEqual(pause_threshold([.0001] * 100), .0008)


if __name__ == '__main__':
    unittest.main()
