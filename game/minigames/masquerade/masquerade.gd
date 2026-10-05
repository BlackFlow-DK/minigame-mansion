class_name Masquerade
extends Minigame
## Masquerade (hidden identity): a candle-lit ballroom where every blob looks the same: one
## shared look (colours, the masq_mask, no hats or wearables, normal size), no name tags, no
## rings, among 20 identical NPC dancers (14 with 2-3 players) who stroll and waltz. You know
## which one is you only by steering it (and a faint ring under you for the first seconds).
## Find the real players and shove them; do not shove the dancers.
## - A landed shove on a real player UNMASKS them: their true look pops back (poof, a
##   spotlight), they are out a moment later (`knock_out`, reason `unmasked`), shover +2.
## - A landed shove on an NPC: the shover is stunned 1.5 s, flashes their true colours for
##   1.5 s (everyone watching learns who they are) and loses 1 point (never below 0); the NPC
##   tumbles and recovers.
## - Shove cooldown 1.2 s. Humans stroll (full stick = the fastest NPC stroll); NPCs now and
##   then fake a shove at each other (shove_started, no hit), so the motion alone gives
##   nothing away.
## - End: one unfound player left, or 75 s. Ranking: survivors first (at time-out tied groups by
##   points, most first), then the unmasked, last unmasked first. HUD counter = points.
##
## Host decides (hits, points, who is out) and tells every peer with reliable call_local RPCs.
## The disguise runs on every peer (MasqDisguise: public cosmetics/size/name-tag APIs only) and
## is released on every exit path: round over (the `finished` RPC), stage clear or the minigame
## leaving the tree (the Disguise node's _exit_tree); a leaver's node goes with them.
## Roster bots: MasqBots keeps their brains in an NPC mode and decides suspicion hunts; the brains
## walk, face and shove through the generic hooks (bot_wants_action / bot_aim / bot_action_reach).
## Dev args (after `--`): `--masq-demo-unmask=<s>` (slot 1 is unmasked by slot 0 at s seconds),
## `--masq-demo-wrong=<s>` (slot 2 shoves the nearest NPC at s seconds) and `--masq-closeup`
## (the camera looks at slot 0's mask): screenshots only.

## Every peer: `victim` was unmasked by `shover` (who now has `shover_points`).
signal unmasked(victim_slot: int, shover_slot: int)
## Every peer: `shover` shoved the NPC `npc_slot`.
signal wrong_shove(shover_slot: int, npc_slot: int)
## Every peer: the round is over; `survivors` are the unfound players.
signal round_over(survivors: Array)

const GARLAND_SCENE: PackedScene = preload("res://assets/models/props/masq_garland.glb")
const ROSETTE_SCENE: PackedScene = preload("res://assets/models/props/masq_rosette.glb")
const MASK_SCENE: PackedScene = preload("res://assets/models/props/masq_mask.glb")
const ENV_DIR := "res://assets/models/env/"

# --- Room ----------------------------------------------------------------------------------
const HALF_X := 10.0
const BACK_Z := -8.0
const FRONT_Z := 8.0
## Blob centres stay inside this floor rectangle (bots and NPCs treat it as safe).
const SAFE_MIN := Vector2(-8.4, -5.8)
const SAFE_MAX := Vector2(8.4, 6.8)
## Dance circles of the NPCs (and dancing bots): one in each quarter of the floor and one in
## the middle, so the crowd fills the room (a circle reaches ~3 m out, still on the floor).
## NPC dancers are dealt round-robin over them.
const DANCE_CENTERS: Array[Vector3] = [Vector3(-5.2, 0.0, -2.6), Vector3(5.2, 0.0, -2.6), Vector3(-5.2, 0.0, 3.6),
	Vector3(5.2, 0.0, 3.6), Vector3(0.0, 0.0, 0.5)]
const FALL_Y := -5.0

