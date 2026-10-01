extends Node
## Autoload `Feel`: the game-feel director for moments that belong to no single object.
## Owner: look and effects (juice).
##
## Listens only to existing signals: Session (`state_changed`, `round_intro`, `round_started`,
## `round_finished`), the main scene's `app_state_changed`, and the Stage's players. It never
## writes gameplay state, sends no RPCs and never touches Engine.time_scale, so every peer can
## run it on its own and positions still agree (all of it is presentation).
##
##   Transitions    a plum iris curtain, at most CURTAIN_TIME each way. It closes in the last
##                  CURTAIN_TIME of a RESULTS phase that leads to another round, and of PODIUM
##                  (from Session.phase_time_left), and opens on every stage load: round_intro,
##                  back to LOBBY, title <-> lobby. Mouse is ignored, so it never blocks input.
##                  Closed longer than CURTAIN_FAILSAFE without a load: it opens anyway.
##   Arena intro    round_intro: ArenaCamera.intro_sweep(INTRO_SWEEP_TIME) and letterbox bars;
##                  round_started (GO) lifts the bars and ends any sweep still running.
##   Round end      round_finished: the winner cheers under a spotlight with a sparkle. When the
##                  round ended by knockout (exactly one player left standing) there is first a
##                  SLOWMO_TIME slow-motion (FeelTime.scale = SLOWMO_SCALE: effects and blob
##                  animation only), a camera push-in on the winner, a vignette, then confetti.
##   shake(amount)  screen shake on the active ArenaCamera (the players' fx component uses it).
##
## Quality LOW (Look.is_high() false) skips the spotlight, vignette, sparkle and extra confetti.

## A curtain started closing (true) or opening (false).
signal transition_changed(closing: bool)
## The curtain is fully open again.
signal transition_finished
signal intro_started
signal winner_celebrated(slot: int)
signal knockout_started(slot: int)
signal knockout_finished(slot: int)

const CURTAIN_TIME := 0.35
const CURTAIN_FAILSAFE := 0.6
## Phases shorter than this (real seconds) never pre-close the curtain (fast test runs).
const CURTAIN_MIN_PHASE := 1.0
## Height of each letterbox bar, as a fraction of the screen.
const LETTERBOX_SIZE := 0.085
const LETTERBOX_TIME := 0.35
const INTRO_SWEEP_TIME := 2.5
const SLOWMO_SCALE := 0.3
const SLOWMO_TIME := 0.6
const KO_FOCUS_TIME := 2.8
const KO_SHAKE := 0.35
const SPOT_HEIGHT := 7.0
const SPOT_ENERGY := 6.0

const CURTAIN_SHADER := preload("res://feel/materials/curtain.gdshader")
const VIGNETTE_SHADER := preload("res://feel/materials/vignette.gdshader")
const BAR_COLOR := Color(0.07, 0.05, 0.08)

## Master switch (tests, a settings menu).
var enabled: bool = true

## 0 open .. 1 closed (linear in time; the shader gets it eased).
var curtain: float = 0.0:
	set(value):
		curtain = clampf(value, 0.0, 1.0)
		if _curtain_mat:
			_curtain_mat.set_shader_parameter(&"progress", curtain * curtain * (3.0 - 2.0 * curtain))
		if _curtain_rect:
			_curtain_rect.visible = curtain > 0.0
## 0 hidden .. 1 bars fully in.
var letterbox: float = 0.0:
	set(value):
		letterbox = clampf(value, 0.0, 1.0)
		_layout_bars()
## 0 .. 1 knockout vignette.
var vignette: float = 0.0:
	set(value):
		vignette = clampf(value, 0.0, 1.0)
		if _vignette_mat:
			_vignette_mat.set_shader_parameter(&"amount", vignette)
		if _vignette_rect:
			_vignette_rect.visible = vignette > 0.0

var _under: CanvasLayer
var _over: CanvasLayer
var _curtain_rect: ColorRect
var _curtain_mat: ShaderMaterial
var _vignette_rect: ColorRect
var _vignette_mat: ShaderMaterial
var _bar_top: ColorRect
var _bar_bottom: ColorRect
## +1 closing, -1 opening, 0 still. Advanced in _process with a clamped delta, so the hitch
## of a stage load (the frame a reveal starts in) cannot eat the wipe.
var _curtain_dir: int = 0
var _letterbox_tween: Tween
var _vignette_tween: Tween
var _spot_tween: Tween
var _closing: bool = false
var _opening: bool = false
var _closed_for: float = 0.0
var _slowmo_left: float = 0.0
var _ko_slot: int = -1
var _ko_target: WeakRef = null
var _spot: SpotLight3D
var _spot_target: WeakRef = null
var _main: Node = null
## Session phase the curtain already closed for (state * 1000 + round), so a failsafe-opened
## curtain does not close again in the same phase.
var _closed_phase: int = -1
var _app_state: int = -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_overlay()
	_build_spot()
	Session.state_changed.connect(_on_state_changed)
	Session.round_intro.connect(_on_round_intro)
	Session.round_started.connect(_on_round_started)
	Session.round_finished.connect(_on_round_finished)


