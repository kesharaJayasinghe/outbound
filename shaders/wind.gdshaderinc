// Shared wind model so grass, fronds and leaves all move with the same gusts.

uniform vec2 wind_direction = vec2(1.0, 0.35);
uniform float wind_strength = 1.0;
uniform float wind_speed = 1.0;

// World-space displacement for a point on a plant rooted at `origin`.
// `weight` is how flexible the point is (0 at the root, larger towards tips).
vec3 wind_offset(vec3 origin, float weight, float time) {
	vec2 dir = normalize(wind_direction);
	float t = time * wind_speed;
	// Phase travels along the wind so gusts visibly roll across the landscape
	float phase = dot(origin.xz, dir) * 0.05;
	float gust = sin(t * 0.35 - phase * 2.0) * 0.5 + 0.5;
	float sway = sin(t * 1.4 - phase * 6.0 + origin.x * 0.13) * 0.6 + sin(t * 2.3 + origin.z * 0.21) * 0.25;
	float bend = (0.4 + gust * 0.8) * wind_strength;
	vec3 offset = vec3(dir.x, 0.0, dir.y) * (bend * 0.6 + sway * bend) * weight;
	offset.y -= abs(bend) * weight * 0.15;
	return offset;
}

float wind_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float wind_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(wind_hash(i), wind_hash(i + vec2(1.0, 0.0)), u.x),
			mix(wind_hash(i + vec2(0.0, 1.0)), wind_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
