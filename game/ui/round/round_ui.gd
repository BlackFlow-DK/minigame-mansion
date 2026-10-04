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
##                        (reads Session.scores as totals INCLUDING this round's points);
##                        "+N coins" this player earned (Progression.local_round_award)
##   session_finished  -> podium with confetti; "Back to lobby" shows for the host after
##                        BACK_BUTTON_HOST_DELAY s, and for everyone once state is LOBBY;
##                        a coins card: the session bonus and the balance counting up.
##                        With a Stage and its last minigame still loaded, the real blobs
##                        stand on a 3D podium (RoundPodiumStage: the host respawns them
##                        there, every peer poses them with play_result_pose for their final
##                        place) and the panel only adds captions; poses stop when it closes
##   state_changed(LOBBY) with no podium up -> everything hidden
##
## Minigame-facing API (the only calls a minigame makes; local to this peer, so call it on
## every peer, e.g. from the minigame's own RPC). Without a RoundUI in the tree they do nothing:
##   RoundUI.push_counter(slot, value)       # per-player counter on the strip (coins, ...)
##   RoundUI.push_banner(text, seconds)      # big centre banner, e.g. "SUDDEN DEATH!"
## or, without referencing the class: get_tree().call_group(&"round_ui", &"set_counter", slot, value)
## and get_tree().call_group(&"round_ui", &"show_banner", text, seconds).
## Counters reset at every round_intro.
##
## Teams and roles (Minigame.assign_teams / set_role_text, read from the round's minigame and
## its `teams_changed` / `role_changed`): the intro card shows this player's team and role
## line, the HUD strip groups the players by team, the results list a team or any tied group
## (Session.round_groups) on one line, and a role line also shows as a banner after GO!.
## All of it is per round: the next round_intro starts without.

## Emote hint: in the lobby hall (Session LOBBY, this peer in a game, the Stage following the
## roster) a small "1-4 / D-pad: emotes" pill sits bottom-left until this player's first emote
## key press, then fades for good (this app run).
const EMOTE_HINT_TEXT := "1-4 / D-pad: emotes"
const EMOTE_ACTIONS: Array[StringName] = [&"emote_1", &"emote_2", &"emote_3", &"emote_4"]
static var emote_hint_used: bool = false

## Seconds after round_started before the role banner (lets "GO!" clear first).
const ROLE_BANNER_DELAY := 1.0
const ROLE_BANNER_SECONDS := 2.6

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
## The 3D podium behind the podium panel (null when none is up).
var podium_stage: RoundPodiumStage = null

var _root: Control
var _banner: PanelContainer
var _banner_label: Label
var _banner_tween: Tween
var _emote_hint: PanelContainer
var _emote_hint_tween: Tween
var _podium_tween: Tween
var _role_tween: Tween
## The minigame whose teams_changed / role_changed this UI listens to.
var _watched: Minigame = null
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
	_build_emote_hint()
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
	if _role_tween and _role_tween.is_valid():
		_role_tween.kill()
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
	_watch_minigame(RoundStyle.current_minigame())
	hud.rebuild()
	_bind_players()
	intro.play(str(info.get("title", "")), str(info.get("rule_text", "")), index, Session.round_count)
	_refresh_intro_team()
	_show(View.INTRO)


func _on_round_started() -> void:
	_bind_players()
	var minigame := RoundStyle.current_minigame()
	_watch_minigame(minigame)
	_show(View.HUD)
	hud.start(minigame.time_limit if minigame else 0.0)
	var role := minigame.role_of(Net.local_slot()) if minigame else ""
	if role != "":
		_queue_role_banner(role)


func _on_round_finished(ranking: Array, points: Dictionary) -> void:
	hud.stop()
	var totals: Dictionary = {}
	for slot: int in Session.scores:
		totals[slot] = Session.scores[slot]
	for s: Variant in points:
		if not totals.has(int(s)):
			totals[int(s)] = int(points[s])
	results.play(ranking, points, totals, Progression.local_round_award(ranking, points),
		RoundStyle.groups_for(ranking), RoundStyle.current_teams())
	_show(View.RESULTS)


# --- Teams and roles -------------------------------------------------------------------

## Follows `minigame`'s team and role changes (drops the previous round's minigame).
func _watch_minigame(minigame: Minigame) -> void:
	if minigame == _watched:
		return
	if is_instance_valid(_watched):
		if _watched.teams_changed.is_connected(_on_teams_changed):
			_watched.teams_changed.disconnect(_on_teams_changed)
		if _watched.role_changed.is_connected(_on_role_changed):
			_watched.role_changed.disconnect(_on_role_changed)
	_watched = minigame
	if minigame:
		minigame.teams_changed.connect(_on_teams_changed)
		minigame.role_changed.connect(_on_role_changed)


func _on_teams_changed() -> void:
	hud.layout_teams()
	_refresh_intro_team()


func _on_role_changed(slot: int, text: String) -> void:
	if slot != Net.local_slot():
		return
	intro.set_role(text)
	if view == View.HUD and text != "":
		show_banner(text, ROLE_BANNER_SECONDS)


func _refresh_intro_team() -> void:
	var m := RoundStyle.current_minigame()
	var me := Net.local_slot()
	intro.set_team(m.team_of(me) if m else -1)
	intro.set_role(m.role_of(me) if m else "")


