extends Node3D

## Scatters grass, rocks, bushes and tropical trees over the generated terrain.
## Trees, bushes and rocks are MultiMeshes split into chunks so off-screen chunks are
## culled. Grass is a camera-following GPU field (see grass.gdshader).

const ProcMesh = preload("res://scripts/world/proc_mesh.gd")
const GRASS_SHADER = preload("res://shaders/grass.gdshader")
const FOLIAGE_SHADER = preload("res://shaders/foliage.gdshader")
const BARK_SHADER = preload("res://shaders/bark.gdshader")
const ROCK_SHADER = preload("res://shaders/rock.gdshader")

const CHUNK_SIZE = 128.0       # Metres per scatter chunk side (smaller culls better, but more draw calls)
const GRASS_SPACING = 0.35     # Metres between grass clumps
const GRASS_CHUNKS = 6         # Grass chunks per side around the camera
const GRASS_CHUNK_CELLS = 34   # Clumps per grass chunk side
const SPAWN_CLEARANCE = 4.0    # Keep trees and boulders off the player's spawn point
const ISLET_PALMS = 0.12       # Palm chance per tree spot in an islet's palm clumps
const ISLET_BUSHES = 0.25      # Bush density on islets, relative to the main island
const COCONUT_CHANCE = 0.55    # Palms on the sand that carry a bunch of coconuts
const FALLEN_CHANCE = 0.4      # ...and that have a coconut or two lying underneath

var gen: Node3D
var rng := RandomNumberGenerator.new()
var forest_noise := FastNoiseLite.new()
var water_m := -INF
var half_world := 0.0
var chunks := 1                # Scatter chunks per side
var spawn := Vector2.INF
var buckets := {}              # [mesh, chunk] -> {mesh, xforms, vis_end}
var body: StaticBody3D
var grass_root: Node3D


func build(generator: Node3D) -> void:
	gen = generator
	rng.seed = gen.rng.randi()
	forest_noise.seed = rng.randi()
	forest_noise.frequency = 0.006
	forest_noise.fractal_octaves = 3
	if gen.water_enabled:
		water_m = gen.water_level * gen.max_height
	half_world = (gen.size - 1) * 0.5 * gen.cell_size
	chunks = maxi(1, ceili(half_world * 2.0 / CHUNK_SIZE))
	var player := gen.get_node_or_null("Player") as Node3D
	if player:
		spawn = Vector2(player.position.x, player.position.z)

	body = StaticBody3D.new()
	body.name = "VegetationBody"
	add_child(body)

	_scatter_trees()
	_scatter_bushes()
	_scatter_rocks()
	_flush_buckets()
	if gen.grass_enabled:
		_build_grass()


func _process(_delta: float) -> void:
	if grass_root == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam:
		var p := cam.global_position
		grass_root.global_position = Vector3(snappedf(p.x, GRASS_SPACING), 0.0, snappedf(p.z, GRASS_SPACING))


# --- Terrain queries -------------------------------------------------------

func _slope(i: int) -> float:
	return 1.0 - gen.normal_map[i].y


## True in or right beside a lake or river: water covers the spot, or the ground is
## less than `clearance` metres above the local water surface.
func _in_inland_water(x: float, z: float, h: float, clearance: float) -> bool:
	if not gen.has_method("inland_water_at"):
		return false
	if gen.inland_water_at(x, z) > 0.0:
		return true
	var surface: float = gen.water_surface_at(x, z)
	return surface > water_m + 0.05 and h < surface + clearance


func _near_spawn(x: float, z: float) -> bool:
	return Vector2(x, z).distance_to(spawn) < SPAWN_CLEARANCE


## Walks a jittered grid over the map and calls `place(x, z)` at each candidate.
## Jittered grids keep objects from clumping on top of each other.
func _jittered_grid(spacing: float, place: Callable) -> void:
	var z := -half_world + spacing * 0.5
	while z < half_world:
		var x := -half_world + spacing * 0.5
		while x < half_world:
			var px := clampf(x + rng.randf_range(-0.45, 0.45) * spacing, -half_world + 1.0, half_world - 1.0)
			var pz := clampf(z + rng.randf_range(-0.45, 0.45) * spacing, -half_world + 1.0, half_world - 1.0)
			place.call(px, pz)
			x += spacing
		z += spacing


