shader_type canvas_item;
// Statue Garden RED mood: a dark red vignette creeping in from the edges, pulsing gently.

uniform float strength : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform vec4 tint : source_color = vec4(0.5, 0.02, 0.06, 1.0);

void fragment() {
	vec2 uv = UV - 0.5;
	uv.x *= 1.35;
	float d = length(uv) * 1.55;
	float edge = smoothstep(0.62, 1.2, d);
	float a = (edge * (0.8 + 0.2 * pulse) + 0.04) * strength;
	COLOR = vec4(tint.rgb, clamp(a, 0.0, 0.72));
}