func _process(delta: float) -> void:
	_connect_main()
	_tick_curtain(delta)
	if _slowmo_left > 0.0:
		_slowmo_left -= delta
		if _slowmo_left <= 0.0:
			_end_knockout()
	_follow_targets()


# --- Public API ----------------------------------------------------------------------------

## Screen shake on the active ArenaCamera (no-op without one).
func shake(amount: float) -> void:
	if not enabled:
		return
	var cam := arena_camera()
	if cam:
		cam.add_shake(amount)


## The ArenaCamera of the loaded minigame (or the viewport's, if it is one), or null.
func arena_camera() -> ArenaCamera:
	var stage := _stage()
	if stage and is_instance_valid(stage.minigame) and stage.minigame.is_inside_tree():
		for c in stage.minigame.get_children():
			if c is ArenaCamera:
				return c as ArenaCamera
	if not is_inside_tree():
		return null
	return get_viewport().get_camera_3d() as ArenaCamera


## Closes the curtain over CURTAIN_TIME (scaled by how open it is). Idempotent.
func close_curtain() -> void:
	if _closing or curtain >= 1.0:
		return
	_closing = true
	_opening = false
	_curtain_dir = 1
	_center_curtain()
	transition_changed.emit(true)


## Opens the curtain over CURTAIN_TIME. `from_closed` snaps it shut first (the stage just
## changed under it, so the reveal always reads as a wipe).
func open_curtain(from_closed: bool = true) -> void:
	if not enabled:
		return
	if from_closed:
		curtain = 1.0
	_closing = false
	if curtain <= 0.0:
		_opening = false
		_curtain_dir = 0
		return
	_opening = true
	_curtain_dir = -1
	_center_curtain()
	transition_changed.emit(false)


## True while the curtain is anything but fully open.
func is_transitioning() -> bool:
	return _closing or _opening or curtain > 0.0


## True while a knockout slow-motion runs.
func is_slowmo() -> bool:
	return _slowmo_left > 0.0


## The overlay never takes mouse input (tests check it).
func blocks_input() -> bool:
	for c: Control in [_curtain_rect, _vignette_rect, _bar_top, _bar_bottom]:
		if c.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return true
	return false


## Is the spotlight shining (on a winner)?
func is_spotlight_on() -> bool:
	return _spot != null and _spot.visible


## Ends every running moment at once: slow-motion, vignette, spotlight, letterbox (not the
## curtain). Called on every stage load; safe at any time.
func reset_moment() -> void:
	_slowmo_left = 0.0
	_ko_slot = -1
	_ko_target = null
	FeelTime.set_scale(1.0)
	_kill(_vignette_tween)
	vignette = 0.0
	_spot_off(true)
	_kill(_letterbox_tween)
	letterbox = 0.0


# --- Session / app handlers ----------------------------------------------------------------

func _on_round_intro(_info: Dictionary, _index: int) -> void:
	reset_moment()
	if not enabled:
		return
	open_curtain(true)
	letterbox = 1.0  # behind the curtain; lifts at GO
	var cam := arena_camera()
	if cam:
		cam.intro_sweep(INTRO_SWEEP_TIME)
	intro_started.emit()


func _on_round_started() -> void:
	var cam := arena_camera()
	if cam and cam.is_sweeping():
		cam.stop_sweep()  # play needs the real camera basis (camera-relative controls)
	_kill(_letterbox_tween)
	if letterbox > 0.0:
		_letterbox_tween = create_tween()
		_letterbox_tween.tween_property(self, ^"letterbox", 0.0, LETTERBOX_TIME) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)


func _on_state_changed(state: int) -> void:
	_closed_phase = -1
	if state == Session.State.LOBBY:
		reset_moment()
		open_curtain(true)


func _on_app_state_changed(state: int) -> void:
	# Title <-> anything: the world changes under the menu; wipe it in.
	if _app_state != -1 and (_app_state == 0) != (state == 0):
		open_curtain(true)
	_app_state = state


