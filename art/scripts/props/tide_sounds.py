"""Rising Tide sounds -> game/minigames/rising_tide/audio/:
  tide_splash.wav   0.75 s heavy splash + bubbles (a blob drowns)
  tide_boing.wav    0.45 s canvas spring "boing" (a bouncy awning launches a blob)
  tide_rumble.wav   0.9 s low stony rumble with grit (a crumbling ledge gives way)

Standard library only; reuses the instruments of art/scripts/audio/gen_sfx.py (imported, not edited).
Run from anywhere:  python art/scripts/props/tide_sounds.py   then tools/godot-import.ps1.
"""
from __future__ import annotations

import math
import random
import struct
import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "audio"))
from gen_sfx import (SR, blip, bandpass, db, env_ad, env_adsr, env_bell, exp_glide, highpass, lerp, lowpass,  # noqa: E402
                     mix, mul, n_of, noise, osc, saturate)

OUT_DIR = Path(__file__).resolve().parents[3] / "game" / "minigames" / "rising_tide" / "audio"


def splash(rng):
	s = 0.75
	# the slap: a short burst of broadband noise sweeping down
	slap = mul(lowpass(noise(s, rng), lambda t: exp_glide(6000, 900, min(t * 3.0, 1.0))), env_ad(s, 0.003, 9.0))
	# the body of water: a low whump
	whump = blip(lambda t: exp_glide(140, 55, t ** 0.6), 0.35, 0.003, 5.0)
	# spray falling back: hissy tail
	spray = mul(highpass(lowpass(noise(s, rng), 5000, 2), 1200), env_adsr(s, 0.06, 0.15, 0.35, 0.45))
	parts = [(slap, 0, 1.0), (whump, 0, 0.9), (spray, 0.05, 0.35)]
	# bubbles: little rising sine blips
	for _ in range(9):
		d = rng.uniform(0.03, 0.06)
		f0 = rng.uniform(380, 900)
		parts.append((blip(lambda t, f0=f0: exp_glide(f0, f0 * 1.9, t), d, 0.003, 5.0), rng.uniform(0.12, 0.6), 0.28))
	return mix(*parts, length=n_of(s)), 0.6


def boing(rng):
	s = 0.45
	# a sprung canvas: a pitch that jumps up and wobbles while it decays
	def f(t):
		return exp_glide(140, 420, min(t * 4.0, 1.0)) * (1.0 + 0.06 * math.sin(t * 60.0))
	body = mul(osc(s, f, "sine"), env_ad(s, 0.004, 4.0))
	twang = mul(osc(s, lambda t: f(t) * 2.01, "tri"), env_ad(s, 0.004, 7.0))
	thump = blip(lambda t: exp_glide(120, 60, t), 0.12, 0.002, 6.0)
	return saturate(mix(body, (twang, 0, 0.3), (thump, 0, 0.6), length=n_of(s)), 1.3), 0.55


def rumble(rng):
	s = 0.9
	low = mul(lowpass(noise(s, rng), lambda t: lerp(260, 120, t), 3), env_bell(s, 0.3))
	grit = [0.0] * n_of(s)
	for i in range(len(grit)):
		if rng.random() < 0.006:
			grit[i] = rng.uniform(-1, 1)
	grit = mul(bandpass(grit, 2200, 1.5), env_adsr(s, 0.02, 0.3, 0.5, 0.4))
	knock = blip(lambda t: exp_glide(95, 50, t), 0.25, 0.003, 5.0)
	return saturate(mix((low, 0, 1.0), (grit, 0, 0.7), (knock, 0.02, 0.7), length=n_of(s)), 1.6), 0.55


def write(name: str, sig: list[float], peak: float) -> int:
	m = max(abs(x) for x in sig) or 1.0
	sig = [x * peak / m for x in sig]
	problems = []
	pk = max(abs(x) for x in sig)
	rms = math.sqrt(sum(x * x for x in sig) / len(sig))
	line = f"{name} {len(sig) / SR:6.3f}s  peak {db(pk):6.1f} dBFS  rms {db(rms):6.1f} dBFS"
	if pk >= 0.99:
		problems.append("clipping")
	if db(rms) < -35.0:
		problems.append("too quiet")
	if abs(sig[0]) > 0.02 or abs(sig[-1]) > 0.02:
		problems.append("clicky edge")
	ints = [int(round(max(-1.0, min(1.0, x)) * 32767)) for x in sig]
	OUT_DIR.mkdir(parents=True, exist_ok=True)
	with wave.open(str(OUT_DIR / f"{name}.wav"), "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes(struct.pack(f"<{len(ints)}h", *ints))
	print(line + ("  FAIL: " + ", ".join(problems) if problems else ""))
	return 1 if problems else 0


def _fade(sig: list[float], fin: float = 0.003, fout: float = 0.02) -> list[float]:
	n = len(sig)
	a, b = n_of(fin), n_of(fout)
	out = list(sig)
	for i in range(min(a, n)):
		out[i] *= 0.5 - 0.5 * math.cos(math.pi * i / a)
	for i in range(min(b, n)):
		out[n - 1 - i] *= 0.5 - 0.5 * math.cos(math.pi * i / b)
	return out


def main() -> int:
	rng = random.Random(4711)
	bad = 0
	for name, fn in (("tide_splash", splash), ("tide_boing", boing), ("tide_rumble", rumble)):
		sig, peak = fn(rng)
		bad += write(name, _fade(sig), peak)
	return 1 if bad else 0


if __name__ == "__main__":
	sys.exit(main())
