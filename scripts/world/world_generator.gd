extends Node3D

## Procedural terrain generator.
## Pipeline: layered noise heightmap -> hydraulic erosion -> mesh (analytic normals)
## + heightmap collision + water plane. Erosion data (drainage / sediment) is passed
## to the terrain shader through vertex colours so gullies and deposits can be shaded.

const TERRAIN_SHADER = preload("res://shaders/terrain.gdshader")
const WATER_SHADER = preload("res://shaders/water.gdshader")
const VEGETATION = preload("res://scripts/world/vegetation.gd")
const AMBIENT_AUDIO = preload("res://scripts/world/ambient_audio.gd")

@export_group("Shape")
@export var resolution: int = 256          ## Cells per side (vertices per side = resolution + 1)
@export var cell_size: float = 2.0         ## Metres between vertices
@export var max_height: float = 90.0       ## Height of the tallest peak in metres
@export var terrain_seed: int = 0          ## 0 = new random terrain every run
@export var island: bool = true            ## Sink the map border into the sea, making an island

@export_group("Erosion")
@export var erosion_droplets: int = 70000  ## More droplets = deeper, more defined gullies (slower)
@export var erosion_radius: int = 2

@export_group("Water")
@export var water_enabled: bool = true
@export_range(0.0, 1.0) var water_level: float = 0.08  ## Fraction of max_height
@export_range(0.0, 0.95) var beach_flatness: float = 0.75  ## Flattens the coast into wide beaches (0 = off)
@export var beach_height: float = 2.4      ## Metres above the water that sand reaches

@export_group("Vegetation")
@export var vegetation_enabled: bool = true
@export var grass_enabled: bool = true
@export_range(0.0, 3.0) var tree_density: float = 1.0
@export_range(0.0, 3.0) var bush_density: float = 1.0
@export_range(0.0, 3.0) var rock_density: float = 1.0

@export_group("Audio")
@export var audio_enabled: bool = true

# Droplet erosion tuning (heightmap units are 0..1, distance unit is one cell)
const DROP_LIFETIME = 40
const INERTIA = 0.05
const SEDIMENT_CAPACITY = 4.0
const MIN_SEDIMENT_CAPACITY = 0.01
const ERODE_SPEED = 0.3
const DEPOSIT_SPEED = 0.3
const EVAPORATE_SPEED = 0.015
const DROP_GRAVITY = 4.0

var heights := PackedFloat32Array()   # Normalised 0..1, row-major (z * size + x)
var flow_map := PackedFloat32Array()  # Accumulated water passing through each vertex
var deposit_map := PackedFloat32Array()
var normal_map := PackedVector3Array() # Per-vertex terrain normal
var island_edge := PackedFloat32Array() # Per-vertex distance through the island falloff (island mode)
var size := 0                          # Vertices per side
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	if terrain_seed == 0:
		rng.randomize()
	else:
		rng.seed = terrain_seed
	size = resolution + 1

	var t := Time.get_ticks_msec()
	_generate_heightmap()
	_erode()
	if water_enabled:
		_shape_beaches()
	if island:
		_sink_seabed()
	_build_terrain()
	if water_enabled:
		_build_water()
	_place_player()
	print("Terrain generated in %d ms" % (Time.get_ticks_msec() - t))
	var vegetation: Node3D = null
	if vegetation_enabled:
		t = Time.get_ticks_msec()
		vegetation = VEGETATION.new()
		vegetation.name = "Vegetation"
		add_child(vegetation)
		vegetation.build(self)
		print("Vegetation generated in %d ms" % (Time.get_ticks_msec() - t))
	if audio_enabled:
		var ambience := AMBIENT_AUDIO.new()
		ambience.name = "AmbientAudio"
		add_child(ambience)
		ambience.setup(self, vegetation)


## Height in metres at a world-space XZ position. Interpolates across the same
## triangles the terrain mesh uses, so objects sit exactly on the visible surface.
func get_height(world_x: float, world_z: float) -> float:
	var half := (size - 1) * 0.5
	var gx := clampf(world_x / cell_size + half, 0.0, size - 1.001)
	var gz := clampf(world_z / cell_size + half, 0.0, size - 1.001)
	return _sample(gx, gz) * max_height


