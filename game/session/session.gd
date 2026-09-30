extends Node
## Autoload `Session`: round order, scores and the flow lobby -> rounds -> podium.
## Owner: session.
##
## Host-driven state machine: LOBBY -> INTRO -> PLAYING -> RESULTS -> (INTRO of the next
## round | PODIUM) -> LOBBY. The host decides every transition and sends it with one
## `call_local` RPC, so the fields and signals change the same way on every peer
## (the host runs the same handler). Each transition first updates the fields, then emits
## `state_changed`, then the event of that state (`round_intro`, `round_started`,
## `round_finished`, `session_finished`).
##
## Per round, on every peer: Stage loads the minigame and spawns frozen players ->
## `_setup(players)` -> INTRO (title card + countdown) -> players unfrozen, `_start()` ->
## PLAYING (host calls `_host_tick` every physics frame) until the minigame emits
## `finished(ranking)` on the host. Backstop: `time_limit_grace` seconds after the
## minigame's `time_limit`, Session finishes it itself: survivors (alive, by slot) share
## first place, then the knocked-out in reverse order.
##
## Scoring: 1st 4, 2nd 3, 3rd 2, 4th 1, the rest (and anyone missing from the ranking) 0.
## Final ranking: total desc, then round wins desc, then slot asc.

enum State { LOBBY, INTRO, PLAYING, RESULTS, PODIUM }

signal state_changed(state: State)
## `info`: `{ "id": StringName, "title": String, "rule_text": String }`; `index` is 0-based.
signal round_intro(info: Dictionary, index: int)
signal round_started
## `ranking`: slots, best first. `points`: slot -> points earned this round.
signal round_finished(ranking: Array[int], points: Dictionary)
signal session_finished(final_ranking: Array[int])

## Points by place (index 0 = first); places beyond the table score 0.
const PLACE_POINTS: Array[int] = [4, 3, 2, 1]

## Seconds the title card shows before the countdown.
@export var intro_time: float = 3.0
## Seconds of the 3-2-1 countdown (the last part of INTRO).
@export var countdown_time: float = 3.0
## Seconds the round results stay up (covers the round UI's ranking + bar race, ~6.5 s).
@export var results_time: float = 7.0
## Seconds on the podium before returning to the lobby.
@export var podium_time: float = 8.0
## Seconds past the minigame's `time_limit` before Session finishes the round itself.
@export var time_limit_grace: float = 1.0
## Fewer players than this: start_session is ignored, a running session ends early.
@export var min_players: int = 2
## Multiplies how fast Session's own timers run (phases and the time-limit backstop);
## tests raise it. Does not change the delta passed to `_host_tick`.
@export var time_scale: float = 1.0

## Seed for the round order; -1 = random. Host only.
var order_seed: int = -1
## Tests/tools: when set, every round loads this scene (root extends Minigame) instead of
## the registry scene; the round's id still comes from the registry order.
var scene_override: PackedScene = null

var state: State = State.LOBBY
## slot -> total points.
var scores: Dictionary[int, int] = {}
## slot -> rounds won (first place). Tie-break for the final ranking.
var round_wins: Dictionary[int, int] = {}
## 0-based index of the current round, -1 before the first.
var round_index: int = -1
var round_count: int = 0
var current_minigame: Minigame = null
## Minigame ids for every round of the running session. Host only.
var round_order: Array[StringName] = []
## Length of the current phase in seconds (INTRO: intro + countdown; PLAYING: the time
## limit, 0 = none; RESULTS; PODIUM). Replicated; UIs can derive the countdown from it.
var phase_duration: float = 0.0
## Seconds left in the current phase (counts down on every peer at `time_scale`).
var phase_time_left: float = 0.0

## Seconds of play in the current round (scaled), host only.
var _play_elapsed: float = 0.0
## A ranking the minigame emitted during INTRO, applied when play starts. Host only.
var _pending_ranking: Array[int] = []
var _has_pending: bool = false
## Slots that share first place (set by the time-limit backstop). Host only.
var _tied_top: Array[int] = []


func _ready() -> void:
	Net.roster_changed.connect(_on_roster_changed)
	Net.server_closed.connect(_on_server_closed)
	multiplayer.peer_connected.connect(_on_peer_connected)


