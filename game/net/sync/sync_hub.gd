class_name SyncHub
extends Node
## Player sync transport. Owner: player sync. Stage creates one as its child `SyncHub`, so it
## has the same node path on every peer; players never receive RPCs themselves (their nodes
## come and go with rounds), everything goes through here keyed by slot and tagged with
## `Stage.net_load_id`, and traffic for another load or an unknown slot is dropped.
##
## Star topology, host-forwarded (SceneMultiplayer's server_relay is off, see Net): a client
## sends only to the host; the host applies what it receives, checks it, and forwards it to
## the other clients with the true origin peer attached (`_rpc_fwd_*`, callable by the host
## only, so a client cannot claim to be someone else).
## - State: 30 times a second each peer sends one unreliable packet with the state of every
##   player it is authority for (SyncComponent.pack_state). Accepted only from that player's
##   authority. The receiving SyncComponent buffers and interpolates it.
## - Extras (Stage.spawn_extras, slots >= 100, always host-owned): the host adds one compact
##   packet per tick with all of them (`pack_extras`, EXTRA_BYTES each); events and impulses
##   work exactly as for players (slots are looked up with `Stage.get_body`).
## - Events: `Player.emit_event` -> SyncComponent.relay_event -> every other peer (reliable)
##   -> `Player.receive_event`. Accepted from the player's authority or the host;
##   `eliminated` / `respawned` only from the host.
## - Impulses: `Player.apply_impulse` on a non-authority -> the authority only (reliable).
##   Accepted from the host, or from the authority of the source player.
## Offline (no connected ENet peer) it sends nothing.
## Every send goes peer by peer to `live_peers()` only: when several clients drop in the same
## network poll, the ones not handled yet are ENet zombies (0 channels) still listed in
## `multiplayer.get_peers()`, and sending to them logs "Unable to send packet".

const FLAG_ON_FLOOR := 1
const FLAG_CONTROL_LOCKED := 2
const FLAG_ALIVE := 4
const FLAG_FROZEN := 8
## Events only the host may raise for a player.
const HOST_ONLY_EVENTS: Array[StringName] = [&"eliminated", &"respawned"]
const HOST_PEER := 1

## State packets per second.
@export var send_rate: float = 30.0

## The Stage this hub belongs to (set by Stage before it enters the tree).
var stage: Stage = null
## Local sync clock: seconds of physics time. Stamps outgoing state; remotes estimate
## each sender's clock offset from it.
var clock: float = 0.0

var _send_accum: float = 0.0
var _seq: int = 0
## sender peer -> estimated (local clock - sender clock), i.e. one-way latency + clock skew.
var _offsets: Dictionary[int, float] = {}
static var _event_names: Dictionary = {}


## True when `mp` has a connected network peer (not offline).
static func is_networked(mp: MultiplayerAPI) -> bool:
	if mp == null:
		return false
	var peer := mp.multiplayer_peer
	return peer != null and not (peer is OfflineMultiplayerPeer) \
			and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## Peers this one can send to right now: `multiplayer.get_peers()` minus any whose direct
## ENet link (host -> client, client -> host) is no longer CONNECTED, i.e. a peer whose
## disconnect has arrived but whose `peer_disconnected` has not been handled yet. Peers that
## already left are not listed by `get_peers()`. Clients reach other clients through the host's
## relay; those links are the host's business.
static func live_peers(mp: MultiplayerAPI) -> Array[int]:
	var out: Array[int] = []
	if not is_networked(mp):
		return out
	var enet := mp.multiplayer_peer as ENetMultiplayerPeer
	var server := mp.is_server()
	for id in mp.get_peers():
		if enet and (server or id == HOST_PEER):
			var pp := enet.get_peer(id)
			if pp == null or pp.get_state() != ENetPacketPeer.STATE_CONNECTED:
				continue
		out.append(id)
	return out


