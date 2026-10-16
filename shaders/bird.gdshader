shader_type spatial;
render_mode cull_disabled;

// Seabirds (birds.gd, beach_birds.gd). The wings flap in here, rotating about the body's
// long axis: UV2.x is how far out along the wing a vertex is (0 = body, 1 = wingtip), and
// the outer wing lags a little behind the inner one, so the stroke whips. On the ground the
// wings fold back along the body and the legs (UV2.y = 1) appear and step.
// COLOR is the plumage. Per bird, INSTANCE_CUSTOM:
//   r = cycle phase (0..1), g = how hard it's flapping (0 = gliding),
//   b = flap rate multiplier in the air, or how fast it's walking (0..1) on the ground,
//   a = perched: 0 flying .. 1 standing (wings folded, legs down)

uniform float flap_rate = 6.5;    // Radians per second
uniform float flap_angle = 0.8;   // Up and down from level (radians)
uniform float step_rate = 11.0;   // Leg swing, radians per second at a walk
const float HIP = -0.03;          // Where the legs join the body (mesh units)

void vertex() {
	float along = UV2.x;
	float perched = INSTANCE_CUSTOM.a;
	float side = sign(VERTEX.x);
	if (along > 0.0) {
		vec3 rest = VERTEX;
		float t = TIME * flap_rate * INSTANCE_CUSTOM.b + INSTANCE_CUSTOM.r * TAU;
		float inner = sin(t);
		float outer = sin(t - 0.7);
		float angle = mix(inner, outer, smoothstep(0.4, 1.0, along)) * flap_angle * INSTANCE_CUSTOM.g;
		float c = cos(angle);
		float s = sin(angle);
		// Rotate in the plane across the body, mirrored for the left wing
		float out_x = abs(VERTEX.x);
		VERTEX.xy = vec2(side * (out_x * c - VERTEX.y * s), out_x * s + VERTEX.y * c);
		float n_out = NORMAL.x * side;
		NORMAL.xy = vec2(side * (n_out * c - NORMAL.y * s), n_out * s + NORMAL.y * c);
		// Folded: laid down along the flanks from the shoulder, the dark tips crossing past
		// the tail (the grey "mantle" of a standing gull)
		vec3 folded = vec3(side * (0.085 - 0.035 * along), 0.075 - 0.045 * along, -0.14 + along * 0.52 + rest.z * 0.3);
		VERTEX = mix(VERTEX, folded, perched);
		NORMAL = normalize(mix(NORMAL, vec3(side * 0.75, 0.65, 0.0), perched));
	}
	if (UV2.y > 0.0) {
		// Legs: tucked away in flight; stepping, the feet swing fore and aft in turn
		float down = smoothstep(0.4, 1.0, perched);
		float swing = sin(TIME * step_rate + INSTANCE_CUSTOM.r * TAU + (side > 0.0 ? PI : 0.0))
				* 0.5 * INSTANCE_CUSTOM.b * down;
		float drop = VERTEX.y - HIP;
		VERTEX.z -= drop * sin(swing);
		VERTEX.y = HIP + drop * cos(swing) * down;
	}
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.85;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;  // Lit properly from below as well as above
	}
}
