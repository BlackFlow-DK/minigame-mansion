class_name SyncHub
extends Node
## Player sync transport. Owner: player sync. Stage creates one as its child `SyncHub`, so it
## has the same node path on every peer; players never receive RPCs themselves (their nodes
## come and go with rounds), everything goes through here keyed by slot and tagged with
## `Stage.net_load_id`, and traffic for another load or an unknown slot is dropped.
##
## - State: 30 times a second each peer sends one unreliable packet with the state of every
##   player it is authority for (SyncComponent.pack_state). Accepted only from that player's
##   authority. The receiving SyncComponent buffers and interpolates it.
## - Events: `Player.emit_event` -> SyncComponent.relay_event -> every other peer (reliable,
##   clients reach each other through the host's relay) -> `Player.receive_event`. Accepted
##   from the player's authority or the host; `eliminated` / `respawned` only from the host.
## - Impulses: `Player.apply_impulse` on a non-authority -> the authority only (reliable).
##   Accepted from the host, or from the authority of the source player.
## Offline (no connected ENet peer) it sends nothing.

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
	if data.is_empty():
		return
	_seq += 1
	_rpc_states.rpc(stage.net_load_id, _seq, clock, data)


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
	_rpc_event.rpc(stage.net_load_id, p.slot, event, args)


## Hands an impulse for `p` to its authority.
func send_impulse(p: Player, impulse: Vector3, source: Player) -> void:
	if stage == null or not is_networked(multiplayer):
		return
	var auth := p.get_multiplayer_authority()
	if auth == multiplayer.get_unique_id():
		return
	var source_slot := source.slot if is_instance_valid(source) else -1
	_rpc_impulse.rpc_id(auth, stage.net_load_id, p.slot, impulse, source_slot)


# --- RPCs --------------------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "unreliable")
func _rpc_states(load_id: Variant, seq: Variant, t: Variant, data: Variant) -> void:
	receive_states(multiplayer.get_remote_sender_id(), load_id, seq, t, data)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_event(load_id: Variant, slot: Variant, event: Variant, args: Variant) -> void:
	receive_event(multiplayer.get_remote_sender_id(), load_id, slot, event, args)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_impulse(load_id: Variant, slot: Variant, impulse: Variant, source_slot: Variant) -> void:
	receive_impulse(multiplayer.get_remote_sender_id(), load_id, slot, impulse, source_slot)


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
		var p := stage.get_player(e[0])
		if p == null or p.is_authority() or p.get_multiplayer_authority() != sender:
			continue
		var s := p.get_component(&"sync") as SyncComponent
		if s and s.receive_state(seq, t, e):
			applied += 1
	return applied


## An event from `sender`. Returns true if it was raised here.
func receive_event(sender: int, load_id: Variant, slot: Variant, event: Variant, args: Variant) -> bool:
	if stage == null or typeof(load_id) != TYPE_INT or load_id != stage.net_load_id \
			or typeof(slot) != TYPE_INT or typeof(args) != TYPE_ARRAY \
			or (typeof(event) != TYPE_STRING_NAME and typeof(event) != TYPE_STRING):
		return false
	var p := stage.get_player(slot)
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
	if stage == null or typeof(load_id) != TYPE_INT or load_id != stage.net_load_id \
			or typeof(slot) != TYPE_INT or typeof(impulse) != TYPE_VECTOR3 or typeof(source_slot) != TYPE_INT:
		return false
	var p := stage.get_player(slot)
	if p == null or not p.is_authority() or not (impulse as Vector3).is_finite():
		return false
	var source: Player = stage.get_player(source_slot) if source_slot >= 0 else null
	if sender != HOST_PEER and (source == null or source.get_multiplayer_authority() != sender):
		return false
	p.apply_impulse(impulse, source)
	return true


## Only the signals declared by the Player script (not Node's own, like tree_exited).
func _is_player_event(p: Player, ev: StringName) -> bool:
	if _event_names.is_empty():
		var script := p.get_script() as Script
		if script:
			for s: Dictionary in script.get_script_signal_list():
				_event_names[StringName(s["name"])] = true
	return _event_names.has(ev)