# --- Rules (host) ----------------------------------------------------------------------------
@export var extras_count: int = 20
## With 2-3 players.
@export var extras_count_small: int = 14
@export var shove_cooldown: float = 1.2
## Humans' max speed as a share of the normal one: full stick = the fastest NPC stroll.
@export var human_speed_factor: float = 0.5
@export var unmask_points: int = 2
@export var wrong_penalty: int = 1
@export var wrong_stun: float = 1.5
@export var wrong_flash: float = 1.5
## Seconds an unmasked player stands revealed before they are out.
@export var reveal_hold: float = 1.2
## Seconds after GO the local player's "that's you" ring lasts.
@export var you_ring_time: float = 2.0
@export var end_grace: float = 2.0
## Extras built per frame during the intro (host; Stage.spawn_extras batch).
@export var extras_per_frame: int = 4
## NPC fake shoves: chance per NPC per second while someone stands in front of it.
@export var fake_shove_rate: float = 0.06
## Share of NPCs that dance (the rest wander).
@export var dance_share: float = 0.4
## Roster bots' hunt eagerness (MasqBots.hunt_chance and hunt_suspicion_gain) by player count
## (index = players; 8+ use the last). Calmer with 2-3 players: one shove ends a duel (at full
## eagerness 44 % of 2-player rounds were over in under 20 s). Full eagerness from 4 up: the
## old big-round calming (0.69 at 8) let half the 8-player rounds run to the 75 s limit.
## Bots, 48 rounds per count: docs/balance-v03-b.md.
@export var bot_hunt_scale: PackedFloat32Array = PackedFloat32Array([1.0, 1.0, 0.55, 0.75, 1.0, 1.0, 1.0, 1.0, 1.0])

## The music director plays this for the round (a waltz).
var music_track := &"lobby_waltz"
## Bot brain hint: never chase on their own (MasqBots decides hunts; the brain's action hooks shove).
var bot_aggression_scale: float = 0.0
## Every MasqBots made for this round registers here (the host's, a dev check's own); the bot
## hooks ask the one that drives the player.
var bot_drivers: Array = []
## Tests: when >= 0, the next Masquerade seeds `rng` and `bot_rng` from it in _ready (then it
## goes back to -1), so a whole round (placement, NPC modes, bots) replays.
static var next_seed: int = -1
## Host randomness (placement, NPC modes). Tests may seed it.
var rng := RandomNumberGenerator.new()
## Host randomness for bots and fake shoves. Tests may seed it.
var bot_rng := RandomNumberGenerator.new()

## Every peer: slot -> points (HUD counter).
var points: Dictionary[int, int] = {}
## Every peer: unmasked slots.
var found: Dictionary[int, bool] = {}
## Every peer: [victim, shover] per unmasking, in order.
var unmask_log: Array = []
## Every peer: [shover, npc] per wrong shove, in order.
var wrong_log: Array = []
## Every peer: true once the round is over.
var over: bool = false
## Host: seconds of play since _start.
var elapsed: float = 0.0
## Every peer: the disguise of this round.
var disguise: MasqDisguise = null
## Host: the bot driver.
var bots: MasqBots = null

var _dancers: int = 0                      # host: NPC dancers dealt to circles so far
var _dance_offset: int = 0                 # host: the circle the first dancer got
var _out_order: Array[int] = []            # host: unmasked slots in order
var _pending_out: Dictionary[int, float] = {}  # host: slot -> seconds until knock_out
var _running: bool = false
var _fake_clock: float = 0.0
var _ring: MeshInstance3D = null
var _ring_left: float = -1.0
var _ring_player: Player = null
var _demo_unmask: float = -1.0
var _demo_wrong: float = -1.0
var _closeup: bool = false
var _stage_ref: Stage = null

@onready var _camera: ArenaCamera = get_node_or_null(^"ArenaCamera") as ArenaCamera


func _ready() -> void:
	rng.randomize()
	bot_rng.randomize()
	if next_seed >= 0:
		rng.seed = next_seed
		bot_rng.seed = next_seed * 31 + 7
		next_seed = -1
	disguise = MasqDisguise.new()
	add_child(disguise)
	_build_room()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--masq-demo-unmask="):
			_demo_unmask = arg.trim_prefix("--masq-demo-unmask=").to_float()
		elif arg.begins_with("--masq-demo-wrong="):
			_demo_wrong = arg.trim_prefix("--masq-demo-wrong=").to_float()
		elif arg == "--masq-closeup":
			_closeup = true


# --- Minigame flow ---------------------------------------------------------------------------

func _setup(setup_players: Array[Player]) -> void:
	var stage := _stage()
	for p in setup_players:
		points[p.slot] = 0
		var shove := p.get_component(&"shove") as ShoveComponent
		if shove:
			shove.cooldown = shove_cooldown
		var move := p.get_component(&"movement") as MovementComponent
		if move and not p.is_bot:
			move.max_speed *= human_speed_factor  # frozen: this is the base value
		disguise.hold(p)
	if stage and not stage.extras_spawned.is_connected(_on_extras_spawned):
		stage.extras_spawned.connect(_on_extras_spawned)
	if stage:
		for x in stage.extras:
			disguise.hold(x)
	if _is_host() and stage:
		_host_setup(stage, setup_players)
	_make_you_ring(setup_players)


