class_name GameModes
extends RefCounted
## Round-order modes and the vote's pure logic (Session drives them). Owner: modes.
##
## SHUFFLE: every playable minigame, shuffled bags (no repeat until all were played).
## PLAYLIST: only the ticked ids, shuffled the same way, repeating as needed.
## VOTE: before each round three candidates (from the ticked ids) are shown; players vote with
## left/right + action; the most votes wins, ties at random. Bots vote at random.
## Every mode only draws minigames that fit the current player count (MinigameCatalog min/max).

enum Order { SHUFFLE, PLAYLIST, VOTE }
const ORDER_NAMES: Array[String] = ["Shuffle", "Playlist", "Vote"]
const ROUND_CHOICES: Array[int] = [4, 8, 12]
const VOTE_CANDIDATES := 3


## The ids a round may draw from: `ticked` (all playable when empty or in SHUFFLE) that fit
## `player_count`, in registry order. Falls back to every fitting playable id when that is empty,
## then to every playable id (a session never stalls). `from`: the playable ids (default: the
## registry; tests pass their own).
static func pool(order: int, ticked: Array, player_count: int, from: Array[StringName] = []) -> Array[StringName]:
	var all := from if not from.is_empty() else MinigameCatalog.playable()
	var src: Array[StringName] = []
	for id in all:
		if order == Order.SHUFFLE or ticked.is_empty() or ticked.has(id) or ticked.has(String(id)):
			src.append(id)
	var out := fitting(src, player_count)
	if out.is_empty():
		out = fitting(all, player_count)
	if out.is_empty():
		out = all
	return out


## `ids` that fit `player_count`.
static func fitting(ids: Array[StringName], player_count: int) -> Array[StringName]:
	var out: Array[StringName] = []
	for id in ids:
		if MinigameCatalog.fits(id, player_count):
			out.append(id)
	return out


## Up to `count` distinct candidates from `from`, random; `avoid` (last round's id) only when
## there are not enough others; ids in `played` (this session) are preferred less.
static func pick_candidates(from: Array[StringName], rng: RandomNumberGenerator, avoid: StringName = &"",
		played: Array = [], count: int = VOTE_CANDIDATES) -> Array[StringName]:
	var fresh: Array[StringName] = []
	var seen: Array[StringName] = []
	var last: Array[StringName] = []
	for id in from:
		if id == avoid:
			last.append(id)
		elif played.has(id):
			seen.append(id)
		else:
			fresh.append(id)
	var out: Array[StringName] = []
	for group: Array[StringName] in [fresh, seen, last]:
		var bag := group.duplicate()
		_shuffle(bag, rng)
		for id in bag:
			if out.size() < count:
				out.append(id)
	_shuffle(out, rng)
	return out


## Index of the winning candidate: most votes (`votes`: slot -> candidate index), ties at
## random; no votes at all: any candidate at random. -1 when there are no candidates.
static func tally(votes: Dictionary, candidate_count: int, rng: RandomNumberGenerator) -> int:
	if candidate_count <= 0:
		return -1
	var counts: Array[int] = []
	counts.resize(candidate_count)
	counts.fill(0)
	for s: Variant in votes:
		var i := int(votes[s])
		if i >= 0 and i < candidate_count:
			counts[i] += 1
	var best: int = counts.max()
	var top: Array[int] = []
	for i in candidate_count:
		if counts[i] == best:
			top.append(i)
	return top[rng.randi_range(0, top.size() - 1)]


## Vote counts per candidate (`votes`: slot -> index).
static func counts(votes: Dictionary, candidate_count: int) -> Array[int]:
	var out: Array[int] = []
	out.resize(maxi(candidate_count, 0))
	out.fill(0)
	for s: Variant in votes:
		var i := int(votes[s])
		if i >= 0 and i < candidate_count:
			out[i] += 1
	return out


## "8 rounds · Vote · Mutators: sometimes" (the clients' lobby line).
static func summary(rounds: int, order: int, mutator_mode: int, ticked_count: int = -1) -> String:
	var parts: Array[String] = ["%d rounds" % rounds, ORDER_NAMES[clampi(order, 0, 2)]]
	if order != Order.SHUFFLE and ticked_count >= 0:
		parts[1] += " (%d games)" % ticked_count
	parts.append("Mutators: %s" % Mutators.MODE_NAMES[clampi(mutator_mode, 0, 2)].to_lower())
	return " · ".join(parts)


static func _shuffle(a: Array, rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t
