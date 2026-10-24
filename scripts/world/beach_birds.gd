extends Node3D

## Gulls on the beaches: small groups on low, flat sand by the sea. They stand, waddle a
## few steps, peck at the sand and turn about. Come too close (closer still if you're
## running) and one gives an alarm call and takes off away from you, out over the water,
## and its neighbours follow a moment later. After a while in the air each picks a beach
## well away from the player and lands there, so the beaches never empty for good.
## They share the flying gulls' mesh and shader (birds.gd, bird.gdshader); only birds
## within SIMULATE_RANGE of the player are updated.

const BIRDS = preload("res://scripts/world/birds.gd")
const BIRD_SHADER = preload("res://shaders/bird.gdshader")

const GROUPS = 6
const PER_GROUP = Vector2i(2, 4)
const GROUP_SPREAD = 4.0          # Metres around a group's spot
const SIZE = 1.25                 # As the flying gulls
const STAND_HEIGHT = 0.2 * SIZE   # Feet to body origin
const SPOOK_DISTANCE = 8.0        # Metres; doubled when the player runs
const PANIC_RADIUS = 7.0          # Neighbours this close take off too
const WALK_SPEED = 0.55
const HOME_RANGE = 5.0            # How far a bird strays from its spot on foot
const FLIGHT_SPEED = 8.5
const CRUISE_HEIGHT = 14.0        # Above the ground or sea, between beaches
const LAND_FROM = 25.0            # Start gliding down this far from the landing spot
const LANDING_HOP = Vector2(50.0, 200.0)  # How far away (metres) a new beach is picked
const TURN_RATE = 1.4             # Radians per second in the air
const SIMULATE_RANGE = 220.0
const ALARM_PITCH = Vector2(1.15, 1.3)

enum State { STAND, WALK, PECK, TAKE_OFF, FLY, LAND }

var gen: Node3D
var player: Node3D
var rng := RandomNumberGenerator.new()
var spots := PackedVector3Array()   # Low, flat sand by the sea (on the ground)
var birds: Array[Dictionary] = []
var multimesh := MultiMesh.new()
var alarms: Array[AudioStreamPlayer3D] = []
var time := 0.0


func build(generator: Node3D) -> void:
	gen = generator
	player = gen.get_node_or_null("Player") as Node3D
	rng.seed = gen.terrain_seed + 6173
	spots = _beach_spots()
	if spots.is_empty():
		return
	_place_groups()

	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.mesh = BIRDS._bird_mesh()
	multimesh.instance_count = birds.size()
	var world_half: float = (gen.size - 1) * 0.5 * gen.cell_size
	multimesh.custom_aabb = AABB(Vector3(-world_half, -20.0, -world_half), Vector3(world_half * 2.0, 200.0, world_half * 2.0))
	var instance := MultiMeshInstance3D.new()
	instance.name = "BeachGulls"
	instance.multimesh = multimesh
	var mat := ShaderMaterial.new()
	mat.shader = BIRD_SHADER
	instance.material_override = mat
	add_child(instance)

	for k in 2:
		var voice := AudioStreamPlayer3D.new()
		voice.bus = &"Ambience"
		voice.unit_size = 14.0
		voice.max_distance = 180.0
		add_child(voice)
		alarms.append(voice)
	for k in birds.size():
		_pose(k, birds[k], 0.0)


## Every other vertex that's sandy beach: low, flat, dry, open sand next to the sea
func _beach_spots() -> PackedVector3Array:
	var points := PackedVector3Array()
	var n: int = gen.size
	var half := (n - 1) * 0.5
	var heights: PackedFloat32Array = gen.heights
	var sea: float = gen.water_surface()
	for z in range(2, n - 2, 2):
		for x in range(2, n - 2, 2):
			var i := z * n + x
			var h: float = heights[i] * gen.max_height
			if h < sea + 0.4 or h > sea + 1.8 or gen.normal_map[i].y < 0.96 or gen.inland_mask[i] > 0.0:
				continue
			var p := Vector3((x - half) * gen.cell_size, h, (z - half) * gen.cell_size)
			if gen._in_cave_box(x, z):
				continue
			points.append(p)
	return points


