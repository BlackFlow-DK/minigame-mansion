extends GameTest
## Player sync (single process): the SyncHub's receive side is driven directly with fake
## sender peer ids; a "remote copy" is a player whose authority is set to another peer.
## The real network path is covered by game/net/sync/dev/run_sync_smoke.ps1.

const DEV_ARENA_PATH_S := "res://dev/dev_arena.tscn"
const ON_FLOOR_ALIVE := SyncHub.FLAG_ON_FLOOR | SyncHub.FLAG_ALIVE


func _remote(p: Player, peer_id: int = 2) -> SyncComponent:
	p.set_multiplayer_authority(peer_id)
	return p.get_component(&"sync") as SyncComponent


func _entry(p: Player, pos: Vector3, vel: Vector3, respawns: int = 0, teleports: int = 0,
		flags: int = ON_FLOOR_ALIVE) -> Array:
	return [p.slot, respawns, teleports, pos, vel, Vector3.RIGHT, flags]


func _info(slot: int, peer_id: int, spawn: int) -> Dictionary:
	var d := PlayerInfo.new(slot, peer_id, "P%d" % slot, false, {}).to_dict()
	d["spawn"] = spawn
	return d


# --- Offline -------------------------------------------------------------------------------

func test_offline_stage_spawns_as_before() -> void:
	var ps := spawn_arena(3)
	assert_eq(ps.size(), 3, "three players")
	for p in ps:
		assert_eq(String(p.name), "P%d" % p.slot, "node name")
		assert_true(p.is_authority(), "offline: every player simulated here")
	assert_true(stage.sync_hub != null and stage.sync_hub.get_parent() == stage, "hub under Stage")
	assert_eq(String(stage.sync_hub.name), "SyncHub", "hub node name")
	var jumps := watch(ps[0], &"jumped")
	ps[0].emit_event(&"jumped")
	assert_eq(jumps.size(), 1, "event raised once locally")
	ps[1].apply_impulse(Vector3(1, 0, 0), ps[0])  # authority: straight to status
	assert_true(ps[1].velocity.x > 0.0, "offline impulse applied")


func test_authority_counts_teleports_and_respawns() -> void:
	var ps := spawn_arena(2)
	var s := ps[0].get_component(&"sync") as SyncComponent
	await step(2)
	assert_eq(s.pack_state()[2], 0, "no teleport yet")
	ps[0].place_at(Transform3D(Basis.IDENTITY, Vector3(6, 0, 6)))
	await step(2)
	assert_eq(s.pack_state()[2], 1, "place_at far away counts as a teleport")
	ps[0].respawn_at(Transform3D(Basis.IDENTITY, Vector3(-3, 0, 0)))
	await step(1)
	var packed := s.pack_state()
	assert_eq(packed[1], 1, "respawn counted")
	assert_eq(packed[0], ps[0].slot, "slot first")
	assert_true(packed[6] & SyncHub.FLAG_ALIVE != 0, "alive flag")


# --- Remote copies ---------------------------------------------------------------------------

func test_remote_copy_interpolates_smoothly() -> void:
	var ps := spawn_arena(2)
	var r := ps[1]
	var s := _remote(r)
	assert_false(r.is_authority(), "remote copy")
	var hub := stage.sync_hub
	var start := Vector3(0, 0, -3)
	var t0 := hub.clock
	var xs: Array[float] = []
	var seq := [0]
	await step(60, func(i: int) -> void:
		if i % 2 == 0:
			seq[0] += 1
			var el := hub.clock - t0
			hub.receive_states(2, stage.net_load_id, seq[0], hub.clock,
					[_entry(r, start + Vector3(3.0 * el, 0, 0), Vector3(3, 0, 0))])
		xs.append(r.global_position.x))
	var elapsed := hub.clock - t0
	assert_near(r.global_position.x, 3.0 * (elapsed - s.interp_delay), 0.2, "about interp_delay behind")
	assert_near(r.velocity, Vector3(3, 0, 0), 0.01, "velocity replicated")
	assert_near(r.facing, Vector3.RIGHT, 0.01, "facing replicated")
	assert_true(s.is_grounded(), "grounded replicated")
	var worst := 0.0
	for i in range(1, xs.size()):
		assert_true(xs[i] >= xs[i - 1] - 0.0001, "never moves backwards (frame %d)" % i)
		worst = maxf(worst, xs[i] - xs[i - 1])
	assert_true(worst <= 3.0 / 60.0 * 2.0 + 0.001, "no jumps between frames (worst %.3f)" % worst)


