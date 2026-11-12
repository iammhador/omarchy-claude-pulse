#!/usr/bin/env python3
"""Compose Claude Pulse's own alert sounds: a warm bell / marimba voice.

    python3 tools/make-sounds.py [out_dir]     (default: assets/sounds)

Standard library only and fully deterministic, so the WAV files in the repo
can always be rebuilt and checked. Each note is a small additive bell: a
fundamental plus inharmonic partials that die away faster than it does, a
soft 4 ms attack, and a short feedback delay for a little room.

  finished.wav  G5 C6 E6 (last note held)   "done": warm, rising, resolved
  needs.wav     A5 D6                       "your turn": a short question
  warning.wav   E4 C4                       "careful": lower, falling, soft
"""

import math
import os
import struct
import sys
import wave

RATE = 44100
PEAK = 10 ** (-3 / 20)  # -3 dBFS

# Voices: (ratio to the fundamental, level, decay in seconds)
VOICES = {
    # Warm bell: the default "claude" set.
    "bell": [(1.0, 1.0, 0.90), (2.0, 0.28, 0.45), (2.76, 0.22, 0.30), (5.40, 0.08, 0.12), (8.93, 0.03, 0.06)],
    # Marimba: woody, short, a strong fourth partial that dies fast.
    "marimba": [(1.0, 1.0, 0.34), (3.93, 0.32, 0.07), (9.24, 0.07, 0.025)],
    # Glass: bright and airy, long shimmering partials.
    "glass": [(1.0, 0.85, 1.30), (2.32, 0.42, 0.95), (4.25, 0.26, 0.55), (6.63, 0.14, 0.30)],
}
BELL = VOICES["bell"]


def freq(note: str) -> float:
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    semis = names[note[0]] + (int(note[1:]) - 4) * 12
    return 440.0 * 2 ** (semis / 12)


def render(notes, length, decay_scale=1.0, brightness=1.0, voice=None):
    """notes: [(note, start_s, gain, hold)]; returns a list of floats."""
    voice = voice or BELL
    out = [0.0] * int(length * RATE)
    for name, start, gain, hold in notes:
        f = freq(name)
        s0 = int(start * RATE)
        for i in range(s0, len(out)):
            t = (i - s0) / RATE
            attack = min(1.0, t / 0.004)
            v = 0.0
            for ratio, level, decay in voice:
                lvl = level * (brightness if ratio > 1.5 else 1.0)
                v += lvl * math.exp(-t / (decay * decay_scale * hold)) * math.sin(2 * math.pi * f * ratio * t)
            out[i] += gain * attack * v
    # A little room: two soft feedback taps.
    for delay, fb in ((0.083, 0.22), (0.131, 0.14)):
        d = int(delay * RATE)
        for i in range(d, len(out)):
            out[i] += fb * out[i - d]
    # Fade the tail so nothing clicks, then normalise.
    fade = int(0.08 * RATE)
    for k in range(fade):
        out[len(out) - 1 - k] *= k / fade
    top = max(abs(x) for x in out) or 1.0
    return [x / top * PEAK for x in out]


def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(round(max(-1.0, min(1.0, x)) * 32767))) for x in samples))


SOUNDS = {
    "finished": dict(notes=[("G5", 0.00, 0.80, 0.55), ("C6", 0.12, 0.85, 0.60), ("E6", 0.24, 1.00, 1.30)], length=1.25),
    "needs": dict(notes=[("A5", 0.00, 0.85, 0.45), ("D6", 0.11, 1.00, 0.70)], length=0.55),
    "warning": dict(notes=[("E4", 0.00, 1.00, 0.60), ("C4", 0.17, 0.95, 0.80)], length=0.75, decay_scale=0.9, brightness=0.6),
}


# Sets: file prefix -> (voice, transpose in octaves, length scale)
SETS = {"": ("bell", 0, 1.0), "marimba-": ("marimba", 0, 0.8), "glass-": ("glass", 1, 1.15)}


def shift(note, octaves):
    return note[0] + str(int(note[1:]) + octaves)


def main(argv):
    out_dir = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sounds")
    os.makedirs(out_dir, exist_ok=True)
    for prefix, (voice, octaves, stretch) in SETS.items():
        for name, spec in SOUNDS.items():
            oct_ = octaves if name != "warning" else 0
            notes = [(shift(n, oct_), t, g, h) for n, t, g, h in spec["notes"]]
            samples = render(notes, spec["length"] * stretch, spec.get("decay_scale", 1.0), spec.get("brightness", 1.0), VOICES[voice])
            write(os.path.join(out_dir, prefix + name + ".wav"), samples)
            print(f"{prefix}{name}.wav  {len(samples) / RATE:.2f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
