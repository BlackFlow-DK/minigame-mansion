"""Statue Garden sounds -> game/minigames/statue_garden/audio/:
  statue_tune_loop.wav  a jaunty tiptoe march, 8 bars of 2/4 at 150 bpm = exactly 6.4 s, seamless loop
  statue_creak.wav      0.5 s rising stone-on-stone creak (the head starts to turn: WARNING)
  statue_zap.wav        0.45 s eye-beam zap (a blob is caught)

Standard library only; reuses the instruments of art/scripts/audio/gen_sfx.py (imported, not edited).
Run from anywhere:  python art/scripts/props/statue_sounds.py   then tools/godot-import.ps1.
The committed statue_tune_loop.wav.import sets edit/loop_mode=2 (Forward).
"""
from __future__ import annotations

import math
import random
import struct
import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "audio"))
from gen_sfx import (SR, TAU, bandpass, bell, db, env_ad, env_bell, exp_glide, fade, hz, lowpass, mallet,  # noqa: E402
                     mix, mul, n_of, noise, osc, piano, saturate)

OUT_DIR = Path(__file__).resolve().parents[3] / "game" / "minigames" / "statue_garden" / "audio"

BPM = 150.0
BEAT = 60.0 / BPM          # 0.4 s
EIGHTH = BEAT / 2.0        # 0.2 s
BARS = 8
LOOP_SEC = BARS * 2 * BEAT  # 6.4 s

# Harmony per bar (2/4): (bass on beat 1, bass on beat 2, chord plucked on the off-beats).
C = ("C3", "G2", ["E4", "G4", "C5"])
F = ("F2", "C3", ["F4", "A4", "C5"])
G = ("G2", "D3", ["F4", "B4", "D5"])
HARMONY = [C, F, C, G, C, G, C, C]

# Melody: (note, start eighth, length in eighths). Staccato tiptoes with a cheeky turn.
MELODY = [
	("C5", 0, 1), ("E5", 1, 1), ("G5", 2, 1), ("E5", 3, 1),
	("F5", 4, 1), ("A5", 5, 1), ("G5", 6, 2),
	("E5", 8, 1), ("C5", 9, 1), ("D5", 10, 1), ("E5", 11, 1),
	("D5", 12, 1), ("B4", 13, 1), ("G4", 14, 2),
	("C5", 16, 1), ("E5", 17, 1), ("G5", 18, 1), ("C6", 19, 1),
	("B5", 20, 1), ("A5", 21, 1), ("G5", 22, 1), ("F5", 23, 1),
	("E5", 24, 1), ("G5", 25, 1), ("D5", 26, 1), ("F5", 27, 1),
	("E5", 28, 1), ("C5", 29, 1), ("G4", 30, 1), ("C5", 31, 1),
]


def place(buf: list[float], sig: list[float], at_sec: float, g: float) -> None:
	"""Adds `sig` into the circular buffer `buf` at `at_sec` (wrapping past the end)."""
	n = len(buf)
	off = int(round(at_sec * SR))
	for i, x in enumerate(sig):
		buf[(off + i) % n] += x * g


def tune() -> tuple[list[float], float]:
	rng = random.Random("mm-statue-tune")
	buf = [0.0] * n_of(LOOP_SEC)
	for bar, (b1, b2, chord) in enumerate(HARMONY):
		t0 = bar * 2 * BEAT
		for k, bass in enumerate((b1, b2)):
			place(buf, fade(piano(hz(bass), 0.34, rng), 0.002, 0.12), t0 + k * BEAT, 0.8)
			for j, nm in enumerate(chord):
				place(buf, mallet(hz(nm), 0.14, 14.0), t0 + k * BEAT + EIGHTH + j * 0.004, 0.22)
			d = 0.05
			tick = mul(bandpass(noise(d, rng), 6000, 1.4), env_ad(d, 0.001, 9.0))
			place(buf, tick, t0 + k * BEAT + EIGHTH, 0.06)
	for nm, start, length in MELODY:
		dur = length * EIGHTH * 0.75 + 0.06
		place(buf, mallet(hz(nm), dur, 7.0), start * EIGHTH, 0.6)
		place(buf, bell(hz(nm) * 2.0, min(dur, 0.3), 8.0), start * EIGHTH, 0.1)
	sig = saturate(buf, 0.9)
	mean = sum(sig) / len(sig)
	return [x - mean for x in sig], 0.5