func _host_setup(stage: Stage, setup_players: Array[Player]) -> void:
	var count := extras_count_small if setup_players.size() <= 3 else extras_count
	var spots := scatter(setup_players.size() + count)
	# Built a few per frame through the intro (Stage batches: 20 at once stall a peer long
	# enough to trip the network timeout while the round loads); brains in _on_extras_spawned.
	var loadouts: Array[Dictionary] = []
	var xforms: Array[Transform3D] = []
	for i in count:
		loadouts.append(MasqDisguise.LOOK.duplicate())
		xforms.append(spots[setup_players.size() + i])
	stage.spawn_extras(count, loadouts, xforms, extras_per_frame)
	# Players stand among the crowd, not on the (well-known) spawn markers.
	var slots: Array = []
	var places: Array = []
	for i in setup_players.size():
		slots.append(setup_players[i].slot)
		places.append(spots[i])
	_rpc_places.rpc(slots, places)


## Host: NPC brains for new extras: a share dance (dealt round-robin over the circles, so the
## crowd spreads over the floor), the rest wander from where they stand.
func _configure_crowd(spawned: Array[Player]) -> void:
	for x in spawned:
		var brain := BotBrain.of(x)
		if brain == null:
			continue
		var dance := bot_rng.randf() < dance_share
		var seed_value := bot_rng.randi()
		var center := Vector3.INF
		if dance:
			var r := bot_rng.randi()
			if _dancers == 0:
				_dance_offset = r % DANCE_CENTERS.size()
			center = DANCE_CENTERS[(_dance_offset + _dancers) % DANCE_CENTERS.size()]
			_dancers += 1
		brain.configure_extra(&"dance" if dance else &"wander", seed_value, center)


func _start() -> void:
	var stage := _stage()
	if _is_host() and stage and stage.is_spawning_extras():
		stage.flush_extras()  # a very short intro (tests, sandbox): all now
	elapsed = 0.0
	_running = true
	for p in players:
		RoundUI.push_counter(p.slot, points.get(p.slot, 0))
	if _ring:
		_ring_left = you_ring_time
	if _closeup and _camera and not players.is_empty():
		# Dev: look at one masked blob up close (screenshots of the mask).
		_camera.fixed_focus = players[0].global_position + Vector3(0.0, 0.6, 0.0)
		_camera.fixed_distance = 2.6
		_camera.pitch_degrees = 18.0
		_camera.yaw_degrees = rad_to_deg(atan2(players[0].facing.x, players[0].facing.z))
	if not _is_host():
		return
	if not finished.is_connected(_on_finished):
		finished.connect(_on_finished)
	bots = MasqBots.new(self, bot_rng, DANCE_CENTERS)
	var calm := bot_hunt_scale_for(players.size())
	bots.hunt_chance *= calm
	bots.hunt_suspicion_gain *= calm
	for p in players:
		p.shove_hit.connect(_on_shove_hit.bind(p))
		if p.is_bot:
			var brain := BotBrain.of(p)
			if brain:
				bots.add(p, brain)


func _host_tick(delta: float) -> void:
	if is_finished():
		return
	elapsed += delta
	for p in players:
		if is_instance_valid(p) and p.alive and p.global_position.y < FALL_Y and not found.has(p.slot):
			_put_out(p, &"fell")
	if bots:
		bots.tick(delta)
	_fake_shoves(delta)
	_demo()
	if is_finished():
		return
	if players.size() >= 2 and unfound().size() <= 1:
		_finish_round()
	elif time_limit > 0.0 and elapsed >= time_limit:
		_finish_round()


## The players still in disguise and in the round.
func unfound() -> Array[Player]:
	var out: Array[Player] = []
	for p in players:
		if is_instance_valid(p) and p.alive and not found.has(p.slot):
			out.append(p)
	return out


