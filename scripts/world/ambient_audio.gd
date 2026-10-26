extends Node

## Ambient soundscape that follows the player around the island:
## - surf from the nearest stretch of shoreline (positional, so it has direction)
## - distant, muffled sea: near the coast and from high up, fading out deep inland
## - birdsong in the forest, thinning out on open ground and high up, and quiet at night
## - wind that picks up with altitude and on exposed ground
## - a babbling river from the nearest flowing stretch, and rushing water near rapids
## - at night (day_night.gd): a jungle chorus of insects and frogs in the forest, quiet
##   crickets inland (not by the beach), frogs croaking from the nearest lake or river bank, and now and then an owl
##   hooting from the trees somewhere around, sometimes answered by another

const SEA_SHORE = preload("res://audio/sea_shore.wav")
const SEA_DISTANT = preload("res://audio/sea_distant.wav")
const BIRDS = preload("res://audio/birds.wav")
const WIND = preload("res://audio/wind.wav")
const RIVER_BABBLE = preload("res://audio/river_babble.wav")
const RIVER_RUSH = preload("res://audio/river_rush.wav")
const NIGHT_JUNGLE = preload("res://audio/night/night_jungle.wav")
const CRICKETS = preload("res://audio/night/crickets.wav")
const FROGS = preload("res://audio/night/frogs.wav")
const OWLS: Array[AudioStream] = [preload("res://audio/night/owl_1.wav"), preload("res://audio/night/owl_2.wav"),
		preload("res://audio/night/owl_3.wav"), preload("res://audio/night/owl_4.wav"), preload("res://audio/night/owl_5.wav")]

const UPDATE_INTERVAL = 0.2   # Seconds between shoreline searches
const FADE_RATE = 1.5         # How quickly bed volumes follow their targets
const STARTUP_FADE = 3.0      # Seconds to fade the world in
const CRICKET_LEVEL = 0.3    # Crickets' loudest (linear): a backdrop, under the frogs and owls
const CRICKET_INLAND = Vector2(30.0, 110.0)  # Metres from the shore over which they fade in
const OWL_INTERVAL = Vector2(14.0, 40.0)  # Seconds between owl calls at night
const OWL_DISTANCE = Vector2(30.0, 85.0)  # How far from the player an owl calls (metres)
const OWL_REPLY_CHANCE = 0.35             # Another owl answers from somewhere else

var gen: Node3D
var forest_noise: FastNoiseLite
var player: Node3D
var shore_points := PackedVector3Array()
var surf_target := Vector3.ZERO
var river_points := PackedVector3Array()   # Flowing inland water
var rapid_points := PackedVector3Array()   # Steep, fast stretches
var river_target := Vector3.ZERO
var rapid_target := Vector3.ZERO
var wet_points := PackedVector3Array()     # All lake and river water, for the frogs
var frog_target := Vector3.ZERO
var owl_timer := 0.0
var owl_reply := 0.0                       # Countdown to an answering call (0 = none due)
var rng := RandomNumberGenerator.new()
var search_timer := 0.0
var startup := 0.0

