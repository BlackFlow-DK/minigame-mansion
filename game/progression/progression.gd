extends Node
## Autoload `Progression`: Mansion Coins and cosmetic unlocks of the player on this PC.
## Owner: progression. Design: docs/superpowers/specs/2026-09-30-night-features-design.md §4.
##
## Every peer awards ITSELF from the Session signals it already receives: no network traffic,
## no host involvement, nothing synced. Coins, unlocks and stats live in this player's own
## `user://profile.json` (through `Cosmetics.load_progress` / `save_progress`).
##
##   round_finished   -> the local human gets coins by placement: 1st 6, 2nd 4, 3rd 3, else 2
##                       (only when in the round's ranking; slots sharing first place all get 6)
##   session_finished -> session bonus by final placement: 1st 40, 2nd 25, 3rd 15, else 10
##   offline sessions (`Net.start_offline`) earn half of both, rounded up; bots never earn
##   award(reason, amount)  -> generic reward, one-time per reason by default (the tutorial
##                             calls `Progression.award(&"tutorial", 20)` once)
##
## Unlocks only gate the local wardrobe: `is_unlocked(slot, id)` is true for the starter set
## (catalog `free`), bought items and everything under `--unlock-all` / `dev_unlock_all()`
## (testing only; never written to the profile). Colours and sizes are always free.
## Loadouts from the network are never checked against unlocks (`Cosmetics.sanitize` keeps them).
##
## Saving: on by default; off in test runs (a `--script` main loop) and in dev runs (the
## MainApp dev args, `--screenshot=`, the sandbox args, `--coins=N`), so they never touch the
## real profile. Dev: `--coins=N` starts this run with N coins (not saved); `--unlock-all`.

## The balance changed (award, unlock, reload).
signal coins_changed(total: int)
## Coins were given: `reason` &"round", &"session" or the `award()` reason.
signal awarded(reason: StringName, amount: int, total: int)
## Something became unlocked (`id` "" after `dev_unlock_all`).
signal unlocks_changed(slot: StringName, id: String)

## Coins per round by placement (index 0 = 1st); anyone else in the ranking gets the last value.
const ROUND_COINS: Array[int] = [6, 4, 3]
const ROUND_COINS_TAKING_PART := 2
## Session bonus by final placement; everyone else in the final ranking gets the last value.
const SESSION_COINS: Array[int] = [40, 25, 15]
const SESSION_COINS_TAKING_PART := 10
## User args that make a run a dev/test run (no saving). Mirrors MainApp.DEV_ARGS plus tooling.
const DEV_ARGS: Array[String] = ["name", "offline", "auto-host", "auto-join", "bots", "auto-start",
	"round-time", "time-scale", "round-minigame", "open-wardrobe", "min-players", "fps", "screenshot",
	"sandbox", "minigame", "players", "coins"]

## Mansion Coins of the local player.
var coins: int = 0
## "slot:id" of every item bought (the starter set is not listed: it is free).
var unlocked: Array[String] = []
## Counters for a later stats page: sessions_played, session_wins, podiums, rounds_played,
## rounds_won, coins_earned, items_unlocked.
var stats: Dictionary = {}
## Reasons of one-time rewards already given.
var claimed: Array[String] = []
## Write changes to the profile. See the header for when it starts off.
var persist: bool = true
## Offline sessions earn half (rounded up). Dev scenes may turn it off for screenshots.
var offline_half_rate: bool = true
## Everything counts as unlocked (testing only: `--unlock-all`, `dev_unlock_all()`).
var unlock_all: bool = false
## Coins the last round / session gave the local player (0 if none). For the round UI.
var last_round_award: int = 0
var last_session_award: int = 0

var _arg_unlock_all: bool = false
var _arg_coins: int = -1


func _ready() -> void:
	var tool_run := get_tree().get_script() != null
	var args := parse_args(OS.get_cmdline_user_args())
	_arg_unlock_all = args["unlock_all"]
	_arg_coins = args["coins"]
	if args["dev"]:
		persist = false
	if tool_run:
		persist = false
		unlock_all = _arg_unlock_all
	else:
		reload()
	if _arg_coins >= 0:
		coins = _arg_coins
		coins_changed.emit(coins)
	Session.round_finished.connect(_on_round_finished)
	Session.session_finished.connect(_on_session_finished)


