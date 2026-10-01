extends GameTest
## Net: roster rules (offline and host-side), wire helpers, LAN discovery on loopback, join timeout.
## Multi-process joins/leaves: game/net/dev/run_net_smoke.ps1.

## Ports away from the real default so a running game on this PC does not interfere.
const TEST_PORT_HOST := 24591
const TEST_PORT_DISCOVERY := 24592
const TEST_PORT_NOBODY := 24593


func after_each() -> void:
	Net.stop_discovery()
	Net.accept_late_joiners = false
	Net.port = Net.DEFAULT_PORT


func _hello(version: int = NetProtocol.VERSION, player_name: String = "Alice") -> Dictionary:
	return NetProtocol.parse_json_object(NetProtocol.make_hello(version, player_name, {}))


# --- Offline roster --------------------------------------------------------------------

func test_offline_roster_and_bots() -> void:
	var changes := watch(Net, &"roster_changed")
	Net.start_offline()
	assert_true(Net.is_host(), "offline is host")
	assert_eq(Net.local_slot(), 0, "local slot")
	assert_eq(Net.roster.size(), 1, "one human")
	assert_eq(Net.roster[0].peer_id, 1, "offline peer id")
	assert_false(Net.roster[0].is_bot, "slot 0 human")
	for i in Net.MAX_PLAYERS - 1:
		assert_eq(Net.add_bot(), i + 1, "bot slot")
	assert_eq(Net.add_bot(), -1, "full")
	assert_eq(Net.roster.size(), Net.MAX_PLAYERS, "8 slots")
	assert_true(Net.roster[5].is_bot and Net.roster[5].peer_id == 1, "bot simulated by host")
	Net.remove_bot(3)
	assert_false(Net.roster.has(3), "bot removed")
	Net.remove_bot(0)
	assert_true(Net.roster.has(0), "humans are not removed by remove_bot")
	assert_eq(Net.add_bot(), 3, "lowest free slot reused")
	assert_eq(changes.size(), 1 + 7 + 1 + 1, "roster_changed per change")
	Net.leave()
	assert_true(Net.roster.is_empty(), "leave clears")
	assert_eq(Net.local_slot(), -1, "no slot after leave")


func test_offline_profile() -> void:
	Net.start_offline()
	var changes := watch(Net, &"roster_changed")
	var loadout := {"primary": "#112233", "secondary": "#ffffff", "hat": "", "face": "", "neck": "", "back": ""}
	Net.set_local_profile("Sander", loadout)
	assert_eq(Net.roster[0].name, "Sander", "name")
	assert_eq(Net.roster[0].loadout, loadout, "loadout")
	assert_eq(changes.size(), 1, "roster_changed")
	Net.start_offline()
	assert_eq(Net.roster[0].name, "Sander", "profile kept for the next game")


# --- Wire helpers ------------------------------------------------------------------------

func test_check_join_reasons() -> void:
	assert_eq(NetProtocol.check_join(_hello(), 1, 8, false), "", "accept")
	assert_eq(NetProtocol.check_join(_hello(NetProtocol.VERSION + 1), 1, 8, false), "version mismatch", "newer version")
	assert_eq(NetProtocol.check_join({}, 1, 8, false), "version mismatch", "garbage hello")
	assert_eq(NetProtocol.check_join({"game": "other", "version": NetProtocol.VERSION}, 1, 8, false), "version mismatch", "other game")
	assert_eq(NetProtocol.check_join(_hello(), 8, 8, false), "full", "full")
	assert_eq(NetProtocol.check_join(_hello(), 1, 8, true), "in progress", "in progress")
	assert_eq(NetProtocol.parse_json_object("not json".to_utf8_buffer()), {}, "bad json")
	assert_eq(NetProtocol.parse_json_object(NetProtocol.make_reply("full")).get("reason"), "full", "reply")


func test_roster_wire_roundtrip() -> void:
	var r: Dictionary[int, PlayerInfo] = {}
	r[0] = PlayerInfo.new(0, 1, "Host", false, {"primary": "#e63946"})
	r[2] = PlayerInfo.new(2, 1, "Bot 2", true, {"primary": "#2a9d8f"})
	r[1] = PlayerInfo.new(1, 12345, "Alice", false, {"primary": "#457b9d"})
	var data := NetProtocol.roster_to_array(r)
	assert_eq(data.size(), 3, "size")
	assert_eq(data[1]["slot"], 1, "sorted by slot")
	var back: Dictionary[int, PlayerInfo] = {}
	back[7] = PlayerInfo.new(7)
	NetProtocol.fill_roster(back, data + [{"slot": "x"}, 42, {"slot": 9, "peer_id": 1}], 8)
	assert_eq(back.keys().size(), 3, "old entries gone, invalid skipped")
	assert_eq(back[1].peer_id, 12345, "peer id")
	assert_eq(back[1].name, "Alice", "name")
	assert_true(back[2].is_bot, "bot flag")
	assert_eq(back[0].loadout, {"primary": "#e63946"}, "loadout")