func test_remote_snaps_on_teleport_and_drops_stale_state() -> void:
	var ps := spawn_arena(2)
	var r := ps[1]
	var s := _remote(r)
	var hub := stage.sync_hub
	var id := stage.net_load_id
	assert_eq(hub.receive_states(2, id, 1, hub.clock, [_entry(r, Vector3(1, 0, 0), Vector3.ZERO)]), 1, "first sample")
	assert_near(r.global_position, Vector3(1, 0, 0), 0.001, "first sample snaps")
	await step(3)
	assert_eq(hub.receive_states(2, id, 1, hub.clock, [_entry(r, Vector3(9, 0, 9), Vector3.ZERO)]), 0, "same seq dropped")
	assert_eq(hub.receive_states(2, id, 2, hub.clock, [_entry(r, Vector3(8, 0, 8), Vector3.ZERO, 0, 1)]), 1, "teleport")
	assert_near(r.global_position, Vector3(8, 0, 8), 0.001, "teleport snaps at once")
	# Host respawns it (its events reach every peer); state sent before that is stale.
	r.respawn_at(Transform3D(Basis.IDENTITY, Vector3(-2, 0, 0)))
	assert_eq(hub.receive_states(2, id, 3, hub.clock, [_entry(r, Vector3(8, 0, 8), Vector3.ZERO, 0, 1)]), 0, "pre-respawn state dropped")
	await step(3)
	assert_near(r.global_position, Vector3(-2, 0, 0), 0.001, "holds at the respawn point")
	assert_eq(hub.receive_states(2, id, 4, hub.clock, [_entry(r, Vector3(-2, 0, 0.5), Vector3.ZERO, 1, 1)]), 1, "post-respawn state")
	assert_near(r.global_position, Vector3(-2, 0, 0.5), 0.001, "snaps to fresh state")
	s.interp_delay = 0.1  # touch the export so a rename breaks this test


func test_state_accepted_only_from_the_authority_and_current_load() -> void:
	var ps := spawn_arena(2)
	var r := ps[1]
	_remote(r)
	var hub := stage.sync_hub
	var id := stage.net_load_id
	assert_eq(hub.receive_states(3, id, 1, hub.clock, [_entry(r, Vector3(5, 0, 5), Vector3.ZERO)]), 0, "not its authority")
	assert_eq(hub.receive_states(2, id + 1, 1, hub.clock, [_entry(r, Vector3(5, 0, 5), Vector3.ZERO)]), 0, "other load")
	assert_eq(hub.receive_states(2, id, 1, hub.clock, [_entry(ps[0], Vector3(5, 0, 5), Vector3.ZERO)]), 0, "a player simulated here")
	assert_eq(hub.receive_states(2, id, 1, hub.clock, [[1, "x"], "junk", [99]]), 0, "garbage ignored")
	assert_eq(hub.receive_states(2, id, "1", hub.clock, []), 0, "bad header ignored")
	assert_true(ps[0].global_position.distance_to(Vector3(5, 0, 5)) > 1.0, "local player untouched")


func test_remote_copy_replicates_status_flags() -> void:
	var ps := spawn_arena(2)
	var r := ps[1]
	var s := _remote(r)
	var hub := stage.sync_hub
	hub.receive_states(2, stage.net_load_id, 1, hub.clock,
			[_entry(r, Vector3(0, 2, 0), Vector3(0, -3, 0), 0, 0, SyncHub.FLAG_CONTROL_LOCKED | SyncHub.FLAG_FROZEN)])
	assert_true(r.control_locked, "control_locked applied to the copy")
	assert_false(s.is_grounded(), "airborne")
	assert_false(s.remote_alive, "alive flag replicated")
	assert_true(s.remote_frozen, "frozen flag replicated")
	assert_true(r.alive, "alive itself follows events only")


# --- Events and impulses -----------------------------------------------------------------------

