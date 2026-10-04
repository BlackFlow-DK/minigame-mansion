class_name BlobPose
extends RefCounted
## One overlay pose for the blob (an emote, a podium pose, a fidget, a social reaction, a
## throw), as targets the visuals component blends over the base animation by a weight.
## `fill()` rewrites every field in place (no allocations per frame). Model space: +X is the
## blob's left, +Z its front, y up from the feet; the body is about an ellipsoid centred at
## y 0.45 with radii 0.41 / 0.55 (the visuals push the hands out of it after blending).

## Palms forward, fingers up (left hand); the right hand uses the X-mirrored rotation.
const PALM_FORWARD_L := Basis(Vector3(0, 0, -1), Vector3(0, -1, 0), Vector3(-1, 0, 0))

## 0..1: how much this pose owns the hands.
var hands: float = 0.0
var hand_pos: PackedVector3Array = PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var hand_rot: Array[Quaternion] = [Quaternion.IDENTITY, Quaternion.IDENTITY]
## Body: hop (m up, feet follow), squash (added to the vertical stretch target), twist and
## spin (yaw, rad), lean (x forward, y toward the blob's right) blended in by lean_w, sway
## (hips sideways, m).
var hop: float = 0.0
var squash: float = 0.0
var twist: float = 0.0
var spin: float = 0.0
var lean: Vector2 = Vector2.ZERO
var lean_w: float = 0.0
var sway: float = 0.0
## Feet (x = left foot, y = right foot): lift (m), forward (m), toe pitch (rad, + = toe down).
var foot_lift: Vector2 = Vector2.ZERO
var foot_fwd: Vector2 = Vector2.ZERO
var foot_pitch: Vector2 = Vector2.ZERO
## Face: preset, a lid override (< 0 = none), a pupil offset blended in by pupil_w.
var expression: StringName = &""
var lid: float = -1.0
var pupil: Vector2 = Vector2.ZERO
var pupil_w: float = 0.0
## Comic tears (cry).
var tears: bool = false

static var _palm_l: Quaternion = PALM_FORWARD_L.get_rotation_quaternion()


func reset() -> void:
	hands = 0.0
	hop = 0.0
	squash = 0.0
	twist = 0.0
	spin = 0.0
	lean = Vector2.ZERO
	lean_w = 0.0
	sway = 0.0
	foot_lift = Vector2.ZERO
	foot_fwd = Vector2.ZERO
	foot_pitch = Vector2.ZERO
	expression = &""
	lid = -1.0
	pupil = Vector2.ZERO
	pupil_w = 0.0
	tears = false


## The palm-forward rotation for hand `sgn` (+1 left, -1 right).
static func palm(sgn: float) -> Quaternion:
	return _palm_l if sgn > 0.0 else Quaternion(_palm_l.x, -_palm_l.y, -_palm_l.z, _palm_l.w)


## Palms up (holding something overhead, stretching).
static func palm_up(sgn: float) -> Quaternion:
	return Quaternion(Vector3.BACK, -sgn * PI * 0.5)


## Mirrors a left-hand rotation for hand `sgn`.
static func mirror(q: Quaternion, sgn: float) -> Quaternion:
	return q if sgn > 0.0 else Quaternion(q.x, -q.y, -q.z, q.w)