## Groups spread around the beaches (farthest-point sampling), a few birds each
func _place_groups() -> void:
	var chosen := PackedVector3Array([spots[rng.randi() % spots.size()]])
	while chosen.size() < mini(GROUPS, spots.size()):
		var best := spots[0]
		var best_d := -1.0
		for p in spots:
			var d := INF
			for c in chosen:
				d = minf(d, p.distance_squared_to(c))
			if d > best_d:
				best_d = d
				best = p
		chosen.append(best)
	for c in chosen:
		for k in rng.randi_range(PER_GROUP.x, PER_GROUP.y):
			var at := _ground_spot(c)
			birds.append({
				"state": State.STAND, "timer": rng.randf_range(0.5, 4.0),
				"pos": at, "home": c,
				"heading": Vector3.FORWARD.rotated(Vector3.UP, rng.randf() * TAU),
				"phase": rng.randf(), "perched": 1.0, "flap": 0.0, "walk": 0.0,
				"peck": 0.0, "turn": 0.0, "speed": 0.0, "target": Vector3.ZERO,
			})


func _process(delta: float) -> void:
	time += delta
	if birds.is_empty():
		return
	var from := player.global_position if player else Vector3(INF, INF, INF)
	var running := player != null and Vector2(player.velocity.x, player.velocity.z).length() > 5.0
	for k in birds.size():
		var b: Dictionary = birds[k]
		var airborne: bool = b.state >= State.TAKE_OFF
		if not airborne and (b.pos as Vector3).distance_to(from) > SIMULATE_RANGE:
			continue
		if not airborne and (b.pos as Vector3).distance_to(from) < SPOOK_DISTANCE * (2.0 if running else 1.0):
			_take_off(k, from, true)
		_step(b, delta, from)
		_pose(k, b, delta)


# --- Behaviour -------------------------------------------------------------------------

func _step(b: Dictionary, delta: float, from: Vector3) -> void:
	b.timer -= delta
	match b.state:
		State.STAND, State.PECK:
			b.perched = move_toward(b.perched, 1.0, delta * 2.5)
			b.walk = move_toward(b.walk, 0.0, delta * 3.0)
			b.peck = (absf(sin(time * 9.0 + b.phase * TAU)) if b.state == State.PECK else 0.0)
			if b.timer <= 0.0:
				_next_ground_action(b)
		State.WALK:
			b.perched = move_toward(b.perched, 1.0, delta * 2.5)
			var next: Vector3 = b.pos + (b.heading as Vector3) * WALK_SPEED * delta
			if not _walkable(next) or Vector2(next.x - b.home.x, next.z - b.home.z).length() > HOME_RANGE:
				# Blocked (the waterline, or too far from home): turn round and stop for a
				# moment. Turning again every frame would just spin it on the spot.
				b.heading = (b.heading as Vector3).rotated(Vector3.UP, PI * rng.randf_range(0.6, 1.4))
				b.state = State.STAND
				b.timer = rng.randf_range(0.5, 1.5)
			else:
				next.y = gen.get_height(next.x, next.z)
				b.pos = next
			b.walk = move_toward(b.walk, 1.0, delta * 4.0)
			if b.timer <= 0.0:
				_next_ground_action(b)
		State.TAKE_OFF:
			# A couple of quick steps and up, wings opening
			b.perched = move_toward(b.perched, 0.0, delta * 3.5)
			b.flap = 1.0
			b.speed = move_toward(b.speed, FLIGHT_SPEED, delta * 6.0)
			b.pos += (b.heading as Vector3) * b.speed * delta + Vector3.UP * 3.5 * delta
			if b.timer <= 0.0:
				b.state = State.FLY
				b.timer = rng.randf_range(3.0, 6.0)   # Keep going away before turning for land
				b.target = Vector3.ZERO
		State.FLY, State.LAND:
			_fly(b, delta, from)


