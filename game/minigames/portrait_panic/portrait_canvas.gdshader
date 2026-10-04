// Portrait Panic: the canvas of the huge gilded portrait on the back wall (the big screen).
// symbol < 0: the card back (shuffling). Otherwise the symbol, with a countdown ring
// (`progress` 1 -> 0, < 0 hides it) and, for DECOY, two pips (`pips` 1 or 2 lit).
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://minigames/portrait_panic/portrait_symbols.gdshaderinc"

uniform int symbol = -1;
uniform float progress = -1.0;
uniform int pips = 0;
uniform float flash = 0.0;
uniform float glow = 0.0;
uniform float aspect = 1.5;
uniform float brightness = 1.25;

void fragment() {
	vec2 p = vec2((UV.x * 2.0 - 1.0) * aspect, 1.0 - UV.y * 2.0);
	float aa = max(fwidth(p.x), fwidth(p.y)) * 1.3;
	vec3 col;
	if (symbol < 0) {
		col = pp_card_back(p * 0.62, aa * 0.62);
	} else {
		float s = 0.74;
		float m;
		col = pp_picture(symbol, p / s, aa / s, m);
		col = mix(col, col * 1.25, m * glow);
	}
	if (progress >= 0.0) {
		float r = length(p);
		float band = abs(r - 0.9) - 0.055;
		float a = fract(atan(p.x, p.y + 1e-5) / 6.2831853 + 1.0);
		vec3 on = progress > 0.3 ? vec3(0.95, 0.75, 0.30) : vec3(0.95, 0.30, 0.22);
		float lit = 1.0 - smoothstep(-0.004, 0.004, a - progress);
		vec3 ring = mix(vec3(0.10, 0.07, 0.10), on, lit);
		col = mix(col, ring, 1.0 - smoothstep(-aa, aa, band));
	}
	if (pips > 0) {
		for (int i = 1; i <= 2; i++) {
			vec2 c = vec2(i == 1 ? -1.2 : 1.2, 0.0);
			float d = length(p - c) - 0.12;
			vec3 pc = (i == pips) ? vec3(1.0, 0.85, 0.35) : vec3(0.22, 0.17, 0.24);
			col = mix(col, vec3(0.05), 1.0 - smoothstep(-aa, aa, d - 0.03));
			col = mix(col, pc, 1.0 - smoothstep(-aa, aa, d));
		}
	}
	col = mix(col, vec3(1.0, 0.97, 0.9), clamp(flash, 0.0, 1.0));
	ALBEDO = pp_lin(col) * brightness;
}
