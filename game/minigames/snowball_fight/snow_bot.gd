class_name SnowBot
extends RefCounted
## Snowball Fight's thrower AI for one blob, run on that blob's authority (the host for bots).
##
## Why it exists: the generic BotBrain walks to `Minigame.get_bot_goal` and presses action only to
## shove someone right in front of it, and it cannot aim. So the minigame drives the scoop and the
## throw itself, through exactly the path a human's press takes (`SnowballFight.press` /
## `throw_at`: a request to the host, which validates it). The brain still does the walking:
## `goal()` (answered through get_bot_goal) picks cover from an armed enemy while empty-handed,
## a spot at fighting range off to one side of the target while armed (the side flips now and
## then: strafing), the ammo pile when it is near; `SnowballFight.is_safe` keeps it off cover.
##
## Perception is re-made every THINK seconds (slower for low skill): the target is the nearest
## enemy a ball would reach right now (`SnowArc.clear_shot`, so cover hides), the threat the
## nearest armed enemy with a clear shot at this blob. Skill (from the bot's BotBrain, else rolled)
## sets reaction, aim error and lead. All randomness comes from its own seeded generator.

## Seconds between perception updates (low skill, high skill).
const THINK := Vector2(0.32, 0.14)
## Seconds a target must be in sight before the throw.
const REACT := Vector2(0.55, 0.18)
## Aim error (degrees, about this much at most) and how much of the target's motion it leads.
const AIM_ERROR_DEG := Vector2(15.0, 3.5)
const LEAD := Vector2(0.15, 0.85)
## Extra seconds between two throws of one bot (random in 0.7..1.3 of this).
const THROW_GAP := Vector2(0.9, 0.35)
## Seconds after its last ball before it scoops the next.
const SCOOP_DELAY := Vector2(0.45, 0.12)
## Unarmed with an armed enemy this near and in the clear: take cover first...
const THREAT_RANGE := 8.5
## ...for this long at most, then scoop anyway.
const BRAVE_TIME := Vector2(0.7, 1.5)
## Preferred distance to the target while armed (m).
const FIGHT_DIST := Vector2(7.5, 6.0)
## Goes for the ammo pile when it is nearer than this (m).
const PILE_GREED := 8.0

var game: SnowballFight
var player: Player
var skill: float = 0.6
## Throws this AI asked for (the host may still refuse one).
var throws: int = 0

var _rng := RandomNumberGenerator.new()
var _think: float = 0.0
var _target: Player = null
var _target_seen: float = 0.0
var _react: float = 0.3
var _threat: Player = null
var _threat_time: float = 0.0
var _gap: float = 0.0
var _scoop_wait: float = 0.0
var _strafe: float = 1.0
var _strafe_timer: float = 1.0
var _armed: bool = false


func _init(owner_game: SnowballFight, p: Player, seed_value: int) -> void:
	game = owner_game
	player = p
	_rng.seed = seed_value
	var brain := BotBrain.of(p)
	skill = brain.skill if brain else _rng.randf_range(0.35, 0.95)
	_strafe = 1.0 if _rng.randf() < 0.5 else -1.0
	_strafe_timer = _rng.randf_range(0.8, 2.0)
	_think = _rng.randf_range(0.0, _lerp(THINK))


## One physics tick on the authority.
func tick(delta: float) -> void:
	if not is_instance_valid(player) or not player.alive or player.frozen:
		_target = null
		_threat = null
		_target_seen = 0.0
		_threat_time = 0.0
		return
	var slot := player.slot
	_think -= delta
	_gap -= delta
	_scoop_wait -= delta
	_strafe_timer -= delta
	if _strafe_timer <= 0.0:
		_strafe_timer = _rng.randf_range(0.9, 2.2)
		if _rng.randf() < 0.6:
			_strafe = -_strafe
		game.request_bot_rethink(slot)
	var armed := game.ammo_of(slot) > 0
	if armed != _armed:
		_armed = armed
		_scoop_wait = _lerp(SCOOP_DELAY) * _rng.randf_range(0.7, 1.3)
		_target_seen = 0.0
		game.request_bot_rethink(slot)
	if _think <= 0.0:
		_think = _lerp(THINK) * _rng.randf_range(0.8, 1.2)
		_perceive()
	if player.control_locked:
		_target_seen = 0.0
		return
	if not armed:
		if game.is_scooping(slot):
			return
		if game.pile_active and _pile_distance() < PILE_GREED * 0.6:
			return  # run for the pile instead
		_threat_time = _threat_time + delta if _threat != null else 0.0
		if _scoop_wait <= 0.0 and (_threat == null or _threat_time > _lerp(BRAVE_TIME)):
			game.press(player)
		return
	if not game.can_throw(slot) or _target == null:
		_target_seen = 0.0
		return
	_target_seen += delta
	if _target_seen >= _react and _gap <= 0.0:
		if game.throw_at(player, _aim(_target)):
			throws += 1
			_gap = _lerp(THROW_GAP) * _rng.randf_range(0.7, 1.3)
			_target_seen = 0.0
			_react = _lerp(REACT) * _rng.randf_range(0.6, 1.0)


