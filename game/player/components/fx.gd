class_name FxComponent
extends PlayerComponent
## Effects for one player, on every peer: listens to the Player events and plays `Fx`
## effects, puffs footstep dust while running on the floor, keeps a blob shadow under the
## player and a star swirl over a stunned head. Never touches gameplay state.
## Owner: look and effects.

## Landing below this impact speed makes no effect; above `thud_speed` it is a big thud.
@export var land_min_speed: float = 3.0
@export var thud_speed: float = 9.0
## Horizontal speed that counts as running (footstep dust), and the time between puffs.
@export var run_speed: float = 2.5
@export var footstep_interval: float = 0.24
## A soft round shadow straight under the player (shows where a jump lands).
@export var blob_shadow: bool = true
## Height of the stun stars above the player's origin.
@export var head_height: float = 1.12

var _step_timer: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _has_last: bool = false
var _swirl: FxEffect = null
var _swirl_serial: int = -1
var _shadow: BlobShadow = null


func _ready() -> void:
	if player == null:
		return
	player.jumped.connect(_on_jumped)
	player.landed.connect(_on_landed)
	player.shove_started.connect(_on_shove_started)
	player.got_hit.connect(_on_got_hit)
	player.stunned.connect(_on_stunned)
	player.eliminated.connect(_on_eliminated)
	player.respawned.connect(_on_respawned)
	if blob_shadow and DisplayServer.get_name() != "headless":
		_shadow = BlobShadow.new()
		_shadow.name = "BlobShadow"
		add_child(_shadow)


func _process(delta: float) -> void:
	if player == null or not player.alive or delta <= 0.0:
		_has_last = false
		return
	var pos := player.global_position
	if not _has_last:
		_last_pos = pos
		_has_last = true
		return
	var moved := pos - _last_pos
	_last_pos = pos
	var speed := Vector2(moved.x, moved.z).length() / delta
	if speed >= run_speed and _on_floor(moved.y / delta):
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer = footstep_interval
			var fx := Fx.play(&"dust_puff", pos - player.facing * 0.2, Color.WHITE)
			if fx:
				fx.scale = Vector3.ONE * 0.55
	else:
		_step_timer = minf(_step_timer, footstep_interval * 0.3)


## The primary colour of this player.
func primary_color() -> Color:
	return Look.parse_color(player.loadout.get("primary", ""), Color.WHITE) if player else Color.WHITE


## The primary colour of the player in `slot`, gold if unknown.
func slot_color(slot: int) -> Color:
	if slot < 0:
		return Look.GOLD
	var stage := get_tree().get_first_node_in_group(&"stage") as Stage
	if stage:
		var p := stage.get_player(slot)
		if p and p.loadout.has("primary"):
			return Look.parse_color(p.loadout["primary"], Look.GOLD)
	var info: Variant = Net.roster.get(slot)
	if info != null and info is PlayerInfo and (info as PlayerInfo).loadout.has("primary"):
		return Look.parse_color((info as PlayerInfo).loadout["primary"], Look.GOLD)
	return Look.GOLD


func _on_floor(vertical_speed: float) -> bool:
	if player.is_authority():
		return player.is_on_floor()
	return absf(vertical_speed) < 0.5  # remote copies do not move_and_slide


func _feet() -> Vector3:
	return player.global_position


func _on_jumped() -> void:
	var fx := Fx.play(&"dust_puff", _feet(), Color.WHITE)
	if fx:
		fx.scale = Vector3.ONE * 0.8


func _on_landed(impact_speed: float) -> void:
	if impact_speed >= thud_speed:
		var fx := Fx.play(&"land_thud", _feet(), Color.WHITE)
		if fx:
			fx.scale = Vector3.ONE * clampf(impact_speed / thud_speed, 1.0, 1.6)
	elif impact_speed >= land_min_speed:
		Fx.play(&"dust_puff", _feet(), Color.WHITE)


func _on_shove_started() -> void:
	var f := player.facing
	var fx := Fx.play(&"shove_whoosh", _feet(), primary_color())
	if fx and f.length_squared() > 0.0001:
		fx.basis = Basis.looking_at(-f, Vector3.UP)  # local +Z along facing


func _on_got_hit(impulse: Vector3, source_slot: int) -> void:
	var at := _feet() + Vector3.UP * 0.6
	var dir := Vector3(impulse.x, 0.0, impulse.z)
	if dir.length_squared() > 0.0001:
		at -= dir.normalized() * 0.35  # on the side the blow came from
	Fx.play(&"hit_stars", at, slot_color(source_slot))


func _on_stunned(duration: float) -> void:
	_stop_swirl()
	var fx := Fx.play(&"stun_swirl", _feet() + Vector3.UP * head_height, Color.WHITE)
	if fx:
		fx.hold(duration, player, Vector3.UP * head_height)
		_swirl = fx
		_swirl_serial = fx.serial


func _on_eliminated(reason: StringName) -> void:
	_stop_swirl()
	var pos := _feet()
	if String(reason).contains("lava"):
		Fx.play(&"splash_lava", pos, Color.WHITE)
	Fx.play(&"poof", pos + Vector3.UP * 0.5, primary_color())


func _on_respawned(xform: Transform3D) -> void:
	_has_last = false
	Fx.play(&"respawn_sparkle", xform.origin, primary_color())


func _stop_swirl() -> void:
	if _swirl and is_instance_valid(_swirl) and _swirl.serial == _swirl_serial and _swirl.playing:
		_swirl.stop()
	_swirl = null
	_swirl_serial = -1


func _exit_tree() -> void:
	_stop_swirl()
