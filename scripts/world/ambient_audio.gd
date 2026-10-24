extends Node

## Ambient soundscape that follows the player around the island:
## - surf from the nearest stretch of shoreline (positional, so it has direction)
## - distant, muffled sea: near the coast and from high up, fading out deep inland
## - birdsong in the forest, thinning out on open ground and high up, and quiet at night
## - wind that picks up with altitude and on exposed ground
## - a babbling river from the nearest flowing stretch, and rushing water near rapids

const SEA_SHORE = preload("res://audio/sea_shore.wav")
const SEA_DISTANT = preload("res://audio/sea_distant.wav")
const BIRDS = preload("res://audio/birds.wav")
const WIND = preload("res://audio/wind.wav")
const RIVER_BABBLE = preload("res://audio/river_babble.wav")
const RIVER_RUSH = preload("res://audio/river_rush.wav")

const UPDATE_INTERVAL = 0.2   # Seconds between shoreline searches
const FADE_RATE = 1.5         # How quickly bed volumes follow their targets
const STARTUP_FADE = 3.0      # Seconds to fade the world in

var gen: Node3D
var forest_noise: FastNoiseLite
var player: Node3D
var shore_points := PackedVector3Array()
var surf_target := Vector3.ZERO
var river_points := PackedVector3Array()   # Flowing inland water
var rapid_points := PackedVector3Array()   # Steep, fast stretches
var river_target := Vector3.ZERO
var rapid_target := Vector3.ZERO
var search_timer := 0.0
var startup := 0.0

var surf: AudioStreamPlayer3D
var distant_sea: AudioStreamPlayer
var birds: AudioStreamPlayer
var wind: AudioStreamPlayer
var river: AudioStreamPlayer3D
var rapids: AudioStreamPlayer3D


func setup(generator: Node3D, vegetation: Node) -> void:
	gen = generator
	player = gen.get_node_or_null("Player") as Node3D
	if vegetation and "forest_noise" in vegetation:
		forest_noise = vegetation.forest_noise
	if gen.water_enabled:
		_find_shoreline()
		_find_river()

	surf = _emitter(SEA_SHORE, 14.0, 260.0)
	river = _emitter(RIVER_BABBLE, 5.0, 90.0)
	rapids = _emitter(RIVER_RUSH, 6.0, 110.0)

	distant_sea = _bed(SEA_DISTANT)
	birds = _bed(BIRDS)
	wind = _bed(WIND)

	if player:
		for e in [[surf, shore_points], [river, river_points], [rapids, rapid_points]]:
			if not e[1].is_empty():
				e[0].global_position = _nearest(e[1], player.global_position)
		surf_target = surf.global_position
		river_target = river.global_position
		rapid_target = rapids.global_position
	# Start each loop at a random point so runs don't always sound identical
	for p in [surf, distant_sea, birds, wind, river, rapids]:
		p.play(randf() * p.stream.get_length())


