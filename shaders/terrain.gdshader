shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Material palette
uniform vec3 grass_lush : source_color = vec3(0.10, 0.24, 0.05);
uniform vec3 grass_dry : source_color = vec3(0.24, 0.34, 0.10);
uniform vec3 dirt_color : source_color = vec3(0.33, 0.24, 0.16);
uniform vec3 rock_light : source_color = vec3(0.47, 0.44, 0.40);
uniform vec3 rock_dark : source_color = vec3(0.26, 0.24, 0.22);
uniform vec3 sand_color : source_color = vec3(0.86, 0.80, 0.64);
uniform vec3 mud_color : source_color = vec3(0.24, 0.21, 0.16);  // Lake and river beds
uniform vec3 snow_color : source_color = vec3(0.93, 0.95, 0.98);

// Set from world_generator.gd
uniform float max_height = 90.0;
uniform float water_level = 9.0;
uniform float beach_height = 2.4;  // Metres above the water that sand reaches

// Thresholds (slope: 0 = flat, 1 = vertical)
uniform float rock_slope = 0.22;
uniform float snow_height_fraction = 2.0; // > 1 disables snow (tropical)
uniform float detail_strength = 0.6;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec2 erosion; // x = drainage flow, y = sediment deposit
varying float inland; // 1 under a lake or river
varying float ambient; // 1 in the open; less inside caves (cave.gd), where sky light can't reach
varying float cave;    // 1 on a cave's own rock (COLOR.a < 0.99): no grass there

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

float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < octaves; i++) {
		sum += amp * value_noise(p);
		p = rot * p * 2.03 + vec2(17.1, 9.2);
		amp *= 0.5;
	}
	return sum;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	erosion = COLOR.rg;
	inland = COLOR.b;
	cave = 1.0 - step(0.99, COLOR.a);
	ambient = mix(1.0, COLOR.a / 0.98, cave);
}

void fragment() {
	vec3 n = normalize(world_normal);
	vec2 xz = world_pos.xz;
	float h = world_pos.y;
	float dist = length(world_pos - CAMERA_POSITION_WORLD);
	// Fade out high-frequency detail with distance to avoid shimmering
	float near_fade = 1.0 - smoothstep(40.0, 160.0, dist);

	// Noise at several scales for natural variation
	float macro = fbm(xz * 0.006, 4);
	float mid = fbm(xz * 0.05, 4);
	float fine = mix(0.5, fbm(xz * 0.7, 3), near_fade);

	float slope = 1.0 - n.y;
	float flow = erosion.x;
	float deposit = erosion.y;

	// --- Grass: lush in valleys and drainage lines, drier on exposed high ground
	float dryness = clamp(macro * 1.2 - 0.3 + (h / max_height) * 0.6 - flow * 0.5, 0.0, 1.0);
	vec3 grass = mix(grass_lush, grass_dry, smoothstep(0.2, 0.8, dryness));
	grass *= 0.8 + 0.4 * mid;
	grass *= 0.85 + 0.3 * fine;

	// --- Bare dirt where sediment collects, on moderate slopes, and in patches
	float dirt_t = smoothstep(0.6, 0.9, deposit + (fine - 0.5) * 0.3) * 0.8;
	dirt_t = max(dirt_t, smoothstep(rock_slope - 0.12, rock_slope, slope) * 0.8);
	// Mottled soil: darker damp patches, lighter dry crust, grass creeping in
	vec3 dirt = dirt_color * (0.7 + 0.35 * fine + 0.25 * mid);
	dirt = mix(dirt, grass * 0.8, smoothstep(0.55, 0.8, fbm(xz * 0.35, 3)) * 0.5);
	vec3 col = mix(grass, dirt, dirt_t);

	// --- Rock on steep slopes, with sedimentary strata bands
	float rock_t = smoothstep(rock_slope, rock_slope + 0.1, slope + (mid - 0.5) * 0.25);
	float strata = sin(h * 1.3 + fbm(xz * 0.02, 3) * 8.0) * 0.5 + 0.5;
	vec3 rock = mix(rock_dark, rock_light, clamp(strata * 0.6 + fine * 0.5 + (macro - 0.5) * 0.4, 0.0, 1.0));
	col = mix(col, rock, rock_t);
	// Caves: bare rock, except the floor (sandy where it's low, from the beach rule below)
	rock_t = max(rock_t, cave * (1.0 - smoothstep(0.6, 0.85, n.y)));
	col = mix(col, rock, cave);

	// --- Sandy / muddy shoreline just above the water
	// Ragged line where the sand gives way to grass
	float beach_top = water_level + beach_height + (mid - 0.5) * 1.6;
	float beach_t = (1.0 - smoothstep(beach_top - 0.6, beach_top + 0.3, h)) * (1.0 - rock_t);
	col = mix(col, sand_color * (0.85 + 0.3 * fine), beach_t);

	// --- Lake and river beds: dark silt with pebbly patches
	vec3 bed = mix(mud_color, rock_dark * 1.2, smoothstep(0.55, 0.8, fine + mid * 0.3)) * (0.85 + 0.3 * fine);
	col = mix(col, bed, smoothstep(0.1, 0.6, inland));

	// --- Snow on high, not-too-steep ground with a ragged snow line
	float snow_line = max_height * snow_height_fraction + (macro - 0.5) * max_height * 0.25;
	float snow_t = smoothstep(snow_line, snow_line + 4.0, h + (fine - 0.5) * 6.0);
	snow_t *= 1.0 - smoothstep(0.35, 0.6, slope);
	col = mix(col, snow_color, snow_t);

	// --- Wetness: darken and gloss drainage channels and the waterline
	float wet = clamp(smoothstep(0.55, 0.9, flow) + (1.0 - smoothstep(water_level, water_level + 0.6, h)) + inland, 0.0, 1.0);
	wet *= 1.0 - snow_t;
	col *= mix(1.0, 0.65, wet);

	// Cheap cavity darkening in gullies
	col *= 1.0 - smoothstep(0.6, 1.0, flow) * 0.15;

	// --- Detail normal: perturb by the gradient of a noise height field
	float e = 0.08;
	vec2 dp = xz * 1.2;
	float d0 = fbm(dp, 3);
	float dx = fbm(dp + vec2(e, 0.0), 3);
	float dz = fbm(dp + vec2(0.0, e), 3);
	float bump = detail_strength * near_fade * mix(0.4, 1.5, rock_t) * (1.0 - snow_t * 0.7);
	vec3 detail_n = normalize(n + vec3(d0 - dx, 0.0, d0 - dz) / e * bump * 0.25);
	NORMAL = normalize((VIEW_MATRIX * vec4(detail_n, 0.0)).xyz);

	ALBEDO = col;
	float rough = mix(0.95, 0.8, rock_t);
	rough = mix(rough, 0.55, snow_t);
	rough = mix(rough, 0.5, wet);
	ROUGHNESS = rough;
	SPECULAR = 0.3;
	AO = ambient;
}
