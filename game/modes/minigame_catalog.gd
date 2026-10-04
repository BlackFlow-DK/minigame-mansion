class_name MinigameCatalog
extends RefCounted
## What the menus and the vote need to know about a minigame without loading its scene:
## display name, kind tag, player range, one-line rule, icon colour. Owner: modes.
## Ids missing here (a new minigame not added yet) still work: `info()` falls back to the id
## ("my_game" -> "My Game", kind "party", 2-8 players, a colour from the id's hash).
## Playable ids come from `MinigameRegistry.IDS`; entries for ids not in the registry yet
## (in progress / planned) are only data.

const KIND_NAMES := {
	&"brawl": "Brawl", &"race": "Race", &"team": "Team", &"hidden": "Hidden", &"hazard": "Hazard",
	&"score": "Score", &"keepaway": "Keep-away", &"tag": "Tag", &"memory": "Memory",
	&"throwing": "Throwing", &"climb": "Climb", &"party": "Party",
}

const ENTRIES := {
	&"floor_is_lava": {"name": "Floor Is Lava", "kind": &"hazard", "min": 2, "max": 8, "color": "#d9483b",
		"rule": "Tiles crumble under your feet. Keep moving, shove, be the last one up!"},
	&"bumper_sumo": {"name": "Bumper Sumo", "kind": &"brawl", "min": 2, "max": 8, "color": "#e8b33a",
		"rule": "Shove everyone off the shrinking ring!"},
	&"hot_potato": {"name": "Hot Potato", "kind": &"keepaway", "min": 2, "max": 8, "color": "#e67e22",
		"rule": "Touch someone to pass the bomb before it blows!"},
	&"coin_scramble": {"name": "Coin Scramble", "kind": &"score", "min": 2, "max": 8, "color": "#f2c94c",
		"rule": "Grab the most coins. Get shoved and you drop some!"},
	&"cannon_alley": {"name": "Cannon Alley", "kind": &"hazard", "min": 2, "max": 8, "color": "#5e5263",
		"rule": "Dodge the cannonballs, jump the slow ones. Two hits and you're out!"},
	&"paint_splat": {"name": "Paint Splat", "kind": &"score", "min": 2, "max": 8, "color": "#cc79a7",
		"rule": "Run over tiles to paint them. Most tiles wins; shove to steal!"},
	&"spotlight_chairs": {"name": "Spotlight Chairs", "kind": &"party", "min": 2, "max": 8, "color": "#b388eb",
		"rule": "When the music stops, stand on a pad! One blob per pad."},
	&"crown_keeper": {"name": "Crown Keeper", "kind": &"keepaway", "min": 2, "max": 8, "color": "#f5d76e",
		"rule": "Wear the crown to score. Shove the wearer to knock it off!"},
	&"mansion_dash": {"name": "Mansion Dash", "kind": &"race", "min": 2, "max": 8, "color": "#56b4e9",
		"rule": "Race through the garden course! Fall in the pond and it's back to the last flag."},
	&"blob_ball": {"name": "Blob Ball", "kind": &"team", "min": 2, "max": 8, "color": "#e69f00",
		"rule": "Shove the big ball into the other team's goal! First to 3."},
	&"statue_garden": {"name": "Statue Garden", "kind": &"race", "min": 2, "max": 8, "color": "#a3b18a",
		"rule": "Move while the butler looks away. Freeze when he stares! First to touch him wins."},
	&"masquerade": {"name": "Masquerade", "kind": &"hidden", "min": 2, "max": 8, "color": "#9b59b6",
		"rule": "Everyone wears the same mask. Shove the real players, never the dancers!"},
	&"hide_and_sneak": {"name": "Hide and Sneak", "kind": &"hidden", "min": 3, "max": 8, "color": "#8d6e63",
		"rule": "Hiders: be furniture and keep still! Seekers: poke what isn't furniture."},
	&"ghost_tag": {"name": "Ghost Tag", "kind": &"tag", "min": 2, "max": 8, "color": "#b8e0f6",
		"rule": "One ghost. A touch turns you into a ghost too. Stay alive!"},
	&"portrait_panic": {"name": "Portrait Panic", "kind": &"memory", "min": 2, "max": 8, "color": "#2fa7a0",
		"rule": "Stand on the tile that matches the portrait before the rest drop!"},
	&"snowball_fight": {"name": "Snowball Fight", "kind": &"throwing", "min": 2, "max": 8, "color": "#e8f1f8",
		"rule": "Press to scoop snow, press again to throw. Three hits and you're snowed in!"},
	&"rising_tide": {"name": "Rising Tide", "kind": &"climb", "min": 2, "max": 8, "color": "#009e73",
		"rule": "The water is rising! Climb high and shove climbers off."},
}


## Everything about `id`: {id, name, kind, kind_name, min, max, rule, color: Color, known: bool}.
static func info(id: StringName) -> Dictionary:
	var e: Dictionary = ENTRIES.get(id, {})
	var kind: StringName = e.get("kind", &"party")
	return {
		"id": id,
		"name": str(e.get("name", String(id).capitalize())),
		"kind": kind,
		"kind_name": str(KIND_NAMES.get(kind, String(kind).capitalize())),
		"min": int(e.get("min", 2)),
		"max": int(e.get("max", 8)),
		"rule": str(e.get("rule", "")),
		"color": Color.from_string(str(e.get("color", "")), fallback_color(id)),
		"known": not e.is_empty(),
	}


static func display_name(id: StringName) -> String:
	return info(id)["name"]


static func min_players(id: StringName) -> int:
	return info(id)["min"]


static func max_players(id: StringName) -> int:
	return info(id)["max"]


## True when a round of `id` works with `player_count` players.
static func fits(id: StringName, player_count: int) -> bool:
	var i := info(id)
	return player_count >= int(i["min"]) and player_count <= int(i["max"])


## The playable ids (MinigameRegistry.IDS, in order).
static func playable() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(MinigameRegistry.IDS)
	return out


## A stable, pleasant colour for an id without an entry.
static func fallback_color(id: StringName) -> Color:
	var h := float(hash(String(id)) & 0xffff) / 65535.0
	return Color.from_hsv(h, 0.45, 0.85)
