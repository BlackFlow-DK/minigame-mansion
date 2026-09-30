class_name RoundBlobIcon
extends Control
## A player's blob face drawn in their colour (body, eyes, pupils). Scales with its size.
## Owner: round UI.

var color: Color = Color.WHITE:
	set(value):
		color = value
		queue_redraw()

## Greyed out (eliminated): grey body, closed eyes.
var grey: bool = false:
	set(value):
		grey = value
		queue_redraw()


func _init(p_color: Color = Color.WHITE, p_size: float = 40.0) -> void:
	color = p_color
	custom_minimum_size = Vector2(p_size, p_size)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var r := minf(size.x, size.y) * 0.5
	if r <= 0.0:
		return
	var c := size * 0.5
	var body := RoundStyle.GREY if grey else color
	draw_circle(c + Vector2(0, r * 0.06), r, RoundStyle.CHARCOAL, true, -1.0, true)
	draw_circle(c, r * 0.86, body, true, -1.0, true)
	draw_circle(c + Vector2(-r * 0.36, -r * 0.4), r * 0.16, Color(1, 1, 1, 0.35), true, -1.0, true)
	for side: float in [-1.0, 1.0]:
		var eye := c + Vector2(r * 0.3 * side, -r * 0.08)
		if grey:
			draw_line(eye - Vector2(r * 0.16, 0), eye + Vector2(r * 0.16, 0), RoundStyle.CHARCOAL, maxf(2.0, r * 0.1), true)
		else:
			draw_circle(eye, r * 0.2, Color.WHITE, true, -1.0, true)
			draw_circle(eye + Vector2(r * 0.04, r * 0.05), r * 0.1, RoundStyle.CHARCOAL, true, -1.0, true)
