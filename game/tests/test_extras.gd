extends GameTest
## NPC extras (Stage.spawn_extras): spawn/despawn, manifests ("peers" simulated with a second
## Stage), the compact sync stream, exclusion from rankings / HUD / camera / name tags, shoves
## and eliminations, the wander/dance brains, `is_ally`, and cost. The real network path is
## covered by game/net/sync/dev/run_extras_smoke.ps1.

const CAMERA_SCENE: PackedScene = preload("res://camera/arena_camera.tscn")
const NAME_TAG_SCENE: PackedScene = preload("res://ui/round/name_tag.tscn")
const UI_SCENE: PackedScene = preload("res://ui/round/round_ui.tscn")
const DEV_ARENA: PackedScene = preload("res://dev/dev_arena.tscn")

var _extra_stages: Array[Node] = []
var _session_used: bool = false


func after_each() -> void:
	if _session_used:
		Session.abort_session()
	for n in _extra_stages:
		if is_instance_valid(n):
			if n is Stage:
				(n as Stage).clear()
			n.get_parent().remove_child(n)
			n.queue_free()
	_extra_stages.clear()
	if _session_used:
		Session.scene_override = null
		Session.time_scale = 1.0
		Session.order_seed = -1


func _names(ps: Array[Player]) -> Array[String]:
	var out: Array[String] = []
	for p in ps:
		out.append(String(p.name))
	return out


# --- Spawn / despawn ---------------------------------------------------------------------------

func test_spawn_and_despawn() -> void:
	var ps := spawn_arena(4)
	var got := watch(stage, &"extras_spawned")
	var xs := stage.spawn_extras(5)
	assert_eq(xs.size(), 5, "five extras")
	assert_eq(stage.extras.size(), 5, "Stage.extras")
	assert_eq(got.size(), 1, "extras_spawned once")
	assert_eq(_names(xs), ["X100", "X101", "X102", "X103", "X104"] as Array[String], "node names")
	for x in xs:
		assert_true(x.is_extra and x.is_bot, "flagged extra and bot")
		assert_eq(String(x.get_parent().name), "Extras", "under Stage/Extras")
		assert_eq(x.get_multiplayer_authority(), 1, "host-owned")
		assert_false(x.frozen, "extras spawn unfrozen")
		assert_eq(stage.get_body(x.slot), x, "get_body finds it")
		assert_eq(stage.get_extra(x.slot), x, "get_extra finds it")
		assert_true(stage.get_player(x.slot) == null, "get_player does not")
		var brain := BotBrain.of(x)
		assert_true(brain != null and brain.extra_mode == &"wander", "wander brain")
	assert_eq(stage.players.size(), 4, "Stage.players unchanged")
	assert_eq(get_minigame().players.size(), 4, "Minigame.players unchanged")
	assert_eq(Net.roster.size(), 4, "roster unchanged")
	assert_true(Stage.is_extra_slot(100) and not Stage.is_extra_slot(7), "is_extra_slot")
	var more := stage.spawn_extras(2)
	assert_eq(_names(more), ["X105", "X106"] as Array[String], "slots continue")
	stage.despawn_extras()
	assert_true(stage.extras.is_empty(), "despawned")
	await step(1)
	assert_true(stage.get_node(^"Extras").get_child_count() == 0, "nodes freed")
	for p in ps:
		assert_true(is_instance_valid(p), "players untouched")
	stage.spawn_extras(3)
	stage.clear()
	assert_true(stage.extras.is_empty(), "clear() removes extras")


func test_loadouts_and_spawn_xforms_are_used() -> void:
	spawn_arena(2)
	var look: Array[Dictionary] = [{"primary": "#123456", "secondary": "#ffffff", "size": "big"}]
	var at: Array[Transform3D] = [Transform3D(Basis.IDENTITY, Vector3(3, 0, -2))]
	var xs := stage.spawn_extras(2, look, at)
	assert_eq(xs[0].loadout.get("primary"), "#123456", "given loadout")
	assert_near(xs[0].global_position, Vector3(3, 0, -2), 0.001, "given transform")
	assert_true(xs[1].loadout.has("primary"), "default loadout")
	assert_true(xs[1].global_position.length() > 2.0, "default spot off the centre")


