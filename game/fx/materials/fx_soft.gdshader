// Soft see-through effect parts (shockwave rings, wind streaks): unshaded, alpha from the
// particle colour, no depth write.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform float brightness = 1.0;
instance uniform vec4 tint : source_color = vec4(1.0);

vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void fragment() {
	ALBEDO = to_linear(max(COLOR.rgb, vec3(0.0))) * tint.rgb * brightness;
	ALPHA = clamp(COLOR.a, 0.0, 1.0);
}
