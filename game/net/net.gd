extends Node
## Autoload `Net`: hosting, joining, LAN discovery and the player roster. Owner: net.
##
## ENet high-level multiplayer. The host is peer 1 and owns the roster: it assigns slots,
## adds/removes bots and sends the full roster to every client on any change. Clients only
## ask (handshake, `set_local_profile`). Offline (`start_offline`) this peer is 1 and slot 0.
##
## Handshake (SceneMultiplayer auth, before any RPC): the client sends a JSON hello with the
## protocol version, name and loadout; the host answers accept or a `join_failed` reason
## (NetProtocol.REASON_*: "timeout", "full", "in progress", "version mismatch", "could not connect").
##
## LAN discovery: while hosting, a JSON beacon goes out once a second to UDP ports
## DISCOVERY_PORT .. DISCOVERY_PORT + DISCOVERY_PORT_COUNT - 1 (several listeners on one PC
## each bind the first free one). `start_discovery` raises `games_found` whenever the list of
## live games changes; each entry: {id, address ("ip:port", pass it to join_game), ip, port,
## game_name, host_name, players, max_players, in_lobby, version, compatible}.
##
## User args (after `--`): `--port=N` ENet port, `--bind-ip=A` listen only on A (e.g. 127.0.0.1).

signal roster_changed
signal games_found(games: Array)
signal join_failed(reason: String)
signal server_closed

const MAX_PLAYERS := 8
const DEFAULT_PORT := 24565
const DISCOVERY_PORT := 24566
const DISCOVERY_PORT_COUNT := 4
const PROTOCOL_VERSION := NetProtocol.VERSION
const JOIN_TIMEOUT_SEC := 5.0
const BEACON_INTERVAL_SEC := 1.0
const GAME_EXPIRY_SEC := 3.5
## ENet accepts a few more connections than slots so a joiner hears "full" instead of timing out.
const _ENET_MAX_CLIENTS := MAX_PLAYERS + 4
## Per-peer ENet timeout (ENetPacketPeer.set_timeout: RTT factor, min ms, max ms). The ENet
## defaults (5-30 s) left a PC that dropped off the network standing as a frozen ghost.
const PEER_TIMEOUT := Vector3i(32, 2000, 6000)

enum Mode { OFFLINE, HOSTING, JOINING, CLIENT }

## ENet port for host_game and the default for join_game (`--port=N` overrides).
@export var port: int = DEFAULT_PORT
## Interface to listen on; "*" = all (`--bind-ip=A` overrides).
@export var bind_ip: String = "*"

## slot -> PlayerInfo. Every peer holds the same roster.
var roster: Dictionary[int, PlayerInfo] = {}
## Host writes (Session sets it while a session runs); replicated to clients with the roster
## and advertised as `in_lobby = false`. While true, new joiners are refused ("in progress")
## unless `accept_late_joiners`; accepted late joiners get a roster slot like anyone else.
var session_in_progress: bool = false:
	set(value):
		if session_in_progress == value:
			return
		session_in_progress = value
		if _mode == Mode.HOSTING:
			_send_roster()
var accept_late_joiners: bool = false
## Name of the hosted game (host), or the joined host's game (client, from its beacon: unknown here).
var game_name: String = ""

