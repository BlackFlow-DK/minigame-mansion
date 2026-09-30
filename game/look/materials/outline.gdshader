// Inverted-hull outline, used as the next_pass of toon materials by Look.apply_toon.
// Pushes back faces out along the SMOOTHED normal that Look.prepare_outline bakes into
// CUSTOM0.xyz (CUSTOM0.w = the mesh's outline weight). Split normals would tear the hull
// into spikes; meshes that were never prepared (CUSTOM0 = 0) or that opted out get no hull.
// The push grows with distance so the line is a steady `width_px` on screen (at 720p, a fixed
// share of the screen height at any resolution); never more than `max_world` metres.
shader_type spatial;
render_mode unshaded, cull_front, skip_vertex_transform, fog_disabled, shadows_disabled;

// false (LOW quality) collapses the hull: no fragments, next to no cost
uniform bool enabled = true;
uniform vec4 outline_color : source_color = vec4(0.18, 0.15, 0.2, 1.0);
uniform float width_px : hint_range(0.0, 8.0) = 1.7;
uniform float max_world = 0.06;

void vertex() {
	vec3 v = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 smooth_n = CUSTOM0.xyz;
	float weight = CUSTOM0.w;
	vec3 n = mat3(MODELVIEW_MATRIX) * smooth_n;
	float len = length(n);
	n = len > 1e-6 ? n / len : vec3(0.0);
	float dist = max(-v.z, 0.01);
	// Vulkan projections flip Y: [1][1] is negative
	float metres_per_px = 2.0 * dist / (max(abs(PROJECTION_MATRIX[1][1]), 1e-4) * 720.0);
	v += n * min(width_px * metres_per_px, max_world) * weight;
	// No hull when off, not prepared/opted out, or in a directional shadow pass (orthographic).
	if (!enabled || weight <= 0.0 || PROJECTION_MATRIX[3][3] > 0.5) {
		v = vec3(0.0);
	}
	VERTEX = v;
	NORMAL = n;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
