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
##
## Game modes (v0.3, A3/A4; logic in res://modes/): the host's setup (`configure`: rounds,
## `order_mode` SHUFFLE / PLAYLIST / VOTE, the ticked `playlist`, `mutator_mode`) is sent to
## every peer, lobby included (`setup_changed`). Every mode only draws minigames that fit the
## player count (MinigameCatalog). VOTE adds a VOTE state before each round's INTRO: three
## candidates (`vote_candidates`), every player moves a marker (`vote(index, lock)`), bots vote
## at random, the host tallies (ties random) and sends `vote_decided`, then the INTRO of the
## winner. Mutators: the host rolls one per round from the minigame's allowed set
## (`mutator_blocklist`) and sends it with the INTRO (`round_mutator`, `info["mutator"]`); every
## peer applies it to every player for the round and takes it off at RESULTS.
## Practice (`start_practice(id, mutator)`): one round of `id`, normal INTRO/PLAYING/RESULTS,
## no points (all 0), no coins (Progression skips `practice` rounds), then straight to LOBBY.

## VOTE (appended, so the older values keep their numbers): the next round's vote.
enum State { LOBBY, INTRO, PLAYING, RESULTS, PODIUM, VOTE }

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
## The host's game setup reached this peer (`setup_rounds`, `order_mode`, `playlist`,
## `mutator_mode`), lobby included.
signal setup_changed
## VOTE started for round `index` (0-based): `candidates` (Array of StringName, the cards).
signal vote_started(candidates: Array, index: int)
## A player's marker moved or locked (`vote_marks`, `vote_locked`).
signal vote_updated
## The host tallied: `winner` indexes `vote_candidates`; the INTRO of `id` follows.
signal vote_decided(winner: int, id: StringName)
## This round's mutator changed on this peer (&"" = none / taken off).
signal mutator_changed(id: StringName)


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
## Seconds players have to vote (VOTE); it ends early once everyone locked.
@export var vote_time: float = 8.0
## Seconds the winning card shows before the INTRO.
@export var vote_reveal_time: float = 1.8

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

## Game setup, host decides (`configure`), every peer holds it. `setup_rounds` is the lobby's
## choice (start_session's `rounds` still wins); `playlist` the ticked ids (PLAYLIST and VOTE draw
## from them; empty = every id); `order_mode` GameModes.Order; `mutator_mode` Mutators.Mode.
var setup_rounds: int = 8
var order_mode: int = GameModes.Order.SHUFFLE
var playlist: Array[StringName] = []
var mutator_mode: int = Mutators.Mode.OFF
## Host, dev (`--mutator=<id>`): every round tries this mutator (when the minigame allows it).
var forced_mutator: StringName = &""
## Every peer: this session is a practice round (no points, no coins, back to LOBBY after).
var practice: bool = false
## Every peer: the mutator on every player this round (&"" = none). Set with the INTRO,
## cleared at RESULTS.
var round_mutator: StringName = &""
## Every peer, VOTE: the round being voted for, its candidates, slot -> marked candidate index,
## slot -> true once locked, and the winner (-1 until the host tallied).
var vote_index: int = -1
var vote_candidates: Array[StringName] = []
var vote_marks: Dictionary[int, int] = {}
var vote_locked: Dictionary[int, bool] = {}
var vote_winner: int = -1

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
## Host: per-round mutator rolls, vote draws and bot votes.
var _mode_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _last_mutator: StringName = &""
## Host: the practice round's mutator pick.
var _practice_mutator: StringName = &""
## Host, VOTE: bot slot -> [mark at (s), candidate, lock at (s)]; seconds into the vote.
var _bot_votes: Dictionary = {}
var _vote_elapsed: float = 0.0
## The Stage whose players_spawned we listen to (late spawns get the round's mutator).
var _watched_stage: Stage = null


func _ready() -> void:
	Net.roster_changed.connect(_on_roster_changed)
	Net.server_closed.connect(_on_server_closed)
	multiplayer.peer_connected.connect(_on_peer_connected)
	apply_dev_args(OS.get_cmdline_user_args())
	# The vote cards and the mutator badge (a CanvasLayer; loaded at runtime: it names autoloads).
	_add_overlay.call_deferred()


func _add_overlay() -> void:
	var overlay_script := load("res://modes/modes_overlay.gd") as GDScript
	if overlay_script and get_node_or_null(^"ModesOverlay") == null:
		add_child(overlay_script.new() as Node)


