shader_type sky;

// The sky: a gradient like Godot's ProceduralSkyMaterial (which this replaces), the sun,
// the moon and stars, and a layer of fair-weather clouds. day_night.gd drives it.
//
// The clouds are 2D noise projected onto a flat layer overhead, so they're cheap (no ray
// marching). They thin out towards the horizon, are lit from the sun's (or at night the
// moon's) side with one extra noise sample towards it, and get a bright rim when they
// pass near the sun.
//
// What moves every frame (cloud drift, sun and moon) comes from global shader parameters,
// and this shader doesn't read TIME or the LIGHT0_* built-ins: either would make Godot
// re-render the sky's lighting cubemap every frame (about three times the cost). The
// colours are material uniforms, which day_night.gd only updates every so often, so the
// cubemap (ambient light and reflections) is re-rendered then.

global uniform float cloud_time;
global uniform vec3 sun_direction;   // Towards the sun (it can be below the horizon)
global uniform vec3 moon_direction;

uniform vec3 sky_top_color : source_color = vec3(0.16, 0.38, 0.78);
uniform vec3 sky_horizon_color : source_color = vec3(0.62, 0.76, 0.9);
uniform float sky_curve : hint_range(0.0, 1.0) = 0.12;
uniform vec3 ground_bottom_color : source_color = vec3(0.1, 0.22, 0.3);
uniform vec3 ground_horizon_color : source_color = vec3(0.62, 0.76, 0.9);
uniform float ground_curve : hint_range(0.0, 1.0) = 0.02;
uniform vec3 twilight_color : source_color = vec3(0.0);  // Sunrise / sunset glow on the horizon, on the sun's side

group_uniforms sun;
uniform vec3 sun_color = vec3(1.3, 1.22, 1.09);  // Disc colour times brightness
uniform float sun_size = 0.006;       // Disc radius (radians)
uniform float sun_angle_max = 20.0;   // Degrees: the sun's glow fades out this far from it
uniform float sun_curve : hint_range(0.0, 1.0) = 0.15;

group_uniforms night;
uniform float stars : hint_range(0.0, 1.0) = 0.0;  // How much of the starfield shows
uniform vec3 moon_color = vec3(0.0);   // Disc colour times brightness (0 = not shown)
uniform float moon_size = 0.014;       // Disc radius (radians); bigger than life, as in films

