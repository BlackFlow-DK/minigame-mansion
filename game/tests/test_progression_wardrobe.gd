extends GameTest
## Progression in the UI: locked wardrobe tiles (greyed, padlock, price), click-to-unlock with
## enough coins (deducts, wears, persists) and the refusal without, the balance pills, and the
## "+N coins" on the round results and the podium.

const WARDROBE := "res://ui/wardrobe/wardrobe.tscn"
const ROUND_UI := "res://ui/round/round_ui.tscn"
const TEST_PROFILE := "user://test_progression_wardrobe_profile.json"

var w: Wardrobe
var ui: RoundUI


func before_each() -> void:
	Net.leave()
	Cosmetics.profile_path = TEST_PROFILE
	_remove_profile()
	Progression.persist = false
	Progression.offline_half_rate = true
	Progression.set_unlock_all_arg(false)
	Progression.reset()


func after_each() -> void:
	for n: Node in [w, ui]:
		if is_instance_valid(n):
			remove_child(n)
			n.queue_free()
	Net.leave()
	Progression.persist = false
	Progression.reset()
	_remove_profile()
	Cosmetics.profile_path = Cosmetics.PROFILE_PATH


func _remove_profile() -> void:
	for suffix: String in ["", ".bak", ".tmp", ".corrupt"]:  # the profile and its crash-safe save sidecars
		if FileAccess.file_exists(TEST_PROFILE + suffix):
			DirAccess.remove_absolute(TEST_PROFILE + suffix)


func _open() -> Wardrobe:
	w = (load(WARDROBE) as PackedScene).instantiate() as Wardrobe
	add_child(w)
	await step(2)
	return w


# --- Wardrobe --------------------------------------------------------------------------------

func test_locked_tiles_show_padlock_and_price() -> void:
	Progression.award(&"test_coins", 45)
	await _open()
	assert_false(w.is_tile_locked(&"hat", ""), "None is never locked")
	assert_false(w.is_tile_locked(&"hat", "party_cone"), "starter hat")
	assert_false(w.is_tile_locked(&"face", "round_glasses"), "starter face")
	for id: String in ["top_hat", "crown", "chef"]:
		assert_true(w.is_tile_locked(&"hat", id), "%s locked" % id)
		var lock := w.get_tile(&"hat", id).get_node(^"Lock")
		assert_true(lock.get_node(^"Padlock") is PadlockIcon, "%s padlock" % id)
		var amount := lock.get_node(^"PriceRow/Price/Row/Amount") as Label
		assert_eq(amount.text, str(Progression.price(&"hat", id)), "%s price shown" % id)
	assert_true(w.get_tile_texture(&"hat", "crown") == null or w._thumb_rects[WardrobeThumbs.key_of(&"hat", "crown")].material != null, "crown greyed")
	assert_eq(w.balance.shown_value, 45, "balance top-right")
	assert_true(w.balance.get_parent().get_parent() != null, "balance in the panel head")


func test_click_without_enough_coins_wobbles_and_keeps_it_locked() -> void:
	Progression.award(&"test_coins", 20)
	await _open()
	w.open_tab(&"hat")
	var before := w.loadout.duplicate()
	w.get_tile(&"hat", "top_hat").pressed.emit()
	await step(3)
	assert_eq(w.loadout, before, "not worn")
	assert_eq(Progression.coins, 20, "nothing spent")
	assert_true(w.is_tile_locked(&"hat", "top_hat"), "still locked")
	assert_false(w.get_tile(&"hat", "top_hat").button_pressed, "not selected")
	var notes := w.find_children("*", "Label", true, false).filter(func(n: Node) -> bool: return (n as Label).text == "Need 40 more")
	assert_eq(notes.size(), 1, "'Need 40 more' shown")
	assert_false(w.select_item(&"hat", "top_hat"), "select_item refuses a locked item")


