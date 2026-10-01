"""Composes and synthesises the music of Minigame Mansion into game/audio/music/*.ogg.

Synthesis is standard library only: stereo, 44.1 kHz, 16-bit WAV into build/music/wav/
(gitignored). ffmpeg then encodes each WAV to Ogg Vorbis (-q:a 5) in game/audio/music/.
ffmpeg: FFMPEG_BIN, else PATH, else %LOCALAPPDATA%/Microsoft/WinGet/Links/ffmpeg.exe; the
script fails if none is found. Each .ogg is decoded back and its length, alignment and loop
seam are checked again (Vorbis is lossy and has encoder priming).
Run from anywhere:  python art/scripts/audio/gen_music.py [name ...] [-j N] [--no-preview]
Then run tools/godot-import.ps1. The loop flag lives in each .ogg.import (loop=true,
loop_offset=0; loop=false for the sting): this script patches existing .import files, so after
a brand-new track's first import run `gen_music.py --patch-imports` and import once more.

Every song is data (SONGS, below): tempo, metre, a chord progression, melody lines and the
parts that play them (instrument, pattern, gain, pan, reverb send). Edit the data and re-run.

Pattern strings (spaces ignored, one step per character, the list cycles bar by bar):
  drums      X x o g = hit (velocity 1.0 / 0.75 / 0.5 / 0.3), - or . = nothing
  bass       1 3 5 7 8 9 = chord degree (in the bass register), ^ v = a semitone below / above
             the next chord's root, - = hold the previous note, . = rest
  comp/arp   comp: X x o g = play the voiced chord; arp: 0-9 = index into the voiced chord
             (wraps up an octave); - = hold, . = rest
Melody lines: "E5:2 A4:1 | ..." note:beats per token, r = rest, bars separated by |. Every bar
must add up to the metre (checked).

Style: soft timbres only. Additive sine voices with gentle attacks (e-piano, vibes, celesta,
flute, pad, organ, piano, round basses), filtered-noise percussion, pitched-sine drums, and a
Freeverb-style room (comb + allpass). Loops are rendered circularly: note and reverb tails
wrap from the end into the start, so the seam is as smooth as any other sample boundary.

Each track is normalised to TARGET_RMS_DB through a soft limiter, validated (clipping, RMS,
seam jump, duration, DC, silence gaps, level spread, brightness), and summarised in a table
(plus a per-second loudness sparkline). Exit 1 on any failure. A PNG waveform + spectrogram per
track goes to build/music/<name>.png.
"""
from __future__ import annotations

import bisect
import math
import os
import random
import shutil
import struct
import subprocess
import sys
import wave
import zlib
from array import array
from pathlib import Path

SR = 44100
TAU = 2.0 * math.pi
ROOT = Path(__file__).resolve().parents[3]
OUT_DIR = ROOT / "game" / "audio" / "music"
PREVIEW_DIR = ROOT / "build" / "music"
WAV_DIR = PREVIEW_DIR / "wav"
DECODED_DIR = PREVIEW_DIR / "decoded"
OGG_QUALITY = "5"

TARGET_RMS_DB = -14.0
RMS_TOLERANCE_DB = 1.0
CEILING = 0.891          # -1 dBFS: the limiter never goes above this
LIMIT_KNEE = 0.6         # the limiter is linear below this

# ======================================================================================
# SONGS (the data to tweak)
# ======================================================================================

