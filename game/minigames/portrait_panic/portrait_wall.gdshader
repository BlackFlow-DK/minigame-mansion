// Portrait Panic gallery walls: a two-tone damask trellis in world space (walls are axis
// aligned, so x + z along the wall and y up give a seamless pattern), toon-lit like the house look.
shader_type spatial;
render_mode diffuse_toon, specular_disabled;

uniform vec3 base : source_color = vec3(0.48, 0.17, 0.24);
uniform vec3 ink : source_color = vec3(0.38, 0.12, 0.19);
uniform vec3 sheen : source_color = vec3(0.58, 0.24, 0.29);
uniform float scale = 1.1;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = vec2(v_world.x + v_world.z, v_world.y * 0.8) / scale;
	vec2 g = fract(uv) - 0.5;
	float aa = max(fwidth(uv.x), fwidth(uv.y)) * 1.5;
	// trellis: diamond lines through the cell corners
	float diamond = abs(abs(g.x) + abs(g.y) - 0.5);
	float lines = 1.0 - smoothstep(0.025, 0.025 + aa, diamond);
	// a four-petal motif in each diamond
	vec2 q = abs(g);
	float petal = min(length(q - vec2(0.0, 0.13)) - 0.07, length(q - vec2(0.13, 0.0)) - 0.07);
	petal = min(petal, length(g) - 0.05);
	float motif = 1.0 - smoothstep(-aa, aa, petal);
	vec3 col = mix(base, ink, lines * 0.9);
	col = mix(col, sheen, motif * 0.85);
	ALBEDO = col;
	ROUGHNESS = 0.85;
}
