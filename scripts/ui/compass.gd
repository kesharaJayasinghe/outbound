extends Control

## The compass bar at the top centre of the screen. A strip of bearings scrolls past as the
## camera turns: ticks every 15°, N / E / S / W (N picked out) and the in-between points,
## with the exact bearing under the centre notch. Placed structures (shelter, radio) show as
## markers at their bearing, with how far away they are, in the map's colour. Bearings
## match the map: 0° = north (-Z), 90° = east (+X).

const MAP_VIEW = preload("res://scripts/ui/map_view.gd")

const BAR_SIZE = Vector2(560, 30)
const TOP_MARGIN = 14.0
const SPAN = 150.0             # Degrees of bearing across the whole bar
const TICK_STEP = 15
const LABELS := {0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW"}
const NORTH_COLOR = Color(1.0, 0.45, 0.35)
const TEXT_COLOR = Color(1, 1, 1)
const BAR_COLOR = Color(0.05, 0.07, 0.06, 0.55)
const MARKER_RANGE = 2000.0    # Don't show structures further away than this (metres)

var player: Node3D
var structures: Node3D


func setup(player_node: Node3D, structures_node: Node3D) -> void:
	player = player_node
	structures = structures_node
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	offset_left = -BAR_SIZE.x * 0.5
	offset_right = BAR_SIZE.x * 0.5
	offset_top = TOP_MARGIN
	offset_bottom = TOP_MARGIN + BAR_SIZE.y + 42.0  # Room for the bearing and distances below


func _process(_delta: float) -> void:
	queue_redraw()


## Compass bearing the camera faces, in degrees (as on the map)
func _bearing() -> float:
	var look: Vector3 = -(player.camera as Camera3D).global_basis.z
	return fposmod(rad_to_deg(atan2(look.x, -look.z)), 360.0)


## Where a bearing falls on the bar (x, from its left edge), or NAN if it's off the bar
func _x_of(bearing: float, facing: float) -> float:
	var off := wrapf(bearing - facing, -180.0, 180.0)
	if absf(off) > SPAN * 0.5:
		return NAN
	return BAR_SIZE.x * 0.5 + off / SPAN * BAR_SIZE.x


## Things fade out towards the ends of the bar
func _fade(x: float) -> float:
	var from_centre := absf(x - BAR_SIZE.x * 0.5) / (BAR_SIZE.x * 0.5)
	return 1.0 - smoothstep(0.7, 1.0, from_centre)


func _draw() -> void:
	if player == null:
		return
	var font := get_theme_default_font()
	var facing := _bearing()
	var mid := BAR_SIZE.y * 0.5

	var bar := StyleBoxFlat.new()
	bar.bg_color = BAR_COLOR
	bar.set_corner_radius_all(6)
	draw_style_box(bar, Rect2(Vector2.ZERO, BAR_SIZE))

	# Ticks and the compass points
	for b in range(0, 360, TICK_STEP):
		var x := _x_of(b, facing)
		if is_nan(x):
			continue
		var alpha := _fade(x)
		if LABELS.has(b):
			var cardinal := b % 90 == 0
			var font_size := 17 if cardinal else 13
			var colour := NORTH_COLOR if b == 0 else TEXT_COLOR
			colour.a = alpha * (1.0 if cardinal else 0.8)
			_text(font, LABELS[b], Vector2(x, mid + font_size * 0.36), font_size, colour)
		else:
			draw_line(Vector2(x, mid - 4.0), Vector2(x, mid + 4.0), Color(1, 1, 1, 0.45 * alpha), 1.5)

	# Placed structures: a marker at their bearing, and the distance under the bar
	if structures:
		var at := player.global_position
		for building: Node3D in structures.get_children():
			if building.is_queued_for_deletion():
				continue
			var to := building.global_position - at
			var dist := Vector2(to.x, to.z).length()
			if dist < 1.0 or dist > MARKER_RANGE:
				continue
			var x := _x_of(fposmod(rad_to_deg(atan2(to.x, -to.z)), 360.0), facing)
			if is_nan(x):
				continue
			var alpha := _fade(x)
			var colour := MAP_VIEW.STRUCTURE_COLOR
			colour.a = alpha
			var box := Rect2(Vector2(x - 3.5, 1.5), Vector2(7.0, 7.0))
			draw_rect(box, colour)
			draw_rect(box, Color(0.2, 0.1, 0.05, alpha), false, 1.5)
			# Under the bar; lower down when it's near the middle, clear of the bearing
			var y := BAR_SIZE.y + (38.0 if absf(x - BAR_SIZE.x * 0.5) < 30.0 else 22.0)
			_text(font, "%d m" % roundi(dist), Vector2(x, y), 11, Color(colour, 0.85 * alpha))

	# Centre notch and the exact bearing
	var notch := PackedVector2Array([Vector2(BAR_SIZE.x * 0.5 - 6.0, BAR_SIZE.y + 7.0),
			Vector2(BAR_SIZE.x * 0.5 + 6.0, BAR_SIZE.y + 7.0), Vector2(BAR_SIZE.x * 0.5, BAR_SIZE.y)])
	draw_colored_polygon(notch, TEXT_COLOR)
	_text(font, "%03d°" % (roundi(facing) % 360), Vector2(BAR_SIZE.x * 0.5, BAR_SIZE.y + 22.0), 12, Color(1, 1, 1, 0.8))


## Text centred on x, with its baseline at y, and a drop shadow like the other HUD labels
func _text(font: Font, text: String, at: Vector2, font_size: int, colour: Color) -> void:
	var w := 80.0
	var shadow := Color(0, 0, 0, 0.8 * colour.a)
	draw_string(font, at + Vector2(-w * 0.5 + 1.0, 1.0), text, HORIZONTAL_ALIGNMENT_CENTER, w, font_size, shadow)
	draw_string(font, at + Vector2(-w * 0.5, 0.0), text, HORIZONTAL_ALIGNMENT_CENTER, w, font_size, colour)