SONGS: dict[str, dict] = {
	# ---- Title screen: gentle, inviting. Piano arpeggios, flute melody, soft pad. ------------
	"title_theme": {
		"key": "D major", "bpm": 70, "meter": 4, "bars": 16, "loop": True,
		"reverb": {"wet": 0.42, "room": 0.84, "damp": 0.35},
		"chords": "Dmaj7 | F#m7 | Gmaj7 | A6 | Bm7 | F#m7 | Gmaj7 | Asus4 A |"
		          "Gmaj7 | A6 | F#m7 | Bm7 | Em7 | A7 | Dmaj7 | Asus4 A",
		"lines": {
			"melody": "F#5:3 E5:1 | C#5:3 A4:1 | B4:1 D5:1 F#5:1 A5:1 | F#5:2 E5:2 |"
			          "F#5:2 D5:1 B4:1 | C#5:2 E5:1 A5:1 | B5:2 A5:1 F#5:1 | E5:2 D5:1 C#5:1 |"
			          "D5:1 G5:1 F#5:1 D5:1 | E5:2 C#5:2 | A5:1.5 F#5:0.5 E5:1 C#5:1 | D5:2 B4:2 |"
			          "G5:1.5 F#5:0.5 E5:1 B4:1 | C#5:1 E5:1 G5:1 A5:1 | F#5:4 | r:2 E5:1 C#5:1",
		},
		"parts": [
			{"type": "line", "line": "melody", "inst": "flute", "gain": 0.50, "send": 0.35},
			{"type": "line", "line": "melody", "inst": "celesta", "transpose": 12, "gain": 0.16, "pan": 0.35, "send": 0.5, "bars": (9, 16)},
			{"type": "arp", "inst": "piano", "steps": 8, "pattern": "01232123", "center": 62, "notes": 4, "gate": 1.8, "gain": 0.30, "pan": -0.15, "send": 0.35},
			{"type": "bass", "inst": "piano", "steps": 8, "pattern": "1-------", "low": 38, "gate": 0.95, "gain": 0.30, "send": 0.25},
			{"type": "pad", "inst": "pad", "center": 57, "notes": 4, "gain": 0.10, "send": 0.5},
		],
	},

	# ---- Lobby: warm, slightly spooky mansion waltz. Oom-pah-pah, organ, music box. ----------
	"lobby_waltz": {
		"key": "A minor", "bpm": 90, "meter": 3, "bars": 24, "loop": True,
		"reverb": {"wet": 0.40, "room": 0.86, "damp": 0.3},
		"chords": "Am | E7 | Am | A7 | Dm | Am | B7 | E7 |"
		          "Am | E7 | Am | A7 | Dm | Am | E7 | Am |"
		          "F | G7 | C | Am | Dm | Bdim | E7 | E7",
		"lines": {
			"melody": "E5:2 A4:1 | G#4:2 B4:1 | C5:1 B4:1 A4:1 | C#5:2 E5:1 |"
			          "F5:2 E5:1 | C5:2 A4:1 | A4:1 B4:1 D#5:1 | E5:2 D5:1 |"
			          "C5:2 E5:1 | D5:1 B4:1 G#4:1 | A4:1 C5:1 E5:1 | G5:2 E5:1 |"
			          "F5:1 E5:1 D5:1 | C5:1 B4:1 A4:1 | B4:2 G#4:1 | A4:3 |"
			          "A4:1 C5:1 F5:1 | G5:2 F5:1 | E5:2 C5:1 | A4:1 C5:1 E5:1 |"
			          "F5:2 D5:1 | F5:1 D5:1 B4:1 | G#4:1 B4:1 D5:1 | E5:1 D5:1 B4:1",
		},
		"parts": [
			{"type": "line", "line": "melody", "inst": "glass", "gain": 0.46, "send": 0.32},
			{"type": "line", "line": "melody", "inst": "celesta", "transpose": 12, "gain": 0.11, "pan": 0.35, "send": 0.45, "bars": (9, 24)},
			{"type": "bass", "inst": "upright", "steps": 6, "pattern": "1-----", "low": 36, "gate": 0.8, "gain": 0.50, "send": 0.15},
			{"type": "comp", "inst": "epiano", "steps": 6, "pattern": "..x.x.", "center": 60, "notes": 3, "gate": 0.55, "gain": 0.20, "pan": -0.12, "send": 0.3},
			{"type": "pad", "inst": "organ", "center": 57, "notes": 3, "gain": 0.07, "send": 0.5},
			{"type": "arp", "inst": "celesta", "steps": 6, "pattern": "012321", "center": 74, "notes": 3, "gate": 1.0, "gain": 0.12, "pan": -0.4, "send": 0.5, "bars": (17, 24)},
			{"type": "drum", "drum": "brush", "steps": 6, "pattern": "..x.o.", "gain": 0.40, "pan": 0.25, "send": 0.2},
		],
	},

	# ---- Floor is Lava (LAVA_CAVE): driving drums over a low ostinato, horn hook later. -----
	"lava_drums": {
		"key": "D minor", "bpm": 120, "meter": 4, "bars": 16, "loop": True,
		"reverb": {"wet": 0.30, "room": 0.80, "damp": 0.4},
		"chords": "Dm | Dm | Bb | C | Dm | Dm | Gm | A | Dm | Dm | Bb | C | Gm | Bb | A7 | A7",
		"lines": {
			"hook": "r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | r:4 |"
			        "D5:1.5 F5:0.5 A5:1 F5:1 | E5:1.5 D5:0.5 C5:1 A4:1 | D5:1.5 F5:0.5 Bb5:1 A5:1 | G5:3 r:1 |"
			        "Bb5:1.5 A5:0.5 G5:1 D5:1 | F5:1.5 D5:0.5 Bb4:1 D5:1 | C#5:1.5 E5:0.5 G5:1 E5:1 | A4:2 r:2",
		},
		"parts": [
			{"type": "line", "line": "hook", "inst": "brass", "gain": 0.40, "send": 0.3},
			{"type": "bass", "inst": "bass_round", "steps": 8, "pattern": "11811581", "low": 36, "gate": 0.55, "gain": 0.42},
			{"type": "pad", "inst": "pad", "center": 57, "notes": 3, "gain": 0.09, "send": 0.45},
			{"type": "arp", "inst": "pluck", "steps": 8, "pattern": "01202120", "center": 64, "notes": 3, "gate": 0.9, "gain": 0.13, "pan": 0.35, "send": 0.3, "bars": [(5, 8), (13, 16)]},
			{"type": "drum", "drum": "taiko", "steps": 16, "gain": 0.85, "send": 0.25,
			 "pattern": ["X-----x---x-----", "X-----x---x-----", "X-----x---x-----", "X-----x---X-x-x-"]},
			{"type": "drum", "drum": "tom", "steps": 16, "gain": 0.40, "pan": -0.25, "send": 0.2,
			 "pattern": ["----x-------x---", "----x-------x---", "----x-------x---", "----x-------xxxx"]},
			{"type": "drum", "drum": "shaker", "steps": 16, "pattern": "xgogxgogxgogxgog", "gain": 0.26, "pan": 0.35},
			{"type": "drum", "drum": "clap", "steps": 16, "pattern": "----x-------x---", "gain": 0.50, "pan": 0.1, "send": 0.3, "bars": (9, 16)},
		],
	},

	# ---- Bumper Sumo / Cannon Alley (BRIGHT_DAY): bouncy taiko, cheerful pentatonic hook. ----
	"sky_sumo": {
		"key": "G major", "bpm": 128, "meter": 4, "bars": 16, "loop": True,
		"reverb": {"wet": 0.26, "room": 0.78, "damp": 0.4},
		"chords": "G | C | D | G | Em | C | D | D7 | G | C | D | G | C | D | Em | D7",
		"lines": {
			"hook": "D5:0.5 E5:0.5 G5:1 E5:0.5 D5:0.5 B4:1 | E5:1 G5:0.5 E5:0.5 D5:1 r:1 |"
			        "A4:0.5 B4:0.5 D5:1 E5:0.5 D5:0.5 A4:1 | B4:1.5 A4:0.5 G4:2 |"
			        "B4:0.5 D5:0.5 E5:1 G5:1 E5:1 | G5:0.5 A5:0.5 G5:0.5 E5:0.5 D5:1 E5:1 |"
			        "F#5:1 E5:0.5 D5:0.5 E5:1 F#5:1 | A5:3 r:1 |"
			        "D5:0.5 E5:0.5 G5:1 E5:0.5 D5:0.5 B4:1 | E5:1 G5:0.5 E5:0.5 D5:1 r:1 |"
			        "A4:0.5 B4:0.5 D5:1 E5:0.5 D5:0.5 A4:1 | B4:0.5 D5:0.5 G5:2 r:1 |"
			        "E5:1 G5:1 A5:1 G5:1 | F#5:1 E5:0.5 D5:0.5 A4:2 | G5:1 E5:1 D5:1 B4:1 | A4:1 B4:0.5 C5:0.5 D5:1 r:1",
		},
		"parts": [
			{"type": "line", "line": "hook", "inst": "flute", "gain": 0.46, "send": 0.25},
			{"type": "line", "line": "hook", "inst": "marimba", "transpose": -12, "gain": 0.20, "pan": -0.3, "send": 0.2},
			{"type": "bass", "inst": "bass_round", "steps": 8, "pattern": "1.5.8.5.", "low": 36, "gate": 0.9, "gain": 0.48},
			{"type": "comp", "inst": "pluck", "steps": 8, "pattern": ".x.x.x.x", "center": 67, "notes": 3, "gate": 0.7, "gain": 0.15, "pan": 0.3, "send": 0.2},
			{"type": "pad", "inst": "pad", "center": 60, "notes": 3, "gain": 0.06, "send": 0.4},
			{"type": "drum", "drum": "taiko", "steps": 16, "gain": 0.70, "send": 0.25,
			 "pattern": ["X-----x-X-------", "X-----x-X-----x-", "X-----x-X-------", "X---X---X-x-X-x-"]},
			{"type": "drum", "drum": "shime", "steps": 16, "pattern": ["x-o-x-o-x-o-x-o-", "x-o-x-o-x-o-xoxo"], "gain": 0.22, "pan": -0.2, "send": 0.15},
			{"type": "drum", "drum": "woodblock", "steps": 16, "pattern": "--x---x---x---x-", "gain": 0.20, "pan": 0.4, "send": 0.2},
		],
	},

	# ---- Hot Potato (NIGHT_PARTY): funky bass, e-piano stabs, soft lead. --------------------
	"night_party": {
		"key": "E dorian", "bpm": 110, "meter": 4, "bars": 16, "loop": True, "swing16": 0.54,
		"reverb": {"wet": 0.24, "room": 0.76, "damp": 0.45},
		"chords": "Em7 | Em7 | A9 | A9 | Em7 | Em7 | A9 | A9 | Cmaj7 | Bm7 | Am7 | D9 | Em7 | Em7 | A9 | B7",
		"lines": {
			"lead": "r:2 B4:0.5 D5:0.5 E5:0.5 r:0.5 | G5:0.75 E5:0.25 r:0.5 D5:0.5 E5:2 |"
			        "r:2 C#5:0.5 E5:0.5 G5:0.5 r:0.5 | F#5:0.75 E5:0.25 r:0.5 C#5:0.5 B4:2 |"
			        "r:2 B4:0.5 D5:0.5 E5:0.5 r:0.5 | G5:0.75 E5:0.25 r:0.5 D5:0.5 E5:2 |"
			        "r:2 C#5:0.5 E5:0.5 G5:0.5 r:0.5 | F#5:0.75 E5:0.25 r:0.5 G5:0.5 A5:2 |"
			        "G5:1 E5:0.5 B4:0.5 r:2 | F#5:1 D5:0.5 A4:0.5 r:2 | E5:1 C5:0.5 A4:0.5 r:2 |"
			        "F#5:0.5 E5:0.5 D5:0.5 C5:0.5 A4:2 | B4:0.5 D5:0.5 E5:0.5 G5:0.5 r:0.5 E5:0.5 D5:1 |"
			        "E5:3 r:1 | C#5:0.5 E5:0.5 G5:0.5 B5:0.5 r:0.5 A5:0.5 G5:1 | F#5:1 D#5:1 B4:1 r:1",
		},
		"parts": [
			{"type": "line", "line": "lead", "inst": "lead", "gain": 0.40, "pan": 0.1, "send": 0.25, "gate": 0.85},
			{"type": "bass", "inst": "bass_funk", "steps": 16, "low": 36, "gate": 0.8, "gain": 0.44,
			 "pattern": ["1--1--8-.1-7-58-", "1--1--8-.1-7-5-^"]},
			{"type": "comp", "inst": "epiano", "steps": 16, "pattern": "..X...x..x...x..", "center": 64, "notes": 4, "gate": 1.0, "gain": 0.24, "pan": -0.2, "send": 0.25},
			{"type": "pad", "inst": "pad", "center": 60, "notes": 4, "gain": 0.10, "send": 0.45, "bars": (9, 12)},
			{"type": "drum", "drum": "kick", "steps": 16, "pattern": "X------x-x------", "gain": 0.70},
			{"type": "drum", "drum": "snare", "steps": 16, "pattern": "----X--g----X--g", "gain": 0.40, "pan": 0.05, "send": 0.2},
			{"type": "drum", "drum": "hat", "steps": 16, "pattern": "xgogxgogxgogxgog", "gain": 0.50, "pan": 0.3},
		],
	},

	# ---- Coin Scramble / WARM_HALL arenas: light swing, vibes, walking bass, brushes. --------
	"vault_jazz": {
		"key": "F major", "bpm": 115, "meter": 4, "bars": 16, "loop": True, "swing": 0.64,
		"reverb": {"wet": 0.32, "room": 0.80, "damp": 0.35},
		"chords": "Fmaj7 | D7 | Gm7 | C7 | Am7 | D7 | Gm7 C7 | Fmaj7 |"
		          "Cm7 F7 | Bbmaj7 | Bbm7 Eb7 | Am7 D7 | Gm7 | C7 | Fmaj7 D7 | Gm7 C7",
		"lines": {
			"melody": "C5:0.5 D5:0.5 E5:1 C5:1 A4:1 | F#5:1 E5:0.5 D5:0.5 C5:1 A4:1 |"
			          "Bb4:1 D5:0.5 F5:0.5 A5:1 G5:1 | E5:1 G5:0.5 Bb5:0.5 A5:1 r:1 |"
			          "C5:0.5 D5:0.5 E5:1 G5:1 E5:1 | F#5:1 A5:0.5 F#5:0.5 D5:1 C5:1 |"
			          "Bb4:1 D5:1 E5:1 G5:1 | F5:3 r:1 |"
			          "Eb5:1 G5:1 A5:1 C6:0.5 A5:0.5 | Bb5:1 A5:0.5 F5:0.5 D5:2 |"
			          "Db5:1 F5:1 G5:1 Db5:1 | C5:1 E5:1 F#5:1 A5:1 |"
			          "G5:1 F5:0.5 D5:0.5 Bb4:1 A4:1 | G4:0.5 A4:0.5 Bb4:0.5 C5:0.5 E5:1 D5:1 |"
			          "C5:1 A4:1 F#4:1 A4:1 | Bb4:1 G4:1 E4:1 Bb4:0.5 B4:0.5",
		},
		"parts": [
			{"type": "line", "line": "melody", "inst": "vibes", "gain": 0.46, "pan": 0.15, "send": 0.3},
			{"type": "walk", "inst": "upright", "low": 36, "gate": 0.85, "gain": 0.42, "send": 0.12},
			{"type": "comp", "inst": "epiano", "steps": 8, "pattern": "X--x....", "follow_changes": True, "center": 62, "notes": 4, "gate": 0.8, "gain": 0.20, "pan": -0.2, "send": 0.3},
			{"type": "drum", "drum": "ride", "steps": 8, "pattern": "o-xgo-xg", "gain": 0.16, "pan": 0.3, "send": 0.2},
			{"type": "drum", "drum": "chick", "steps": 8, "pattern": "--x---x-", "gain": 0.30, "pan": -0.3},
			{"type": "drum", "drum": "brush", "steps": 8, "pattern": "--o---o-", "gain": 0.40, "pan": 0.1, "send": 0.15},
		],
	},

	# ---- Podium: 8 s celebratory loop (4 bars at 120). -------------------------------------
	"podium_theme": {
		"key": "C major", "bpm": 120, "meter": 4, "bars": 4, "loop": True,
		"reverb": {"wet": 0.32, "room": 0.82, "damp": 0.35},
		"chords": "C | F | G7 | C",
		"lines": {
			"fanfare": "C5:0.5 E5:0.5 G5:1 E5:0.5 G5:0.5 C6:1 | A5:1.5 G5:0.5 F5:1 A5:1 |"
			           "G5:0.5 F5:0.5 E5:0.5 D5:0.5 B4:1 D5:1 | C5:2 r:1 G4:1",
		},
		"parts": [
			{"type": "line", "line": "fanfare", "inst": "brass", "gain": 0.44, "send": 0.3},
			{"type": "line", "line": "fanfare", "inst": "celesta", "transpose": 12, "gain": 0.12, "pan": 0.35, "send": 0.4},
			{"type": "comp", "inst": "pluck", "steps": 8, "pattern": "x.x.x.x.", "center": 64, "notes": 3, "gate": 0.8, "gain": 0.16, "pan": -0.3, "send": 0.25},
			{"type": "bass", "inst": "bass_round", "steps": 8, "pattern": "1.5.1.5.", "low": 36, "gate": 0.9, "gain": 0.45},
			{"type": "pad", "inst": "pad", "center": 60, "notes": 3, "gain": 0.07, "send": 0.4},
			{"type": "drum", "drum": "timpani", "steps": 16, "gain": 0.55, "send": 0.3,
			 "pattern": ["X-------x-------", "X-------x-------", "X-------x-------", "X-------x-x-x-x-"]},
			{"type": "drum", "drum": "snare", "steps": 16, "gain": 0.22, "pan": 0.15, "send": 0.25,
			 "pattern": ["----x-------x---", "----x-------x---", "----x-------x---", "----x---gggooxxx"]},
			{"type": "drum", "drum": "crash", "steps": 16, "pattern": ["x---------------", "----------------", "----------------", "----------------"], "gain": 0.10, "pan": 0.2, "send": 0.3},
		],
	},

	# ---- Results sting: a 4 s flourish (not a loop). ---------------------------------------
	"results_sting": {
		"key": "C major", "bpm": 120, "meter": 4, "bars": 2, "loop": False, "fade_out": 0.9,
		"reverb": {"wet": 0.40, "room": 0.84, "damp": 0.3},
		"chords": "C | Cmaj9",
		"lines": {
			"run": "G4:0.25 C5:0.25 E5:0.25 G5:0.25 C6:3 | r:4",
			"bell_hi": "r:1 E6:3 | r:4",
			"bell_lo": "r:1 G5:3 | r:4",
			"horn": "r:1 G4:0.5 C5:0.5 E5:2 | D5:0.5 E5:1.5 r:2",
			"low": "r:1 C2:3 | C2:2 r:2",
		},
		"parts": [
			{"type": "line", "line": "run", "inst": "pluck", "gain": 0.40, "pan": -0.2, "send": 0.4},
			{"type": "line", "line": "bell_hi", "inst": "celesta", "gain": 0.20, "pan": 0.3, "send": 0.5},
			{"type": "line", "line": "bell_lo", "inst": "celesta", "gain": 0.18, "pan": -0.3, "send": 0.5},
			{"type": "line", "line": "horn", "inst": "brass", "gain": 0.38, "send": 0.35},
			{"type": "line", "line": "low", "inst": "bass_round", "gain": 0.45},
			{"type": "pad", "inst": "pad", "center": 60, "notes": 4, "gain": 0.12, "send": 0.5},
			{"type": "drum", "drum": "timpani", "steps": 16, "pattern": ["----X-----------", "----------------"], "gain": 0.6, "send": 0.3},
			{"type": "drum", "drum": "crash", "steps": 16, "pattern": ["----x-----------", "----------------"], "gain": 0.12, "pan": 0.2, "send": 0.4},
		],
	},
}