## Fills the pose `pose_name` at `t` seconds into it (`length` = its duration). `clock` is a
## free-running time for wiggles, `rest_l` / `rest_r` the hands' rest positions, `hat_grip`
## where the left hand holds the hat brim. Unknown names leave the pose empty (hands 0).
func fill(pose_name: StringName, t: float, length: float, clock: float, rest_l: Vector3,
		rest_r: Vector3, hat_grip: Vector3) -> void:
	reset()
	var u := clampf(t / maxf(length, 0.001), 0.0, 1.0)
	match pose_name:
		&"cheer":
			var b := absf(sin(PI * t / 0.45))
			hop = 0.16 * b
			squash = 0.08 * b - 0.14 * pow(1.0 - b, 4.0)
			for i in 2:
				var sgn := _sgn(i)
				_hand(i, Vector3(sgn * 0.52, 0.74 + 0.07 * sin(clock * 13.0 + sgn * 0.9), 0.07), palm(sgn))
			expression = BlobExpressions.CHEER
		&"wave":
			lean = Vector2(0.0, 0.07 + 0.03 * sin(clock * 5.5))
			lean_w = 1.0
			_hand(0, rest_l + Vector3(0.0, -0.02, 0.05), Quaternion.IDENTITY)
			_hand(1, Vector3(-0.56, 0.8, 0.1), Quaternion(Vector3.BACK, 0.55 * sin(clock * 11.0)) * palm(-1.0))
			expression = BlobExpressions.HAPPY
		&"sad":
			lean = Vector2(0.24, 0.0)
			lean_w = 1.0
			squash = -0.1
			_hand(0, rest_l + Vector3(-0.07, -0.11, 0.08), Quaternion(Vector3.RIGHT, 0.25))
			_hand(1, rest_r + Vector3(0.07, -0.11, 0.08), Quaternion(Vector3.RIGHT, 0.25))
			expression = BlobExpressions.SAD
		&"dance":
			_dance(t)
		&"taunt":
			_taunt(t, clock)
		&"cry":
			_cry(t, length, clock)
		&"victory":
			_victory(t)
		&"clap_nod", &"clap":
			_clap(t, pose_name == &"clap_nod")
		&"sulk":
			_sulk(t)
		&"stretch":
			var s := sin(PI * u)
			for i in 2:
				var sgn := _sgn(i)
				_hand(i, Vector3(sgn * 0.36, 1.3, 0.0), palm_up(sgn))
			squash = 0.07
			lean = Vector2(-0.08, 0.07 * sin(TAU * u))
			lean_w = 1.0
			foot_pitch = Vector2(0.3, 0.3) * s
			foot_lift = Vector2(0.02, 0.02) * s
			expression = BlobExpressions.HAPPY
			lid = 1.9
		&"yawn":
			_hand(0, Vector3(0.45, 0.95, 0.0), palm_up(1.0))
			_hand(1, Vector3(-0.06, 0.55, 0.47), Quaternion(Vector3.RIGHT, -0.3))
			lean = Vector2(lerpf(-0.12, 0.04, smoothstep(0.55, 0.9, u)), 0.03)
			lean_w = 1.0
			squash = 0.04 * sin(PI * u)
			expression = BlobExpressions.YAWN
		&"scratch":
			_hand(0, rest_l, Quaternion.IDENTITY)
			_hand(1, Vector3(-0.36, 0.86 + 0.02 * sin(clock * 30.0), 0.1),
				Quaternion(Vector3.BACK, PI * 0.35))
			lean = Vector2(0.0, 0.1)
			lean_w = 1.0
			pupil = Vector2(-0.008, 0.012)
			pupil_w = 1.0
			expression = BlobExpressions.WORRIED
		&"hat":
			_hand(0, hat_grip + Vector3(0.0, 0.012 * sin(clock * 9.0), 0.02 * sin(clock * 9.0)),
				Quaternion(Vector3.BACK, -0.6))
			_hand(1, rest_r, Quaternion.IDENTITY)
			lean = Vector2(0.02, -0.07)
			lean_w = 1.0
			twist = 0.12
			pupil = Vector2(0.006, 0.014)
			pupil_w = 1.0
			expression = BlobExpressions.HAPPY
		&"tap":
			_hips()
			foot_pitch = Vector2(-0.4 * absf(sin(clock * PI * 4.4)), 0.0)
			lean = Vector2(-0.04, 0.0)
			lean_w = 1.0
			pupil = Vector2(0.012 * sin(clock * 1.7), 0.006)
			pupil_w = 1.0
			expression = BlobExpressions.NEUTRAL
			lid = 0.75
		&"wrist":
			_hand(0, Vector3(0.3, 0.47, 0.42), Quaternion(Vector3.BACK, PI * 0.5))
			_hand(1, rest_r, Quaternion.IDENTITY)
			lean = Vector2(0.1, -0.04)
			lean_w = 1.0
			twist = 0.18
			pupil = Vector2(0.014, -0.016)
			pupil_w = 1.0
			expression = BlobExpressions.NEUTRAL
		&"flinch":
			for i in 2:
				var sgn := _sgn(i)
				_hand(i, Vector3(sgn * 0.21, 0.72, 0.43), palm(sgn))
			squash = -0.15
			lean_w = 1.0  # the caller points `lean` away from the shover
			expression = BlobExpressions.WINCE
		&"wince":
			for i in 2:
				var sgn := _sgn(i)
				_hand(i, Vector3(sgn * 0.3, 0.58, 0.36), mirror(Quaternion(Vector3.BACK, 0.4), sgn))
			lean = Vector2(-0.1, 0.0)
			lean_w = 1.0
			squash = -0.04
			expression = BlobExpressions.WINCE
		&"gloat":
			_hips()
			hop = 0.07 * absf(sin(TAU * u))
			lean = Vector2(-0.07, 0.0)
			lean_w = 1.0
			expression = BlobExpressions.SMUG
		&"throw":
			_throw(u)


