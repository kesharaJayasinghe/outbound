shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// GPU grass field. The MultiMesh is a fixed grid of clumps that follows the camera
// (snapped to the grid spacing). Each clump finds its own terrain height, density
// and random variation here, keyed on its world grid cell so nothing "swims".

#include "res://shaders/wind.gdshaderinc"

uniform sampler2D heightmap : filter_nearest, repeat_disable;
uniform sampler2D grass_mask : filter_linear, repeat_disable;
uniform float max_height = 90.0;
uniform float cell_size = 2.0;
uniform float map_size = 257.0;
uniform float spacing = 0.35;
uniform float fade_start = 24.0;
uniform float fade_end = 34.0;
// Spots kept clear around small placed things (builder.gd): xy = world XZ, z = radius
const int MAX_CLEARINGS = 16;
uniform vec4 clearings[MAX_CLEARINGS];
uniform int clearing_count = 0;

uniform vec3 base_color : source_color = vec3(0.04, 0.10, 0.02);
uniform vec3 tip_color : source_color = vec3(0.26, 0.50, 0.10);
uniform vec3 dry_tip_color : source_color = vec3(0.42, 0.52, 0.16);

varying float blade_t;
varying float tint;
varying vec2 world_xz;

// Height at a world XZ position using the same triangle split as the terrain mesh
float terrain_height(vec2 wxz) {
	vec2 g = clamp(wxz / cell_size + (map_size - 1.0) * 0.5, vec2(0.0), vec2(map_size - 1.001));
	ivec2 c = ivec2(floor(g));
	vec2 f = g - vec2(c);
	float h00 = texelFetch(heightmap, c, 0).r;
	float h10 = texelFetch(heightmap, c + ivec2(1, 0), 0).r;
	float h01 = texelFetch(heightmap, c + ivec2(0, 1), 0).r;
	float h11 = texelFetch(heightmap, c + ivec2(1, 1), 0).r;
	float h = (f.x + f.y <= 1.0)
			? h00 + (h10 - h00) * f.x + (h01 - h00) * f.y
			: h11 + (h01 - h11) * (1.0 - f.x) + (h10 - h11) * (1.0 - f.y);
	return h * max_height;
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec2 cell = round(origin.xz / spacing);
	float r1 = wind_hash(cell);
	float r2 = wind_hash(cell + 71.3);
	float r3 = wind_hash(cell + 19.1);
	float r4 = wind_hash(cell + 5.7);

	vec2 jitter = (vec2(r1, r2) - 0.5) * spacing * 1.6;
	vec2 wxz = origin.xz + jitter;
	vec2 uv = (wxz / cell_size + (map_size - 1.0) * 0.5 + 0.5) / map_size;
	float mask = textureLod(grass_mask, uv, 0.0).r;
	// Patchy density so the field has natural clearings and thick tufts
	float patches = wind_value_noise(wxz * 0.09) * 0.6 + wind_value_noise(wxz * 0.31) * 0.4;
	float density = mask * smoothstep(0.2, 0.6, patches + mask * 0.3);

	float dist = length(wxz - CAMERA_POSITION_WORLD.xz);
	float fade = 1.0 - smoothstep(fade_start, fade_end, dist);
	float s = fade * smoothstep(r4 * 0.9, r4 * 0.9 + 0.1, density) * (0.55 + 0.7 * r3) * (0.6 + 0.6 * mask);
	for (int i = 0; i < clearing_count; i++) {
		s *= smoothstep(clearings[i].z * 0.6, clearings[i].z, length(wxz - clearings[i].xy));
	}

	float ang = r1 * 6.2831;
	mat2 rot = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang)));
	vec3 v = VERTEX * s;
	v.xz = rot * v.xz;
	NORMAL.xz = rot * NORMAL.xz;
	v += wind_offset(vec3(wxz.x, 0.0, wxz.y), UV.y * UV.y * s * 0.35, TIME);

	VERTEX = v + vec3(jitter.x, terrain_height(wxz) - origin.y - 0.03, jitter.y);
	blade_t = UV.y;
	tint = r2;
	world_xz = wxz;
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL; // Keep the soft upward normals on both sides of the blade
	}
	float dry = smoothstep(0.45, 0.75, wind_value_noise(world_xz * 0.02) + tint * 0.25);
	vec3 tip = mix(tip_color, dry_tip_color, dry * 0.4) * (0.85 + tint * 0.3);
	vec3 col = mix(base_color, tip, pow(blade_t, 0.7));
	ALBEDO = col;
	BACKLIGHT = col * 0.6;
	AO = mix(0.35, 1.0, blade_t);
	AO_LIGHT_AFFECT = 0.5;
	ROUGHNESS = 0.6;
	SPECULAR = 0.25;
}