# ======================================================================================
# Theory: notes, chords, voicings
# ======================================================================================

NOTE_PC = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

# Intervals above the root.
QUALITIES = {
	"": (0, 4, 7), "m": (0, 3, 7), "7": (0, 4, 7, 10), "m7": (0, 3, 7, 10), "maj7": (0, 4, 7, 11),
	"6": (0, 4, 7, 9), "m6": (0, 3, 7, 9), "9": (0, 4, 7, 10, 14), "m9": (0, 3, 7, 10, 14),
	"maj9": (0, 4, 7, 11, 14), "dim": (0, 3, 6), "dim7": (0, 3, 6, 9), "m7b5": (0, 3, 6, 10),
	"sus4": (0, 5, 7), "sus2": (0, 2, 7), "7sus4": (0, 5, 7, 10), "add9": (0, 4, 7, 14), "aug": (0, 4, 8),
}


def pc_of(name: str) -> int:
	pc = NOTE_PC[name[0]]
	for ch in name[1:]:
		pc += 1 if ch == "#" else -1 if ch == "b" else 0
	return pc % 12


def midi_of(name: str) -> int:
	"""'C#5' -> 73 (A4 = 69)."""
	i = 1
	pc = NOTE_PC[name[0]]
	while i < len(name) and name[i] in "#b":
		pc += 1 if name[i] == "#" else -1
		i += 1
	return pc + 12 * (int(name[i:]) + 1)


def hz(midi: float) -> float:
	return 440.0 * 2.0 ** ((midi - 69) / 12.0)


class Chord:
	def __init__(self, symbol: str):
		self.symbol = symbol
		body = symbol
		bass = None
		if "/" in body:
			body, bass = body.split("/")
		root = body[0]
		rest = body[1:]
		if rest[:1] in ("#", "b"):
			root += rest[0]
			rest = rest[1:]
		if rest not in QUALITIES:
			raise ValueError(f"unknown chord quality in '{symbol}'")
		self.root = pc_of(root)
		self.ivs = QUALITIES[rest]
		self.bass = pc_of(bass) if bass else self.root

	def pcs(self) -> list[int]:
		return [(self.root + i) % 12 for i in self.ivs]

	def degree(self, d: str) -> int:
		"""Semitones above the root for a bass/walk degree character."""
		if d == "1":
			return 0
		if d == "8":
			return 12
		if d == "9":
			return 14
		if d == "3":
			return self.ivs[1]
		if d == "5":
			return next((i for i in self.ivs if i in (6, 7, 8)), 7)
		if d == "7":
			return next((i for i in self.ivs if i in (9, 10, 11)), 12)
		raise ValueError(f"bad degree '{d}'")


def voicing(chord: Chord, center: int, count: int, prev: list[int] | None) -> list[int]:
	"""Close voicing of `count` notes near `center`, moving as little as possible from `prev`."""
	ivs = list(chord.ivs)
	while len(ivs) > count and 7 in ivs:      # drop the fifth first
		ivs.remove(7)
	while len(ivs) > count:                   # then the root (the bass has it)
		ivs.remove(ivs[0]) if ivs[0] == 0 else ivs.pop()
	pcs = [(chord.root + i) % 12 for i in ivs]
	while len(pcs) < count:
		pcs.append(pcs[len(pcs) % len(ivs)])
	best: list[int] = []
	best_cost = 1e9
	for base in range(center - 7, center + 6):
		notes = []
		for pc in pcs:
			m = base + ((pc - base) % 12)
			while m in notes:
				m += 12
			notes.append(m)
		notes.sort()
		mean = sum(notes) / len(notes)
		cost = abs(mean - center)
		if prev and len(prev) == len(notes):
			cost = 0.4 * cost + sum(abs(a - b) for a, b in zip(notes, prev))
		if cost < best_cost:
			best_cost = cost
			best = notes
	return best


def parse_progression(text: str, meter: int, bars: int) -> list[tuple[float, float, Chord]]:
	cells = [c.strip() for c in text.split("|")]
	cells = [c for c in cells if c]
	if len(cells) != bars:
		raise ValueError(f"progression has {len(cells)} bars, expected {bars}")
	spans = []
	for b, cell in enumerate(cells):
		syms = cell.split()
		each = meter / len(syms)
		for k, s in enumerate(syms):
			spans.append((b * meter + k * each, b * meter + (k + 1) * each, Chord(s)))
	return spans