func _sgn(i: int) -> float:
	return 1.0 if i == 0 else -1.0


func _hand(i: int, pos: Vector3, rot: Quaternion) -> void:
	hands = 1.0
	hand_pos[i] = pos
	hand_rot[i] = rot


func _hips() -> void:
	for i in 2:
		var sgn := _sgn(i)
		_hand(i, Vector3(sgn * 0.46, 0.4, -0.06), mirror(Quaternion(Vector3.BACK, 1.1), sgn))


## A looping groove: hips sway on the beat, alternate arm pumps, alternate feet.
func _dance(t: float) -> void:
	var ph := TAU * t / 1.0
	var s := sin(ph)
	sway = 0.045 * s
	twist = 0.3 * s
	lean = Vector2(0.05, -0.12 * s)
	lean_w = 1.0
	squash = -0.06 * pow(absf(cos(ph)), 2.0)
	for i in 2:
		var sgn := _sgn(i)
		var up := 0.5 + 0.5 * s * sgn
		var low := Vector3(sgn * 0.47, 0.34, 0.2)
		var high := Vector3(sgn * 0.4, 0.98, 0.16)
		_hand(i, low.lerp(high, up), Quaternion.IDENTITY.slerp(palm(sgn), up))
	foot_lift = Vector2(0.045 * maxf(0.0, -s), 0.045 * maxf(0.0, s))
	foot_pitch = foot_lift * 6.0
	expression = BlobExpressions.HAPPY


## Belly slaps (chest out), then a raspberry with waggling hands at the temples.
func _taunt(t: float, clock: float) -> void:
	var k := exp(-pow((t - 0.2) / 0.06, 2.0)) + exp(-pow((t - 0.55) / 0.06, 2.0))
	var r := smoothstep(0.85, 0.95, t)
	for i in 2:
		var sgn := _sgn(i)
		var slap := Vector3(sgn * 0.3, 0.38, 0.36).lerp(Vector3(sgn * 0.15, 0.36, 0.45), k)
		var temple := Vector3(sgn * 0.4, 0.82, 0.2)
		var waggle := Quaternion(Vector3.BACK, sgn * 0.5 * sin(clock * 22.0)) * palm(sgn)
		_hand(i, slap.lerp(temple, r), Quaternion.IDENTITY.slerp(waggle, r))
	squash = -0.07 * k * (1.0 - r)
	lean = Vector2(-0.1, 0.0).lerp(Vector2(0.14, 0.06 * sin(clock * 9.0)), r)
	lean_w = 1.0
	expression = BlobExpressions.SMUG if r < 0.5 else BlobExpressions.RASPBERRY


## Sobbing into the hands, then arms out wailing; tears stream the whole time.
func _cry(t: float, length: float, clock: float) -> void:
	var out := smoothstep(0.5, 0.6, t / maxf(length, 0.001))
	for i in 2:
		var sgn := _sgn(i)
		var rub := Vector3(sgn * 0.2, 0.64 + 0.025 * sin(clock * 14.0 + sgn * 1.5), 0.43)
		var wail := Vector3(sgn * 0.5, 0.72 + 0.05 * sin(clock * 10.0 + sgn), 0.12)
		_hand(i, rub.lerp(wail, out), Quaternion(Vector3.RIGHT, -0.4).slerp(mirror(Quaternion(Vector3.BACK, 0.4), sgn), out))
	squash = -0.04 * absf(sin(clock * 9.0))
	lean = Vector2(0.12 + 0.03 * sin(clock * 9.0), 0.0)
	lean_w = 1.0
	expression = BlobExpressions.CRY
	tears = true