## User args -> `{unlock_all: bool, coins: int (-1 = not given), dev: bool (a dev/test run:
## do not save)}`.
static func parse_args(args: PackedStringArray) -> Dictionary:
	var out := {"unlock_all": false, "coins": -1, "dev": false}
	for arg in args:
		if not arg.begins_with("--"):
			continue
		if arg == "--unlock-all":
			out["unlock_all"] = true
		elif arg.begins_with("--coins=") and arg.trim_prefix("--coins=").is_valid_int():
			out["coins"] = maxi(0, int(arg.trim_prefix("--coins=")))
		if DEV_ARGS.has(arg.trim_prefix("--").split("=", true, 1)[0]):
			out["dev"] = true
	return out


## Testing: what `--unlock-all` would do (reload/reset keep it on).
func set_unlock_all_arg(on: bool) -> void:
	_arg_unlock_all = on
	unlock_all = on


# --- State -----------------------------------------------------------------------------------

## Reads coins, unlocks, stats and claimed rewards from the profile (`Cosmetics.profile_path`).
## Clears `dev_unlock_all()` unless the run has `--unlock-all`.
func reload() -> void:
	var p := Cosmetics.load_progress()
	coins = p["coins"]
	unlocked.assign(p["unlocked"])
	stats = p["stats"]
	claimed.assign(p["claimed"])
	unlock_all = _arg_unlock_all
	last_round_award = 0
	last_session_award = 0
	coins_changed.emit(coins)


## Forgets everything in memory (not on disk): 0 coins, nothing bought. Tests.
func reset() -> void:
	coins = 0
	unlocked.clear()
	stats = {}
	claimed.clear()
	unlock_all = _arg_unlock_all
	last_round_award = 0
	last_session_award = 0
	coins_changed.emit(coins)


## Writes the progress to the profile when `persist`. Returns OK when skipped.
func save() -> Error:
	if not persist:
		return OK
	return Cosmetics.save_progress({"coins": coins, "unlocked": unlocked, "stats": stats, "claimed": claimed})


# --- Earning ---------------------------------------------------------------------------------

## Gives `amount` coins for `reason`. With `once` (default) a reason pays only the first time
## (later calls return 0), e.g. `award(&"tutorial", 20)`. Returns the coins actually given.
func award(reason: StringName, amount: int, once: bool = true) -> int:
	if amount <= 0 or reason == &"":
		return 0
	if once:
		if claimed.has(String(reason)):
			return 0
		claimed.append(String(reason))
	_grant(reason, amount)
	save()
	return amount


## True if the one-time reward `reason` was already given.
func has_claimed(reason: StringName) -> bool:
	return claimed.has(String(reason))


## True when this is an offline game (`Net.start_offline`): sessions earn half.
func is_offline() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer == null or peer is OfflineMultiplayerPeer


## Placement (1-based) of `slot` in a round: its index in `ranking`, except that slots with the
## winner's points (time-out survivors) share 1st. 0 if `slot` is not in the ranking.
static func round_place(ranking: Array, points: Dictionary, slot: int) -> int:
	var i := ranking.find(slot)
	if i < 0:
		return 0
	if i > 0 and points.has(slot) and points.has(ranking[0]):
		var mine := int(points[slot])
		if mine > 0 and mine == int(points[ranking[0]]):
			return 1
	return i + 1


## Coins a round gives `slot` (0 for a bot or a slot not in the ranking), halved (rounded up)
## when `offline`.
func round_award(ranking: Array, points: Dictionary, slot: int, offline: bool) -> int:
	if not _is_human(slot):
		return 0
	var place := round_place(ranking, points, slot)
	if place == 0:
		return 0
	var coins_for := ROUND_COINS[place - 1] if place <= ROUND_COINS.size() else ROUND_COINS_TAKING_PART
	return _rate(coins_for, offline)