func _physics_process(delta: float) -> void:
	clock += delta
	if stage == null or not is_networked(multiplayer) or multiplayer.get_peers().is_empty():
		_send_accum = 0.0
		return
	_send_accum += delta
	var interval := 1.0 / maxf(send_rate, 1.0)
	if _send_accum + 0.0001 < interval:
		return
	_send_accum = minf(_send_accum - interval, interval)
	var data: Array = []
	for p: Player in stage.players.values():
		if not is_instance_valid(p) or not p.is_authority():
			continue
		var s := p.get_component(&"sync") as SyncComponent
		if s:
			data.append(s.pack_state())
	var extras := PackedByteArray()
	if multiplayer.is_server() and not stage.extras.is_empty():
		extras = pack_extras(stage.extras)
	if data.is_empty() and extras.is_empty():
		return
	_seq += 1
	if multiplayer.is_server():
		for id in live_peers(multiplayer):
			if not data.is_empty():
				_rpc_fwd_states.rpc_id(id, HOST_PEER, stage.net_load_id, _seq, clock, data)
			if not extras.is_empty():
				_rpc_fwd_extras.rpc_id(id, stage.net_load_id, _seq, clock, extras)
	elif live_peers(multiplayer).has(HOST_PEER):
		_rpc_states.rpc_id(HOST_PEER, stage.net_load_id, _seq, clock, data)


## The sender's clock "now" as estimated here (for interpolation), or -INF if unknown.
func sender_clock(peer_id: int) -> float:
	if not _offsets.has(peer_id):
		return -INF
	return clock - _offsets[peer_id]


# --- Outgoing ---------------------------------------------------------------------------------

## Raises `event` for `p` on every other peer.
func send_event(p: Player, event: StringName, args: Array) -> void:
	if stage == null or not is_networked(multiplayer) or multiplayer.get_peers().is_empty():
		return
	if multiplayer.is_server():
		_forward_event(HOST_PEER, stage.net_load_id, p.slot, event, args)
	elif live_peers(multiplayer).has(HOST_PEER):
		_rpc_event.rpc_id(HOST_PEER, stage.net_load_id, p.slot, event, args)


## Hands an impulse for `p` to its authority.
func send_impulse(p: Player, impulse: Vector3, source: Player) -> void:
	if stage == null or not is_networked(multiplayer):
		return
	var auth := p.get_multiplayer_authority()
	if auth == multiplayer.get_unique_id():
		return
	var source_slot := source.slot if is_instance_valid(source) else -1
	if multiplayer.is_server():
		if live_peers(multiplayer).has(auth):
			_rpc_fwd_impulse.rpc_id(auth, HOST_PEER, stage.net_load_id, p.slot, impulse, source_slot)
	elif live_peers(multiplayer).has(HOST_PEER):
		_rpc_impulse.rpc_id(HOST_PEER, stage.net_load_id, p.slot, impulse, source_slot)


# --- RPCs --------------------------------------------------------------------------------------

# Client -> host. The host applies, checks and forwards; anywhere else they are ignored.

@rpc("any_peer", "call_remote", "unreliable")
func _rpc_states(load_id: Variant, seq: Variant, t: Variant, data: Variant) -> void:
	if not multiplayer.is_server():
		return
	var origin := multiplayer.get_remote_sender_id()
	receive_states(origin, load_id, seq, t, data)
	if typeof(load_id) != TYPE_INT or typeof(seq) != TYPE_INT or typeof(t) != TYPE_FLOAT or typeof(data) != TYPE_ARRAY:
		return
	for id in live_peers(multiplayer):
		if id != origin:
			_rpc_fwd_states.rpc_id(id, origin, load_id, seq, t, data)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_event(load_id: Variant, slot: Variant, event: Variant, args: Variant) -> void:
	if not multiplayer.is_server():
		return
	var origin := multiplayer.get_remote_sender_id()
	if receive_event(origin, load_id, slot, event, args):
		_forward_event(origin, load_id, slot, event, args)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_impulse(load_id: Variant, slot: Variant, impulse: Variant, source_slot: Variant) -> void:
	if not multiplayer.is_server():
		return
	var origin := multiplayer.get_remote_sender_id()
	var victim := _impulse_victim(origin, load_id, slot, impulse, source_slot)
	if victim == null:
		return
	if victim.is_authority():
		receive_impulse(origin, load_id, slot, impulse, source_slot)
	elif live_peers(multiplayer).has(victim.get_multiplayer_authority()):
		_rpc_fwd_impulse.rpc_id(victim.get_multiplayer_authority(), origin, load_id, slot, impulse, source_slot)


# Host -> client, with the origin peer the host saw (only the host may call these).

