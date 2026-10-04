class_name BlobExpressions
extends RefCounted
## Face presets for the blob. Each preset is a target the face eases toward:
##   lid    lid rotation.x in radians (0 open, 1.2 half, 2.0 shut)
##   mouth  mouth scale (x width, y height; 1 = the modelled half-open smile, y 0.15 closed, 1.8 shout)
##   cheek  cheek blush scale (1 = rest)
##   pupil  pupil scale (1 = rest)

const NEUTRAL := &"neutral"
const HAPPY := &"happy"
const EFFORT := &"effort"
const HURT := &"hurt"
const DIZZY := &"dizzy"
const CHEER := &"cheer"
const SAD := &"sad"
const PANIC := &"panic"
const WORRIED := &"worried"
const SMUG := &"smug"
const SLEEPY := &"sleepy"
const YAWN := &"yawn"
const WINCE := &"wince"
const CRY := &"cry"
const RASPBERRY := &"raspberry"

const PRESETS: Dictionary = {
	&"neutral": {"lid": 0.0, "mouth": Vector2(0.95, 0.7), "cheek": 1.0, "pupil": 1.0},
	&"happy": {"lid": 0.45, "mouth": Vector2(1.12, 1.25), "cheek": 1.25, "pupil": 1.05},
	&"effort": {"lid": 0.85, "mouth": Vector2(1.15, 1.8), "cheek": 1.15, "pupil": 0.9},
	&"hurt": {"lid": 2.0, "mouth": Vector2(1.2, 0.35), "cheek": 1.3, "pupil": 1.0},
	&"dizzy": {"lid": 1.2, "mouth": Vector2(0.75, 0.55), "cheek": 0.85, "pupil": 0.85},
	&"cheer": {"lid": 0.3, "mouth": Vector2(1.2, 1.75), "cheek": 1.4, "pupil": 1.1},
	&"sad": {"lid": 1.05, "mouth": Vector2(0.7, 0.2), "cheek": 0.7, "pupil": 1.0},
	&"panic": {"lid": 0.0, "mouth": Vector2(0.85, 1.7), "cheek": 0.9, "pupil": 0.72},
	&"worried": {"lid": 0.2, "mouth": Vector2(0.8, 0.45), "cheek": 0.9, "pupil": 0.85},
	&"smug": {"lid": 0.8, "mouth": Vector2(1.25, 0.8), "cheek": 1.3, "pupil": 1.0},
	&"sleepy": {"lid": 1.8, "mouth": Vector2(0.7, 0.35), "cheek": 1.15, "pupil": 1.0},
	&"yawn": {"lid": 1.65, "mouth": Vector2(0.95, 1.8), "cheek": 1.0, "pupil": 1.0},
	&"wince": {"lid": 2.0, "mouth": Vector2(1.15, 0.2), "cheek": 1.2, "pupil": 1.0},
	&"cry": {"lid": 1.35, "mouth": Vector2(0.9, 1.45), "cheek": 1.35, "pupil": 1.1},
	&"raspberry": {"lid": 0.7, "mouth": Vector2(0.55, 1.25), "cheek": 1.4, "pupil": 1.0},
}


static func has(expression: StringName) -> bool:
	return PRESETS.has(expression)


## The preset `expression`, or neutral if unknown.
static func get_preset(expression: StringName) -> Dictionary:
	return PRESETS.get(expression, PRESETS[NEUTRAL])
