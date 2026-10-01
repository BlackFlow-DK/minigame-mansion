extends RefCounted
## The cosmetic catalog and colour palettes: data only, read by the `Cosmetics` autoload.
## Owner: cosmetics system.
##
## Every item: `id` (unique within its slot), `slot` (hat, face, neck, back), `name` (shown in
## the wardrobe) and its fit on the real blob relative to the socket it hangs from:
## `offset` (metres), `rotation` (degrees, XYZ Euler) and `scale` (Vector3). Optional flags:
## `spin_child` (name of a child node that spins around its own Y) with `spin_speed` (rad/s).
## The model is `res://assets/models/cosmetics/<slot>_<id>.glb` unless `model` is given.
## Fit values were tuned by eye on the real blob with `game/cosmetics/dev/fit_check.tscn`.

const SLOTS: Array[StringName] = [&"hat", &"face", &"neck", &"back"]

## Socket node per slot (in blob.glb) and its contract position (fallback if the node is missing).
const SOCKETS: Dictionary = {
	&"hat": [&"HatSocket", Vector3(0.0, 1.0, 0.0)],
	&"face": [&"FaceSocket", Vector3(0.0, 0.68, 0.37)],
	&"neck": [&"NeckSocket", Vector3(0.0, 0.40, 0.0)],
	&"back": [&"BackSocket", Vector3(0.0, 0.50, -0.37)],
}

