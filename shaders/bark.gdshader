shader_type spatial;
render_mode world_vertex_coords, diffuse_burley;

// Tree trunks and branches. UV.x wraps around the trunk, UV.y is metres along it.
// UV2.x is the sway weight, matching the foliage so leaves stay attached.

#include "res://shaders/wind.gdshaderinc"

uniform vec3 bark_dark : source_color = vec3(0.20, 0.16, 0.12);
uniform vec3 bark_light : source_color = vec3(0.45, 0.40, 0.33);
uniform float ring_strength = 0.0;   // Palm trunk leaf-scar rings
uniform float ring_spacing = 0.18;   // Metres between rings

varying vec2 bark_uv;

void vertex() {
	VERTEX += wind_offset(MODEL_MATRIX[3].xyz, UV2.x, TIME);
	bark_uv = UV;
}

void fragment() {
	// Vertical fibres plus broad blotches
	float fibres = wind_value_noise(vec2(bark_uv.x * 24.0, bark_uv.y * 1.2));
	float blotch = wind_value_noise(bark_uv * vec2(4.0, 0.6));
	float n = fibres * 0.6 + blotch * 0.4;
	float ring = smoothstep(0.75, 1.0, sin(bark_uv.y / ring_spacing * 6.2831 + fibres * 1.5) * 0.5 + 0.5);
	vec3 col = mix(bark_dark, bark_light, n);
	col *= 1.0 - ring * ring_strength * 0.45;
	ALBEDO = col;
	ROUGHNESS = 0.92;
	SPECULAR = 0.2;
}