def creak() -> tuple[list[float], float]:
	"""Stone grinding on stone, rising: a train of friction clicks speeding up, over a rumble."""
	rng = random.Random("mm-statue-creak")
	s = 0.5
	n = n_of(s)
	clicks = [0.0] * n
	t = 0.0
	while t < s - 0.03:
		u = t / s
		d = 0.012
		c = mul(bandpass(noise(d, rng), exp_glide(500, 1400, u), 3.0), env_ad(d, 0.0005, 5.0))
		j = int(t * SR)
		for i, x in enumerate(c):
			if j + i < n:
				clicks[j + i] += x * (0.5 + 0.5 * u)
		t += 1.0 / exp_glide(28.0, 75.0, u) * rng.uniform(0.8, 1.2)
	groan = mul(osc(s, lambda u: exp_glide(70, 190, u) + 6 * math.sin(TAU * 9 * u), "tri"), env_bell(s, 0.75))
	groan = lowpass(groan, 900)
	rumble = mul(lowpass(noise(s, rng), 220), env_bell(s, 0.6))
	return fade(mix((clicks, 0, 1.0), (groan, 0, 0.55), (rumble, 0, 0.5), length=n), 0.01, 0.04), 0.6


def zap() -> tuple[list[float], float]:
	"""A buzzy eye-beam: a falling wobbly tone, a bright crackle and a low thump."""
	rng = random.Random("mm-statue-zap")
	s = 0.45
	tone = mul(osc(s, lambda u: exp_glide(1700, 160, u ** 0.7) * (1.0 + 0.08 * math.sin(TAU * 38 * u)), "tri"),
			   env_ad(s, 0.003, 3.5))
	buzz = mul(osc(s, lambda u: exp_glide(900, 90, u)), env_ad(s, 0.002, 5.0))
	crackle = mul(bandpass(noise(s, rng), lambda u: exp_glide(5000, 1500, u), 1.5), env_ad(s, 0.001, 7.0))
	thump = mul(osc(0.15, lambda u: exp_glide(120, 45, u)), env_ad(0.15, 0.002, 5.0))
	return saturate(mix((tone, 0, 0.55), (buzz, 0, 0.35), (crackle, 0, 0.45), (thump, 0, 0.6)), 1.4), 0.7


def write(name: str, sig: list[float], peak: float, loop: bool = False) -> int:
	m = max(abs(x) for x in sig) or 1.0
	sig = [x * peak / m for x in sig]
	problems = []
	pk = max(abs(x) for x in sig)
	rms = math.sqrt(sum(x * x for x in sig) / len(sig))
	line = f"{name} {len(sig) / SR:6.3f}s  peak {db(pk):6.1f} dBFS  rms {db(rms):6.1f} dBFS"
	if loop:
		seam = abs(sig[0] - sig[-1])
		step = max(abs(sig[i] - sig[i - 1]) for i in range(1, len(sig)))
		if seam > max(step, 0.02) * 1.05:
			problems.append(f"loop seam jump {seam:.3f}")
		line += f"  seam {seam:.4f}  loop"
	if pk >= 0.99:
		problems.append("clipping")
	if db(rms) < -35.0:
		problems.append("too quiet")
	ints = [int(round(max(-1.0, min(1.0, x)) * 32767)) for x in sig]
	OUT_DIR.mkdir(parents=True, exist_ok=True)
	with wave.open(str(OUT_DIR / f"{name}.wav"), "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes(struct.pack(f"<{len(ints)}h", *ints))
	print(line + ("  FAIL: " + ", ".join(problems) if problems else ""))
	return 1 if problems else 0


def main() -> int:
	bad = 0
	sig, peak = tune()
	bad += write("statue_tune_loop", sig, peak, loop=True)
	sig, peak = creak()
	bad += write("statue_creak", sig, peak)
	sig, peak = zap()
	bad += write("statue_zap", sig, peak)
	return 1 if bad else 0


if __name__ == "__main__":
	sys.exit(main())
