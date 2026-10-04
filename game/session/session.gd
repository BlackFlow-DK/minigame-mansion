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
## first place (one tied group), then the knocked-out in reverse order.
##
## Ties: Session scores the minigame's `finish_groups` (Array of `Array[int]`, best first; a
## group of 2+ is a tie, e.g. the time-out survivors or a team). Every member of a group gets
## the points of the group's best place; the next group's place counts the tied players
## (competition ranking: 1, 1, 3). Every member of the first group gets a round win.
## Signals: `round_finished(ranking, points)` keeps the flat order (groups flattened), then
## `round_ranked(groups, points)` follows with the groups; `round_groups` holds them from
## RESULTS until the next round's intro.
##
## End grace: a minigame that finishes with `finish(ranking, grace)` keeps the round on screen:
## Session sends `_rpc_end_grace(grace)` (every peer freezes all players and counts `end_grace`
## down), stays in PLAYING, and the host scores the round when the grace runs out. The
## time-limit backstop does not interrupt it.
##
## Scoring scales with the players in the round, so most players score most rounds
## (`place_points`): 2-3 players 3/2/1; 4-5 players 4/3/2/1; 6-8 players 5/4/3/2/1/1. Places
## past the table (and anyone missing from the ranking) score 0.
## Final ranking: total desc, then round wins desc, then slot asc.

enum State { LOBBY, INTRO, PLAYING, RESULTS, PODIUM }

signal state_changed(state: State)
## `info`: `{ "id": StringName, "title": String, "rule_text": String }`; `index` is 0-based.
signal round_intro(info: Dictionary, index: int)
signal round_started
## `ranking`: slots, best first (tied groups flattened). `points`: slot -> points this round.
signal round_finished(ranking: Array[int], points: Dictionary)
## Right after `round_finished`: the same ranking as tied groups (Array of `Array[int]`, best
## first; flattened it is `ranking`).
signal round_ranked(groups: Array, points: Dictionary)
signal session_finished(final_ranking: Array[int])


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
## Multiplies how fast a session's clocks run: Session's own timers (phases and the
## time-limit backstop) and the delta passed to the minigame's `_host_tick`, so a minigame
## that counts time in `_host_tick` stays in step with the backstop. Tests and smokes raise
## it; player physics still runs at normal speed.
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
## Seconds left of a minigame's end grace (0 = none): the round is over, everyone is frozen,
## RESULTS follows when it reaches 0. Replicated; counts down on every peer at `time_scale`.
var end_grace: float = 0.0
## The last round's ranking as tied groups (Array of `Array[int]`, best first), set on every
## peer just before `round_finished`; empty from the next round's intro (and in LOBBY).
var round_groups: Array = []

## Seconds of play in the current round (scaled), host only.
var _play_elapsed: float = 0.0
## Ranking groups the minigame finished with during INTRO, applied when play starts. Host only.
var _pending_ranking: Array = []
var _has_pending: bool = false
## Players the current round started with (picks the points table).
var _round_player_count: int = 0
## The ranking groups waiting for the end grace to run out. Host only.
var _grace_ranking: Array = []
var _grace_active: bool = false


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
	# Before the intro RPC goes out: refuse joiners from now on, and leave lobby mode now.
	# Turning follow_roster off sends the lobby's last manifest, which must reach clients
	# before the intro, not after (a late lobby manifest made clients rebuild round 1's
	# minigame without _setup/_start).
	Net.session_in_progress = true
	_stage().follow_roster = false
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


## Points by place (index 0 = first) for a round of `player_count` players; places past
## the table score 0.
static func place_points(player_count: int) -> Array[int]:
	if player_count <= 3:
		return [3, 2, 1]
	if player_count <= 5:
		return [4, 3, 2, 1]
	return [5, 4, 3, 2, 1, 1]


## slot -> points for a round `ranking` (best first) of `player_count` players (-1: the
## ranking's length). The first `tied_top` entries all score first place; the rest score by
## position (competition ranking). Shorthand for `points_for_groups`.
static func points_for_ranking(ranking: Array[int], tied_top: int = 1, player_count: int = -1) -> Dictionary:
	var groups: Array = []
	var top: Array[int] = []
	for i in ranking.size():
		if i < tied_top:
			top.append(ranking[i])
		else:
			if not top.is_empty():
				groups.append(top)
				top = []
			groups.append([ranking[i]] as Array[int])
	if not top.is_empty():
		groups.append(top)
	return points_for_groups(groups, player_count)


## slot -> points for ranking `groups` (Array of slot Arrays, best first) of `player_count`
## players (-1: the slots in `groups`). Every member of a group scores the group's best place;
## places count the players before it (1, 1, 3). Places past the table score 0.
static func points_for_groups(groups: Array, player_count: int = -1) -> Dictionary:
	var total := 0
	for g: Array in groups:
		total += g.size()
	var table := place_points(player_count if player_count > 0 else total)
	var points: Dictionary = {}
	var place := 0
	for g: Array in groups:
		for s: Variant in g:
			points[int(s)] = table[place] if place < table.size() else 0
		place += g.size()
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
	end_grace = maxf(0.0, end_grace - delta * time_scale)
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
	if _grace_active:
		if end_grace <= 0.0:
			_grace_active = false
			_end_round(_grace_ranking)
		return
	if not is_instance_valid(current_minigame):
		_end_round([])
		return
	if not current_minigame.is_finished():
		current_minigame._host_tick(delta * time_scale)
	if state != State.PLAYING or _grace_active:
		return  # the minigame finished during its tick
	_play_elapsed += delta * time_scale
	var limit := current_minigame.time_limit
	if limit > 0.0 and _play_elapsed >= limit + time_limit_grace:
		_force_finish()


