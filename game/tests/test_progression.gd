extends GameTest
## Progression (Mansion Coins): round and session awards by placement, half rate offline and
## with fewer than 2 humans, bots never earn, one-time awards, unlocking (deducts, persists, refuses when poor), the profile
## upgrade from a pre-coins profile, --unlock-all, and sanitize keeping locked items.

const TEST_PROFILE := "user://test_progression_profile.json"
## Base port for the hosted (full rate) tests; a few are tried in case one is busy.
const TEST_PORT := 24611


func before_each() -> void:
	Net.leave()
	Cosmetics.profile_path = TEST_PROFILE
	_remove_profile()
	Progression.persist = false
	Progression.offline_half_rate = true
	Progression.set_unlock_all_arg(false)
	Progression.reset()


func after_each() -> void:
	Net.leave()
	Net.port = Net.DEFAULT_PORT
	Progression.persist = false
	Progression.offline_half_rate = true
	Progression.set_unlock_all_arg(false)
	Progression.reset()
	_remove_profile()
	Cosmetics.profile_path = Cosmetics.PROFILE_PATH


func _remove_profile() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".corrupt"]:  # the profile and its crash-safe save sidecars
		if FileAccess.file_exists(TEST_PROFILE + suffix):
			DirAccess.remove_absolute(TEST_PROFILE + suffix)


## Hosts a LAN game with a second human (a full-rate session): this peer is slot 0, the friend
## slot 7 (added straight into the roster; no second process). False if no port was free.
func _host(with_friend: bool = true) -> bool:
	for i in 4:
		Net.port = TEST_PORT + i
		if Net.host_game("Coins test") == OK:
			if with_friend:
				_friend()
			return true
	fail("could not host on ports %d-%d" % [TEST_PORT, TEST_PORT + 3])
	return false


## A second human in the roster (slot 7, another peer).
func _friend() -> void:
	Net.roster[7] = PlayerInfo.new(7, 99, "Friend", false, Cosmetics.default_loadout(7))


## Adds `count` bots (slots 1..count).
func _bots(count: int) -> void:
	for i in count:
		Net.add_bot()


## Points as Session gives them (4/3/2/1, the rest 0; `tied` share first).
func _points(ranking: Array[int], tied: int = 1) -> Dictionary:
	return Session.points_for_ranking(ranking, tied)


# --- Earning ---------------------------------------------------------------------------------

func test_round_awards_by_placement() -> void:
	if not _host():
		return
	_bots(5)
	var expected := [6, 4, 3, 2, 2, 2]
	for place in 6:
		var ranking: Array[int] = [1, 2, 3, 4, 5]
		ranking.insert(place, 0)
		assert_eq(Progression.local_round_award(ranking, _points(ranking)), expected[place], "place %d" % (place + 1))
	# Survivors sharing first place all get the winner's coins.
	var tied: Array[int] = [3, 0, 1, 2, 4, 5]
	assert_eq(Progression.local_round_award(tied, _points(tied, 2)), 6, "shared first place")
	# Not in the ranking (spectating): nothing.
	var without: Array[int] = [1, 2, 3]
	assert_eq(Progression.local_round_award(without, _points(without)), 0, "not in the ranking")


func test_round_finished_pays_the_local_player() -> void:
	if not _host():
		return
	_bots(3)
	var changes := watch(Progression, &"coins_changed")
	var ranking: Array[int] = [2, 0, 1, 3]
	Session.round_finished.emit(ranking, _points(ranking))
	assert_eq(Progression.coins, 4, "2nd place: 4 coins")
	assert_eq(Progression.last_round_award, 4, "last_round_award")
	assert_eq(changes.size(), 1, "coins_changed once")
	ranking = [0, 1, 2, 3]
	Session.round_finished.emit(ranking, _points(ranking))
	assert_eq(Progression.coins, 10, "then 1st place: +6")
	assert_eq(int(Progression.stats.get("rounds_played", 0)), 2, "rounds played")
	assert_eq(int(Progression.stats.get("rounds_won", 0)), 1, "rounds won")
	assert_eq(int(Progression.stats.get("coins_earned", 0)), 10, "coins earned")