func _emitter(stream: AudioStream, unit_size: float, max_distance: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = &"Ambience"
	p.unit_size = unit_size
	p.max_distance = max_distance
	p.volume_db = -80.0
	add_child(p)
	return p


func _bed(stream: AudioStream) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = &"Ambience"
	p.volume_db = -80.0
	add_child(p)
	return p


## Land vertices next to water, at water level. Sampled every other vertex,
## which is plenty for placing a sound.
func _find_shoreline() -> void:
	var size: int = gen.size
	var water: float = gen.water_level
	var half := (size - 1) * 0.5
	var heights: PackedFloat32Array = gen.heights
	for z in range(1, size - 1, 2):
		for x in range(1, size - 1, 2):
			var i := z * size + x
			if heights[i] < water:
				continue
			if heights[i - 1] < water or heights[i + 1] < water or heights[i - size] < water or heights[i + size] < water:
				shore_points.append(Vector3((x - half) * gen.cell_size, water * gen.max_height, (z - half) * gen.cell_size))


## Lake and river vertices, sorted by how fast the water there flows (from the slope
## of the water surface). Still lake water is left out: it makes no sound of its own.
func _find_river() -> void:
	if not "inland_mask" in gen or gen.inland_mask.is_empty():
		return
	var size: int = gen.size
	var half := (size - 1) * 0.5
	var cell: float = gen.cell_size
	for z in range(1, size - 1, 2):
		for x in range(1, size - 1, 2):
			var i := z * size + x
			if gen.inland_mask[i] < 0.5:
				continue
			var p := Vector3((x - half) * cell, 0.0, (z - half) * cell)
			p.y = gen.water_surface_at(p.x, p.z)
			var speed: float = gen.water_current_at(p.x, p.z).length() / 1.5
			if speed > 0.08:
				river_points.append(p)
			if speed > 0.5:
				rapid_points.append(p)


func _nearest(points: PackedVector3Array, from: Vector3) -> Vector3:
	var best := points[0]
	var best_d := INF
	for p in points:
		var d := from.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = p
	return best


func _process(delta: float) -> void:
	if player == null:
		return
	startup = minf(startup + delta / STARTUP_FADE, 1.0)
	var pos := player.global_position
	var altitude := clampf(pos.y / gen.max_height, 0.0, 1.0)

	var forest := 0.5
	if forest_noise:
		forest = smoothstep(0.35, 0.7, forest_noise.get_noise_2d(pos.x, pos.z) * 0.5 + 0.5)
	forest *= 1.0 - smoothstep(0.45, 0.7, altitude)  # Same tree line the vegetation uses

	# Surf: glide the emitter towards the nearest shoreline so switching stretches
	# of coast never makes the sound jump
	if not shore_points.is_empty():
		search_timer -= delta
		if search_timer <= 0.0:
			search_timer = UPDATE_INTERVAL
			surf_target = _nearest(shore_points, pos)
			if not river_points.is_empty():
				river_target = _nearest(river_points, pos)
			if not rapid_points.is_empty():
				rapid_target = _nearest(rapid_points, pos)
		surf.global_position = surf.global_position.lerp(surf_target, 1.0 - exp(-2.0 * delta))
		surf.volume_db = linear_to_db(startup) + 2.0
		# Inland and low down the sea is out of earshot; from high up it carries again
		var coast := 1.0 - smoothstep(40.0, 160.0, pos.distance_to(surf_target))
		_fade(distant_sea, (0.06 + 0.19 * coast + 0.6 * smoothstep(0.25, 0.8, altitude)) * 0.8, delta)
	else:
		surf.volume_db = -80.0
		_fade(distant_sea, 0.0, delta)

	_follow(river, river_target, river_points, -2.0, delta)
	_follow(rapids, rapid_target, rapid_points, 0.0, delta)

	var dark: float = gen.day_night.night if gen.day_night else 0.0
	_fade(birds, lerpf(0.2, 1.0, forest) * (1.0 - smoothstep(0.45, 0.8, altitude)) * (1.0 - 0.9 * dark), delta)
	_fade(wind, (0.2 + 0.8 * smoothstep(0.1, 0.7, altitude)) * (1.0 - 0.35 * forest) * 0.8, delta)


func _follow(p: AudioStreamPlayer3D, target: Vector3, points: PackedVector3Array, db: float, delta: float) -> void:
	if points.is_empty():
		p.volume_db = -80.0
		return
	p.global_position = p.global_position.lerp(target, 1.0 - exp(-2.0 * delta))
	p.volume_db = linear_to_db(maxf(startup, 0.0001)) + db


func _fade(p: AudioStreamPlayer, target_linear: float, delta: float) -> void:
	var current := db_to_linear(p.volume_db)
	var next := lerpf(current, target_linear * startup, 1.0 - exp(-FADE_RATE * delta))
	p.volume_db = linear_to_db(maxf(next, 0.0001))
