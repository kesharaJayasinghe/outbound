extends Node3D

## Procedural terrain generator.
## Pipeline: layered noise heightmap -> hydraulic erosion -> beaches and seabed ->
## lake and river (water_carver.gd) -> mesh (analytic normals) + heightmap collision +
## sea plane + inland-water mesh. Erosion data (drainage / sediment) and the inland-water
## mask are passed to the terrain shader through vertex colours.

const TERRAIN_SHADER = preload("res://shaders/terrain.gdshader")
const WATER_SHADER = preload("res://shaders/water.gdshader")
const INLAND_WATER_SHADER = preload("res://shaders/inland_water.gdshader")
const WATER_CARVER = preload("res://scripts/world/water_carver.gd")
const VEGETATION = preload("res://scripts/world/vegetation.gd")
const AMBIENT_AUDIO = preload("res://scripts/world/ambient_audio.gd")
const WATERFALL = preload("res://scripts/world/waterfall.gd")
const CAVE = preload("res://scripts/world/cave.gd")
const BIRDS = preload("res://scripts/world/birds.gd")
const BEACH_BIRDS = preload("res://scripts/world/beach_birds.gd")
const PICKUPS = preload("res://scripts/world/pickups.gd")
const HOTBAR = preload("res://scripts/player/hotbar.gd")
const HIDDEN_SEABED_DEPTH = 24.0  # Seabed deeper than this (metres) is left out of the terrain mesh
const WATERFALL_STEP = 3.0  # Water surface drop across one cell (metres) that counts as a waterfall
const BUILDER = preload("res://scripts/build/builder.gd")
const DAY_NIGHT = preload("res://scripts/world/day_night.gd")

## Load this baked island (see tools/bake_island.gd) instead of generating one.
## Clear it to generate from the settings below. Shape, Erosion and beach settings
## only matter when generating; the island's own size and heights come from the bake.
@export var baked_island: Resource

@export_group("Shape")
@export var resolution: int = 256          ## Cells per side (vertices per side = resolution + 1)
@export var cell_size: float = 2.0         ## Metres between vertices
@export var max_height: float = 90.0       ## Height of the tallest peak in metres
@export var terrain_seed: int = 71195        ## 0 = new random terrain every run
@export var island: bool = true            ## Sink the map border into the sea, making an island

@export_group("Erosion")
@export var erosion_droplets: int = 70000  ## More droplets = deeper, more defined gullies (slower)
@export var erosion_radius: int = 2

@export_group("Water")
@export var water_enabled: bool = true
@export_range(0.0, 1.0) var water_level: float = 0.08  ## Fraction of max_height
@export_range(0.0, 0.95) var beach_flatness: float = 0.75  ## Flattens the coast into wide beaches (0 = off)
@export var beach_height: float = 2.4      ## Metres above the water that sand reaches

@export_group("Lake and River")
@export var lake_and_river: bool = true    ## Carve a hillside lake with a river running to the sea
@export var lake_radius: float = 24.0      ## Metres (the shoreline is irregular around this)
@export var lake_depth: float = 4.0        ## Metres at the centre
@export var river_width: float = 7.0       ## Metres near the lake; widens downstream
@export var river_depth: float = 1.1       ## Metres at the centre near the lake; deepens downstream
@export var waterfall: bool = true         ## A second river from the lake, over a cliff as a waterfall
@export var waterfall_cave: bool = true    ## A hidden grotto behind the waterfall, reached from a ledge behind the curtain
@export_range(0.0, 360.0) var waterfall_bearing: float = 270.0  ## Compass direction from the lake to look for a cliff (0 = north/-Z, 90 = east/+X)

@export_group("Islet")
@export var islet: bool = true             ## A small, low, sandy island off the main one
@export var world_resolution: int = 640    ## Cells per side of the whole world; the main island sits in the middle (must exceed `resolution` by an even number)
@export var islet_center: Vector2 = Vector2(-410.0, 210.0)  ## World X, Z (metres)
@export_range(0.05, 1.0) var islet_area: float = 0.3  ## Land area as a fraction of the main island's