group_uniforms clouds;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.38;  // Share of the sky covered
uniform float cloud_softness : hint_range(0.01, 0.5) = 0.18;
uniform float cloud_scale = 0.55;          // Noise frequency on the layer (bigger = smaller clouds)
uniform vec2 cloud_wind = vec2(0.006, 0.002);  // Drift (layer units per second)
uniform vec3 cloud_light : source_color = vec3(1.0, 0.98, 0.95);  // Lit side
uniform vec3 cloud_shade : source_color = vec3(0.58, 0.64, 0.74); // Side away from the light
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.92;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 hash3(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
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

// Stars: at most one per cell of a 3D grid around the viewer, a soft point about a pixel
// across at 720p, twinkling slowly
float starfield(vec3 dir) {
	vec3 p = dir * 110.0;
	vec3 cell = floor(p);
	vec3 h = hash3(cell);
	if (h.x < 0.93) {
		return 0.0;
	}
	vec3 at = cell + 0.25 + h * 0.5;
	float d = length(p - at);
	float bright = pow((h.x - 0.93) / 0.07, 3.0) * 1.6 + 0.08;
	float twinkle = 0.75 + 0.25 * sin(cloud_time * (1.5 + h.y * 2.5) + h.z * 6.28);
	return bright * twinkle * (1.0 - smoothstep(0.0, 0.16, d));
}

void sky() {
	vec3 dir = EYEDIR;
	float v_angle = acos(clamp(dir.y, -1.0, 1.0));
	vec3 col;
	if (v_angle < PI * 0.5) {
		float c = 1.0 - v_angle / (PI * 0.5);
		float up = clamp(1.0 - pow(1.0 - c, 1.0 / sky_curve), 0.0, 1.0);
		vec3 horizon = sky_horizon_color;
		// Sunrise and sunset: warm on the sun's side of the horizon, reaching a little way up
		vec2 flat_sun = normalize(sun_direction.xz + vec2(0.0001));
		vec2 flat_dir = normalize(dir.xz + vec2(0.0001));
		float toward = pow(dot(flat_sun, flat_dir) * 0.5 + 0.5, 3.0);
		horizon += twilight_color * toward;
		col = mix(horizon, sky_top_color, up);
		col += twilight_color * toward * 0.35 * (1.0 - smoothstep(0.0, 0.45, dir.y));
	} else {
		float c = (v_angle - PI * 0.5) / (PI * 0.5);
		col = mix(ground_horizon_color, ground_bottom_color, clamp(1.0 - pow(1.0 - c, 1.0 / ground_curve), 0.0, 1.0));
	}

	if (dir.y > 0.0 && stars > 0.0 && !AT_CUBEMAP_PASS) {
		col += vec3(0.85, 0.9, 1.0) * starfield(dir) * stars * smoothstep(0.0, 0.25, dir.y);
	}

	// The moon: a mottled disc with a faint halo
	float moon_angle = acos(clamp(dot(moon_direction, dir), -1.0, 1.0));
	float moon_lit = max(max(moon_color.r, moon_color.g), moon_color.b);
	if (moon_lit > 0.0) {
		if (moon_angle < moon_size) {
			vec3 side = normalize(cross(moon_direction, vec3(0.0, 1.0, 0.0)) + vec3(0.0001));
			vec3 up = cross(side, moon_direction);
			vec2 face = vec2(dot(dir, side), dot(dir, up)) / moon_size;
			float maria = smoothstep(0.45, 0.7, fbm(face * 2.2 + 4.0));
			float edge = smoothstep(1.0, 0.85, moon_angle / moon_size);
			col = mix(col, moon_color * (1.0 - 0.3 * maria), edge);
		} else {
			col += moon_color * 0.08 * exp(-(moon_angle - moon_size) * 25.0);
		}
	}

	float sun_glow = 0.0;  // 1 at the sun's disc, fading to 0 at sun_angle_max
	float sun_angle = acos(clamp(dot(sun_direction, dir), -1.0, 1.0));
	float glow_max = radians(sun_angle_max);
	float sun_lit = max(max(sun_color.r, sun_color.g), sun_color.b);
	if (sun_lit > 0.0) {
		if (sun_angle < sun_size) {
			col = sun_color;
			sun_glow = 1.0;
		} else if (sun_angle < glow_max) {
			float c = (sun_angle - sun_size) / (glow_max - sun_size);
			float t = clamp(1.0 - pow(1.0 - c, 1.0 / sun_curve), 0.0, 1.0);
			col = mix(sun_color, col, t);
			sun_glow = 1.0 - t;
		}
	}

	if (dir.y > 0.0) {
		// Where this view ray meets the cloud layer (flattened near the horizon)
		vec2 p = dir.xz / (dir.y + 0.12) * cloud_scale + cloud_wind * cloud_time;
		float d = density(p);
		if (d > 0.0) {
			// Thicker towards the light = this side is in the cloud's own shadow
			vec3 light_dir = sun_direction.y > -0.05 ? sun_direction : moon_direction;
			vec2 to_light = normalize(light_dir.xz + vec2(0.0001)) * 0.12;
			float toward = density(p + to_light);
			float lit = clamp(1.0 - (toward - d) * 1.6 - toward * 0.35, 0.0, 1.0);
			vec3 cloud = mix(cloud_shade, cloud_light, lit);
			cloud += sun_color * sun_glow * (1.0 - d) * 0.6;  // Bright edges against the sun
			// Fade into the haze at the horizon
			float fade = smoothstep(0.02, 0.22, dir.y);
			cloud = mix(col, cloud, 0.85 + 0.15 * fade);
			col = mix(col, cloud, d * fade * cloud_opacity);
		}
	}
	COLOR = col;
}
