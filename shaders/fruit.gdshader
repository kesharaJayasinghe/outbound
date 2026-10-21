shader_type spatial;
render_mode world_vertex_coords, diffuse_burley, specular_schlick_ggx;

// Berries on the bushes (proc_mesh.gd berry_cluster). UV2.x is the sway weight, matching
// the bush's leaf cards so the berries stay on it. COLOR.r is ripeness: unripe green to
// ripe red. Glossy skin, with a little light glowing through it.

#include "res://shaders/wind.gdshaderinc"

uniform vec3 color_unripe : source_color = vec3(0.42, 0.55, 0.16);
uniform vec3 color_ripe : source_color = vec3(0.72, 0.06, 0.08);

varying float ripeness;

void vertex() {
	VERTEX += wind_offset(MODEL_MATRIX[3].xyz, UV2.x, TIME);
	ripeness = COLOR.r;
}

void fragment() {
	vec3 col = mix(color_unripe, color_ripe, ripeness);
	ALBEDO = col;
	BACKLIGHT = col * 0.3;
	ROUGHNESS = 0.3;
	SPECULAR = 0.55;
}