func test_session_bonus_by_final_placement() -> void:
	if not _host():
		return
	_bots(4)
	var expected := [40, 25, 15, 10, 10]
	for place in 5:
		var final: Array[int] = [1, 2, 3, 4]
		final.insert(place, 0)
		assert_eq(Progression.local_session_award(final), expected[place], "final place %d" % (place + 1))
	var final_first: Array[int] = [0, 1, 2, 3, 4]
	Session.session_finished.emit(final_first)
	assert_eq(Progression.coins, 40, "session winner bonus")
	assert_eq(Progression.last_session_award, 40, "last_session_award")
	assert_eq(int(Progression.stats.get("sessions_played", 0)), 1, "sessions played")
	assert_eq(int(Progression.stats.get("session_wins", 0)), 1, "session wins")
	assert_eq(int(Progression.stats.get("podiums", 0)), 1, "podiums")
	var final_fourth: Array[int] = [1, 2, 3, 0, 4]
	Session.session_finished.emit(final_fourth)
	assert_eq(Progression.coins, 50, "then 4th: +10")
	assert_eq(int(Progression.stats.get("podiums", 0)), 1, "4th is no podium")


func test_offline_sessions_earn_half_rounded_up() -> void:
	Net.start_offline()
	_bots(5)
	assert_true(Progression.is_offline(), "start_offline is offline")
	var expected := [3, 2, 2, 1, 1]
	for place in 5:
		var ranking: Array[int] = [1, 2, 3, 4]
		ranking.insert(place, 0)
		assert_eq(Progression.local_round_award(ranking, _points(ranking)), expected[place], "offline place %d" % (place + 1))
	var session_expected := [20, 13, 8, 5]
	for place in 4:
		var final: Array[int] = [1, 2, 3]
		final.insert(place, 0)
		assert_eq(Progression.local_session_award(final), session_expected[place], "offline final place %d" % (place + 1))
	var ranking: Array[int] = [0, 1, 2]
	Session.round_finished.emit(ranking, _points(ranking))
	assert_eq(Progression.coins, 3, "offline round win pays 3")
	Session.session_finished.emit(ranking)
	assert_eq(Progression.coins, 23, "offline session win pays 20")
	# Hosting a LAN game with a friend is full rate.
	Net.leave()
	if not _host():
		return
	assert_false(Progression.is_offline(), "hosting is not offline")
	assert_false(Progression.is_half_rate(), "two humans: full rate")


func test_fewer_than_two_humans_earn_half() -> void:
	if not _host(false):
		return
	_bots(3)
	assert_false(Progression.is_offline(), "hosted")
	assert_eq(Progression.human_count(), 1, "one human")
	assert_true(Progression.is_half_rate(), "a host alone with bots: half rate")
	var ranking: Array[int] = [0, 1, 2, 3]
	assert_eq(Progression.local_round_award(ranking, _points(ranking)), 3, "round win: 6 -> 3")
	assert_eq(Progression.local_session_award(ranking), 20, "session win: 40 -> 20")
	Session.round_finished.emit(ranking, _points(ranking))
	Session.session_finished.emit(ranking)
	assert_eq(Progression.coins, 23, "paid at half rate")
	# A friend joins: full rate again.
	_friend()
	assert_eq(Progression.human_count(), 2, "two humans")
	assert_false(Progression.is_half_rate(), "full rate")
	assert_eq(Progression.local_round_award(ranking, _points(ranking)), 6, "round win: 6")
	assert_eq(Progression.local_session_award(ranking), 40, "session win: 40")
	# The friend leaves again before the end: half.
	Net.roster.erase(7)
	assert_true(Progression.is_half_rate(), "alone again: half rate")
	# Offline can never be full rate.
	Net.leave()
	Net.start_offline()
	_friend()
	assert_true(Progression.is_half_rate(), "offline is always half rate")