func _next_ground_action(b: Dictionary) -> void:
	var r := rng.randf()
	if r < 0.45:
		b.state = State.WALK
		b.timer = rng.randf_range(1.0, 3.0)
		b.heading = (b.heading as Vector3).rotated(Vector3.UP, rng.randf_range(-1.2, 1.2))
	elif r < 0.7:
		b.state = State.PECK
		b.timer = rng.randf_range(0.8, 1.6)
	else:
		b.state = State.STAND
		b.timer = rng.randf_range(1.0, 4.0)
		if r > 0.9:
			b.heading = (b.heading as Vector3).rotated(Vector3.UP, rng.randf_range(-2.0, 2.0))


## A random spot within GROUP_SPREAD of a beach spot that the bird can walk from. The
## beach spot itself is always walkable, so it's the fallback.
func _ground_spot(centre: Vector3) -> Vector3:
	for attempt in 12:
		var at := centre + Vector3(rng.randf_range(-1, 1), 0.0, rng.randf_range(-1, 1)) * GROUP_SPREAD
		if _walkable(at):
			at.y = gen.get_height(at.x, at.z)
			return at
	return centre


func _walkable(p: Vector3) -> bool:
	var h: float = gen.get_height(p.x, p.z)
	return h > gen.water_surface() + 0.25 and h < gen.water_surface() + 2.4


## Spooked: away from the player and out towards the sea, with an alarm call; any birds
## close by follow a moment later
func _take_off(k: int, from: Vector3, first: bool) -> void:
	var b: Dictionary = birds[k]
	if b.state >= State.TAKE_OFF:
		return
	var away := Vector3(b.pos.x - from.x, 0.0, b.pos.z - from.z).normalized()
	if away == Vector3.ZERO:
		away = Vector3.FORWARD
	b.heading = (away + _seaward(b.pos) * 0.8).normalized()
	b.state = State.TAKE_OFF
	b.timer = 0.6
	b.speed = 2.0
	b.walk = 0.0
	b.peck = 0.0
	if first:
		_alarm(b.pos)
		for other in birds.size():
			var o: Dictionary = birds[other]
			if other != k and o.state < State.TAKE_OFF and (o.pos as Vector3).distance_to(b.pos) < PANIC_RADIUS:
				# Not all at once
				get_tree().create_timer(rng.randf_range(0.1, 0.6), false).timeout.connect(_take_off.bind(other, from, false))


## Something landed at `point` (a thrown stone): gulls on the ground within `radius` take
## off, the nearest first with an alarm call.
func spook(point: Vector3, radius: float) -> void:
	var nearest := -1
	var best := radius
	for k in birds.size():
		var b: Dictionary = birds[k]
		var d := (b.pos as Vector3).distance_to(point)
		if b.state < State.TAKE_OFF and d < best:
			best = d
			nearest = k
	if nearest >= 0:
		_take_off(nearest, point, true)


## Downhill along the ground: towards the water
func _seaward(p: Vector3) -> Vector3:
	var e := 3.0
	var dx: float = gen.get_height(p.x + e, p.z) - gen.get_height(p.x - e, p.z)
	var dz: float = gen.get_height(p.x, p.z + e) - gen.get_height(p.x, p.z - e)
	var down := Vector3(-dx, 0.0, -dz)
	return down.normalized() if down.length() > 0.01 else Vector3.ZERO