func _on_round_finished(ranking: Array, _points: Dictionary) -> void:
	if not enabled or ranking.is_empty():
		return
	var stage := _stage()
	if stage == null:
		return
	var winner := stage.get_player(int(ranking[0]))
	if winner == null or not is_instance_valid(winner) or not winner.is_inside_tree() or not winner.alive:
		return
	var total := 0
	var alive := 0
	for p: Player in stage.players.values():
		if is_instance_valid(p):
			total += 1
			if p.alive:
				alive += 1
	_celebrate(winner)
	if total >= 2 and alive == 1:
		_start_knockout(winner)


# --- Moments -------------------------------------------------------------------------------

func _celebrate(winner: Player) -> void:
	var visuals := winner.get_component(&"visuals") as VisualsComponent
	if visuals and visuals.get_emote() != &"cheer":
		visuals.play_emote(&"cheer", true)
	if Look.is_high():
		Fx.play(&"respawn_sparkle", winner.global_position, Look.GOLD)
		_spot_on(winner)
	winner_celebrated.emit(winner.slot)


func _start_knockout(winner: Player) -> void:
	_ko_slot = winner.slot
	_ko_target = weakref(winner)
	_slowmo_left = SLOWMO_TIME
	FeelTime.set_scale(SLOWMO_SCALE)
	var cam := arena_camera()
	if cam:
		cam.focus_on(winner, KO_FOCUS_TIME, maxf(cam.close_up_distance * 0.85, 4.5))
		cam.add_shake(KO_SHAKE)
	if Look.is_high():
		_kill(_vignette_tween)
		_vignette_tween = create_tween()
		_vignette_tween.tween_property(self, ^"vignette", 1.0, 0.15).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	knockout_started.emit(_ko_slot)