## Dev / smoke args: `--order=shuffle|playlist|vote`, `--playlist=id,id`,
## `--mutators=off|sometimes|always`, `--mutator=<id>` (every round, when allowed).
func apply_dev_args(args: PackedStringArray) -> void:
	for arg in args:
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() < 2:
			continue
		match kv[0]:
			"order":
				var i := _find_name(GameModes.ORDER_NAMES, kv[1])
				if i >= 0:
					order_mode = i
			"playlist":
				playlist.clear()
				for id in kv[1].split(",", false):
					playlist.append(StringName(id.strip_edges()))
			"mutators":
				var m := _find_name(Mutators.MODE_NAMES, kv[1])
				if m >= 0:
					mutator_mode = m
			"mutator":
				if Mutators.has(StringName(kv[1])):
					forced_mutator = StringName(kv[1])


static func _find_name(names: Array[String], text: String) -> int:
	for i in names.size():
		if names[i].to_lower() == text.to_lower():
			return i
	return -1


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
		_mode_rng.seed = order_seed + 7919
	else:
		rng.randomize()
		_mode_rng.randomize()
	_last_mutator = &""
	_practice_mutator = &""
	var pool := GameModes.pool(order_mode, playlist, Net.roster.size())
	if order_mode == GameModes.Order.VOTE:
		round_order = []
	else:
		round_order = build_round_order(rounds, rng, pool)
		if round_order.is_empty():
			push_warning("Session.start_session: the minigame registry is empty")
			return
	# Before the intro RPC goes out: refuse joiners from now on, and leave lobby mode now.
	# Turning follow_roster off sends the lobby's last manifest, which must reach clients
	# before the intro, not after (a late lobby manifest made clients rebuild round 1's
	# minigame without _setup/_start).
	Net.session_in_progress = true
	_stage().follow_roster = false
	if order_mode == GameModes.Order.VOTE:
		_begin_vote(0, rounds)
	else:
		_send_intro(0, rounds, false)


## Host only, from LOBBY: plays ONE round of `id` with the current roster (the normal INTRO /
## PLAYING / RESULTS flow, no points, no coins), then returns to LOBBY. `mutator`: a mutator id
## for the round (&"" = none; ignored if the minigame blocks it).
func start_practice(id: StringName, mutator: StringName = &"") -> void:
	if not Net.is_host() or state != State.LOBBY:
		return
	if not MinigameRegistry.has(id):
		push_warning("Session.start_practice: unknown minigame '%s'" % id)
		return
	var need := maxi(1, MinigameCatalog.min_players(id))
	if Net.roster.size() < need:
		push_warning("Session.start_practice: %s needs %d players, roster has %d" % [id, need, Net.roster.size()])
		return
	if _stage() == null:
		push_warning("Session.start_practice: no Stage in the tree (group 'stage')")
		return
	if order_seed >= 0:
		_mode_rng.seed = order_seed + 7919
	else:
		_mode_rng.randomize()
	_practice_mutator = mutator if Mutators.has(mutator) else &""
	_last_mutator = &""
	round_order = [id]
	Net.session_in_progress = true
	_stage().follow_roster = false
	_send_intro(0, 1, true)


## Host only: the game setup for the next session, sent to every peer (lobby summary).
## `order`: GameModes.Order; `ticked`: the playlist (ids); `mutators`: Mutators.Mode.
## Outside a game (or offline) it is just stored.
func configure(rounds: int, order: int, ticked: Array, mutators: int) -> void:
	var ids: Array = []
	for id: Variant in ticked:
		ids.append(str(id))
	if Net.is_host() and Net.local_slot() >= 0:
		_rpc_setup.rpc(rounds, order, ids, mutators)
	else:
		_rpc_setup(rounds, order, ids, mutators)


## Any peer, during VOTE: this peer's player puts its marker on candidate `index`; `lock` makes
## it final. The host decides (it ignores changes after a lock or after the tally).
func vote(index: int, lock: bool = false) -> void:
	var slot := Net.local_slot()
	if slot < 0 or state != State.VOTE:
		return
	if Net.is_host():
		_host_vote(slot, index, lock)
	else:
		_rpc_vote_input.rpc_id(1, index, lock)


## Every peer: the title-card line of the round's mutator ("" for none).
func mutator_line() -> String:
	return Mutators.card_line(round_mutator)


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


