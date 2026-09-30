// A big flat disc under a floating arena: solid `color` in the middle fading to fully
// transparent at `outer_radius` (metres from the node origin), so the arena's edge drops
// away into the background instead of ending at a hard line. Unshaded, never writes depth.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 color : source_color = vec4(0.18, 0.165, 0.2, 1.0);
uniform float inner_radius = 8.0;
uniform float outer_radius = 30.0;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	float r = length(local_pos.xz);
	float a = 1.0 - smoothstep(inner_radius, outer_radius, r);
	ALBEDO = color.rgb;
	ALPHA = color.a * a * a;
}