def parse_line(text: str, meter: int, bars: int, label: str) -> list[tuple[float, float, int | None]]:
	cells = [c.strip() for c in text.split("|")]
	cells = [c for c in cells if c]
	if len(cells) != bars:
		raise ValueError(f"{label}: {len(cells)} bars, expected {bars}")
	events = []
	for b, cell in enumerate(cells):
		t = 0.0
		for tok in cell.split():
			name, dur = tok.split(":")
			d = float(dur)
			events.append((b * meter + t, d, None if name in ("r", "-") else midi_of(name)))
			t += d
		if abs(t - meter) > 1e-6:
			raise ValueError(f"{label}: bar {b + 1} has {t} beats, expected {meter}")
	return events


# ======================================================================================
# DSP primitives
# ======================================================================================

def n_of(sec: float) -> int:
	return max(1, int(round(sec * SR)))


def lp1(sig: list[float], fc: float) -> list[float]:
	a = 1.0 - math.exp(-TAU * fc / SR)
	y = 0.0
	out = [0.0] * len(sig)
	for i, x in enumerate(sig):
		y += a * (x - y)
		out[i] = y
	return out


def hp1(sig: list[float], fc: float) -> list[float]:
	return [x - l for x, l in zip(sig, lp1(sig, fc))]


def bp(sig: list[float], fc: float, q: float) -> list[float]:
	"""Chamberlin state-variable bandpass."""
	f = 2.0 * math.sin(math.pi * min(fc, SR * 0.2) / SR)
	damp = 1.0 / q
	low = band = 0.0
	out = [0.0] * len(sig)
	for i, x in enumerate(sig):
		high = x - low - damp * band
		band += f * high
		low += f * band
		out[i] = band
	return out


def noise(sec: float, rng: random.Random) -> list[float]:
	return [rng.uniform(-1.0, 1.0) for _ in range(n_of(sec))]


def env_exp(n: int, tau: float, attack: float = 0.001) -> list[float]:
	na = max(1, n_of(attack))
	k = 1.0 / (tau * SR)
	return [(0.5 - 0.5 * math.cos(math.pi * i / na) if i < na else 1.0) * math.exp(-i * k) for i in range(n)]


def mul(a: list[float], b: list[float]) -> list[float]:
	return [x * y for x, y in zip(a, b)]


def add(a: list[float], b: list[float], g: float = 1.0) -> list[float]:
	if len(b) > len(a):
		a = a + [0.0] * (len(b) - len(a))
	out = list(a)
	for i, x in enumerate(b):
		out[i] += x * g
	return out


