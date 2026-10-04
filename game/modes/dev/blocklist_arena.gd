extends Minigame
## Test fixture (test_modes.gd): the dev arena with a mutator blocklist that allows only
## low gravity, declared the way minigames do it.

var mutator_blocklist: Array[StringName] = [&"giant", &"tiny", &"turbo", &"slippery", &"super_shove", &"heavy", &"mirror"]
