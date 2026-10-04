class_name Stage
extends Node3D
## Loads one minigame scene and spawns one Player per `Net.roster` entry at its spawn
## points, on every peer, so node paths match: players are `Players/P<slot>`, each with
## multiplayer authority = its `PlayerInfo.peer_id` (bots: the host). Find it with
## `get_tree().get_first_node_in_group(&"stage")`. The Stage must sit at the same node path
## on every peer (it is part of the main scene): its RPCs and those of its `SyncHub` child
## (player sync transport, game/net/sync/) are addressed by path.
##
## Networking (host-authoritative, explicit RPCs, no MultiplayerSpawner):
## - Any peer's `load_minigame*` loads locally. Session calls it on every peer in the same
##   reliable RPC stream as the roster, so every peer spawns the same players.
## - After each load (and after every change to the player set) the host sends a manifest:
##   load id, scene path, `follow_roster`, and the exact players (PlayerInfo + spawn point).
##   A client adopts it: it reconciles the players it spawned itself, or loads the scene
##   from the manifest when it did not load it (host-only loads, late joiners).
## - Clients never add or remove players from their own roster; only host manifests do.
## - `clear()` on the host clears every peer.
## - Host -> client sends go peer by peer to `SyncHub.live_peers()`, never to a peer that is
##   in the middle of disconnecting (two clients dropping in the same network poll).
## - Normal rounds: a slot that leaves the roster is knocked out (`Minigame.knock_out`, host)
##   so rankings stay right, then removed on every peer. `follow_roster` (lobby): players
##   are added and removed as the roster changes, no knock-outs.
## Offline everything is local, exactly as before.
##
## NPC extras (`spawn_extras`, host only): bot-driven blobs that are not players. They live in
## `extras` and under `Extras/X<slot>` (slots EXTRA_SLOT_BASE..), never in `players`,
## `Minigame.players` or the roster, so nothing that counts players (Session, HUD, camera,
## Progression) sees them. Authority is the host; clients get them through the manifest and the
## SyncHub syncs them like bots (compact packets). Freed with the stage (`clear`, next load).
## Batched spawning (`spawn_extras(..., batch)`): building ~20 blobs in one frame stalls a peer
## for most of a second (long enough to drop ENet clients while a round loads), so the host
## builds `batch` per frame and sends the manifest once all are in; clients that get a manifest
## over the network build new extras CLIENT_EXTRA_BATCH per frame. `extras_spawned` comes once
## when a batch run is complete.

signal players_spawned(players: Array[Player])
## Extras spawned on this peer (host: by spawn_extras, once all of a batched call are in;
## clients: from the host manifest, once its new extras are built).
signal extras_spawned(extras: Array[Player])

const PLAYER_SCENE: PackedScene = preload("res://player/player.tscn")
const NAME_TAG_PATH := "res://ui/round/name_tag.tscn"
## First slot of NPC extras (players are 0..7).
const EXTRA_SLOT_BASE := 100
## Most extras one stage holds (slots 100..355; the sync packs slot - 100 in one byte).
const MAX_EXTRAS := 256
## Default extra colours (muted, so they read as a crowd next to the players).
const EXTRA_PRIMARIES: Array[String] = ["#9aa5b1", "#b5a48c", "#8fa89b", "#a99bb5", "#b59a9a", "#9cb0c4", "#c2b78f", "#a3a3a3"]
## Extras a client builds per frame from a manifest that came over the network.
const CLIENT_EXTRA_BATCH := 4

## Lobby mode: spawn/remove players as `Net.roster` changes (host decides; clients follow the
## host's manifest). Set it before or after loading; the host resends the manifest.
## Players spawn frozen, as always: the lobby unfreezes them (listen to `players_spawned`).
@export var follow_roster: bool = false:
	set(value):
		if follow_roster == value:
			return
		follow_roster = value
		if is_inside_tree() and minigame and not _is_client():
			_on_roster_changed()
			_send_manifest()
## Give each spawned player a floating NameTag (never when headless).
@export var name_tags: bool = true
## Give extras a NameTag too (off by default; needs `name_tags`). Set it before spawn_extras.
@export var extra_name_tags: bool = false