var _mode: Mode = Mode.OFFLINE
var _local_name: String = "Player"
var _local_loadout: Dictionary = {}
## Protocol version this peer claims in its hello (tests fake a mismatch through it).
var _hello_version: int = PROTOCOL_VERSION
## Host: accepted in the handshake, waiting for peer_connected. peer_id -> {name, loadout}.
var _pending: Dictionary[int, Dictionary] = {}
## Bumped whenever the connection is torn down, so deferred work for an old one is dropped.
var _generation: int = 0
var _join_timer: Timer
var _beacon_timer: Timer
var _beacon_socket: PacketPeerUDP = null
var _beacon_targets: Array[String] = []
var _beacon_id: String = ""
var _listener: PacketPeerUDP = null
var _found: Dictionary = {}  # beacon id -> {entry: Dictionary, seen: float}
var _found_signature: String = ""
var _clock: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port=") and arg.trim_prefix("--port=").is_valid_int():
			port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--bind-ip="):
			bind_ip = arg.trim_prefix("--bind-ip=")
	_join_timer = Timer.new()
	_join_timer.one_shot = true
	_join_timer.timeout.connect(func() -> void: _fail_join(NetProtocol.REASON_TIMEOUT, _generation))
	add_child(_join_timer)
	_beacon_timer = Timer.new()
	_beacon_timer.wait_time = BEACON_INTERVAL_SEC
	_beacon_timer.timeout.connect(_send_beacon)
	add_child(_beacon_timer)
	var sm := multiplayer as SceneMultiplayer
	if sm:
		sm.auth_callback = _on_auth
		sm.auth_timeout = JOIN_TIMEOUT_SEC
		# Star topology: clients talk only to the host (player sync forwards client traffic
		# itself, game/net/sync/sync_hub.gd). Without the engine's relay the host also stops
		# announcing peer joins/leaves to clients, which went to peers that were themselves
		# mid-disconnect when several clients dropped at once ("Unable to send packet").
		sm.server_relay = false
		sm.peer_authenticating.connect(_on_peer_authenticating)
		sm.peer_authentication_failed.connect(_on_peer_authentication_failed)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func() -> void: _fail_join(NetProtocol.REASON_TIMEOUT, _generation))
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _exit_tree() -> void:
	# Quitting: tell the other side now instead of letting it time out.
	_shutdown_peer()
	stop_discovery()


func _process(delta: float) -> void:
	_clock += delta
	if _listener:
		_poll_discovery()


# --- Public API (docs/contract.md) ------------------------------------------------------

## Hosts a LAN game under `game_name`: this peer becomes 1 and slot 0, beacons start.
func host_game(p_game_name: String) -> Error:
	_shutdown_peer()
	var peer := ENetMultiplayerPeer.new()
	if bind_ip != "*" and bind_ip != "":
		peer.set_bind_ip(bind_ip)
	var err := peer.create_server(port, _ENET_MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_mode = Mode.HOSTING
	game_name = p_game_name
	session_in_progress = false
	roster.clear()
	roster[0] = PlayerInfo.new(0, 1, _local_name, false, _loadout_or_default(_local_loadout, 0))
	roster_changed.emit()
	_start_beacon()
	return OK


## Joins the host at `address` ("ip", "name" or "ip:port"; default port `port`). Returns an
## error only if the attempt could not start; later failures arrive as `join_failed(reason)`,
## success as `roster_changed` with `local_slot() >= 0`.
func join_game(address: String) -> Error:
	var hp := NetProtocol.split_address(address, port)
	var host: String = hp[0]
	if host == "":
		return ERR_INVALID_PARAMETER
	_shutdown_peer()
	session_in_progress = false
	if not roster.is_empty():
		roster.clear()
		roster_changed.emit()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, hp[1])
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_mode = Mode.JOINING
	game_name = ""
	_join_timer.start(JOIN_TIMEOUT_SEC)
	return OK


## Single-player session on this machine: this peer is host (id 1); the local human is slot 0.
func start_offline() -> void:
	_shutdown_peer()
	session_in_progress = false
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	roster.clear()
	var loadout := _local_loadout if not _local_loadout.is_empty() else Cosmetics.default_loadout(0)
	roster[0] = PlayerInfo.new(0, multiplayer.get_unique_id(), _local_name, false, loadout)
	roster_changed.emit()


## Leaves the game (or closes it when hosting) and clears the roster.
func leave() -> void:
	_shutdown_peer()
	session_in_progress = false
	roster.clear()
	roster_changed.emit()


## Starts listening for LAN games; results arrive through `games_found`. Never fails loudly:
## when every discovery port is taken it warns and finds nothing.
func start_discovery() -> void:
	if _listener:
		return
	var ip := bind_ip if bind_ip != "*" and bind_ip != "" else "0.0.0.0"
	for i in DISCOVERY_PORT_COUNT:
		var sock := PacketPeerUDP.new()
		if sock.bind(DISCOVERY_PORT + i, ip) == OK:
			_listener = sock
			break
	if _listener == null:
		push_warning("Net: discovery ports %d-%d are all in use; LAN games will not be listed" % [DISCOVERY_PORT, DISCOVERY_PORT + DISCOVERY_PORT_COUNT - 1])
	_found.clear()
	_found_signature = ""


func stop_discovery() -> void:
	if _listener:
		_listener.close()
		_listener = null
	_found.clear()
	_found_signature = ""