# --- Public API ------------------------------------------------------------------------

## Host only. Starts a session of `rounds` rounds with the current roster. Ignored when
## not in LOBBY, with fewer than `min_players`, or without a Stage in the tree.
func start_session(rounds: int) -> void:
	if not Net.is_host() or state != State.LOBBY:
		return
	if rounds < 1:
		push_warning("Session.start_session: rounds must be >= 1 (got %d)" % rounds)
		return
	if Net.roster.size() < min_players:
		push_warning("Session.start_session: needs %d players, roster has %d" % [min_players, Net.roster.size()])
		return
	if _stage() == null:
		push_warning("Session.start_session: no Stage in the tree (group 'stage')")
		return
	var rng := RandomNumberGenerator.new()
	if order_seed >= 0:
		rng.seed = order_seed
	else:
		rng.randomize()
	round_order = build_round_order(rounds, rng)
	if round_order.is_empty():
		push_warning("Session.start_session: the minigame registry is empty")
		return
	_rpc_intro.rpc(0, rounds, String(round_order[0]), intro_time + countdown_time)


## Host only: leaves the podium early (the podium's "Back to lobby" button) and returns
## every peer to LOBBY. Ignored in any other state.
func return_to_lobby() -> void:
	if Net.is_host() and state == State.PODIUM:
		_rpc_lobby.rpc()


## Ends any running session and returns to LOBBY (host: on every peer). Also resets the
## stage. Safe to call in any state.
func abort_session() -> void:
	if Net.is_host():
		if state != State.LOBBY:
			_rpc_lobby.rpc()
	else:
		_rpc_lobby()


