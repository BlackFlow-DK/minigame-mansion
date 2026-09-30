// Stylised lava: dark crust plates drifting on glowing molten flow, bright cracks between
// the plates, a slow swell in the surface. World-space so neighbouring tiles line up.
// Flat candy colours, no textures. Emission is HDR so it blooms with the StageLook glow.
shader_type spatial;
render_mode diffuse_toon, specular_disabled;

uniform vec4 molten_color : source_color = vec4(1.0, 0.416, 0.122, 1.0);   // #ff6a1f
uniform vec4 hot_color : source_color = vec4(1.0, 0.68, 0.22, 1.0);        // crests and cracks
uniform vec4 crust_color : source_color = vec4(0.30, 0.10, 0.09, 1.0);     // cooled plates
uniform float emission_strength = 1.5;
uniform float crust_amount : hint_range(0.0, 1.0) = 0.6;
uniform float cell_size = 1.6;          // metres per crust plate
uniform float flow_speed = 0.18;
uniform float wave_height = 0.05;
uniform vec2 flow_dir = vec2(1.0, 0.35);

varying vec3 world_pos;

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2(i).x;
	float b = hash2(i + vec2(1.0, 0.0)).x;
	float c = hash2(i + vec2(0.0, 1.0)).x;
	float d = hash2(i + vec2(1.0, 1.0)).x;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return v;
}

// x: distance to the nearest cell centre, y: distance to the cell border, z: cell id
vec3 voronoi(vec2 p, float t) {
	vec2 n = floor(p);
	vec2 f = fract(p);
	vec2 mg;
	vec2 mr;
	float md = 8.0;
	float id = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 o = hash2(n + g);
			o = 0.5 + 0.35 * sin(t + 6.2831 * o);
			vec2 r = g + o - f;
			float d = dot(r, r);
			if (d < md) {
				md = d;
				mr = r;
				mg = g;
				id = hash2(n + g).y;
			}
		}
	}
	float border = 8.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			vec2 g = mg + vec2(float(i), float(j));
			vec2 o = hash2(n + g);
			o = 0.5 + 0.35 * sin(t + 6.2831 * o);
			vec2 r = g + o - f;
			if (dot(mr - r, mr - r) > 0.00001) {
				border = min(border, dot(0.5 * (mr + r), normalize(r - mr)));
			}
		}
	}
	return vec3(sqrt(md), border, id);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float s = fbm(world_pos.xz * 0.35 + TIME * 0.12);
	VERTEX.y += (s - 0.5) * 2.0 * wave_height;
}

void fragment() {
	vec2 flow = normalize(flow_dir) * TIME * flow_speed;
	vec2 p = world_pos.xz / cell_size + flow;
	vec3 v = voronoi(p, TIME * 0.35);
	float warp = fbm(world_pos.xz * 0.6 - flow * 1.6);
	// plates: only some cells crust over, shrunk away from the border so cracks glow
	float crusted = step(1.0 - crust_amount, fract(v.z + warp * 0.35));
	float aa = clamp(length(fwidth(p)) * 0.7, 0.0, 0.3);
	float plate = crusted * smoothstep(0.06, 0.16 + aa, v.y);
	// molten flow with posterised hot crests
	float heat = fbm(world_pos.xz * 0.45 + flow * 2.2 + warp);
	float crest = smoothstep(0.56, 0.72, heat);
	vec3 molten = mix(molten_color.rgb, hot_color.rgb, crest * 0.6);
	// the glowing rim hugging each plate
	float rim = crusted * (1.0 - smoothstep(0.02, 0.1 + aa, v.y));
	molten = mix(molten, hot_color.rgb, rim * 0.65);
	vec3 crust = crust_color.rgb * (0.85 + 0.3 * v.z);
	vec3 col = mix(molten, crust, plate);
	float glow = (1.0 - plate) * (0.75 + 0.35 * crest + 0.6 * rim);
	ALBEDO = col * mix(0.35, 1.0, plate);
	EMISSION = molten * emission_strength * glow;
	ROUGHNESS = mix(0.3, 0.9, plate);
}