## Host: the ranking now: unfound players first (grouped by points, most first; equal points
## share a place), then the unmasked, last unmasked first, then anyone else (leavers).
func compute_ranking() -> Array:
	var ranking: Array = []
	var by_points: Dictionary = {}
	for p in unfound():
		var pts: int = points.get(p.slot, 0)
		if not by_points.has(pts):
			by_points[pts] = []
		(by_points[pts] as Array).append(p.slot)
	var levels: Array = by_points.keys()
	levels.sort()
	levels.reverse()
	for pts: int in levels:
		var group: Array = by_points[pts]
		group.sort()
		ranking.append(group)
	var placed: Dictionary = {}
	for g: Array in ranking:
		for s: int in g:
			placed[s] = true
	for i in range(_out_order.size() - 1, -1, -1):
		if not placed.has(_out_order[i]):
			ranking.append(_out_order[i])
			placed[_out_order[i]] = true
	for i in range(knocked_out.size() - 1, -1, -1):
		if not placed.has(knocked_out[i]):
			ranking.append(knocked_out[i])
			placed[knocked_out[i]] = true
	for p in players:
		if is_instance_valid(p) and not placed.has(p.slot):
			ranking.append(p.slot)
	return ranking


func _finish_round() -> void:
	if is_finished():
		return
	finish(compute_ranking(), end_grace)


## Where a bot wants to be: a stroll target like an NPC's (within 4 m, on the floor).
func get_bot_goal(player: Player) -> Vector3:
	var from := player.global_position if player else Vector3.ZERO
	for i in 6:
		var off := Vector2.RIGHT.rotated(bot_rng.randf() * TAU) * 4.0 * sqrt(bot_rng.randf())
		var c := from + Vector3(off.x, 0.0, off.y)
		if is_safe(c):
			return c
	return Vector3(clampf(from.x, SAFE_MIN.x, SAFE_MAX.x), 0.0, clampf(from.z, SAFE_MIN.y, SAFE_MAX.y))


## BotBrain hook: a hunting bot closes in, faces its target and shoves.
func bot_wants_action(player: Player) -> bool:
	var d := _driver_of(player)
	return d != null and d.wants_action(player)


## BotBrain hook: the hunted blob.
func bot_aim(player: Player) -> Vector3:
	var d := _driver_of(player)
	return d.aim(player) if d else Vector3.ZERO


## BotBrain hook: close in this far before facing and shoving.
func bot_action_reach() -> float:
	return MasqBots.SHOVE_DIST


## BotBrain hook: no faster than the shove cooldown.
func bot_action_cooldown() -> float:
	return shove_cooldown


func _driver_of(p: Player) -> MasqBots:
	for d: Variant in bot_drivers:
		if d is MasqBots and (d as MasqBots).drives(p):
			return d
	return null


## Bot hunt eagerness for `count` players (bot_hunt_scale).
func bot_hunt_scale_for(count: int) -> float:
	if bot_hunt_scale.is_empty():
		return 1.0
	return bot_hunt_scale[clampi(count, 0, bot_hunt_scale.size() - 1)]


## Safe = on the dance floor, inside the room.
func is_safe(pos: Vector3) -> bool:
	return pos.x >= SAFE_MIN.x and pos.x <= SAFE_MAX.x and pos.z >= SAFE_MIN.y and pos.z <= SAFE_MAX.y \
		and pos.y > -1.0


## Host (tests): drives `p` (e.g. the local human) with `brain` like a roster bot, at bot speed.
func drive_with_bot(p: Player, brain: BotBrain) -> void:
	if bots == null:
		return
	var move := p.get_component(&"movement") as MovementComponent
	if move and not p.is_bot:
		var size := p.get_component(&"size") as SizeComponent
		move.max_speed = (size.base_of(&"movement", &"max_speed") if size else move.max_speed) / human_speed_factor
	bots.add(p, brain)


## `count` spots on the floor at least 1.2 m apart (host rng), facing anywhere.
func scatter(count: int) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var pts: Array[Vector3] = []
	var gap := 1.25
	var tries := 0
	while pts.size() < count:
		tries += 1
		if tries > 4000:
			gap *= 0.85
			tries = 0
		var c := Vector3(rng.randf_range(SAFE_MIN.x + 0.4, SAFE_MAX.x - 0.4), 0.0,
			rng.randf_range(SAFE_MIN.y + 0.4, SAFE_MAX.y - 0.4))
		var ok := true
		for q in pts:
			if Vector2(q.x - c.x, q.z - c.z).length() < gap:
				ok = false
				break
		if ok:
			pts.append(c)
	for q in pts:
		var yaw := rng.randf() * TAU
		out.append(Transform3D(Basis(Vector3.UP, yaw), q))
	return out


# --- Host: shoves -------------------------------------------------------------------------------

