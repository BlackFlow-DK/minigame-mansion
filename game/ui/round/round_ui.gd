class_name RoundUI
extends CanvasLayer
## In-round UI (`res://ui/round/round_ui.tscn`). Owner: round UI.
## Driven only by the `Session` signals/state, `Net.roster` and the players' `eliminated` /
## `respawned` events (players found through the Stage group). Every peer runs its own copy.
##
##   round_intro       -> title card slides in, then 3-2-1 (expects round_started about
##                        RoundIntroCard.LEAD_SECONDS later; an earlier one cuts it short)
##   round_started     -> HUD: GO!, round x/y, time left (Minigame.time_limit > 0), player strip
##   round_finished    -> results: round ranking with points, then a bar race of totals
##                        (reads Session.scores as totals INCLUDING this round's points)
##   session_finished  -> podium with confetti; "Back to lobby" shows for the host after
##                        BACK_BUTTON_HOST_DELAY s, and for everyone once state is LOBBY
##   state_changed(LOBBY) with no podium up -> everything hidden
##
## Minigame-facing API (the only calls a minigame makes; local to this peer, so call it on
## every peer, e.g. from the minigame's own RPC). Without a RoundUI in the tree they do nothing:
##   RoundUI.push_counter(slot, value)       # per-player counter on the strip (coins, ...)
##   RoundUI.push_banner(text, seconds)      # big centre banner, e.g. "SUDDEN DEATH!"
## or, without referencing the class: get_tree().call_group(&"round_ui", &"set_counter", slot, value)
## and get_tree().call_group(&"round_ui", &"show_banner", text, seconds).
## Counters reset at every round_intro.

## Pressed "Back to lobby" (the UI has already hidden itself).
signal back_to_lobby_pressed

enum View { NONE, INTRO, HUD, RESULTS, PODIUM }

const GROUP := &"round_ui"
const BACK_BUTTON_HOST_DELAY := 3.0

var intro: RoundIntroCard
var hud: RoundHud
var results: RoundResults
var podium: RoundPodium
## The panel on screen now.
var view: View = View.NONE

var _root: Control
var _banner: PanelContainer
var _banner_label: Label
var _banner_tween: Tween
var _podium_tween: Tween
## Instance ids of the players whose events are connected.
var _bound: Dictionary[int, bool] = {}


# --- Minigame-facing static accessors ------------------------------------------------

## The RoundUI in the running scene tree, or null.
static func get_instance() -> RoundUI:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.get_first_node_in_group(GROUP) as RoundUI


## Shows `value` on the counter of player `slot`. No-op without a RoundUI.
static func push_counter(slot: int, value: int) -> void:
	var ui := get_instance()
	if ui:
		ui.set_counter(slot, value)


## Shows a centre banner for `seconds`. No-op without a RoundUI.
static func push_banner(text: String, seconds: float = 2.0) -> void:
	var ui := get_instance()
	if ui:
		ui.show_banner(text, seconds)


# --- Lifecycle -----------------------------------------------------------------------

func _enter_tree() -> void:
	add_to_group(GROUP)
	if is_node_ready():
		_connect_session(true)


func _exit_tree() -> void:
	_connect_session(false)


## Listens to Session only while in the tree (a removed, not yet freed UI stays silent).
func _connect_session(on: bool) -> void:
	var pairs: Array[Array] = [
		[Session.state_changed, _on_state_changed],
		[Session.round_intro, _on_round_intro],
		[Session.round_started, _on_round_started],
		[Session.round_finished, _on_round_finished],
		[Session.session_finished, _on_session_finished],
	]
	for pair in pairs:
		var sig: Signal = pair[0]
		var target: Callable = pair[1]
		if on and not sig.is_connected(target):
			sig.connect(target)
		elif not on and sig.is_connected(target):
			sig.disconnect(target)


func _ready() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.theme = RoundStyle.get_theme()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	hud = RoundHud.new()
	hud.name = "Hud"
	_root.add_child(hud)
	intro = RoundIntroCard.new()
	intro.name = "Intro"
	_root.add_child(intro)
	results = RoundResults.new()
	results.name = "Results"
	_root.add_child(results)
	podium = RoundPodium.new()
	podium.name = "Podium"
	_root.add_child(podium)
	podium.back_pressed.connect(_on_back_pressed)
	_build_banner()
	RoundStyle.ignore_mouse(_root)

	_connect_session(true)
	_show(View.NONE)


# --- Public API ----------------------------------------------------------------------

func set_counter(slot: int, value: int) -> void:
	hud.set_counter(slot, value)


func clear_counters() -> void:
	hud.clear_counters()