var surf: AudioStreamPlayer3D
var distant_sea: AudioStreamPlayer
var birds: AudioStreamPlayer
var wind: AudioStreamPlayer
var river: AudioStreamPlayer3D
var rapids: AudioStreamPlayer3D
var jungle: AudioStreamPlayer
var crickets: AudioStreamPlayer
var frogs: AudioStreamPlayer3D
var owl: AudioStreamPlayer3D


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
	frogs = _emitter(FROGS, 9.0, 140.0)
	owl = _emitter(OWLS[0], 16.0, 220.0)
	owl.volume_db = 0.0
	owl_timer = rng.randf_range(4.0, OWL_INTERVAL.x)

	distant_sea = _bed(SEA_DISTANT)
	birds = _bed(BIRDS)
	wind = _bed(WIND)
	jungle = _bed(NIGHT_JUNGLE)
	crickets = _bed(CRICKETS)

	if player:
		for e in [[surf, shore_points], [river, river_points], [rapids, rapid_points], [frogs, wet_points]]:
			if not e[1].is_empty():
				e[0].global_position = _nearest(e[1], player.global_position)
		surf_target = surf.global_position
		river_target = river.global_position
		rapid_target = rapids.global_position
		frog_target = frogs.global_position
	# Start each loop at a random point so runs don't always sound identical
	for p in [surf, distant_sea, birds, wind, river, rapids, jungle, crickets, frogs]:
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
## of the water surface). Still lake water is left out of the river sounds (it makes no
## sound of its own), but all of it goes in wet_points, where the frogs are.
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
			wet_points.append(p)
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
			if not wet_points.is_empty():
				frog_target = _nearest(wet_points, pos)
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
	_night(pos, altitude, forest, dark, delta)
	_fade(wind, (0.2 + 0.8 * smoothstep(0.1, 0.7, altitude)) * (1.0 - 0.35 * forest) * 0.8, delta)


## The night chorus: insects and frogs where there's forest, quiet crickets away from the
## shore, both fading out high up and out at sea; frogs at the nearest water; owls now and then
func _night(pos: Vector3, altitude: float, forest: float, dark: float, delta: float) -> void:
	var land := 1.0
	var ground: float = gen.get_height(pos.x, pos.z)
	if ground < gen.water_surface() and not shore_points.is_empty():
		land = 1.0 - smoothstep(15.0, 120.0, pos.distance_to(surf_target))  # Swimming away from the island
	var low := 1.0 - smoothstep(0.5, 0.85, altitude)
	_fade(jungle, dark * land * low * lerpf(0.15, 0.9, forest), delta)
	var inland := 1.0
	if not shore_points.is_empty():
		inland = smoothstep(CRICKET_INLAND.x, CRICKET_INLAND.y, pos.distance_to(surf_target))
	_fade(crickets, dark * land * low * inland * CRICKET_LEVEL, delta)

	if wet_points.is_empty():
		frogs.volume_db = -80.0
	else:
		frogs.global_position = frogs.global_position.lerp(frog_target, 1.0 - exp(-2.0 * delta))
		frogs.volume_db = linear_to_db(maxf(startup * dark, 0.0001)) + 2.0

	if dark < 0.7 or forest_noise == null:
		return
	if owl_reply > 0.0:
		owl_reply -= delta
		if owl_reply <= 0.0:
			_hoot(pos, false)
	owl_timer -= delta
	if owl_timer <= 0.0:
		owl_timer = rng.randf_range(OWL_INTERVAL.x, OWL_INTERVAL.y)
		_hoot(pos, true)


## An owl call from a tree somewhere in the forest around the player (no call if there's
## no forest nearby)
func _hoot(around: Vector3, may_reply: bool) -> void:
	for attempt in 10:
		var angle := rng.randf() * TAU
		var spot := around + Vector3(cos(angle), 0.0, sin(angle)) * rng.randf_range(OWL_DISTANCE.x, OWL_DISTANCE.y)
		var ground: float = gen.get_height(spot.x, spot.z)
		if ground < gen.water_surface() + 2.0 or forest_noise.get_noise_2d(spot.x, spot.z) * 0.5 + 0.5 < 0.45:
			continue
		owl.stream = OWLS[rng.randi() % OWLS.size()]
		owl.pitch_scale = rng.randf_range(0.92, 1.06)
		owl.volume_db = rng.randf_range(-4.0, 0.0)
		owl.global_position = Vector3(spot.x, ground + rng.randf_range(8.0, 16.0), spot.z)
		owl.play()
		if may_reply and rng.randf() < OWL_REPLY_CHANCE:
			owl_reply = owl.stream.get_length() + rng.randf_range(1.5, 4.0)
		return


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