# --- "Peers": manifests ------------------------------------------------------------------------

func test_manifest_gives_a_peer_the_same_extras() -> void:
	spawn_arena(3)
	stage.spawn_extras(6)
	var client := STAGE_SCENE.instantiate() as Stage
	client.name = "ClientStage"
	add_child(client)
	_extra_stages.append(client)
	var spawned := watch(client, &"extras_spawned")
	client.apply_manifest(stage.net_load_id, DEV_ARENA_PATH, false, stage._manifest_entries(), stage._extra_entries())
	assert_eq(_names(client.extras), _names(stage.extras), "same extra node names on the peer")
	assert_eq(client.players.size(), stage.players.size(), "same players")
	assert_eq(spawned.size(), 1, "extras_spawned on the peer")
	for i in client.extras.size():
		var a := stage.extras[i]
		var b := client.extras[i]
		assert_eq(b.loadout, a.loadout, "same loadout")
		assert_true(b.is_extra and b.get_multiplayer_authority() == 1, "peer copy: extra, host authority")
		assert_near(b.global_position, a.global_position, 0.001, "same spawn spot")
	# Host despawns two: the next manifest removes exactly those.
	var keep := stage._extra_entries().slice(0, 4)
	client.apply_manifest(stage.net_load_id, DEV_ARENA_PATH, false, stage._manifest_entries(), keep)
	assert_eq(_names(client.extras), ["X100", "X101", "X102", "X103"] as Array[String], "reconciled")
	# Old-style manifest without extras leaves them alone; an empty list removes all.
	client.apply_manifest(stage.net_load_id, DEV_ARENA_PATH, false, stage._manifest_entries())
	assert_eq(client.extras.size(), 4, "null extras: untouched")
	client.apply_manifest(stage.net_load_id, DEV_ARENA_PATH, false, stage._manifest_entries(), [{"slot": 7}, "junk", {"slot": 500}])
	assert_eq(client.extras.size(), 0, "bad entries ignored, the rest removed")
	# A new load clears extras with everything else.
	client.apply_manifest(stage.net_load_id, DEV_ARENA_PATH, false, stage._manifest_entries(), stage._extra_entries())
	client.apply_manifest(stage.net_load_id + 1, DEV_ARENA_PATH, false, stage._manifest_entries(), [])
	assert_eq(client.extras.size(), 0, "new load: no extras")


# --- Sync stream -------------------------------------------------------------------------------

func test_compact_extras_stream_round_trips_and_applies() -> void:
	spawn_arena(2)
	var xs := stage.spawn_extras(20)
	xs[3].velocity = Vector3(1.25, -2.5, 3.0)
	xs[3].facing = Vector3(1, 0, 1).normalized()
	var packed := SyncHub.pack_extras(stage.extras)
	assert_eq(packed.size(), 20 * SyncHub.EXTRA_BYTES, "26 bytes per extra")
	assert_true(packed.size() < 1200, "20 extras fit one unfragmented packet")
	var rows := SyncHub.unpack_extras(packed)
	assert_eq(rows.size(), 20, "unpacked")
	var orig := (xs[3].get_component(&"sync") as SyncComponent).pack_state()
	var row: Array = rows[3]
	assert_eq(row[0], 103, "slot")
	assert_near(row[3], orig[3], 0.0001, "position exact (f32)")
	assert_near(row[4], orig[4], 0.01, "velocity (f16)")
	assert_near(row[5], orig[5], 0.001, "facing (u16 yaw)")
	assert_eq(row[6], orig[6], "flags")
	assert_eq(SyncHub.unpack_extras(PackedByteArray([1, 2, 3])).size(), 0, "malformed packet ignored")
	# A peer's remote copy (authority elsewhere) takes the decoded state.
	var hub := stage.sync_hub
	for x in xs:
		x.set_multiplayer_authority(2)
	var target := Vector3(4, 0, 4)
	var bytes := PackedByteArray()
	bytes.resize(SyncHub.EXTRA_BYTES)
	bytes.encode_u8(0, 5)
	bytes.encode_u8(1, SyncHub.FLAG_ALIVE | SyncHub.FLAG_ON_FLOOR)
	bytes.encode_float(6, target.x)
	bytes.encode_float(14, target.z)
	assert_eq(hub.receive_extras(2, stage.net_load_id, 1, hub.clock, bytes), 0, "only the host may send extras")
	assert_eq(hub.receive_states(2, stage.net_load_id, 1, hub.clock, SyncHub.unpack_extras(bytes)), 1, "decoded state applied")
	assert_near(xs[5].global_position, target, 0.001, "remote extra moved")
	# Bandwidth estimate (per client, 30 Hz): a player's Variant entry vs an extra's 26 bytes.
	var per_player := var_to_bytes(orig).size()
	var rate := hub.send_rate
	print("extras bandwidth: player entry %d B, extra %d B -> 20 extras %.0f B/s per client (%.0f B/s as Variant arrays)" % [
		per_player, SyncHub.EXTRA_BYTES, 20 * SyncHub.EXTRA_BYTES * rate, 20 * per_player * rate])