@export_group("Vegetation")
@export var vegetation_enabled: bool = true
@export var grass_enabled: bool = true
@export_range(0.0, 3.0) var tree_density: float = 1.0
@export_range(0.0, 3.0) var bush_density: float = 1.0
@export_range(0.0, 3.0) var rock_density: float = 1.0

@export_group("Wildlife")
@export var birds_enabled: bool = true     ## Seabirds circling over the coasts, and gulls on the beaches

@export_group("Day and Night")
@export var day_night_cycle: bool = true   ## Let time pass (off: the clock stays at the start hour)
@export_range(0.0, 24.0) var start_hour: float = 20.0
@export_range(1.0, 120.0) var day_length_minutes: float = 24.0  ## Real minutes for a whole day, night included
@export_range(1.0, 6.0) var night_speed: float = 2.0  ## Night hours pass this many times faster than day hours

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
var water_height := PackedFloat32Array() # Water surface per vertex (normalised): sea level, or lake/river level inland
var inland_mask := PackedFloat32Array()  # 1 where a lake or river covers the vertex
var inland_flow := PackedVector2Array()  # Smoothed downstream direction x speed (0..1) per vertex
var waterfalls: Array[Dictionary] = []   # {top (lip, metres), dir, drop, width} per fall, from water_carver.gd
var islets: Array[Dictionary] = []       # {center (world X, Z), radius (metres)} per islet
var caves: Array[Dictionary] = []        # Cave layouts (cave.gd), behind waterfalls that have one
var terrain_material: ShaderMaterial
var size := 0                          # Vertices per side
var day_night: Node                    # day_night.gd: the clock, sun, moon and sky
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	var t := Time.get_ticks_msec()
	day_night = DAY_NIGHT.new()
	day_night.name = "DayNight"
	add_child(day_night)
	var world_env := get_node_or_null("WorldEnvironment") as WorldEnvironment
	day_night.setup(get_node_or_null("DirectionalLight3D") as DirectionalLight3D,
			world_env.environment if world_env else null, start_hour, day_length_minutes * 60.0,
			night_speed, day_night_cycle)
	if baked_island:
		_load_baked(baked_island)
	else:
		generate()
	_compute_inland_flow()
	caves.clear()
	for fall in waterfalls:
		if fall.get("cave", false):
			caves.append(CAVE.layout(self, fall))
	_build_terrain()
	if water_enabled:
		_build_water()
		_build_inland_water()
		_build_waterfalls()
	_build_caves()
	_place_player()
	print("Terrain %s in %d ms" % ["loaded" if baked_island else "generated", Time.get_ticks_msec() - t])
	var vegetation: Node3D = null
	if vegetation_enabled:
		t = Time.get_ticks_msec()
		vegetation = VEGETATION.new()
		vegetation.name = "Vegetation"
		add_child(vegetation)
		vegetation.build(self)
		print("Vegetation generated in %d ms" % (Time.get_ticks_msec() - t))
	if birds_enabled and water_enabled:
		var birds := BIRDS.new()
		birds.name = "Birds"
		add_child(birds)
		birds.build(self)
		var beach_birds := BEACH_BIRDS.new()
		beach_birds.name = "BeachBirds"
		add_child(beach_birds)
		beach_birds.build(self)
	if audio_enabled:
		var ambience := AMBIENT_AUDIO.new()
		ambience.name = "AmbientAudio"
		add_child(ambience)
		ambience.setup(self, vegetation)
	var player := get_node_or_null("Player") as CharacterBody3D
	if player:
		var builder := BUILDER.new()
		builder.name = "Builder"
		add_child(builder)
		builder.setup(self, player)
		if vegetation:
			var pickups := PICKUPS.new()
			pickups.name = "Pickups"
			add_child(pickups)
			pickups.setup(self, player, vegetation, builder)
			var hotbar := HOTBAR.new()
			hotbar.name = "Hotbar"
			add_child(hotbar)
			hotbar.setup(self, player, builder, pickups, get_node_or_null("BeachBirds"), vegetation)