## The loaded minigame, or null.
var minigame: Minigame = null
## slot -> Player, for the loaded minigame.
var players: Dictionary[int, Player] = {}
## Id of the current load as numbered by the host (same on every peer once a client has
## the host's manifest; -1 while unknown or nothing is loaded). Sync traffic is tagged with it.
var net_load_id: int = -1
## Player sync transport (child `SyncHub`).
var sync_hub: SyncHub = null
## NPC extras of the current load, in slot order (see spawn_extras).
var extras: Array[Player] = []

var _load_counter: int = 0
var _scene_path: String = ""
## slot -> spawn point index used for that player.
var _spawn_index: Dictionary[int, int] = {}

var _extra_slots: Dictionary[int, Player] = {}
## Spawn transform per extra slot (sent in the manifest).
var _extra_xforms: Dictionary[int, Transform3D] = {}
## Host, batched spawn_extras: extras still to build ([slot, name, loadout, xform]), how many
## per frame, and the ones built so far (emitted together when the queue is empty).
var _extra_queue: Array[Array] = []
var _extra_batch: int = 0
var _extra_built: Array[Player] = []
## Client: manifest extras still to build (entry dicts, slot order), and the ones built so far.
var _client_extra_queue: Array[Dictionary] = []
var _client_extra_built: Array[Player] = []

@onready var _players_root: Node3D = $Players
@onready var _extras_root: Node3D = $Extras


func _enter_tree() -> void:
	add_to_group(&"stage")
	if not Net.roster_changed.is_connected(_on_roster_changed):
		Net.roster_changed.connect(_on_roster_changed)
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)


func _exit_tree() -> void:
	if Net.roster_changed.is_connected(_on_roster_changed):
		Net.roster_changed.disconnect(_on_roster_changed)
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)


func _ready() -> void:
	sync_hub = SyncHub.new()
	sync_hub.name = "SyncHub"
	sync_hub.stage = self
	add_child(sync_hub)


## Frees the current minigame and players, loads minigame `id` (see MinigameRegistry)
## and spawns the players. Returns the minigame, or null if the id is unknown.
func load_minigame(id: StringName) -> Minigame:
	if not MinigameRegistry.has(id):
		push_error("Stage.load_minigame: unknown minigame '%s'" % id)
		return null
	return load_minigame_scene(load(MinigameRegistry.scene_path(id)) as PackedScene)


## Like load_minigame, from a scene whose root extends Minigame (dev arenas, tests).
func load_minigame_scene(scene: PackedScene) -> Minigame:
	_clear_local()
	if not _instance_scene(scene):
		return null
	if not _is_client():
		_load_counter += 1
		net_load_id = _load_counter
	spawn_players()
	_send_manifest()
	return minigame


## Spawns one frozen Player per roster entry (sorted by slot) at the minigame's spawn
## points, sets `minigame.players`, emits `players_spawned`. Whoever starts play unfreezes them.
## Spawn point: the i-th player gets point i (with `follow_roster`: point `slot`).
func spawn_players() -> Array[Player]:
	var spawned: Array[Player] = []
	var slots: Array[int] = []
	slots.assign(Net.roster.keys())
	slots.sort()
	for i in slots.size():
		var info: PlayerInfo = Net.roster[slots[i]]
		spawned.append(_spawn(info, info.slot if follow_roster else i))
	if minigame:
		minigame.players = spawned.duplicate()
	players_spawned.emit(spawned)
	return spawned


## The player in `slot`, or null.
func get_player(slot: int) -> Player:
	return players.get(slot) as Player