func _add(mesh: Mesh, xform: Transform3D, vis_end := 0.0) -> void:
	var cx := clampi(int((xform.origin.x + half_world) / (half_world * 2.0) * chunks), 0, chunks - 1)
	var cz := clampi(int((xform.origin.z + half_world) / (half_world * 2.0) * chunks), 0, chunks - 1)
	var key := [mesh, cz * chunks + cx]
	if not buckets.has(key):
		buckets[key] = {"mesh": mesh, "xforms": [], "vis_end": vis_end}
	buckets[key].xforms.append(xform)


func _add_collider(shape: Shape3D, xform: Transform3D) -> void:
	var owner_id := body.create_shape_owner(body)
	body.shape_owner_add_shape(owner_id, shape)
	body.shape_owner_set_transform(owner_id, xform)


func _flush_buckets() -> void:
	for key in buckets:
		var bucket: Dictionary = buckets[key]
		var xforms: Array = bucket.xforms
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = bucket.mesh
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		if bucket.vis_end > 0.0:
			mmi.visibility_range_end = bucket.vis_end
			mmi.visibility_range_end_margin = 20.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(mmi)
	buckets.clear()


# --- Materials ---------------------------------------------------------------

func _foliage_material(tex: Texture2D, young: Color, old: Color, gloss: float, flutter: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = FOLIAGE_SHADER
	if tex:
		m.set_shader_parameter("leaf_texture", tex)
	m.set_shader_parameter("color_young", young)
	m.set_shader_parameter("color_old", old)
	m.set_shader_parameter("gloss", gloss)
	m.set_shader_parameter("flutter", flutter)
	return m


func _bark_material(dark: Color, light: Color, rings: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = BARK_SHADER
	m.set_shader_parameter("bark_dark", dark)
	m.set_shader_parameter("bark_light", light)
	m.set_shader_parameter("ring_strength", rings)
	return m


# --- Trees ---------------------------------------------------------------------

func _scatter_trees() -> void:
	var palm_bark := _bark_material(Color(0.30, 0.25, 0.19), Color(0.55, 0.49, 0.40), 1.0)
	var frond_mat := _foliage_material(null, Color(0.17, 0.36, 0.07), Color(0.40, 0.40, 0.14), 0.4, 0.08)
	var jungle_bark := _bark_material(Color(0.18, 0.15, 0.12), Color(0.42, 0.38, 0.32), 0.0)
	var canopy_mat := _foliage_material(ProcMesh.leaf_texture(rng, false),
			Color(0.13, 0.32, 0.06), Color(0.26, 0.38, 0.09), 0.3, 0.05)

	var palms: Array[Mesh] = []
	var jungle: Array[Mesh] = []
	for i in 4:
		palms.append(ProcMesh.palm(rng, palm_bark, frond_mat))
		jungle.append(ProcMesh.broadleaf(rng, jungle_bark, canopy_mat))
	# Coconuts use their own random numbers, so adding them doesn't move any trees
	var coco_rng := RandomNumberGenerator.new()
	coco_rng.seed = gen.terrain_seed + 3301
	var green_husk := _bark_material(Color(0.32, 0.38, 0.1), Color(0.6, 0.6, 0.2), 0.0)
	var clusters: Array[Mesh] = []
	for palm in palms:
		clusters.append(ProcMesh.coconut_cluster(coco_rng, palm.get_meta(&"crown"), green_husk))
	var fallen := ProcMesh.fallen_coconut(coco_rng, green_husk)

	if gen.tree_density <= 0.0:
		return
	_jittered_grid(6.5 / sqrt(gen.tree_density), func(x: float, z: float) -> void:
		if _near_spawn(x, z):
			return
		var i: int = gen.grid_index(x, z)
		var h: float = gen.get_height(x, z)
		var above := h - water_m
		var slope := _slope(i)
		if above < 1.0 or slope > 0.35 or _in_inland_water(x, z, h, 0.8):
			return
		var forest := forest_noise.get_noise_2d(x, z) * 0.5 + 0.5
		var flat := 1.0 - smoothstep(0.18, 0.35, slope)
		var altitude: float = h / gen.max_height
		# Palms line the shores; rainforest fills the wetter lowland and valley patches
		var shore := exp(-above / 5.0) if water_m > -INF else 0.0
		var palm_p := (shore * 0.6 + smoothstep(0.6, 0.85, forest) * 0.03) * flat
		var jungle_p: float = smoothstep(0.42, 0.68, forest + gen.flow_map[i] * 0.25) * (1.0 - shore) \
				* (1.0 - smoothstep(0.45, 0.7, altitude)) * flat * 0.6
		# Islets are open sand with a few palms in loose clumps, and no rainforest
		var islet: float = gen.islet_weight(x, z)
		if islet > 0.0:
			palm_p = lerpf(palm_p, ISLET_PALMS * (0.2 + 0.8 * smoothstep(0.4, 0.7, forest)), islet)
			jungle_p *= 1.0 - islet
		var r := rng.randf()
		var rot := Basis(Vector3.UP, rng.randf() * TAU)
		if r < palm_p:
			var s := rng.randf_range(0.8, 1.15)
			var kind := rng.randi() % palms.size()
			var xform := Transform3D(rot.scaled(Vector3.ONE * s), Vector3(x, h - 0.15, z))
			_add(palms[kind], xform)
			# Coconuts on palms that stand on the beach sand
			if above < gen.beach_height + 0.3 and coco_rng.randf() < COCONUT_CHANCE:
				_add(clusters[kind], xform, 180.0)
				if coco_rng.randf() < FALLEN_CHANCE:
					for n in coco_rng.randi_range(1, 2):
						var at := Vector3(x, 0.0, z) + Vector3.FORWARD.rotated(Vector3.UP, coco_rng.randf() * TAU) * coco_rng.randf_range(0.7, 2.2)
						at.y = gen.get_height(at.x, at.z) - 0.01  # Just settled into the sand
						_add(fallen, Transform3D(Basis(Vector3.UP, coco_rng.randf() * TAU), at), 90.0)
			var col := CylinderShape3D.new()
			col.radius = 0.25 * s
			col.height = 3.0
			_add_collider(col, Transform3D(Basis(), Vector3(x, h + 1.4, z)))
		elif r < palm_p + jungle_p:
			var s := rng.randf_range(0.8, 1.3)
			_add(jungle[rng.randi() % jungle.size()], Transform3D(rot.scaled(Vector3.ONE * s), Vector3(x, h - 0.2, z)))
			var col := CylinderShape3D.new()
			col.radius = 0.32 * s
			col.height = 4.0
			_add_collider(col, Transform3D(Basis(), Vector3(x, h + 1.9, z)))
	)


# --- Bushes --------------------------------------------------------------------

func _scatter_bushes() -> void:
	var big_leaf := ProcMesh.leaf_texture(rng, true)
	var mat := _foliage_material(big_leaf, Color(0.12, 0.30, 0.07), Color(0.26, 0.40, 0.10), 0.4, 0.04)
	var meshes: Array[Mesh] = []
	for i in 3:
		meshes.append(ProcMesh.bush(rng, mat))

	if gen.bush_density <= 0.0:
		return
	_jittered_grid(3.5 / sqrt(gen.bush_density), func(x: float, z: float) -> void:
		var i: int = gen.grid_index(x, z)
		var h: float = gen.get_height(x, z)
		if h - water_m < gen.beach_height + 0.4 or _slope(i) > 0.3 or h / gen.max_height > 0.7 \
				or _in_inland_water(x, z, h, 0.4):
			return
		var forest := forest_noise.get_noise_2d(x, z) * 0.5 + 0.5
		var p: float = 0.04 + smoothstep(0.4, 0.7, forest) * 0.45 + gen.flow_map[i] * 0.1
		p *= 1.0 - (1.0 - ISLET_BUSHES) * gen.islet_weight(x, z)
		if rng.randf() < p:
			var s := rng.randf_range(0.6, 1.4)
			var rot := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.8, 1.2), s))
			_add(meshes[rng.randi() % meshes.size()], Transform3D(rot, Vector3(x, h - 0.1, z)), 220.0)
	)