func _queue_role_banner(text: String) -> void:
	if _role_tween and _role_tween.is_valid():
		_role_tween.kill()
	_role_tween = create_tween()
	_role_tween.tween_interval(ROLE_BANNER_DELAY)
	_role_tween.tween_callback(func() -> void:
		if view == View.HUD:
			show_banner(text, ROLE_BANNER_SECONDS))


func _on_session_finished(final_ranking: Array) -> void:
	hud.stop()
	var totals: Dictionary = {}
	for slot: int in Session.scores:
		totals[slot] = Session.scores[slot]
	var staged := _build_podium_stage(final_ranking, totals)
	podium.play(final_ranking, totals, Progression.local_session_award(final_ranking), staged)
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


## Puts up the 3D podium on the Stage's last minigame (every peer; the host places the
## players). False when there is no stage or minigame to put it on (the panel then draws
## its own podium).
func _build_podium_stage(ranking: Array, totals: Dictionary) -> bool:
	_clear_podium_stage()
	var stage := _find_stage() if is_inside_tree() else null
	if stage == null or not is_instance_valid(stage.minigame) or not stage.minigame.is_inside_tree():
		return false
	var s := RoundPodiumStage.new()
	s.name = "PodiumStage"
	s.position = RoundPodiumStage.OFFSET
	stage.minigame.add_child(s)
	s.setup(stage)
	s.pose_players(ranking, totals, Session.round_wins)
	s.place_players(ranking)
	s.tree_exiting.connect(_on_podium_stage_gone.bind(s), CONNECT_ONE_SHOT)
	podium_stage = s
	return true


func _clear_podium_stage() -> void:
	if is_instance_valid(podium_stage):
		podium_stage.stop_poses()
		if podium_stage.tree_exiting.is_connected(_on_podium_stage_gone):
			podium_stage.tree_exiting.disconnect(_on_podium_stage_gone)
		podium_stage.queue_free()
	podium_stage = null


## The stage was cleared under the podium (e.g. back in the lobby): the panel dims again.
func _on_podium_stage_gone(s: RoundPodiumStage) -> void:
	if s == podium_stage:
		podium_stage = null
		podium.set_staged(false)


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
		_clear_podium_stage()
		if _podium_tween and _podium_tween.is_valid():
			_podium_tween.kill()
	if v != View.HUD:
		hud.stop()
		if _role_tween and _role_tween.is_valid():
			_role_tween.kill()  # a role banner still waiting belongs to the round that ended
	_hide_name_tags(v == View.RESULTS or v == View.PODIUM)


## The 3D name tags (Stage.name_tags) would show through the results / podium dim: hidden
## while those panels are up, back (their own visibility rules) after.
func _hide_name_tags(hide: bool) -> void:
	if not is_inside_tree():
		return  # reset() while the app is being torn down
	var stage := _find_stage()
	if stage == null:
		return
	var bodies: Array[Player] = []
	bodies.assign(stage.players.values())
	bodies.append_array(stage.extras)  # NPC extras with opted-in tags (Stage.extra_name_tags)
	for p in bodies:
		if not is_instance_valid(p):
			continue
		var tag := p.get_node_or_null(^"NameTag") as Node3D
		if tag == null:
			continue
		tag.set_process(not hide)
		if hide:
			tag.visible = false


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


## True while the emote hint should be up (see EMOTE_HINT_TEXT).
func emote_hint_wanted() -> bool:
	if emote_hint_used or view != View.NONE or Net.local_slot() < 0 or Session.state != Session.State.LOBBY:
		return false
	var stage := _find_stage() if is_inside_tree() else null
	return stage != null and stage.follow_roster and stage.minigame != null


func is_emote_hint_shown() -> bool:
	return _emote_hint != null and _emote_hint.visible


func _process(_delta: float) -> void:
	if _emote_hint == null or (_emote_hint_tween and _emote_hint_tween.is_valid()):
		return
	var want := emote_hint_wanted()
	if want != _emote_hint.visible:
		_emote_hint.visible = want
		if want:
			_emote_hint.modulate.a = 0.0
			_emote_hint_tween = create_tween()
			_emote_hint_tween.tween_property(_emote_hint, ^"modulate:a", 1.0, 0.4)


func _input(event: InputEvent) -> void:
	if emote_hint_used or not is_emote_hint_shown():
		return
	for action in EMOTE_ACTIONS:
		if event.is_action_pressed(action):
			emote_hint_used = true
			if _emote_hint_tween and _emote_hint_tween.is_valid():
				_emote_hint_tween.kill()
			_emote_hint_tween = create_tween()
			_emote_hint_tween.tween_interval(0.6)
			_emote_hint_tween.tween_property(_emote_hint, ^"modulate:a", 0.0, 0.5)
			_emote_hint_tween.tween_callback(_emote_hint.hide)
			return


func _build_emote_hint() -> void:
	var style := RoundStyle.box(Color(RoundStyle.CHARCOAL, 0.85), RoundStyle.CREAM.darkened(0.3), 2, 14, false)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 6.0
	_emote_hint = RoundStyle.panel(style)
	_emote_hint.name = "EmoteHint"
	_emote_hint.anchor_top = 1.0
	_emote_hint.anchor_bottom = 1.0
	_emote_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_emote_hint.offset_left = 24.0
	_emote_hint.offset_bottom = -84.0  # clear of the lobby's bottom bar
	_root.add_child(_emote_hint)
	_emote_hint.add_child(RoundStyle.label(EMOTE_HINT_TEXT, 20, RoundStyle.CREAM, 5))
	_emote_hint.visible = false


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
