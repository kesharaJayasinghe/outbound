shader_type spatial;
render_mode diffuse_burley;

// Scattered boulders: triplanar noise colouring with moss on upward-facing surfaces.

#include "res://shaders/wind.gdshaderinc"

uniform vec3 rock_light : source_color = vec3(0.46, 0.43, 0.39);
uniform vec3 rock_dark : source_color = vec3(0.22, 0.21, 0.19);
uniform vec3 moss_color : source_color = vec3(0.18, 0.30, 0.08);
uniform float moss_amount = 0.8;

varying vec3 world_pos;
varying vec3 world_normal;

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * wind_value_noise(p);
		p = p * 2.07 + vec2(13.1, 7.7);
		a *= 0.5;
	}
	return s;
}

float triplanar(vec3 p, vec3 w) {
	return fbm(p.yz) * w.x + fbm(p.xz) * w.y + fbm(p.xy) * w.z;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(world_normal);
	vec3 w = pow(abs(n), vec3(4.0));
	w /= w.x + w.y + w.z;
	float coarse = triplanar(world_pos * 1.3, w);
	float fine = triplanar(world_pos * 7.0, w);

	vec3 col = mix(rock_dark, rock_light, clamp(coarse * 1.2 - 0.1 + (fine - 0.5) * 0.4, 0.0, 1.0));
	float moss = smoothstep(0.45, 0.8, n.y + (coarse - 0.5) * 0.6) * moss_amount;
	col = mix(col, moss_color * (0.7 + 0.6 * fine), moss);

	// Detail bump from the fine noise
	float e = 0.05;
	vec3 p = world_pos * 7.0;
	float dx = triplanar(p + vec3(e, 0.0, 0.0), w) - fine;
	float dy = triplanar(p + vec3(0.0, e, 0.0), w) - fine;
	float dz = triplanar(p + vec3(0.0, 0.0, e), w) - fine;
	vec3 bumped = normalize(n - vec3(dx, dy, dz) / e * 0.08);
	NORMAL = normalize((VIEW_MATRIX * vec4(bumped, 0.0)).xyz);

	ALBEDO = col;
	ROUGHNESS = mix(0.85, 0.95, moss);
	SPECULAR = 0.3;
}
