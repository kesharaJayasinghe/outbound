shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;

// The falling curtain of a waterfall (waterfall.gd). UV.x runs across the curtain,
// UV.y is metres travelled from the lip; COLOR.r is 0 at the lip and 1 at the pool.
// Streaks of white water race down it, and it breaks up into spray towards the bottom.

#include "res://shaders/wind.gdshaderinc"

uniform vec3 water_color : source_color = vec3(0.55, 0.7, 0.72);
uniform vec3 foam_color : source_color = vec3(0.93, 0.96, 0.98);
uniform float speed = 7.0;     // Metres per second the streaks fall
uniform float width_m = 5.0;   // Curtain width at the lip, so streaks keep a fixed size

float streaks(vec2 uv, float t) {
	float across = uv.x * width_m;
	// Long thin streaks: fine across, stretched along the fall
	float a = wind_value_noise(vec2(across * 3.2, (uv.y - t * speed) * 0.45));
	float b = wind_value_noise(vec2(across * 7.5 + 13.0, (uv.y - t * speed * 1.2) * 0.9));
	return a * 0.65 + b * 0.35;
}

void fragment() {
	float frac = COLOR.r;
	float s = streaks(UV, TIME);
	float edges = smoothstep(0.0, 0.14, UV.x) * smoothstep(1.0, 0.86, UV.x);
	// Glassy and fairly solid as it pours over the lip, white and broken lower down
	float white = smoothstep(0.35, 0.75, s + frac * 0.35);
	float body = mix(0.75, 0.35, frac) + white * 0.5;
	float breakup = smoothstep(0.15 + frac * 0.35, 0.45 + frac * 0.35, s);
	ALBEDO = mix(water_color, foam_color, white);
	ALPHA = clamp(body * mix(1.0, breakup, frac * 0.8), 0.0, 1.0) * edges;
	ROUGHNESS = mix(0.08, 0.5, white);
	SPECULAR = 0.5;
	BACKLIGHT = vec3(0.35);
}