## True on the host (and offline).
func is_host() -> bool:
	return multiplayer.is_server()


## Slot of the human on this peer, or -1.
func local_slot() -> int:
	var me := multiplayer.get_unique_id()
	for s: int in roster:
		var info := roster[s]
		if info.peer_id == me and not info.is_bot:
			return s
	return -1


## Host only. Adds a bot in the lowest free slot; returns the slot, or -1 when full (or not host).
func add_bot() -> int:
	if not _can_edit_roster():
		return -1
	var s := NetProtocol.free_slot(roster, MAX_PLAYERS)
	if s < 0 or (_mode == Mode.HOSTING and roster.size() + _pending.size() >= MAX_PLAYERS):
		return -1
	roster[s] = PlayerInfo.new(s, multiplayer.get_unique_id(), "Bot %d" % s, true, Cosmetics.default_loadout(s))
	_roster_updated()
	return s


## Host only. Removes the bot in `slot` (humans are not removed).
func remove_bot(slot: int) -> void:
	if _can_edit_roster() and roster.has(slot) and roster[slot].is_bot:
		roster.erase(slot)
		_roster_updated()


## Sets this peer's name and loadout, now and for the next game. On a client the host applies
## it and the change comes back with the roster.
func set_local_profile(player_name: String, loadout: Dictionary) -> void:
	_local_name = player_name
	_local_loadout = loadout
	if _mode == Mode.CLIENT:
		_rpc_set_profile.rpc_id(1, player_name, loadout)
		return
	if _mode == Mode.JOINING:
		return  # goes out with the hello (or already went; the host has the old one until then)
	var s := local_slot()
	if s >= 0:
		roster[s].name = unique_name(roster, s, player_name)
		roster[s].loadout = loadout
		_roster_updated()


# --- Host side ----------------------------------------------------------------------------

func _can_edit_roster() -> bool:
	return _mode == Mode.OFFLINE or _mode == Mode.HOSTING


## Host: why `hello` from `peer_id` is refused ("" = accepted and reserved a slot).
func _host_accept(peer_id: int, hello: Dictionary) -> String:
	var reason := NetProtocol.check_join(hello, roster.size() + _pending.size(), MAX_PLAYERS,
			session_in_progress and not accept_late_joiners)
	if reason == "":
		_pending[peer_id] = {
			"name": NetProtocol.sanitize_name(hello.get("name"), "Player"),
			"loadout": hello.get("loadout", {}),
		}
	return reason


## Host: a peer finished the handshake; give it a slot. Returns the slot, -1 if none.
func _host_add_peer(peer_id: int) -> int:
	var p: Dictionary = _pending.get(peer_id, {"name": "Player", "loadout": {}})
	_pending.erase(peer_id)
	var s := NetProtocol.free_slot(roster, MAX_PLAYERS)
	if s < 0:
		return -1
	roster[s] = PlayerInfo.new(s, peer_id, unique_name(roster, s, p["name"]), false, _loadout_or_default(p["loadout"], s))
	_roster_updated()
	return s


## `wanted`, or "wanted 2", "wanted 3"... so no other roster entry than `slot` has the same
## name (case-insensitive; at most 16 characters). Friends all called "Player" stay apart.
static func unique_name(p_roster: Dictionary[int, PlayerInfo], slot: int, wanted: String) -> String:
	var taken: Array[String] = []
	for s: int in p_roster:
		if s != slot:
			taken.append(p_roster[s].name.to_lower())
	if not taken.has(wanted.to_lower()):
		return wanted
	for n in range(2, MAX_PLAYERS + 2):
		var suffix := " %d" % n
		var candidate := wanted.left(16 - suffix.length()).strip_edges() + suffix
		if not taken.has(candidate.to_lower()):
			return candidate
	return wanted


## Host: a peer left; free its slot(s).
func _host_drop_peer(peer_id: int) -> void:
	_pending.erase(peer_id)
	var gone: Array[int] = []
	for s: int in roster:
		if roster[s].peer_id == peer_id and not roster[s].is_bot:
			gone.append(s)
	for s in gone:
		roster.erase(s)
	if not gone.is_empty():
		_roster_updated()