## Time-limit backstop: survivors share first place (one tied group, by slot), then the
## knocked-out in reverse order. Finishes the minigame so its own logic stops too.
func _force_finish() -> void:
	var survivors: Array[int] = []
	for p in current_minigame.players:
		if is_instance_valid(p) and p.alive:
			survivors.append(p.slot)
	survivors.sort()
	var groups: Array = [survivors]
	for i in range(current_minigame.knocked_out.size() - 1, -1, -1):
		groups.append(current_minigame.knocked_out[i])
	groups = Minigame.normalize_ranking(groups)
	current_minigame.finish(groups)
	if state == State.PLAYING and not _grace_active:  # finish() was ignored (already finished earlier)
		_end_round(groups)


func _on_minigame_finished(ranking: Array[int], minigame: Minigame) -> void:
	if minigame != current_minigame:
		return
	# The groups finish() normalised; a bare `finished` emit (no finish()) is all singles.
	var groups: Array = minigame.finish_groups.duplicate(true)
	if Minigame.flatten_groups(groups) != ranking:
		groups = Minigame.normalize_ranking(ranking)
	if state == State.PLAYING:
		if minigame.finish_grace > 0.0 and not _grace_active:
			_grace_ranking = groups
			_grace_active = true
			_rpc_end_grace.rpc(minigame.finish_grace)
		elif not _grace_active:
			_end_round(groups)
	elif state == State.INTRO:
		_pending_ranking = groups
		_has_pending = true


## Host: scores the round and sends RESULTS. `ranking`: slots and/or tied groups, best first
## (see Minigame.finish). Slots not in the roster are dropped; roster slots missing from the
## ranking score 0.
func _end_round(ranking: Array) -> void:
	var clean: Array = []
	for g: Array in Minigame.normalize_ranking(ranking):
		var kept: Array[int] = []
		for s: int in g:
			if Net.roster.has(s):
				kept.append(s)
		if not kept.is_empty():
			clean.append(kept)
	# The table goes by who started the round (a leaver does not shrink it).
	var count := _round_player_count if _round_player_count > 0 else Net.roster.size()
	var points := points_for_groups(clean, count)
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
	if not clean.is_empty():
		for s: int in clean[0]:
			wins[s] = int(wins.get(s, 0)) + 1
	var sizes: Array[int] = []
	for g: Array in clean:
		sizes.append(g.size())
	_rpc_results.rpc(Minigame.flatten_groups(clean), points, totals, wins, results_time, sizes)


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
	round_groups = []
	_clear_grace()
	current_minigame = null
	var stage := _stage()
	if stage:
		# Rounds never follow the roster (the lobby does): leavers are knocked out, and every
		# peer must pick the same spawn points (by roster order, not by slot). The host
		# already turned it off in start_session (so this sends nothing); clients got it with
		# the lobby's last manifest, this is a local safety net.
		stage.follow_roster = false
		if scene_override:
			current_minigame = stage.load_minigame_scene(scene_override)
		else:
			current_minigame = stage.load_minigame(StringName(id))
	else:
		push_error("Session: no Stage in the tree (group 'stage') to load '%s'" % id)
	var info := {"id": StringName(id), "title": "", "rule_text": ""}
	_round_player_count = current_minigame.players.size() if current_minigame else Net.roster.size()
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


## `ranking` flat, best first; `group_sizes` cuts it into the tied groups (sums to its size).
@rpc("authority", "call_local", "reliable")
func _rpc_results(ranking: Array, points: Dictionary, totals: Dictionary, wins: Dictionary, duration: float, group_sizes: Array) -> void:
	var r: Array[int] = []
	for s: Variant in ranking:
		r.append(int(s))
	var pts: Dictionary = {}
	for s: Variant in points:
		pts[int(s)] = int(points[s])
	round_groups = groups_from_sizes(r, group_sizes)
	_assign_totals(totals, wins)
	_clear_grace()
	for p in _stage_players():
		p.frozen = true
	_set_phase(State.RESULTS, duration)
	round_finished.emit(r, pts)
	round_ranked.emit(round_groups.duplicate(true), pts)


## `flat` cut into groups of `sizes` (anything left over: one slot per group).
static func groups_from_sizes(flat: Array[int], sizes: Array) -> Array:
	var groups: Array = []
	var i := 0
	for n: Variant in sizes:
		var g: Array[int] = []
		for k in maxi(int(n), 0):
			if i < flat.size():
				g.append(flat[i])
				i += 1
		if not g.is_empty():
			groups.append(g)
	while i < flat.size():
		groups.append([flat[i]] as Array[int])
		i += 1
	return groups


@rpc("authority", "call_local", "reliable")
func _rpc_podium(final_ranking: Array, totals: Dictionary, wins: Dictionary, duration: float) -> void:
	var r: Array[int] = []
	for s: Variant in final_ranking:
		r.append(int(s))
	_assign_totals(totals, wins)
	_clear_grace()
	for p in _stage_players():
		p.frozen = true
	_set_phase(State.PODIUM, duration)
	session_finished.emit(r)


## The round is decided; hold it on screen for `seconds` (every player frozen) before RESULTS.
@rpc("authority", "call_local", "reliable")
func _rpc_end_grace(seconds: float) -> void:
	end_grace = maxf(0.0, seconds)
	for p in _stage_players():
		p.frozen = true


func _clear_grace() -> void:
	end_grace = 0.0
	_grace_active = false
	_grace_ranking = []


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
	round_groups = []
	_clear_grace()
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