# --- Rocks ---------------------------------------------------------------------

func _scatter_rocks() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = ROCK_SHADER
	var meshes: Array[Mesh] = []
	for i in 5:
		meshes.append(ProcMesh.rock(rng, mat))

	if gen.rock_density <= 0.0:
		return
	_jittered_grid(4.0 / sqrt(gen.rock_density), func(x: float, z: float) -> void:
		var i: int = gen.grid_index(x, z)
		var h: float = gen.get_height(x, z)
		var slope := _slope(i)
		var above := h - water_m
		if above < -1.5:
			return
		var size := 0.0
		var r := rng.randf()
		var boulder_p := smoothstep(0.18, 0.4, slope) * 0.35
		var pebble_p: float = gen.flow_map[i] * 0.2 + (0.15 if above < 1.5 else 0.0) + 0.04
		if r < boulder_p:
			size = rng.randf_range(0.8, 2.5)          # Boulders on steep ground
		elif r < boulder_p + pebble_p:
			size = rng.randf_range(0.12, 0.45)        # Pebbles in channels and on beaches
		elif r < boulder_p + pebble_p + 0.02:
			size = rng.randf_range(0.4, 1.3)          # The odd lone rock
		else:
			return
		if size > 1.0 and _near_spawn(x, z):
			return
		var n: Vector3 = gen.normal_map[i]
		# Tilt with the terrain, then spin and stretch for variety
		var align := Basis(Quaternion(Vector3.UP, n))
		var rot := align * Basis(Vector3.UP, rng.randf() * TAU)
		rot = rot.scaled(Vector3(size, size * rng.randf_range(0.7, 1.1), size * rng.randf_range(0.8, 1.3)))
		var origin := Vector3(x, h - size * 0.15, z)
		_add(meshes[rng.randi() % meshes.size()], Transform3D(rot, origin), 0.0 if size > 1.0 else 160.0)
		if size > 1.0:
			var col := SphereShape3D.new()
			col.radius = size * 0.7
			_add_collider(col, Transform3D(Basis(), origin + Vector3.UP * size * 0.05))
	)


