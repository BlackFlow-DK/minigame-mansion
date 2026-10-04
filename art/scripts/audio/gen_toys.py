"""Lobby toy sounds -> game/audio/sfx/toy_*.wav.

Standard library only; reuses the primitives and the checked renderer of gen_sfx.py (imported,
not edited: the toy specs are added to its SPECS table at runtime).
Run from anywhere:  python art/scripts/audio/gen_toys.py [name ...]
Then run tools/godot-import.ps1.

toy_bell     big brass hand bell: hum, prime, minor third, fifth and nominal partials, long ring
toy_boing    trampoline: a springy "boi-oing" with a soft thump
toy_kick     a toy football kick: rubbery thump
toy_cheer    goal: a party horn toot plus a little crowd "yay" of detuned voices and claps
toy_shutter  photo: a camera shutter click-clack with a flash whine
toy_tick     photo countdown tick (a wooden tock)
toy_thunk    see-saw end hitting the floor: a wooden thunk
toy_sproing  see-saw catapult: a rising spring twang
"""
from __future__ import annotations

import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_sfx  # noqa: E402
from gen_sfx import (SR, TAU, bandpass, blip, env_ad, env_bell, exp_glide, lerp, lowpass, mix, mul,  # noqa: E402
                     n_of, noise, osc, saturate)


def _partial(sec: float, f: float, decay: float, attack: float = 0.002, amp: float = 1.0) -> list[float]:
	return [x * amp for x in mul(osc(sec, f), env_ad(sec, attack, decay))]


def s_toy_bell(rng):
	s = 2.6
	f = 330.0
	parts = [(0.5, 2.2, 0.55), (1.0, 3.0, 1.0), (1.19, 3.8, 0.55), (1.5, 4.5, 0.35), (2.0, 4.0, 0.6),
			(2.52, 6.0, 0.22), (3.0, 7.0, 0.16), (4.07, 9.0, 0.08)]
	tracks = []
	for ratio, dec, amp in parts:
		# a slow beat between two near partials gives the bell its shimmer
		tracks.append((_partial(s, f * ratio, dec, 0.002, amp), 0.0, 1.0))
		tracks.append((_partial(s, f * ratio * 1.0025, dec * 1.1, 0.002, amp * 0.35), 0.0, 1.0))
	strike = mul(lowpass(noise(0.04, rng), 3000), env_ad(0.04, 0.001, 8.0))
	tracks.append((strike, 0.0, 0.35))
	return saturate(mix(*tracks, length=n_of(s)), 1.1), 0.75


def s_toy_boing(rng):
	s = 0.55
	def fr(t: float) -> float:
		base = exp_glide(170, 330, min(1.0, t * 3.0))
		return base * (1.0 + 0.32 * math.exp(-5.0 * t) * math.sin(TAU * 9.0 * t * s))
	twang = mul(osc(s, fr, "tri"), env_ad(s, 0.004, 3.2))
	body = mul(osc(s, lambda t: fr(t) * 0.5), env_ad(s, 0.004, 4.0))
	thump = blip(lambda t: exp_glide(110, 55, t), 0.12, 0.002, 6.0)
	return mix(twang, (body, 0, 0.7), (thump, 0, 0.8), length=n_of(s)), 0.6


def s_toy_kick(rng):
	s = 0.2
	body = blip(lambda t: exp_glide(210, 80, t ** 0.6), s, 0.002, 6.0)
	slap = mul(bandpass(noise(0.05, rng), 1600, 1.2), env_ad(0.05, 0.001, 9.0))
	return saturate(mix(body, (slap, 0, 0.5), length=n_of(s)), 1.5), 0.7


