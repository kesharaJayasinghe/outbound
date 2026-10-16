extends Node3D

## A placeable transistor radio (models/radio.tscn). It stays silent until builder.gd
## calls `built()`, so the placement preview never plays. The interaction menu shows its
## `menu_actions()` while the player faces it: switch it on or off, and skip to the next
## song. It plays the playlist in order and starts over at the end. The playlist runs
## "live": switching on lands wherever the clock says it is, often mid-song. Switching on
## and skipping play a burst of static first. The sound is 3D, on a "Radio" bus (made in
## code) that band-limits it like a small speaker and sends it on to Ambience, like other
## outdoor sounds.

## `volume` evens out the tracks' loudness (dB; track1 is about -22.5 LUFS, track2 -15).
## The tracks must not loop on import, or the next one never starts.
const PLAYLIST := [
	{"name": "Track 1", "stream": preload("res://audio/radio/track1.wav"), "volume": 6.0},
	{"name": "Track 2", "stream": preload("res://audio/radio/track2.wav"), "volume": -1.0},
]
const RADIO_BUS = &"Radio"
const MUSIC_VOLUME = 6.0
const BUS_BOOST = 8.0       # Extra gain on the Radio bus (dB), so it carries over the surf
const LOUDNESS_RANGE = 8.0  # Full volume within this distance (unit_size), then fading
const TUNING = preload("res://audio/radio/tuning.wav")
const TUNING_OVERLAP = 0.35   # Music starts this long before the static ends (seconds)
const DIAL_GLOW = Color(1.0, 0.75, 0.35)

var on := false
var track := 0
var music: AudioStreamPlayer3D
var static_player: AudioStreamPlayer3D
var dial_material: StandardMaterial3D


## Called once the radio is placed in the world: sets up its speakers and switches it on
func built() -> void:
	_ensure_bus()
	music = _speaker(&"Music", MUSIC_VOLUME)
	music.finished.connect(_next_in_playlist)
	static_player = _speaker(&"Static", 0.0)
	static_player.stream = TUNING
	var dial := get_node_or_null("Dial") as MeshInstance3D
	if dial:
		dial_material = (dial.get_active_material(0) as StandardMaterial3D).duplicate()
		dial.material_override = dial_material
	switch(true)


## The shared "Radio" bus: cuts the lows and highs and squeezes the dynamics so the
## music sounds like it comes out of a small speaker
static func _ensure_bus() -> void:
	if AudioServer.get_bus_index(RADIO_BUS) >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, RADIO_BUS)
	AudioServer.set_bus_send(i, &"Ambience")
	AudioServer.set_bus_volume_db(i, BUS_BOOST)
	var low_cut := AudioEffectHighPassFilter.new()
	low_cut.cutoff_hz = 220.0
	low_cut.db = AudioEffectFilter.FILTER_24DB
	var high_cut := AudioEffectLowPassFilter.new()
	high_cut.cutoff_hz = 4200.0
	high_cut.db = AudioEffectFilter.FILTER_24DB
	var presence := AudioEffectEQ6.new()
	presence.set_band_gain_db(4, 3.0)  # 3.2 kHz band
	var squash := AudioEffectCompressor.new()
	squash.threshold = -18.0
	squash.ratio = 3.0
	squash.gain = 4.0
	var limiter := AudioEffectHardLimiter.new()  # The boost mustn't clip
	limiter.ceiling_db = -0.5
	for effect in [low_cut, high_cut, presence, squash, limiter]:
		AudioServer.add_bus_effect(i, effect)


func _speaker(node_name: StringName, volume: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.name = node_name
	p.bus = RADIO_BUS
	p.volume_db = volume
	p.unit_size = LOUDNESS_RANGE
	p.max_db = 12.0
	p.max_distance = 70.0
	p.position = Vector3(0.0, 0.12, 0.05)
	add_child(p)
	return p


func switch(state: bool) -> void:
	on = state
	if dial_material:
		dial_material.emission_enabled = on
		dial_material.emission = DIAL_GLOW
		dial_material.emission_energy_multiplier = 0.8
	if on:
		_tune()
	else:
		music.stop()
		static_player.stop()


## Skips to the start of the next song
func skip() -> void:
	track = (track + 1) % PLAYLIST.size()
	if on:
		_tune(0.0)


## Static, then the music: from `from` seconds into the current track, or where the
## clock says the playlist is if `from` is negative
func _tune(from := -1.0) -> void:
	music.stop()
	static_player.play()
	var tuned := track
	await get_tree().create_timer(TUNING.get_length() - TUNING_OVERLAP).timeout
	if not on or track != tuned or not is_inside_tree():
		return
	if from < 0.0:
		from = _live_position()
	_play(from)


## Picks the track and offset the playlist would be at now if it had been playing since
## the game started
func _live_position() -> float:
	var total := 0.0
	for entry: Dictionary in PLAYLIST:
		total += (entry.stream as AudioStream).get_length()
	var at := fmod(Time.get_ticks_msec() / 1000.0, total)
	for i in PLAYLIST.size():
		var length: float = (PLAYLIST[i].stream as AudioStream).get_length()
		if at < length:
			track = i
			return at
		at -= length
	return 0.0


func _play(from: float) -> void:
	music.stream = PLAYLIST[track].stream
	music.volume_db = MUSIC_VOLUME + PLAYLIST[track].volume
	music.play(from)


## A song finished: straight on to the next, no static
func _next_in_playlist() -> void:
	if not on:
		return
	track = (track + 1) % PLAYLIST.size()
	_play(0.0)


## Rows for the interaction menu while the player faces the radio
func menu_actions() -> Array[Dictionary]:
	var now_playing := "Playing %s." % PLAYLIST[track].name
	var rows: Array[Dictionary] = []
	rows.append({"label": "Turn radio off" if on else "Turn radio on",
			"detail": now_playing if on else "", "action": switch.bind(not on)})
	if on:
		var upcoming: String = PLAYLIST[(track + 1) % PLAYLIST.size()].name
		rows.append({"label": "Next song", "detail": "%s Next: %s." % [now_playing, upcoming],
				"action": skip})
	return rows
