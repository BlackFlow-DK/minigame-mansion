// Lit effect particles (puffs, stars, chunks, confetti): soft toon ramp like the characters,
// colour from the particle colour (authored sRGB, converted here) times the per-instance
// tint, optional self-glow so hot bits bloom.
shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_back;

uniform float glow = 0.0;
uniform float roughness = 0.6;
uniform float rim = 0.35;
instance uniform vec4 tint : source_color = vec4(1.0);

vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void fragment() {
	vec3 c = to_linear(max(COLOR.rgb, vec3(0.0))) * tint.rgb;
	ALBEDO = c;
	ROUGHNESS = roughness;
	RIM = rim;
	RIM_TINT = 0.5;
	EMISSION = c * glow;
}