## Host (or offline) only: spawns `count` NPC extras, bot-driven `Player`s with `is_extra` and
## `is_bot` true, slots EXTRA_SLOT_BASE + n (continuing after the ones already there), nodes
## `Extras/X<slot>`, authority the host, NOT frozen. `loadouts[i]` / `spawn_xforms[i]` dress and
## place extra i (missing: a muted crowd colour / a spot on a sunflower spiral around the
## minigame's origin, facing it). Each brain starts in `wander` mode, seeded by slot and load
## (re-configure with `BotBrain.of(x).configure_extra(mode, seed)`). Clients get the same nodes
## from the host manifest. On a client this does nothing and returns [].
## `batch` 0 (default): all are built now and returned. `batch` > 0: `batch` per frame (the
## first batch now), returns []: listen to `extras_spawned` (once, with all of them, then the
## manifest goes out). Slots are fixed at the call; `flush_extras()` finishes a run at once.
func spawn_extras(count: int, loadouts: Array[Dictionary] = [], spawn_xforms: Array[Transform3D] = [], batch: int = 0) -> Array[Player]:
	var out: Array[Player] = []
	if _is_client():
		return out
	if minigame == null:
		push_warning("Stage.spawn_extras: no minigame loaded")
		return out
	var first := EXTRA_SLOT_BASE
	for p in extras:
		first = maxi(first, p.slot + 1)
	for q in _extra_queue:
		first = maxi(first, int(q[0]) + 1)
	count = mini(count, EXTRA_SLOT_BASE + MAX_EXTRAS - first)
	for i in count:
		var slot := first + i
		var loadout: Dictionary = loadouts[i] if i < loadouts.size() else default_extra_loadout(slot)
		var xform: Transform3D = spawn_xforms[i] if i < spawn_xforms.size() \
				else default_extra_xform(slot - EXTRA_SLOT_BASE, first - EXTRA_SLOT_BASE + count)
		var extra_name := "Extra %d" % (slot - EXTRA_SLOT_BASE + 1)
		if batch > 0:
			_extra_queue.append([slot, extra_name, loadout, xform])
		else:
			out.append(_host_spawn_extra(slot, extra_name, loadout, xform))
	if batch > 0:
		_extra_batch = batch
		_pump_extras()
		return []
	if not out.is_empty():
		extras_spawned.emit(out)
		_send_manifest()
	return out


## Host: builds every extra a batched spawn_extras still has queued, now (emits
## `extras_spawned` for the run, sends the manifest). Returns the run's extras ([] if none).
func flush_extras() -> Array[Player]:
	if _extra_queue.is_empty():
		return []
	_extra_batch = _extra_queue.size()
	return _pump_extras()


## True while a batched spawn_extras is still building (host) or manifest extras are still
## being built (client).
func is_spawning_extras() -> bool:
	return not _extra_queue.is_empty() or not _client_extra_queue.is_empty()


## Host (or offline) only: removes every extra, on every peer.
func despawn_extras() -> void:
	if _is_client():
		return
	var had := not extras.is_empty() or not _extra_queue.is_empty()
	_clear_extras()
	if had:
		_send_manifest()


## The extra in `slot`, or null.
func get_extra(slot: int) -> Player:
	return _extra_slots.get(slot) as Player


## The player or extra in `slot`, or null (sync, and anything handed a slot by an event).
func get_body(slot: int) -> Player:
	return get_extra(slot) if slot >= EXTRA_SLOT_BASE else get_player(slot)


## True for slots that belong to extras.
static func is_extra_slot(slot: int) -> bool:
	return slot >= EXTRA_SLOT_BASE


## Default look of extra `slot`: a muted colour, cream secondary, no items, normal size.
static func default_extra_loadout(slot: int) -> Dictionary:
	return {"primary": EXTRA_PRIMARIES[posmod(slot, EXTRA_PRIMARIES.size())], "secondary": "#efe6d2",
		"hat": "", "face": "", "neck": "", "back": "", "size": "normal"}


## Default spot of the `index`-th of `total` extras: a sunflower spiral 2.5..8 m around the
## minigame's origin, facing it.
func default_extra_xform(index: int, total: int) -> Transform3D:
	var center := minigame.global_position if minigame and minigame.is_inside_tree() else Vector3.ZERO
	var r := 2.5 + 5.5 * sqrt((index + 0.5) / maxf(total, 1.0))
	var a := index * 2.39996323  # golden angle
	var pos := center + Vector3(cos(a) * r, 0.0, sin(a) * r)
	var face := center - pos
	face.y = 0.0
	var basis := Basis.looking_at(face.normalized(), Vector3.UP, true) if face.length_squared() > 0.01 else Basis.IDENTITY
	return Transform3D(basis, pos)


## Frees the minigame and all players. On the host, every client clears too.
func clear() -> void:
	_clear_local()
	if _is_host_net():
		for id in SyncHub.live_peers(multiplayer):
			_rpc_clear.rpc_id(id)


# --- Spawning ----------------------------------------------------------------------------

func _instance_scene(scene: PackedScene) -> bool:
	minigame = scene.instantiate() as Minigame if scene else null
	if minigame == null:
		push_error("Stage.load_minigame_scene: scene root does not extend Minigame")
		return false
	_scene_path = scene.resource_path
	minigame.name = "Minigame"
	add_child(minigame)
	return true