func _on_shove_hit(victim_slot: int, shover: Player) -> void:
	if is_finished() or not _running or not is_instance_valid(shover) or not shover.alive \
			or found.has(shover.slot):
		return
	var stage := _stage()
	var victim := stage.get_body(victim_slot) if stage else null
	if victim == null or not is_instance_valid(victim):
		return
	if Stage.is_extra_slot(victim_slot):
			_wrong(shover, victim)
	elif players.has(victim) and victim.alive and not found.has(victim_slot):
		_unmask(victim, shover)


func _unmask(victim: Player, shover: Player) -> void:
	points[shover.slot] = int(points.get(shover.slot, 0)) + unmask_points
	_out_order.append(victim.slot)
	_pending_out[victim.slot] = reveal_hold
	_rpc_unmask.rpc(victim.slot, shover.slot, points[shover.slot])
	request_bot_rethink()
	if players.size() >= 2 and unfound().size() <= 1:
		_finish_round()


func _wrong(shover: Player, npc: Player) -> void:
	points[shover.slot] = maxi(0, int(points.get(shover.slot, 0)) - wrong_penalty)
	_rpc_wrong.rpc(shover.slot, npc.slot, points[shover.slot])


## Out now: knock_out while the round runs (it records the order), else a plain eliminate.
func _put_out(p: Player, reason: StringName) -> void:
	if not is_instance_valid(p) or not p.alive:
		return
	if is_finished():
		p.eliminate(reason)
	else:
		if not _out_order.has(p.slot):
			_out_order.append(p.slot)
		found[p.slot] = true
		knock_out(p, reason)


func _physics_process(delta: float) -> void:
	# Host: the unmasked leave after their reveal (also during the end grace).
	if _pending_out.is_empty() or not _is_host():
		return
	for slot: int in _pending_out.keys():
		_pending_out[slot] = float(_pending_out[slot]) - delta
		if float(_pending_out[slot]) <= 0.0:
			_pending_out.erase(slot)
			var stage := _stage()
			var p := stage.get_player(slot) if stage else null
			if p and is_instance_valid(p) and p.alive:
				if is_finished():
					p.eliminate(&"unmasked")
				else:
					knock_out(p, &"unmasked")


## NPCs now and then shove at a neighbour in front of them: the motion only, nothing hits.
func _fake_shoves(delta: float) -> void:
	_fake_clock += delta
	if _fake_clock < 0.25:
		return
	var dt := _fake_clock
	_fake_clock = 0.0
	var stage := _stage()
	if stage == null:
		return
	var bodies: Array[Player] = []
	bodies.append_array(players)
	bodies.append_array(stage.extras)
	for x in stage.extras:
		if not is_instance_valid(x) or not x.alive or x.control_locked or x.frozen:
			continue
		if bot_rng.randf() >= fake_shove_rate * dt:
			continue
		var f := Vector2(x.facing.x, x.facing.z).normalized()
		for o in bodies:
			if o == x or not is_instance_valid(o) or not o.alive:
				continue
			var to := Vector2(o.global_position.x - x.global_position.x, o.global_position.z - x.global_position.z)
			var d := to.length()
			# Just out of reach (a real shove reaches 1.3 m): a near miss, never a hit.
			if d > 1.45 and d < 2.2 and f.dot(to / d) > 0.8:
				x.emit_event(&"shove_started")
				break


func _demo() -> void:
	if _demo_unmask > 0.0 and elapsed >= _demo_unmask and players.size() >= 2:
		_demo_unmask = -1.0
		if players[1].alive and not found.has(players[1].slot):
			_unmask(players[1], players[0])
	if _demo_wrong > 0.0 and elapsed >= _demo_wrong and players.size() >= 3:
		_demo_wrong = -1.0
		var stage := _stage()
		var best: Player = null
		for x in stage.extras:
			if best == null or x.global_position.distance_to(players[2].global_position) < best.global_position.distance_to(players[2].global_position):
				best = x
		if best:
			_wrong(players[2], best)


func _on_finished(_ranking: Array[int]) -> void:
	var survivors: Array = []
	for p in unfound():
		survivors.append(p.slot)
	_rpc_round_over.rpc(survivors)


# --- RPCs (host -> every peer) ---------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_places(slots: Array, places: Array) -> void:
	var stage := _stage()
	if stage == null:
		return
	for i in mini(slots.size(), places.size()):
		var p := stage.get_player(int(slots[i]))
		if p and is_instance_valid(p):
			p.place_at(places[i] as Transform3D)


