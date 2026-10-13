extends Node

## Ambient soundscape that follows the player around the island:
## - surf from the nearest stretch of shoreline (positional, so it has direction)
## - distant, muffled sea that carries further the higher you climb
## - birdsong in the forest, thinning out on open ground and high up
## - wind that picks up with altitude and on exposed ground

const SEA_SHORE = preload("res://audio/sea_shore.wav")
const SEA_DISTANT = preload("res://audio/sea_distant.wav")
const BIRDS = preload("res://audio/birds.wav")
const WIND = preload("res://audio/wind.wav")

const UPDATE_INTERVAL = 0.2   # Seconds between shoreline searches
const FADE_RATE = 1.5         # How quickly bed volumes follow their targets
const STARTUP_FADE = 3.0      # Seconds to fade the world in

var gen: Node3D
var forest_noise: FastNoiseLite
var player: Node3D
var shore_points := PackedVector3Array()
var surf_target := Vector3.ZERO
var search_timer := 0.0
var startup := 0.0

var surf: AudioStreamPlayer3D
var distant_sea: AudioStreamPlayer
var birds: AudioStreamPlayer
var wind: AudioStreamPlayer


func setup(generator: Node3D, vegetation: Node) -> void:
	gen = generator
	player = gen.get_node_or_null("Player") as Node3D
	if vegetation and "forest_noise" in vegetation:
		forest_noise = vegetation.forest_noise
	if gen.water_enabled:
		_find_shoreline()

	surf = AudioStreamPlayer3D.new()
	surf.stream = SEA_SHORE
	surf.bus = &"Ambience"
	surf.unit_size = 14.0
	surf.max_distance = 260.0
	surf.volume_db = -80.0
	add_child(surf)

	distant_sea = _bed(SEA_DISTANT)
	birds = _bed(BIRDS)
	wind = _bed(WIND)

	if not shore_points.is_empty() and player:
		surf_target = _nearest_shore(player.global_position)
		surf.global_position = surf_target
	# Start each loop at a random point so runs don't always sound identical
	for p in [surf, distant_sea, birds, wind]:
		p.play(randf() * p.stream.get_length())


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


func _nearest_shore(from: Vector3) -> Vector3:
	var best := shore_points[0]
	var best_d := INF
	for p in shore_points:
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
			surf_target = _nearest_shore(pos)
		surf.global_position = surf.global_position.lerp(surf_target, 1.0 - exp(-2.0 * delta))
		surf.volume_db = linear_to_db(startup) + 2.0
		_fade(distant_sea, (0.25 + 0.6 * smoothstep(0.1, 0.6, altitude)) * 0.8, delta)
	else:
		surf.volume_db = -80.0
		_fade(distant_sea, 0.0, delta)

	_fade(birds, lerpf(0.2, 1.0, forest) * (1.0 - smoothstep(0.45, 0.8, altitude)), delta)
	_fade(wind, (0.2 + 0.8 * smoothstep(0.1, 0.7, altitude)) * (1.0 - 0.35 * forest) * 0.8, delta)


func _fade(p: AudioStreamPlayer, target_linear: float, delta: float) -> void:
	var current := db_to_linear(p.volume_db)
	var next := lerpf(current, target_linear * startup, 1.0 - exp(-FADE_RATE * delta))
	p.volume_db = linear_to_db(maxf(next, 0.0001))