## Podium winner: two big jumps (a spin on the second), then pumping fists.
func _victory(t: float) -> void:
	var b := 0.0
	if t < 0.5:
		b = sin(PI * t / 0.5)
	elif t >= 0.6 and t < 1.1:
		b = sin(PI * (t - 0.6) / 0.5)
	if t < 1.15:
		hop = 0.24 * b
		squash = 0.08 * b - 0.12 * pow(1.0 - b, 4.0) * (1.0 - smoothstep(1.1, 1.15, t))
		spin = TAU * smoothstep(0.6, 1.1, t)
		for i in 2:
			var sgn := _sgn(i)
			_hand(i, Vector3(sgn * 0.5, 0.82, 0.08), palm(sgn))
	else:
		var p := TAU * (t - 1.15) / 0.6
		hop = 0.045 * absf(sin(p))
		squash = -0.04 * absf(cos(p))
		for i in 2:
			var sgn := _sgn(i)
			var pump := maxf(0.0, sin(p + (0.0 if sgn > 0.0 else PI)))
			_hand(i, Vector3(sgn * 0.4, 0.74 + 0.22 * pump, 0.15), Quaternion(Vector3.RIGHT, -0.3 * pump))
	expression = BlobExpressions.CHEER


## Clapping in front of the belly; `nod` adds happy nods (2nd/3rd place).
func _clap(t: float, nod: bool) -> void:
	var rate := 2.5 if nod else 1.6
	var c := 0.5 + 0.5 * cos(TAU * t * rate)
	var spread := 0.14 if nod else 0.09
	for i in 2:
		var sgn := _sgn(i)
		_hand(i, Vector3(sgn * (0.075 + spread * c), 0.42, 0.45), mirror(Quaternion(Vector3.UP, 0.25), sgn))
	if nod:
		lean = Vector2(0.06 + 0.07 * maxf(0.0, sin(TAU * t / 0.6)), 0.0)
		expression = BlobExpressions.HAPPY
	else:
		lean = Vector2(0.03, 0.0)
		expression = BlobExpressions.NEUTRAL
	lean_w = 1.0


## Last place: slumped, arms hanging, scuffing one foot, looking at the floor.
func _sulk(t: float) -> void:
	lean = Vector2(0.3, 0.06)
	lean_w = 1.0
	squash = -0.07
	twist = -0.15
	for i in 2:
		var sgn := _sgn(i)
		_hand(i, Vector3(sgn * 0.27, 0.18, 0.3), Quaternion(Vector3.RIGHT, 0.5))
	var s := sin(TAU * t / 1.5)
	foot_fwd = Vector2(0.0, 0.09 * s)
	foot_pitch = Vector2(0.0, 0.2 * s)
	foot_lift = Vector2(0.0, 0.012 * maxf(0.0, cos(TAU * t / 1.5)))
	pupil = Vector2(0.0, -0.016)
	pupil_w = 1.0
	expression = BlobExpressions.SAD


## Wind up overhead, fling forward, follow through (`u` 0..1).
func _throw(u: float) -> void:
	var wind := 1.0 - smoothstep(0.3, 0.45, u)
	var follow := smoothstep(0.55, 0.85, u)
	for i in 2:
		var sgn := _sgn(i)
		var back := Vector3(sgn * 0.3, 0.9, -0.3)
		var fling := Vector3(sgn * 0.18, 0.85, 0.55)
		var through := Vector3(sgn * 0.22, 0.55, 0.5)
		var p := fling.lerp(back, wind).lerp(through, follow)
		_hand(i, p, palm_up(sgn).slerp(palm(sgn), 1.0 - wind))
	lean = Vector2(-0.15 * wind + 0.3 * (1.0 - wind) * (1.0 - follow) + 0.15 * follow, 0.0)
	lean_w = 1.0
	squash = 0.05 * (1.0 - wind) * (1.0 - follow) - 0.04 * wind
	expression = BlobExpressions.EFFORT