func _end_knockout() -> void:
	_slowmo_left = 0.0
	FeelTime.set_scale(1.0)
	var winner := _ko_target.get_ref() as Player if _ko_target else null
	if winner and is_instance_valid(winner) and winner.is_inside_tree():
		var at := winner.global_position + Vector3.UP * 1.2
		Fx.play(&"confetti", at)
		if Look.is_high():
			Fx.play(&"confetti", at + Vector3(-1.2, -0.4, 0.4))
			Fx.play(&"confetti", at + Vector3(1.2, -0.4, 0.4))
	_kill(_vignette_tween)
	if vignette > 0.0:
		_vignette_tween = create_tween()
		_vignette_tween.tween_interval(0.6)
		_vignette_tween.tween_property(self, ^"vignette", 0.0, 1.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var slot := _ko_slot
	_ko_slot = -1
	knockout_finished.emit(slot)


func _spot_on(target: Player) -> void:
	_spot_target = weakref(target)
	_spot.visible = true
	_spot.light_energy = 0.0
	_place_spot(target)
	_kill(_spot_tween)
	_spot_tween = create_tween()
	_spot_tween.tween_property(_spot, ^"light_energy", SPOT_ENERGY, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _spot_off(now: bool = false) -> void:
	_kill(_spot_tween)
	_spot_target = null
	if now or not _spot.visible:
		_spot.visible = false
		_spot.light_energy = 0.0
		return
	_spot_tween = create_tween()
	_spot_tween.tween_property(_spot, ^"light_energy", 0.0, 0.3)
	_spot_tween.tween_callback(_spot.hide)


func _place_spot(target: Node3D) -> void:
	var at := target.global_position
	_spot.global_position = at + Vector3(0.0, SPOT_HEIGHT, 1.5)
	_spot.look_at(at, Vector3.FORWARD)


# --- Per frame -----------------------------------------------------------------------------

func _tick_curtain(delta: float) -> void:
	if _curtain_dir != 0:
		curtain += float(_curtain_dir) * minf(delta, 1.0 / 30.0) / CURTAIN_TIME
		if _curtain_dir > 0 and curtain >= 1.0:
			_curtain_dir = 0
			_closing = false
			_closed_for = 0.0
		elif _curtain_dir < 0 and curtain <= 0.0:
			_curtain_dir = 0
			_opening = false
			transition_finished.emit()
		return
	if not enabled:
		return
	if curtain >= 1.0 and not _opening and not _closing:
		_closed_for += delta
		if _closed_for > CURTAIN_FAILSAFE:
			open_curtain(false)
		return
	if _closing or _opening or curtain > 0.0:
		return
	var leads_to_load := false
	match Session.state:
		Session.State.RESULTS:
			leads_to_load = Session.round_index + 1 < Session.round_count
		Session.State.PODIUM:
			leads_to_load = true
	var phase := int(Session.state) * 1000 + Session.round_index
	if not leads_to_load or phase == _closed_phase:
		return
	var rate := maxf(Session.time_scale, 0.0001)
	var left := Session.phase_time_left / rate
	if Session.phase_duration / rate >= CURTAIN_MIN_PHASE and left > 0.0 and left <= CURTAIN_TIME:
		_closed_phase = phase
		close_curtain()


func _follow_targets() -> void:
	if _spot.visible:
		var t := _spot_target.get_ref() as Node3D if _spot_target else null
		if t == null or not is_instance_valid(t) or not t.is_inside_tree():
			_spot_off()
		else:
			_place_spot(t)
	if vignette > 0.0:
		var t := _ko_target.get_ref() as Node3D if _ko_target else null
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if t and is_instance_valid(t) and t.is_inside_tree() and cam and not cam.is_position_behind(t.global_position):
			var size := get_viewport().get_visible_rect().size
			if size.x > 0.0 and size.y > 0.0:
				var uv := cam.unproject_position(t.global_position + Vector3.UP * 0.5) / size
				_vignette_mat.set_shader_parameter(&"center", uv.clamp(Vector2(0.2, 0.2), Vector2(0.8, 0.8)))
				_vignette_mat.set_shader_parameter(&"aspect", size.x / size.y)


func _connect_main() -> void:
	if not is_inside_tree():
		return
	var scene := get_tree().current_scene
	if scene == _main:
		return
	_main = scene
	if scene and scene.has_signal(&"app_state_changed"):
		var cb := Callable(self, &"_on_app_state_changed")
		if not scene.is_connected(&"app_state_changed", cb):
			scene.connect(&"app_state_changed", cb)
		var s: Variant = scene.get(&"app_state")
		_app_state = int(s) if s != null else -1


# --- Building ------------------------------------------------------------------------------

func _build_overlay() -> void:
	# Under the round UI (layer 10): letterbox bars and the vignette.
	_under = CanvasLayer.new()
	_under.name = "FeelUnder"
	_under.layer = 5
	add_child(_under)
	_vignette_mat = ShaderMaterial.new()
	_vignette_mat.shader = VIGNETTE_SHADER
	_vignette_rect = _full_rect("Vignette", Color.WHITE)
	_vignette_rect.material = _vignette_mat
	_under.add_child(_vignette_rect)
	_bar_top = _full_rect("LetterboxTop", BAR_COLOR)
	_bar_bottom = _full_rect("LetterboxBottom", BAR_COLOR)
	_under.add_child(_bar_top)
	_under.add_child(_bar_bottom)
	# Over everything (menus are layer 10/11): the transition curtain.
	_over = CanvasLayer.new()
	_over.name = "FeelOver"
	_over.layer = 120
	add_child(_over)
	_curtain_mat = ShaderMaterial.new()
	_curtain_mat.shader = CURTAIN_SHADER
	_curtain_rect = _full_rect("Curtain", Color.WHITE)
	_curtain_rect.material = _curtain_mat
	_over.add_child(_curtain_rect)
	curtain = 0.0
	vignette = 0.0
	letterbox = 0.0


func _build_spot() -> void:
	_spot = SpotLight3D.new()
	_spot.name = "WinnerSpot"
	_spot.light_color = Color(1.0, 0.92, 0.75)
	_spot.spot_range = SPOT_HEIGHT + 4.0
	_spot.spot_angle = 13.0
	_spot.spot_angle_attenuation = 0.6
	_spot.shadow_enabled = false
	_spot.light_energy = 0.0
	_spot.visible = false
	add_child(_spot)


func _full_rect(node_name: String, color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.name = node_name
	r.color = color
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.visible = false
	return r


func _layout_bars() -> void:
	if _bar_top == null:
		return
	var h := LETTERBOX_SIZE * _ease_out(letterbox)
	_bar_top.anchor_bottom = h
	_bar_top.offset_bottom = 0.0
	_bar_bottom.anchor_top = 1.0 - h
	_bar_bottom.offset_top = 0.0
	_bar_top.visible = letterbox > 0.0
	_bar_bottom.visible = letterbox > 0.0


func _center_curtain() -> void:
	if not is_inside_tree():
		return
	var size := get_viewport().get_visible_rect().size
	if size.y > 0.0:
		_curtain_mat.set_shader_parameter(&"aspect", size.x / size.y)


func _stage() -> Stage:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(&"stage") as Stage


static func _ease_out(t: float) -> float:
	return 1.0 - (1.0 - t) * (1.0 - t)


static func _kill(t: Tween) -> void:
	if t and t.is_valid():
		t.kill()
