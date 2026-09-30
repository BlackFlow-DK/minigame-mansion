"""Synthesises every sound effect of Minigame Mansion into game/audio/sfx/*.wav.

Standard library only (wave, math, random, struct). Mono, 44.1 kHz, 16-bit.
Run from anywhere:  python art/scripts/audio/gen_sfx.py [name ...]
Then run tools/godot-import.ps1 so Godot imports the new/changed files.
Loops (*_loop) loop through their committed .wav.import settings (edit/loop_mode=2, Forward);
a brand-new loop needs that line set once after its first import.

Style: soft and cartoony. Sine/triangle blips with pitch envelopes, filtered noise,
short envelopes, light tanh saturation, raised-cosine fades so nothing clicks.
Each sound is peak-normalised to its own target level; the script prints peak, RMS and
duration and fails (exit 1) on clipping, silence, DC offset, a clicky edge, a wrong
length, or a loop whose seam jumps.
"""
from __future__ import annotations

import math
import random
import struct
import sys
import wave
from pathlib import Path

SR = 44100
TAU = 2.0 * math.pi
OUT_DIR = Path(__file__).resolve().parents[3] / "game" / "audio" / "sfx"


# --- primitives -------------------------------------------------------------------------

def n_of(sec: float) -> int:
	return max(1, int(round(sec * SR)))


def silence(sec: float) -> list[float]:
	return [0.0] * n_of(sec)


def lerp(a: float, b: float, t: float) -> float:
	return a + (b - a) * t


def exp_glide(f0: float, f1: float, t: float) -> float:
	"""Exponential (musical) glide from f0 to f1, t in 0..1."""
	t = min(max(t, 0.0), 1.0)
	return f0 * (f1 / f0) ** t


def tri(phase: float) -> float:
	p = phase / TAU % 1.0
	return 4.0 * p - 1.0 if p < 0.5 else 3.0 - 4.0 * p


def osc(sec: float, freq, shape: str = "sine", phase: float = 0.0) -> list[float]:
	"""Oscillator; `freq` is a number or a function of normalised time 0..1."""
	n = n_of(sec)
	out = [0.0] * n
	f = freq if callable(freq) else (lambda _t, v=freq: v)
	ph = phase
	for i in range(n):
		t = i / n
		out[i] = math.sin(ph) if shape == "sine" else tri(ph)
		ph += TAU * f(t) / SR
	return out


def env_ad(sec: float, attack: float, decay_curve: float = 4.0) -> list[float]:
	"""Attack (linear-ish, raised cosine) then exponential decay to ~0 at the end."""
	n = n_of(sec)
	a = max(1, n_of(attack))
	out = [0.0] * n
	for i in range(n):
		if i < a:
			out[i] = 0.5 - 0.5 * math.cos(math.pi * i / a)
		else:
			t = (i - a) / max(1, n - a)
			out[i] = math.exp(-decay_curve * t) * (1.0 - t)
	return out


def env_adsr(sec: float, a: float, d: float, s: float, r: float) -> list[float]:
	n = n_of(sec)
	na, nd, nr = n_of(a), n_of(d), n_of(r)
	out = [0.0] * n
	for i in range(n):
		if i < na:
			v = 0.5 - 0.5 * math.cos(math.pi * i / na)
		elif i < na + nd:
			v = lerp(1.0, s, (i - na) / nd)
		else:
			v = s
		if i > n - nr:
			v *= 0.5 + 0.5 * math.cos(math.pi * (i - (n - nr)) / nr)
		out[i] = v
	return out


def env_bell(sec: float, peak_at: float = 0.5) -> list[float]:
	"""Smooth swell and fade (for whooshes)."""
	n = n_of(sec)
	out = [0.0] * n
	for i in range(n):
		t = i / n
		if t < peak_at:
			out[i] = math.sin(0.5 * math.pi * t / peak_at) ** 2
		else:
			out[i] = math.cos(0.5 * math.pi * (t - peak_at) / (1.0 - peak_at)) ** 2
	return out


def mul(a: list[float], b: list[float]) -> list[float]:
	return [x * y for x, y in zip(a, b)]


def gain(a: list[float], g: float) -> list[float]:
	return [x * g for x in a]