func _loadout_or_default(loadout: Variant, slot: int) -> Dictionary:
	var fallback := Cosmetics.default_loadout(slot)
	if typeof(loadout) != TYPE_DICTIONARY or (loadout as Dictionary).is_empty():
		return fallback
	return NetProtocol.sanitize_loadout(loadout, fallback)


## Local roster changed (offline or host): tell listeners, and clients when hosting.
func _roster_updated() -> void:
	roster_changed.emit()
	if _mode == Mode.HOSTING:
		_send_roster()


func _send_roster() -> void:
	if multiplayer.get_peers().is_empty():
		return
	# Peer by peer, skipping clients whose ENet link is no longer CONNECTED: when several
	# clients drop in the same network poll, the ones not handled yet are zombies (0 channels)
	# still listed by get_peers(), and sending to them logs "Unable to send packet".
	var data := NetProtocol.roster_to_array(roster)
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	for id in multiplayer.get_peers():
		var pp := enet.get_peer(id) if enet else null
		if enet and (pp == null or pp.get_state() != ENetPacketPeer.STATE_CONNECTED):
			continue
		_rpc_roster.rpc_id(id, data, session_in_progress)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_profile(player_name: Variant, loadout: Variant) -> void:
	if _mode != Mode.HOSTING:
		return
	var sender := multiplayer.get_remote_sender_id()
	for s: int in roster:
		var info := roster[s]
		if info.peer_id == sender and not info.is_bot:
			info.name = unique_name(roster, s, NetProtocol.sanitize_name(player_name, info.name))
			info.loadout = _loadout_or_default(loadout, s)
			_roster_updated()
			return


# --- Client side ----------------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _rpc_roster(data: Variant, in_progress: Variant) -> void:
	if _mode != Mode.CLIENT and _mode != Mode.JOINING:
		return
	_mode = Mode.CLIENT
	_join_timer.stop()
	NetProtocol.fill_roster(roster, data, MAX_PLAYERS)
	session_in_progress = in_progress == true
	roster_changed.emit()


func _fail_join(reason: String, generation: int) -> void:
	if generation != _generation or _mode != Mode.JOINING:
		return
	_shutdown_peer()
	join_failed.emit(reason)


# --- Multiplayer signals ---------------------------------------------------------------------

func _on_auth(peer_id: int, data: PackedByteArray) -> void:
	var sm := multiplayer as SceneMultiplayer
	var msg := NetProtocol.parse_json_object(data)
	if _mode == Mode.HOSTING:
		var reason := _host_accept(peer_id, msg)
		sm.send_auth(peer_id, NetProtocol.make_reply(reason))
		if reason == "":
			sm.complete_auth(peer_id)
		# Refused: the client disconnects itself; auth_timeout drops it otherwise.
	elif _mode == Mode.JOINING and peer_id == 1:
		if msg.get("ok") == true:
			sm.complete_auth(1)
		else:
			var reason: String = str(msg.get("reason", "")) if msg.get("reason", "") != "" else NetProtocol.REASON_VERSION
			# Not from inside the auth callback: it runs in the middle of the peer's packet loop.
			_fail_join.call_deferred(reason, _generation)


func _on_peer_authenticating(peer_id: int) -> void:
	if _mode == Mode.JOINING and peer_id == 1:
		(multiplayer as SceneMultiplayer).send_auth(1, NetProtocol.make_hello(_hello_version, _local_name, _local_loadout))


func _on_peer_authentication_failed(peer_id: int) -> void:
	if _mode == Mode.HOSTING:
		_pending.erase(peer_id)
	elif peer_id == 1:
		_fail_join(NetProtocol.REASON_TIMEOUT, _generation)


func _on_peer_connected(peer_id: int) -> void:
	if _mode != Mode.HOSTING:
		return
	_apply_timeout(peer_id)
	if session_in_progress and not accept_late_joiners:
		# Accepted in the handshake just before the host pressed START: no slot mid-round.
		_pending.erase(peer_id)
		_rpc_refused.rpc_id(peer_id, NetProtocol.REASON_IN_PROGRESS)
		(multiplayer as SceneMultiplayer).disconnect_peer.call_deferred(peer_id)
		return
	if _host_add_peer(peer_id) < 0:
		(multiplayer as SceneMultiplayer).disconnect_peer(peer_id)


