extends GameTest
## Framework hooks for minigames (docs/contract.md "Minigame hooks"): cosmetics look override,
## size override, name tag / blob shadow hiding, fx colours that follow a disguise, the status
## stun, batched extras, and the bot brain's hold.

const NAME_TAG_SCENE: PackedScene = preload("res://ui/round/name_tag.tscn")
const LOOK := {"primary": "#ece2cf", "secondary": "#b7a3d9", "hat": "", "face": "", "neck": "", "back": "",
	"size": "normal"}

var _extra_stages: Array[Node] = []


func after_each() -> void:
	for n in _extra_stages:
		if is_instance_valid(n):
			(n as Stage).clear()
			n.get_parent().remove_child(n)
			n.queue_free()
	_extra_stages.clear()


func _model(p: Player) -> Node3D:
	return (p.get_component(&"cosmetics") as CosmeticsComponent).get_model_root()


func _key(look: Dictionary) -> Array:
	return MasqDisguise.colour_key(look)


func _with_size(p: Player, size: String) -> void:
	var l := p.loadout.duplicate(true)
	l["size"] = size
	p.loadout = l


# --- 1. Look override ---------------------------------------------------------------------------

func test_look_override_is_visual_and_clears_back() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var real := p.loadout.duplicate(true)
	var cosmetics := p.get_component(&"cosmetics") as CosmeticsComponent
	await step(1)
	assert_eq(_model(p).get_meta(&"cosmetic_colours", []), _key(real), "real colours first")
	cosmetics.set_look_override(LOOK)
	assert_eq(_model(p).get_meta(&"cosmetic_colours", []), _key(LOOK), "override shown at once")
	await step(3)
	assert_eq(_model(p).get_meta(&"cosmetic_colours", []), _key(LOOK), "and kept")
	assert_eq(p.loadout, real, "player.loadout untouched")
	assert_eq((Net.roster[p.slot] as PlayerInfo).loadout, real, "roster untouched")
	assert_eq(cosmetics.shown_look(), LOOK, "shown_look is the override")
	for slot: StringName in [&"hat", &"face", &"neck", &"back"]:
		assert_true(Cosmetics.get_item_node(_model(p), slot) == null, "no %s under the override" % slot)
	# A loadout change while overridden does not break through.
	var recoloured := real.duplicate()
	recoloured["primary"] = "#123456"
	p.loadout = recoloured
	await step(2)
	assert_eq(_model(p).get_meta(&"cosmetic_colours", []), _key(LOOK), "override wins over a loadout change")
	cosmetics.clear_look_override()
	assert_false(cosmetics.has_look_override(), "cleared")
	assert_eq(_model(p).get_meta(&"cosmetic_colours", []), _key(recoloured), "real loadout back")


# --- 2. Size override ---------------------------------------------------------------------------

func test_size_override_forces_looks_capsule_and_stats() -> void:
	var ps := spawn_arena(2)
	var big := ps[0]
	var normal := ps[1]
	_with_size(big, "big")
	await step(30)
	var size := big.get_component(&"size") as SizeComponent
	var shape := (big.get_node(^"CollisionShape3D") as CollisionShape3D)
	assert_eq(size.size_id, "big", "big from the loadout")
	assert_true((shape.shape as CapsuleShape3D).radius > 0.45, "big capsule")
	var big_speed := (big.get_component(&"movement") as MovementComponent).max_speed
	size.set_size_override("normal", true)
	assert_eq(size.size_id, "normal", "override in effect")
	assert_near((big.get_component(&"visuals") as Node3D).scale.x, 1.0, 0.001, "snapped to normal scale")
	await step(2)
	var capsule := shape.shape as CapsuleShape3D
	assert_near(capsule.radius, 0.4, 0.001, "normal capsule radius")
	assert_near(capsule.height, 1.0, 0.001, "normal capsule height")
	assert_near(shape.position.y, 0.5, 0.001, "normal capsule centre")
	for stat: Array in SizeComponent.STATS:
		assert_near(float(big.get_component(stat[0]).get(stat[1])), float(normal.get_component(stat[0]).get(stat[1])), 0.001,
			"%s.%s like a normal blob" % [stat[0], stat[1]])
	assert_eq(big.loadout["size"], "big", "loadout untouched")
	size.clear_size_override(true)
	await step(2)
	assert_eq(size.size_id, "big", "cleared: big again")
	assert_true((shape.shape as CapsuleShape3D).radius > 0.45, "big capsule again")
	assert_near((big.get_component(&"movement") as MovementComponent).max_speed, big_speed, 0.001, "big speed again")
	assert_true((big.get_component(&"visuals") as Node3D).scale.x > 1.1, "big scale again")