# --- Not players -------------------------------------------------------------------------------

func test_extras_never_reach_session_rankings() -> void:
	_session_used = true
	Session.abort_session()
	Session.scene_override = DEV_ARENA
	Session.time_scale = 50.0
	Session.order_seed = 1234
	Net.start_offline()
	for i in 3:
		Net.add_bot()
	var arena := STAGE_SCENE.instantiate() as Stage
	add_child(arena)
	_extra_stages.append(arena)
	var finished: Array = []
	var cb := func(r: Array[int], pts: Dictionary) -> void: finished.append([r, pts])
	Session.round_finished.connect(cb)
	Session.start_session(1)
	var ok := false
	for i in 900:
		if Session.state == 2:  # PLAYING
			ok = true
			break
		await step(1)
	assert_true(ok, "round playing")
	var xs := arena.spawn_extras(3)
	assert_eq(Session.current_minigame.players.size(), 4, "minigame players: no extras")
	Session.current_minigame.knock_out(xs[0])  # a minigame that forgets the guard
	assert_false(Session.current_minigame.is_finished(), "knocking out an extra does not end the round")
	var r: Array[int] = [100, 2, 0, 101, 1, 3]
	Session.current_minigame.finish(r)
	for i in 300:
		if not finished.is_empty():
			break
		await step(1)
	Session.round_finished.disconnect(cb)
	assert_eq(finished.size(), 1, "round finished")
	var ranking: Array = finished[0][0]
	var pts: Dictionary = finished[0][1]
	assert_eq(ranking, [2, 0, 1, 3], "ranking without extras")
	for s: int in pts:
		assert_true(s < Net.MAX_PLAYERS, "no points for slot %d" % s)
	for s: int in Session.scores:
		assert_true(s < Net.MAX_PLAYERS, "no score for slot %d" % s)