func _spawn(info: PlayerInfo, point_index: int) -> Player:
	var p := PLAYER_SCENE.instantiate() as Player
	p.name = "P%d" % info.slot
	p.slot = info.slot
	p.display_name = info.name
	p.is_bot = info.is_bot
	p.loadout = info.loadout
	p.frozen = true
	p.set_multiplayer_authority(info.peer_id)
	_players_root.add_child(p)
	var points: Array[Transform3D] = minigame.get_spawn_points() if minigame else []
	if not points.is_empty():
		p.place_at(points[point_index % points.size()])
	players[info.slot] = p
	_spawn_index[info.slot] = point_index
	_attach_name_tag(p)
	return p


func _attach_name_tag(p: Player) -> void:
	if not name_tags or DisplayServer.get_name() == "headless" or not ResourceLoader.exists(NAME_TAG_PATH):
		return
	var scene := load(NAME_TAG_PATH) as PackedScene
	var tag := scene.instantiate() if scene else null
	if tag == null:
		return
	tag.name = "NameTag"
	if p.is_extra:
		tag.set(&"show_extras", true)  # opted in (extra_name_tags)
	p.add_child(tag)
	if tag.has_method(&"setup"):
		tag.call(&"setup", p)


func _spawn_extra(slot: int, extra_name: String, loadout: Dictionary, xform: Transform3D) -> Player:
	var p := PLAYER_SCENE.instantiate() as Player
	p.name = "X%d" % slot
	p.slot = slot
	p.display_name = extra_name
	p.is_bot = true
	p.is_extra = true
	p.loadout = loadout
	p.set_multiplayer_authority(SyncHub.HOST_PEER)
	_extras_root.add_child(p)
	p.place_at(xform)
	extras.append(p)
	_extra_slots[slot] = p
	_extra_xforms[slot] = xform
	if extra_name_tags:
		_attach_name_tag(p)
	return p


## Host: one extra with its default wander brain.
func _host_spawn_extra(slot: int, extra_name: String, loadout: Dictionary, xform: Transform3D) -> Player:
	var p := _spawn_extra(slot, extra_name, loadout, xform)
	var brain := BotBrain.of(p)
	if brain:
		brain.configure_extra(&"wander", slot * 7919 + maxi(net_load_id, 0))
	return p


func _process(_delta: float) -> void:
	if not _extra_queue.is_empty():
		_pump_extras()
	if not _client_extra_queue.is_empty():
		_pump_client_extras(CLIENT_EXTRA_BATCH)


## Host: builds the next `_extra_batch` queued extras. When the queue is empty: emits the
## run's extras, sends the manifest and returns them (else []).
func _pump_extras() -> Array[Player]:
	var n := mini(maxi(_extra_batch, 1), _extra_queue.size())
	for i in n:
		var q: Array = _extra_queue[i]
		_extra_built.append(_host_spawn_extra(q[0], q[1], q[2], q[3]))
	_extra_queue = _extra_queue.slice(n)
	if not _extra_queue.is_empty():
		return []
	var run := _extra_built
	_extra_built = []
	if not run.is_empty():
		extras_spawned.emit(run)
		_send_manifest()
	return run


## Client: builds the next `n` extras of the manifest queue; emits them all when it is empty.
func _pump_client_extras(n: int) -> void:
	n = mini(n, _client_extra_queue.size())
	for i in n:
		var e := _client_extra_queue[i]
		var slot: int = e["slot"]
		if get_extra(slot) == null:
			_client_extra_built.append(_spawn_extra_from_entry(slot, e))
	_client_extra_queue = _client_extra_queue.slice(n)
	if not _client_extra_queue.is_empty():
		return
	var run := _client_extra_built
	_client_extra_built = []
	if not run.is_empty():
		extras.sort_custom(func(a: Player, b: Player) -> bool: return a.slot < b.slot)
		extras_spawned.emit(run)


func _spawn_extra_from_entry(slot: int, e: Dictionary) -> Player:
	var loadout: Dictionary = e.get("loadout") if typeof(e.get("loadout")) == TYPE_DICTIONARY else {}
	var xform: Transform3D = e.get("xform") if typeof(e.get("xform")) == TYPE_TRANSFORM3D else Transform3D.IDENTITY
	return _spawn_extra(slot, str(e.get("name", "")), loadout, xform)