## `rounds` minigame ids from `from` (default: the registry): shuffled bags, so no id repeats
## until all have been played, and no id twice in a row across bags.
static func build_round_order(rounds: int, rng: RandomNumberGenerator, from: Array[StringName] = []) -> Array[StringName]:
	var order: Array[StringName] = []
	var pool: Array[StringName] = from.duplicate() if not from.is_empty() else MinigameRegistry.IDS.duplicate()
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
				var next := round_index + 1
				if practice:
					_rpc_lobby.rpc()
				elif next < round_count and order_mode == GameModes.Order.VOTE:
					_begin_vote(next, round_count)
				elif next < round_count and next < round_order.size():
					_send_intro(next, round_count, false)
				else:
					_go_podium()
		State.PODIUM:
			if phase_time_left <= 0.0:
				_rpc_lobby.rpc()
		State.VOTE:
			_tick_vote(delta)


## Host: sends round `index`'s INTRO (the planned id, swapped for one that fits the player
## count if needed) with its mutator.
func _send_intro(index: int, count: int, is_practice: bool) -> void:
	var id: StringName = round_order[index] if index < round_order.size() else &""
	if not is_practice and not MinigameCatalog.fits(id, Net.roster.size()):
		var pool := GameModes.pool(order_mode, playlist, Net.roster.size())
		var prev: StringName = round_order[index - 1] if index > 0 else &""
		if pool.size() > 1:
			pool.erase(prev)
		id = pool[_mode_rng.randi_range(0, pool.size() - 1)]
		round_order[index] = id
	var mode := Mutators.Mode.OFF if is_practice else mutator_mode
	var forced := _practice_mutator if is_practice else forced_mutator
	var mutator := Mutators.roll(mode, _blocklist_for(id), _mode_rng, forced, _last_mutator)
	if mutator != &"":
		_last_mutator = mutator
	_rpc_intro.rpc(index, count, String(id), intro_time + countdown_time, is_practice, String(mutator))


## The minigame's `mutator_blocklist` without loading its whole scene: an instance of its root
## script alone (no children, never in the tree), or the scene's own override of the property.
func _blocklist_for(id: StringName) -> Array:
	var scene: PackedScene = scene_override
	if scene == null and MinigameRegistry.has(id):
		scene = load(MinigameRegistry.scene_path(id)) as PackedScene
	if scene == null:
		return []
	var st := scene.get_state()
	var script: Script = null
	for i in st.get_node_property_count(0):
		var prop := st.get_node_property_name(0, i)
		if prop == &"mutator_blocklist":
			var v: Variant = st.get_node_property_value(0, i)
			return (v as Array).duplicate() if v is Array else []
		if prop == &"script":
			script = st.get_node_property_value(0, i) as Script
	if script == null or not script.can_instantiate():
		return []
	var probe: Object = script.new()
	var out := Mutators.blocklist_of(probe).duplicate()
	if probe is Node:
		(probe as Node).free()
	return out


# --- Vote (host) -----------------------------------------------------------------------------

func _begin_vote(index: int, count: int) -> void:
	var pool := GameModes.pool(order_mode, playlist, Net.roster.size())
	var last: StringName = round_order[index - 1] if index > 0 and index - 1 < round_order.size() else &""
	var candidates := GameModes.pick_candidates(pool, _mode_rng, last, round_order)
	_bot_votes.clear()
	for s: int in Net.roster:
		if Net.roster[s].is_bot:
			var mark_at := _mode_rng.randf_range(0.6, vote_time * 0.45)
			_bot_votes[s] = [mark_at, _mode_rng.randi_range(0, candidates.size() - 1),
				_mode_rng.randf_range(mark_at + 0.5, vote_time * 0.8)]
	var names: Array = []
	for id in candidates:
		names.append(String(id))
	_rpc_vote_start.rpc(index, count, names, vote_time)


func _tick_vote(delta: float) -> void:
	_vote_elapsed += delta * time_scale
	if vote_winner < 0:
		for s: int in _bot_votes.keys():
			var plan: Array = _bot_votes[s]
			if not Net.roster.has(s):
				_bot_votes.erase(s)
			elif not vote_marks.has(s) and _vote_elapsed >= float(plan[0]):
				_host_vote(s, int(plan[1]), false)
			elif not vote_locked.has(s) and _vote_elapsed >= float(plan[2]):
				_host_vote(s, int(plan[1]), true)
		if phase_time_left <= 0.0:
			var votes: Dictionary = {}
			for s: int in vote_marks:
				if Net.roster.has(s):
					votes[s] = vote_marks[s]
			_rpc_vote_result.rpc(GameModes.tally(votes, vote_candidates.size(), _mode_rng), vote_reveal_time)
	elif phase_time_left <= 0.0:
		var id := vote_candidates[clampi(vote_winner, 0, vote_candidates.size() - 1)]
		if round_order.size() <= vote_index:
			round_order.resize(vote_index + 1)
		round_order[vote_index] = id
		_send_intro(vote_index, round_count, false)