func test_extras_absent_from_hud_camera_and_tags() -> void:
	var ps := spawn_arena(4)
	var ui := UI_SCENE.instantiate() as RoundUI
	add_child(ui)
	_extra_stages.append(ui)
	var xs := stage.spawn_extras(6)
	await step(2)
	assert_true(ui.hud.get_card(100) == null, "no HUD card for an extra")
	xs[0].eliminate(&"test")
	await step(1)
	assert_true(ui.hud.get_card(100) == null, "eliminating an extra adds no card")
	# Camera: players only unless include_extras.
	var cam := CAMERA_SCENE.instantiate() as ArenaCamera
	add_child(cam)
	_extra_stages.append(cam)
	cam.set_process(false)
	assert_eq(cam.get_living_players().size(), ps.size(), "living players: players only")
	assert_eq(cam.get_framed_points().size(), ps.size(), "framed: players only")
	cam.include_extras = true
	assert_eq(cam.get_framed_points().size(), ps.size() + 5, "include_extras: + living extras")
	xs[1].place_at(Transform3D(Basis.IDENTITY, Vector3(30, 0, 30)))
	cam.include_extras = false
	cam.snap()
	var far := cam.focus
	cam.include_extras = true
	cam.snap()
	assert_true(cam.focus.distance_to(far) > 1.0, "an extra far away moves the framing only with include_extras")
	# Name tags: hidden for extras unless opted in.
	var tag := NAME_TAG_SCENE.instantiate() as NameTag
	xs[2].add_child(tag)
	tag.setup(xs[2])
	tag._process(0.016)
	assert_false(tag.visible, "no tag on an extra by default")
	tag.show_extras = true
	tag._process(0.016)
	assert_true(tag.visible, "opt-in shows it")
	var ptag := NAME_TAG_SCENE.instantiate() as NameTag
	ps[1].add_child(ptag)
	ptag.setup(ps[1])
	ptag._process(0.016)
	assert_true(ptag.visible, "players keep their tags")


# --- Shoves and eliminations ----------------------------------------------------------------------

func test_extras_are_shoved_stunned_and_eliminated() -> void:
	var ps := spawn_arena(2)
	var at: Array[Transform3D] = [Transform3D(Basis.IDENTITY, ps[0].global_position + ps[0].facing * 1.0)]
	var x := stage.spawn_extras(1, [], at)[0]
	BotBrain.of(x).configure_extra(&"idle", 1)
	var hits := watch(x, &"got_hit")
	var shoves := watch(ps[0], &"shove_hit")
	var start := x.global_position
	await step(31, func(i: int) -> void: ps[0].intent.action_pressed = i == 0)
	assert_eq(shoves.size(), 1, "the shove connects")
	assert_eq(shoves[0][0], x.slot, "victim is the extra")
	assert_eq(hits.size(), 1, "extra got_hit")
	assert_eq(hits[0][1], ps[0].slot, "source slot")
	assert_true(x.global_position.distance_to(start) > 0.5, "knocked back (%.2f m)" % x.global_position.distance_to(start))
	x.eliminate(&"test")
	assert_false(x.alive, "eliminated by the host")
	assert_false(x.visible, "hidden")
	assert_false(get_minigame().is_finished(), "the round goes on")
	assert_eq(get_minigame().knocked_out.size(), 0, "not a knock-out")


# --- Brains ------------------------------------------------------------------------------------

func test_wander_brain_is_deterministic_and_calm() -> void:
	var a := BotBrain.new()
	var b := BotBrain.new()
	a.configure_extra(&"wander", 42)
	b.configure_extra(&"wander", 42)
	a._home = Vector3.ZERO
	b._home = Vector3.ZERO
	for i in 10:
		assert_near(a._pick_wander_target(null), b._pick_wander_target(null), 0.0001, "same seed, same targets")
	var c := BotBrain.new()
	c.configure_extra(&"wander", 43)
	c._home = Vector3.ZERO
	assert_true(c._pick_wander_target(null).distance_to(a._pick_wander_target(null)) > 0.001, "another seed differs")
	for n: BotBrain in [a, b, c]:
		n.free()
	# In the arena: same seeds and spots -> the same walk; they move, stay home, never shove.
	spawn_arena(1)
	var runs: Array = []
	for run in 2:
		var xs := stage.spawn_extras(6, [], _ring(6, 4.0))
		var shoves: Array = []
		for i in xs.size():
			BotBrain.of(xs[i]).configure_extra(&"wander", 1000 + i)
			shoves.append(watch(xs[i], &"shove_started"))
		var start: Array[Vector3] = []
		for x in xs:
			start.append(x.global_position)
		await step(240)
		var at: Array[Vector3] = []
		var moved := 0
		for i in xs.size():
			at.append(xs[i].global_position)
			if xs[i].global_position.distance_to(start[i]) > 0.5:
				moved += 1
			assert_true(Vector2(at[i].x, at[i].z).length() < 4.0 + 4.0 + 1.5, "stays near home")
			assert_eq((shoves[i] as Array).size(), 0, "never shoves")
		assert_true(moved >= 4, "they wander (%d of 6 moved)" % moved)
		runs.append(at)
		stage.despawn_extras()
		await step(2)
	for i in 6:
		assert_near(runs[1][i], runs[0][i], 0.05, "deterministic by seed (extra %d)" % i)


