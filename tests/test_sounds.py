"""Run: python3 -m unittest discover -s tests"""

import hashlib
import importlib.machinery
import importlib.util
import os
import struct
import tempfile
import unittest
import wave
from contextlib import redirect_stdout
import io

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("make_sounds", os.path.join(HERE, "..", "tools", "make-sounds.py"))
spec = importlib.util.spec_from_loader("make_sounds", loader)
S = importlib.util.module_from_spec(spec)
loader.exec_module(S)


def build(out):
    with redirect_stdout(io.StringIO()):
        S.main(["x", out])


class SoundTests(unittest.TestCase):
    def test_valid_wavs(self):
        out = tempfile.mkdtemp()
        build(out)
        for name in [p + k for p in ("", "marimba-", "glass-") for k in ("finished", "needs", "warning")]:
            with wave.open(os.path.join(out, name + ".wav")) as w:
                self.assertEqual((w.getnchannels(), w.getsampwidth(), w.getframerate()), (1, 2, 44100))
                secs = w.getnframes() / 44100
                self.assertTrue(0.3 <= secs <= 2.0, (name, secs))
                frames = w.readframes(w.getnframes())
            peak = max(abs(v) for (v,) in struct.iter_unpack("<h", frames)) / 32767
            self.assertLessEqual(peak, 0.71, name)
            self.assertGreater(peak, 0.6, name)

    def test_deterministic_and_matches_repo(self):
        a, b = tempfile.mkdtemp(), tempfile.mkdtemp()
        build(a)
        build(b)
        repo = os.path.join(HERE, "..", "assets", "sounds")
        for name in [p + k for p in ("", "marimba-", "glass-") for k in ("finished", "needs", "warning")]:
            digest = [hashlib.sha256(open(os.path.join(d, name + ".wav"), "rb").read()).hexdigest() for d in (a, b, repo)]
            self.assertEqual(len(set(digest)), 1, name + ": rebuild the sounds with tools/make-sounds.py")


if __name__ == "__main__":
    unittest.main()