func test_event_authority_rules() -> void:
	var ps := spawn_arena(2)
	var r := ps[1]
	_remote(r)
	var hub := stage.sync_hub
	var id := stage.net_load_id
	var jumps := watch(r, &"jumped")
	var outs := watch(r, &"eliminated")
	assert_true(hub.receive_event(2, id, r.slot, &"jumped", []), "authority may raise its events")
	assert_eq(jumps.size(), 1, "raised once")
	assert_false(hub.receive_event(3, id, r.slot, &"jumped", []), "a third peer may not")
	assert_true(hub.receive_event(1, id, r.slot, "jumped", []), "the host may (String name ok)")
	assert_eq(jumps.size(), 2, "raised again")
	assert_false(hub.receive_event(2, id, r.slot, &"eliminated", [&"x"]), "only the host eliminates")
	assert_true(r.alive and outs.is_empty(), "still alive")
	assert_false(hub.receive_event(2, id, ps[0].slot, &"eliminated", [&"x"]), "client cannot eliminate others")
	assert_true(ps[0].alive, "host player alive")
	assert_false(hub.receive_event(1, id, r.slot, &"tree_exited", []), "Node signals are not events")
	assert_false(hub.receive_event(1, id + 1, r.slot, &"jumped", []), "other load")
	assert_false(hub.receive_event(1, id, 7, &"jumped", []), "unknown slot")
	assert_true(hub.receive_event(1, id, r.slot, &"eliminated", [&"fell"]), "host eliminates")
	assert_false(r.alive, "eliminated applied")
	assert_eq(outs, [[&"fell"]], "eliminated raised once")
	var at := Transform3D(Basis.IDENTITY, Vector3(2, 0, 2))
	assert_true(hub.receive_event(1, id, r.slot, &"respawned", [at]), "host respawns")
	assert_true(r.alive, "back in play")
	assert_near(r.global_position, Vector3(2, 0, 2), 0.001, "at the respawn point")


func test_impulse_rules() -> void:
	var ps := spawn_arena(3)
	var me := ps[0]
	var other := ps[1]
	_remote(other, 2)
	_remote(ps[2], 3)
	var hub := stage.sync_hub
	var id := stage.net_load_id
	var hits := watch(me, &"got_hit")
	assert_false(hub.receive_impulse(3, id, me.slot, Vector3(5, 1, 0), other.slot), "sender is not the source's authority")
	assert_false(hub.receive_impulse(2, id, me.slot, Vector3(5, 1, 0), -1), "clients need a source they own")
	assert_false(hub.receive_impulse(2, id, other.slot, Vector3(5, 1, 0), other.slot), "not simulated here")
	assert_false(hub.receive_impulse(2, id, me.slot, Vector3(INF, 0, 0), other.slot), "non-finite")
	assert_false(hub.receive_impulse(2, id + 1, me.slot, Vector3(5, 1, 0), other.slot), "other load")
	assert_eq(hits.size(), 0, "nothing applied yet")
	assert_true(hub.receive_impulse(2, id, me.slot, Vector3(5, 1, 0), other.slot), "shove from its owner")
	assert_eq(hits.size(), 1, "got_hit once")
	assert_eq(hits[0][1], other.slot, "source slot")
	assert_true(me.velocity.x > 0.0, "pushed")
	await step(30)
	assert_true(hub.receive_impulse(1, id, me.slot, Vector3(0, 4, 0), -1), "the host may push without a source")
	assert_eq(hits.size(), 2, "second hit")
	other.apply_impulse(Vector3(1, 0, 0), me)  # remote copy, offline: relayed nowhere, no error
	assert_near(other.velocity, Vector3.ZERO, 0.001, "remote copy not pushed locally")


# --- Collisions ------------------------------------------------------------------------------

## Walks player 0 into player 1 standing at (2, 0, 0.3); returns player 0's track.
func _walk_into(remote: bool) -> Array[Vector3]:
	var ps := spawn_arena(2)
	var me := ps[0]
	var r := ps[1]
	var wall := Vector3(2.0, 0, 0.3)
	if remote:
		_remote(r)
	me.place_at(Transform3D(Basis.IDENTITY, Vector3.ZERO))
	r.place_at(Transform3D(Basis.IDENTITY, wall))
	var hub := stage.sync_hub
	var track: Array[Vector3] = []
	var seq := [0]
	await step(60, func(i: int) -> void:
		me.intent.move = Vector2(1, 0)
		if remote and i % 2 == 0:
			seq[0] += 1
			hub.receive_states(2, stage.net_load_id, seq[0], hub.clock, [_entry(r, wall, Vector3.ZERO)])
		track.append(me.global_position))
	assert_near(r.global_position, wall, 0.001, "the other blob never moves (remote=%s)" % remote)
	return track


func test_remote_copy_collides_like_an_offline_blob() -> void:
	var offline := await _walk_into(false)
	_teardown()
	var networked := await _walk_into(true)
	assert_eq(networked.size(), offline.size(), "same length")
	var worst := 0.0
	for i in mini(offline.size(), networked.size()):
		worst = maxf(worst, offline[i].distance_to(networked[i]))
	assert_true(worst < 0.01, "same trajectory as offline (worst %.3f m)" % worst)
	for p in networked:
		assert_true(p.is_finite() and p.y < 1.5, "no launch: %s" % p)


