// Stylised water: flat teal body, drifting lighter bands, soft foam where it meets geometry
// (depth-based), gentle swell. Opaque-looking but alpha-blended near the shore.
shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_back, depth_draw_always;

uniform vec4 deep_color : source_color = vec4(0.09, 0.33, 0.42, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.184, 0.655, 0.627, 1.0);   // #2fa7a0
uniform vec4 foam_color : source_color = vec4(0.953, 0.902, 0.784, 1.0);      // #f3e6c8
uniform float foam_width = 0.35;
uniform float band_scale = 0.45;
uniform float wave_height = 0.06;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 world_pos;

float wave(vec2 p, float t) {
	return sin(p.x * 0.9 + t * 1.1) * 0.5 + sin(p.y * 1.3 - t * 0.8) * 0.35 + sin((p.x + p.y) * 0.6 + t * 0.6) * 0.3;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += wave(world_pos.xz, TIME) * wave_height;
}

void fragment() {
	// thin wavy highlight lines drifting over a deep-to-teal body
	vec2 p = world_pos.xz * band_scale;
	float warp = wave(p * 1.7, TIME * 0.7) * 0.6;
	float lines = sin(p.x * 2.2 + p.y * 0.8 + warp * 2.0 + TIME * 0.9);
	float stripe = smoothstep(0.95, 0.985, lines);
	float body = 0.5 + 0.5 * sin(world_pos.x * 0.08 + world_pos.z * 0.06 + warp);
	vec3 col = mix(deep_color.rgb, shallow_color.rgb * 0.8, body * 0.6);
	col = mix(col, foam_color.rgb * 0.85, stripe * 0.35);
	// shore foam from the scene depth behind the surface
	float scene_depth = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	view.xyz /= view.w;
	float gap = VERTEX.z - view.z;
	float foam = 1.0 - smoothstep(foam_width * 0.5, foam_width, gap);
	col = mix(col, foam_color.rgb, foam);
	ALBEDO = col;
	ROUGHNESS = 0.25;
	SPECULAR = 0.4;
}