## Runs the procedural pipeline (no scene nodes are built). Used by _ready and by the
## bake tool.
## Drives the sky's cloud drift (shaders/sky.gdshader). It's a global shader parameter,
## not TIME: a sky shader that uses TIME re-renders its lighting cubemap every frame.
func _process(_delta: float) -> void:
	RenderingServer.global_shader_parameter_set(&"cloud_time", Time.get_ticks_msec() / 1000.0)


func generate() -> void:
	if terrain_seed == 0:
		terrain_seed = randi_range(1, 999999)  # Pick one so it can be reported and baked
	rng.seed = terrain_seed
	size = resolution + 1
	print("Generating island with seed %d" % terrain_seed)
	_generate_heightmap()
	_erode()
	if water_enabled:
		_shape_beaches()
	if island:
		_sink_seabed()
	water_height.resize(size * size)
	water_height.fill(water_level)
	waterfalls.clear()
	inland_mask.resize(size * size)
	inland_mask.fill(0.0)
	if water_enabled and lake_and_river:
		var result: String = WATER_CARVER.carve(self)
		print("Carved " + result if result != "" else "No suitable lake site found")
	islets.clear()
	if islet and world_resolution > resolution:
		_expand_world(world_resolution + 1)
		_add_islet()


func _load_baked(data: Resource) -> void:
	cell_size = data.cell_size
	max_height = data.max_height
	water_level = data.water_level
	terrain_seed = data.terrain_seed
	rng.seed = data.terrain_seed
	rng.state = data.rng_state

	var h: Image = data.heightmap.get_image()
	if h.get_format() != Image.FORMAT_RF:
		h.convert(Image.FORMAT_RF)
	size = h.get_width()
	resolution = size - 1
	assert(h.get_height() == size, "Baked heightmap must be square")
	heights = h.get_data().to_float32_array()

	var m: Image = data.masks.get_image()
	if m.get_format() != Image.FORMAT_RGBF:
		m.convert(Image.FORMAT_RGBF)
	assert(m.get_width() == size and m.get_height() == size, "Masks must match the heightmap size")
	var rgb := m.get_data().to_float32_array()
	flow_map.resize(size * size)
	deposit_map.resize(size * size)
	inland_mask.resize(size * size)
	for i in size * size:
		flow_map[i] = rgb[i * 3]
		deposit_map[i] = rgb[i * 3 + 1]
		inland_mask[i] = rgb[i * 3 + 2]

	if data.water:
		var w: Image = data.water.get_image()
		if w.get_format() != Image.FORMAT_RF:
			w.convert(Image.FORMAT_RF)
		assert(w.get_width() == size and w.get_height() == size, "Water map must match the heightmap size")
		water_height = w.get_data().to_float32_array()
	else:
		water_height.resize(size * size)  # Bakes from before lakes and rivers: sea only
		water_height.fill(water_level)
	waterfalls.assign(data.get("waterfalls") if data.get("waterfalls") != null else [])
	islets.assign(data.get("islets") if data.get("islets") != null else [])


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
	if floor_collider is StaticBody3D and floor_collider.name in [&"VegetationBody", &"CaveBody"]:
		return &"stone"
	var i := grid_index(pos.x, pos.z)
	if water_enabled and heights[i] < water_level + beach_height / max_height:
		return &"sand"
	if 1.0 - normal_map[i].y > 0.26:
		return &"stone"
	return &"grass"


## Sea level in metres, or -INF with water turned off.
func water_surface() -> float:
	return water_level * max_height if water_enabled else -INF