## Client: the host refused us after the handshake (a session started meanwhile).
@rpc("authority", "call_remote", "reliable")
func _rpc_refused(reason: Variant) -> void:
	if _mode != Mode.CLIENT and _mode != Mode.JOINING:
		return
	_shutdown_peer()
	if not roster.is_empty():
		roster.clear()
		roster_changed.emit()
	join_failed.emit(str(reason))


## Shorter ENet timeouts for `peer_id` (host: each client; client: the host, id 1).
func _apply_timeout(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var pp := enet.get_peer(peer_id)
	if pp:
		pp.set_timeout(PEER_TIMEOUT.x, PEER_TIMEOUT.y, PEER_TIMEOUT.z)


func _on_peer_disconnected(peer_id: int) -> void:
	if _mode == Mode.HOSTING:
		_host_drop_peer(peer_id)


func _on_connected_to_server() -> void:
	if _mode == Mode.JOINING:
		_mode = Mode.CLIENT
		_join_timer.stop()
		_apply_timeout(1)


func _on_server_disconnected() -> void:
	if _mode != Mode.CLIENT:
		return
	leave()
	server_closed.emit()


## Closes any ENet connection (notifying the other side) and returns to an offline peer.
## Does not touch the roster.
func _shutdown_peer() -> void:
	_generation += 1
	_mode = Mode.OFFLINE
	_pending.clear()
	if _join_timer:
		_join_timer.stop()
	_stop_beacon()
	if not is_inside_tree():
		return
	var old := multiplayer.multiplayer_peer
	if old is ENetMultiplayerPeer:
		old.close()
	if not (old is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


# --- LAN discovery ------------------------------------------------------------------------

func _start_beacon() -> void:
	_beacon_id = "%08x%08x" % [randi(), randi()]
	_beacon_socket = PacketPeerUDP.new()
	_beacon_socket.set_broadcast_enabled(true)
	var loopback_only := bind_ip.begins_with("127.")
	if _beacon_socket.bind(0, "127.0.0.1" if loopback_only else "0.0.0.0") != OK:
		push_warning("Net: could not open the LAN beacon socket; this game will not be listed")
		_beacon_socket = null
		return
	if loopback_only:
		_beacon_targets = ["127.0.0.1"]
	else:
		_beacon_targets = NetProtocol.beacon_targets(IP.get_local_addresses())
	_send_beacon()
	_beacon_timer.start()


func _stop_beacon() -> void:
	if _beacon_timer:
		_beacon_timer.stop()
	if _beacon_socket:
		_beacon_socket.close()
		_beacon_socket = null


func _send_beacon() -> void:
	if _beacon_socket == null or _mode != Mode.HOSTING:
		return
	var host_name := roster[0].name if roster.has(0) else _local_name
	var packet := NetProtocol.make_beacon({
		"id": _beacon_id, "game_name": game_name, "host_name": host_name,
		"players": roster.size(), "max_players": MAX_PLAYERS,
		"in_lobby": not session_in_progress, "port": port,
	})
	for target in _beacon_targets:
		for i in DISCOVERY_PORT_COUNT:
			_beacon_socket.set_dest_address(target, DISCOVERY_PORT + i)
			_beacon_socket.put_packet(packet)  # errors (unreachable subnet) are expected; ignore


func _poll_discovery() -> void:
	while _listener.get_available_packet_count() > 0:
		var packet := _listener.get_packet()
		var ip := _listener.get_packet_ip()
		var info := NetProtocol.parse_beacon(packet)
		if info.is_empty() or ip == "":
			continue
		var known: Dictionary = _found.get(info["id"], {})
		# The same host arrives over several routes; keep a LAN address over loopback.
		if not known.is_empty() and ip.begins_with("127.") and not (known["entry"]["ip"] as String).begins_with("127."):
			ip = known["entry"]["ip"]
		info["ip"] = ip
		info["address"] = "%s:%d" % [ip, info["port"]]
		_found[info["id"]] = {"entry": info, "seen": _clock}
	for id: String in _found.keys():
		if _clock - float(_found[id]["seen"]) > GAME_EXPIRY_SEC:
			_found.erase(id)
	var games: Array = []
	for id: String in _found:
		games.append(_found[id]["entry"])
	games.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["address"]) < str(b["address"]))
	var signature := JSON.stringify(games)
	if signature != _found_signature:
		_found_signature = signature
		games_found.emit(games)