func show_banner(text: String, seconds: float = 2.0) -> void:
	_banner_label.text = text
	_banner.visible = true
	_banner.reset_size()
	_banner.pivot_offset = _banner.get_combined_minimum_size() * 0.5
	_banner.scale = Vector2(0.3, 0.3)
	_banner.modulate.a = 1.0
	_banner.rotation_degrees = -6.0
	if _banner_tween and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, ^"scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.parallel().tween_property(_banner, ^"rotation_degrees", 0.0, 0.4).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_banner_tween.tween_interval(maxf(0.0, seconds - 0.55))
	_banner_tween.tween_property(_banner, ^"modulate:a", 0.0, 0.25)
	_banner_tween.tween_callback(_banner.hide)


## Hides every panel and the banner at once (the app left the game, e.g. to the title).
func reset() -> void:
	_show(View.NONE)
	if _banner_tween and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner.visible = false


func is_banner_shown() -> bool:
	return _banner.visible


func get_banner_text() -> String:
	return _banner_label.text


## Listens to `player`'s eliminated/respawned events (idempotent). Called automatically for
## the Stage's players; public for scenes that spawn players another way.
func bind_player(player: Player) -> void:
	if player == null:
		return
	var id := player.get_instance_id()
	if _bound.has(id):
		return
	_bound[id] = true
	player.eliminated.connect(_on_player_eliminated.bind(player.slot))
	player.respawned.connect(_on_player_respawned.bind(player.slot))
	player.tree_exiting.connect(_unbind.bind(id), CONNECT_ONE_SHOT)


# --- Session handlers ------------------------------------------------------------------

func _on_state_changed(state: int) -> void:
	if state != Session.State.LOBBY:
		return
	if view == View.PODIUM:
		podium.show_back_button()
	else:
		_show(View.NONE)


func _on_round_intro(info: Dictionary, index: int) -> void:
	hud.rebuild()
	_bind_players()
	intro.play(str(info.get("title", "")), str(info.get("rule_text", "")), index, Session.round_count)
	_show(View.INTRO)


func _on_round_started() -> void:
	_bind_players()
	var minigame := Session.current_minigame
	if minigame == null:
		var stage := _find_stage()
		minigame = stage.minigame if stage else null
	_show(View.HUD)
	hud.start(minigame.time_limit if minigame else 0.0)


func _on_round_finished(ranking: Array, points: Dictionary) -> void:
	hud.stop()
	var totals: Dictionary = {}
	for slot: int in Session.scores:
		totals[slot] = Session.scores[slot]
	for s: Variant in points:
		if not totals.has(int(s)):
			totals[int(s)] = int(points[s])
	results.play(ranking, points, totals)
	_show(View.RESULTS)


func _on_session_finished(final_ranking: Array) -> void:
	hud.stop()
	var totals: Dictionary = {}
	for slot: int in Session.scores:
		totals[slot] = Session.scores[slot]
	podium.play(final_ranking, totals)
	_show(View.PODIUM)
	if _podium_tween and _podium_tween.is_valid():
		_podium_tween.kill()
	_podium_tween = create_tween()
	_podium_tween.tween_interval(BACK_BUTTON_HOST_DELAY)
	_podium_tween.tween_callback(func() -> void:
		if view == View.PODIUM and Net.is_host():
			podium.show_back_button())


func _on_back_pressed() -> void:
	_show(View.NONE)
	back_to_lobby_pressed.emit()


# --- Internals -----------------------------------------------------------------------

func _show(v: View) -> void:
	view = v
	intro.visible = v == View.INTRO
	hud.visible = v == View.HUD
	results.visible = v == View.RESULTS
	podium.visible = v == View.PODIUM
	if v != View.INTRO:
		intro.stop()
	if v != View.RESULTS:
		results.stop()
	if v != View.PODIUM:
		podium.stop()
		if _podium_tween and _podium_tween.is_valid():
			_podium_tween.kill()
	if v != View.HUD:
		hud.stop()


func _find_stage() -> Stage:
	return get_tree().get_first_node_in_group(&"stage") as Stage


func _bind_players() -> void:
	var stage := _find_stage()
	if stage == null:
		return
	if not stage.players_spawned.is_connected(_on_players_spawned):
		stage.players_spawned.connect(_on_players_spawned)
	for p: Player in stage.players.values():
		bind_player(p)


func _unbind(id: int) -> void:
	_bound.erase(id)


func _on_player_eliminated(_reason: StringName, slot: int) -> void:
	hud.set_eliminated(slot, true)


func _on_player_respawned(_xform: Transform3D, slot: int) -> void:
	hud.set_eliminated(slot, false)


func _on_players_spawned(spawned: Array) -> void:
	for p: Variant in spawned:
		bind_player(p as Player)


func _build_banner() -> void:
	var center := RoundStyle.centered()
	center.name = "Banner"
	center.offset_bottom = -200.0
	_root.add_child(center)
	var style := RoundStyle.box(RoundStyle.RED, RoundStyle.CHARCOAL, 6, 22)
	style.content_margin_left = 36.0
	style.content_margin_right = 36.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	_banner = RoundStyle.panel(style)
	center.add_child(_banner)
	_banner_label = RoundStyle.label("", 52, RoundStyle.CREAM, 12)
	_banner.add_child(_banner_label)
	_banner.visible = false
