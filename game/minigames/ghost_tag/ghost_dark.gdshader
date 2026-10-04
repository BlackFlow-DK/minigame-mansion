shader_type spatial;
// Ghost Tag night: a dark veil over the attic with soft pools of light punched out where the
// lanterns (and the ghosts' cold glow, and the moonlit windows) are. Sits on a plane above
// the walls; each fragment is projected along the view ray down to blob height, so the pools
// sit exactly around the blobs from any camera. Name tags (render_priority 10) draw after it.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 dark_color : source_color = vec4(0.03, 0.03, 0.09, 0.6);
// xy = world x/z, z = radius (m), w = strength (0..1)
uniform vec4 holes[16];
uniform int hole_count = 0;
uniform float sample_height = 0.5;
uniform vec4 bounds = vec4(-12.0, -9.0, 12.0, 9.0);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 dir = world_pos - cam;
	vec2 p = world_pos.xz;
	if (abs(dir.y) > 0.0001) {
		float t = (sample_height - cam.y) / dir.y;
		p = (cam + dir * t).xz;
	}
	float lit = 0.0;
	for (int i = 0; i < 16; i++) {
		if (i >= hole_count) {
			break;
		}
		vec4 h = holes[i];
		float d = distance(p, h.xy) / max(h.z, 0.01);
		lit = max(lit, h.w * (1.0 - smoothstep(0.25, 1.0, d)));
	}
	// a little darker toward the edges of the attic (a soft vignette in the room itself)
	vec2 c = (bounds.xy + bounds.zw) * 0.5;
	vec2 half_size = (bounds.zw - bounds.xy) * 0.5;
	float edge = length((p - c) / half_size);
	float vig = smoothstep(0.75, 1.35, edge) * 0.25;
	ALBEDO = dark_color.rgb;
	ALPHA = clamp(dark_color.a * (1.0 - lit) + vig, 0.0, 0.95);
}
