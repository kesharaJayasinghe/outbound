extends Node3D

## Seabirds circling over the coasts in loose flocks: gulls with white bodies, grey wings
## and dark tips. Each flock wheels around a point above the shore that drifts slowly;
## the birds glide most of the time, banking into the turn, and flap now and then
## (more when climbing). All birds are one MultiMesh, moved here every frame; the wings
## flap in shaders/bird.gdshader.

const BIRD_SHADER = preload("res://shaders/bird.gdshader")

const FLOCKS = 5
const BIRDS_PER_FLOCK = Vector2i(4, 6)
const ALTITUDE = Vector2(14.0, 32.0)  # Above the sea (metres)
const TERRAIN_CLEARANCE = 10.0        # Never lower than this over the ground
const CIRCLE_RADIUS = Vector2(12.0, 38.0)
const SIZE = 1.25                     # Mesh scale: about 1.9 m across the wings
const SPEED = Vector2(8.0, 11.0)      # Metres per second
const WANDER = 30.0                   # How far a flock's centre drifts (metres)

var gen: Node3D
var rng := RandomNumberGenerator.new()
var flocks: Array[Dictionary] = []   # {centre, turn (+1 / -1), wander_phase}
var birds: Array[Dictionary] = []    # Per bird: its flock, path and flapping state
var multimesh := MultiMesh.new()
var time := 0.0


func build(generator: Node3D) -> void:
	gen = generator
	rng.seed = gen.terrain_seed + 6151
	_place_flocks()

	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = _bird_mesh()
	multimesh.instance_count = birds.size()
	var world_half: float = (gen.size - 1) * 0.5 * gen.cell_size
	multimesh.custom_aabb = AABB(Vector3(-world_half, 0.0, -world_half), Vector3(world_half * 2.0, 200.0, world_half * 2.0))
	var instance := MultiMeshInstance3D.new()
	instance.name = "Flocks"
	instance.multimesh = multimesh
	var mat := ShaderMaterial.new()
	mat.shader = BIRD_SHADER
	instance.material_override = mat
	add_child(instance)
	_update(0.0)


## Flocks over the shore, spread around the coastline (farthest-point sampling), the
## first one by the waterfall if there is one
func _place_flocks() -> void:
	var coast := _coast_points()
	if coast.is_empty():
		return
	var chosen := PackedVector3Array()
	var first := coast[rng.randi() % coast.size()]
	if not gen.waterfalls.is_empty():
		var top: Vector3 = gen.waterfalls[0].top
		first = coast[0]
		for p in coast:
			if Vector2(p.x - top.x, p.z - top.z).length() < Vector2(first.x - top.x, first.z - top.z).length():
				first = p
	chosen.append(first)
	while chosen.size() < FLOCKS:
		var best := coast[0]
		var best_d := -1.0
		for p in coast:
			var d := INF
			for c in chosen:
				d = minf(d, p.distance_squared_to(c))
			if d > best_d:
				best_d = d
				best = p
		chosen.append(best)

	var sea: float = gen.water_surface()
	for c in chosen:
		var flock := {
			"centre": Vector3(c.x, sea, c.z),
			"turn": 1.0 if rng.randf() < 0.5 else -1.0,
			"wander_phase": rng.randf() * TAU,
		}
		flocks.append(flock)
		for k in rng.randi_range(BIRDS_PER_FLOCK.x, BIRDS_PER_FLOCK.y):
			birds.append({
				"flock": flock,
				"angle": rng.randf() * TAU,
				"radius": rng.randf_range(CIRCLE_RADIUS.x, CIRCLE_RADIUS.y),
				"altitude": rng.randf_range(ALTITUDE.x, ALTITUDE.y),
				"speed": rng.randf_range(SPEED.x, SPEED.y),
				"phase": rng.randf(),         # For the slow radius / height drift and the flap cycle
				"flap": 0.0,
				"flap_rate": rng.randf_range(0.85, 1.15),
				"flap_timer": rng.randf_range(0.0, 6.0),
				"flapping": false,
				"last": Vector3.ZERO,
			})


## Shore points: land vertices next to the sea (every fourth vertex is plenty)
func _coast_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	var n: int = gen.size
	var half := (n - 1) * 0.5
	var heights: PackedFloat32Array = gen.heights
	var water: float = gen.water_level
	for z in range(4, n - 4, 4):
		for x in range(4, n - 4, 4):
			var i := z * n + x
			if heights[i] < water:
				continue
			if heights[i - 4] < water or heights[i + 4] < water or heights[i - 4 * n] < water or heights[i + 4 * n] < water:
				points.append(Vector3((x - half) * gen.cell_size, 0.0, (z - half) * gen.cell_size))
	return points


func _process(delta: float) -> void:
	_update(delta)