## `rounds` minigame ids from the registry: shuffled bags, so no id repeats until all
## have been played, and no id twice in a row across bags.
static func build_round_order(rounds: int, rng: RandomNumberGenerator) -> Array[StringName]:
	var order: Array[StringName] = []
	var pool: Array[StringName] = MinigameRegistry.IDS.duplicate()
	if pool.is_empty():
		return order
	while order.size() < rounds:
		var bag: Array[StringName] = pool.duplicate()
		for i in range(bag.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var tmp := bag[i]
			bag[i] = bag[j]
			bag[j] = tmp
		if not order.is_empty() and bag.size() > 1 and bag[0] == order.back():
			var k := rng.randi_range(1, bag.size() - 1)
			bag[0] = bag[k]
			bag[k] = order.back()
		order.append_array(bag)
	order.resize(rounds)
	return order


## slot -> points for a round `ranking` (best first). The first `tied_top` entries all
## score first place; the rest score by position (competition ranking).
static func points_for_ranking(ranking: Array[int], tied_top: int = 1) -> Dictionary:
	var points: Dictionary = {}
	for i in ranking.size():
		var place := 0 if i < tied_top else i
		points[ranking[i]] = PLACE_POINTS[place] if place < PLACE_POINTS.size() else 0
	return points


## `slots` sorted by total desc, round wins desc, slot asc.
static func rank_totals(slots: Array[int], totals: Dictionary, wins: Dictionary) -> Array[int]:
	var out: Array[int] = slots.duplicate()
	out.sort_custom(func(a: int, b: int) -> bool:
		var ta: int = totals.get(a, 0)
		var tb: int = totals.get(b, 0)
		if ta != tb:
			return ta > tb
		var wa: int = wins.get(a, 0)
		var wb: int = wins.get(b, 0)
		if wa != wb:
			return wa > wb
		return a < b)
	return out


# --- Host flow ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if state == State.LOBBY:
		return
	phase_time_left = maxf(0.0, phase_time_left - delta * time_scale)
	if not Net.is_host():
		return
	match state:
		State.INTRO:
			if phase_time_left <= 0.0:
				var limit := current_minigame.time_limit if is_instance_valid(current_minigame) else 0.0
				_rpc_play.rpc(limit)
				if _has_pending and state == State.PLAYING:
					_has_pending = false
					_end_round(_pending_ranking)
		State.PLAYING:
			_tick_playing(delta)
		State.RESULTS:
			if phase_time_left <= 0.0:
				if round_index + 1 < round_count and round_index + 1 < round_order.size():
					var next := round_index + 1
					_rpc_intro.rpc(next, round_count, String(round_order[next]), intro_time + countdown_time)
				else:
					_go_podium()
		State.PODIUM:
			if phase_time_left <= 0.0:
				_rpc_lobby.rpc()


func _tick_playing(delta: float) -> void:
	if not is_instance_valid(current_minigame):
		_end_round([])
		return
	if not current_minigame.is_finished():
		current_minigame._host_tick(delta)
	if state != State.PLAYING:
		return  # the minigame finished during its tick
	_play_elapsed += delta * time_scale
	var limit := current_minigame.time_limit
	if limit > 0.0 and _play_elapsed >= limit + time_limit_grace:
		_force_finish()


## Time-limit backstop: survivors share first place (by slot), then the knocked-out in
## reverse order. Finishes the minigame so its own logic stops too.
func _force_finish() -> void:
	var survivors: Array[int] = []
	for p in current_minigame.players:
		if is_instance_valid(p) and p.alive:
			survivors.append(p.slot)
	survivors.sort()
	var ranking: Array[int] = survivors.duplicate()
	for i in range(current_minigame.knocked_out.size() - 1, -1, -1):
		var s := current_minigame.knocked_out[i]
		if not ranking.has(s):
			ranking.append(s)
	_tied_top = survivors
	current_minigame.finish(ranking)
	if state == State.PLAYING:  # finish() was ignored (already finished earlier)
		_end_round(ranking)


func _on_minigame_finished(ranking: Array[int], minigame: Minigame) -> void:
	if minigame != current_minigame:
		return
	if state == State.PLAYING:
		_end_round(ranking)
	elif state == State.INTRO:
		_pending_ranking = ranking.duplicate()
		_has_pending = true


## Host: scores the round and sends RESULTS. Slots not in the roster are dropped;
## roster slots missing from the ranking score 0.
func _end_round(ranking: Array[int]) -> void:
	var clean: Array[int] = []
	for s in ranking:
		if Net.roster.has(s) and not clean.has(s):
			clean.append(s)
	var tied := 1
	if not _tied_top.is_empty():
		tied = 0
		for s in clean:
			if _tied_top.has(s):
				tied += 1
		tied = maxi(tied, 1)
	_tied_top = []
	var points := points_for_ranking(clean, tied)
	for s: int in Net.roster:
		if not points.has(s):
			points[s] = 0
	var totals: Dictionary = {}
	for s: int in scores:
		totals[s] = scores[s]
	var wins: Dictionary = {}
	for s: int in round_wins:
		wins[s] = round_wins[s]
	for s: int in points:
		totals[s] = int(totals.get(s, 0)) + int(points[s])
	for i in mini(tied, clean.size()):
		wins[clean[i]] = int(wins.get(clean[i], 0)) + 1
	_rpc_results.rpc(clean, points, totals, wins, results_time)


func _go_podium() -> void:
	var slots: Array[int] = []
	slots.assign(Net.roster.keys())
	var final := rank_totals(slots, scores, round_wins)
	var totals: Dictionary = {}
	for s: int in scores:
		totals[s] = scores[s]
	var wins: Dictionary = {}
	for s: int in round_wins:
		wins[s] = round_wins[s]
	_rpc_podium.rpc(final, totals, wins, podium_time)


func _on_roster_changed() -> void:
	if Net.roster.is_empty():
		if state != State.LOBBY:
			_rpc_lobby()  # we left the game: reset locally
		return
	if not Net.is_host():
		return
	if (state == State.INTRO or state == State.PLAYING or state == State.RESULTS) \
			and Net.roster.size() < min_players:
		_go_podium()


func _on_server_closed() -> void:
	_rpc_lobby()


## Host: a peer joined mid-session; it spectates until the next round and gets the
## current state and scores now.
func _on_peer_connected(peer_id: int) -> void:
	if not Net.is_host() or state == State.LOBBY:
		return
	_rpc_snapshot.rpc_id(peer_id, state, round_index, round_count, scores, round_wins, phase_duration, phase_time_left)


# --- Replicated transitions (host -> every peer, host included) ----------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_intro(index: int, count: int, id: String, duration: float) -> void:
	if index == 0:
		if Net.is_host():
			Net.session_in_progress = true
		scores.clear()
		round_wins.clear()
		for s: int in Net.roster:
			scores[s] = 0
			round_wins[s] = 0
	round_index = index
	round_count = count
	_play_elapsed = 0.0
	_has_pending = false
	_pending_ranking = []
	_tied_top = []
	current_minigame = null
	var stage := _stage()
	if stage:
		# Rounds never follow the roster (the lobby does): leavers are knocked out, and every
		# peer must pick the same spawn points (by roster order, not by slot).
		stage.follow_roster = false
		if scene_override:
			current_minigame = stage.load_minigame_scene(scene_override)
		else:
			current_minigame = stage.load_minigame(StringName(id))
	else:
		push_error("Session: no Stage in the tree (group 'stage') to load '%s'" % id)
	var info := {"id": StringName(id), "title": "", "rule_text": ""}
	if current_minigame:
		info["title"] = current_minigame.title
		info["rule_text"] = current_minigame.rule_text
		if Net.is_host():
			current_minigame.finished.connect(_on_minigame_finished.bind(current_minigame))
		current_minigame._setup(current_minigame.players)
	_set_phase(State.INTRO, duration)
	round_intro.emit(info, index)


@rpc("authority", "call_local", "reliable")
func _rpc_play(time_limit: float) -> void:
	_play_elapsed = 0.0
	for p in _stage_players():
		p.frozen = false
	if is_instance_valid(current_minigame):
		current_minigame._start()
	_set_phase(State.PLAYING, time_limit)
	round_started.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_results(ranking: Array, points: Dictionary, totals: Dictionary, wins: Dictionary, duration: float) -> void:
	var r: Array[int] = []
	for s: Variant in ranking:
		r.append(int(s))
	var pts: Dictionary = {}
	for s: Variant in points:
		pts[int(s)] = int(points[s])
	_assign_totals(totals, wins)
	for p in _stage_players():
		p.frozen = true
	_set_phase(State.RESULTS, duration)
	round_finished.emit(r, pts)


@rpc("authority", "call_local", "reliable")
func _rpc_podium(final_ranking: Array, totals: Dictionary, wins: Dictionary, duration: float) -> void:
	var r: Array[int] = []
	for s: Variant in final_ranking:
		r.append(int(s))
	_assign_totals(totals, wins)
	for p in _stage_players():
		p.frozen = true
	_set_phase(State.PODIUM, duration)
	session_finished.emit(r)


## Back to LOBBY: clears the stage, keeps `scores` of the last session for the lobby UI.
@rpc("authority", "call_local", "reliable")
func _rpc_lobby() -> void:
	if Net.is_host():
		Net.session_in_progress = false
	var stage := _stage()
	if stage:
		stage.clear()
	current_minigame = null
	round_index = -1
	round_count = 0
	round_order = []
	_play_elapsed = 0.0
	_has_pending = false
	_pending_ranking = []
	_tied_top = []
	if state != State.LOBBY:
		_set_phase(State.LOBBY, 0.0)
	else:
		phase_duration = 0.0
		phase_time_left = 0.0


## Late joiner: current state, no round events (it spectates until the next round).
@rpc("authority", "call_remote", "reliable")
func _rpc_snapshot(new_state: int, index: int, count: int, totals: Dictionary, wins: Dictionary, duration: float, time_left: float) -> void:
	round_index = index
	round_count = count
	_assign_totals(totals, wins)
	_set_phase(new_state as State, duration)
	phase_time_left = time_left


# --- Helpers -------------------------------------------------------------------------------

func _set_phase(new_state: State, duration: float) -> void:
	state = new_state
	phase_duration = duration
	phase_time_left = duration
	state_changed.emit(new_state)


func _assign_totals(totals: Dictionary, wins: Dictionary) -> void:
	scores.clear()
	for s: Variant in totals:
		scores[int(s)] = int(totals[s])
	round_wins.clear()
	for s: Variant in wins:
		round_wins[int(s)] = int(wins[s])


func _stage() -> Stage:
	return get_tree().get_first_node_in_group(&"stage") as Stage


func _stage_players() -> Array[Player]:
	var out: Array[Player] = []
	var stage := _stage()
	if stage:
		for p: Player in stage.players.values():
			if is_instance_valid(p):
				out.append(p)
	return out