const ITEMS: Array[Dictionary] = [
	# --- hats (HatSocket, top of the dome at y = 1.0) -------------------------------------
	{"id": "top_hat", "slot": "hat", "name": "Top Hat", "offset": Vector3(0.0, -0.015, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "party_cone", "slot": "hat", "name": "Party Cone", "offset": Vector3(0.066, -0.006, 0.0), "rotation": Vector3(0.0, 0.0, -10.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "crown", "slot": "hat", "name": "Crown", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "wizard", "slot": "hat", "name": "Wizard Hat", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "cowboy", "slot": "hat", "name": "Cowboy Hat", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "chef", "slot": "hat", "name": "Chef Hat", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "propeller_cap", "slot": "hat", "name": "Propeller Cap", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0), "spin_child": "Spin", "spin_speed": 9.0},
	{"id": "pirate", "slot": "hat", "name": "Pirate Hat", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "viking", "slot": "hat", "name": "Viking Helmet", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "flower_pot", "slot": "hat", "name": "Flower Pot", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "traffic_cone", "slot": "hat", "name": "Traffic Cone", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "cat_ears", "slot": "hat", "name": "Cat Ears", "offset": Vector3(0.0, -0.01, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	# --- face (FaceSocket, between the eyes on the surface at (0, 0.68, 0.37)) ------------
	{"id": "round_glasses", "slot": "face", "name": "Round Glasses", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "star_shades", "slot": "face", "name": "Star Shades", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "monocle", "slot": "face", "name": "Monocle", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "moustache", "slot": "face", "name": "Moustache", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "clown_nose", "slot": "face", "name": "Clown Nose", "offset": Vector3(0.0, -0.04, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "eye_patch", "slot": "face", "name": "Eye Patch", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	# --- neck (NeckSocket, body centre at y = 0.40 where the body radius is 0.40) ---------
	{"id": "scarf", "slot": "neck", "name": "Scarf", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(0.95, 1.0, 0.95)},
	{"id": "bow_tie", "slot": "neck", "name": "Bow Tie", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "gold_chain", "slot": "neck", "name": "Gold Chain", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "flower_lei", "slot": "neck", "name": "Flower Lei", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(8.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "bandana", "slot": "neck", "name": "Bandana", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	# --- back (BackSocket, body surface at (0, 0.50, -0.37)) -------------------------------
	{"id": "cape", "slot": "back", "name": "Cape", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "backpack", "slot": "back", "name": "Backpack", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "angel_wings", "slot": "back", "name": "Angel Wings", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "jetpack", "slot": "back", "name": "Jetpack", "offset": Vector3(0.0, 0.0, 0.045), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
	{"id": "turtle_shell", "slot": "back", "name": "Turtle Shell", "offset": Vector3(0.0, 0.0, 0.0), "rotation": Vector3(0.0, 0.0, 0.0), "scale": Vector3(1.0, 1.0, 1.0)},
]

## Body colours (PlayerPrimary: body, lids, lips). The first eight are the most distinct and are
## the default colours of slots 0..7; the rest are extra choices for the wardrobe.
const PRIMARY: Array[String] = [
	"#e0303a", # 0 red
	"#2f7fe0", # 1 blue
	"#3cb44b", # 2 green
	"#ffe03a", # 3 yellow
	"#9b5de5", # 4 purple
	"#ff7a1a", # 5 orange
	"#1cc7c1", # 6 teal
	"#ff6fb5", # 7 pink
	"#f2eee6", # 8 cream white
	"#3b3f4c", # 9 charcoal
	"#a6d92f", # 10 lime
	"#7ec8ff", # 11 sky
	"#b5227f", # 12 magenta
	"#8d5a3b", # 13 cocoa
	"#26306b", # 14 navy
	"#8fe3b0", # 15 mint
]

## Accent colours (PlayerSecondary: belly, hands, feet).
const SECONDARY: Array[String] = [
	"#ffffff", # 0 white
	"#fff1c1", # 1 cream
	"#ffd0e0", # 2 blush
	"#cde8ff", # 3 ice
	"#d8f5c8", # 4 pale mint
	"#e6d6ff", # 5 lavender
	"#ffdcbc", # 6 apricot
	"#ffd23f", # 7 gold
	"#ff5d73", # 8 coral
	"#9aa0a6", # 9 grey
	"#2b2d42", # 10 ink
	"#7a4a2a", # 11 brown
]

## Body sizes (loadout key `size`), in wardrobe order; free for everyone. `scale` sizes the whole
## blob (model, worn items, collision capsule, name tag). The other numbers multiply component
## tuning on top of whatever the minigame set (the `size` player component applies them):
## `speed` movement.max_speed, `jump` jump.jump_height, `reach` shove.reach and shove.width;
## `shove` (pushes you give) and `knockback` (pushes you take) are in felt slide distance: the
## component applies their square root to shove.force / status.knockback_multiplier.
## Starting point: docs/superpowers/specs/2026-09-30-night-features-design.md section 3;
## tuned with game/tests/test_size_balance.gd (multipliers only; 96 mixed bot rounds, gate:
## win-rate spread <= 8 points, every size wins in both minigames). Shove/knockback pairs tried
## (small / big): 0.90-1.10 / 1.10-0.92 spread 13.5; 0.92-1.08 / 1.08-0.93 15.1;
## 0.90-1.06 / 1.10-0.95 17.7; 0.95-1.06 / 1.06-0.95 7.3; 0.94-1.07 / 1.07-0.94 4.7 (chosen:
## small 14.1 / normal 17.2 / big 18.8 % wins).
const SIZES: Array[Dictionary] = [
	{"id": "small", "name": "Small", "blurb": "Fast and bouncy, but shoves softer and flies further.",
		"scale": 0.82, "speed": 1.15, "jump": 1.08, "shove": 0.94, "reach": 0.97, "knockback": 1.07},
	{"id": "normal", "name": "Normal", "blurb": "The classic blob: good at everything.",
		"scale": 1.0, "speed": 1.0, "jump": 1.0, "shove": 1.0, "reach": 1.0, "knockback": 1.0},
	{"id": "big", "name": "Big", "blurb": "Shoves harder and is hard to budge, but slow and heavy.",
		"scale": 1.22, "speed": 0.88, "jump": 0.94, "shove": 1.07, "reach": 1.04, "knockback": 0.94},
]
const DEFAULT_SIZE := "normal"


## The SIZES entry for `id`; the normal entry for anything else.
static func size_entry(id: Variant) -> Dictionary:
	for entry: Dictionary in SIZES:
		if entry["id"] == id:
			return entry
	return SIZES[1]


## Per roster slot 0..7: [primary index, secondary index, hat id].
const DEFAULTS: Array[Array] = [
	[0, 1, "party_cone"],
	[1, 3, "wizard"],
	[2, 7, "propeller_cap"],
	[3, 11, "pirate"],
	[4, 5, "crown"],
	[5, 10, "cowboy"],
	[6, 0, "viking"],
	[7, 2, "top_hat"],
]
