class_name FeelTime
extends RefCounted
## Visual-only clock for game feel. Owner: look and effects (juice).
##
## `scale` slows what is drawn (effects, blob animation, pop-ghost tweens), never physics,
## timers that matter, input or networking: Engine.time_scale stays 1.0 on every peer.
## Readers multiply their own frame delta by it:
##   FxEffect._process      (particles: CPUParticles3D.speed_scale follows it)
##   VisualsComponent._process
##   nodes in group GROUP with a Tween in meta TWEEN_META (e.g. the elimination pop ghost)
## Only the `Feel` autoload writes it (knockout slow-motion), through set_scale().

const GROUP := &"feel_slowmo"
const TWEEN_META := &"feel_tween"

static var scale: float = 1.0


## Sets the visual time scale (clamped 0.05..1) and re-times the tweens of GROUP nodes.
static func set_scale(value: float) -> void:
	scale = clampf(value, 0.05, 1.0)
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for n in tree.get_nodes_in_group(GROUP):
		retime(n)


## Applies the current scale to the Tween stored in `node`'s TWEEN_META (if still running).
static func retime(node: Node) -> void:
	if node == null or not node.has_meta(TWEEN_META):
		return
	var tw := node.get_meta(TWEEN_META) as Tween
	if tw and tw.is_valid():
		tw.set_speed_scale(scale)
