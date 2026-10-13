shader_type canvas_item;

// The island map (map_view.gd), drawn from the terrain data: sea shaded by depth,
// beaches, grass, rock on steep ground, lakes and rivers, hill shading and 10 m
// contour lines. North (-Z) is up.
// terrain: R = height, B = water surface (both as fractions of max_height), G = lake /
// river coverage. view_origin / view_scale pick the part shown (1 = whole map).

uniform sampler2D terrain : filter_linear, repeat_disable;
uniform float max_height = 90.0;
uniform float water_level = 0.08;
uniform float beach_height = 2.4;
uniform float cell_size = 2.0;
uniform float map_size = 257.0;
uniform vec2 view_origin = vec2(0.0);
uniform float view_scale = 1.0;

uniform vec3 deep_sea : source_color = vec3(0.07, 0.17, 0.32);
uniform vec3 shallow_sea : source_color = vec3(0.36, 0.66, 0.72);
uniform vec3 sand : source_color = vec3(0.90, 0.84, 0.66);
uniform vec3 lowland : source_color = vec3(0.38, 0.56, 0.28);
uniform vec3 upland : source_color = vec3(0.55, 0.60, 0.38);
uniform vec3 rock : source_color = vec3(0.56, 0.52, 0.47);
uniform vec3 fresh_water : source_color = vec3(0.24, 0.55, 0.78);

float height_at(vec2 uv) {
	return texture(terrain, uv).r * max_height;
}

// 1 on the line where `c` crosses a whole number, about a pixel wide at any zoom
float contour(float c) {
	return 1.0 - smoothstep(0.0, fwidth(c) * 1.2, abs(fract(c - 0.5) - 0.5));
}

void fragment() {
	vec2 uv = view_origin + UV * view_scale;
	float sea = water_level * max_height;
	vec4 t = texture(terrain, clamp(uv, vec2(0.0), vec2(1.0)));
	float h = t.r * max_height;
	bool outside = any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)));

	// Slope and hill shading (light from the north-west, as on printed maps)
	float texel = 1.0 / map_size;
	float hx = (height_at(uv + vec2(texel, 0.0)) - height_at(uv - vec2(texel, 0.0))) / (2.0 * cell_size);
	float hz = (height_at(uv + vec2(0.0, texel)) - height_at(uv - vec2(0.0, texel))) / (2.0 * cell_size);
	vec3 n = normalize(vec3(-hx, 1.0, -hz));
	float slope = 1.0 - n.y;
	float shade = clamp(dot(n, normalize(vec3(-1.0, 1.4, -1.0))), 0.0, 1.0);

	vec3 col;
	if (outside || h < sea) {
		float depth = outside ? 40.0 : sea - h;
		col = mix(shallow_sea, deep_sea, smoothstep(0.0, 22.0, depth));
		// Faint line just off the shore
		col = mix(col, vec3(0.85, 0.93, 0.95), (1.0 - smoothstep(0.0, 0.5, depth)) * 0.5);
	} else {
		float above = h - sea;
		col = mix(lowland, upland, smoothstep(10.0, 50.0, above));
		col = mix(col, rock, smoothstep(0.28, 0.42, slope));
		col = mix(sand, col, smoothstep(beach_height - 0.6, beach_height + 0.4, above));
		col *= 0.6 + 0.55 * shade;
		// Contours every 10 m, a little stronger every 50 m
		float minor = contour(above / 10.0);
		float major = contour(above / 50.0);
		col = mix(col, col * 0.62, max(minor * 0.45, major * 0.8));
	}
	// Lakes and rivers
	float fresh = smoothstep(0.35, 0.65, t.g) * (outside ? 0.0 : 1.0);
	col = mix(col, fresh_water * (0.85 + 0.2 * shade), fresh);

	COLOR = vec4(col, 1.0);
}