func test_size_override_keeps_a_minigame_base() -> void:
	var ps := spawn_arena(1)
	var p := ps[0]
	_with_size(p, "small")
	await step(2)
	var size := p.get_component(&"size") as SizeComponent
	var move := p.get_component(&"movement") as MovementComponent
	move.max_speed = 3.0  # a minigame's absolute value
	await step(1)
	assert_near(size.base_of(&"movement", &"max_speed"), 3.0, 0.001, "base taken")
	size.set_size_override("normal")
	await step(1)
	assert_near(move.max_speed, 3.0, 0.001, "normal override: the base itself")
	size.set_size_override("big")
	await step(1)
	assert_near(move.max_speed, 3.0 * size.factor("speed"), 0.001, "big override: base * big factor")


# --- 3. Name tag and shadow ---------------------------------------------------------------------

func test_name_tag_suppressed_and_presentation_hidden() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var tag := NAME_TAG_SCENE.instantiate() as NameTag
	tag.name = "SomeOtherName"  # found by class, not by node name
	p.add_child(tag)
	tag.setup(p)
	await step(2)
	assert_eq(NameTag.of(p), tag, "NameTag.of finds it")
	assert_true(NameTag.of(ps[1]) == null, "none on the other")
	assert_true(tag.visible, "visible at first")
	FxComponent.set_presentation_hidden(p, true)
	assert_true(tag.suppressed and not tag.visible, "hidden at once")
	var fx := p.get_component(&"fx") as FxComponent
	assert_true(fx.shadow_hidden, "shadow hidden too")
	await step(3)
	assert_false(tag.visible, "stays hidden")
	FxComponent.set_presentation_hidden(p, false, true, false)
	assert_true(tag.visible and not tag.suppressed, "tag back")
	assert_true(fx.shadow_hidden, "shadow untouched when not asked")
	fx.shadow_hidden = false
	p.eliminate(&"test")
	await step(1)
	tag.suppressed = true
	tag.suppressed = false
	assert_false(tag.visible, "an eliminated player's tag stays hidden after clearing")


# --- 4. Fx colour follows the disguise ----------------------------------------------------------

func test_fx_colours_follow_the_look_override() -> void:
	var ps := spawn_arena(2)
	var p := ps[0]
	var looks: Array[Dictionary] = [LOOK.duplicate()]
	var at: Array[Transform3D] = [Transform3D(Basis.IDENTITY, Vector3(6, 0, 6))]
	var x := stage.spawn_extras(1, looks, at)[0]
	var fx := p.get_component(&"fx") as FxComponent
	var real := Look.parse_color(p.loadout["primary"], Color.WHITE)
	assert_eq(fx.primary_color(), real, "true colour without an override")
	(p.get_component(&"cosmetics") as CosmeticsComponent).set_look_override(LOOK)
	var played := watch(Fx, &"played")
	p.emit_event(&"shove_started")
	x.emit_event(&"shove_started")  # an NPC's fake shove: the plain public event
	var whooshes: Array[Color] = []
	for e: Array in played:
		if e[0] == &"shove_whoosh":
			whooshes.append(e[2])
	if assert_eq(whooshes.size(), 2, "two whooshes"):
		assert_eq(whooshes[0], whooshes[1], "disguised player's whoosh == the extra's, exactly")
		assert_true(whooshes[0] != real, "not the true colour")
	# Stars on a victim of the disguised player use the disguise colour too.
	played.clear()
	ps[1].emit_event(&"got_hit", [Vector3(3, 0, 0), p.slot])
	var stars: Array = played.filter(func(e: Array) -> bool: return e[0] == &"hit_stars")
	if assert_eq(stars.size(), 1, "hit stars"):
		assert_eq(stars[0][2], fx.slot_color(x.slot), "stars caused by the disguised player = an extra's")
	(p.get_component(&"cosmetics") as CosmeticsComponent).clear_look_override()
	assert_eq(fx.primary_color(), real, "true colour after clearing")


