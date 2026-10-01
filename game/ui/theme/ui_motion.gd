class_name UiMotion
extends RefCounted
## The one place menu motion comes from, so every screen moves the same way. Owner: UI polish.
##
##   UiMotion.attach(root)        every BaseButton under `root` (now and added later) pops:
##                                hover / focus -> scale 1.04, held -> 0.97, 80 ms
##   UiMotion.enter(screen, slide) a screen or overlay arrives: fade in + a short slide of
##                                `slide` (default the screen itself), 0.24 s
##   UiMotion.pulse(control)      a slow "press me" pulse (START), stop with stop_pulse()
##
## `Settings.reduced_motion` (when the Settings autoload exists): no scaling or sliding, only
## a quick fade.

const HOVER_SCALE := 1.04
const PRESS_SCALE := 0.97
const POP_TIME := 0.08
const SCREEN_TIME := 0.24
const SLIDE := Vector2(0, 26)
const PULSE_SCALE := 1.06
const PULSE_TIME := 0.55

static var _roots: Array[WeakRef] = []


## True when the player asked for reduced motion (Settings autoload).
static func reduced_motion() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return false
	var s := tree.root.get_node_or_null(^"Settings")
	return s != null and bool(s.get(&"reduced_motion"))


# --- Buttons -----------------------------------------------------------------------------------

## Hooks every BaseButton under `root`, and any added under it later.
static func attach(root: Node) -> void:
	if root == null:
		return
	for ref in _roots:
		if ref.get_ref() == root:
			return
	_roots.append(weakref(root))
	_hook_all(root)
	var tree := root.get_tree() if root.is_inside_tree() else Engine.get_main_loop() as SceneTree
	if tree and not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)


## Gives one button the hover / focus / press pop.
static func hook_button(b: BaseButton) -> void:
	if b == null or b.has_meta(&"_ui_motion"):
		return
	b.set_meta(&"_ui_motion", true)
	b.resized.connect(_center_pivot.bind(b))
	_center_pivot(b)
	for sig: Signal in [b.mouse_entered, b.mouse_exited, b.focus_entered, b.focus_exited]:
		sig.connect(_refresh.bind(b))
	b.button_down.connect(func() -> void:
		b.set_meta(&"_ui_held", true)
		_refresh(b))
	b.button_up.connect(func() -> void:
		b.set_meta(&"_ui_held", false)
		_refresh(b))
	b.visibility_changed.connect(func() -> void:
		if not b.is_visible_in_tree():
			_kill(b, &"_ui_pop")
			b.set_meta(&"_ui_held", false)
			b.scale = Vector2.ONE)


## The scale `b` should settle at right now.
static func target_scale(b: BaseButton) -> float:
	if b.disabled or reduced_motion():
		return 1.0
	if bool(b.get_meta(&"_ui_held", false)):
		return PRESS_SCALE
	if b.has_focus() or b.is_hovered():
		return HOVER_SCALE
	return 1.0


static func _refresh(b: BaseButton) -> void:
	if not is_instance_valid(b) or not b.is_inside_tree() or b.has_meta(&"_ui_pulse"):
		return
	var s := target_scale(b)
	_kill(b, &"_ui_pop")
	if is_equal_approx(b.scale.x, s):
		return
	var t := b.create_tween()
	t.tween_property(b, ^"scale", Vector2(s, s), POP_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	b.set_meta(&"_ui_pop", t)


static func _center_pivot(c: Control) -> void:
	if is_instance_valid(c):
		c.pivot_offset = c.size * 0.5


static func _hook_all(node: Node) -> void:
	if node is BaseButton:
		hook_button(node as BaseButton)
	for child in node.get_children():
		_hook_all(child)


static func _on_node_added(node: Node) -> void:
	if not node is BaseButton:
		return
	for ref in _roots:
		var r := ref.get_ref() as Node
		if r != null and (r == node or r.is_ancestor_of(node)):
			hook_button(node as BaseButton)
			return


# --- Screens -----------------------------------------------------------------------------------

## `screen` arrives: fades in while `slide` (default: `screen`; a full-rect or freely placed
## Control, not one a container positions) slides up into place. The slide moves the
## control's top and bottom offsets together, so it is right even while the control's size is
## stale (a screen that was hidden until this frame).
static func enter(screen: Control, slide: Control = null) -> void:
	if screen == null:
		return
	var mover := slide if slide != null else screen
	_kill(screen, &"_ui_enter")
	var calm := reduced_motion()
	var home: Vector2 = mover.get_meta(&"_ui_home", Vector2(mover.offset_top, mover.offset_bottom))
	mover.set_meta(&"_ui_home", home)
	screen.modulate.a = 0.0
	var dy := 0.0 if calm else SLIDE.y
	mover.offset_top = home.x + dy
	mover.offset_bottom = home.y + dy
	var t := screen.create_tween().set_parallel(true)
	t.tween_property(screen, ^"modulate:a", 1.0, SCREEN_TIME * (0.5 if calm else 1.0)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if not calm:
		t.tween_property(mover, ^"offset_top", home.x, SCREEN_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		t.tween_property(mover, ^"offset_bottom", home.y, SCREEN_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	screen.set_meta(&"_ui_enter", t)


## Ends any running enter() on `screen` at once (fully shown).
static func finish(screen: Control, slide: Control = null) -> void:
	if screen == null:
		return
	_kill(screen, &"_ui_enter")
	screen.modulate.a = 1.0
	var mover := slide if slide != null else screen
	if mover.has_meta(&"_ui_home"):
		var home: Vector2 = mover.get_meta(&"_ui_home")
		mover.offset_top = home.x
		mover.offset_bottom = home.y


## A slow scale pulse on `c` (its pivot centred), until stop_pulse(c).
static func pulse(c: Control) -> void:
	if c == null or c.has_meta(&"_ui_pulse"):
		return
	if reduced_motion():
		return
	_center_pivot(c)
	var t := c.create_tween().set_loops()
	t.tween_property(c, ^"scale", Vector2(PULSE_SCALE, PULSE_SCALE), PULSE_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(c, ^"scale", Vector2.ONE, PULSE_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	c.set_meta(&"_ui_pulse", t)


static func stop_pulse(c: Control) -> void:
	if c == null or not c.has_meta(&"_ui_pulse"):
		return
	_kill(c, &"_ui_pulse")
	c.remove_meta(&"_ui_pulse")
	c.scale = Vector2.ONE
	if c is BaseButton:
		_refresh(c as BaseButton)


static func is_pulsing(c: Control) -> bool:
	return c != null and c.has_meta(&"_ui_pulse")


static func _kill(o: Object, key: StringName) -> void:
	if o.has_meta(key):
		var t := o.get_meta(key) as Tween
		if t and t.is_valid():
			t.kill()