## Where the brain should walk now (asked through SnowballFight.get_bot_goal).
func goal() -> Vector3:
	var pos := player.global_position
	var slot := player.slot
	var ammo := game.ammo_of(slot)
	if game.pile_active and ammo < 2 and _pile_distance() < PILE_GREED:
		return SnowYard.PILE_AT
	if ammo <= 0:
		if _threat != null and is_instance_valid(_threat) and _threat.alive:
			return _cover_from(_threat.global_position, pos)
		return _walkable_near(pos + _rand_flat(1.4), pos)
	var foe := _target if _target != null and is_instance_valid(_target) and _target.alive else _nearest_enemy()
	if foe == null:
		return _walkable_near(pos + _rand_flat(2.5), pos)
	var fp := foe.global_position
	var away := Vector3(pos.x - fp.x, 0.0, pos.z - fp.z)
	if away.length_squared() < 0.01:
		away = _rand_flat(1.0)
	away = away.normalized().rotated(Vector3.UP, _strafe * _rng.randf_range(0.35, 0.75))
	return _walkable_near(fp + away * _lerp(FIGHT_DIST), pos)


func _perceive() -> void:
	var me := player.global_position
	var reach := SnowArc.reach() + SnowArc.RELEASE_FWD
	var best: Player = null
	var best_score := INF
	var threat: Player = null
	var threat_d := THREAT_RANGE
	for o in game.players:
		if o == player or not is_instance_valid(o) or not o.alive or game.is_snowed(o.slot) or o.is_extra:
			continue
		var d := Vector2(o.global_position.x - me.x, o.global_position.z - me.z).length()
		var armed := game.ammo_of(o.slot) > 0
		if d > reach and (not armed or d > threat_d):
			continue
		if not SnowArc.clear_shot(me, o.global_position):
			continue
		if d <= reach:
			var score := d * (0.8 if o == _target else 1.0)
			if score < best_score:
				best_score = score
				best = o
		if armed and d < threat_d:
			threat_d = d
			threat = o
	if best != _target:
		_target = best
		_target_seen = 0.0
		_react = _lerp(REACT) * _rng.randf_range(0.8, 1.25)
	_threat = threat


## Throw direction at `target`: leads its motion a little, with skill-based error.
func _aim(target: Player) -> Vector3:
	var from := player.global_position
	var to := target.global_position
	var fly := Vector2(to.x - from.x, to.z - from.z).length() / SnowArc.SPEED
	var lead := Vector3(target.velocity.x, 0.0, target.velocity.z) * fly * _lerp(LEAD)
	var dir := SnowArc.flat_dir(to + lead - from)
	var err := deg_to_rad(_lerp(AIM_ERROR_DEG)) * (_rng.randf_range(-1.0, 1.0) + _rng.randf_range(-1.0, 1.0)) * 0.5
	return dir.rotated(Vector3.UP, err)


## A walkable spot behind the cover piece that best hides this blob from `threat`.
func _cover_from(threat: Vector3, pos: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_score := INF
	for piece in SnowYard.cover_pieces():
		var c: Vector2 = piece[0]
		var hx: float = piece[1]
		var hz: float = piece[2]
		var d := Vector2(c.x - threat.x, c.y - threat.z)
		if d.length_squared() < 0.01:
			continue
		d = d.normalized()
		var extent := absf(d.x) * hx + absf(d.y) * hz + 0.8
		var spot := Vector3(c.x + d.x * extent, 0.0, c.y + d.y * extent)
		if not SnowYard.walkable(spot):
			continue
		var score := Vector2(spot.x - pos.x, spot.z - pos.z).length()
		if score > 9.0:
			continue
		if Vector2(spot.x - threat.x, spot.z - threat.z).length() < 3.0:
			score += 4.0
		if score < best_score:
			best_score = score
			best = spot
	if best != Vector3.INF:
		return best
	var away := SnowArc.flat_dir(pos - threat)
	return _walkable_near(pos + away * 3.0, pos)


func _nearest_enemy() -> Player:
	var me := player.global_position
	var best: Player = null
	var best_d := INF
	for o in game.players:
		if o == player or not is_instance_valid(o) or not o.alive or game.is_snowed(o.slot) or o.is_extra:
			continue
		var d := me.distance_squared_to(o.global_position)
		if d < best_d:
			best_d = d
			best = o
	return best


func _pile_distance() -> float:
	var p := player.global_position
	return Vector2(p.x - SnowYard.PILE_AT.x, p.z - SnowYard.PILE_AT.z).length()


## `want` if blobs can stand there, else the nearest walkable point around it, else `fallback`.
func _walkable_near(want: Vector3, fallback: Vector3) -> Vector3:
	want.y = 0.0
	want.x = clampf(want.x, -SnowYard.HALF_X + 0.8, SnowYard.HALF_X - 0.8)
	want.z = clampf(want.z, -SnowYard.HALF_Z + 0.8, SnowYard.HALF_Z - 0.8)
	if SnowYard.walkable(want):
		return want
	for r: float in [0.8, 1.6, 2.6]:
		for k in 8:
			var c := want + Vector3(cos(TAU * k / 8.0), 0.0, sin(TAU * k / 8.0)) * r
			if SnowYard.walkable(c):
				return c
	return Vector3(fallback.x, 0.0, fallback.z)


func _rand_flat(radius: float) -> Vector3:
	var a := _rng.randf() * TAU
	return Vector3(cos(a), 0.0, sin(a)) * radius * _rng.randf_range(0.5, 1.0)


func _lerp(range_: Vector2) -> float:
	return lerpf(range_.x, range_.y, skill)
