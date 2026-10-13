shader_type spatial;
render_mode cull_disabled, world_vertex_coords, diffuse_burley, specular_schlick_ggx;

// Leaves, palm fronds and bushes.
// UV2.x = sway weight (bends with the whole plant), UV2.y = leaf flutter weight.
// COLOR.r = per-leaf variation between the young and old colours.

#include "res://shaders/wind.gdshaderinc"

uniform sampler2D leaf_texture : source_color, filter_linear_mipmap, hint_default_white;
uniform vec3 color_young : source_color = vec3(0.22, 0.42, 0.10);
uniform vec3 color_old : source_color = vec3(0.42, 0.42, 0.14);
uniform float alpha_cut = 0.45;
uniform float flutter = 0.06;
uniform float gloss = 0.5;

varying float variation;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	VERTEX += wind_offset(origin, UV2.x, TIME);
	float ph = dot(VERTEX, vec3(1.7, 2.3, 1.1));
	VERTEX += vec3(sin(TIME * 6.0 + ph), sin(TIME * 5.1 + ph * 1.3) * 0.6, cos(TIME * 5.7 + ph))
			* flutter * UV2.y * wind_strength;
	variation = COLOR.r;
}

void fragment() {
	vec4 tex = texture(leaf_texture, UV);
	if (!FRONT_FACING) {
		NORMAL = -NORMAL; // Use the canopy-shaped normals on both sides of each card
	}
	vec3 col = tex.rgb * mix(color_young, color_old, variation) * 1.25;
	ALBEDO = col;
	ALPHA = tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	BACKLIGHT = col * 0.4; // Sunlight glowing through the leaves
	ROUGHNESS = 1.0 - gloss * 0.6;
	SPECULAR = 0.25;
}