## Index of the heightmap vertex nearest to a world-space XZ position.
func grid_index(world_x: float, world_z: float) -> int:
	var half := (size - 1) * 0.5
	var gx := clampi(roundi(world_x / cell_size + half), 0, size - 1)
	var gz := clampi(roundi(world_z / cell_size + half), 0, size - 1)
	return gz * size + gx


## Ground type at a position, for footstep sounds: &"sand", &"stone" or &"grass".
## `floor_collider` is what the character is standing on (boulders count as stone).
func surface_at(pos: Vector3, floor_collider: Object = null) -> StringName:
	if floor_collider is StaticBody3D and floor_collider.name == &"VegetationBody":
		return &"stone"
	var i := grid_index(pos.x, pos.z)
	if water_enabled and heights[i] < water_level + beach_height / max_height:
		return &"sand"
	if 1.0 - normal_map[i].y > 0.26:
		return &"stone"
	return &"grass"


## Height of the water surface in metres, or -INF with water turned off.
func water_surface() -> float:
	return water_level * max_height if water_enabled else -INF


## How deep the water is above a point, in metres (0 on dry land or with water off).
func water_depth_at(pos: Vector3) -> float:
	if not water_enabled:
		return 0.0
	return maxf(water_level * max_height - pos.y, 0.0)


func _sample(x: float, z: float) -> float:
	var cx := int(x)
	var cz := int(z)
	var fx := x - cx
	var fz := z - cz
	var i := cz * size + cx
	if fx + fz <= 1.0:
		return heights[i] + (heights[i + 1] - heights[i]) * fx + (heights[i + size] - heights[i]) * fz
	var h11 := heights[i + size + 1]
	return h11 + (heights[i + size] - h11) * (1.0 - fx) + (heights[i + 1] - h11) * (1.0 - fz)


