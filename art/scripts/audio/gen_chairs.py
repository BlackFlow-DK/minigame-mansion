"""Spotlight Chairs music: a cheerful little waltz loop -> game/audio/sfx/chairs_waltz_loop.wav.

Standard library only; reuses the instruments of gen_sfx.py (imported, not edited).
Run from anywhere:  python art/scripts/audio/gen_chairs.py
Then run tools/godot-import.ps1. The committed .wav.import sets edit/loop_mode=2 (Forward).

The tune: 8 bars of 3/4 at 180 bpm = exactly 8.0 s. Oom-pah-pah: a soft piano bass note on
beat 1, marimba chord plucks on beats 2 and 3, a marimba melody doubled an octave up by a
quiet glockenspiel, and a brushed tick on the off beats. Notes are mixed into a circular
buffer, so whatever rings past the end of bar 8 lands on the start: the loop is seamless.
"""
from __future__ import annotations

import math
import random
import struct
import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_sfx import (SR, OUT_DIR, bandpass, bell, db, env_ad, fade, hz, mallet, mul, n_of, noise,  # noqa: E402
                     piano, saturate)

BPM = 180.0
BEAT = 60.0 / BPM
BARS = 8
LOOP_SEC = BARS * 3 * BEAT  # 8.0 s

# Harmony per bar: (bass note, chord notes).
C = ("C3", ["E4", "G4", "C5"])
C_ALT = ("G2", ["E4", "G4", "C5"])
G7 = ("G2", ["F4", "B4", "D5"])
G7_ALT = ("D3", ["F4", "B4", "D5"])
F = ("F2", ["F4", "A4", "C5"])
BARS_HARMONY = [C, C_ALT, G7, G7_ALT, G7, F, C, G7]

# Melody: (note, start beat, length in beats).
MELODY = [
	("C5", 0, 1), ("E5", 1, 1), ("G5", 2, 1),
	("C6", 3, 2), ("G5", 5, 1),
	("F5", 6, 1), ("D5", 7, 1), ("B4", 8, 1),
	("G4", 9, 2), ("B4", 11, 1),
	("D5", 12, 1), ("F5", 13, 1), ("A5", 14, 1),
	("A5", 15, 1), ("G5", 16, 1), ("F5", 17, 1),
	("E5", 18, 1), ("G5", 19, 1), ("E5", 20, 1),
	("D5", 21, 1), ("B4", 22, 1), ("G4", 23, 1),
]


def place(buf: list[float], sig: list[float], at_sec: float, g: float) -> None:
	"""Adds `sig` into the circular buffer `buf` at `at_sec` (wrapping past the end)."""
	n = len(buf)
	off = int(round(at_sec * SR))
	for i, x in enumerate(sig):
		buf[(off + i) % n] += x * g


def render() -> tuple[list[float], float]:
	rng = random.Random("mm-chairs-waltz")
	buf = [0.0] * n_of(LOOP_SEC)
	for bar, (bass, chord) in enumerate(BARS_HARMONY):
		t0 = bar * 3 * BEAT
		# oom: a soft piano bass note (faded out so its tail does not click)
		place(buf, fade(piano(hz(bass), 0.9, rng), 0.002, 0.2), t0, 0.9)
		# pah pah: short marimba chord plucks
		for beat in (1, 2):
			for k, nm in enumerate(chord):
				place(buf, mallet(hz(nm), 0.22, 10.0), t0 + beat * BEAT + k * 0.004, 0.26)
		# brushed ticks on 2 and 3
		for beat in (1, 2):
			d = 0.06
			tick = mul(bandpass(noise(d, rng), 5200, 1.3), env_ad(d, 0.002, 8.0))
			place(buf, tick, t0 + beat * BEAT, 0.05)
	for nm, start, length in MELODY:
		dur = max(0.3, length * BEAT + 0.12)
		place(buf, mallet(hz(nm), dur, 4.5), start * BEAT, 0.62)
		up = hz(nm) * 2.0
		place(buf, bell(up, min(dur, 0.5), 6.0), start * BEAT, 0.12)
	sig = saturate(buf, 0.9)
	mean = sum(sig) / len(sig)
	sig = [x - mean for x in sig]  # zero mean (a tiny constant shift keeps the seam intact)
	return sig, 0.5


def main() -> int:
	sig, peak = render()
	m = max(abs(x) for x in sig) or 1.0
	sig = [x * peak / m for x in sig]
	problems = []
	pk = max(abs(x) for x in sig)
	rms = math.sqrt(sum(x * x for x in sig) / len(sig))
	# seam: the last sample flows into the first (circular mix), so their step must be small
	seam = abs(sig[0] - sig[-1])
	step = max(abs(sig[i] - sig[i - 1]) for i in range(1, len(sig)))
	if seam > max(step, 0.02) * 1.05:
		problems.append(f"loop seam jump {seam:.3f} (largest in-loop step {step:.3f})")
	if pk >= 0.99:
		problems.append("clipping")
	if db(rms) < -35.0:
		problems.append("too quiet")
	ints = [int(round(max(-1.0, min(1.0, x)) * 32767)) for x in sig]
	name = "chairs_waltz_loop"
	OUT_DIR.mkdir(parents=True, exist_ok=True)
	with wave.open(str(OUT_DIR / f"{name}.wav"), "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes(struct.pack(f"<{len(ints)}h", *ints))
	line = f"{name} {len(sig) / SR:6.3f}s  peak {db(pk):6.1f} dBFS  rms {db(rms):6.1f} dBFS  seam {seam:.4f}  loop"
	print(line + ("  FAIL: " + ", ".join(problems) if problems else ""))
	return 1 if problems else 0


if __name__ == "__main__":
	sys.exit(main())
