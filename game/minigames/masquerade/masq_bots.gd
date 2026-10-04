class_name MasqBots
extends RefCounted
## Masquerade's bot driver: makes real players that are bots behave like the NPC dancers most of
## the time and, now and then, hunt a suspicious blob and shove it. Owner: masquerade minigame.
##
## Each driven blob keeps its own BotBrain, configured as an NPC extra (`configure_extra`
## wander / dance, the very code the NPC crowd runs), and its controller is `scripted`, so this
## driver fills its intent every tick: the brain's NPC stroll, or a hunt. A hunt: walk straight
## at the chosen blob at a brisk stroll, shove when it is in reach and in front, then go back to
## the NPC pattern from where it stands (5 s give-up).
##
## Who to hunt comes only from what anybody watching could see (never from who is real):
## every blob (players and extras) builds up suspicion when it walks dead straight for long,
## stops abruptly, shoves (NPCs fake-shove too), or flashes its true colours after a wrong shove;
## suspicion fades. A bot picks among the blobs near it, weighted by suspicion plus a baseline,
## so it shoves NPCs as well as players.
## Used by the minigame on the host (roster bots) and by the network check for each peer's own
## player. Deterministic for a given rng seed.

## Seconds between a bot's decisions (random in range).
const THINK := Vector2(1.6, 3.4)
## Chance per decision to hunt at all, plus how much the most suspicious nearby blob adds.
var hunt_chance: float = 0.16
var hunt_suspicion_gain: float = 0.12
## Only blobs within this distance (m) are considered.
const HUNT_RADIUS := 5.5
## Weight of a blob with no suspicion at all.
const BASE_WEIGHT := 0.35
## Stick length while hunting (the fastest NPC stroll is 0.55).
const HUNT_STICK := 0.55
## Shove when the target is this close (m, centre to centre) and within SHOVE_CONE_DEG.
const SHOVE_DIST := 1.1
const SHOVE_CONE_DEG := 28.0
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
## Hunts started / shoves pressed (stats for tests).
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
	# A wrong shove flashes the shover's true colours to everyone watching.
	if game and game.has_signal(&"wrong_shove"):
		game.connect(&"wrong_shove", func(shover_slot: int, _npc_slot: int) -> void: note(shover_slot, GAIN_FLASH))


## Drives `p` from now on with `brain` (its own BotBrain; `BotBrain.of(p)` for roster bots).
## Configures the brain as an NPC and makes the controller scripted.
func add(p: Player, brain: BotBrain) -> void:
	if p == null or brain == null or _driven.has(p):
		return
	_driven.append(p)
	_brains[p.slot] = brain
	_think[p.slot] = rng.randf_range(THINK.x, THINK.y) + 1.0
	_be_npc(p)
	var c := p.get_component(&"controller") as ControllerComponent
	if c:
		c.scripted = true


func driven() -> Array[Player]:
	return _driven


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
		if not p.alive:
			continue
		if p.frozen or p.control_locked:
			_hunt.erase(p.slot)
			continue
		if _hunt.has(p.slot):
			_hunt_tick(p, delta)
			continue
		_brains[p.slot].fill_intent(p.intent, delta)
		_think[p.slot] = float(_think[p.slot]) - delta
		if float(_think[p.slot]) <= 0.0:
			_think[p.slot] = rng.randf_range(THINK.x, THINK.y)
			_decide(p)


# --- Hunting --------------------------------------------------------------------------------

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


func _hunt_tick(p: Player, delta: float) -> void:
	var tv: Variant = _hunt[p.slot]
	_hunt_time[p.slot] = float(_hunt_time[p.slot]) + delta
	var intent := p.intent
	intent.clear()
	if not is_instance_valid(tv) or not (tv as Player).alive or _gone(tv as Player) 			or float(_hunt_time[p.slot]) > HUNT_GIVE_UP:
		_end_hunt(p)
		return
	var t := tv as Player
	var to := _flat(t.global_position - p.global_position)
	var d := to.length()
	var dir := to / d if d > 0.01 else Vector2(p.facing.x, p.facing.z)
	var facing := Vector2(p.facing.x, p.facing.z).normalized()
	if d <= SHOVE_DIST and facing.dot(dir) >= cos(deg_to_rad(SHOVE_CONE_DEG)):
		var shove := p.get_component(&"shove") as ShoveComponent
		if shove == null or shove.can_shove():
			intent.action_pressed = true
			shoves += 1
			_end_hunt(p)
			return
	# Close in; once near, slow down and turn to face it.
	intent.move = dir * (HUNT_STICK if d > SHOVE_DIST else 0.2)


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