## Water surface height in metres at a world XZ position: the lake or river level
## inland, sea level elsewhere. Only meaningful where it's above the ground.
func water_surface_at(world_x: float, world_z: float) -> float:
	if not water_enabled:
		return -INF
	var half := (size - 1) * 0.5
	var gx := clampf(world_x / cell_size + half, 0.0, size - 1.001)
	var gz := clampf(world_z / cell_size + half, 0.0, size - 1.001)
	# The carver writes lake and river levels a little past their banks, to keep the
	# shoreline gap-free. Where land just outside dips below that level there's no water
	# drawn, so only count the lake or river where it actually covers the ground.
	if inland_mask.size() == size * size and _sample_map(inland_mask, gx, gz) < 0.01:
		return water_level * max_height
	return _sample_map(water_height, gx, gz) * max_height


## How deep the water is above a point, in metres (0 on dry land or with water off,
## and underground, e.g. in a cave beneath a river).
func water_depth_at(pos: Vector3) -> float:
	if not water_enabled or is_underground(pos):
		return 0.0
	return maxf(water_surface_at(pos.x, pos.z) - pos.y, 0.0)


## River current at a position (metres per second, horizontal): down the slope of the
## water surface, so lakes and the sea are still and steep stretches run fast.
func water_current_at(world_x: float, world_z: float) -> Vector3:
	if not water_enabled or inland_water_at(world_x, world_z) <= 0.0 or inland_flow.is_empty():
		return Vector3.ZERO
	var f := inland_flow[grid_index(world_x, world_z)]
	return Vector3(f.x, 0.0, f.y) * 1.5


## True below the terrain surface: inside a cave.
func is_underground(pos: Vector3) -> bool:
	return pos.y < get_height(pos.x, pos.z) - 1.0


## 0..1: how much this position belongs to an islet (1 on it and its shallows, fading
## out across the drop to open sea). Vegetation thins out there.
func islet_weight(world_x: float, world_z: float) -> float:
	var w := 0.0
	for it in islets:
		var c: Vector2 = it.center
		var r: float = it.radius
		w = maxf(w, 1.0 - smoothstep(1.4, 1.8, Vector2(world_x, world_z).distance_to(c) / r))
	return w


## 0..1: how much a lake or river covers this position (0 for the sea and dry land).
func inland_water_at(world_x: float, world_z: float) -> float:
	return inland_mask[grid_index(world_x, world_z)] if inland_mask.size() == size * size else 0.0


func _sample(x: float, z: float) -> float:
	return _sample_map(heights, x, z)


## Samples a per-vertex map across the same triangles the terrain mesh uses.
func _sample_map(map: PackedFloat32Array, x: float, z: float) -> float:
	var cx := int(x)
	var cz := int(z)
	var fx := x - cx
	var fz := z - cz
	var i := cz * size + cx
	if fx + fz <= 1.0:
		return map[i] + (map[i + 1] - map[i]) * fx + (map[i + size] - map[i]) * fz
	var h11 := map[i + size + 1]
	return h11 + (map[i + size] - h11) * (1.0 - fx) + (map[i + 1] - h11) * (1.0 - fz)


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
## Grows the world grid to `new_size` vertices per side, keeping everything generated so
## far exactly as it is in the middle. The main island's grid ends in open-sea floor
## (_sink_seabed), which carries on across the new area.
func _expand_world(new_size: int) -> void:
	assert((new_size - size) % 2 == 0, "world_resolution must exceed resolution by an even number")
	var off := (new_size - size) / 2
	var floor_h := heights[0]
	var grown := {}
	for pair in [["heights", floor_h], ["flow_map", 0.0], ["deposit_map", 0.0],
			["water_height", water_level], ["inland_mask", 0.0], ["island_edge", 2.0]]:
		var old: PackedFloat32Array = get(pair[0])
		var map := PackedFloat32Array()
		map.resize(new_size * new_size)
		map.fill(pair[1])
		if old.size() == size * size:
			for z in size:
				for x in size:
					map[(z + off) * new_size + x + off] = old[z * size + x]
		grown[pair[0]] = map
	for key in grown:
		set(key, grown[key])
	size = new_size
	resolution = new_size - 1


