// Inverted-hull outline, used as the next_pass of toon materials by Look.apply_toon.
// Back faces pushed out along the normal in view space by an amount that grows with
// distance, so the line keeps a steady on-screen width (width_px at 720p, a fixed share of
// the screen height at any resolution), capped in metres for close-ups.
shader_type spatial;
render_mode unshaded, cull_front, skip_vertex_transform, fog_disabled, shadows_disabled;

// false (LOW quality) collapses the hull: no fragments, next to no cost
uniform bool enabled = true;
uniform vec4 outline_color : source_color = vec4(0.18, 0.15, 0.2, 1.0);
uniform float width_px : hint_range(0.0, 8.0) = 2.0;
uniform float max_world = 0.035;

void vertex() {
	vec3 v = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n = normalize(mat3(MODELVIEW_MATRIX) * NORMAL);
	float dist = max(-v.z, 0.01);
	float metres_per_px = 2.0 * dist / (max(PROJECTION_MATRIX[1][1], 1e-4) * 720.0);
	v += n * min(width_px * metres_per_px, max_world);
	// Orthographic projection = directional shadow pass: the hull must not cast shadows.
	if (!enabled || PROJECTION_MATRIX[3][3] > 0.5) {
		v = vec3(0.0);
	}
	VERTEX = v;
	NORMAL = n;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