func test_sanitize() -> void:
	assert_eq(NetProtocol.sanitize_name("  Bob  ", "P"), "Bob", "trim")
	assert_eq(NetProtocol.sanitize_name("", "P"), "P", "empty")
	assert_eq(NetProtocol.sanitize_name(5, "P"), "P", "not a string")
	assert_eq(NetProtocol.sanitize_name("abcdefghijklmnopqrstuvwxyz", "P").length(), NetProtocol.MAX_NAME_LENGTH, "capped")
	var fallback := {"primary": "#ff0000", "secondary": "#00ff00", "hat": "", "face": "", "neck": "", "back": "", "size": "normal"}
	var l := NetProtocol.sanitize_loadout({"primary": "red", "secondary": "#0000ff", "hat": "tophat", "evil": 1, "face": 3, "size": "small"}, fallback)
	assert_eq(l, {"primary": "#ff0000", "secondary": "#0000ff", "hat": "tophat", "face": "", "neck": "", "back": "", "size": "small"}, "loadout")
	assert_eq(NetProtocol.sanitize_loadout({"size": 7}, fallback)["size"], "normal", "bad size -> fallback")
	assert_eq(NetProtocol.sanitize_loadout("nope", fallback), fallback, "not a dictionary")


func test_split_address() -> void:
	assert_eq(NetProtocol.split_address("192.168.1.5", 24565), ["192.168.1.5", 24565], "ip")
	assert_eq(NetProtocol.split_address(" 10.0.0.2:30000 ", 24565), ["10.0.0.2", 30000], "ip:port")
	assert_eq(NetProtocol.split_address("gamepc", 1), ["gamepc", 1], "host name")
	assert_eq(NetProtocol.split_address("1.2.3.4:abc", 1)[0], "", "bad port")
	assert_eq(NetProtocol.split_address("", 1)[0], "", "empty")
	assert_eq(Net.join_game(""), ERR_INVALID_PARAMETER, "join empty address")
	assert_eq(Net.join_game("1.2.3.4:0"), ERR_INVALID_PARAMETER, "join bad port")


func test_beacon_roundtrip_and_targets() -> void:
	var b := NetProtocol.make_beacon({"id": "abc", "game_name": "G", "host_name": "H", "players": 3, "max_players": 8, "in_lobby": true, "port": 24565})
	var info := NetProtocol.parse_beacon(b)
	assert_eq(info.get("players"), 3, "players int")
	assert_eq(info.get("port"), 24565, "port")
	assert_eq(info.get("in_lobby"), true, "in lobby")
	assert_eq(info.get("compatible"), true, "compatible")
	assert_eq(NetProtocol.parse_beacon("hello".to_utf8_buffer()), {}, "foreign packet")
	assert_eq(NetProtocol.parse_beacon(JSON.stringify({"magic": "MMANSION-LAN", "id": "x"}).to_utf8_buffer()), {}, "missing fields")
	var targets := NetProtocol.beacon_targets(PackedStringArray(["127.0.0.1", "192.168.1.20", "fe80::1", "169.254.3.4", "10.0.5.9", "192.168.1.30"]))
	assert_eq(targets, ["255.255.255.255", "127.0.0.1", "192.168.1.255", "10.0.5.255"] as Array[String], "targets")


# --- Real sockets, one process ------------------------------------------------------------