@rpc("authority", "call_local", "reliable")
func _rpc_unmask(victim_slot: int, shover_slot: int, shover_points: int) -> void:
	found[victim_slot] = true
	points[shover_slot] = shover_points
	unmask_log.append([victim_slot, shover_slot])
	RoundUI.push_counter(shover_slot, shover_points)
	var stage := _stage()
	var victim := stage.get_player(victim_slot) if stage else null
	var shover := stage.get_player(shover_slot) if stage else null
	if victim and is_instance_valid(victim):
		victim.frozen = true
		disguise.release(victim)
		var at := victim.global_position
		var fx := victim.get_component(&"fx")
		var colour: Color = fx.call(&"primary_color") if fx and fx.has_method(&"primary_color") else Color.WHITE
		Fx.play(&"poof", at + Vector3.UP * 0.6, colour)
		Fx.play(&"confetti", at + Vector3.UP * 1.2)
		_spotlight(at)
		var visuals := victim.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"sad")
		if _camera:
			_camera.add_shake(0.25)
		RoundUI.push_banner("%s unmasked %s!" % [_name_of(shover, shover_slot), _name_of(victim, victim_slot)], 1.8)
	unmasked.emit(victim_slot, shover_slot)


@rpc("authority", "call_local", "reliable")
func _rpc_wrong(shover_slot: int, npc_slot: int, shover_points: int) -> void:
	points[shover_slot] = shover_points
	wrong_log.append([shover_slot, npc_slot])
	RoundUI.push_counter(shover_slot, shover_points)
	var stage := _stage()
	var shover := stage.get_player(shover_slot) if stage else null
	if shover and is_instance_valid(shover):
		disguise.flash(shover, wrong_flash)
		if shover.is_authority():
			_stun(shover)
		Fx.play(&"hit_stars", shover.global_position + Vector3.UP * 1.1)
		Sfx.play(&"hit_bonk", shover.global_position)
	wrong_shove.emit(shover_slot, npc_slot)


@rpc("authority", "call_local", "reliable")
func _rpc_round_over(survivors: Array) -> void:
	over = true
	_running = false
	disguise.release_players()
	var stage := _stage()
	for s: Variant in survivors:
		var p := stage.get_player(int(s)) if stage else null
		if p == null or not is_instance_valid(p) or not p.alive:
			continue
		var fx := p.get_component(&"fx")
		var colour: Color = fx.call(&"primary_color") if fx and fx.has_method(&"primary_color") else Color.WHITE
		Fx.play(&"poof", p.global_position + Vector3.UP * 0.6, colour)
		Fx.play(&"confetti", p.global_position + Vector3.UP * 1.3)
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"cheer", true)
	RoundUI.push_banner("The masks come off!", 1.8)
	round_over.emit(survivors)


# --- Every peer: helpers ------------------------------------------------------------------------

## The wrong-shove penalty on the shover's own peer: a `wrong_stun` stun plus a small recoil, so
## the usual stunned / got_hit events and visuals run.
func _stun(p: Player) -> void:
	var back := -p.facing
	back.y = 0.0
	back = back.normalized() if back.length_squared() > 0.0001 else Vector3.BACK
	var status := p.get_component(&"status") as StatusComponent
	if status:
		status.stun(wrong_stun)
	p.apply_impulse(back * 2.5 + Vector3.UP * 1.5)


## Every peer: new extras join the disguise; on the host they get their NPC brains.
func _on_extras_spawned(spawned: Array[Player]) -> void:
	for x in spawned:
		disguise.hold(x)
	if _is_host():
		_configure_crowd(spawned)


## The local player's "that's you" ring (this peer only): from the intro until you_ring_time
## after GO, fading out.
func _make_you_ring(setup_players: Array[Player]) -> void:
	var local := Net.local_slot()
	for p in setup_players:
		if p.slot == local and not p.is_bot:
			_ring_player = p
	if _ring_player == null:
		return
	_ring = MeshInstance3D.new()
	_ring.name = "YouRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.52
	torus.outer_radius = 0.64
	torus.rings = 24
	torus.ring_segments = 6
	_ring.mesh = torus
	_ring.scale = Vector3(1.0, 0.15, 1.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.93, 0.7, 0.55)
	_ring.material_override = m
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.top_level = true
	add_child(_ring)


func _process(delta: float) -> void:
	if _ring == null:
		return
	if not is_instance_valid(_ring_player) or not _ring_player.alive:
		_free_ring()
		return
	_ring.global_position = _ring_player.global_position + Vector3.UP * 0.04
	if _ring_left >= 0.0:
		_ring_left -= delta
		var m := _ring.material_override as StandardMaterial3D
		m.albedo_color.a = 0.55 * clampf(_ring_left / 0.6, 0.0, 1.0)
		if _ring_left <= 0.0:
			_free_ring()


