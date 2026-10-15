shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;

// Churning white water on a plunge pool, where a waterfall lands (waterfall.gd).
// Drawn on a flat square: a ragged patch of foam that boils outward from the centre.

#include "res://shaders/wind.gdshaderinc"

uniform vec3 foam_color : source_color = vec3(0.9, 0.94, 0.95);
uniform float spread_speed = 0.6;

void fragment() {
	vec2 p = UV - 0.5;
	float r = length(p) * 2.0;  // 0 at the centre, 1 at the edge of the square
	vec2 out_dir = p / max(length(p), 1e-4);
	// Noise drifting outward, in two cycles cross-faded so it never stretches
	float t = TIME * spread_speed;
	float ph0 = fract(t);
	float ph1 = fract(t + 0.5);
	vec2 q = UV * 9.0;
	float a = wind_value_noise(q - out_dir * ph0 * 2.0);
	float b = wind_value_noise(q - out_dir * ph1 * 2.0 + 5.3);
	float n = mix(b, a, abs(1.0 - 2.0 * ph0));
	n = n * 0.7 + wind_value_noise(q * 2.7 + TIME * 0.8) * 0.3;
	float core = 1.0 - smoothstep(0.15, 0.95, r + (n - 0.5) * 0.5);
	ALBEDO = foam_color;
	ALPHA = clamp(core * smoothstep(0.3, 0.6, n + core * 0.4), 0.0, 1.0) * 0.9;
	ROUGHNESS = 0.6;
}