# --- 5. Stun ------------------------------------------------------------------------------------

func test_stun_locks_for_its_own_length_and_raises_stunned_once() -> void:
	var ps := spawn_arena(1)
	var p := ps[0]
	var status := p.get_component(&"status") as StatusComponent
	var stuns := watch(p, &"stunned")
	var hits := watch(p, &"got_hit")
	status.stun(1.5)
	p.apply_impulse(Vector3(4, 2, 0))  # its own shorter stun is absorbed
	assert_true(p.control_locked, "locked")
	assert_eq(stuns.size(), 1, "stunned once")
	assert_near(float(stuns[0][0]), 1.5, 0.001, "with the given length")
	assert_eq(hits.size(), 1, "the knock still lands")
	assert_near(status.stun_max, 0.6, 0.001, "no tuning touched")
	status.stun(0.5)
	assert_eq(stuns.size(), 1, "a shorter stun does not shorten it")
	await step(int(1.4 / physics_delta()))
	assert_true(p.control_locked, "still locked at 1.4 s")
	await step(int(0.15 / physics_delta()))
	assert_false(p.control_locked, "free after 1.5 s")
	status.invulnerable = true
	status.stun(1.0)
	assert_false(p.control_locked, "invulnerable: ignored")
	status.invulnerable = false
	p.frozen = true
	status.stun(1.0)
	assert_false(p.control_locked, "frozen: ignored")


# --- 6. Batched extras --------------------------------------------------------------------------

func test_batched_extras_spread_over_frames_and_emit_once() -> void:
	spawn_arena(2)
	var got := watch(stage, &"extras_spawned")
	var out := stage.spawn_extras(10, [], [], 4)
	assert_eq(out.size(), 0, "batched: returns []")
	assert_eq(stage.extras.size(), 4, "first batch now")
	assert_true(stage.is_spawning_extras(), "still spawning")
	assert_eq(got.size(), 0, "not emitted yet")
	var counts: Array[int] = [stage.extras.size()]
	await step(4, func(_i: int) -> void: counts.append(stage.extras.size()))
	counts.append(stage.extras.size())
	for i in range(1, counts.size()):
		assert_true(counts[i] - counts[i - 1] <= 4, "at most 4 per frame: %s" % [counts])
	assert_eq(stage.extras.size(), 10, "all in")
	assert_false(stage.is_spawning_extras(), "done")
	if assert_eq(got.size(), 1, "extras_spawned once"):
		assert_eq((got[0][0] as Array).size(), 10, "with all ten")
	var names: Array[String] = []
	for x in stage.extras:
		names.append(String(x.name))
	assert_eq(names[0], "X100", "slots in order")
	assert_eq(names[9], "X109", "slots in order")
	# flush_extras finishes a run at once; slots continue after queued ones.
	stage.spawn_extras(6, [], [], 2)
	var flushed := stage.flush_extras()
	assert_eq(flushed.size(), 6, "flush returns the run")
	assert_eq(stage.extras.size(), 16, "all built")
	assert_eq(got.size(), 2, "one emit per run")
	# Despawn mid-run drops the queue.
	stage.spawn_extras(8, [], [], 2)
	stage.despawn_extras()
	await step(3)
	assert_eq(stage.extras.size(), 0, "despawned, nothing more built")


