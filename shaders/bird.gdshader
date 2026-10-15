shader_type spatial;
render_mode cull_disabled;

// Seabirds (birds.gd). The wings flap in here, rotating about the body's long axis:
// UV2.x is how far out along the wing a vertex is (0 = body, 1 = wingtip), and the outer
// wing lags a little behind the inner one, so the stroke whips. COLOR is the plumage.
// Per bird, INSTANCE_CUSTOM: r = flap phase (0..1), g = how hard it's flapping
// (0 = gliding), b = flap rate multiplier.

uniform float flap_rate = 6.5;    // Radians per second
uniform float flap_angle = 0.8;   // Up and down from level (radians)

void vertex() {
	float along = UV2.x;
	if (along > 0.0) {
		float t = TIME * flap_rate * INSTANCE_CUSTOM.b + INSTANCE_CUSTOM.r * TAU;
		float inner = sin(t);
		float outer = sin(t - 0.7);
		float angle = mix(inner, outer, smoothstep(0.4, 1.0, along)) * flap_angle * INSTANCE_CUSTOM.g;
		float side = sign(VERTEX.x);
		float c = cos(angle);
		float s = sin(angle);
		// Rotate in the plane across the body, mirrored for the left wing
		float out_x = abs(VERTEX.x);
		VERTEX.xy = vec2(side * (out_x * c - VERTEX.y * s), out_x * s + VERTEX.y * c);
		float n_out = NORMAL.x * side;
		NORMAL.xy = vec2(side * (n_out * c - NORMAL.y * s), n_out * s + NORMAL.y * c);
	}
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.85;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;  // Lit properly from below as well as above
	}
}