func _remove_extra(slot: int) -> void:
	var p: Player = _extra_slots.get(slot)
	_extra_slots.erase(slot)
	_extra_xforms.erase(slot)
	extras.erase(p)
	if is_instance_valid(p):
		if p.get_parent() == _extras_root:
			_extras_root.remove_child(p)
		p.queue_free()


func _clear_extras() -> void:
	_extra_queue.clear()
	_extra_built = []
	_client_extra_queue.clear()
	_client_extra_built = []
	for slot: int in _extra_slots.keys():
		_remove_extra(slot)
	extras.clear()


func _remove_player(slot: int) -> void:
	var p: Player = players.get(slot)
	players.erase(slot)
	_spawn_index.erase(slot)
	if not is_instance_valid(p):
		return
	if minigame:
		minigame.players.erase(p)
	if p.get_parent() == _players_root:
		_players_root.remove_child(p)
	p.queue_free()


func _clear_local() -> void:
	_clear_extras()
	for p: Player in players.values():
		if is_instance_valid(p):
			if p.get_parent() == _players_root:
				_players_root.remove_child(p)
			p.queue_free()
	players.clear()
	_spawn_index.clear()
	if minigame:
		remove_child(minigame)
		minigame.queue_free()
		minigame = null
	_scene_path = ""
	net_load_id = -1


# --- Roster changes (host / offline) -------------------------------------------------------

func _on_roster_changed() -> void:
	if not is_inside_tree() or minigame == null or _is_client():
		return
	var changed := false
	for slot: int in players.keys():
		if not players.has(slot):
			continue  # removed while knocking out another one
		var info: PlayerInfo = Net.roster.get(slot)
		var p: Player = players[slot]
		if info != null and is_instance_valid(p) and info.peer_id == p.get_multiplayer_authority():
			continue
		if not follow_roster and is_instance_valid(p) and not minigame.is_finished():
			minigame.knock_out(p)  # host decision: may finish the round
		_remove_player(slot)
		changed = true
	var added: Array[Player] = []
	if follow_roster and minigame:
		var slots: Array[int] = []
		slots.assign(Net.roster.keys())
		slots.sort()
		for slot in slots:
			var info: PlayerInfo = Net.roster[slot]
			var p: Player = players.get(slot)
			if p == null:
				var np := _spawn(info, slot)
				minigame.players.append(np)
				added.append(np)
			elif p.display_name != info.name or p.loadout != info.loadout:
				p.display_name = info.name
				p.loadout = info.loadout
				changed = true
	if not added.is_empty():
		players_spawned.emit(added)
	if changed or not added.is_empty():
		_send_manifest()


# --- Host -> clients ------------------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	if _is_host_net() and minigame and SyncHub.live_peers(multiplayer).has(peer_id):
		_rpc_manifest.rpc_id(peer_id, net_load_id, _scene_path, follow_roster, _manifest_entries(), _extra_entries())


func _send_manifest() -> void:
	if not _is_host_net() or minigame == null:
		return
	var peers := SyncHub.live_peers(multiplayer)  # never a peer that is disconnecting right now
	if peers.is_empty():
		return
	var entries := _manifest_entries()
	var extra_entries := _extra_entries()
	for id in peers:
		_rpc_manifest.rpc_id(id, net_load_id, _scene_path, follow_roster, entries, extra_entries)


func _manifest_entries() -> Array:
	var slots: Array[int] = []
	slots.assign(players.keys())
	slots.sort()
	var out: Array = []
	for slot in slots:
		var p: Player = players[slot]
		var d := PlayerInfo.new(slot, p.get_multiplayer_authority(), p.display_name, p.is_bot, p.loadout).to_dict()
		d["spawn"] = _spawn_index.get(slot, 0)
		out.append(d)
	return out


## Extras as the manifest carries them: `{slot, name, loadout, xform}` (xform: where it spawned;
## the sync moves it from there).
func _extra_entries() -> Array:
	var out: Array = []
	for p in extras:
		if is_instance_valid(p):
			out.append({"slot": p.slot, "name": p.display_name, "loadout": p.loadout,
				"xform": _extra_xforms.get(p.slot, p.global_transform)})
	return out


@rpc("authority", "call_remote", "reliable")
func _rpc_manifest(load_id: Variant, scene_path: Variant, follow: Variant, entries: Variant, extra_entries: Variant) -> void:
	apply_manifest(load_id, scene_path, follow, entries, extra_entries, CLIENT_EXTRA_BATCH)


