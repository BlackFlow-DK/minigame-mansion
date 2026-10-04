// Portrait Panic floor tiles: one MultiMesh, one material. Per instance (INSTANCE_CUSTOM):
// r = symbol index (0..7), g = unused, b = glow (target highlight), a = fade (dithered).
// The tile mesh's top face (+Y) shows the picture, its bottom face (-Y) the card back, so a
// half turn about X hides the symbol (MEMORY) and a full turn shows a new one (SHUFFLE).
shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_back;

#include "res://minigames/portrait_panic/portrait_symbols.gdshaderinc"

uniform float frame_width = 0.07;

varying float v_face;
varying vec4 v_custom;

void vertex() {
	v_face = NORMAL.y;
	v_custom = INSTANCE_CUSTOM;
}

// Interleaved gradient noise: a stable screen-space dither for the fade.
float pp_dither(vec2 fc) {
	return fract(52.9829189 * fract(dot(fc, vec2(0.06711056, 0.00583715))));
}

void fragment() {
	if (v_custom.a < 0.999 && v_custom.a <= pp_dither(FRAGCOORD.xy)) {
		discard;
	}
	int sym = int(round(v_custom.r));
	float glow = v_custom.b;
	vec3 gold = vec3(0.90, 0.68, 0.27);
	vec3 col;
	vec3 emit = vec3(0.0);
	float rough = 0.75;
	if (abs(v_face) > 0.5) {
		vec2 uv = UV;
		float e = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
		vec2 p = vec2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
		vec2 pp = p / (1.0 - frame_width * 2.0 - 0.05);
		float aa = max(fwidth(pp.x), fwidth(pp.y)) * 1.1;
		if (v_face > 0.5) {
			float m;
			col = pp_picture(sym, pp, aa, m);
			emit = pp_lin(pp_color(sym)) * m * (0.22 + 0.5 * glow);
		} else {
			col = pp_card_back(pp * 0.92, aa);
		}
		// Gilded frame: a rounded ridge, lit from the far-left, dark lines inside and out.
		float fa = max(fwidth(e), 0.0005) * 1.2;
		float in_frame = 1.0 - smoothstep(frame_width - fa, frame_width + fa, e);
		bool lit_side = min(uv.x, uv.y) < min(1.0 - uv.x, 1.0 - uv.y);
		float ridge = 0.72 + 0.4 * sin(clamp(e / frame_width, 0.0, 1.0) * 3.14159);
		vec3 fcol = gold * (lit_side ? 1.12 : 0.8) * ridge;
		float inner = 1.0 - smoothstep(0.0, fa * 1.5, abs(e - frame_width) - 0.005);
		float outer = 1.0 - smoothstep(0.0, fa * 1.5, e - 0.006);
		col = mix(col, fcol, in_frame);
		col = mix(col, vec3(0.16, 0.10, 0.05), max(inner, outer) * 0.85);
		emit += pp_lin(gold) * in_frame * glow * 1.4;
		rough = mix(0.75, 0.4, in_frame);
	} else {
		col = mix(vec3(0.33, 0.22, 0.13), gold * 0.75, 0.25);
		emit = pp_lin(gold) * glow * 0.5;
	}
	ALBEDO = pp_lin(col);
	ROUGHNESS = rough;
	EMISSION = emit;
}
