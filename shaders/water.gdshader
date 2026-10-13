shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.10, 0.62, 0.58);
uniform vec3 deep_color : source_color = vec3(0.01, 0.16, 0.28);
uniform float depth_fade = 4.0;   // Metres until water reaches deep colour
uniform float wave_scale = 0.08;
uniform float wave_speed = 0.6;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

varying vec3 world_pos;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float waves(vec2 p, float t) {
	return value_noise(p + vec2(t, t * 0.7)) * 0.6 + value_noise(p * 2.3 - vec2(t * 1.3, t * 0.4)) * 0.4;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Water depth behind this pixel, reconstructed from the depth buffer
	float scene_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	scene_view.xyz /= scene_view.w;
	float water_depth = max(VERTEX.z - scene_view.z, 0.0);
	float depth_t = 1.0 - exp(-water_depth / depth_fade);

	// Animated ripple normal
	float t = TIME * wave_speed;
	vec2 p = world_pos.xz * wave_scale * 10.0;
	float e = 0.1;
	float w0 = waves(p, t);
	float wx = waves(p + vec2(e, 0.0), t);
	float wz = waves(p + vec2(0.0, e), t);
	// Ripples fade out with distance so the far ocean doesn't sparkle with aliasing
	float ripple = 0.15 * (1.0 - smoothstep(40.0, 300.0, length(VERTEX)));
	vec3 n = normalize(vec3((w0 - wx) / e * ripple, 1.0, (w0 - wz) / e * ripple));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	ALBEDO = mix(shallow_color, deep_color, depth_t);
	// Clear at the shoreline, more opaque as it deepens; fresnel adds reflectivity at grazing angles
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALPHA = clamp(mix(0.35, 0.95, depth_t) + fresnel * 0.5, 0.0, 1.0) * smoothstep(0.0, 0.3, water_depth);
	ROUGHNESS = 0.05;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