func test_half_rate_is_decided_at_round_zero() -> void:
	if not _host():
		return
	var info := {"id": &"test", "title": "T", "rule_text": ""}
	var ranking: Array[int] = [0, 7]
	Session.round_intro.emit(info, 0)
	assert_false(Progression.is_half_rate(), "two humans at round 0: full rate")
	Net.roster.erase(7)  # the friend leaves before the podium
	assert_eq(Progression.human_count(), 1, "one human left")
	assert_false(Progression.is_half_rate(), "still full rate: decided at round 0")
	Session.round_intro.emit(info, 1)
	assert_false(Progression.is_half_rate(), "a later round does not re-decide")
	Session.session_finished.emit([0, 1] as Array[int])
	assert_eq(Progression.coins, 40, "full session bonus")
	Session.state_changed.emit(Session.State.LOBBY)
	assert_true(Progression.is_half_rate(), "back in the lobby: live again (alone)")
	# Alone at round 0, a friend joining mid-session does not double the rate.
	Session.round_intro.emit(info, 0)
	_friend()
	assert_true(Progression.is_half_rate(), "half rate fixed at round 0")
	assert_eq(Progression.local_round_award(ranking, _points(ranking)), 3, "round win at half rate")
	Session.state_changed.emit(Session.State.LOBBY)


func test_bots_never_earn() -> void:
	Net.start_offline()
	_bots(3)
	var ranking: Array[int] = [1, 2, 3, 0]
	for bot in [1, 2, 3]:
		assert_eq(Progression.round_award(ranking, _points(ranking), bot, false), 0, "bot %d round" % bot)
		assert_eq(Progression.session_award(ranking, bot, false), 0, "bot %d session" % bot)
	assert_eq(Progression.round_award(ranking, _points(ranking), 6, false), 0, "empty slot")
	# Bots win everything: the local human still gets only its own last place.
	Session.round_finished.emit(ranking, _points(ranking))
	assert_eq(Progression.coins, 1, "local last place offline: 1")
	# No local human at all (left the game): nothing.
	Net.leave()
	Session.round_finished.emit(ranking, _points(ranking))
	Session.session_finished.emit(ranking)
	assert_eq(Progression.coins, 1, "nobody local, nothing paid")


func test_one_time_awards_are_idempotent() -> void:
	Progression.persist = true
	var given := watch(Progression, &"awarded")
	assert_eq(Progression.award(&"tutorial", 20), 20, "first time pays")
	assert_eq(Progression.award(&"tutorial", 20), 0, "second time pays nothing")
	assert_eq(Progression.coins, 20, "paid once")
	assert_true(Progression.has_claimed(&"tutorial"), "claimed")
	assert_eq(given.size(), 1, "awarded once")
	assert_eq(given[0], [&"tutorial", 20, 20], "awarded args")
	# Survives a restart (saved with the profile).
	Progression.reset()
	Progression.reload()
	assert_eq(Progression.coins, 20, "coins saved")
	assert_eq(Progression.award(&"tutorial", 20), 0, "still claimed after reload")
	# Repeatable rewards and nonsense.
	assert_eq(Progression.award(&"daily", 5, false), 5, "repeatable")
	assert_eq(Progression.award(&"daily", 5, false), 5, "repeatable again")
	assert_eq(Progression.award(&"nothing", 0), 0, "zero")
	assert_eq(Progression.award(&"negative", -10), 0, "negative")
	assert_false(Progression.has_claimed(&"nothing"), "a zero award claims nothing")
	assert_eq(Progression.coins, 30, "total")


func test_saving_is_off_unless_asked() -> void:
	assert_false(Progression.persist, "test runs start with saving off")
	Progression.award(&"tutorial", 20)
	assert_false(FileAccess.file_exists(TEST_PROFILE), "nothing written")
	assert_true(Progression.parse_args(PackedStringArray(["--offline"]))["dev"], "dev args turn saving off")
	assert_true(Progression.parse_args(PackedStringArray(["--screenshot=x.png"]))["dev"], "screenshots too")
	assert_false(Progression.parse_args(PackedStringArray(["--port=1234"]))["dev"], "a port is a real run")
	assert_eq(Progression.parse_args(PackedStringArray(["--coins=250"]))["coins"], 250, "--coins")


# --- Unlocking -------------------------------------------------------------------------------

