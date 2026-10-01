@tool
class_name FocusRingStyle
extends StyleBox
## Keyboard / gamepad focus ring for every menu control: a gold ring with a charcoal rim, a
## small gap outside the control, so it reads on cream panels, dark scrims and the plum
## backdrop alike. Used by mansion_theme.tres (make_theme.gd) as the `focus` stylebox.

@export var radius: int = 18
@export var gap: float = 3.0
@export var ring_width: int = 4
@export var rim_width: int = 3
@export var ring_color: Color = Color("#ffc93c")
@export var rim_color: Color = Color("#2e2a33")


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	var ring_outer := gap + ring_width
	var rim := StyleBoxFlat.new()
	rim.draw_center = false
	rim.anti_aliasing = true
	rim.corner_detail = 10
	rim.border_color = rim_color
	rim.set_border_width_all(rim_width)
	rim.set_corner_radius_all(radius + int(ring_outer + rim_width))
	rim.draw(to_canvas_item, rect.grow(ring_outer + rim_width))
	var ring := StyleBoxFlat.new()
	ring.draw_center = false
	ring.anti_aliasing = true
	ring.corner_detail = 10
	ring.border_color = ring_color
	ring.set_border_width_all(ring_width)
	ring.set_corner_radius_all(radius + int(ring_outer))
	ring.draw(to_canvas_item, rect.grow(ring_outer))
