shader_type sky;

// The sky: the same gradient and sun as Godot's ProceduralSkyMaterial (which this replaces),
// plus a layer of fair-weather clouds. The clouds are 2D noise projected onto a flat layer
// overhead, so they're cheap (no ray marching). They thin out towards the horizon, are lit
// from the sun's side (one extra noise sample towards it) and get a bright rim when they
// pass near the sun. They drift with `cloud_time`, a global shader parameter that
// world_generator.gd advances: using TIME would make Godot re-render the sky's lighting
// cubemap every frame (about three times the cost). The lighting keeps the clouds as they
// were when it was last rendered, which is fine for ambient light and reflections.

uniform vec3 sky_top_color : source_color = vec3(0.16, 0.38, 0.78);
uniform vec3 sky_horizon_color : source_color = vec3(0.62, 0.76, 0.9);
uniform float sky_curve : hint_range(0.0, 1.0) = 0.12;
uniform vec3 ground_bottom_color : source_color = vec3(0.1, 0.22, 0.3);
uniform vec3 ground_horizon_color : source_color = vec3(0.62, 0.76, 0.9);
uniform float ground_curve : hint_range(0.0, 1.0) = 0.02;
uniform float sun_angle_max = 20.0;  // Degrees: the sun's glow fades out this far from it
uniform float sun_curve : hint_range(0.0, 1.0) = 0.15;

global uniform float cloud_time;

group_uniforms clouds;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.38;  // Share of the sky covered
uniform float cloud_softness : hint_range(0.01, 0.5) = 0.18;
uniform float cloud_scale = 0.55;          // Noise frequency on the layer (bigger = smaller clouds)
uniform vec2 cloud_wind = vec2(0.006, 0.002);  // Drift (layer units per second)
uniform vec3 cloud_light : source_color = vec3(1.0, 0.98, 0.95);
uniform vec3 cloud_shade : source_color = vec3(0.58, 0.64, 0.74);
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.92;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float sum = 0.0;
	float amp = 0.5;
	const mat2 turn = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));  // Rotate octaves: hides the grid
	for (int i = 0; i < 5; i++) {
		sum += noise(p) * amp;
		p = turn * p * 2.03 + vec2(1.7, 9.2);
		amp *= 0.5;
	}
	return sum;
}

// Cloud density (0..1) at a point on the layer
float density(vec2 p) {
	float n = fbm(p);
	float cut = 1.0 - cloud_coverage;
	return smoothstep(cut * 0.75, cut * 0.75 + cloud_softness, n);
}

void sky() {
	vec3 dir = EYEDIR;
	float v_angle = acos(clamp(dir.y, -1.0, 1.0));
	vec3 col;
	if (v_angle < PI * 0.5) {
		float c = 1.0 - v_angle / (PI * 0.5);
		col = mix(sky_horizon_color, sky_top_color, clamp(1.0 - pow(1.0 - c, 1.0 / sky_curve), 0.0, 1.0));
	} else {
		float c = (v_angle - PI * 0.5) / (PI * 0.5);
		col = mix(ground_horizon_color, ground_bottom_color, clamp(1.0 - pow(1.0 - c, 1.0 / ground_curve), 0.0, 1.0));
	}

	float sun_glow = 0.0;  // 1 at the sun's disc, fading to 0 at sun_angle_max
	if (LIGHT0_ENABLED) {
		float sun_angle = acos(clamp(dot(LIGHT0_DIRECTION, dir), -1.0, 1.0));
		float glow_max = radians(sun_angle_max);
		if (sun_angle < LIGHT0_SIZE) {
			col = LIGHT0_COLOR * LIGHT0_ENERGY;
			sun_glow = 1.0;
		} else if (sun_angle < glow_max) {
			float c = (sun_angle - LIGHT0_SIZE) / (glow_max - LIGHT0_SIZE);
			float t = clamp(1.0 - pow(1.0 - c, 1.0 / sun_curve), 0.0, 1.0);
			col = mix(LIGHT0_COLOR * LIGHT0_ENERGY, col, t);
			sun_glow = 1.0 - t;
		}
	}

	if (dir.y > 0.0) {
		// Where this view ray meets the cloud layer (flattened near the horizon)
		vec2 p = dir.xz / (dir.y + 0.12) * cloud_scale + cloud_wind * cloud_time;
		float d = density(p);
		if (d > 0.0) {
			// Thicker towards the sun = this side is in the cloud's own shadow
			vec2 to_sun = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION.xz + vec2(0.0001)) * 0.12 : vec2(0.0);
			float toward = density(p + to_sun);
			float lit = clamp(1.0 - (toward - d) * 1.6 - toward * 0.35, 0.0, 1.0);
			vec3 sun_col = LIGHT0_ENABLED ? LIGHT0_COLOR : vec3(1.0);
			vec3 cloud = mix(cloud_shade, cloud_light * sun_col, lit);
			cloud += sun_col * sun_glow * (1.0 - d) * 0.8;  // Bright edges against the sun
			// Fade into the haze at the horizon
			float fade = smoothstep(0.02, 0.22, dir.y);
			cloud = mix(col, cloud, 0.85 + 0.15 * fade);
			col = mix(col, cloud, d * fade * cloud_opacity);
		}
	}
	COLOR = col;
}