@rpc("authority", "call_remote", "unreliable")
func _rpc_fwd_states(origin: Variant, load_id: Variant, seq: Variant, t: Variant, data: Variant) -> void:
	if typeof(origin) == TYPE_INT:
		receive_states(origin, load_id, seq, t, data)


@rpc("authority", "call_remote", "reliable")
func _rpc_fwd_event(origin: Variant, load_id: Variant, slot: Variant, event: Variant, args: Variant) -> void:
	if typeof(origin) == TYPE_INT:
		receive_event(origin, load_id, slot, event, args)


@rpc("authority", "call_remote", "reliable")
func _rpc_fwd_impulse(origin: Variant, load_id: Variant, slot: Variant, impulse: Variant, source_slot: Variant) -> void:
	if typeof(origin) == TYPE_INT:
		receive_impulse(origin, load_id, slot, impulse, source_slot)


## Host -> client: the state of every extra (host-owned), packed by `pack_extras`.
@rpc("authority", "call_remote", "unreliable")
func _rpc_fwd_extras(load_id: Variant, seq: Variant, t: Variant, packed: Variant) -> void:
	receive_extras(HOST_PEER, load_id, seq, t, packed)


## Host: raises an event from `origin` on every live client except `origin`.
func _forward_event(origin: int, load_id: Variant, slot: Variant, event: Variant, args: Variant) -> void:
	for id in live_peers(multiplayer):
		if id != origin:
			_rpc_fwd_event.rpc_id(id, origin, load_id, slot, event, args)


# --- Incoming (public so tests can play any sender) ----------------------------------------------

## A state packet from `sender`. Returns how many player states were applied.
func receive_states(sender: int, load_id: Variant, seq: Variant, t: Variant, data: Variant) -> int:
	if stage == null or typeof(load_id) != TYPE_INT or typeof(seq) != TYPE_INT \
			or typeof(t) != TYPE_FLOAT or typeof(data) != TYPE_ARRAY:
		return 0
	var off: float = clock - float(t)
	if not _offsets.has(sender) or off < _offsets[sender]:
		_offsets[sender] = off
	else:
		_offsets[sender] = lerpf(_offsets[sender], off, 0.01)  # follow drift / slower routes slowly
	if load_id != stage.net_load_id:
		return 0
	var applied := 0
	for e: Variant in data:
		if typeof(e) != TYPE_ARRAY or (e as Array).is_empty() or typeof(e[0]) != TYPE_INT:
			continue
		var p := stage.get_body(e[0])
		if p == null or p.is_authority() or p.get_multiplayer_authority() != sender:
			continue
		var s := p.get_component(&"sync") as SyncComponent
		if s and s.receive_state(seq, t, e):
			applied += 1
	return applied


## A packed extras state packet from `sender` (only the host's are accepted). Returns how
## many extra states were applied.
func receive_extras(sender: int, load_id: Variant, seq: Variant, t: Variant, packed: Variant) -> int:
	if sender != HOST_PEER or typeof(packed) != TYPE_PACKED_BYTE_ARRAY:
		return 0
	return receive_states(sender, load_id, seq, t, unpack_extras(packed))


# --- Extras wire format ---------------------------------------------------------------------
# Extras are many and always host-owned, so their state travels compactly in one
# PackedByteArray per tick (EXTRA_BYTES each; 20 extras = 520 bytes, well under one MTU) instead
# of SyncComponent's Variant array (~88 bytes each). Per extra, little endian:
#   u8 slot - EXTRA_SLOT_BASE, u8 flags, u16 respawns, u16 teleports,
#   f32 x3 position, f16 x3 velocity, u16 facing yaw (0..65535 = 0..TAU).
# Decoded back into SyncComponent.pack_state()'s array, so remote playback is the same as bots'.

const EXTRA_BYTES := 26