func test_dance_brain_circles_its_centre() -> void:
	spawn_arena(1)
	var xs := stage.spawn_extras(5, [], _ring(5, 2.0, Vector3(3, 0, 0)))
	for i in xs.size():
		BotBrain.of(xs[i]).configure_extra(&"dance", 7 + i, Vector3(3, 0, 0))
	var path := 0.0
	var last := xs[0].global_position
	for f in 240:
		await step(1)
		path += xs[0].global_position.distance_to(last)
		last = xs[0].global_position
	assert_true(path > 3.0, "dancing moves (%.1f m)" % path)
	for x in xs:
		assert_true(Vector2(x.global_position.x - 3.0, x.global_position.z).length() < 4.5, "stays around the centre")


func _ring(n: int, r: float, c: Vector3 = Vector3.ZERO) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in n:
		var a := TAU * i / n
		out.append(Transform3D(Basis.IDENTITY, c + Vector3(cos(a), 0.0, sin(a)) * r))
	return out


## A dev-arena minigame with `is_ally` (first parameter typed `ally_arg`) and a goal in the middle.
func _ally_arena(ally: bool, by_slot: bool) -> PackedScene:
	var s := GDScript.new()
	var t := "int" if by_slot else "Player"
	s.source_code = "extends Minigame\nvar ally := %s\nfunc is_ally(a: %s, b: %s) -> bool:\n\treturn ally\nfunc get_bot_goal(_p: Player) -> Vector3:\n\treturn Vector3.ZERO\n" % [
		"true" if ally else "false", t, t]
	s.reload()
	var root := DEV_ARENA.instantiate()
	root.set_script(s)
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


func _bot_shoves(ally: bool, by_slot: bool) -> int:
	Net.start_offline()
	Net.add_bot()
	Net.add_bot()
	stage = STAGE_SCENE.instantiate() as Stage
	add_child(stage)
	var m := stage.load_minigame_scene(_ally_arena(ally, by_slot))
	players.assign(stage.players.values())
	var count := [0]
	for p in players:
		p.frozen = false
		if p.is_bot:
			BotBrain.of(p).configure(11 + p.slot, 1.0, 1.0)
			p.shove_started.connect(func() -> void: count[0] += 1)
		else:
			(p.get_component(&"controller") as ControllerComponent).scripted = true
			p.place_at(Transform3D(Basis.IDENTITY, Vector3(8, 0, 8)))  # out of the way
	m._start()
	await step(300)
	stage.clear()
	remove_child(stage)
	stage.queue_free()
	stage = null
	return count[0]


func test_bots_never_shove_allies() -> void:
	var enemies := await _bot_shoves(false, false)
	assert_true(enemies > 0, "control: bots shove each other (%d)" % enemies)
	assert_eq(await _bot_shoves(true, false), 0, "is_ally(Player, Player): no shoves")
	assert_eq(await _bot_shoves(true, true), 0, "is_ally(int, int): no shoves")


# --- Cost --------------------------------------------------------------------------------------

func _frame_ms(frames: int) -> float:
	await step(30)  # settle
	var t0 := Time.get_ticks_usec()
	await step(frames)
	return float(Time.get_ticks_usec() - t0) / 1000.0 / frames


func test_twenty_extras_stay_cheap() -> void:
	spawn_arena(8, &"", false)
	var base: float = await _frame_ms(240)
	stage.spawn_extras(20)
	var with: float = await _frame_ms(240)
	var per := (with - base) / 20.0
	print("extras cost (headless): 8 players %.3f ms/frame, +20 extras %.3f ms/frame -> %.3f ms per extra" % [base, with, per])
	assert_true(per < 0.5, "per-extra cost under 0.5 ms headless (%.3f)" % per)
