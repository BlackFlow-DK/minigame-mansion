shader_type canvas_item;
// Plum iris curtain for screen transitions. `progress` 0 = fully open, 1 = fully closed.
// The hole is a circle around `center` (UV), its edge trimmed in gold; the curtain itself
// has soft vertical velvet folds. Mouse input never depends on this (the rect ignores it).

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec2 center = vec2(0.5, 0.5);
uniform float aspect = 1.7777;
uniform vec4 curtain_color : source_color = vec4(0.427, 0.290, 0.486, 1.0);
uniform vec4 fold_color : source_color = vec4(0.300, 0.190, 0.350, 1.0);
uniform vec4 trim_color : source_color = vec4(0.910, 0.702, 0.227, 1.0);

void fragment() {
	vec2 p = (UV - center) * vec2(aspect, 1.0);
	float d = length(p);
	// Radius that clears every corner from any centre.
	vec2 far = max(center, vec2(1.0) - center) * vec2(aspect, 1.0);
	float r = (length(far) + 0.06) * (1.0 - progress);
	float aa = fwidth(d) * 1.5;
	float cover = smoothstep(r - aa, r + aa, d);
	float trim = 0.022;
	float in_trim = cover * (1.0 - smoothstep(r + trim - aa, r + trim + aa, d));
	float folds = 0.5 + 0.5 * sin(UV.x * aspect * 46.0 + sin(UV.y * 5.0) * 0.6);
	vec3 velvet = mix(fold_color.rgb, curtain_color.rgb, folds * 0.75 + 0.25);
	// Darker towards the hole, so the edge reads as depth.
	velvet *= mix(0.75, 1.0, smoothstep(r, r + 0.35, d));
	vec3 col = mix(velvet, trim_color.rgb, in_trim);
	COLOR = vec4(col, cover);
}