func test_host_roster_rules() -> void:
	Net.port = TEST_PORT_HOST
	var changes := watch(Net, &"roster_changed")
	assert_eq(Net.host_game("Test"), OK, "host_game")
	assert_true(Net.is_host(), "is host")
	assert_eq(Net.local_slot(), 0, "host is slot 0")
	assert_eq(Net.roster[0].peer_id, 1, "host peer id")
	assert_eq(Net._host_accept(100, _hello(NetProtocol.VERSION, "  Alice ")), "", "accept Alice")
	assert_eq(Net._host_add_peer(100), 1, "Alice gets slot 1")
	assert_eq(Net.roster[1].name, "Alice", "sanitised name")
	assert_eq(Net.roster[1].peer_id, 100, "Alice's peer")
	assert_eq(Net.roster[1].loadout, Cosmetics.default_loadout(1), "default loadout for slot")
	assert_eq(Net.add_bot(), 2, "bot slot 2")
	assert_eq(Net._host_accept(101, _hello(99)), "version mismatch", "version")
	Net.session_in_progress = true
	assert_eq(Net._host_accept(101, _hello()), "in progress", "in progress")
	Net.accept_late_joiners = true
	assert_eq(Net._host_accept(101, _hello(NetProtocol.VERSION, "Late")), "", "late joiner accepted when allowed")
	assert_eq(Net._host_add_peer(101), 3, "late joiner slot")
	Net.session_in_progress = false
	Net._host_drop_peer(100)
	assert_false(Net.roster.has(1), "Alice's slot freed")
	assert_true(Net.roster.has(2), "bot kept")
	while Net.add_bot() >= 0:
		pass
	assert_eq(Net.roster.size(), Net.MAX_PLAYERS, "filled with bots")
	assert_eq(Net._host_accept(102, _hello()), "full", "full")
	Net.remove_bot(7)
	assert_eq(Net._host_accept(103, _hello()), "", "room again")
	assert_eq(Net.add_bot(), -1, "pending joiner holds the last slot")
	Net._host_drop_peer(103)
	assert_true(changes.size() >= 6, "roster_changed on changes")
	Net.leave()
	assert_true(Net.roster.is_empty(), "leave clears")
	assert_true(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "offline peer after leave")
	assert_eq(Net.host_game("Again"), OK, "port released by leave")


func test_discovery_finds_host_on_loopback() -> void:
	# Hold the first discovery ports, as other listeners on this PC would.
	var blockers: Array[PacketPeerUDP] = []
	for i in Net.DISCOVERY_PORT_COUNT - 1:
		var b := PacketPeerUDP.new()
		if b.bind(Net.DISCOVERY_PORT + i, "0.0.0.0") == OK:
			blockers.append(b)
	var found := watch(Net, &"games_found")
	Net.start_discovery()
	Net.port = TEST_PORT_DISCOVERY
	assert_eq(Net.host_game("Disco"), OK, "host_game")
	var mine := {}
	for i in 600:
		mine = _find_game(found, TEST_PORT_DISCOVERY)
		if not mine.is_empty():
			break
		await step(1)
	if assert_false(mine.is_empty(), "own game discovered"):
		assert_eq(mine["game_name"], "Disco", "game name")
		assert_eq(mine["players"], 1, "players")
		assert_eq(mine["max_players"], Net.MAX_PLAYERS, "max")
		assert_eq(mine["in_lobby"], true, "in lobby")
		assert_eq(mine["compatible"], true, "compatible")
		assert_eq(mine["address"], "%s:%d" % [mine["ip"], TEST_PORT_DISCOVERY], "address")
		var same := (found[-1][0] as Array).filter(func(g: Dictionary) -> bool: return g["id"] == mine["id"])
		assert_eq(same.size(), 1, "de-duplicated")
	Net.add_bot()
	Net.session_in_progress = true
	for i in 200:
		mine = _find_game(found, TEST_PORT_DISCOVERY)
		if not mine.is_empty() and mine["in_lobby"] == false:
			break
		await step(1)
	assert_eq(mine.get("in_lobby"), false, "in_lobby follows the session")
	assert_eq(mine.get("players"), 2, "player count follows the roster")
	Net.leave()
	for i in 400:
		if _find_game(found, TEST_PORT_DISCOVERY).is_empty():
			break
		await step(1)
	assert_true(_find_game(found, TEST_PORT_DISCOVERY).is_empty(), "stale game expires")
	# Every port taken: a warning, no crash.
	Net.stop_discovery()
	var extra := PacketPeerUDP.new()
	extra.bind(Net.DISCOVERY_PORT + Net.DISCOVERY_PORT_COUNT - 1, "0.0.0.0")
	Net.start_discovery()
	await step(5)
	Net.stop_discovery()
	extra.close()
	for b in blockers:
		b.close()


func test_join_timeout() -> void:
	var failed := watch(Net, &"join_failed")
	assert_eq(Net.join_game("127.0.0.1:%d" % TEST_PORT_NOBODY), OK, "join starts")
	assert_false(Net.is_host(), "client while joining")
	for i in int(Net.JOIN_TIMEOUT_SEC * 60) + 60:
		if not failed.is_empty():
			break
		await step(1)
	assert_eq(failed.size(), 1, "one join_failed")
	if not failed.is_empty():
		assert_eq(failed[0][0], "timeout", "reason")
	assert_true(Net.is_host(), "back to a usable offline peer")
	assert_true(Net.roster.is_empty(), "no roster")
	Net.start_offline()
	assert_eq(Net.local_slot(), 0, "offline works after a failed join")


## Latest games_found entry advertising `port`, or {}.
func _find_game(found: Array, port: int) -> Dictionary:
	if found.is_empty():
		return {}
	for g: Dictionary in found[-1][0]:
		if g["port"] == port:
			return g
	return {}