func test_client_builds_manifest_extras_in_batches() -> void:
	spawn_arena(2)
	stage.spawn_extras(10)
	var client := STAGE_SCENE.instantiate() as Stage
	client.name = "ClientStage"
	add_child(client)
	_extra_stages.append(client)
	var got := watch(client, &"extras_spawned")
	client.apply_manifest(stage.net_load_id, DEV_ARENA_PATH, false, stage._manifest_entries(), stage._extra_entries(), 4)
	assert_eq(client.extras.size(), 4, "first batch at once")
	assert_eq(got.size(), 0, "not emitted yet")
	var counts: Array[int] = [client.extras.size()]
	await step(4, func(_i: int) -> void: counts.append(client.extras.size()))
	counts.append(client.extras.size())
	for i in range(1, counts.size()):
		assert_true(counts[i] - counts[i - 1] <= 4, "at most 4 per frame: %s" % [counts])
	assert_eq(client.extras.size(), 10, "the rest over the next frames")
	if assert_eq(got.size(), 1, "extras_spawned once"):
		assert_eq((got[0][0] as Array).size(), 10, "with all ten")
	assert_eq(client.extras[9].slot, 109, "slot order")
	# A newer manifest while building replaces what is still to build.
	var fresh := STAGE_SCENE.instantiate() as Stage
	fresh.name = "ClientStage2"
	add_child(fresh)
	_extra_stages.append(fresh)
	fresh.apply_manifest(stage.net_load_id, DEV_ARENA_PATH, false, stage._manifest_entries(), stage._extra_entries(), 4)
	fresh.apply_manifest(stage.net_load_id, DEV_ARENA_PATH, false, stage._manifest_entries(), stage._extra_entries().slice(0, 6), 4)
	await step(3)
	assert_eq(fresh.extras.size(), 6, "only what the newest manifest lists")


# --- 7. Bot hold --------------------------------------------------------------------------------

func _holder() -> Minigame:
	var script := GDScript.new()
	script.source_code = """extends Minigame
var hold := true
func bot_should_hold(_p: Player) -> bool:
	return hold
func get_bot_goal(p: Player) -> Vector3:
	return p.global_position + Vector3(3.0, 0.0, 0.0)
"""
	script.reload()
	return script.new() as Minigame  # never in the tree: the brain only calls its methods


func test_held_brains_fill_an_empty_intent() -> void:
	var ps := spawn_arena(3)
	var holder := _holder()
	var bot := ps[1]
	# Crowd it: personal space, a wall of blobs, would make a free bot move.
	bot.place_at(Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)))
	ps[2].place_at(Transform3D(Basis.IDENTITY, Vector3(0.5, 0, 0)))
	ps[0].place_at(Transform3D(Basis.IDENTITY, Vector3(-0.6, 0, 0.3)))
	var brain := BotBrain.new()
	brain.player = bot
	brain.minigame = holder
	add_child(brain)
	brain.configure(7, 0.9, 1.0)
	assert_true(brain.reaction_time() > 0.0, "a reaction time is exposed")
	var busy := [0]
	await step(120, func(_i: int) -> void:
		brain.fill_intent(bot.intent, physics_delta())
		if bot.intent.move != Vector2.ZERO or bot.intent.jump_pressed or bot.intent.jump_held or bot.intent.action_pressed:
			busy[0] += 1)
	assert_eq(busy[0], 0, "held: no move, jump or action for 2 s")
	assert_true(brain.is_held(), "is_held")
	# Extras' modes are held too.
	brain.configure_extra(&"dance", 3, Vector3(2, 0, 2))
	await step(30, func(_i: int) -> void:
		brain.fill_intent(bot.intent, physics_delta())
		if bot.intent.move != Vector2.ZERO:
			busy[0] += 1)
	assert_eq(busy[0], 0, "a held dancer stands still")
	holder.set(&"hold", false)
	brain.configure(7, 0.9, 1.0)
	var moved := [0]
	await step(90, func(_i: int) -> void:
		brain.fill_intent(bot.intent, physics_delta())
		if bot.intent.move != Vector2.ZERO:
			moved[0] += 1)
	assert_true(moved[0] > 0, "released: it moves again")
	assert_false(brain.is_held(), "not held")
	brain.queue_free()
	holder.free()