# --- Grass -----------------------------------------------------------------------

func _build_grass() -> void:
	var count: int = gen.size * gen.size
	var water_n: float = water_m / gen.max_height if water_m > -INF else -1.0

	# Where grass grows: dry land, not too steep, not on bare sediment
	var mask := PackedByteArray()
	mask.resize(count)
	for i in count:
		var h: float = gen.heights[i]
		var m: float = smoothstep(water_n + gen.beach_height / gen.max_height, water_n + (gen.beach_height + 1.2) / gen.max_height, h)
		m *= 1.0 - smoothstep(0.14, 0.24, _slope(i))
		m *= 1.0 - smoothstep(0.75, 0.95, gen.deposit_map[i])
		m *= 1.0 - smoothstep(0.7, 0.8, h)
		# No grass under lakes and rivers or on the waterline
		m *= (1.0 - gen.inland_mask[i]) * smoothstep(0.0, 0.5 / gen.max_height, h - gen.water_height[i])
		mask[i] = int(clampf(m, 0.0, 1.0) * 255.0)
	var mask_tex := ImageTexture.create_from_image(Image.create_from_data(gen.size, gen.size, false, Image.FORMAT_R8, mask))
	var height_tex := ImageTexture.create_from_image(
			Image.create_from_data(gen.size, gen.size, false, Image.FORMAT_RF, gen.heights.to_byte_array()))

	var mat := ShaderMaterial.new()
	mat.shader = GRASS_SHADER
	mat.set_shader_parameter("heightmap", height_tex)
	mat.set_shader_parameter("grass_mask", mask_tex)
	mat.set_shader_parameter("max_height", gen.max_height)
	mat.set_shader_parameter("cell_size", gen.cell_size)
	mat.set_shader_parameter("map_size", float(gen.size))
	mat.set_shader_parameter("spacing", GRASS_SPACING)
	var chunk_world := GRASS_CHUNK_CELLS * GRASS_SPACING
	mat.set_shader_parameter("fade_end", chunk_world * GRASS_CHUNKS * 0.5 - 1.0)
	mat.set_shader_parameter("fade_start", chunk_world * GRASS_CHUNKS * 0.5 - 10.0)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = ProcMesh.grass_clump(rng, mat)
	mm.instance_count = GRASS_CHUNK_CELLS * GRASS_CHUNK_CELLS
	for z in GRASS_CHUNK_CELLS:
		for x in GRASS_CHUNK_CELLS:
			mm.set_instance_transform(z * GRASS_CHUNK_CELLS + x,
					Transform3D(Basis(), Vector3(x * GRASS_SPACING, 0.0, z * GRASS_SPACING)))
	# Heights are applied in the shader, so give each chunk a box tall enough to cover the terrain
	mm.custom_aabb = AABB(Vector3(-1.0, -5.0, -1.0), Vector3(chunk_world + 2.0, gen.max_height + 10.0, chunk_world + 2.0))

	grass_root = Node3D.new()
	grass_root.name = "Grass"
	add_child(grass_root)
	for cz in GRASS_CHUNKS:
		for cx in GRASS_CHUNKS:
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.position = Vector3((cx - GRASS_CHUNKS * 0.5) * chunk_world, 0.0, (cz - GRASS_CHUNKS * 0.5) * chunk_world)
			grass_root.add_child(mmi)