def mix(*tracks, length: int | None = None) -> list[float]:
	"""mix((signal, offset_sec, gain), ...) or plain signals."""
	items = []
	for t in tracks:
		if isinstance(t, tuple):
			sig, off, g = (t + (1.0,))[:3] if len(t) == 2 else t
		else:
			sig, off, g = t, 0.0, 1.0
		items.append((sig, int(round(off * SR)), g))
	n = length if length is not None else max(o + len(s) for s, o, _ in items)
	out = [0.0] * n
	for sig, off, g in items:
		for i, x in enumerate(sig):
			j = off + i
			if 0 <= j < n:
				out[j] += x * g
	return out


def noise(sec: float, rng: random.Random) -> list[float]:
	return [rng.uniform(-1.0, 1.0) for _ in range(n_of(sec))]


def lowpass(sig: list[float], cutoff, poles: int = 2) -> list[float]:
	"""Cascaded one-pole lowpass; `cutoff` in Hz or a function of normalised time."""
	c = cutoff if callable(cutoff) else (lambda _t, v=cutoff: v)
	n = len(sig)
	out = list(sig)
	for _ in range(poles):
		y = 0.0
		for i in range(n):
			a = 1.0 - math.exp(-TAU * min(c(i / n), SR * 0.45) / SR)
			y += a * (out[i] - y)
			out[i] = y
	return out


def highpass(sig: list[float], cutoff: float) -> list[float]:
	low = lowpass(sig, cutoff, poles=1)
	return [x - l for x, l in zip(sig, low)]


def bandpass(sig: list[float], center, q: float = 2.0) -> list[float]:
	"""Chamberlin state-variable bandpass; `center` Hz or function of normalised time."""
	c = center if callable(center) else (lambda _t, v=center: v)
	n = len(sig)
	low = band = 0.0
	damp = 1.0 / q
	out = [0.0] * n
	for i in range(n):
		f = 2.0 * math.sin(math.pi * min(c(i / n), SR * 0.2) / SR)
		high = sig[i] - low - damp * band
		band += f * high
		low += f * band
		out[i] = band
	return out


def saturate(sig: list[float], drive: float = 1.5) -> list[float]:
	k = math.tanh(drive)
	return [math.tanh(drive * x) / k for x in sig]