## A small, low island at islet_center: a sandy plateau a couple of metres above the
## sea with a few dunes (grass grows on the ones that rise above the sand line), a
## ragged coastline, a ring of shallows, then a slope down to the open-sea floor.
func _add_islet() -> void:
	const PLATEAU = 1.9       # Metres above the sea, inland
	const SHALLOWS = 2.0      # Depth at the edge of the shallow ring
	var sea := water_level * max_height
	var land := 0
	for h in heights:
		if h > water_level:
			land += 1
	var radius := sqrt(islet_area * land * cell_size * cell_size / PI)

	var coast_noise := FastNoiseLite.new()
	coast_noise.seed = terrain_seed + 2027
	coast_noise.frequency = 0.008
	var dune_noise := FastNoiseLite.new()
	dune_noise.seed = terrain_seed + 2028
	dune_noise.frequency = 0.035
	var half := (size - 1) * 0.5
	var c := islet_center / cell_size + Vector2(half, half)
	var reach := int(radius * 2.2 / cell_size) + 2
	for z in range(maxi(int(c.y) - reach, 0), mini(int(c.y) + reach + 1, size)):
		for x in range(maxi(int(c.x) - reach, 0), mini(int(c.x) + reach + 1, size)):
			var wx := (x - half) * cell_size
			var wz := (z - half) * cell_size
			var t := Vector2(x, z).distance_to(c) * cell_size / (radius * (1.0 + 0.15 * coast_noise.get_noise_2d(wx, wz)))
			if t > 1.8:
				continue
			var above := PLATEAU * smoothstep(1.0, 0.6, t) - SHALLOWS * smoothstep(1.0, 1.35, t)
			above += maxf(dune_noise.get_noise_2d(wx, wz) - 0.1, 0.0) * 6.0 * smoothstep(0.9, 0.5, t)
			var i := z * size + x
			var target := (sea + above) / max_height
			heights[i] = maxf(heights[i], lerpf(target, heights[i], smoothstep(1.35, 1.8, t)))
			deposit_map[i] = 0.0
	islets.append({"center": islet_center, "radius": radius})
	print("Added an islet at %s, %.0f m across" % [islet_center, radius * 2.0])


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
			colors[i] = Color(flow_map[i], deposit_map[i], inland_mask[i])
	normal_map = normals

	# Seabed this deep is never seen through the water (it's fully the deep colour well
	# before), so most of the open sea needs no terrain triangles
	var hidden := (water_level * max_height - HIDDEN_SEABED_DEPTH) / max_height if water_enabled else -INF
	var indices := PackedInt32Array()
	indices.resize(resolution * resolution * 6)
	var k := 0
	for z in resolution:
		for x in resolution:
			var i := z * size + x
			if maxf(maxf(heights[i], heights[i + 1]), maxf(heights[i + size], heights[i + size + 1])) < hidden:
				continue
			if _in_cave_box(x, z):
				continue  # The cave's own mesh takes over here
			indices[k] = i
			indices[k + 1] = i + 1
			indices[k + 2] = i + size
			indices[k + 3] = i + 1
			indices[k + 4] = i + size + 1
			indices[k + 5] = i + size
			k += 6
	indices.resize(k)

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

	terrain_material = mat
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
	# Holes where caves replace the terrain (NaN vertices drop every cell touching them)
	for c in caves:
		var box: Rect2i = c.box
		for z in range(box.position.y + 1, box.end.y):
			for x in range(box.position.x + 1, box.end.x):
				col_heights[z * size + x] = NAN
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


