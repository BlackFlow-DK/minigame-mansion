// Camera-facing puffy stars (hit stars, stun swirl, sparkles): like fx_lit but the mesh is
// turned to face the camera, spun in screen space by the particle angle (INSTANCE_CUSTOM.x),
// so a star never goes edge-on. Glows a little so it pops on any floor.
shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_back;

uniform float glow = 0.5;
uniform float spin_speed = 0.0;   // extra spin for plain meshes (radians per second)
instance uniform vec4 tint : source_color = vec4(1.0);

vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void vertex() {
	float a = INSTANCE_CUSTOM.x + TIME * spin_speed;
	mat4 world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	world = world * mat4(vec4(cos(a), -sin(a), 0.0, 0.0), vec4(sin(a), cos(a), 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * world;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec3 c = to_linear(max(COLOR.rgb, vec3(0.0))) * tint.rgb;
	ALBEDO = c;
	ROUGHNESS = 0.5;
	RIM = 0.3;
	RIM_TINT = 0.5;
	EMISSION = c * glow;
}
