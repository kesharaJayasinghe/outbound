shader_type spatial;
render_mode world_vertex_coords, diffuse_burley, specular_schlick_ggx, cull_disabled;

// Fruit: berries on the bushes, mangoes and oranges in the trees, and fallen ones
// (proc_mesh.gd). COLOR is the colour, painted per vertex (ripeness, a mango's blush,
// the stalks). UV2.x is the sway weight, matching the plant it hangs on so it stays on.
// Glossy skin, with a little light glowing through it, and a faint glow of its own so it
// still reads in the shade of a canopy. Two-sided for the thin stalks.

#include "res://shaders/wind.gdshaderinc"

void vertex() {
	VERTEX += wind_offset(MODEL_MATRIX[3].xyz, UV2.x, TIME);
}

void fragment() {
	ALBEDO = COLOR.rgb;
	BACKLIGHT = COLOR.rgb * 0.3;
	EMISSION = COLOR.rgb * 0.12;
	ROUGHNESS = 0.35;
	SPECULAR = 0.5;
}