func _host_vote(slot: int, index: int, lock: bool) -> void:
	if state != State.VOTE or vote_winner >= 0 or vote_locked.has(slot) or not Net.roster.has(slot):
		return
	if index < 0 or index >= vote_candidates.size():
		return
	_rpc_vote_mark.rpc(slot, index, lock)
	if lock and _all_locked():
		phase_time_left = minf(phase_time_left, 0.5)


func _all_locked() -> bool:
	for s: int in Net.roster:
		if not vote_locked.has(s):
			return false
	return true


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
	if practice:
		_end_practice_round(ranking)
		return
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


## Practice: the same results, every point 0, totals and wins untouched.
func _end_practice_round(ranking: Array) -> void:
	var clean: Array = []
	for g: Array in Minigame.normalize_ranking(ranking):
		var kept: Array[int] = []
		for s: int in g:
			if Net.roster.has(s):
				kept.append(s)
		if not kept.is_empty():
			clean.append(kept)
	var points: Dictionary = {}
	for s: int in Net.roster:
		points[s] = 0
	var sizes: Array[int] = []
	for g: Array in clean:
		sizes.append(g.size())
	var totals: Dictionary = {}
	for s: int in scores:
		totals[s] = scores[s]
	var wins: Dictionary = {}
	for s: int in round_wins:
		wins[s] = round_wins[s]
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
	if not Net.is_host() or practice:
		return  # practice plays on with whoever is left (a minigame ends itself when needed)
	if (state == State.INTRO or state == State.PLAYING or state == State.RESULTS or state == State.VOTE) \
			and Net.roster.size() < min_players:
		_go_podium()


func _on_server_closed() -> void:
	_rpc_lobby()


## Host: a peer joined. It gets the game setup (the lobby summary); mid-session it spectates
## until the next round and gets the current state, scores, mutator and vote now.
func _on_peer_connected(peer_id: int) -> void:
	if not Net.is_host():
		return
	_rpc_setup.rpc_id(peer_id, setup_rounds, order_mode, _playlist_strings(), mutator_mode)
	if state == State.LOBBY:
		return
	_rpc_snapshot.rpc_id(peer_id, state, round_index, round_count, scores, round_wins, phase_duration, phase_time_left, snapshot_extra())


## The mode fields a late joiner needs (also read by tests).
func snapshot_extra() -> Dictionary:
	var cands: Array = []
	for id in vote_candidates:
		cands.append(String(id))
	return {
		"practice": practice, "mutator": String(round_mutator), "vote_index": vote_index,
		"vote_candidates": cands, "vote_marks": vote_marks.duplicate(), "vote_locked": vote_locked.duplicate(),
		"vote_winner": vote_winner,
	}


func _playlist_strings() -> Array:
	var out: Array = []
	for id in playlist:
		out.append(String(id))
	return out


# --- Replicated transitions (host -> every peer, host included) ----------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_setup(rounds: int, order: int, ticked: Array, mutators: int) -> void:
	setup_rounds = maxi(1, rounds)
	order_mode = clampi(order, 0, GameModes.ORDER_NAMES.size() - 1)
	playlist.clear()
	for id: Variant in ticked:
		playlist.append(StringName(str(id)))
	mutator_mode = clampi(mutators, 0, Mutators.MODE_NAMES.size() - 1)
	setup_changed.emit()


## `is_practice`: a practice round. `mutator`: this round's mutator id ("" = none), applied to
## every player on every peer.
@rpc("authority", "call_local", "reliable")
func _rpc_intro(index: int, count: int, id: String, duration: float, is_practice: bool = false, mutator: String = "") -> void:
	practice = is_practice
	_clear_mutator()
	_clear_vote()
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
	var info := {"id": StringName(id), "title": "", "rule_text": "", "mutator": StringName(mutator),
		"mutator_line": Mutators.card_line(StringName(mutator)), "practice": is_practice}
	_round_player_count = current_minigame.players.size() if current_minigame else Net.roster.size()
	if current_minigame:
		info["title"] = current_minigame.title
		info["rule_text"] = current_minigame.rule_text
		if Net.is_host():
			current_minigame.finished.connect(_on_minigame_finished.bind(current_minigame))
		current_minigame.active_mutator = StringName(mutator) if Mutators.has(StringName(mutator)) else &""
		current_minigame._setup(current_minigame.players)
	_watch_stage(stage)
	_set_mutator(StringName(mutator))
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
	_clear_mutator()
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
	_clear_mutator()
	_clear_vote()
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
	_clear_mutator()
	_clear_vote()
	practice = false
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


