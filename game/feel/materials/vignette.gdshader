shader_type canvas_item;
// Knockout vignette: dark plum edges closing in around `center` (UV), plus a faint warm
// glow at the centre. `amount` 0 = invisible.

uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 center = vec2(0.5, 0.5);
uniform float aspect = 1.7777;
uniform vec4 edge_color : source_color = vec4(0.10, 0.05, 0.12, 1.0);

void fragment() {
	vec2 p = (UV - center) * vec2(aspect, 1.0);
	float d = length(p);
	float edge = smoothstep(mix(1.2, 0.32, amount), mix(1.6, 0.95, amount), d);
	COLOR = vec4(edge_color.rgb, edge * amount * 0.92);
}