func _fly(b: Dictionary, delta: float, from: Vector3) -> void:
	# After fleeing for a while, head for a beach well away from the player
	if b.target == Vector3.ZERO and b.timer <= 0.0:
		for attempt in 40:
			var spot := spots[rng.randi() % spots.size()]
			var hop := spot.distance_to(b.pos)
			if spot.distance_to(from) > 60.0 and hop > LANDING_HOP.x and hop < LANDING_HOP.y:
				b.target = _ground_spot(spot)
				b.home = spot
				break
	var to_target: Vector3 = b.target - b.pos if b.target != Vector3.ZERO else Vector3.ZERO
	var flat := Vector2(to_target.x, to_target.z).length()
	var heading: Vector3 = b.heading
	b.turn = 0.0
	if b.target != Vector3.ZERO:
		var want := atan2(-to_target.x, -to_target.z)
		var have := atan2(-heading.x, -heading.z)
		var turn := clampf(wrapf(want - have, -PI, PI), -TURN_RATE * delta, TURN_RATE * delta)
		b.heading = heading.rotated(Vector3.UP, turn)
		b.turn = turn / maxf(delta, 1e-4)
	var ground := maxf(gen.get_height(b.pos.x, b.pos.z), gen.water_surface())
	var height := ground + CRUISE_HEIGHT
	b.speed = FLIGHT_SPEED
	if b.target != Vector3.ZERO and flat < LAND_FROM:
		b.state = State.LAND
		# Glide down towards the spot, slowing, wings opening up to brake near the ground
		height = lerpf(b.target.y + STAND_HEIGHT, ground + CRUISE_HEIGHT, clampf(flat / LAND_FROM, 0.0, 1.0) ** 1.5)
		b.speed = lerpf(2.0, FLIGHT_SPEED, clampf(flat / LAND_FROM, 0.0, 1.0))
	var climb: float = clampf((height - b.pos.y) * 1.5, -4.0, 4.0)
	var pos: Vector3 = b.pos + (b.heading as Vector3) * b.speed * delta + Vector3.UP * climb * delta
	pos.y = maxf(pos.y, gen.get_height(pos.x, pos.z) + STAND_HEIGHT)
	b.pos = pos
	b.flap = move_toward(b.flap, 1.0 if climb > 0.8 or b.state == State.LAND and flat < 6.0 else 0.0, delta * 2.0)

	if b.state == State.LAND and flat < 0.8:
		# Down: fold up and carry on as a beach bird here
		b.pos = b.target
		b.state = State.STAND
		b.timer = rng.randf_range(1.0, 3.0)
		b.flap = 0.0
		b.speed = 0.0
		b.target = Vector3.ZERO
	b.perched = move_toward(b.perched, 1.0 if b.state < State.TAKE_OFF else 0.0, delta * 2.5)


func _alarm(at: Vector3) -> void:
	var voice: AudioStreamPlayer3D = alarms[0]
	for v in alarms:
		if not v.playing:
			voice = v
			break
	voice.stream = BIRDS.CALLS[rng.randi() % BIRDS.CALLS.size()]
	voice.pitch_scale = rng.randf_range(ALARM_PITCH.x, ALARM_PITCH.y)  # Sharper, more urgent
	voice.volume_db = 0.0
	voice.global_position = at + Vector3.UP
	voice.play()


# --- Drawing -------------------------------------------------------------------------

func _pose(k: int, b: Dictionary, _delta: float) -> void:
	var heading: Vector3 = b.heading
	var pos: Vector3 = b.pos
	var facing: Basis
	if b.state < State.TAKE_OFF:
		# Standing: level, bobbing a little as it walks, dipping the head to peck
		pos.y += STAND_HEIGHT + absf(sin(time * 11.0 + b.phase * TAU)) * 0.025 * b.walk
		facing = Basis.looking_at(heading, Vector3.UP)
		facing = facing.rotated(facing.x.normalized(), -0.5 * b.peck)
	else:
		# Flying: nose along the path, banked into turns
		var velocity: Vector3 = heading * b.speed
		var left := Vector3.UP.cross(heading)
		var bank: float = clampf(b.turn * b.speed / 9.8 * 1.5, -0.8, 0.8)
		facing = Basis.looking_at(velocity.normalized() if velocity.length() > 0.1 else heading, (Vector3.UP + left * tan(bank)).normalized())
	multimesh.set_instance_transform(k, Transform3D(facing.scaled(Vector3.ONE * SIZE), pos))
	var on_ground: bool = b.state < State.TAKE_OFF
	multimesh.set_instance_custom_data(k, Color(b.phase, b.flap, b.walk if on_ground else 1.0, b.perched))