func _free_ring() -> void:
	if _ring:
		_ring.queue_free()
	_ring = null
	_ring_player = null


## A spotlight on an unmasked blob, fading after the reveal.
func _spotlight(at: Vector3) -> void:
	var s := SpotLight3D.new()
	s.light_color = Color(1.0, 0.92, 0.75)
	s.light_energy = 9.0
	s.spot_range = 9.0
	s.spot_angle = 13.0
	s.shadow_enabled = false
	add_child(s)
	s.look_at_from_position(at + Vector3(0.0, 6.5, 1.2), at, Vector3.UP)
	var tw := create_tween()
	tw.tween_interval(reveal_hold + 0.3)
	tw.tween_property(s, ^"light_energy", 0.0, 0.5)
	tw.tween_callback(s.queue_free)


func _stage() -> Stage:
	if _stage_ref == null or not is_instance_valid(_stage_ref):
		_stage_ref = get_tree().get_first_node_in_group(&"stage") as Stage if is_inside_tree() else null
	return _stage_ref


func _name_of(p: Player, slot: int) -> String:
	if p and p.display_name != "":
		return p.display_name
	return "Player %d" % (slot + 1)


# --- Room (every peer, built in code; identical everywhere) -----------------------------------------

func _build_room() -> void:
	var room := Node3D.new()
	room.name = "Room"
	add_child(room)
	var body := StaticBody3D.new()
	body.name = "RoomBody"
	body.collision_mask = 0
	room.add_child(body)
	# Parquet: 5 x 4 tiles cover x -10..10, z -8..8, with the medallion in the middle.
	for ix in 5:
		for iz in 4:
			_place(room, "floor_tile_4x4", Vector3(-8.0 + 4.0 * ix, 0.0, -6.0 + 4.0 * iz), 0.0)
	_box(body, Vector3(0.0, -0.25, 0.0), Vector3(2.0 * HALF_X + 0.6, 0.5, FRONT_Z - BACK_Z + 0.6))
	var rosette := ROSETTE_SCENE.instantiate() as Node3D
	rosette.name = "Rosette"
	rosette.position = Vector3(0.0, 0.002, 0.6)
	room.add_child(rosette)
	Look.apply_toon(rosette, false)
	var surround := MeshInstance3D.new()
	surround.name = "Surround"
	var plane := PlaneMesh.new()
	plane.size = Vector2(90.0, 90.0)
	surround.mesh = plane
	surround.material_override = Look.toon_material(Color("#170f22"), 0.9, false)
	surround.position = Vector3(0.0, -0.2, 0.0)
	room.add_child(surround)

	# Walls: back and sides; the front is open to the camera (a plinth and an invisible barrier).
	var back: Array[String] = ["wall_window", "wall_4m", "wall_door", "wall_4m", "wall_window"]
	for i in back.size():
		_place(room, back[i], Vector3(-8.0 + 4.0 * i, 0.0, BACK_Z), 0.0)
	var side: Array[String] = ["wall_window", "wall_4m", "wall_window", "wall_4m"]
	for i in side.size():
		var z := -6.0 + 4.0 * i
		_place(room, side[i], Vector3(-HALF_X, 0.0, z), 90.0)
		_place(room, side[3 - i], Vector3(HALF_X, 0.0, z), -90.0)
	for sx: float in [-1.0, 1.0]:
		_place(room, "wall_corner", Vector3(sx * HALF_X, 0.0, BACK_Z), 0.0)
		_place(room, "wall_corner", Vector3(sx * HALF_X, 0.0, FRONT_Z), 0.0)
	var plinth := MeshInstance3D.new()
	plinth.name = "FrontPlinth"
	var pm := BoxMesh.new()
	pm.size = Vector3(2.0 * HALF_X, 0.3, 0.3)
	plinth.mesh = pm
	plinth.material_override = Look.toon_material(Color("#4a2a3a"), 0.7)
	plinth.position = Vector3(0.0, 0.15, FRONT_Z)
	room.add_child(plinth)
	var wall_h := 3.0
	var depth := FRONT_Z - BACK_Z
	_box(body, Vector3(0.0, wall_h * 0.5, BACK_Z), Vector3(2.0 * HALF_X + 0.6, wall_h, 0.3))
	_box(body, Vector3(0.0, wall_h * 0.5, FRONT_Z), Vector3(2.0 * HALF_X + 0.6, wall_h, 0.3))
	for sx: float in [-1.0, 1.0]:
		_box(body, Vector3(sx * HALF_X, wall_h * 0.5, 0.0), Vector3(0.3, wall_h, depth + 0.6))

	# A giant mask over the door, garlands along the walls.
	var emblem := MASK_SCENE.instantiate() as Node3D
	emblem.name = "Emblem"
	emblem.position = Vector3(0.0, 2.35, BACK_Z + 0.55)
	emblem.scale = Vector3.ONE * 3.2
	room.add_child(emblem)
	Look.apply_toon(emblem)
	for x: float in [-6.0, 6.0]:
		_garland(room, Vector3(x, 0.0, BACK_Z + 0.25), 0.0)
	for sx: float in [-1.0, 1.0]:
		for z: float in [-4.0, 2.0]:
			_garland(room, Vector3(sx * (HALF_X - 0.25), 0.0, z), -sx * 90.0)

	# Furniture off the floor: a piano and a clock at the back, sofas and plants on the sides.
	var piano := _place(room, "piano", Vector3(-7.4, 0.0, -6.9), 15.0)
	piano.scale = Vector3.ONE * 0.9
	_box(body, Vector3(-7.4, 0.6, -6.9), Vector3(2.0, 1.2, 1.4))
	_place(room, "grandfather_clock", Vector3(7.6, 0.0, -7.4), 0.0)
	_box(body, Vector3(7.6, 1.0, -7.4), Vector3(0.9, 2.0, 0.6))
	_place(room, "sofa", Vector3(5.2, 0.0, -7.1), 0.0)
	_box(body, Vector3(5.2, 0.45, -7.1), Vector3(2.2, 0.9, 1.0))
	for sx: float in [-1.0, 1.0]:
		_place(room, "pillar", Vector3(sx * (HALF_X - 0.75), 0.0, -1.0), 0.0)
		_box(body, Vector3(sx * (HALF_X - 0.75), 1.5, -1.0), Vector3(1.0, 3.0, 1.0))
		_place(room, "potted_plant", Vector3(sx * (HALF_X - 0.8), 0.0, 6.9), 0.0)
		_box(body, Vector3(sx * (HALF_X - 0.8), 0.6, 6.9), Vector3(0.9, 1.2, 0.9))
		_place(room, "candelabra", Vector3(sx * (HALF_X - 0.7), 0.0, 4.2), 0.0)
		_place(room, "armchair", Vector3(sx * (HALF_X - 0.9), 0.0, -4.6), -sx * 90.0)
		_box(body, Vector3(sx * (HALF_X - 0.9), 0.45, -4.6), Vector3(1.0, 0.9, 1.0))
	_place(room, "candelabra", Vector3(-2.6, 0.0, BACK_Z + 0.6), 0.0)
	_place(room, "candelabra", Vector3(2.6, 0.0, BACK_Z + 0.6), 0.0)

	# Warm candle light: two chandeliers over the back half, a central lamp, a soft wash.
	var lights := Node3D.new()
	lights.name = "Lights"
	room.add_child(lights)
	for pos: Vector3 in [Vector3(-5.0, 6.4, -3.0), Vector3(5.0, 6.4, -3.0), Vector3(0.0, 6.8, 2.0)]:
		if pos.x != 0.0:
			var ch := _place(room, "chandelier", pos, 0.0)
			for n: Node in ch.find_children("*", "GeometryInstance3D", true, false):
				(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.74, 0.45)
		lamp.light_energy = 2.6
		lamp.omni_range = 13.0
		lamp.omni_attenuation = 1.0
		lamp.position = pos + Vector3(0.0, -1.5, 0.0)
		lights.add_child(lamp)


func _garland(parent: Node3D, pos: Vector3, yaw_deg: float) -> void:
	var g := GARLAND_SCENE.instantiate() as Node3D
	g.position = pos
	g.rotation_degrees.y = yaw_deg
	parent.add_child(g)
	Look.apply_toon(g, false)


func _place(parent: Node3D, piece: String, pos: Vector3, yaw_deg: float) -> Node3D:
	var scene := load(ENV_DIR + piece + ".glb") as PackedScene
	if scene == null:
		push_error("masquerade: missing kit piece %s" % piece)
		return Node3D.new()
	var n := scene.instantiate() as Node3D
	n.position = pos
	n.rotation_degrees.y = yaw_deg
	parent.add_child(n)
	Look.apply_toon(n)
	return n


func _box(body: StaticBody3D, center: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	body.add_child(cs)
