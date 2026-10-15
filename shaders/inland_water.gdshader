shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

// Lakes and rivers. COLOR.rg = downstream direction (0.5 = none), COLOR.b = flow speed
// (0 = still lake, 1 = rapids), COLOR.a = water coverage (fades the edges, and the river
// into the sea at its mouth). Ripples drift downstream using the two-phase flow-map
// technique, so the pattern moves without stretching over time.

#include "res://shaders/wind.gdshaderinc"

uniform vec3 shallow_color : source_color = vec3(0.20, 0.42, 0.32);
uniform vec3 deep_color : source_color = vec3(0.03, 0.12, 0.12);
uniform vec3 foam_color : source_color = vec3(0.85, 0.9, 0.88);
uniform float depth_fade = 2.0;      // Metres until the water reaches its deep colour
uniform float flow_rate = 3.0;       // How far ripples drift per flow cycle at full speed
uniform float cycle_speed = 0.5;     // Flow cycles per second. Must be the same everywhere:
                                     // a cycle that varies with local speed drifts out of
                                     // phase over time and shows as stripes.
uniform float ripple_scale = 0.9;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

varying vec3 world_pos;
varying vec3 flow;
varying float coverage;

float ripples(vec2 p) {
	return wind_value_noise(p) * 0.6 + wind_value_noise(p * 2.3 + 7.1) * 0.4;
}

// Ripple height at a point, drifting along `dir` (two offset phases cross-faded)
float flowing(vec2 p, vec2 dir, float t) {
	float ph0 = fract(t);
	float ph1 = fract(t + 0.5);
	float w = abs(1.0 - 2.0 * ph0);
	vec2 still = vec2(TIME * 0.15, TIME * 0.1);  // Lakes still shimmer a little
	float a = ripples(p - dir * ph0 * flow_rate + still);
	float b = ripples(p - dir * ph1 * flow_rate + still + 3.7);
	return mix(b, a, w);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	flow = vec3(COLOR.rg * 2.0 - 1.0, COLOR.b);
	coverage = COLOR.a;
}

void fragment() {
	// Water depth behind this pixel, reconstructed from the depth buffer
	float scene_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	scene_view.xyz /= scene_view.w;
	float water_depth = max(VERTEX.z - scene_view.z, 0.0);
	float depth_t = 1.0 - exp(-water_depth / depth_fade);

	vec2 dir = flow.xy * flow.z;  // Faster water drifts further per cycle
	float t = TIME * cycle_speed;
	vec2 p = world_pos.xz * ripple_scale;
	float e = 0.08;
	float r0 = flowing(p, dir, t);
	float rx = flowing(p + vec2(e, 0.0), dir, t);
	float rz = flowing(p + vec2(0.0, e), dir, t);
	float strength = mix(0.12, 0.3, flow.z);
	vec3 n = normalize(vec3((r0 - rx) / e * strength, 1.0, (r0 - rz) / e * strength));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	// White water where the river runs fast
	float foam = smoothstep(0.45, 0.9, flow.z) * smoothstep(0.55, 0.8, r0);
	vec3 col = mix(shallow_color, deep_color, depth_t);
	ALBEDO = mix(col, foam_color, foam);
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALPHA = clamp(mix(0.25, 0.9, depth_t) + fresnel * 0.4 + foam * 0.6, 0.0, 1.0)
			* smoothstep(0.0, 0.15, water_depth) * smoothstep(0.0, 0.7, coverage);
	ROUGHNESS = mix(0.05, 0.4, foam);
	SPECULAR = 0.5;
}