## Session bonus for `slot` at its place in `final_ranking` (0 for a bot or a missing slot).
func session_award(final_ranking: Array, slot: int, offline: bool) -> int:
	if not _is_human(slot):
		return 0
	var i := final_ranking.find(slot)
	if i < 0:
		return 0
	return _rate(SESSION_COINS[i] if i < SESSION_COINS.size() else SESSION_COINS_TAKING_PART, offline)


## What the local player gets for this round (what the results screen shows).
func local_round_award(ranking: Array, points: Dictionary) -> int:
	return round_award(ranking, points, Net.local_slot(), is_offline())


## What the local player gets for this session (what the podium shows).
func local_session_award(final_ranking: Array) -> int:
	return session_award(final_ranking, Net.local_slot(), is_offline())


func _on_round_finished(ranking: Array, points: Dictionary) -> void:
	var slot := Net.local_slot()
	last_round_award = local_round_award(ranking, points)
	if not _is_human(slot) or not ranking.has(slot):
		return
	_bump(&"rounds_played")
	if round_place(ranking, points, slot) == 1:
		_bump(&"rounds_won")
	_grant(&"round", last_round_award)
	save()


func _on_session_finished(final_ranking: Array) -> void:
	var slot := Net.local_slot()
	last_session_award = local_session_award(final_ranking)
	if not _is_human(slot) or not final_ranking.has(slot):
		return
	var place := final_ranking.find(slot) + 1
	_bump(&"sessions_played")
	if place == 1:
		_bump(&"session_wins")
	if place <= 3:
		_bump(&"podiums")
	_grant(&"session", last_session_award)
	save()


# --- Unlocking -------------------------------------------------------------------------------

## True if the local player may wear `id` in `slot`: nothing, the starter set, bought items, or
## anything under `unlock_all`. Unknown ids are not unlocked.
func is_unlocked(slot: StringName, id: String) -> bool:
	if not Cosmetics.is_valid_item(slot, id):
		return false
	return unlock_all or Cosmetics.is_free_item(slot, id) or unlocked.has(Cosmetics.unlock_key(slot, id))


## Price of `id` in coins (0 = free starter item, -1 = unknown).
func price(slot: StringName, id: String) -> int:
	return Cosmetics.item_price(slot, id)


## Coins still missing to unlock `id` (0 when affordable or already unlocked).
func coins_needed(slot: StringName, id: String) -> int:
	if is_unlocked(slot, id):
		return 0
	return maxi(0, price(slot, id) - coins)


func can_unlock(slot: StringName, id: String) -> bool:
	return not is_unlocked(slot, id) and price(slot, id) > 0 and coins >= price(slot, id)


## Buys `id`: deducts its price and saves. False (nothing changes) when it is unknown, already
## unlocked or too expensive.
func unlock(slot: StringName, id: String) -> bool:
	if not can_unlock(slot, id):
		return false
	coins -= price(slot, id)
	unlocked.append(Cosmetics.unlock_key(slot, id))
	_bump(&"items_unlocked")
	save()
	coins_changed.emit(coins)
	unlocks_changed.emit(slot, id)
	return true


## Testing only: everything counts as unlocked for this run (nothing is saved).
func dev_unlock_all() -> void:
	unlock_all = true
	unlocks_changed.emit(&"", "")


# --- Helpers ---------------------------------------------------------------------------------

func _grant(reason: StringName, amount: int) -> void:
	if amount <= 0:
		return
	coins += amount
	stats["coins_earned"] = int(stats.get("coins_earned", 0)) + amount
	awarded.emit(reason, amount, coins)
	coins_changed.emit(coins)


func _bump(stat: StringName) -> void:
	stats[String(stat)] = int(stats.get(String(stat), 0)) + 1


func _rate(amount: int, offline: bool) -> int:
	return ceili(amount / 2.0) if offline and offline_half_rate else amount


func _is_human(slot: int) -> bool:
	return slot >= 0 and Net.roster.has(slot) and not Net.roster[slot].is_bot