## Downstream direction and speed for every lake/river vertex: down the slope of the
## water surface (speed 1 = rapids, a slope of about 0.14), then smoothed over the
## neighbours. Where the water is nearly flat the raw slope is tiny and its direction
## is noise, so without smoothing the current would point every which way.
func _compute_inland_flow() -> void:
	var count := size * size
	inland_flow.resize(count)
	inland_flow.fill(Vector2.ZERO)
	if inland_mask.size() != count:
		return
	var wet := PackedByteArray()  # Vertices that carry inland water (or its bank margin)
	wet.resize(count)
	var sea := water_level + 0.0005
	for z in range(1, size - 1):
		for x in range(1, size - 1):
			var i := z * size + x
			if inland_mask[i] <= 0.0 and water_height[i] <= sea:
				continue
			wet[i] = 1
			var gx := (water_height[i + 1] - water_height[i - 1]) * max_height / (2.0 * cell_size)
			var gz := (water_height[i + size] - water_height[i - size]) * max_height / (2.0 * cell_size)
			var down := -Vector2(gx, gz)
			if down.length() > 1e-6:
				inland_flow[i] = down.normalized() * clampf(down.length() * 7.0, 0.0, 1.0)
	for _pass in 4:
		var smoothed := inland_flow.duplicate()
		for z in range(1, size - 1):
			for x in range(1, size - 1):
				var i := z * size + x
				if wet[i] == 0:
					continue
				var sum := Vector2.ZERO
				var n := 0
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						var j := i + dz * size + dx
						if wet[j] == 1:
							sum += inland_flow[j]
							n += 1
				smoothed[i] = sum / n
		inland_flow = smoothed


## Lake and river surfaces: one mesh over every grid cell that touches inland water,
## with each vertex at its water height, so the river surface follows its channel
## downhill. Vertex colour carries the downstream direction (RG), speed (B) and water
## coverage (A, for soft edges) for inland_water.gdshader. Edges overlap the banks and
## are hidden under them; at the river mouth the coverage fades into the sea.
func _build_inland_water() -> void:
	var half := (size - 1) * 0.5
	var used := PackedInt32Array()
	used.resize(size * size)
	used.fill(-1)
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for z in resolution:
		for x in resolution:
			var i := z * size + x
			if maxf(maxf(inland_mask[i], inland_mask[i + 1]), maxf(inland_mask[i + size], inland_mask[i + size + 1])) <= 0.01:
				continue
			# A waterfall's drop: the falling water is its own mesh (waterfall.gd)
			var lo := minf(minf(water_height[i], water_height[i + 1]), minf(water_height[i + size], water_height[i + size + 1]))
			var hi := maxf(maxf(water_height[i], water_height[i + 1]), maxf(water_height[i + size], water_height[i + size + 1]))
			if (hi - lo) * max_height > WATERFALL_STEP:
				continue
			var corners := [i, i + 1, i + size, i + size + 1]
			for v in corners:
				if used[v] < 0:
					used[v] = verts.size()
					var vx: int = v % size
					var vz: int = v / size
					verts.append(Vector3((vx - half) * cell_size, water_height[v] * max_height, (vz - half) * cell_size))
					var f := inland_flow[v]
					var speed := f.length()
					var dir := f / speed if speed > 1e-5 else Vector2.ZERO
					colors.append(Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, speed, inland_mask[v]))
			indices.append_array([used[i], used[i + 1], used[i + size], used[i + 1], used[i + size + 1], used[i + size]])
	if indices.is_empty():
		return
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = INLAND_WATER_SHADER
	var water := MeshInstance3D.new()
	water.name = "InlandWater"
	water.mesh = mesh
	water.material_override = mat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(water)


## Whether a terrain cell (by its corner vertex) is replaced by a cave's mesh
func _in_cave_box(x: int, z: int) -> bool:
	for c in caves:
		if (c.box as Rect2i).has_point(Vector2i(x, z)):
			return true
	return false


func _build_caves() -> void:
	for c in caves:
		var t := Time.get_ticks_msec()
		var node := CAVE.new()
		node.name = "Cave"
		add_child(node, true)
		node.build(self, c, terrain_material)
		print("Cave built in %d ms" % (Time.get_ticks_msec() - t))


func _build_waterfalls() -> void:
	for fall in waterfalls:
		var node := WATERFALL.new()
		node.name = "Waterfall"
		add_child(node, true)
		node.build(fall)


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
			if h < min_h or h < water_height[z * size + x] + 0.02 or inland_mask[z * size + x] > 0.0:
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