def edge_fade(sig: list[float], sec: float = 0.004) -> list[float]:
	n = min(n_of(sec), len(sig) // 2)
	out = list(sig)
	for i in range(n):
		out[len(out) - 1 - i] *= 0.5 - 0.5 * math.cos(math.pi * i / n)
	return out


# ======================================================================================
# Instruments: f(freq, gate_sec) -> mono samples (gate + release tail)
# ======================================================================================

def _env(n_gate: int, n_rel: int, attack: float) -> list[float]:
	n = n_gate + n_rel
	env = [1.0] * n
	na = min(max(1, n_of(attack)), n)
	for i in range(na):
		env[i] = 0.5 - 0.5 * math.cos(math.pi * i / na)
	for i in range(n_rel):
		env[n_gate + i] *= 0.5 + 0.5 * math.cos(math.pi * (i + 1) / n_rel)
	return env


def voice(freq: float, gate: float, partials, attack=0.005, release=0.12,
		vib=(0.0, 0.0, 0.2), trem=(0.0, 0.0)) -> list[float]:
	"""Additive voice. partials: (ratio, amp, decay per second). vib: (rate Hz, depth, delay s)."""
	n_gate = n_of(gate)
	n_rel = n_of(release)
	n = n_gate + n_rel
	w = TAU * freq / SR
	vrate, vdepth, vdelay = vib
	if vdepth > 0.0:
		nd = max(1, n_of(vdelay))
		vw = TAU * vrate / SR
		ph = [0.0] * n
		p = 0.0
		for i in range(n):
			ph[i] = p
			d = vdepth if i >= nd else vdepth * i / nd
			p += w * (1.0 + d * math.sin(vw * i))
	else:
		ph = [w * i for i in range(n)]
	out = [0.0] * n
	for ratio, amp, dec in partials:
		if freq * ratio > 14000.0:
			continue
		if dec > 0.0:
			k = -dec / SR
			out = [o + amp * math.exp(k * i) * math.sin(ratio * p) for i, o, p in zip(range(n), out, ph)]
		else:
			out = [o + amp * math.sin(ratio * p) for o, p in zip(out, ph)]
	env = _env(n_gate, n_rel, attack)
	trate, tdepth = trem
	if tdepth > 0.0:
		tw = TAU * trate / SR
		env = [e * (1.0 - tdepth * 0.5 * (1.0 - math.cos(tw * i))) for i, e in enumerate(env)]
	return [o * e for o, e in zip(out, env)]


def i_epiano(f, g):
	return voice(f, g, [(1, 1.0, 1.4), (1.002, 0.25, 1.6), (2, 0.28, 3.0), (3, 0.09, 6.0), (4, 0.04, 9.0)], 0.004, 0.10)


def i_vibes(f, g):
	return voice(f, g, [(1, 1.0, 0.9), (4, 0.20, 5.0), (10, 0.03, 14.0)], 0.003, 0.35, trem=(5.5, 0.35))


def i_celesta(f, g):
	return voice(f, g, [(1, 1.0, 2.4), (2, 0.10, 4.0), (4, 0.20, 8.0)], 0.002, 0.30)


def i_glass(f, g):
	return voice(f, g, [(1, 1.0, 0.25), (2, 0.16, 0.6), (3, 0.06, 1.0)], 0.03, 0.20, vib=(5.2, 0.0045, 0.25))


def i_flute(f, g):
	tone = voice(f, g, [(1, 1.0, 0.1), (2, 0.20, 0.3), (3, 0.05, 0.5)], 0.05, 0.16, vib=(4.8, 0.005, 0.3))
	rng = random.Random(int(f * 100))
	air = bp(noise(len(tone) / SR, rng), min(f * 2.5, 6000.0), 3.0)
	env = _env(len(tone) - n_of(0.16), n_of(0.16), 0.03)
	return [t + 0.06 * a * e for t, a, e in zip(tone, air, env)]


def i_lead(f, g):
	return voice(f, g, [(1, 1.0, 0.4), (2, 0.25, 1.0), (3, 0.12, 2.0), (4, 0.05, 3.0)], 0.012, 0.12, vib=(5.5, 0.004, 0.18))


def i_brass(f, g):
	return voice(f, g, [(1, 1.0, 0.0), (2, 0.5, 0.4), (3, 0.3, 0.8), (4, 0.16, 1.2), (5, 0.08, 1.6)], 0.035, 0.14, vib=(5.0, 0.003, 0.3))


def i_pad(f, g):
	return voice(f, g, [(1, 1.0, 0.0), (1.0035, 0.7, 0.0), (0.9966, 0.7, 0.0), (2, 0.12, 0.0), (3, 0.06, 0.0)], 0.45, 0.70)


def i_organ(f, g):
	return voice(f, g, [(1, 1.0, 0.0), (1.003, 0.4, 0.0), (2, 0.45, 0.0), (3, 0.22, 0.0), (4, 0.10, 0.0)], 0.08, 0.25, vib=(5.8, 0.0018, 0.0))


def i_piano(f, g):
	parts = [(1.0011, 0.5, 1.6)]
	for k in range(1, 8):
		parts.append((k * math.sqrt(1.0 + 0.0004 * k * k), 1.0 / k ** 1.4, 1.6 + 1.2 * k))
	return voice(f, g, parts, 0.003, 0.25)


def i_pluck(f, g):
	return voice(f, g, [(1, 1.0, 2.8), (2, 0.45, 5.0), (3, 0.2, 8.0), (4, 0.1, 12.0), (5, 0.04, 16.0)], 0.002, 0.12)


def i_marimba(f, g):
	return voice(f, g, [(1, 1.0, 4.5), (4, 0.22, 14.0), (10, 0.03, 30.0)], 0.002, 0.06)


def i_bass_round(f, g):
	return voice(f, g, [(1, 1.0, 0.5), (2, 0.32, 1.8), (3, 0.10, 3.5)], 0.006, 0.06)


def i_upright(f, g):
	return voice(f, g, [(1, 1.0, 1.8), (2, 0.5, 3.5), (3, 0.18, 6.0), (4, 0.07, 9.0)], 0.005, 0.07)


def i_bass_funk(f, g):
	return voice(f, g, [(1, 1.0, 1.0), (2, 0.55, 3.5), (3, 0.3, 7.0), (4, 0.14, 11.0), (5, 0.07, 15.0)], 0.003, 0.05)


INSTRUMENTS = {
	"epiano": i_epiano, "vibes": i_vibes, "celesta": i_celesta, "glass": i_glass, "flute": i_flute,
	"lead": i_lead, "brass": i_brass, "pad": i_pad, "organ": i_organ, "piano": i_piano,
	"pluck": i_pluck, "marimba": i_marimba, "bass_round": i_bass_round, "upright": i_upright,
	"bass_funk": i_bass_funk,
}


# ======================================================================================
# Drums: f(rng) -> mono samples
# ======================================================================================

def _swept(n: int, freq_of_t, amp_of_t) -> list[float]:
	out = [0.0] * n
	ph = 0.0
	for i in range(n):
		t = i / SR
		out[i] = math.sin(ph) * amp_of_t(t)
		ph += TAU * freq_of_t(t) / SR
	return out


def d_kick(rng):
	n = n_of(0.4)
	body = _swept(n, lambda t: 48.0 + 75.0 * math.exp(-t / 0.03), lambda t: math.exp(-t / 0.13) * min(1.0, t / 0.0015))
	click = mul(lp1(noise(0.006, rng), 2500.0), env_exp(n_of(0.006), 0.002))
	return add(body, click, 0.25)


def d_taiko(rng):
	n = n_of(0.9)
	body = _swept(n, lambda t: 62.0 + 38.0 * math.exp(-t / 0.05), lambda t: math.exp(-t / 0.3) * min(1.0, t / 0.002))
	mode2 = _swept(n, lambda t: 1.59 * (62.0 + 30.0 * math.exp(-t / 0.05)), lambda t: math.exp(-t / 0.12) * min(1.0, t / 0.002))
	skin = mul(lp1(lp1(noise(0.2, rng), 700.0), 700.0), env_exp(n_of(0.2), 0.035))
	return add(add(body, mode2, 0.3), skin, 1.6)


def d_tom(rng):
	n = n_of(0.45)
	body = _swept(n, lambda t: 150.0 * (0.82 + 0.3 * math.exp(-t / 0.04)), lambda t: math.exp(-t / 0.17) * min(1.0, t / 0.0015))
	skin = mul(lp1(noise(0.1, rng), 1500.0), env_exp(n_of(0.1), 0.02))
	return add(body, skin, 0.6)


def d_shime(rng):
	n = n_of(0.25)
	body = _swept(n, lambda t: 420.0 * (0.85 + 0.2 * math.exp(-t / 0.02)), lambda t: math.exp(-t / 0.06) * min(1.0, t / 0.001))
	slap = mul(bp(noise(0.08, rng), 2200.0, 1.5), env_exp(n_of(0.08), 0.015))
	return add(body, slap, 0.9)


def d_snare(rng):
	n = n_of(0.3)
	body = _swept(n, lambda t: 190.0, lambda t: math.exp(-t / 0.05) * min(1.0, t / 0.001))
	body = add(body, _swept(n, lambda t: 330.0, lambda t: math.exp(-t / 0.03)), 0.4)
	wires = lp1(mul(bp(noise(0.3, rng), 2600.0, 0.7), env_exp(n, 0.09)), 7000.0)
	return add(body, wires, 1.6)


def d_clap(rng):
	n = n_of(0.3)
	nz = bp(noise(0.3, rng), 1400.0, 1.3)
	env = [0.0] * n
	for i in range(n):
		t = i / SR
		v = 0.0
		for o in (0.0, 0.011, 0.023):
			if t >= o:
				v += math.exp(-(t - o) / 0.005)
		if t >= 0.03:
			v += 0.7 * math.exp(-(t - 0.03) / 0.08)
		env[i] = v
	return mul(nz, env)


def d_hat(rng):
	n = n_of(0.08)
	nz = lp1(hp1(hp1(noise(0.08, rng), 7000.0), 7000.0), 11000.0)
	return mul(nz, env_exp(n, 0.022))


def d_shaker(rng):
	n = n_of(0.14)
	return mul(bp(noise(0.14, rng), 5200.0, 1.0), env_exp(n, 0.035, attack=0.01))


def d_brush(rng):
	n = n_of(0.3)
	return mul(bp(noise(0.3, rng), 2800.0, 0.6), env_exp(n, 0.09, attack=0.02))


def d_ride(rng):
	n = n_of(1.2)
	out = [0.0] * n
	base = 1650.0 * rng.uniform(0.995, 1.005)
	for ratio, amp, dec in ((1.0, 1.0, 1.6), (1.47, 0.7, 2.2), (2.09, 0.5, 2.8), (2.56, 0.4, 3.5), (3.31, 0.3, 4.5), (4.03, 0.2, 6.0)):
		w = TAU * base * ratio / SR
		ph0 = rng.uniform(0.0, TAU)
		k = -dec / SR
		out = [o + amp * math.exp(k * i) * math.sin(w * i + ph0) for i, o in enumerate(out)]
	out = mul(out, env_exp(n, 10.0, attack=0.001))
	tick = mul(hp1(noise(0.2, rng), 6000.0), env_exp(n_of(0.2), 0.03))
	return [x * 0.5 for x in add(out, tick, 0.8)]


def d_chick(rng):
	n = n_of(0.06)
	return mul(bp(noise(0.06, rng), 6500.0, 2.0), env_exp(n, 0.012))


def d_woodblock(rng):
	n = n_of(0.12)
	a = _swept(n, lambda t: 950.0, lambda t: math.exp(-t / 0.025) * min(1.0, t / 0.0005))
	b = _swept(n, lambda t: 950.0 * 2.6, lambda t: math.exp(-t / 0.012) * min(1.0, t / 0.0005))
	return add(a, b, 0.4)


def d_timpani(rng):
	n = n_of(1.4)
	f0 = 130.8
	body = _swept(n, lambda t: f0 * (1.0 + 0.03 * math.exp(-t / 0.08)), lambda t: math.exp(-t / 0.5) * min(1.0, t / 0.002))
	m2 = _swept(n, lambda t: 1.5 * f0, lambda t: math.exp(-t / 0.35) * min(1.0, t / 0.002))
	m3 = _swept(n, lambda t: 1.98 * f0, lambda t: math.exp(-t / 0.25) * min(1.0, t / 0.002))
	mallet = mul(lp1(noise(0.1, rng), 500.0), env_exp(n_of(0.1), 0.02))
	return add(add(add(body, m2, 0.35), m3, 0.2), mallet, 0.8)


def d_crash(rng):
	n = n_of(2.0)
	nz = noise(2.0, rng)
	shimmer = add(bp(nz, 5500.0, 0.6), bp(nz, 3200.0, 0.8), 0.6)
	return lp1(mul(shimmer, env_exp(n, 0.6, attack=0.003)), 9000.0)


DRUMS = {
	"kick": d_kick, "taiko": d_taiko, "tom": d_tom, "shime": d_shime, "snare": d_snare,
	"clap": d_clap, "hat": d_hat, "shaker": d_shaker, "brush": d_brush, "ride": d_ride,
	"chick": d_chick, "woodblock": d_woodblock, "timpani": d_timpani, "crash": d_crash,
}
DRUM_VARIANTS = 3
VELOCITY = {"X": 1.0, "x": 0.75, "o": 0.5, "g": 0.3}


# ======================================================================================
# Arrangement: a Track renders the parts of one song into stereo buffers
# ======================================================================================

class Track:
	def __init__(self, name: str, spec: dict):
		self.name = name
		self.spec = spec
		self.bpm = spec["bpm"]
		self.meter = spec["meter"]
		self.bars = spec["bars"]
		self.loop = spec["loop"]
		self.spb = 60.0 / self.bpm
		self.total_beats = self.bars * self.meter
		self.n = int(round(self.total_beats * self.spb * SR))
		self.swing = spec.get("swing", 0.5)
		self.swing16 = spec.get("swing16", 0.5)
		self.spans = parse_progression(spec["chords"], self.meter, self.bars)
		self.span_starts = [s for s, _, _ in self.spans]
		self.lines = {k: parse_line(v, self.meter, self.bars, f"{name}.{k}") for k, v in spec.get("lines", {}).items()}
		self.rng = random.Random(f"mm-music-{name}")
		self.L = [0.0] * self.n
		self.R = [0.0] * self.n
		self.S = [0.0] * self.n
		self.stems: dict[str, float] = {}
		self._notes: dict = {}
		self._drums: dict = {}

	# --- time -----------------------------------------------------------------------------
	def warp(self, beat: float) -> float:
		"""Swing: moves the off-beat 8th (and 16th) later; a piecewise-linear time warp."""
		whole = math.floor(beat)
		f = beat - whole
		if self.swing != 0.5:
			s = self.swing
			f = f / 0.5 * s if f < 0.5 else s + (f - 0.5) / 0.5 * (1.0 - s)
		elif self.swing16 != 0.5:
			half = math.floor(f * 2.0) * 0.5
			h = (f - half) * 2.0
			s = self.swing16
			h = h / 0.5 * s if h < 0.5 else s + (h - 0.5) / 0.5 * (1.0 - s)
			f = half + h * 0.5
		return whole + f

	def chord_at(self, beat: float) -> Chord:
		i = bisect.bisect_right(self.span_starts, beat + 1e-9) - 1
		return self.spans[max(0, i)][2]

	def next_chord(self, beat: float) -> Chord:
		"""The chord of the next span after the one at `beat` (wraps to the first)."""
		i = bisect.bisect_right(self.span_starts, beat + 1e-9)
		return self.spans[i % len(self.spans)][2]

	def bar_of(self, beat: float) -> int:
		return int(beat // self.meter) + 1

	# --- mixing ----------------------------------------------------------------------------
	def place(self, sig: list[float], energy: float, beat: float, gain: float, pan: float, send: float, stem: str, jitter: bool = True):
		t = self.warp(beat) * self.spb
		if jitter and beat > 0.0:
			t += self.rng.gauss(0.0, 0.003)
		start = int(round(t * SR))
		gain *= 1.0 + self.rng.uniform(-0.05, 0.05)
		gl = gain * math.cos((pan + 1.0) * math.pi / 4.0)
		gr = gain * math.sin((pan + 1.0) * math.pi / 4.0)
		self.stems[stem] = self.stems.get(stem, 0.0) + energy * gain * gain
		n = self.n
		m = len(sig)
		i = 0
		if start < 0:
			if self.loop:
				start += n
			else:
				i = -start
				start = 0
		pos = start % n if self.loop else start
		L, R, S = self.L, self.R, self.S
		gs = gain * send
		while i < m and pos < n:
			seg = min(m - i, n - pos)
			part = sig[i:i + seg]
			L[pos:pos + seg] = [a + b * gl for a, b in zip(L[pos:pos + seg], part)]
			R[pos:pos + seg] = [a + b * gr for a, b in zip(R[pos:pos + seg], part)]
			if gs > 0.0:
				S[pos:pos + seg] = [a + b * gs for a, b in zip(S[pos:pos + seg], part)]
			i += seg
			pos += seg
			if pos >= n and self.loop:
				pos = 0

	def note(self, inst: str, midi: int, beat: float, beats: float, gain: float, pan: float, send: float, stem: str, gate: float = 1.0):
		t0 = self.warp(beat)
		t1 = self.warp(beat + beats)
		gate_s = max(0.03, (t1 - t0) * self.spb * gate)
		key = (inst, midi, int(round(gate_s * 1000)))
		if key not in self._notes:
			sig = INSTRUMENTS[inst](hz(midi), key[2] / 1000.0)
			self._notes[key] = (sig, sum(x * x for x in sig))
		sig, energy = self._notes[key]
		self.place(sig, energy, beat, gain, pan, send, stem)

	def hit(self, drum: str, beat: float, gain: float, pan: float, send: float, stem: str):
		v = self.rng.randrange(DRUM_VARIANTS)
		key = (drum, v)
		if key not in self._drums:
			sig = edge_fade(DRUMS[drum](random.Random(f"{drum}-{v}")))
			self._drums[key] = (sig, sum(x * x for x in sig))
		sig, energy = self._drums[key]
		self.place(sig, energy, beat, gain, pan, send, stem, jitter=drum not in ("kick", "taiko"))


def _active(part: dict, bar: int) -> bool:
	r = part.get("bars")
	if r is None:
		return True
	ranges = [r] if isinstance(r, tuple) else r
	return any(a <= bar <= b for a, b in ranges)


def _bar_pattern(part: dict, bar: int) -> str:
	p = part["pattern"]
	s = p[(bar - 1) % len(p)] if isinstance(p, list) else p
	s = s.replace(" ", "")
	if len(s) != part["steps"]:
		raise ValueError(f"pattern '{s}' has {len(s)} steps, expected {part['steps']}")
	return s


def _grid(s: str) -> list[tuple[int, int, str]]:
	"""Note grid: (step, length in steps, char) for every hit; '-' holds, '.' rests."""
	events = []
	for i, ch in enumerate(s):
		if ch in "-.":
			continue
		length = 1
		while i + length < len(s) and s[i + length] == "-":
			length += 1
		events.append((i, length, ch))
	return events


def _bass_note(chord: Chord, low: int) -> int:
	return low + ((chord.bass - low) % 12)


def render_part(tr: Track, part: dict, idx: int):
	kind = part["type"]
	gain = part.get("gain", 0.5)
	pan = part.get("pan", 0.0)
	send = part.get("send", 0.0)
	stem = f"{idx}:{kind}:{part.get('inst', part.get('drum', ''))}"
	meter = tr.meter

	if kind == "line":
		tp = part.get("transpose", 0)
		for beat, beats, m in tr.lines[part["line"]]:
			if m is None or not _active(part, tr.bar_of(beat)):
				continue
			accent = 1.06 if abs(beat % meter) < 1e-6 else 1.0
			tr.note(part["inst"], m + tp, beat, beats, gain * accent, pan, send, stem, part.get("gate", 0.95))
		return

	if kind == "pad":
		count = part.get("notes", 4)
		prev = None
		for s, e, chord in tr.spans:
			if not _active(part, tr.bar_of(s)):
				continue
			notes = voicing(chord, part.get("center", 60), count, prev)
			prev = notes
			for k, m in enumerate(notes):
				p = pan + (k / max(1, count - 1) - 0.5) * 0.7
				tr.note(part["inst"], m, s, e - s, gain, p, send, stem, 1.0)
		return

	if kind == "walk":
		low = part.get("low", 36)
		prev_note = None
		for si, (s, e, chord) in enumerate(tr.spans):
			if not _active(part, tr.bar_of(s)):
				continue
			k = int(round(e - s))
			seq = {1: "1", 2: "1^", 3: "15^", 4: "135^"}.get(k, "135" + "5" * (k - 4) + "^")
			root = _bass_note(chord, low)
			nxt = tr.spans[(si + 1) % len(tr.spans)][2]
			nroot = _bass_note(nxt, low)
			for b, d in enumerate(seq):
				if d == "^":
					target = nroot if prev_note is None or abs(nroot - prev_note) <= 6 else nroot + (12 if nroot < prev_note else -12)
					target = max(low, min(low + 19, target))
					m = target - 1 if (prev_note or root) < target else target + 1
				else:
					m = root + chord.degree(d)
				prev_note = m
				tr.note(part["inst"], m, s + b, 1.0, gain * (1.05 if b == 0 else 1.0), pan, send, stem, part.get("gate", 0.85))
		return

	steps = part["steps"]
	step_beats = meter / steps
	for bar in range(1, tr.bars + 1):
		if not _active(part, bar):
			continue
		bar_start = (bar - 1) * meter
		pat = _bar_pattern(part, bar)
		if kind == "drum":
			for i, ch in enumerate(pat):
				if ch in VELOCITY:
					tr.hit(part["drum"], bar_start + i * step_beats, gain * VELOCITY[ch], pan, send, stem)
			continue
		events = _grid(pat)
		if kind == "comp" and part.get("follow_changes"):
			hit_steps = {i for i, _, _ in events}
			for s, e, _ in tr.spans:
				if bar_start < s < bar_start + meter:
					st = int(round((s - bar_start) / step_beats))
					if st not in hit_steps:
						events.append((st, 2, "x"))
			events.sort()
		for i, length, ch in events:
			beat = bar_start + i * step_beats
			dur = length * step_beats
			chord = tr.chord_at(beat)
			if kind == "bass":
				low = part.get("low", 36)
				root = _bass_note(chord, low)
				if ch == "^":
					m = _bass_note(tr.next_chord(beat), low) - 1
				elif ch == "v":
					m = _bass_note(tr.next_chord(beat), low) + 1
				else:
					m = root + chord.degree(ch)
				acc = 1.08 if i == 0 else 1.0
				tr.note(part["inst"], m, beat, dur, gain * acc, pan, send, stem, part.get("gate", 0.9))
			elif kind == "comp":
				notes = voicing(chord, part.get("center", 60), part.get("notes", 3), part.get("_prev"))
				part["_prev"] = notes
				vel = VELOCITY.get(ch, 0.75)
				for k, m in enumerate(notes):
					p = pan + (k / max(1, len(notes) - 1) - 0.5) * 0.4
					tr.note(part["inst"], m, beat, dur, gain * vel, p, send, stem, part.get("gate", 0.8))
			elif kind == "arp":
				notes = voicing(chord, part.get("center", 64), part.get("notes", 3), part.get("_prev"))
				part["_prev"] = notes
				j = int(ch)
				m = notes[j % len(notes)] + 12 * (j // len(notes))
				tr.note(part["inst"], m, beat, dur, gain, pan, send, stem, part.get("gate", 1.0))
			else:
				raise ValueError(f"unknown part type '{kind}'")


# ======================================================================================
# Reverb (Freeverb-style, at half rate), master, validation
# ======================================================================================

COMBS = (1116, 1188, 1277, 1356)
ALLPASSES = (556, 441)
STEREO_SPREAD = 23


def reverb(send: list[float], loop: bool, room: float, damp: float) -> tuple[list[float], list[float]]:
	n = len(send)
	src_full = send + ([send[0]] if loop else [0.0]) if n % 2 else send
	half = [(src_full[2 * i] + src_full[2 * i + 1]) * 0.5 for i in range(len(src_full) // 2)]
	m = len(half)
	# Loops: warm the filters up with the last seconds of the loop, so the output at the start
	# already carries the tail of the end (steady state). One-shots: plain.
	warm = min(m, int(3.0 * SR / 2)) if loop else 0
	src = half[m - warm:] + half if warm else half
	d1 = 1.0 - damp
	outs = []
	for spread in (0, STEREO_SPREAD):
		acc = [0.0] * len(src)
		for d0 in COMBS:
			d = (d0 + spread) // 2
			buf = [0.0] * d
			idx = 0
			filt = 0.0
			for i, v in enumerate(src):
				y = buf[idx]
				filt = y * d1 + filt * damp
				buf[idx] = v + filt * room
				acc[i] += y
				idx += 1
				if idx == d:
					idx = 0
		for a0 in ALLPASSES:
			d = (a0 + spread) // 2
			buf = [0.0] * d
			idx = 0
			for i, v in enumerate(acc):
				b = buf[idx]
				acc[i] = b - v
				buf[idx] = v + b * 0.5
				idx += 1
				if idx == d:
					idx = 0
		acc = acc[warm:]
		up = [0.0] * n
		for i in range(m):
			a = acc[i]
			b = acc[(i + 1) % m] if loop else (acc[i + 1] if i + 1 < m else 0.0)
			j = 2 * i
			if j < n:
				up[j] = a
			if j + 1 < n:
				up[j + 1] = 0.5 * (a + b)
		outs.append(up)
	return outs[0], outs[1]


def rms(x: list[float]) -> float:
	return math.sqrt(sum(v * v for v in x) / max(1, len(x)))


def db(x: float) -> float:
	return 20.0 * math.log10(max(x, 1e-9))


def limiter(x: float) -> float:
	a = abs(x)
	if a <= LIMIT_KNEE:
		return x
	y = LIMIT_KNEE + (CEILING - LIMIT_KNEE) * math.tanh((a - LIMIT_KNEE) / (CEILING - LIMIT_KNEE))
	return y if x > 0 else -y


def master(tr: Track) -> tuple[list[float], list[float], float]:
	rv = tr.spec.get("reverb", {})
	wl, wr = reverb(tr.S, tr.loop, rv.get("room", 0.8), rv.get("damp", 0.35))
	dry = math.sqrt((rms(tr.L) ** 2 + rms(tr.R) ** 2) / 2.0)
	wet = math.sqrt((rms(wl) ** 2 + rms(wr) ** 2) / 2.0)
	wg = rv.get("wet", 0.3) * dry / wet if wet > 1e-9 else 0.0
	L = [a + b * wg for a, b in zip(tr.L, wl)]
	R = [a + b * wg for a, b in zip(tr.R, wr)]
	for ch in (L, R):  # remove DC (a constant: keeps the loop seamless)
		mean = sum(ch) / len(ch)
		for i in range(len(ch)):
			ch[i] -= mean
	if not tr.loop:
		fo = n_of(tr.spec.get("fade_out", 0.5))
		fi = n_of(0.002)
		for ch in (L, R):
			for i in range(fo):
				ch[len(ch) - 1 - i] *= 0.5 - 0.5 * math.cos(math.pi * i / fo)
			for i in range(fi):
				ch[i] *= 0.5 - 0.5 * math.cos(math.pi * i / fi)
	target = 10.0 ** (TARGET_RMS_DB / 20.0)
	both = L + R
	pre_peak = max(abs(v) for v in both)
	g = target / max(rms(both), 1e-9)
	for _ in range(6):
		cur = rms([limiter(v * g) for v in both])
		g *= target / max(cur, 1e-9)
	over_db = db(pre_peak * g / LIMIT_KNEE) if pre_peak * g > LIMIT_KNEE else 0.0
	return [limiter(v * g) for v in L], [limiter(v * g) for v in R], over_db


def to_ints(x: list[float]) -> list[int]:
	return [int(round(max(-1.0, min(1.0, v)) * 32767)) for v in x]


def write_wav(path: Path, L: list[int], R: list[int]):
	inter = array("h", [0]) * (2 * len(L))
	inter[0::2] = array("h", L)
	inter[1::2] = array("h", R)
	if sys.byteorder != "little":
		inter.byteswap()
	path.parent.mkdir(parents=True, exist_ok=True)
	with wave.open(str(path), "wb") as w:
		w.setnchannels(2)
		w.setsampwidth(2)
		w.setframerate(SR)
		w.writeframes(inter.tobytes())


def chord_tone_ratio(tr: Track) -> float:
	"""Share of melody time (all lines) spent on tones of the chord underneath."""
	on = total = 0.0
	for events in tr.lines.values():
		for beat, beats, m in events:
			if m is None:
				continue
			total += beats
			if m % 12 in tr.chord_at(beat).pcs():
				on += beats
	return on / total if total else 1.0


SPARK = " .:-=+*#%@"


def analyse(tr: Track, L: list[float], R: list[float], over_db: float) -> tuple[list[str], dict]:
	n = len(L)
	both = L + R
	peak = max(abs(v) for v in both)
	r = rms(both)
	dur = n / SR
	expected = tr.total_beats * tr.spb
	problems = []
	if peak >= 0.98:
		problems.append(f"clipping (peak {db(peak):.1f} dBFS)")
	ints_l, ints_r = to_ints(L), to_ints(R)
	if any(abs(v) >= 32767 for v in ints_l) or any(abs(v) >= 32767 for v in ints_r):
		problems.append("clipped sample")
	if abs(db(r) - TARGET_RMS_DB) > RMS_TOLERANCE_DB:
		problems.append(f"RMS {db(r):.1f} dBFS outside {TARGET_RMS_DB}+-{RMS_TOLERANCE_DB}")
	if abs(dur - expected) > 1.5 / SR:
		problems.append(f"duration {dur:.4f}s != {expected:.4f}s")
	for ch in (L, R):
		if abs(sum(ch) / n) > 0.002:
			problems.append("DC offset")
			break
	# Seam: the jump from the last sample to the first, against the 99.9th percentile of the
	# sample-to-sample jumps inside the track (a seamless loop is just another sample step).
	diffs = sorted(abs(L[i] - L[i - 1]) for i in range(1, n, 3))
	p999 = diffs[int(len(diffs) * 0.999)]
	if tr.loop:
		seam = max(abs(L[-1] - L[0]), abs(R[-1] - R[0]))
		seam_ratio = seam / max(p999, 1e-9)
		if seam_ratio > 1.0:
			problems.append(f"seam jump {seam:.4f} ({seam_ratio:.2f}x p99.9)")
	else:
		seam_ratio = 0.0
		if max(abs(L[0]), abs(R[0]), abs(L[-1]), abs(R[-1])) > 0.01:
			problems.append("clicky edge")
	# Loudness per second and silence gaps (quarter-second windows).
	per_sec = []
	for s in range(int(math.ceil(dur))):
		a, b = s * SR, min(n, (s + 1) * SR)
		per_sec.append(db(math.sqrt((sum(v * v for v in L[a:b]) + sum(v * v for v in R[a:b])) / (2 * (b - a)))))
	win = SR // 4
	end = n if tr.loop else n - n_of(1.2)
	quiet = min(db(math.sqrt(sum(v * v for v in L[a:a + win]) / win)) for a in range(0, max(win, end - win), win))
	if quiet < -45.0:
		problems.append(f"silence gap ({quiet:.0f} dBFS)")
	body = per_sec if tr.loop else per_sec[:-1]
	spread = max(body) - min(body)
	if tr.loop and spread > 15.0:
		problems.append(f"level spread {spread:.1f} dB")
	drms = math.sqrt(sum((L[i] - L[i - 1]) ** 2 for i in range(1, n)) / n)
	bright = math.asin(min(1.0, drms / max(rms(L), 1e-9) / 2.0)) * SR / math.pi
	if bright > 5000.0:
		problems.append(f"harsh (brightness {bright:.0f} Hz)")
	ct = chord_tone_ratio(tr)
	spark = "".join(SPARK[max(0, min(9, int((v + 34.0) / 3.0)))] for v in per_sec)
	row = {
		"name": tr.name, "key": tr.spec.get("key", ""), "bpm": tr.bpm, "bars": f"{tr.bars}x{tr.meter}/4",
		"dur": dur, "peak": db(peak), "rms": db(r), "seam": seam_ratio, "bright": bright, "ct": ct,
		"over": over_db, "spark": spark, "loop": tr.loop, "problems": problems,
		"stems": tr.stems, "n": n,
	}
	return problems, row | {"ints": (ints_l, ints_r)}


# ======================================================================================
# Preview PNG (waveform + loudness + spectrogram), stdlib only
# ======================================================================================

def _fft(re: list[float], im: list[float]):
	n = len(re)
	j = 0
	for i in range(1, n):
		bit = n >> 1
		while j & bit:
			j ^= bit
			bit >>= 1
		j |= bit
		if i < j:
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
	size = 2
	while size <= n:
		ang = -TAU / size
		wr, wi = math.cos(ang), math.sin(ang)
		half = size // 2
		for start in range(0, n, size):
			cr, ci = 1.0, 0.0
			for k in range(start, start + half):
				l = k + half
				tr_ = re[l] * cr - im[l] * ci
				ti = re[l] * ci + im[l] * cr
				re[l] = re[k] - tr_
				im[l] = im[k] - ti
				re[k] += tr_
				im[k] += ti
				cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
		size *= 2


def write_png(path: Path, w: int, h: int, pixels: list[bytearray]):
	raw = b"".join(b"\x00" + bytes(row) for row in pixels)

	def chunk(tag: bytes, data: bytes) -> bytes:
		return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

	png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
	png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
	path.parent.mkdir(parents=True, exist_ok=True)
	path.write_bytes(png)


def _heat(v: float) -> tuple[int, int, int]:
	v = max(0.0, min(1.0, v))
	stops = [(0.0, (12, 8, 24)), (0.35, (90, 30, 120)), (0.65, (220, 90, 60)), (0.85, (250, 190, 70)), (1.0, (255, 250, 210))]
	for (a, ca), (b, cb) in zip(stops, stops[1:]):
		if v <= b:
			t = (v - a) / (b - a)
			return tuple(int(ca[k] + (cb[k] - ca[k]) * t) for k in range(3))
	return stops[-1][1]


def preview(name: str, L: list[float], R: list[float]):
	W, HW, HS = 800, 160, 200
	n = len(L)
	mono = [(a + b) * 0.5 for a, b in zip(L, R)]
	rows = [bytearray(b"\x10\x10\x18" * W) for _ in range(HW + HS)]

	def put(x, y, c):
		if 0 <= x < W and 0 <= y < HW + HS:
			rows[y][3 * x:3 * x + 3] = bytes(c)

	mid = HW // 2
	ref = 10.0 ** (TARGET_RMS_DB / 20.0)
	for x in range(W):
		a, b = x * n // W, max(x * n // W + 1, (x + 1) * n // W)
		seg = mono[a:b]
		lo, hi = min(seg), max(seg)
		r = math.sqrt(sum(v * v for v in seg) / len(seg))
		for y in range(int(mid - hi * mid), int(mid - lo * mid) + 1):
			put(x, y, (90, 150, 220) if max(abs(lo), abs(hi)) < 0.95 else (255, 60, 60))
		for y in range(int(mid - r * mid), int(mid + r * mid) + 1):
			put(x, y, (170, 210, 255))
		put(x, int(mid - ref * mid), (240, 160, 60))  # target RMS reference
		put(x, int(mid + ref * mid), (240, 160, 60))
	N = 1024
	win = [0.5 - 0.5 * math.cos(TAU * i / (N - 1)) for i in range(N)]
	fmin, fmax = 40.0, 16000.0
	for x in range(W):
		c = x * n // W
		a = max(0, min(n - N, c - N // 2))
		re = [mono[a + i] * win[i] for i in range(N)]
		im = [0.0] * N
		_fft(re, im)
		mags = [db(math.hypot(re[k], im[k]) / (N / 4)) for k in range(N // 2)]
		for y in range(HS):
			f = fmin * (fmax / fmin) ** (1.0 - y / (HS - 1))
			k = min(N // 2 - 1, int(f * N / SR))
			v = (mags[k] + 80.0) / 70.0
			put(x, HW + y, _heat(v))
	write_png(PREVIEW_DIR / f"{name}.png", W, HW + HS, rows)


# ======================================================================================
# Driver
# ======================================================================================

def render(name: str, with_preview: bool = True) -> dict:
	spec = SONGS[name]
	tr = Track(name, spec)
	for idx, part in enumerate(spec["parts"]):
		render_part(tr, dict(part), idx)
	L, R, over = master(tr)
	problems, row = analyse(tr, L, R, over)
	ints_l, ints_r = row.pop("ints")
	wav_path = WAV_DIR / f"{name}.wav"
	write_wav(wav_path, ints_l, ints_r)
	ogg = encode_and_verify(name, wav_path, tr.loop, ints_l)
	row["ogg"] = ogg
	row["problems"] = row["problems"] + ogg["problems"]
	if with_preview:
		preview(name, L, R)
	return row


def find_ffmpeg() -> str:
	links = Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "WinGet" / "Links" / "ffmpeg.exe"
	for cand in (os.environ.get("FFMPEG_BIN"), shutil.which("ffmpeg"), str(links)):
		if cand and Path(cand).exists():
			return cand
	raise SystemExit("gen_music: ffmpeg not found (set FFMPEG_BIN or put ffmpeg on PATH)")


def _ffmpeg(args: list[str]):
	r = subprocess.run([find_ffmpeg(), "-hide_banner", "-loglevel", "error", "-y"] + args, capture_output=True, text=True)
	if r.returncode != 0:
		raise RuntimeError(f"ffmpeg failed ({r.returncode}): {r.stderr.strip()}")


def read_wav(path: Path) -> tuple[list[float], list[float]]:
	with wave.open(str(path), "rb") as w:
		if w.getsampwidth() != 2 or w.getnchannels() != 2:
			raise RuntimeError(f"{path}: expected 16-bit stereo")
		data = array("h")
		data.frombytes(w.readframes(w.getnframes()))
	if sys.byteorder != "little":
		data.byteswap()
	return [v / 32767.0 for v in data[0::2]], [v / 32767.0 for v in data[1::2]]


def encode_and_verify(name: str, wav_path: Path, loop: bool, ints_l: list[int]) -> dict:
	"""WAV -> OGG (game/audio/music), then OGG -> WAV (build) to check length, alignment and seam."""
	ogg_path = OUT_DIR / f"{name}.ogg"
	OUT_DIR.mkdir(parents=True, exist_ok=True)
	_ffmpeg(["-i", str(wav_path), "-c:a", "libvorbis", "-q:a", OGG_QUALITY, "-ac", "2", "-ar", str(SR), str(ogg_path)])
	DECODED_DIR.mkdir(parents=True, exist_ok=True)
	dec_path = DECODED_DIR / f"{name}.wav"
	_ffmpeg(["-i", str(ogg_path), "-c:a", "pcm_s16le", str(dec_path)])
	L, R = read_wav(dec_path)
	n = len(ints_l)
	problems = []
	extra = len(L) - n
	if extra != 0:
		problems.append(f"decoded ogg has {extra:+d} samples")
	# Alignment: the decoded signal against the original (a priming shift would be loud).
	m = min(n, len(L))
	err = sum((L[i] - ints_l[i] / 32767.0) ** 2 for i in range(0, m, 7))
	sig = sum((ints_l[i] / 32767.0) ** 2 for i in range(0, m, 7))
	err_db = 10.0 * math.log10(max(err, 1e-12) / max(sig, 1e-12))
	if err_db > -20.0:
		problems.append(f"decoded ogg differs from the WAV ({err_db:.0f} dB)")
	seam_ratio = 0.0
	if loop:
		diffs = sorted(abs(L[i] - L[i - 1]) for i in range(1, len(L), 3))
		p999 = diffs[int(len(diffs) * 0.999)]
		seam = max(abs(L[-1] - L[0]), abs(R[-1] - R[0]))
		seam_ratio = seam / max(p999, 1e-9)
		if seam_ratio > 1.0:
			problems.append(f"ogg seam jump {seam:.4f} ({seam_ratio:.2f}x p99.9)")
	return {"size": ogg_path.stat().st_size, "extra": extra, "err_db": err_db, "seam": seam_ratio, "problems": problems}


def patch_import(name: str, loop: bool) -> str:
	path = OUT_DIR / f"{name}.ogg.import"
	if not path.exists():
		return "no .import yet"
	text = path.read_text(encoding="utf-8")
	wants = {"loop=": f"loop={'true' if loop else 'false'}", "loop_offset=": "loop_offset=0"}
	lines = text.splitlines()
	changed = False
	for i, line in enumerate(lines):
		for prefix, want in wants.items():
			if line.startswith(prefix) and line != want:
				lines[i] = want
				changed = True
	if changed:
		path.write_text("\n".join(lines) + "\n", encoding="utf-8")
		return "patched"
	return "ok"


def print_table(rows: list[dict]):
	print(f"{'track':14s} {'key':9s} {'bpm':>4s} {'bars':>7s} {'dur s':>7s} {'peak':>6s} {'rms':>6s} {'seam':>5s} {'bright':>6s} {'ct%':>4s} {'lim dB':>6s}  status")
	for r in rows:
		status = "OK" if not r["problems"] else "FAIL: " + ", ".join(r["problems"])
		seam = f"{r['seam']:.2f}" if r["loop"] else "  -  "
		print(f"{r['name']:14s} {r['key']:9s} {r['bpm']:4d} {r['bars']:>7s} {r['dur']:7.3f} {r['peak']:6.1f} {r['rms']:6.1f} {seam:>5s} {r['bright']:6.0f} {r['ct'] * 100:4.0f} {r['over']:6.1f}  {status}")
	print("\nogg, decoded back with ffmpeg (size, sample-count difference, error vs the WAV, loop seam):")
	for r in rows:
		o = r["ogg"]
		seam = f"{o['seam']:.2f}" if r["loop"] else "-"
		print(f"  {r['name']:14s} {o['size'] / 1024:6.0f} KB  {o['extra']:+d} samples  err {o['err_db']:5.1f} dB  seam {seam}")
	print("\nloudness per second (' '=-34 dBFS ... '@'=-7 dBFS):")
	for r in rows:
		print(f"  {r['name']:14s} |{r['spark']}|")
	print("\nstem balance (dB relative to the loudest part):")
	for r in rows:
		top = max(r["stems"].values())
		parts = sorted(r["stems"].items(), key=lambda kv: -kv[1])
		print(f"  {r['name']:14s} " + "  ".join(f"{k.split(':', 1)[1]} {10 * math.log10(max(v, 1e-12) / top):.0f}" for k, v in parts))
	print("\nseam = loop seam jump / 99.9th percentile sample step (<= 1 passes); ct% = melody time on chord tones;")
	print("lim dB = how far the loudest peak was pushed into the soft limiter's knee.")


def main(argv: list[str]) -> int:
	jobs = min(4, os.cpu_count() or 1)
	with_preview = True
	names = []
	patch_only = False
	it = iter(argv)
	for a in it:
		if a == "-j":
			jobs = max(1, int(next(it)))
		elif a == "--no-preview":
			with_preview = False
		elif a == "--patch-imports":
			patch_only = True
		else:
			names.append(a)
	names = names or list(SONGS)
	unknown = [n for n in names if n not in SONGS]
	if unknown:
		print("unknown track(s): " + ", ".join(unknown))
		return 1
	if not patch_only:
		find_ffmpeg()  # fail before rendering
		if jobs > 1 and len(names) > 1:
			from concurrent.futures import ProcessPoolExecutor
			with ProcessPoolExecutor(max_workers=jobs) as ex:
				rows = list(ex.map(render, names, [with_preview] * len(names)))
		else:
			rows = [render(nm, with_preview) for nm in names]
		print_table(rows)
		ok = all(not r["problems"] for r in rows)
	else:
		ok = True
	for nm in names:
		state = patch_import(nm, SONGS[nm]["loop"])
		if state != "ok":
			print(f"  {nm}.ogg.import: {state}")
	print(f"{len(names)} track(s) -> {OUT_DIR}" + ("" if ok else "  (FAILURES)"))
	if with_preview and not patch_only:
		print(f"previews -> {PREVIEW_DIR}")
	return 0 if ok else 1


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
