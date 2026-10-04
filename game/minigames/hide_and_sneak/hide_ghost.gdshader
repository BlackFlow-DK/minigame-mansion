shader_type spatial;
// Hide and Sneak: the hider's own faint blob outline, seen through its prop (own peer only).
// A rim (fresnel) silhouette, unshaded, drawn over everything.
render_mode unshaded, depth_test_disabled, cull_back, shadows_disabled, blend_mix;

uniform vec4 color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float strength = 0.75;

void fragment() {
	float rim = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	ALBEDO = color.rgb;
	ALPHA = clamp(pow(rim, 2.2) * strength + 0.06, 0.0, 1.0);
}