@rpc("authority", "call_remote", "reliable")
func _rpc_clear() -> void:
	_clear_local()


## Client side of the manifest (public for tests): adopt the host's load `load_id` of
## `scene_path` with exactly the players in `entries` (PlayerInfo dicts plus "spawn") and,
## when `extra_entries` is an Array, exactly those extras (null: extras left as they are).
## `extra_batch` > 0: new extras are built that many per frame (removals and updates at once);
## the network path uses CLIENT_EXTRA_BATCH, 0 builds them all now.
func apply_manifest(load_id: Variant, scene_path: Variant, follow: Variant, entries: Variant, extra_entries: Variant = null, extra_batch: int = 0) -> void:
	if typeof(load_id) != TYPE_INT or typeof(scene_path) != TYPE_STRING or typeof(entries) != TYPE_ARRAY:
		return
	follow_roster = follow == true
	var wanted: Dictionary[int, Array] = {}  # slot -> [PlayerInfo, spawn index]
	for d: Variant in entries:
		var info := PlayerInfo.from_dict(d)
		if info == null or info.slot < 0 or info.slot >= Net.MAX_PLAYERS:
			continue
		wanted[info.slot] = [info, int((d as Dictionary).get("spawn", info.slot))]
	var same_load: bool = minigame != null and (net_load_id == load_id \
			or (net_load_id == -1 and _scene_path == scene_path))
	if not same_load:
		var path: String = scene_path
		if not path.begins_with("res://") or not ResourceLoader.exists(path):
			push_warning("Stage: host manifest names an unknown scene '%s'" % path)
			return
		_clear_local()
		if not _instance_scene(load(path) as PackedScene):
			return
	net_load_id = load_id
	for slot: int in players.keys():
		var keep: Array = wanted.get(slot, [])
		if keep.is_empty() or players[slot].get_multiplayer_authority() != (keep[0] as PlayerInfo).peer_id:
			_remove_player(slot)
	var slots: Array[int] = []
	slots.assign(wanted.keys())
	slots.sort()
	var added: Array[Player] = []
	for slot in slots:
		var info: PlayerInfo = wanted[slot][0]
		var p: Player = players.get(slot)
		if p == null:
			p = _spawn(info, wanted[slot][1])
			minigame.players.append(p)
			added.append(p)
		else:
			p.display_name = info.name
			p.loadout = info.loadout
	if not added.is_empty():
		players_spawned.emit(added)
	if typeof(extra_entries) == TYPE_ARRAY:
		_apply_extra_entries(extra_entries, extra_batch)


func _apply_extra_entries(extra_entries: Array, batch: int = 0) -> void:
	var wanted: Dictionary[int, Dictionary] = {}
	for d: Variant in extra_entries:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = d
		var slot: Variant = e.get("slot")
		if typeof(slot) != TYPE_INT or slot < EXTRA_SLOT_BASE or slot >= EXTRA_SLOT_BASE + MAX_EXTRAS:
			continue
		wanted[slot] = e
	for slot: int in _extra_slots.keys():
		if not wanted.has(slot):
			_remove_extra(slot)
	var slots: Array[int] = []
	slots.assign(wanted.keys())
	slots.sort()
	# The newest manifest decides what is still to build: queued entries are replaced.
	_client_extra_queue.clear()
	var still_built: Array[Player] = []
	for v: Variant in _client_extra_built:
		if is_instance_valid(v) and not (v as Node).is_queued_for_deletion():
			still_built.append(v as Player)
	_client_extra_built = still_built
	for slot in slots:
		var e := wanted[slot]
		var p := get_extra(slot)
		if p == null:
			_client_extra_queue.append(e)
		else:
			p.display_name = str(e.get("name", ""))
			p.loadout = e.get("loadout") if typeof(e.get("loadout")) == TYPE_DICTIONARY else {}
	# batch 0: all now; else the first batch now, the rest in _process.
	_pump_client_extras(_client_extra_queue.size() if batch <= 0 else batch)


# --- Helpers ---------------------------------------------------------------------------------

func _is_client() -> bool:
	return SyncHub.is_networked(multiplayer) and not multiplayer.is_server()


func _is_host_net() -> bool:
	return SyncHub.is_networked(multiplayer) and multiplayer.is_server()
