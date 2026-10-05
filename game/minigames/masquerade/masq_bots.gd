class_name MasqBots
extends RefCounted
## Masquerade's bot minds: make real players that are bots behave like the NPC dancers most of the
## time and, now and then, hunt a suspicious blob and shove it. Owner: masquerade minigame.
##
## Each driven blob keeps its own BotBrain, configured as an NPC extra (`configure_extra`
## wander / dance, the very code the NPC crowd runs); its controller runs that brain as for any
## bot. A hunt is the brain's generic action hooks (Masquerade.bot_wants_action / bot_aim /
## bot_action_reach, answered from here): while a blob hunts, the brain closes in on the chosen
## blob at a brisk stroll, turns to face it and presses `action` (its own reaction and aim
## error); the shove (or 5 s, or the target going away) ends the hunt and the brain goes back to
## the NPC pattern from where it stands.
##
## Who to hunt comes only from what anybody watching could see (never from who is real):
## every blob (players and extras) builds up suspicion when it walks dead straight for long,
## stops abruptly, shoves (NPCs fake-shove too), or flashes its true colours after a wrong shove;
## suspicion fades. A bot picks among the blobs near it, weighted by suspicion plus a baseline,
## so it shoves NPCs as well as players.
## Used by the minigame on the host (roster bots) and by the network check for each peer's own
## player. A human handed to `add` (tests, the network check: its controller is scripted) gets
## its brain ticked from `tick`. Deterministic for a given rng seed.

## Seconds between a bot's decisions (random in range).
const THINK := Vector2(1.6, 3.4)
## Chance per decision to hunt at all, plus how much the most suspicious nearby blob adds.
var hunt_chance: float = 0.16
var hunt_suspicion_gain: float = 0.12
## Only blobs within this distance (m) are considered.
const HUNT_RADIUS := 5.5
## Weight of a blob with no suspicion at all.
const BASE_WEIGHT := 0.35
## The brain closes in to this distance (m, centre to centre) before it faces and shoves.
const SHOVE_DIST := 1.1
const HUNT_GIVE_UP := 5.0
## Suspicion: sample period (s), fade time constant (s) and the gains.
const SAMPLE := 0.1
const FADE := 7.0
const GAIN_SHOVE := 1.2
const GAIN_STOP := 0.5
const GAIN_STRAIGHT := 0.12
const GAIN_FLASH := 6.0
const STRAIGHT_AFTER := 1.8
const DANCE_SHARE := 0.4

var game: Minigame = null
var rng: RandomNumberGenerator = null
## Slot -> suspicion score of every blob (players and extras) seen.
var suspicion: Dictionary[int, float] = {}
## Hunts started / shoves made while hunting (stats for tests).
var hunts: int = 0
var shoves: int = 0

var _driven: Array[Player] = []
var _brains: Dictionary[int, BotBrain] = {}
var _think: Dictionary[int, float] = {}
var _hunt: Dictionary = {}   # slot -> target Player (untyped: it may be freed)
var _hunt_time: Dictionary[int, float] = {}
var _mode: Dictionary[int, StringName] = {}
var _centers: Array[Vector3] = []
var _track: Dictionary[int, Array] = {}   # slot -> [last_pos, last_speed, last_dir, straight_t]
var _sample: float = 0.0
var _hooked: Dictionary[int, bool] = {}


func _init(minigame: Minigame, random: RandomNumberGenerator, dance_centers: Array[Vector3]) -> void:
	game = minigame
	rng = random
	_centers = dance_centers
	# The minigame's bot hooks ask its drivers (the host's, a dev check's own).
	var drivers: Variant = game.get(&"bot_drivers") if game else null
	if drivers is Array:
		(drivers as Array).append(self)
	# A wrong shove flashes the shover's true colours to everyone watching.
	if game and game.has_signal(&"wrong_shove"):
		game.connect(&"wrong_shove", func(shover_slot: int, _npc_slot: int) -> void: note(shover_slot, GAIN_FLASH))


## Drives `p` from now on with `brain` (its own BotBrain; `BotBrain.of(p)` for roster bots).
## Configures the brain as an NPC.
func add(p: Player, brain: BotBrain) -> void:
	if p == null or brain == null or _driven.has(p):
		return
	_driven.append(p)
	_brains[p.slot] = brain
	_think[p.slot] = rng.randf_range(THINK.x, THINK.y) + 1.0
	_be_npc(p)
	p.shove_started.connect(_on_shove_started.bind(p))


func driven() -> Array[Player]:
	return _driven


func drives(p: Player) -> bool:
	return p != null and _brains.has(p.slot) and _driven.has(p)


## Mode the NPC brain of `p` runs (&"wander" / &"dance").
func mode_of(p: Player) -> StringName:
	return _mode.get(p.slot, &"")


## A blob was seen shoving (shove_started); `amount` = GAIN_SHOVE by default.
func note(slot: int, amount: float) -> void:
	suspicion[slot] = float(suspicion.get(slot, 0.0)) + amount


## Every physics tick (host for roster bots; each peer for its own player in the net check).
func tick(delta: float) -> void:
	_watch(delta)
	for v: Variant in _driven:
		# Untyped: a bot removed mid-round is freed under us.
		if not is_instance_valid(v):
			continue
		var p := v as Player
		if not p.is_bot:
			_brains[p.slot].fill_intent(p.intent, delta)  # no controller runs it
		if not p.alive:
			continue
		if p.frozen or p.control_locked:
			_hunt.erase(p.slot)
			continue
		if _hunt.has(p.slot):
			_hunt_tick(p, delta)
			continue
		_think[p.slot] = float(_think[p.slot]) - delta
		if float(_think[p.slot]) <= 0.0:
			_think[p.slot] = rng.randf_range(THINK.x, THINK.y)
			_decide(p)