func test_starter_set_is_free_and_the_rest_locked() -> void:
	var free := {&"hat": ["party_cone", "cat_ears"], &"face": ["round_glasses"], &"neck": ["scarf"], &"back": ["backpack"]}
	for slot: StringName in Cosmetics.SLOTS:
		assert_true(Progression.is_unlocked(slot, ""), "%s: nothing is always allowed" % slot)
		for entry: Dictionary in Cosmetics.catalog(slot).slice(1):
			var id: String = entry["id"]
			var is_free: bool = (free[slot] as Array).has(id)
			assert_eq(Progression.is_unlocked(slot, id), is_free, "%s:%s unlocked" % [slot, id])
			assert_true(["common", "rare", "epic"].has(entry["tier"]), "%s:%s has a tier" % [slot, id])
			var expected_price: int = 0 if is_free else {"common": 30, "rare": 60, "epic": 100}[entry["tier"]]
			assert_eq(Progression.price(slot, id), expected_price, "%s:%s price" % [slot, id])
	assert_eq(Progression.price(&"hat", "crown"), 100, "crown is epic")
	assert_false(Progression.is_unlocked(&"hat", "no_such_hat"), "unknown item")
	assert_eq(Progression.price(&"hat", "no_such_hat"), -1, "unknown price")


func test_unlock_deducts_and_persists() -> void:
	Progression.persist = true
	Progression.award(&"test_coins", 130)
	var unlocks := watch(Progression, &"unlocks_changed")
	assert_true(Progression.can_unlock(&"hat", "crown"), "affordable")
	assert_true(Progression.unlock(&"hat", "crown"), "unlocked")
	assert_eq(Progression.coins, 30, "100 deducted")
	assert_true(Progression.is_unlocked(&"hat", "crown"), "now unlocked")
	assert_eq(unlocks.size(), 1, "unlocks_changed")
	assert_false(Progression.unlock(&"hat", "crown"), "cannot buy twice")
	assert_eq(Progression.coins, 30, "nothing deducted the second time")
	assert_true(Progression.unlock(&"face", "moustache"), "a common item for 30")
	assert_eq(Progression.coins, 0, "spent out")
	assert_eq(int(Progression.stats.get("items_unlocked", 0)), 2, "stat")
	# Saved: a fresh load sees it.
	Progression.reset()
	assert_false(Progression.is_unlocked(&"hat", "crown"), "reset forgets in memory")
	Progression.reload()
	assert_true(Progression.is_unlocked(&"hat", "crown"), "crown saved")
	assert_true(Progression.is_unlocked(&"face", "moustache"), "moustache saved")
	assert_eq(Progression.coins, 0, "balance saved")
	var p := Cosmetics.load_progress()
	assert_eq(p["unlocked"], ["hat:crown", "face:moustache"] as Array[String], "profile unlocked list")
	# Saving the look keeps the progress (and the other way round).
	Cosmetics.save_profile("Mia", Cosmetics.default_loadout(2))
	assert_eq(Cosmetics.load_progress()["unlocked"], p["unlocked"], "save_profile keeps unlocks")
	Progression.award(&"more", 5)
	assert_eq(Cosmetics.load_profile()["name"], "Mia", "save_progress keeps the name")


func test_cannot_unlock_when_poor() -> void:
	Progression.award(&"test_coins", 20)
	assert_false(Progression.can_unlock(&"hat", "top_hat"), "60 > 20")
	assert_false(Progression.unlock(&"hat", "top_hat"), "refused")
	assert_eq(Progression.coins, 20, "nothing deducted")
	assert_false(Progression.is_unlocked(&"hat", "top_hat"), "still locked")
	assert_eq(Progression.coins_needed(&"hat", "top_hat"), 40, "40 more needed")
	assert_eq(Progression.coins_needed(&"hat", "party_cone"), 0, "free item needs nothing")
	assert_false(Progression.unlock(&"hat", "party_cone"), "free items are not bought")
	assert_false(Progression.unlock(&"hat", "no_such_hat"), "unknown items are not bought")
	assert_eq(Progression.coins, 20, "balance untouched")


