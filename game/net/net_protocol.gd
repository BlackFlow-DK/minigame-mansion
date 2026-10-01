class_name NetProtocol
extends RefCounted
## Pure helpers behind the `Net` autoload: handshake, roster wire format, LAN beacons,
## address parsing. No state and no sockets, so everything here is unit-testable offline.
## Owner: net.
##
## Wire formats that must stay readable by every future version (so an old client can be
## told "version mismatch" instead of misbehaving): the handshake hello/reply and the LAN
## beacon are UTF-8 JSON objects. Bump VERSION on any change to RPCs or roster data.

## Protocol version exchanged in the handshake and advertised in beacons.
const VERSION := 2
const GAME_ID := "minigame-mansion"
const BEACON_MAGIC := "MMANSION-LAN"
const MAX_NAME_LENGTH := 16
const LOADOUT_KEYS: Array[String] = ["primary", "secondary", "hat", "face", "neck", "back", "size"]

const REASON_TIMEOUT := "timeout"
const REASON_FULL := "full"
const REASON_IN_PROGRESS := "in progress"
const REASON_VERSION := "version mismatch"
const REASON_CONNECT := "could not connect"


# --- Handshake -------------------------------------------------------------------------

## Client -> host, first thing after the transport connects.
static func make_hello(version: int, player_name: String, loadout: Dictionary) -> PackedByteArray:
	return JSON.stringify({"game": GAME_ID, "version": version, "name": player_name, "loadout": loadout}).to_utf8_buffer()


## Host -> client: empty `reason` means accepted.
static func make_reply(reason: String) -> PackedByteArray:
	return JSON.stringify({"game": GAME_ID, "ok": reason == "", "reason": reason}).to_utf8_buffer()


## Why the host must refuse `hello` ("" = accept). `occupied` counts roster entries plus
## accepted-but-not-yet-connected peers.
static func check_join(hello: Dictionary, occupied: int, max_players: int, refuse_in_progress: bool) -> String:
	if hello.get("game") != GAME_ID or not _is_number(hello.get("version")) or int(hello["version"]) != VERSION:
		return REASON_VERSION
	if refuse_in_progress:
		return REASON_IN_PROGRESS
	if occupied >= max_players:
		return REASON_FULL
	return ""


## Parses a UTF-8 JSON object; {} on anything else. Never prints errors.
static func parse_json_object(bytes: PackedByteArray) -> Dictionary:
	var json := JSON.new()
	if json.parse(bytes.get_string_from_utf8()) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data


# --- Roster -----------------------------------------------------------------------------

## Lowest slot in 0..max_players-1 not in `roster`, or -1.
static func free_slot(roster: Dictionary[int, PlayerInfo], max_players: int) -> int:
	for s in max_players:
		if not roster.has(s):
			return s
	return -1


static func roster_to_array(roster: Dictionary[int, PlayerInfo]) -> Array:
	var slots := roster.keys()
	slots.sort()
	var out: Array = []
	for s: int in slots:
		out.append(roster[s].to_dict())
	return out


## Replaces the contents of `roster` (kept as the same object) with `data`. Invalid entries are skipped.
static func fill_roster(roster: Dictionary[int, PlayerInfo], data: Variant, max_players: int) -> void:
	roster.clear()
	if typeof(data) != TYPE_ARRAY:
		return
	for d: Variant in data:
		var info := PlayerInfo.from_dict(d)
		if info and info.slot >= 0 and info.slot < max_players:
			roster[info.slot] = info


## A display name from untrusted input: trimmed, capped, `fallback` when empty.
static func sanitize_name(value: Variant, fallback: String) -> String:
	if typeof(value) != TYPE_STRING:
		return fallback
	var n := (value as String).strip_edges().strip_escapes().left(MAX_NAME_LENGTH)
	return n if n != "" else fallback


## A loadout from untrusted input: only the known keys, strings only, colours must be valid;
## anything missing or invalid comes from `fallback`.
static func sanitize_loadout(value: Variant, fallback: Dictionary) -> Dictionary:
	var src: Dictionary = value if typeof(value) == TYPE_DICTIONARY else {}
	var out: Dictionary = {}
	for key in LOADOUT_KEYS:
		var v: Variant = src.get(key)
		var ok := typeof(v) == TYPE_STRING and (v as String).length() <= 32
		if ok and (key == "primary" or key == "secondary"):
			ok = (v as String).begins_with("#") and Color.html_is_valid(v)
		out[key] = v if ok else fallback.get(key, "")
	return out


# --- LAN beacon -------------------------------------------------------------------------

## `info`: {id, game_name, host_name, players, max_players, in_lobby, port}.
static func make_beacon(info: Dictionary) -> PackedByteArray:
	var d := info.duplicate()
	d["magic"] = BEACON_MAGIC
	d["version"] = VERSION
	return JSON.stringify(d).to_utf8_buffer()


## Parses a beacon; {} when it is not one of ours. Numbers come back as ints.
static func parse_beacon(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() > 2048:
		return {}
	var d := parse_json_object(bytes)
	if d.get("magic") != BEACON_MAGIC or typeof(d.get("id")) != TYPE_STRING:
		return {}
	for key: String in ["players", "max_players", "port", "version"]:
		if not _is_number(d.get(key)):
			return {}
	var port := int(d["port"])
	if port <= 0 or port > 65535:
		return {}
	return {
		"id": d["id"],
		"game_name": str(d.get("game_name", "")),
		"host_name": str(d.get("host_name", "")),
		"players": int(d["players"]),
		"max_players": int(d["max_players"]),
		"in_lobby": d.get("in_lobby", false) == true,
		"version": int(d["version"]),
		"compatible": int(d["version"]) == VERSION,
		"port": port,
	}


## Where a host sends its beacon: limited broadcast, loopback (same-PC listeners) and the
## /24 directed broadcast of each private IPv4 address (Windows sends 255.255.255.255 out of
## one adapter only). `local_addresses`: from IP.get_local_addresses().
static func beacon_targets(local_addresses: PackedStringArray) -> Array[String]:
	var out: Array[String] = ["255.255.255.255", "127.0.0.1"]
	for a in local_addresses:
		if not a.is_valid_ip_address() or a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		var parts := a.split(".")
		var target := "%s.%s.%s.255" % [parts[0], parts[1], parts[2]]
		if not out.has(target):
			out.append(target)
	return out


# --- Addresses --------------------------------------------------------------------------

## "host", "host:port" -> [host: String, port: int]; host "" when unusable.
static func split_address(address: String, default_port: int) -> Array:
	var a := address.strip_edges()
	var port := default_port
	if a.count(":") == 1:
		var p := a.get_slice(":", 1)
		a = a.get_slice(":", 0)
		if not p.is_valid_int() or int(p) <= 0 or int(p) > 65535:
			return ["", default_port]
		port = int(p)
	return [a, port]


static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT
