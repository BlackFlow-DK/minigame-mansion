extends TrainingStation
## Station 7, Hot Potato taster: the Bomber dummy holds a lit bomb (the real Hot Potato rig).
## Walk up to it and it hands you the bomb; pass it on to the Catcher dummy (touch it or shove
## it) before the fuse runs out. The Catcher's bomb blows harmlessly a moment later: done.
## If the fuse runs out on you it pops (a harmless push) and the Bomber gets a fresh one.

enum Phase { BOMBER_HOLDS, PLAYER_HOLDS, CATCHER_HOLDS, BLOWN }

const BombRig := preload("res://minigames/hot_potato/bomb_rig.gd")

const BOMBER_POST := Vector3(-1.8, 0.0, -3.4)
const CATCHER_POST := Vector3(2.0, 0.0, -8.6)
## The Bomber comes for you once you are this close to its post (m).
const NOTICE_RANGE := 3.9
## Blob centres closer than this (flat) touch: the bomb passes (as in Hot Potato).
const TOUCH := 1.0
const FUSE := 9.0
## Seconds the Catcher holds it before it blows, and after a blow-up on you before a new bomb.
const CATCHER_FUSE := 1.1
const REARM_TIME := 1.6

var phase: Phase = Phase.BOMBER_HOLDS
var fuse_left: float = 0.0

var _rig: Node3D = null
var _t: float = 0.0
var _shown_second: int = -1


func _init() -> void:
	checklist_name = "Hot potato"
	card_title = "Hot potato"
	card_line = "Take the bomb from the Bomber, then pass it to the Catcher before it blows!"
	card_tip = "Touch or shove someone to pass the bomb."
	glyphs = [&"move", &"shove"]
	length = 13.0


func build() -> void:
	add_ground(0.0, -length)
	add_disc(BOMBER_POST + Vector3.UP * 0.045, 0.7, 0.03, Color("#d9483b"))
	add_disc(CATCHER_POST + Vector3.UP * 0.045, 0.7, 0.03, TEAL)
	add_model("res://assets/models/props/crate.glb", Vector3(-3.3, 0.0, -1.2), 15.0)
	add_model("res://assets/models/props/crate.glb", Vector3(3.2, 0.0, -11.5), -10.0)
	add_model("res://assets/models/props/barrel.glb", Vector3(-3.4, 0.0, -10.0))
	_rig = BombRig.new()
	_rig.name = "BombRig"
	add_child(_rig)


func dummy_posts() -> Array[Transform3D]:
	return [
		Transform3D(Basis(), to_global(BOMBER_POST + Vector3.UP * 0.05)),
		Transform3D(Basis(), to_global(CATCHER_POST + Vector3.UP * 0.05)),
	]


func target() -> Vector3:
	match phase:
		Phase.PLAYER_HOLDS:
			var c := dummy(1)
			return c.global_position if c else to_global(CATCHER_POST)
		Phase.CATCHER_HOLDS, Phase.BLOWN:
			if done:
				return to_global(Vector3(0.0, 0.0, -length + 1.0))
	var b := dummy(0)
	return b.global_position if b else to_global(BOMBER_POST)


func begin() -> void:
	if player and not player.shove_hit.is_connected(_on_player_shove_hit):
		player.shove_hit.connect(_on_player_shove_hit)
	_give(dummy(0), Phase.BOMBER_HOLDS)


## The bomb rig has its own arrow over the holder: the beacon only points at the Catcher.
func show_beacon() -> bool:
	return phase == Phase.PLAYER_HOLDS or done


## Slot of whoever holds the bomb now (-1: nobody).
func holder_slot() -> int:
	var h := _holder()
	return h.slot if h else -1


func tick(delta: float) -> void:
	if not live(player):
		return
	var bomber := dummy(0)
	var catcher := dummy(1)
	match phase:
		Phase.BOMBER_HOLDS:
			if bomber == null:
				_give(player, Phase.PLAYER_HOLDS)
				return
			if flat_dist(player.global_position, bomber.global_position) < TOUCH:
				_give(player, Phase.PLAYER_HOLDS)
			elif flat_dist(player.global_position, to_global(BOMBER_POST)) < NOTICE_RANGE:
				steer(bomber, player.global_position, 0.75, 0.5)
			else:
				steer(bomber, to_global(BOMBER_POST), 0.5)
		Phase.PLAYER_HOLDS:
			if bomber:
				steer(bomber, to_global(BOMBER_POST), 0.5)
			fuse_left -= delta
			var s := ceili(maxf(fuse_left, 0.0))
			if s != _shown_second:
				_shown_second = s
				set_progress("Fuse: %d s" % s)
			if _rig:
				_rig.call(&"set_level", clampi(int((1.0 - fuse_left / FUSE) * 4.0), 0, 3))
			if catcher == null or flat_dist(player.global_position, catcher.global_position) < TOUCH:
				_give(catcher, Phase.CATCHER_HOLDS)
			elif fuse_left <= 0.0:
				_blow(player)
				phase = Phase.BLOWN
				_t = 0.0
				set_progress("Boom! Too slow. Here comes another bomb.")
		Phase.CATCHER_HOLDS:
			_t += delta
			if bomber:
				steer(bomber, to_global(BOMBER_POST), 0.5)
			if _t >= CATCHER_FUSE:
				_blow(catcher)
				set_progress("")
				phase = Phase.BLOWN
				_t = -INF
				complete()
		Phase.BLOWN:
			_t += delta
			if bomber:
				steer(bomber, to_global(BOMBER_POST), 0.6)
			if _t >= REARM_TIME:
				set_progress("")
				_give(bomber, Phase.BOMBER_HOLDS)


func reset() -> void:
	if phase == Phase.PLAYER_HOLDS:
		set_progress("")
		_give(dummy(0), Phase.BOMBER_HOLDS)


func _on_player_shove_hit(victim_slot: int) -> void:
	var catcher := dummy(1)
	if active and phase == Phase.PLAYER_HOLDS and catcher and victim_slot == catcher.slot:
		_give(catcher, Phase.CATCHER_HOLDS)


func _give(p: Player, next: Phase) -> void:
	phase = next
	_t = 0.0
	_shown_second = -1
	if next == Phase.PLAYER_HOLDS:
		fuse_left = FUSE
	if _rig == null:
		return
	if p == null:
		_rig.call(&"hide_bomb")
		return
	_rig.call(&"show_on", p, 2 if next == Phase.CATCHER_HOLDS else 0)
	if next != Phase.BOMBER_HOLDS:
		Sfx.play(&"hit_bonk", p.global_position)


func _blow(p: Player) -> void:
	if _rig:
		_rig.call(&"hide_bomb")
	if p == null:
		return
	var at := p.global_position + Vector3.UP * 1.2
	Fx.play(&"explosion", at)
	Sfx.play(&"explosion", at)
	if room and room.camera:
		room.camera.add_shake(0.4)
	p.apply_impulse(Vector3(0.0, 6.0, 2.5))
	if p != player:
		var visuals := p.get_component(&"visuals") as VisualsComponent
		if visuals:
			visuals.play_emote(&"sad")


func _holder() -> Player:
	match phase:
		Phase.BOMBER_HOLDS:
			return dummy(0)
		Phase.PLAYER_HOLDS:
			return player
		Phase.CATCHER_HOLDS:
			return dummy(1)
	return null