func _update(delta: float) -> void:
	time += delta
	for k in birds.size():
		var b: Dictionary = birds[k]
		var flock: Dictionary = b.flock
		var phase: float = b.phase * TAU
		# The flock's centre drifts slowly; each bird's circle breathes in and out
		var wander_t: float = time * 0.02 + flock.wander_phase
		var centre: Vector3 = flock.centre + Vector3(sin(wander_t) + 0.5 * sin(wander_t * 2.3), 0.0, cos(wander_t * 0.8) + 0.5 * sin(wander_t * 1.7)) * WANDER * 0.6
		var radius: float = b.radius * (1.0 + 0.25 * sin(time * 0.07 + phase))
		b.angle += flock.turn * b.speed / radius * delta
		var pos := centre + Vector3(cos(b.angle), 0.0, sin(b.angle)) * radius
		var ground: float = gen.get_height(pos.x, pos.z)
		pos.y = maxf(centre.y + b.altitude + 4.0 * sin(time * 0.13 + phase), ground + TERRAIN_CLEARANCE)

		var last: Vector3 = b.last
		var velocity: Vector3 = (pos - last) / delta if delta > 0.0 and last != Vector3.ZERO else \
				Vector3(-sin(b.angle), 0.0, cos(b.angle)) * flock.turn * b.speed
		b.last = pos

		# Flap in bursts, and whenever climbing; otherwise glide
		b.flap_timer -= delta
		if b.flap_timer <= 0.0:
			b.flapping = not b.flapping
			b.flap_timer = rng.randf_range(1.0, 2.5) if b.flapping else rng.randf_range(3.0, 8.0)
		var target := 1.0 if b.flapping or velocity.y > 0.8 else 0.0
		b.flap = move_toward(b.flap, target, delta * 2.5)

		# Face along the path, banked into the turn (wings tilted down towards the centre)
		var forward: Vector3 = velocity.normalized() if velocity.length() > 0.01 else Vector3.FORWARD
		var inward := Vector3(centre.x - pos.x, 0.0, centre.z - pos.z).normalized()
		var bank: float = minf(atan(b.speed * b.speed / (radius * 9.8)) * 1.6, 0.9)
		var up := (Vector3.UP + inward * tan(bank)).normalized()
		multimesh.set_instance_transform(k, Transform3D(Basis.looking_at(forward, up).scaled(Vector3.ONE * SIZE), pos))
		multimesh.set_instance_custom_data(k, Color(b.phase, b.flap, b.flap_rate, 0.0))


## A gull, about 1.5 m across the wings, facing -Z. Wings bend up at the elbow, and the
## tips sweep back (the gull "M"). UV2.x: 0 on the body, out to 1 at the wingtips.
static func _bird_mesh() -> ArrayMesh:
	var white := Color(0.95, 0.95, 0.93)
	var grey := Color(0.7, 0.72, 0.75)
	var black := Color(0.12, 0.12, 0.13)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tri := func(a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
		var n := (c - a).cross(b - a).normalized()
		for v in [[a, ca], [b, cb], [c, cc]]:
			st.set_normal(n)
			st.set_color(v[1])
			st.set_uv2(Vector2(absf((v[0] as Vector3).x) / 0.75, 0.0))
			st.add_vertex(v[0])

	# Body: a spindle from beak to tail, and a fanned tail
	var nose := Vector3(0.0, 0.0, -0.32)
	var tail := Vector3(0.0, 0.01, 0.3)
	var top := Vector3(0.0, 0.055, -0.05)
	var bottom := Vector3(0.0, -0.05, -0.05)
	var left := Vector3(-0.06, 0.0, -0.05)
	var right := Vector3(0.06, 0.0, -0.05)
	for end in [nose, tail]:
		for pair in [[top, right], [right, bottom], [bottom, left], [left, top]]:
			if end == nose:
				tri.call(end, pair[0], pair[1], white, white, white)
			else:
				tri.call(end, pair[1], pair[0], white, white, white)
	tri.call(Vector3(0.0, 0.01, 0.2), Vector3(0.09, 0.01, 0.38), Vector3(-0.09, 0.01, 0.38), white, white, white)

	# Wings: inner panel to the raised elbow, outer panel to the swept-back tip
	for side in [-1.0, 1.0]:
		var root_front := Vector3(0.04 * side, 0.02, -0.12)
		var root_back := Vector3(0.04 * side, 0.02, 0.1)
		var elbow_front := Vector3(0.38 * side, 0.07, -0.1)
		var elbow_back := Vector3(0.36 * side, 0.07, 0.12)
		var tip_front := Vector3(0.72 * side, 0.0, -0.01)
		var tip := Vector3(0.75 * side, -0.01, 0.1)
		tri.call(root_front, elbow_front, elbow_back, grey, grey, grey)
		tri.call(root_front, elbow_back, root_back, grey, grey, grey)
		tri.call(elbow_front, tip_front, tip, grey, black, black)
		tri.call(elbow_front, tip, elbow_back, grey, black, grey)
	return st.commit()
