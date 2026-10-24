shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// The foam ring of a splash (water_splash.gd), on a unit plane scaled up as it spreads.
// `age` (0..1) thins the ring, breaks it up and fades it out. The foam is patchy (value
// noise around the ring), with some churned water left in the middle.

instance uniform float age = 1.0;
global uniform vec3 daylight;  // day_night.gd: unshaded, so it darkens with the light by hand

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 c = UV * 2.0 - 1.0;
	float r = length(c);
	// Noise around the ring from the direction (not the angle, which would leave a seam)
	vec2 around = c / max(r, 0.0001) * 2.3 + vec2(r * 2.0);
	float n = noise(around + 5.0) * 0.6 + noise(around * 2.7 + 3.1) * 0.4;
	float rr = r + (n - 0.5) * 0.12;
	float width = mix(0.22, 0.08, age);
	float ring = smoothstep(0.9 - width, 0.9 - width * 0.3, rr) * (1.0 - smoothstep(0.9, 0.98, rr));
	ring *= smoothstep(0.25 + age * 0.4, 0.75, n);  // Breaks into patches as it spreads
	float centre = (1.0 - smoothstep(0.0, 0.65, r)) * smoothstep(0.35, 0.8, n) * 0.3 * (1.0 - age);
	ALBEDO = vec3(0.92, 0.96, 1.0) * daylight;
	ALPHA = clamp(ring * 0.6 + centre, 0.0, 1.0) * (1.0 - age);
}