def fade(sig: list[float], fade_in: float = 0.003, fade_out: float = 0.012) -> list[float]:
	out = list(sig)
	n = len(out)
	fi, fo = min(n_of(fade_in), n // 2), min(n_of(fade_out), n // 2)
	for i in range(fi):
		out[i] *= 0.5 - 0.5 * math.cos(math.pi * i / fi)
	for i in range(fo):
		out[n - 1 - i] *= 0.5 - 0.5 * math.cos(math.pi * i / fo)
	return out


def remove_dc(sig: list[float]) -> list[float]:
	return highpass(sig, 20.0)


def normalise(sig: list[float], peak: float) -> list[float]:
	m = max(abs(x) for x in sig) or 1.0
	return [x * peak / m for x in sig]


# --- instruments ------------------------------------------------------------------------

NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def hz(name: str) -> float:
	"""'C5' -> Hz (A4 = 440)."""
	semi = NOTE[name[0]] + (1 if "#" in name else 0)
	octave = int(name[-1])
	return 440.0 * 2.0 ** ((semi + 12 * (octave + 1) - 69) / 12.0)


def blip(freq, sec: float, attack: float = 0.004, decay: float = 5.0, shape: str = "sine") -> list[float]:
	return mul(osc(sec, freq, shape), env_ad(sec, attack, decay))


def bell(freq: float, sec: float, decay: float = 5.0) -> list[float]:
	"""Soft glockenspiel: fundamental + inharmonic partials that die faster."""
	return mix(
		mul(osc(sec, freq), env_ad(sec, 0.003, decay)),
		(mul(osc(sec, freq * 2.76), env_ad(sec, 0.002, decay * 2.5)), 0.0, 0.28),
		(mul(osc(sec, freq * 5.40), env_ad(sec, 0.002, decay * 4.0)), 0.0, 0.10),
	)


def mallet(freq: float, sec: float, decay: float = 6.0) -> list[float]:
	"""Marimba-ish: sine + 4x partial, triangle body."""
	return mix(
		mul(osc(sec, freq, "tri"), env_ad(sec, 0.004, decay)),
		(mul(osc(sec, freq), env_ad(sec, 0.003, decay)), 0.0, 0.7),
		(mul(osc(sec, freq * 4.0), env_ad(sec, 0.002, decay * 3.0)), 0.0, 0.15),
	)


def piano(freq: float, sec: float, rng: random.Random) -> list[float]:
	"""Soft piano-ish tone: slightly inharmonic partials, the higher ones decaying faster,
	a detuned second string for warmth and a tiny felt-hammer thump."""
	n = n_of(sec)
	out = [0.0] * n
	b = 0.0004  # inharmonicity
	for k in range(1, 9):
		fk = freq * k * math.sqrt(1.0 + b * k * k)
		if fk > 9000:
			break
		amp = 1.0 / (k ** 1.35)
		dec = 2.2 + 1.3 * k
		ph = rng.uniform(0, TAU)  # both strings struck together: same phase, slow beating
		for detune in (1.0, 1.0012):
			w = TAU * fk * detune / SR
			for i in range(n):
				t = i / SR
				out[i] += 0.5 * amp * math.sin(ph + w * i) * math.exp(-dec * t)
	attack = n_of(0.006)
	for i in range(attack):
		out[i] *= 0.5 - 0.5 * math.cos(math.pi * i / attack)
	thump = mul(lowpass(noise(0.03, rng), 900), env_ad(0.03, 0.002, 6.0))
	out = mix(out, (thump, 0.0, 0.15), length=n)
	return lowpass(out, 5000, poles=1)


def brass(freq: float, sec: float) -> list[float]:
	"""Mellow additive horn with a soft swell (no raw saw/square)."""
	n = n_of(sec)
	env = env_adsr(sec, 0.04, 0.12, 0.75, min(0.25, sec * 0.5))
	out = [0.0] * n
	for k in range(1, 7):
		amp = 1.0 / k ** 1.4
		w = TAU * freq * k / SR
		for i in range(n):
			vib = 1.0 + 0.004 * math.sin(TAU * 5.5 * i / SR) * min(1.0, i / (0.2 * SR))
			out[i] += amp * math.sin(w * i * vib)
	return saturate(mul(out, env), 1.2)


# --- sounds -----------------------------------------------------------------------------
# Each returns (samples, target_peak). Durations are asserted in SPECS.

def s_jump(rng):
	s = 0.2
	body = blip(lambda t: exp_glide(260, 720, t ** 0.6), s, 0.004, 3.5)
	sparkle = blip(lambda t: exp_glide(520, 1440, t ** 0.6), s, 0.004, 6.0, "tri")
	return mix(body, (sparkle, 0, 0.18)), 0.55


def s_land_soft(rng):
	s = 0.16
	thud = blip(lambda t: exp_glide(150, 70, t), s, 0.002, 6.0)
	puff = mul(lowpass(noise(s, rng), 700), env_ad(s, 0.002, 8.0))
	return mix(thud, (puff, 0, 0.6)), 0.5


def s_land_hard(rng):
	s = 0.34
	thud = blip(lambda t: exp_glide(120, 42, t ** 0.7), s, 0.002, 4.5)
	puff = mul(lowpass(noise(s, rng), lambda t: lerp(1400, 300, t)), env_ad(s, 0.002, 6.0))
	return saturate(mix(thud, (puff, 0, 0.7)), 1.8), 0.7


def _step(rng, center, dur):
	tick = mul(bandpass(noise(dur, rng), center, 1.2), env_ad(dur, 0.002, 7.0))
	tap = blip(lambda t: exp_glide(190, 110, t), dur, 0.002, 8.0)
	return mix(tick, (tap, 0, 0.8))


def s_step_a(rng):
	return _step(rng, 900, 0.07), 0.16


def s_step_b(rng):
	return _step(rng, 1150, 0.065), 0.15


def s_step_c(rng):
	return _step(rng, 750, 0.075), 0.16


def s_shove_whoosh(rng):
	s = 0.3
	air = bandpass(noise(s, rng), lambda t: exp_glide(350, 1900, t ** 0.8), 1.6)
	return mul(air, env_bell(s, 0.35)), 0.45


def s_hit_bonk(rng):
	s = 0.26
	body = blip(lambda t: exp_glide(620, 300, t ** 0.5), s, 0.002, 7.0)
	wood = blip(lambda t: exp_glide(620 * 2.7, 300 * 2.7, t ** 0.5), s, 0.002, 16.0)
	knock = mul(lowpass(noise(0.03, rng), 2500), env_ad(0.03, 0.001, 8.0))
	return saturate(mix(body, (wood, 0, 0.25), (knock, 0, 0.35), length=n_of(s)), 1.4), 0.7


def s_stun_wobble(rng):
	s = 0.9
	# two little "birdie" voices circling: vibrato-heavy triangles, slowly sinking
	a = mul(osc(s, lambda t: exp_glide(880, 700, t) * (1 + 0.06 * math.sin(TAU * 7.5 * t * s))), env_adsr(s, 0.02, 0.2, 0.6, 0.3))
	b = mul(osc(s, lambda t: exp_glide(1175, 930, t) * (1 + 0.06 * math.sin(TAU * 7.5 * t * s + 2.0)), "tri"), env_adsr(s, 0.06, 0.2, 0.5, 0.3))
	trem = [0.75 + 0.25 * math.sin(TAU * 4.0 * i / SR) for i in range(n_of(s))]
	return mul(mix(a, (b, 0, 0.35)), trem), 0.4


def s_eliminated_pop(rng):
	pop = blip(lambda t: exp_glide(1100, 180, t ** 0.4), 0.09, 0.001, 4.0)
	burst = mul(lowpass(noise(0.05, rng), 3000), env_ad(0.05, 0.001, 8.0))
	bwoop = blip(lambda t: exp_glide(520, 180, t), 0.26, 0.01, 3.0, "tri")
	return mix((pop, 0, 1.0), (burst, 0, 0.5), (bwoop, 0.07, 0.5)), 0.65


def s_respawn(rng):
	notes = ["C5", "E5", "G5", "C6"]
	parts = [(bell(hz(nm), 0.3, 6.0), i * 0.06, 0.8) for i, nm in enumerate(notes)]
	shimmer = mul(bandpass(noise(0.5, rng), 6000, 3.0), env_bell(0.5, 0.5))
	return mix(*parts, (shimmer, 0.0, 0.08), length=n_of(0.52)), 0.55


def s_coin(rng):
	a = bell(hz("B5"), 0.08, 3.0)
	b = bell(hz("E6"), 0.2, 5.0)
	return mix((a, 0, 0.9), (b, 0.06, 1.0)), 0.5


def s_coin_big(rng):
	notes = ["E5", "G#5", "B5", "E6"]
	parts = [(bell(hz(nm), 0.4 if i == 3 else 0.12, 4.0), i * 0.07, 1.0) for i, nm in enumerate(notes)]
	shimmer = mul(bandpass(noise(0.45, rng), 7000, 4.0), env_bell(0.45, 0.4))
	return mix(*parts, (shimmer, 0.18, 0.1), length=n_of(0.64)), 0.6


def s_bomb_tick(rng):
	s = 0.08
	return mix(blip(1800, s, 0.001, 14.0), (blip(900, s, 0.001, 10.0, "tri"), 0, 0.6)), 0.45


def s_explosion(rng):
	s = 1.2
	rumble = mul(lowpass(noise(s, rng), lambda t: exp_glide(2400, 120, t ** 0.5), 3), env_ad(s, 0.004, 3.5))
	thump = blip(lambda t: exp_glide(95, 32, t ** 0.5), 0.6, 0.003, 3.0)
	poof = mul(bandpass(noise(0.25, rng), lambda t: exp_glide(900, 300, t), 1.0), env_ad(0.25, 0.002, 5.0))
	return saturate(mix(rumble, (thump, 0, 1.1), (poof, 0, 0.6), length=n_of(s)), 2.0), 0.8


def s_platform_crack(rng):
	s = 0.36
	parts = []
	t = 0.0
	for _ in range(6):
		d = rng.uniform(0.015, 0.035)
		c = mul(bandpass(noise(d, rng), rng.uniform(1200, 2600), 2.5), env_ad(d, 0.0005, 6.0))
		parts.append((c, t, rng.uniform(0.6, 1.0)))
		t += rng.uniform(0.025, 0.06)
	creak = mul(osc(0.3, lambda u: 180 + 40 * math.sin(TAU * 23 * u * 0.3) + 60 * u, "tri"), env_bell(0.3, 0.3))
	creak = lowpass(creak, 1200)
	return mix(*parts, (creak, 0.04, 0.35), length=n_of(s)), 0.55


def s_platform_fall(rng):
	s = 0.8
	whistle = mul(osc(s, lambda t: exp_glide(950, 190, t ** 1.2)), env_adsr(s, 0.03, 0.2, 0.7, 0.25))
	air = mul(bandpass(noise(s, rng), lambda t: exp_glide(1500, 400, t), 2.0), env_bell(s, 0.6))
	return mix(whistle, (air, 0, 0.3)), 0.45


def s_lava_sizzle(rng):
	s = 0.8
	hiss = mul(highpass(lowpass(noise(s, rng), 4200, 3), 1500), env_adsr(s, 0.02, 0.2, 0.55, 0.35))
	crackle = [0.0] * n_of(s)
	for i in range(len(crackle)):
		if rng.random() < 0.004:
			crackle[i] = rng.uniform(-1, 1)
	crackle = lowpass(crackle, 4000, 1)
	parts = [hiss, (crackle, 0, 0.8)]
	for _ in range(5):
		d = rng.uniform(0.04, 0.07)
		f0 = rng.uniform(180, 320)
		parts.append((blip(lambda t, f0=f0: exp_glide(f0, f0 * 2.2, t), d, 0.003, 4.0), rng.uniform(0.05, 0.65), 0.5))
	return mix(*parts, length=n_of(s)), 0.4


def s_countdown_beep(rng):
	s = 0.2
	tone = mix(osc(s, 660), (osc(s, 1320), 0, 0.15))
	return mul(tone, env_adsr(s, 0.006, 0.05, 0.6, 0.08)), 0.5


def s_countdown_go(rng):
	s = 0.5
	tone = mix(osc(s, 880), (osc(s, 1320), 0, 0.5), (osc(s, 1760, "tri"), 0, 0.12))
	return saturate(mul(tone, env_adsr(s, 0.006, 0.1, 0.65, 0.25)), 1.2), 0.6


def s_round_win_jingle(rng):
	seq = [("C5", 0.0), ("E5", 0.12), ("G5", 0.24), ("C6", 0.40)]
	parts = []
	for i, (nm, at) in enumerate(seq):
		dur = 0.8 if i == 3 else 0.2
		parts.append((mallet(hz(nm), dur, 4.0 if i == 3 else 6.0), at, 1.0))
		if i == 3:
			parts.append((mallet(hz("G5"), dur, 4.0), at, 0.45))
			parts.append((mallet(hz("E5"), dur, 4.0), at, 0.4))
	return mix(*parts, length=n_of(1.22)), 0.6


def s_round_end(rng):
	parts = [(bell(hz("G5"), 0.35, 4.0), 0.0, 1.0), (bell(hz("C5"), 0.5, 3.5), 0.18, 1.0)]
	return mix(*parts, length=n_of(0.7)), 0.55


def s_podium_fanfare(rng):
	seq = [("G4", 0.0, 0.14), ("G4", 0.16, 0.14), ("G4", 0.32, 0.14), ("C5", 0.48, 0.5),
		("G4", 1.0, 0.16), ("C5", 1.18, 1.3)]
	parts = []
	for nm, at, dur in seq:
		parts.append((brass(hz(nm), dur), at, 0.8))
	# final chord pad and sparkle
	for nm, g in (("E5", 0.45), ("G5", 0.4)):
		parts.append((brass(hz(nm), 1.3), 1.18, g))
	for i, nm in enumerate(["C6", "E6", "G6", "C7"]):
		parts.append((bell(hz(nm), 0.5, 5.0), 1.2 + i * 0.08, 0.25))
	return mix(*parts, length=n_of(2.6)), 0.7


def s_ui_move(rng):
	return blip(1250, 0.06, 0.002, 8.0), 0.28


def s_ui_click(rng):
	s = 0.1
	return mix(blip(lambda t: exp_glide(700, 1150, t), s, 0.002, 6.0), (blip(2300, 0.03, 0.001, 8.0), 0, 0.15), length=n_of(s)), 0.4


def s_ui_back(rng):
	return blip(lambda t: exp_glide(720, 430, t), 0.12, 0.002, 5.0), 0.38


def s_join_chime(rng):
	return mix((bell(hz("E5"), 0.3, 4.0), 0, 1.0), (bell(hz("B5"), 0.4, 4.0), 0.1, 1.0), length=n_of(0.5)), 0.45


def s_leave_chime(rng):
	return mix((bell(hz("B5"), 0.3, 4.0), 0, 0.8), (bell(hz("E5"), 0.4, 4.0), 0.12, 1.0), length=n_of(0.52)), 0.38


def _piano_note(name):
	def gen(rng):
		return piano(hz(name), 1.6, rng), 0.55
	return gen


# --- loops: made seamless by crossfading the tail into the head ---------------------------

def seamless(sig: list[float], loop_sec: float, xfade_sec: float) -> list[float]:
	"""`sig` must be loop+xfade long. Returns loop_sec samples whose end flows into the start."""
	n, x = n_of(loop_sec), n_of(xfade_sec)
	out = sig[:n]
	for i in range(x):
		w = 0.5 - 0.5 * math.cos(math.pi * i / x)  # 0 -> 1
		out[i] = sig[n + i] * (1.0 - w) + sig[i] * w
	return out


def s_bomb_fuse_loop(rng):
	loop, xf = 1.0, 0.1
	total = loop + xf
	hiss = lowpass(bandpass(noise(total, rng), 2600, 1.5), 4500)
	hiss = [h * (0.8 + 0.2 * math.sin(TAU * 13 * i / SR)) for i, h in enumerate(hiss)]
	sparks = [0.0] * n_of(total)
	for i in range(len(sparks)):
		if rng.random() < 0.0025:
			sparks[i] = rng.uniform(-1, 1)
	sparks = lowpass(bandpass(sparks, 2200, 1.5), 5000)
	sig = mix(hiss, (sparks, 0, 2.5))
	return seamless(sig, loop, xf), 0.35


def s_portal_hum_loop(rng):
	loop, xf = 2.0, 0.2
	total = loop + xf
	n = n_of(total)
	out = [0.0] * n
	# every frequency completes an integer number of cycles in 2 s -> the tone part is seamless
	for f, a in ((110.0, 1.0), (165.0, 0.5), (220.0, 0.35), (330.5, 0.12)):
		w = TAU * f / SR
		for i in range(n):
			out[i] += a * math.sin(w * i)
	lfo = [0.8 + 0.2 * math.sin(TAU * 0.5 * i / SR) for i in range(n)]
	shimmer = bandpass(noise(total, rng), 2400, 3.0)
	shimmer = [s * (0.5 + 0.5 * math.sin(TAU * 1.0 * i / SR)) for i, s in enumerate(shimmer)]
	sig = mix(mul(out, lfo), (shimmer, 0, 0.25))
	return seamless(lowpass(sig, 3000, 1), loop, xf), 0.3


# name: (generator, min_sec, max_sec, loop)
SPECS = {
	"jump": (s_jump, 0.1, 0.4, False),
	"land_soft": (s_land_soft, 0.08, 0.3, False),
	"land_hard": (s_land_hard, 0.2, 0.5, False),
	"step_a": (s_step_a, 0.04, 0.12, False),
	"step_b": (s_step_b, 0.04, 0.12, False),
	"step_c": (s_step_c, 0.04, 0.12, False),
	"shove_whoosh": (s_shove_whoosh, 0.15, 0.5, False),
	"hit_bonk": (s_hit_bonk, 0.15, 0.4, False),
	"stun_wobble": (s_stun_wobble, 0.5, 1.2, False),
	"eliminated_pop": (s_eliminated_pop, 0.2, 0.5, False),
	"respawn": (s_respawn, 0.3, 0.8, False),
	"coin": (s_coin, 0.15, 0.4, False),
	"coin_big": (s_coin_big, 0.4, 0.9, False),
	"bomb_tick": (s_bomb_tick, 0.04, 0.15, False),
	"bomb_fuse_loop": (s_bomb_fuse_loop, 0.5, 2.0, True),
	"explosion": (s_explosion, 0.8, 1.6, False),
	"platform_crack": (s_platform_crack, 0.2, 0.6, False),
	"platform_fall": (s_platform_fall, 0.5, 1.2, False),
	"lava_sizzle": (s_lava_sizzle, 0.5, 1.2, False),
	"countdown_beep": (s_countdown_beep, 0.1, 0.3, False),
	"countdown_go": (s_countdown_go, 0.3, 0.8, False),
	"round_win_jingle": (s_round_win_jingle, 0.8, 1.6, False),
	"round_end": (s_round_end, 0.4, 1.0, False),
	"podium_fanfare": (s_podium_fanfare, 2.0, 3.0, False),
	"ui_move": (s_ui_move, 0.03, 0.1, False),
	"ui_click": (s_ui_click, 0.05, 0.15, False),
	"ui_back": (s_ui_back, 0.05, 0.2, False),
	"join_chime": (s_join_chime, 0.3, 0.8, False),
	"leave_chime": (s_leave_chime, 0.3, 0.8, False),
	"portal_hum_loop": (s_portal_hum_loop, 1.0, 4.0, True),
}
for _nm in ("C", "D", "E", "F", "G", "A", "B"):
	SPECS["piano_" + _nm.lower()] = (_piano_note(_nm + "4"), 1.0, 2.0, False)


def db(x: float) -> float:
	return 20.0 * math.log10(max(x, 1e-9))


def render(name: str) -> tuple[bool, str]:
	gen, lo, hi, loop = SPECS[name]
	rng = random.Random(f"mm-sfx-{name}")  # deterministic per sound
	sig, peak = gen(rng)
	if not loop:  # loops are zero-mean by construction; filtering would disturb the seam
		sig = fade(remove_dc(sig))
	sig = normalise(sig, peak)
	if not loop:  # the DC filter can leave a tiny tail offset: re-fade the very end
		sig = fade(sig, 0.001, 0.004)
	problems = []
	pk = max(abs(x) for x in sig)
	rms = math.sqrt(sum(x * x for x in sig) / len(sig))
	dur = len(sig) / SR
	mean = sum(sig) / len(sig)
	if pk >= 0.99:
		problems.append("clipping")
	if db(rms) < -45.0:
		problems.append("near silent")
	if not lo <= dur <= hi:
		problems.append(f"duration {dur:.3f}s outside {lo}-{hi}")
	if abs(mean) > 0.01:
		problems.append(f"DC {mean:.4f}")
	if loop:
		if abs(sig[0] - sig[-1]) > 0.08 * pk:
			problems.append(f"loop seam jump {abs(sig[0] - sig[-1]):.3f}")
	elif abs(sig[0]) > 0.01 or abs(sig[-1]) > 0.01:
		problems.append("clicky edge")
	ints = [int(round(max(-1.0, min(1.0, x)) * 32767)) for x in sig]
	if any(abs(v) >= 32767 for v in ints):
		problems.append("clipped sample")
	OUT_DIR.mkdir(parents=True, exist_ok=True)
	with wave.open(str(OUT_DIR / f"{name}.wav"), "wb") as w:
		w.setnchannels(1)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes(struct.pack(f"<{len(ints)}h", *ints))
	# brightness proxy: rms of the first difference vs the signal -> an "effective" frequency
	drms = math.sqrt(sum((sig[i] - sig[i - 1]) ** 2 for i in range(1, len(sig))) / len(sig))
	bright = math.asin(min(1.0, drms / max(rms, 1e-9) / 2.0)) * SR / math.pi
	if bright > 6000:
		problems.append(f"harsh (brightness {bright:.0f} Hz)")
	line = f"{name:18s} {dur:6.3f}s  peak {db(pk):6.1f} dBFS  rms {db(rms):6.1f} dBFS  bright {bright:5.0f} Hz{'  loop' if loop else ''}"
	if problems:
		line += "  FAIL: " + ", ".join(problems)
	return not problems, line


def main(argv: list[str]) -> int:
	names = argv or list(SPECS)
	unknown = [n for n in names if n not in SPECS]
	if unknown:
		print("unknown sound(s): " + ", ".join(unknown))
		return 1
	ok = True
	for name in names:
		good, line = render(name)
		ok = ok and good
		print(line)
	print(f"{len(names)} sound(s) -> {OUT_DIR}" + ("" if ok else "  (FAILURES)"))
	return 0 if ok else 1


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
