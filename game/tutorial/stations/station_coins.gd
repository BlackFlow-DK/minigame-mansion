extends TrainingStation
## Station 8, Coin Scramble taster: coins rain onto a small vault patch while a padded bar
## (the real spinner model) sweeps slowly around it. Grab 5 coins; jump the bar or get swept.

const CoinPiece := preload("res://minigames/coin_scramble/coin_piece.gd")

const CENTRE := Vector3(0.0, 0.0, -6.5)
const PATCH_RADIUS := 3.3
## The spinner bar: half length, half width and top (m), as in Coin Scramble.
const BAR_HALF_LENGTH := 3.0
const BAR_HALF_WIDTH := 0.21
const BAR_TOP := 0.71
const BAR_RATE := 0.9
const BAR_PUSH := 7.5
const BAR_LIFT := 4.5
const BAR_COOLDOWN := 0.8
const COINS_NEEDED := 5
## Coin landing spots around the patch centre (x, z) and their drop heights (staggered rain).
const SPOTS: Array[Vector2] = [Vector2(-2.0, 0.9), Vector2(1.6, 1.4), Vector2(-1.2, -1.9), Vector2(2.1, -1.1), Vector2(0.2, -2.6)]
const DROP_HEIGHTS: Array[float] = [5.0, 7.0, 9.0, 11.0, 13.0]
const GRAB_RANGE := 0.75

var collected: int = 0
var bar_angle: float = 0.35

var _coins: Array[Node3D] = []
var _bar: Node3D = null
var _running: bool = false
var _hit_cd: float = 0.0


func _init() -> void:
	checklist_name = "Coin rain"
	card_title = "Coin rain"
	card_line = "Grab 5 coins. Jump over the sweeping bar!"
	card_tip = "In Coin Scramble a hit makes you drop coins."
	glyphs = [&"move", &"jump"]
	length = 13.0


func build() -> void:
	add_ground(0.0, -length)
	add_disc(CENTRE + Vector3.UP * 0.05, PATCH_RADIUS, 0.04, Color("#3c6e78"))
	add_disc(CENTRE + Vector3.UP * 0.056, PATCH_RADIUS - 0.25, 0.04, Color("#4f8a92"))
	add_ring_marker(CENTRE, PATCH_RADIUS).material_override = glow_material(GOLD, 1.8)
	var spinner := add_model("res://assets/models/props/spinner_bar.glb", CENTRE + Vector3.UP * 0.05)
	if spinner:
		_bar = spinner.find_child("Bar", true, false) as Node3D
		if _bar == null:
			_bar = spinner
		_bar.rotation.y = bar_angle
	add_model("res://assets/models/props/treasure_chest.glb", Vector3(-3.2, 0.0, -11.6), 25.0)
	add_model("res://assets/models/props/treasure_chest.glb", Vector3(3.2, 0.0, -1.4), -150.0)


func target() -> Vector3:
	var best := to_global(CENTRE)
	var best_d := INF
	for at in coin_positions():
		var d := flat_dist(at, player.global_position) if player else 0.0
		if d < best_d:
			best_d = d
			best = Vector3(at.x, to_global(CENTRE).y, at.z)
	if done:
		return to_global(Vector3(0.0, 0.0, -length + 1.0))
	return best


func begin() -> void:
	_running = true
	collected = 0
	set_progress("0 / %d coins" % COINS_NEEDED)
	for i in SPOTS.size():
		var coin := CoinPiece.new() as Node3D
		coin.name = "Coin%d" % i
		coin.call(&"setup_fall", i, 1, CENTRE + Vector3(SPOTS[i].x, DROP_HEIGHTS[i], SPOTS[i].y))
		add_child(coin)
		_coins.append(coin)


## World positions of the coins still lying (or falling) on the patch.
func coin_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for c in _coins:
		if is_instance_valid(c):
			out.append(to_global(c.call(&"current_pos") as Vector3))
	return out


func tick(delta: float) -> void:
	if not live(player):
		return
	for c: Node3D in _coins.duplicate():
		if not is_instance_valid(c):
			_coins.erase(c)
			continue
		var at := to_global(c.call(&"current_pos") as Vector3)
		if flat_dist(at, player.global_position) < GRAB_RANGE and absf(at.y - player.global_position.y - 0.5) < 1.1 \
				and bool(c.call(&"can_grab", player.slot)):
			_coins.erase(c)
			collected += 1
			Fx.play(&"coin_pickup", at)
			Sfx.play(&"coin", at)
			c.queue_free()
			set_progress("%d / %d coins" % [collected, COINS_NEEDED])
			if collected >= COINS_NEEDED:
				complete()
	# The bar sweeps the player (no dummies come here).
	_hit_cd -= delta
	if _running and _hit_cd <= 0.0:
		var feet := to_local(player.global_position) - CENTRE
		if bar_overlaps(bar_angle, feet, 0.4):
			_hit_cd = BAR_COOLDOWN
			player.apply_impulse(_bar_impulse(feet))


func _physics_process(delta: float) -> void:
	if not _running:
		return
	var rate := BAR_RATE if not done else BAR_RATE * 0.25
	bar_angle = wrapf(bar_angle + rate * delta, -PI, PI)
	if _bar:
		_bar.rotation.y = bar_angle


## True when a body of `radius` with its feet at `feet` (patch frame) is inside the bar at
## angle `a`. Feet at or above the bar's top clear it (a jump). Same rule as Coin Scramble.
static func bar_overlaps(a: float, feet: Vector3, radius: float) -> bool:
	if feet.y >= BAR_TOP - 0.03 or feet.y < -1.0:
		return false
	var u := Vector2(cos(a), -sin(a))
	var rel := Vector2(feet.x, feet.z)
	var along := clampf(rel.dot(u), -BAR_HALF_LENGTH, BAR_HALF_LENGTH)
	return (rel - u * along).length() < BAR_HALF_WIDTH + radius


func _bar_impulse(feet: Vector3) -> Vector3:
	var u := Vector2(cos(bar_angle), -sin(bar_angle))
	var rel := Vector2(feet.x, feet.z)
	var along := rel.dot(u)
	# Along the bar's motion at that point (it turns toward +angle), plus a little outward.
	var h := Vector2(-sin(bar_angle), -cos(bar_angle)) * (signf(along) if absf(along) > 0.05 else 1.0)
	h = (h + (rel.normalized() if rel.length() > 0.05 else u) * 0.35).normalized() * BAR_PUSH
	return Vector3(h.x, BAR_LIFT, h.y)
