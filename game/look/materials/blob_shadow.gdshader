// Soft round contact shadow on a flat quad (BlobShadow). Per-instance strength so one shared
// material serves every player.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 shadow_color : source_color = vec4(0.12, 0.08, 0.14, 1.0);
instance uniform float strength = 0.5;

void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float a = 1.0 - smoothstep(0.35, 1.0, r);
	ALBEDO = shadow_color.rgb;
	ALPHA = a * strength;
}