func test_click_with_enough_coins_unlocks_wears_and_saves() -> void:
	Progression.persist = true
	Progression.award(&"test_coins", 75)
	await _open()
	w.open_tab(&"hat")
	var played := watch(Sfx, &"played")
	w.get_tile(&"hat", "top_hat").pressed.emit()
	await step(2)
	assert_eq(Progression.coins, 15, "60 spent")
	assert_true(Progression.is_unlocked(&"hat", "top_hat"), "unlocked")
	assert_eq(w.loadout["hat"], "top_hat", "worn right away")
	assert_eq(w.preview.loadout["hat"], "top_hat", "on the preview")
	assert_true(w.get_tile(&"hat", "top_hat").button_pressed, "selected")
	assert_false(w.is_tile_locked(&"hat", "top_hat"), "lock gone")
	assert_true(played.any(func(a: Array) -> bool: return a[0] == &"coin"), "coin sound")
	assert_true(w.find_child("UnlockConfetti", true, false) != null, "confetti burst")
	await step(40)
	assert_eq(w.balance.shown_value, 15, "balance counted down")
	assert_true(Cosmetics.load_progress()["unlocked"].has("hat:top_hat"), "saved")
	# Other locked tiles follow the new balance: 30 still affordable, 60 no longer.
	assert_eq(Progression.coins_needed(&"hat", "chef"), 15, "chef needs 15 more now")
	w.done()
	assert_eq(Cosmetics.load_profile()["loadout"]["hat"], "top_hat", "look saved too")


func test_try_unlock_api_and_random_only_uses_unlocked() -> void:
	await _open()
	assert_false(w.try_unlock(&"neck", "gold_chain"), "too poor")
	Progression.award(&"test_coins", 100)
	assert_true(w.try_unlock(&"neck", "gold_chain"), "bought")
	assert_eq(w.loadout["neck"], "gold_chain", "worn")
	for i in 30:
		w.randomise()
		for slot: StringName in Cosmetics.SLOTS:
			assert_true(Progression.is_unlocked(slot, w.loadout[String(slot)]), "random %s unlocked" % slot)
	# Reset leaves a locked default item off (slot 1's default hat is the wizard hat).
	Net.start_offline()
	Net.roster.erase(0)
	Net.roster[1] = PlayerInfo.new(1, multiplayer.get_unique_id(), "Me", false, Cosmetics.default_loadout(1))
	w.reset()
	assert_eq(w.loadout["hat"], "", "locked default hat left off")


func test_title_and_lobby_show_the_balance() -> void:
	Progression.award(&"test_coins", 123)
	var menu := (load("res://ui/menu/menu_root.tscn") as PackedScene).instantiate() as MenuRoot
	add_child(menu)
	await step(1)
	assert_true(menu.title.coin_balance.is_visible_in_tree(), "title shows coins")
	assert_eq(menu.title.coin_balance.shown_value, 123, "title balance")
	assert_eq(menu.lobby.coin_balance.shown_value, 123, "lobby balance")
	Progression.award(&"more", 7)
	await step(60)
	assert_eq(menu.title.coin_balance.shown_value, 130, "follows the balance")
	remove_child(menu)
	menu.queue_free()


# --- Round UI --------------------------------------------------------------------------------

func _round_ui() -> RoundUI:
	ui = (load(ROUND_UI) as PackedScene).instantiate() as RoundUI
	add_child(ui)
	await step(1)
	return ui


func test_results_show_coins_for_the_local_player() -> void:
	Net.start_offline()
	Progression.offline_half_rate = false
	for i in 3:
		Net.add_bot()
	await _round_ui()
	var ranking: Array[int] = [0, 1, 2, 3]
	var points := Session.points_for_ranking(ranking)
	for s: int in points:
		Session.scores[s] = points[s]
	Session.round_finished.emit(ranking, points)
	assert_eq(ui.results.coins_shown, 6, "+6 coins for the win")
	assert_eq(Progression.coins, 6, "and paid")
	await step(150)
	assert_true(ui.results.is_coins_shown(), "the coins pill popped in")
	# Half rate offline shows the halved amount.
	Progression.offline_half_rate = true
	ranking = [1, 0, 2, 3]
	Session.round_finished.emit(ranking, Session.points_for_ranking(ranking))
	assert_eq(ui.results.coins_shown, 2, "offline 2nd: +2")
	Session.scores.clear()


func test_podium_shows_session_bonus_and_counts_up() -> void:
	Net.start_offline()
	Progression.offline_half_rate = false
	for i in 3:
		Net.add_bot()
	Progression.award(&"before", 50)
	await _round_ui()
	var final: Array[int] = [2, 0, 1, 3]
	for s in final:
		Session.scores[s] = 10 - s
	Session.session_finished.emit(final)
	assert_eq(ui.podium.coins_bonus, 25, "2nd place bonus")
	assert_eq(Progression.coins, 75, "paid")
	await step(int((RoundPodium.CELEBRATE_AT + 1.4) * 60.0))
	assert_true(ui.podium.is_coins_card_shown(), "coins card shown")
	await step(int((RoundPodium.COINS_COUNT_SECONDS + 0.5) * 60.0))
	assert_eq(ui.podium.coins_total_shown, 75, "counted up to the new total")
	Session.scores.clear()
