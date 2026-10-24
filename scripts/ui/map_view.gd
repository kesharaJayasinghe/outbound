extends CanvasLayer

## Full-screen island map, opened from the interaction menu. The map itself is drawn
## by shaders/map.gdshader from the terrain data; on top are the player (an arrow
## pointing where the camera faces) and placed structures. The game pauses while it's
## open. Below the map: the player's coordinates, the compass bearing they face and the time.
## It opens framed on the land (all the islands); scroll (mouse wheel or trackpad)
## zooms in around the player. M, Esc or right-click closes it.

const MAP_SHADER = preload("res://shaders/map.gdshader")

const CLOSEST_VIEW = 90.0   # Most zoomed in: metres across the view
const LAND_MARGIN = 0.12    # Space around the land in the opening view (fraction of it)
const ZOOM_STEP = 1.25
const PAN_STEP = 1.0        # Trackpad scroll per zoom step (see builder.gd)
const PLAYER_COLOR = Color(1.0, 0.86, 0.2)
const STRUCTURE_COLOR = Color(0.95, 0.5, 0.25)
const COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

var gen: Node3D
var player: Node3D
var structures: Node3D
var view_scale := 1.0
var home_origin := Vector2.ZERO  # Opening view: frames all the land
var home_scale := 1.0
var min_scale := 0.1
var pan_accum := 0.0

var dim: ColorRect
var frame_panel: PanelContainer
var map_rect: ColorRect
var markers: Control
var position_label: Label
var map_material := ShaderMaterial.new()


func setup(generator: Node3D, player_node: Node3D, structures_node: Node3D) -> void:
	gen = generator
	player = player_node
	structures = structures_node
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS  # Runs while the game is paused
	visible = false

	map_material.shader = MAP_SHADER
	map_material.set_shader_parameter("terrain", _terrain_texture())
	map_material.set_shader_parameter("max_height", gen.max_height)
	map_material.set_shader_parameter("water_level", gen.water_level if gen.water_enabled else -10.0)
	map_material.set_shader_parameter("beach_height", gen.beach_height)
	map_material.set_shader_parameter("cell_size", gen.cell_size)
	map_material.set_shader_parameter("map_size", float(gen.size))
	_frame_land()
	min_scale = minf(CLOSEST_VIEW / ((gen.size - 1) * gen.cell_size), home_scale)
	_build_ui()


## The square part of the map (texture coordinates) that holds all the land, with a margin
func _frame_land() -> void:
	var n: int = gen.size
	var lo := Vector2(n, n)
	var hi := Vector2(-1, -1)
	var heights: PackedFloat32Array = gen.heights
	for z in range(0, n, 2):
		for x in range(0, n, 2):
			if heights[z * n + x] > gen.water_level:
				lo = lo.min(Vector2(x, z))
				hi = hi.max(Vector2(x, z))
	if hi.x < 0:
		return  # No land: show everything
	var side := maxf(hi.x - lo.x, hi.y - lo.y) * (1.0 + LAND_MARGIN * 2.0) / n
	home_scale = minf(side, 1.0)
	var centre := (lo + hi) * 0.5 / n
	home_origin = (centre - Vector2.ONE * home_scale * 0.5).clamp(Vector2.ZERO, Vector2.ONE * (1.0 - home_scale))


## R = height, G = lake / river coverage, B = water surface, per terrain vertex
func _terrain_texture() -> ImageTexture:
	var n: int = gen.size
	var data := PackedFloat32Array()
	data.resize(n * n * 4)
	var heights: PackedFloat32Array = gen.heights
	var inland: PackedFloat32Array = gen.inland_mask
	var water: PackedFloat32Array = gen.water_height
	for i in n * n:
		data[i * 4] = heights[i]
		data[i * 4 + 1] = inland[i] if inland.size() == n * n else 0.0
		data[i * 4 + 2] = water[i] if water.size() == n * n else 0.0
		data[i * 4 + 3] = 1.0
	return ImageTexture.create_from_image(Image.create_from_data(n, n, false, Image.FORMAT_RGBAF, data.to_byte_array()))


func open() -> void:
	view_scale = home_scale
	visible = true
	get_tree().paused = true
	_update_view()


func close() -> void:
	visible = false
	get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var steps := 0
	if event is InputEventPanGesture:
		pan_accum += -event.delta.y
		steps = int(pan_accum / PAN_STEP)
		pan_accum -= steps * PAN_STEP
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				steps = 1
			MOUSE_BUTTON_WHEEL_DOWN:
				steps = -1
			MOUSE_BUTTON_RIGHT:
				close()
	elif event.is_action_pressed(&"interaction_menu") or event.is_action_pressed(&"ui_cancel"):
		close()
	if steps != 0:
		view_scale = clampf(view_scale / pow(ZOOM_STEP, steps), min_scale, home_scale)
	get_viewport().set_input_as_handled()  # The map has the controls while it's open


func _process(_delta: float) -> void:
	if visible:
		_update_view()


