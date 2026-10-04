// Portrait Panic: the eight symbols as signed distance fields, shared by the floor tiles,
// the big portrait and the HUD icon. Coordinates: p in [-1, 1]^2, +y = "up" on the picture.
// Every shape differs in form AND colour (colour-blind friendly): red circle, blue square,
// yellow triangle, green star, purple diamond, orange moon, white cross, teal heart.
// Colours are sRGB; spatial shaders convert with pp_lin().

vec3 pp_lin(vec3 c) {
	// Clamped: pow() of a negative is NaN, and the glow pass smears a NaN over the screen.
	return pow(max(c, vec3(0.0)), vec3(2.2));
}

vec3 pp_color(int s) {
	if (s == 0) return vec3(0.925, 0.200, 0.180);  // red
	if (s == 1) return vec3(0.200, 0.500, 0.960);  // blue
	if (s == 2) return vec3(1.000, 0.830, 0.130);  // yellow
	if (s == 3) return vec3(0.250, 0.780, 0.300);  // green
	if (s == 4) return vec3(0.760, 0.440, 1.000);  // purple
	if (s == 5) return vec3(1.000, 0.560, 0.100);  // orange
	if (s == 6) return vec3(0.975, 0.965, 0.940);  // white
	return vec3(0.120, 0.830, 0.780);              // teal
}

float pp_sd_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float pp_sd_triangle(vec2 p, float r) {
	const float k = 1.7320508;
	p.x = abs(p.x) - r;
	p.y = p.y + r / k;
	if (p.x + k * p.y > 0.0) {
		p = vec2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
	}
	p.x -= clamp(p.x, -2.0 * r, 0.0);
	return -length(p) * sign(p.y);
}

float pp_sd_star5(vec2 p, float r, float rf) {
	const vec2 k1 = vec2(0.809016994375, -0.587785252292);
	const vec2 k2 = vec2(-0.809016994375, -0.587785252292);
	p.x = abs(p.x);
	p -= 2.0 * max(dot(k1, p), 0.0) * k1;
	p -= 2.0 * max(dot(k2, p), 0.0) * k2;
	p.x = abs(p.x);
	p.y -= r;
	vec2 ba = rf * vec2(-k1.y, k1.x) - vec2(0.0, 1.0);
	float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
	return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
}

float pp_sd_rhombus(vec2 p, vec2 b) {
	p = abs(p);
	vec2 c = b - 2.0 * p;
	float h = clamp((c.x * b.x - c.y * b.y) / dot(b, b), -1.0, 1.0);
	float d = length(p - 0.5 * b * vec2(1.0 - h, 1.0 + h));
	return d * sign(p.x * b.y + p.y * b.x - b.x * b.y);
}

float pp_sd_moon(vec2 p, float d, float ra, float rb) {
	p.y = abs(p.y);
	float a = (ra * ra - rb * rb + d * d) / (2.0 * d);
	float b = sqrt(max(ra * ra - a * a, 0.0));
	if (d * (p.x * b - p.y * a) > d * d * max(b - p.y, 0.0)) {
		return length(p - vec2(a, b));
	}
	return max(length(p) - ra, -(length(p - vec2(d, 0.0)) - rb));
}

float pp_sd_cross(vec2 p, vec2 b) {
	p = abs(p);
	p = (p.y > p.x) ? p.yx : p.xy;
	vec2 q = p - b;
	float k = max(q.y, q.x);
	vec2 w = (k > 0.0) ? q : vec2(b.y - p.x, -k);
	return sign(k) * length(max(w, 0.0));
}

float pp_dot2(vec2 v) {
	return dot(v, v);
}

float pp_sd_heart(vec2 p) {
	p.x = abs(p.x);
	if (p.y + p.x > 1.0) {
		return sqrt(pp_dot2(p - vec2(0.25, 0.75))) - 0.35355339;
	}
	return sqrt(min(pp_dot2(p - vec2(0.0, 1.0)), pp_dot2(p - 0.5 * max(p.x + p.y, 0.0)))) * sign(p.x - p.y);
}

// Signed distance of symbol `s` (negative inside), each sized to fill about 75% of the box.
float pp_symbol(int s, vec2 p) {
	if (s == 0) return length(p) - 0.70;
	if (s == 1) return pp_sd_box(p, vec2(0.62), 0.08);
	if (s == 2) return pp_sd_triangle(p - vec2(0.0, -0.12), 0.80) - 0.04;
	if (s == 3) return pp_sd_star5(p - vec2(0.0, -0.06), 0.82, 0.45) - 0.03;
	if (s == 4) return pp_sd_rhombus(p, vec2(0.62, 0.86)) - 0.02;
	if (s == 5) return pp_sd_moon(p - vec2(-0.08, 0.0), 0.42, 0.74, 0.62) - 0.01;
	if (s == 6) return pp_sd_cross(p, vec2(0.78, 0.24)) - 0.03;
	vec2 hp = p / 0.95 + vec2(0.0, 0.66);
	return pp_sd_heart(hp) * 0.95 - 0.02;
}

// Card back (a hidden tile or a blank portrait): gold lattice on deep plum with a
// medallion. Returns sRGB.
vec3 pp_card_back(vec2 p, float aa) {
	vec3 base = vec3(0.24, 0.13, 0.25);
	vec3 gold = vec3(0.86, 0.64, 0.24);
	vec2 r = vec2(p.x + p.y, p.x - p.y) * 2.2;
	vec2 f = abs(fract(r) - 0.5);
	float ln = min(f.x, f.y);
	float lat = 1.0 - smoothstep(0.035, 0.035 + aa * 3.0, ln);
	vec3 col = mix(base, base * 1.25 + vec3(0.03, 0.0, 0.02), lat * 0.9);
	float m = length(p);
	float ring = abs(m - 0.42) - 0.06;
	col = mix(col, vec3(0.16, 0.08, 0.17), 1.0 - smoothstep(-aa, aa, m - 0.48));
	col = mix(col, gold, 1.0 - smoothstep(-aa, aa, ring));
	float dot_ = m - 0.14;
	col = mix(col, gold, 1.0 - smoothstep(-aa, aa, dot_));
	return col;
}

// A picture: dark canvas with symbol `s` (dark outline, soft drop shadow). `aa`: the
// antialias width in p units. Returns sRGB; `sym_mask` = coverage of the symbol itself.
vec3 pp_picture(int s, vec2 p, float aa, out float sym_mask) {
	vec3 canvas = vec3(0.17, 0.14, 0.22) * clamp(1.08 - 0.22 * dot(p, p), 0.55, 1.08);
	float d = pp_symbol(s, p);
	float ds = pp_symbol(s, p - vec2(0.05, -0.07));
	float shadow = 1.0 - smoothstep(-0.06, 0.12, ds);
	vec3 col = mix(canvas, canvas * 0.45, shadow * 0.8);
	float outline = 1.0 - smoothstep(-aa, aa, d - 0.075);
	col = mix(col, vec3(0.05, 0.04, 0.06), outline);
	sym_mask = 1.0 - smoothstep(-aa, aa, d);
	vec3 c = pp_color(s);
	// A soft top-light on the symbol so it reads as a painted shape, not a decal.
	c *= 1.0 + 0.12 * clamp(p.y - d * 1.5, -1.0, 1.0);
	col = mix(col, c, sym_mask);
	return col;
}
