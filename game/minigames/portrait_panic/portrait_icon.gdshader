// Portrait Panic HUD icon: one symbol with a dark outline on a transparent square.
shader_type canvas_item;

#include "res://minigames/portrait_panic/portrait_symbols.gdshaderinc"

uniform int symbol = 0;

void fragment() {
	vec2 p = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0) / 0.86;
	float aa = max(fwidth(p.x), 0.001) * 1.2;
	float d = pp_symbol(symbol, p);
	float outline = 1.0 - smoothstep(-aa, aa, d - 0.1);
	float fill = 1.0 - smoothstep(-aa, aa, d);
	vec3 col = mix(vec3(0.06, 0.05, 0.07), pp_color(symbol), fill);
	COLOR = vec4(col, outline * COLOR.a);
}