# --- Hunting (answered to the brain through the minigame's hooks) ------------------------------

## Hook answer: `p` is hunting a blob still worth a shove.
func wants_action(p: Player) -> bool:
	return _target_of(p) != null


## Hook answer: the hunted blob's position (ZERO when not hunting).
func aim(p: Player) -> Vector3:
	var t := _target_of(p)
	return t.global_position if t else Vector3.ZERO


func _target_of(p: Player) -> Player:
	if p == null or not _hunt.has(p.slot):
		return null
	var tv: Variant = _hunt[p.slot]
	if not is_instance_valid(tv) or not (tv as Player).alive or _gone(tv as Player):
		return null
	return tv as Player


func _decide(p: Player) -> void:
	var cands: Array[Player] = []
	var weights: Array[float] = []
	var best := 0.0
	for b in _bodies():
		if b == p or not b.alive or _gone(b):
			continue
		if _flat(b.global_position - p.global_position).length() > HUNT_RADIUS:
			continue
		var s := float(suspicion.get(b.slot, 0.0))
		cands.append(b)
		weights.append(BASE_WEIGHT + s)
		best = maxf(best, s)
	if cands.is_empty():
		return
	if rng.randf() >= hunt_chance + hunt_suspicion_gain * minf(best, 5.0):
		return
	var total := 0.0
	for w in weights:
		total += w
	var roll := rng.randf() * total
	for i in cands.size():
		roll -= weights[i]
		if roll <= 0.0 or i == cands.size() - 1:
			_hunt[p.slot] = cands[i]
			_hunt_time[p.slot] = 0.0
			hunts += 1
			return


## A hunt runs until the shove, the target going away, or the give-up time.
func _hunt_tick(p: Player, delta: float) -> void:
	_hunt_time[p.slot] = float(_hunt_time[p.slot]) + delta
	if _target_of(p) == null or float(_hunt_time[p.slot]) > HUNT_GIVE_UP:
		_end_hunt(p)


## The hunter shoved (its brain pressed action and the shove went out): the hunt is over.
func _on_shove_started(p: Player) -> void:
	if is_instance_valid(p) and _hunt.has(p.slot):
		shoves += 1
		_end_hunt(p)


func _end_hunt(p: Player) -> void:
	_hunt.erase(p.slot)
	_hunt_time.erase(p.slot)
	_be_npc(p)


## (Re)configures `p`'s brain as an NPC extra from where it stands now.
func _be_npc(p: Player) -> void:
	var brain: BotBrain = _brains.get(p.slot)
	if brain == null:
		return
	var mode: StringName = _mode.get(p.slot, &"")
	if mode == &"":
		mode = &"dance" if rng.randf() < DANCE_SHARE and not _centers.is_empty() else &"wander"
		_mode[p.slot] = mode
	var center := Vector3.INF
	if mode == &"dance":
		center = _centers[rng.randi() % _centers.size()]
	brain.configure_extra(mode, rng.randi(), center)


func is_hunting(p: Player) -> bool:
	return _hunt.has(p.slot)


# --- Watching (suspicion) -------------------------------------------------------------------

func _watch(delta: float) -> void:
	_sample += delta
	if _sample < SAMPLE:
		return
	var dt := _sample
	_sample = 0.0
	var fade := exp(-dt / FADE)
	for slot: int in suspicion.keys():
		suspicion[slot] = float(suspicion[slot]) * fade
	for b in _bodies():
		if not b.alive:
			continue
		if not _hooked.has(b.slot):
			_hooked[b.slot] = true
			b.shove_started.connect(func() -> void: note(b.slot, GAIN_SHOVE))
		var pos := b.global_position
		var tr: Array = _track.get(b.slot, [])
		if tr.is_empty():
			_track[b.slot] = [pos, 0.0, Vector2.ZERO, 0.0]
			continue
		var v := _flat(pos - (tr[0] as Vector3)) / dt
		var speed := v.length()
		var dir := v / speed if speed > 0.05 else Vector2.ZERO
		var straight: float = tr[3]
		if float(tr[1]) > 1.6 and speed < 0.3:
			note(b.slot, GAIN_STOP)
		if speed > 1.2 and (tr[2] as Vector2).dot(dir) > 0.985:
			straight += dt
			if straight > STRAIGHT_AFTER:
				note(b.slot, GAIN_STRAIGHT)
		else:
			straight = 0.0
		_track[b.slot] = [pos, speed, dir, straight]


func _bodies() -> Array[Player]:
	var out: Array[Player] = []
	if game == null or not is_instance_valid(game):
		return out
	for p in game.players:
		if is_instance_valid(p):
			out.append(p)
	var stage := game.get_tree().get_first_node_in_group(&"stage") as Stage if game.is_inside_tree() else null
	if stage:
		for x in stage.extras:
			if is_instance_valid(x):
				out.append(x)
	return out


## Unmasked players (revealed, about to leave) are no longer worth a shove.
func _gone(b: Player) -> bool:
	var found: Variant = game.get(&"found") if game else null
	return found is Dictionary and (found as Dictionary).has(b.slot)


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)
