shader_type spatial;
// Visible spotlight beam: an open cone, additive, unshaded. Brightest near the floor and
// along the axis (faces seen head-on), fading out at the top and at the silhouette edges.
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.9, 0.7);
uniform float strength = 0.2;
// Local height of the mesh (CylinderMesh is centred: y in -height/2..height/2).
uniform float height = 6.2;

varying float v_h;

void vertex() {
	v_h = clamp(VERTEX.y / height + 0.5, 0.0, 1.0); // 0 at the floor, 1 at the lamp
}

void fragment() {
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float edge = pow(facing, 1.6);
	float fade = smoothstep(1.0, 0.5, v_h) * (0.6 + 0.4 * (1.0 - v_h));
	ALBEDO = color * strength * edge * fade;
}