# --- Stage: roster and manifests -------------------------------------------------------------

func test_player_leaving_mid_round_is_knocked_out_and_removed() -> void:
	var ps := spawn_arena(3)
	var m := get_minigame()
	var outs := watch(ps[2], &"eliminated")
	Net.remove_bot(2)
	assert_false(stage.players.has(2), "gone from Stage.players")
	assert_true(stage.get_node_or_null(^"Players/P2") == null, "node removed")
	assert_eq(m.players.size(), 2, "gone from minigame.players")
	assert_eq(m.knocked_out, [2] as Array[int], "knocked out first")
	assert_eq(outs.size(), 1, "eliminated raised")
	assert_false(m.is_finished(), "two left: round goes on")
	Net.remove_bot(1)
	assert_true(m.is_finished(), "one left: finished")
	assert_eq(ranking, [0, 1, 2] as Array[int], "survivor first, then reverse knock-out order")
	await step(2)


func test_follow_roster_adds_and_removes_players() -> void:
	Net.start_offline()
	stage = STAGE_SCENE.instantiate() as Stage
	add_child(stage)
	stage.follow_roster = true
	var m := stage.load_minigame_scene(load(DEV_ARENA_PATH_S) as PackedScene)
	var spawned := watch(stage, &"players_spawned")
	assert_eq(stage.players.size(), 1, "the host")
	var s1 := Net.add_bot()
	assert_true(stage.players.has(s1), "bot added live")
	assert_eq(spawned.size(), 1, "players_spawned for the newcomer")
	assert_eq((spawned[0][0] as Array).size(), 1, "just the newcomer")
	assert_near(stage.get_player(s1).global_position, m.get_spawn_points()[s1].origin, 0.001, "spawn point by slot")
	assert_eq(stage.get_player(s1).get_multiplayer_authority(), 1, "bot simulated by the host")
	var s2 := Net.add_bot()
	assert_eq(m.players.size(), 3, "minigame.players follows")
	Net.remove_bot(s1)
	assert_false(stage.players.has(s1), "removed live")
	assert_true(stage.players.has(s2), "others stay")
	assert_eq(m.knocked_out.size(), 0, "lobby: nobody knocked out")
	await step(2)


func test_manifest_loads_and_reconciles_like_a_client() -> void:
	Net.start_offline()
	stage = STAGE_SCENE.instantiate() as Stage
	add_child(stage)
	stage.apply_manifest(7, DEV_ARENA_PATH_S, false, [_info(0, 1, 0), _info(3, 5, 1)])
	var m := stage.minigame
	assert_true(m != null, "scene loaded from the manifest")
	assert_eq(stage.net_load_id, 7, "load id adopted")
	assert_eq(stage.players.keys().size(), 2, "two players")
	assert_eq(stage.get_player(3).get_multiplayer_authority(), 5, "authority from the manifest")
	assert_true(stage.get_player(3).frozen, "spawned frozen")
	assert_near(stage.get_player(3).global_position, m.get_spawn_points()[1].origin, 0.001, "spawn index from the manifest")
	var p0 := stage.get_player(0)
	stage.apply_manifest(7, DEV_ARENA_PATH_S, false, [_info(0, 1, 0), _info(4, 6, 2)])
	assert_true(stage.minigame == m, "same load: reconciled, not reloaded")
	assert_true(stage.get_player(0) == p0, "kept player untouched")
	assert_false(stage.players.has(3), "dropped player removed")
	assert_eq(stage.get_player(4).get_multiplayer_authority(), 6, "new player added")
	assert_eq(m.players.size(), 2, "minigame.players follows")
	stage.apply_manifest(8, DEV_ARENA_PATH_S, false, [_info(0, 1, 0)])
	assert_true(stage.minigame != m, "a new host load reloads")
	# A client that loaded the scene itself (Session's intro) adopts the manifest.
	var local := stage.load_minigame_scene(load(DEV_ARENA_PATH_S) as PackedScene)
	stage.net_load_id = -1
	stage.apply_manifest(9, DEV_ARENA_PATH_S, false, [_info(0, 1, 0)])
	assert_true(stage.minigame == local, "adopted the local load")
	assert_eq(stage.net_load_id, 9, "with the host's id")
	stage.apply_manifest(10, "res://nope.tscn", false, [])
	assert_true(stage.minigame == local, "unknown scene ignored")
	await step(2)