# --- Coordinates -----------------------------------------------------------------

## Map texture coordinates (0..1 across the terrain) of a world position
func _world_to_uv(p: Vector3) -> Vector2:
	var half: float = (gen.size - 1) * 0.5
	return (Vector2(p.x, p.z) / gen.cell_size + Vector2(half + 0.5, half + 0.5)) / gen.size


## Shows view_scale of the map: the opening view, or zoomed in centred on the player
## (kept inside the map)
func _update_view() -> void:
	var centre := _world_to_uv(player.global_position)
	var origin := home_origin
	if view_scale < home_scale - 1e-4:
		origin = (centre - Vector2.ONE * view_scale * 0.5).clamp(Vector2.ZERO, Vector2.ONE * (1.0 - view_scale))
	map_material.set_shader_parameter("view_origin", origin)
	map_material.set_shader_parameter("view_scale", view_scale)
	markers.set_meta(&"origin", origin)
	markers.queue_redraw()

	var p := player.global_position
	var bearing := _bearing()
	position_label.text = "X %d   Z %d   Elevation %d m      Bearing %03d° %s" % [
			roundi(p.x), roundi(p.z), roundi(p.y), roundi(bearing) % 360, COMPASS[roundi(bearing / 45.0) % 8]]
	if gen.day_night:
		position_label.text += "      %s" % gen.day_night.clock()


## Compass bearing the camera faces, in degrees: 0 = north (-Z), 90 = east (+X)
func _bearing() -> float:
	var cam: Camera3D = player.camera
	var look := -cam.global_basis.z
	return fposmod(rad_to_deg(atan2(look.x, -look.z)), 360.0)


# --- UI ------------------------------------------------------------------------------

func _build_ui() -> void:
	dim = ColorRect.new()
	dim.color = Color(0.02, 0.04, 0.06, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	centre.add_child(column)

	var title := Label.new()
	title.text = "Map"
	title.add_theme_font_size_override("font_size", 22)
	column.add_child(title)

	frame_panel = PanelContainer.new()
	var border := StyleBoxFlat.new()
	border.bg_color = Color(0.9, 0.86, 0.75)
	border.set_content_margin_all(4)
	border.set_corner_radius_all(4)
	frame_panel.add_theme_stylebox_override("panel", border)
	column.add_child(frame_panel)

	map_rect = ColorRect.new()
	map_rect.material = map_material
	map_rect.clip_contents = true
	frame_panel.add_child(map_rect)
	markers = Control.new()
	markers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	markers.draw.connect(_draw_markers)
	map_rect.add_child(markers)

	position_label = Label.new()
	position_label.add_theme_font_size_override("font_size", 15)
	column.add_child(position_label)
	var help := Label.new()
	help.text = "Scroll  Zoom · M / Esc / Right-click  Close"
	help.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	help.add_theme_font_size_override("font_size", 13)
	column.add_child(help)

	get_viewport().size_changed.connect(_fit)
	_fit()


## Keeps the map square and as big as the window allows
func _fit() -> void:
	var view := get_viewport().get_visible_rect().size
	var side := floorf(minf(view.x, view.y * 0.8) * 0.8)  # Room for the lines below
	map_rect.custom_minimum_size = Vector2(side, side)


func _draw_markers() -> void:
	if not markers.has_meta(&"origin"):
		return
	var origin: Vector2 = markers.get_meta(&"origin")
	var size := markers.size
	var to_px := func(p: Vector3) -> Vector2: return (_world_to_uv(p) - origin) / view_scale * size

	# North marker
	var font := markers.get_theme_default_font()
	markers.draw_string(font, Vector2(size.x - 28, 30), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.1, 0.1, 0.1, 0.8))
	markers.draw_line(Vector2(size.x - 22, 36), Vector2(size.x - 22, 56), Color(0.1, 0.1, 0.1, 0.8), 2.0)

	for building: Node3D in structures.get_children():
		if building.is_queued_for_deletion():
			continue
		var p: Vector2 = to_px.call(building.global_position)
		markers.draw_rect(Rect2(p - Vector2(6, 6), Vector2(12, 12)), STRUCTURE_COLOR)
		markers.draw_rect(Rect2(p - Vector2(6, 6), Vector2(12, 12)), Color(0.2, 0.1, 0.05), false, 2.0)

	# Player: an arrow pointing where the camera looks
	var cam: Camera3D = player.camera
	var look := -cam.global_basis.z
	var forward := Vector2(look.x, look.z).normalized()
	var right := Vector2(-forward.y, forward.x)
	var at: Vector2 = to_px.call(player.global_position)
	var arrow := PackedVector2Array([at + forward * 13, at - forward * 8 + right * 8, at - forward * 3, at - forward * 8 - right * 8])
	markers.draw_colored_polygon(arrow, PLAYER_COLOR)
	arrow.append(arrow[0])
	markers.draw_polyline(arrow, Color(0.15, 0.1, 0.0), 2.0)