## Packs the current state of `extras` (valid ones with a sync component).
static func pack_extras(extras: Array[Player]) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(extras.size() * EXTRA_BYTES)
	var o := 0
	for p in extras:
		if not is_instance_valid(p):
			continue
		var s := p.get_component(&"sync") as SyncComponent
		if s == null:
			continue
		var e := s.pack_state()  # [slot, respawns, teleports, pos, vel, facing, flags]
		var pos: Vector3 = e[3]
		var vel: Vector3 = e[4]
		var f: Vector3 = e[5]
		out.encode_u8(o, clampi(int(e[0]) - Stage.EXTRA_SLOT_BASE, 0, 255))
		out.encode_u8(o + 1, int(e[6]) & 0xFF)
		out.encode_u16(o + 2, int(e[1]) & 0xFFFF)
		out.encode_u16(o + 4, int(e[2]) & 0xFFFF)
		out.encode_float(o + 6, pos.x)
		out.encode_float(o + 10, pos.y)
		out.encode_float(o + 14, pos.z)
		out.encode_half(o + 18, vel.x)
		out.encode_half(o + 20, vel.y)
		out.encode_half(o + 22, vel.z)
		out.encode_u16(o + 24, int(fposmod(atan2(f.x, f.z), TAU) / TAU * 65535.0 + 0.5) & 0xFFFF)
		o += EXTRA_BYTES
	out.resize(o)
	return out


## The inverse of pack_extras: one state array per extra (empty on a malformed packet).
static func unpack_extras(packed: PackedByteArray) -> Array:
	var out: Array = []
	if packed.size() % EXTRA_BYTES != 0:
		return out
	for o in range(0, packed.size(), EXTRA_BYTES):
		var yaw := float(packed.decode_u16(o + 24)) / 65535.0 * TAU
		out.append([Stage.EXTRA_SLOT_BASE + packed.decode_u8(o), packed.decode_u16(o + 2), packed.decode_u16(o + 4),
			Vector3(packed.decode_float(o + 6), packed.decode_float(o + 10), packed.decode_float(o + 14)),
			Vector3(packed.decode_half(o + 18), packed.decode_half(o + 20), packed.decode_half(o + 22)),
			Vector3(sin(yaw), 0.0, cos(yaw)), packed.decode_u8(o + 1)])
	return out


## An event from `sender`. Returns true if it was raised here.
func receive_event(sender: int, load_id: Variant, slot: Variant, event: Variant, args: Variant) -> bool:
	if stage == null or typeof(load_id) != TYPE_INT or load_id != stage.net_load_id \
			or typeof(slot) != TYPE_INT or typeof(args) != TYPE_ARRAY \
			or (typeof(event) != TYPE_STRING_NAME and typeof(event) != TYPE_STRING):
		return false
	var p := stage.get_body(slot)
	var ev := StringName(event)
	if p == null or not _is_player_event(p, ev):
		return false
	if HOST_ONLY_EVENTS.has(ev):
		if sender != HOST_PEER:
			return false
	elif sender != HOST_PEER and sender != p.get_multiplayer_authority():
		return false
	p.receive_event(ev, args)
	return true


## An impulse for a player this peer simulates. Returns true if it was applied.
func receive_impulse(sender: int, load_id: Variant, slot: Variant, impulse: Variant, source_slot: Variant) -> bool:
	var p := _impulse_victim(sender, load_id, slot, impulse, source_slot)
	if p == null or not p.is_authority():
		return false
	p.apply_impulse(impulse, stage.get_body(source_slot) if source_slot >= 0 else null)
	return true


## The victim of a well-formed impulse `sender` may give (host: anyone; others: only as the
## authority of the source player), or null.
func _impulse_victim(sender: int, load_id: Variant, slot: Variant, impulse: Variant, source_slot: Variant) -> Player:
	if stage == null or typeof(load_id) != TYPE_INT or load_id != stage.net_load_id \
			or typeof(slot) != TYPE_INT or typeof(impulse) != TYPE_VECTOR3 or typeof(source_slot) != TYPE_INT:
		return null
	var p := stage.get_body(slot)
	if p == null or not (impulse as Vector3).is_finite():
		return null
	var source: Player = stage.get_body(source_slot) if source_slot >= 0 else null
	if sender != HOST_PEER and (source == null or source.get_multiplayer_authority() != sender):
		return null
	return p


## Only the signals declared by the Player script (not Node's own, like tree_exited).
func _is_player_event(p: Player, ev: StringName) -> bool:
	if _event_names.is_empty():
		var script := p.get_script() as Script
		if script:
			for s: Dictionary in script.get_script_signal_list():
				_event_names[StringName(s["name"])] = true
	return _event_names.has(ev)