func _make_noise(freq: float, octaves: int, fractal: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = rng.randi()
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	n.frequency = freq
	n.fractal_type = fractal
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5
	return n


func _generate_heightmap() -> void:
	# Broad rolling landforms
	var base_noise := _make_noise(0.0035, 6, FastNoiseLite.FRACTAL_FBM)
	# Sharp mountain ridges (ridged multifractal)
	var ridge_noise := _make_noise(0.004, 6, FastNoiseLite.FRACTAL_RIDGED)
	# Decides where mountains appear vs. lowlands
	var mask_noise := _make_noise(0.0025, 2, FastNoiseLite.FRACTAL_FBM)
	# Domain warp breaks up the grid-like regularity of plain noise
	var warp_noise := _make_noise(0.004, 3, FastNoiseLite.FRACTAL_FBM)
	const WARP_STRENGTH = 60.0

	heights.resize(size * size)
	island_edge.resize(size * size)
	var half := (size - 1) * 0.5
	var lo := INF
	var hi := -INF
	for z in size:
		for x in size:
			var px := (x - half) * cell_size
			var pz := (z - half) * cell_size
			var wx := px + warp_noise.get_noise_2d(px, pz) * WARP_STRENGTH
			var wz := pz + warp_noise.get_noise_2d(px + 5200.0, pz - 1300.0) * WARP_STRENGTH

			var base := base_noise.get_noise_2d(wx, wz) * 0.5 + 0.5
			var ridge := ridge_noise.get_noise_2d(wx, wz) * 0.5 + 0.5
			var mask := smoothstep(0.35, 0.7, mask_noise.get_noise_2d(px, pz) * 0.5 + 0.5)

			var h := base * 0.6 + ridge * ridge * mask * 0.7
			if island:
				# Rounded-square distance from the centre (0 centre .. 1 border), warped by
				# broad noise for bays and headlands and finer noise for a ragged coast
				var dx := absf(x - half) / half
				var dz := absf(z - half) / half
				var edge := pow(pow(dx, 2.5) + pow(dz, 2.5), 0.4)
				edge += warp_noise.get_noise_2d(px * 0.8, pz * 0.8) * 0.16
				edge += warp_noise.get_noise_2d(px * 2.0, pz * 2.0) * 0.06
				h *= 1.0 - smoothstep(0.5, 0.84, edge)
				island_edge[z * size + x] = edge
			heights[z * size + x] = h
			lo = minf(lo, h)
			hi = maxf(hi, h)

	# Normalise, then push valleys flat and keep peaks sharp
	for i in heights.size():
		heights[i] = pow(maxf((heights[i] - lo) / (hi - lo), 0.0), 1.5)


## Flattens the band of terrain around sea level into wide, gently sloping beaches and
## shallow lagoons. Heights are remapped through a monotonic curve, never reordered:
## the slope is reduced near the waterline, and ground a little further up (and down)
## is made slightly steeper to make up the difference, so hills and the deep seabed
## keep their original heights.
func _shape_beaches() -> void:
	if beach_flatness <= 0.0:
		return
	const STEP = 0.05     # Metres per lookup-table entry
	const LO = -40.0      # Table range, metres relative to the water
	const HI = 40.0
	var n := int((HI - LO) / STEP) + 1
	var zero := int(-LO / STEP)

	# Slope multiplier per height: < 1 on the beach and shallows, > 1 on the backshore
	# and the drop-off, sized so the total change is zero beyond them
	var slope := PackedFloat32Array()
	slope.resize(n)
	var deficit_up := 0.0
	var deficit_down := 0.0
	var bump_up := 0.0
	var bump_down := 0.0
	for k in n:
		var a := LO + k * STEP
		var flat := smoothstep(-8.0, -3.0, a) * (1.0 - smoothstep(3.0, 8.0, a)) * beach_flatness
		slope[k] = 1.0 - flat
		if a >= 0.0:
			deficit_up += flat * STEP
			bump_up += _catch_up(a, 8.0, 30.0) * STEP
		else:
			deficit_down += flat * STEP
			bump_down += _catch_up(-a, 8.0, 30.0) * STEP
	for k in n:
		var a := LO + k * STEP
		if a >= 0.0:
			slope[k] += _catch_up(a, 8.0, 30.0) * deficit_up / bump_up
		else:
			slope[k] += _catch_up(-a, 8.0, 30.0) * deficit_down / bump_down

	# Integrate outwards from the waterline, which stays where it is
	var remap := PackedFloat32Array()
	remap.resize(n)
	remap[zero] = 0.0
	for k in range(zero + 1, n):
		remap[k] = remap[k - 1] + slope[k] * STEP
	for k in range(zero - 1, -1, -1):
		remap[k] = remap[k + 1] - slope[k] * STEP

	var water_m := water_level * max_height
	for i in heights.size():
		var a := heights[i] * max_height - water_m
		if a <= LO or a >= HI:
			continue
		var f := (a - LO) / STEP
		var k := mini(int(f), n - 2)
		var g := lerpf(remap[k], remap[k + 1], f - k)
		heights[i] = maxf((g + water_m) / max_height, 0.0)


## Slopes the seabed down beyond the island's shallows, following the coastline's shape,
## and always reaching full depth at the map border. The terrain mesh ends there, so if
## the water were still shallow it would turn from turquoise to deep blue in a straight
## line where the seabed stops.
func _sink_seabed() -> void:
	const DROP = 30.0  # Metres
	var half := (size - 1) * 0.5
	for z in size:
		for x in size:
			var i := z * size + x
			var border := maxf(absf(x - half), absf(z - half)) / half
			var drop := maxf(smoothstep(0.84, 1.05, island_edge[i]), smoothstep(0.86, 1.0, border))
			heights[i] -= drop * DROP / max_height


## Smooth bump between two distances, used to spread the beach's height deficit.
func _catch_up(d: float, start: float, end: float) -> float:
	if d <= start or d >= end:
		return 0.0
	return sin(PI * (d - start) / (end - start))


## Droplet-based hydraulic erosion (after Hans Theobald Beyer / Sebastian Lague).
## Each droplet runs downhill picking up sediment where it accelerates and dropping
## it where it slows, carving gullies and leaving alluvial fans in the valleys.
func _erode() -> void:
	flow_map.resize(size * size)
	flow_map.fill(0.0)
	deposit_map.resize(size * size)
	deposit_map.fill(0.0)
	if erosion_droplets <= 0:
		return

	# Precompute the erosion brush (weights fall off linearly with distance)
	var brush_offsets := PackedInt32Array()
	var brush_weights := PackedFloat32Array()
	var weight_sum := 0.0
	for dz in range(-erosion_radius, erosion_radius + 1):
		for dx in range(-erosion_radius, erosion_radius + 1):
			var d := sqrt(float(dx * dx + dz * dz))
			if d <= erosion_radius:
				var w := 1.0 - d / (erosion_radius + 1.0)
				brush_offsets.append(dz * size + dx)
				brush_weights.append(w)
				weight_sum += w
	for i in brush_weights.size():
		brush_weights[i] /= weight_sum
	var brush_count := brush_offsets.size()

	var lo := float(erosion_radius)
	var hi := float(size - 2 - erosion_radius)
	var map := heights  # Local alias for speed in the hot loop

	for _d in erosion_droplets:
		var x := rng.randf_range(lo, hi)
		var z := rng.randf_range(lo, hi)
		var dir_x := 0.0
		var dir_z := 0.0
		var speed := 1.0
		var water := 1.0
		var sediment := 0.0

		for _life in DROP_LIFETIME:
			var cx := int(x)
			var cz := int(z)
			var fx := x - cx
			var fz := z - cz
			var i := cz * size + cx
			var h00 := map[i]
			var h10 := map[i + 1]
			var h01 := map[i + size]
			var h11 := map[i + size + 1]
			var grad_x := (h10 - h00) * (1.0 - fz) + (h11 - h01) * fz
			var grad_z := (h01 - h00) * (1.0 - fx) + (h11 - h10) * fx
			var h := h00 * (1.0 - fx) * (1.0 - fz) + h10 * fx * (1.0 - fz) + h01 * (1.0 - fx) * fz + h11 * fx * fz

			flow_map[i] += water

			dir_x = dir_x * INERTIA - grad_x * (1.0 - INERTIA)
			dir_z = dir_z * INERTIA - grad_z * (1.0 - INERTIA)
			var dir_len := sqrt(dir_x * dir_x + dir_z * dir_z)
			if dir_len < 1e-6:
				break
			dir_x /= dir_len
			dir_z /= dir_len
			x += dir_x
			z += dir_z
			if x < lo or z < lo or x >= hi or z >= hi:
				break

			# Height at the new position
			var ncx := int(x)
			var ncz := int(z)
			var nfx := x - ncx
			var nfz := z - ncz
			var ni := ncz * size + ncx
			var new_h := lerpf(lerpf(map[ni], map[ni + 1], nfx), lerpf(map[ni + size], map[ni + size + 1], nfx), nfz)
			var dh := new_h - h

			var capacity := maxf(-dh, MIN_SEDIMENT_CAPACITY) * speed * water * SEDIMENT_CAPACITY
			if sediment > capacity or dh > 0.0:
				# Deposit: fill the pit when going uphill, otherwise drop the excess
				var amount := minf(dh, sediment) if dh > 0.0 else (sediment - capacity) * DEPOSIT_SPEED
				sediment -= amount
				map[i] += amount * (1.0 - fx) * (1.0 - fz)
				map[i + 1] += amount * fx * (1.0 - fz)
				map[i + size] += amount * (1.0 - fx) * fz
				map[i + size + 1] += amount * fx * fz
				deposit_map[i] += amount
			else:
				# Erode with a soft brush, never digging deeper than the drop in height
				var amount := minf((capacity - sediment) * ERODE_SPEED, -dh)
				for b in brush_count:
					var bi := i + brush_offsets[b]
					var e := minf(amount * brush_weights[b], map[bi])
					map[bi] -= e
					sediment += e

			speed = sqrt(maxf(0.0, speed * speed - dh * DROP_GRAVITY))
			water *= 1.0 - EVAPORATE_SPEED

	heights = map
	flow_map = _normalise_log(_blur(flow_map))
	deposit_map = _normalise_log(_blur(deposit_map))


func _blur(src: PackedFloat32Array) -> PackedFloat32Array:
	var dst := src.duplicate()
	for z in range(1, size - 1):
		for x in range(1, size - 1):
			var i := z * size + x
			dst[i] = (src[i] * 4.0 + src[i - 1] + src[i + 1] + src[i - size] + src[i + size]) / 8.0
	return dst


func _normalise_log(src: PackedFloat32Array) -> PackedFloat32Array:
	var hi := 0.0
	for v in src:
		hi = maxf(hi, v)
	if hi <= 0.0:
		return src
	var inv := 1.0 / log(1.0 + hi)
	for i in src.size():
		src[i] = log(1.0 + src[i]) * inv
	return src


func _build_terrain() -> void:
	var count := size * size
	var half := (size - 1) * 0.5
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	verts.resize(count)
	normals.resize(count)
	uvs.resize(count)
	colors.resize(count)

	for z in size:
		for x in size:
			var i := z * size + x
			verts[i] = Vector3((x - half) * cell_size, heights[i] * max_height, (z - half) * cell_size)
			# Central-difference normal straight from the heightfield
			var hl := heights[z * size + maxi(x - 1, 0)]
			var hr := heights[z * size + mini(x + 1, size - 1)]
			var hd := heights[maxi(z - 1, 0) * size + x]
			var hu := heights[mini(z + 1, size - 1) * size + x]
			normals[i] = Vector3((hl - hr) * max_height, 2.0 * cell_size, (hd - hu) * max_height).normalized()
			uvs[i] = Vector2(float(x) / (size - 1), float(z) / (size - 1))
			colors[i] = Color(flow_map[i], deposit_map[i], 0.0)
	normal_map = normals

	var indices := PackedInt32Array()
	indices.resize(resolution * resolution * 6)
	var k := 0
	for z in resolution:
		for x in resolution:
			var i := z * size + x
			indices[k] = i
			indices[k + 1] = i + 1
			indices[k + 2] = i + size
			indices[k + 3] = i + 1
			indices[k + 4] = i + size + 1
			indices[k + 5] = i + size
			k += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := ShaderMaterial.new()
	mat.shader = TERRAIN_SHADER
	mat.set_shader_parameter("max_height", max_height)
	mat.set_shader_parameter("water_level", water_level * max_height if water_enabled else -1000.0)
	mat.set_shader_parameter("beach_height", beach_height)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "TerrainMesh"
	mesh_instance.mesh = mesh
	mesh_instance.material_override = mat
	add_child(mesh_instance)

	# Heightmap collision is far cheaper and more robust than a trimesh.
	# The shape uses 1-unit spacing, so scale it uniformly by cell_size and
	# divide the heights to compensate.
	var shape := HeightMapShape3D.new()
	shape.map_width = size
	shape.map_depth = size
	var col_heights := PackedFloat32Array()
	col_heights.resize(count)
	for i in count:
		col_heights[i] = heights[i] * max_height / cell_size
	shape.map_data = col_heights

	var static_body := StaticBody3D.new()
	static_body.name = "TerrainBody"
	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = shape
	collision_shape.scale = Vector3.ONE * cell_size
	static_body.add_child(collision_shape)
	add_child(static_body)


func _build_water() -> void:
	var plane := PlaneMesh.new()
	# Extends far past the terrain so the island sits in an ocean that reaches the horizon
	plane.size = Vector2.ONE * 8000.0
	plane.subdivide_width = 64
	plane.subdivide_depth = 64
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	var water := MeshInstance3D.new()
	water.name = "Water"
	water.mesh = plane
	water.material_override = mat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.position.y = water_level * max_height
	add_child(water)


## Drop the player onto dry, fairly flat land near the centre of the map.
func _place_player() -> void:
	var player := get_node_or_null("Player") as Node3D
	if player == null:
		return
	var half := (size - 1) * 0.5
	var min_h := water_level + 0.05 if water_enabled else 0.0
	var best := Vector2(half, half)
	var best_score := INF
	for z in range(4, size - 4, 2):
		for x in range(4, size - 4, 2):
			var h := heights[z * size + x]
			if h < min_h:
				continue
			var slope := absf(heights[z * size + x + 1] - heights[z * size + x - 1]) \
					+ absf(heights[(z + 1) * size + x] - heights[(z - 1) * size + x])
			if slope * max_height / cell_size > 0.6:
				continue
			var score := Vector2(x - half, z - half).length() + h * 40.0
			if score < best_score:
				best_score = score
				best = Vector2(x, z)
	var wx := (best.x - half) * cell_size
	var wz := (best.y - half) * cell_size
	player.position = Vector3(wx, get_height(wx, wz) + 2.0, wz)