## Late joiner: current state, no round events (it spectates until the next round). `extra`:
## snapshot_extra() (practice, the round's mutator, the vote).
@rpc("authority", "call_remote", "reliable")
func _rpc_snapshot(new_state: int, index: int, count: int, totals: Dictionary, wins: Dictionary, duration: float, time_left: float, extra: Dictionary = {}) -> void:
	round_index = index
	round_count = count
	_assign_totals(totals, wins)
	apply_snapshot_extra(new_state, extra)
	_set_phase(new_state as State, duration)
	phase_time_left = time_left


## The mode part of a late joiner's snapshot (`snapshot_extra()` from the host).
func apply_snapshot_extra(new_state: int, extra: Dictionary) -> void:
	practice = bool(extra.get("practice", false))
	_clear_vote()
	vote_index = int(extra.get("vote_index", -1))
	for id: Variant in extra.get("vote_candidates", []):
		vote_candidates.append(StringName(str(id)))
	var marks: Dictionary = extra.get("vote_marks", {})
	for s: Variant in marks:
		vote_marks[int(s)] = int(marks[s])
	var locked: Dictionary = extra.get("vote_locked", {})
	for s: Variant in locked:
		vote_locked[int(s)] = true
	vote_winner = int(extra.get("vote_winner", -1))
	_watch_stage(_stage())
	var playing := new_state == State.INTRO or new_state == State.PLAYING
	_set_mutator(StringName(str(extra.get("mutator", ""))) if playing else &"")


## Every peer: VOTE for round `index` of `count` between `candidates` (ids as Strings).
@rpc("authority", "call_local", "reliable")
func _rpc_vote_start(index: int, count: int, candidates: Array, duration: float) -> void:
	_clear_mutator()
	_clear_vote()
	round_count = count
	vote_index = index
	for id: Variant in candidates:
		vote_candidates.append(StringName(str(id)))
	_vote_elapsed = 0.0
	for p in _stage_players():
		p.frozen = true
	_set_phase(State.VOTE, duration)
	vote_started.emit(vote_candidates.duplicate(), index)


## A client's vote input reaches the host (the sender's own human slot only).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_vote_input(index: int, lock: bool) -> void:
	if not Net.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	for s: int in Net.roster:
		var info: PlayerInfo = Net.roster[s]
		if info.peer_id == sender and not info.is_bot:
			_host_vote(s, index, lock)
			return


@rpc("authority", "call_local", "reliable")
func _rpc_vote_mark(slot: int, index: int, lock: bool) -> void:
	vote_marks[slot] = index
	if lock:
		vote_locked[slot] = true
	vote_updated.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_vote_result(winner: int, reveal: float) -> void:
	vote_winner = winner
	phase_duration = reveal
	phase_time_left = reveal
	var id: StringName = vote_candidates[winner] if winner >= 0 and winner < vote_candidates.size() else &""
	vote_decided.emit(winner, id)


func _clear_vote() -> void:
	vote_index = -1
	vote_candidates.clear()
	vote_marks.clear()
	vote_locked.clear()
	vote_winner = -1


# --- Mutators (every peer) ------------------------------------------------------------------

## Puts `id` on every player of the stage (&"" takes it off) and mirrors this peer's input if
## the mutator says so.
func _set_mutator(id: StringName) -> void:
	if not Mutators.has(id):
		id = &""
	var changed := id != round_mutator
	round_mutator = id
	for p in _stage_players():
		Mutators.apply_to(p, id)
	var m := Mutators.get_mutator(id)
	Mutators.set_mirror(m != null and m.mirror)
	if changed and is_instance_valid(current_minigame):
		current_minigame.active_mutator = id
		current_minigame._mutator_changed(id)
	if changed:
		mutator_changed.emit(id)


func _clear_mutator() -> void:
	_set_mutator(&"")


## Players that spawn after the INTRO (a client's manifest) get the round's mutator too.
func _watch_stage(stage: Stage) -> void:
	if stage == null or stage == _watched_stage:
		return
	if is_instance_valid(_watched_stage) and _watched_stage.players_spawned.is_connected(_on_players_spawned):
		_watched_stage.players_spawned.disconnect(_on_players_spawned)
	_watched_stage = stage
	stage.players_spawned.connect(_on_players_spawned)


func _on_players_spawned(spawned: Array[Player]) -> void:
	if round_mutator == &"" or not (state == State.INTRO or state == State.PLAYING):
		return
	for p in spawned:
		Mutators.apply_to(p, round_mutator)


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