func test_profile_upgrade_from_a_pre_coins_profile() -> void:
	var old := {"version": 1, "name": "Oldie", "loadout": {"primary": "#2f7fe0", "secondary": "#ffffff",
		"hat": "crown", "face": "", "neck": "scarf", "back": "jetpack", "size": "big"}}
	var f := FileAccess.open(TEST_PROFILE, FileAccess.WRITE)
	f.store_string(JSON.stringify(old))
	f.close()
	var profile := Cosmetics.load_profile()
	assert_eq(profile["name"], "Oldie", "old name loads")
	assert_eq(profile["loadout"]["hat"], "crown", "old loadout loads")
	var p := Cosmetics.load_progress()
	assert_eq(p["coins"], 0, "starts at 0 coins")
	assert_eq(p["unlocked"], ["hat:crown", "back:jetpack"] as Array[String], "items worn before coins stay unlocked")
	assert_eq(p["stats"], {}, "no stats")
	Progression.reload()
	assert_true(Progression.is_unlocked(&"hat", "crown"), "crown kept")
	assert_true(Progression.is_unlocked(&"back", "jetpack"), "jetpack kept")
	assert_false(Progression.is_unlocked(&"hat", "viking"), "others locked")
	# The next save writes the new format, keeping all of it.
	Cosmetics.save_profile("Oldie", profile["loadout"])
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TEST_PROFILE))
	assert_eq(int(data["version"]), Cosmetics.PROFILE_VERSION, "version bumped")
	assert_eq(int(data["coins"]), 0, "coins written")
	assert_eq(data["unlocked"], ["hat:crown", "back:jetpack"], "unlocks written")
	# A broken progress block is cleaned, not fatal.
	var bad := {"name": "X", "loadout": {}, "coins": -5, "unlocked": ["hat:nope", 7, "hat:party_cone", "face:monocle", "face:monocle"], "stats": {"a": 2, "b": "x"}, "claimed": [3, "tutorial"]}
	var f2 := FileAccess.open(TEST_PROFILE, FileAccess.WRITE)
	f2.store_string(JSON.stringify(bad))
	f2.close()
	var clean := Cosmetics.load_progress()
	assert_eq(clean["coins"], 0, "negative coins -> 0")
	assert_eq(clean["unlocked"], ["face:monocle"] as Array[String], "unknown, free and duplicate unlocks dropped")
	assert_eq(clean["stats"], {"a": 2}, "bad stats dropped")
	assert_eq(clean["claimed"], ["tutorial"] as Array[String], "bad claims dropped")


func test_unlock_all_dev_switch() -> void:
	Progression.persist = true
	assert_true(Progression.parse_args(PackedStringArray(["--unlock-all"]))["unlock_all"], "--unlock-all parsed")
	assert_false(Progression.parse_args(PackedStringArray(["--name=x"]))["unlock_all"], "off by default")
	Progression.dev_unlock_all()
	for slot: StringName in Cosmetics.SLOTS:
		for entry: Dictionary in Cosmetics.catalog(slot):
			assert_true(Progression.is_unlocked(slot, entry["id"]), "%s:%s unlocked" % [slot, entry["id"]])
	assert_true(Progression.unlocked.is_empty(), "nothing bought")
	assert_false(Progression.can_unlock(&"hat", "crown"), "nothing to buy")
	Progression.award(&"save_now", 1)
	assert_eq(Cosmetics.load_progress()["unlocked"], [] as Array[String], "never written to the profile")
	Progression.reload()
	assert_false(Progression.is_unlocked(&"hat", "crown"), "gone after a reload")
	# The user arg keeps it on across reloads.
	Progression.set_unlock_all_arg(true)
	Progression.reload()
	assert_true(Progression.is_unlocked(&"hat", "crown"), "--unlock-all survives reload")


func test_sanitize_keeps_locked_items() -> void:
	var look := {"primary": "#2f7fe0", "secondary": "#ffffff", "hat": "crown", "face": "star_shades",
		"neck": "gold_chain", "back": "angel_wings", "size": "small"}
	assert_false(Progression.is_unlocked(&"hat", "crown"), "crown is locked here")
	assert_eq(Cosmetics.sanitize(look), look, "a friend's unlocked items pass")
	Cosmetics.save_profile("Friend", look)
	assert_eq(Cosmetics.load_profile()["loadout"], look, "and load from a profile")