def s_toy_cheer(rng):
	s = 1.5
	# party horn: two quick toots then a long one, a buzzy reed (triangle + saturation)
	horn = []
	for at, dur, f in ((0.0, 0.12, 523.0), (0.15, 0.12, 659.0), (0.3, 0.55, 784.0)):
		h = mul(osc(dur, lambda t, f=f: f * (1.0 + 0.01 * math.sin(TAU * 6.0 * t * dur)), "tri"),
				gen_sfx.env_adsr(dur, 0.01, 0.05, 0.8, 0.06))
		horn.append((saturate(h, 2.0), at, 0.45))
	# a small crowd: detuned "yay" voices (formant-ish band-passed saw-like triangles)
	voices = []
	for k in range(7):
		f0 = rng.uniform(220.0, 420.0)
		d = rng.uniform(0.7, 1.05)
		at = rng.uniform(0.25, 0.4)
		v = mul(osc(d, lambda t, f0=f0: f0 * (1.0 + 0.25 * t) * (1.0 + 0.02 * math.sin(TAU * 5.0 * t)), "tri"),
				env_bell(d, 0.25))
		v = bandpass(v, lambda t: lerp(900.0, 1500.0, t), 1.4)
		voices.append((v, at, 0.5))
	claps = []
	for k in range(10):
		at = 0.3 + k * 0.09 + rng.uniform(-0.02, 0.02)
		c = mul(bandpass(noise(0.05, rng), 1800, 1.0), env_ad(0.05, 0.001, 10.0))
		claps.append((c, at, 0.35))
	return mix(*(horn + voices + claps), length=n_of(s)), 0.6


def s_toy_shutter(rng):
	s = 0.45
	click = mul(bandpass(noise(0.03, rng), 3200, 1.5), env_ad(0.03, 0.001, 9.0))
	clack = mul(bandpass(noise(0.04, rng), 2100, 1.5), env_ad(0.04, 0.001, 8.0))
	whine = mul(osc(0.35, lambda t: exp_glide(1200, 2600, t)), env_bell(0.35, 0.2))
	return mix((click, 0.0, 1.0), (clack, 0.07, 0.8), (whine, 0.08, 0.12), length=n_of(s)), 0.5


def s_toy_tick(rng):
	s = 0.12
	tock = blip(lambda t: exp_glide(1100, 900, t), s, 0.001, 9.0)
	wood = mul(bandpass(noise(s, rng), 1500, 2.0), env_ad(s, 0.001, 12.0))
	return mix(tock, (wood, 0, 0.5)), 0.45


def s_toy_thunk(rng):
	s = 0.28
	body = blip(lambda t: exp_glide(160, 90, t ** 0.7), s, 0.002, 6.0)
	wood = mul(bandpass(noise(s, rng), 700, 1.6), env_ad(s, 0.001, 9.0))
	return saturate(mix(body, (wood, 0, 0.6)), 1.3), 0.6


def s_toy_sproing(rng):
	s = 0.6
	tw = mul(osc(s, lambda t: exp_glide(200, 900, t ** 0.8) * (1.0 + 0.08 * math.sin(TAU * 28.0 * t * s)), "tri"),
			env_ad(s, 0.003, 3.0))
	return mix(tw), 0.5


SPECS = {
	"toy_bell": (s_toy_bell, 2.0, 3.0, False),
	"toy_boing": (s_toy_boing, 0.3, 0.8, False),
	"toy_kick": (s_toy_kick, 0.1, 0.4, False),
	"toy_cheer": (s_toy_cheer, 1.0, 2.0, False),
	"toy_shutter": (s_toy_shutter, 0.2, 0.7, False),
	"toy_tick": (s_toy_tick, 0.05, 0.2, False),
	"toy_thunk": (s_toy_thunk, 0.15, 0.5, False),
	"toy_sproing": (s_toy_sproing, 0.3, 0.9, False),
}


def main(argv: list[str]) -> int:
	gen_sfx.SPECS.update(SPECS)
	names = argv or list(SPECS)
	ok = True
	for name in names:
		if name not in SPECS:
			print(f"unknown toy sound {name}")
			return 1
		good, line = gen_sfx.render(name)
		ok = ok and good
		print(line)
	print(f"{len(names)} toy sound(s) -> {gen_sfx.OUT_DIR}" + ("" if ok else "  (FAILURES)"))
	return 0 if ok else 1


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
