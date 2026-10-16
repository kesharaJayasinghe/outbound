extends Node

## The interaction menu (M, like GTA Online's), crafting and placing structures.
## Nothing is on screen until the menu is opened. It lists Map, Inventory and Craft, plus context actions
## such as taking down the structure the player faces (highlighted only while that row
## is selected). Picking a recipe the player can afford shows a see-through preview in
## front of them, green where it fits and red where it doesn't (too uneven, in water, or
## blocked by a tree, rock or another build). Click to build it, which spends the cost
## from the player's inventory. On a slope the posts (meshes named Post*) stretch down
## to meet the ground. Placed structures go under the generator's "Structures" node,
## with collision generated from their meshes.

const RECIPES = preload("res://scripts/build/recipes.gd")
const MAP_VIEW = preload("res://scripts/ui/map_view.gd")

const MIN_DISTANCE = 3.5     # Closest the preview's centre gets to the player (metres)
const MAX_DISTANCE = 9.0     # Furthest away the player can build
const AIM_RANGE = 30.0
const MAX_UNEVENNESS = 1.4   # Height difference across the footprint (the posts stretch)
const UPHILL_SINK = 0.25     # How far the structure may sink into the uphill side
const POST_SINK = 0.15       # How far a stretched post goes into the ground
const WATER_MARGIN = 0.1     # Ground must be this far above any water surface
const ROTATE_STEP = deg_to_rad(15.0)
const PAN_STEP = 1.0         # Two-finger trackpad scroll per menu / rotation step
const VALID_COLOR = Color(0.35, 1.0, 0.45, 0.4)
const INVALID_COLOR = Color(1.0, 0.3, 0.25, 0.4)
const REMOVE_REACH = 6.0     # How far from the player a structure can be taken down
const REMOVE_ANGLE = deg_to_rad(35.0)  # How directly the camera must face it

enum Mode { IDLE, MENU, PLACING }

var gen: Node3D
var player: CharacterBody3D
var inventory
var mode := Mode.IDLE
var recipe: Dictionary
var ghost: Node3D
var ghost_material := StandardMaterial3D.new()
var ghost_xray := StandardMaterial3D.new()   # Faint pass that shows through grass and bushes
var rotation_offset := 0.0
var pan_accum := 0.0        # Trackpad scroll not yet turned into a step
var placement := Transform3D()
var placement_ok := false
var structures: Node3D
var collision_cache := {}   # recipe id -> [[Transform3D, Shape3D], ...]
var highlighted: Node3D     # Structure tinted because its menu row is selected
var highlight_overlay := StandardMaterial3D.new()

## Interaction menu: the open page, its rows ({label, detail, action: Callable,
## submenu, enabled, target}) and the selected row
var menu_page := &"root"
var menu_items: Array[Dictionary] = []
var menu_index := 0
var menu_target: Node3D     # Structure the root page's context actions apply to

var hud: CanvasLayer
var map_view: CanvasLayer
var menu_panel: PanelContainer
var menu_title: Label
var menu_rows: VBoxContainer
var menu_detail: Label
var hint_label: Label
var status_label: Label
var toast_time := 0.0


func setup(generator: Node3D, player_node: CharacterBody3D) -> void:
	gen = generator
	player = player_node
	inventory = player.inventory
	structures = Node3D.new()
	structures.name = "Structures"
	gen.add_child(structures)

	_ensure_action(&"interaction_menu", KEY_M, JOY_BUTTON_TOUCHPAD)
	_ensure_action(&"rotate_build", KEY_R)

	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghost_xray.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_xray.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_xray.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghost_xray.no_depth_test = true
	ghost_material.next_pass = ghost_xray
	highlight_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	highlight_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	highlight_overlay.cull_mode = BaseMaterial3D.CULL_DISABLED
	highlight_overlay.albedo_color = Color(1.0, 0.3, 0.2, 0.3)
	_build_hud()
	map_view = MAP_VIEW.new()
	map_view.name = "MapView"
	add_child(map_view)
	map_view.setup(gen, player, structures)


## Default key (and controller button) for an input action, unless the project
## already defines it
func _ensure_action(action: StringName, key: Key, button := JOY_BUTTON_INVALID) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)
	if button != JOY_BUTTON_INVALID:
		var pad := InputEventJoypadButton.new()
		pad.button_index = button
		InputMap.action_add_event(action, pad)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interaction_menu"):
		if mode == Mode.MENU:
			_set_mode(Mode.IDLE)
		else:
			_open_menu(&"root")
		get_viewport().set_input_as_handled()
		return
	if mode == Mode.IDLE:
		return

	if event.is_action_pressed(&"ui_cancel"):
		_back()  # Instead of freeing the mouse
		get_viewport().set_input_as_handled()
		return

	var steps := _pan_steps(event) if event is InputEventPanGesture else 0
	var click: bool = event is InputEventMouseButton and event.pressed \
			and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	if mode == Mode.MENU:
		if steps != 0:
			_select(menu_index + steps)
			get_viewport().set_input_as_handled()
		elif click:
			match event.button_index:
				MOUSE_BUTTON_WHEEL_UP:
					_select(menu_index - 1)
				MOUSE_BUTTON_WHEEL_DOWN:
					_select(menu_index + 1)
				MOUSE_BUTTON_LEFT:
					_activate()
				MOUSE_BUTTON_RIGHT:
					_back()
				_:
					return
			get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.pressed and not event.echo:
			match event.physical_keycode:
				KEY_ENTER, KEY_KP_ENTER:
					_activate()
				KEY_BACKSPACE:
					_back()
				_:
					return
			get_viewport().set_input_as_handled()
		return

	# Placing
	if event.is_action_pressed(&"rotate_build"):
		rotation_offset += PI * 0.5
	elif steps != 0:
		rotation_offset -= steps * ROTATE_STEP  # Same direction as the mouse wheel
	elif click:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				rotation_offset += ROTATE_STEP
			MOUSE_BUTTON_WHEEL_DOWN:
				rotation_offset -= ROTATE_STEP
			MOUSE_BUTTON_LEFT:
				_place()
			MOUSE_BUTTON_RIGHT:
				_back()
			_:
				return
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if mode == Mode.PLACING:
		_update_placement()
	elif mode == Mode.MENU and menu_page == &"root" and _aimed_structure() != menu_target:
		_open_menu(&"root", menu_index)  # Walked up to or away from a structure
	if toast_time > 0.0:
		toast_time -= delta
		if toast_time <= 0.0:
			status_label.text = ""


func _set_mode(new_mode: Mode) -> void:
	mode = new_mode
	if mode != Mode.PLACING and ghost:
		ghost.queue_free()
		ghost = null
	menu_panel.visible = mode == Mode.MENU
	if mode != Mode.MENU:
		_highlight(null)
	hint_label.text = "Click  Build · Scroll / R  Rotate · Right-click  Back" \
			if mode == Mode.PLACING else ""
	if mode != Mode.IDLE:
		status_label.text = ""


## Two-finger scrolling on a trackpad (macOS) arrives as pan gestures rather than
## wheel clicks. Turns it into whole steps: +1 is like one click of the wheel down.
## The pan delta is negated so swiping up moves up the menu, like scrolling a page.
func _pan_steps(event: InputEventPanGesture) -> int:
	var dy := -event.delta.y
	if signf(dy) != signf(pan_accum):
		pan_accum = 0.0  # Changed direction
	pan_accum += dy
	var steps := int(pan_accum / PAN_STEP)
	pan_accum -= steps * PAN_STEP
	return steps


## One step back: placing -> craft page -> main page -> closed
func _back() -> void:
	if mode == Mode.PLACING:
		_open_menu(&"craft")
	elif mode == Mode.MENU and menu_page != &"root":
		_open_menu(&"root")
	else:
		_set_mode(Mode.IDLE)


func _choose(r: Dictionary) -> void:
	if not inventory.can_afford(r.cost):
		_toast("Not enough resources for the %s" % r.name.to_lower())
		return
	recipe = r
	rotation_offset = 0.0
	ghost = r.scene.instantiate()
	ghost.name = "BuildPreview"
	gen.add_child(ghost)
	for mi: MeshInstance3D in ghost.find_children("*", "MeshInstance3D", true, false):
		mi.material_override = ghost_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_set_mode(Mode.PLACING)
	_update_placement()


# --- Placement ---------------------------------------------------------------

## Moves the preview to where the camera is aiming (within reach), sits it on the
## ground, and checks whether it can be built there.
func _update_placement() -> void:
	var cam: Camera3D = player.camera
	var from := cam.global_position
	var aim := -cam.global_basis.z
	var origin := player.global_position
	var flat := Vector3(aim.x, 0.0, aim.z).normalized()
	var offset := flat * MAX_DISTANCE
	var query := PhysicsRayQueryParameters3D.create(from, from + aim * AIM_RANGE)
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		offset = hit.position - origin
		offset.y = 0.0
		if offset.length() < 0.01:
			offset = flat
		offset = offset.normalized() * clampf(offset.length(), MIN_DISTANCE, MAX_DISTANCE)
	var centre := origin + offset

	# Open side faces the player (the model's front is +Z)
	var yaw := atan2(-offset.x, -offset.z) + rotation_offset
	var basis_ := Basis(Vector3.UP, yaw)

	# Sample the ground under the posts and between them
	var fp: Vector2 = recipe.footprint
	var lo := INF
	var hi := -INF
	var wet := false
	for sx in [-1.0, 0.0, 1.0]:
		for sz in [-1.0, 0.0, 1.0]:
			var p := centre + basis_ * Vector3(sx * fp.x, 0.0, sz * fp.y)
			var h: float = gen.get_height(p.x, p.z)
			lo = minf(lo, h)
			hi = maxf(hi, h)
			var surface: float = gen.water_surface_at(p.x, p.z)
			if h < surface + WATER_MARGIN or gen.inland_water_at(p.x, p.z) > 0.0:
				wet = true
	# Level with the ground on flat land; on a slope, dig into the uphill side a little
	# and let the downhill posts stretch
	var base_y := maxf(lo, hi - UPHILL_SINK)
	placement = Transform3D(basis_, Vector3(centre.x, base_y, centre.z))
	ghost.global_transform = placement
	_fit_posts(ghost, false)

	var problem := ""
	if gen.is_underground(player.global_position):
		problem = "Can't build in here"
	elif wet:
		problem = "Can't build in the water"
	elif hi - lo > MAX_UNEVENNESS:
		problem = "The ground is too uneven here"
	elif _blocked():
		problem = "Something is in the way"
	elif not inventory.can_afford(recipe.cost):
		problem = "Not enough resources"
	placement_ok = problem == ""
	ghost_material.albedo_color = VALID_COLOR if placement_ok else INVALID_COLOR
	ghost_xray.albedo_color = Color(ghost_material.albedo_color, 0.12)
	if toast_time <= 0.0:
		status_label.text = problem


## True if a tree, rock, the player or another build is inside the clearance box
func _blocked() -> bool:
	var box: AABB = recipe.clearance
	var shape := BoxShape3D.new()
	shape.size = box.size
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = placement * Transform3D(Basis(), box.get_center())
	var terrain := gen.get_node_or_null("TerrainBody") as CollisionObject3D
	if terrain:
		query.exclude = [terrain.get_rid()]
	return not player.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _place() -> void:
	if not placement_ok or not inventory.spend(recipe.cost):
		return
	var building: Node3D = recipe.scene.instantiate()
	building.name = String(recipe.id).capitalize()
	structures.add_child(building, true)
	building.global_transform = placement

	building.set_meta(&"recipe", recipe.id)

	var body := StaticBody3D.new()
	body.name = "StructureBody"
	building.add_child(body)
	for entry in _collision_shapes(building) + _fit_posts(building, true):
		var owner_id := body.create_shape_owner(body)
		body.shape_owner_add_shape(owner_id, entry[1])
		body.shape_owner_set_transform(owner_id, entry[0])
	_toast("Built a %s" % recipe.name.to_lower())

	if not inventory.can_afford(recipe.cost):
		_set_mode(Mode.IDLE)


## Convex collision for each part of a structure except the posts (built once per
## recipe and shared). Lashings are too small to matter.
func _collision_shapes(building: Node3D) -> Array:
	if collision_cache.has(recipe.id):
		return collision_cache[recipe.id]
	var shapes := []
	var to_local := building.global_transform.affine_inverse()
	for mi: MeshInstance3D in building.find_children("*", "MeshInstance3D", true, false):
		if mi.name.begins_with("Lash") or mi.name.begins_with("Post"):
			continue
		shapes.append([to_local * mi.global_transform, mi.mesh.create_convex_shape(true, true)])
	collision_cache[recipe.id] = shapes
	return shapes


## Stretches each post down so it reaches the ground under it (the model's posts only
## go 0.3 m below its base). Uses the building's current transform. Returns
## [transform, shape] collision for the posts when `with_collision` is set.
func _fit_posts(building: Node3D, with_collision: bool) -> Array:
	var shapes := []
	var xf := building.global_transform
	for mi: MeshInstance3D in building.find_children("Post*", "MeshInstance3D", true, false):
		if not mi.has_meta(&"rest"):
			mi.set_meta(&"rest", mi.transform)
		var rest: Transform3D = mi.get_meta(&"rest")
		var parent_xf := _relative_transform(mi.get_parent(), building)
		var aabb := (parent_xf * rest) * mi.get_aabb()  # In the building's space
		var top := aabb.end.y
		var bottom := aabb.position.y
		var c := aabb.get_center()
		var ground := xf * Vector3(c.x, 0.0, c.z)
		var ground_y: float = gen.get_height(ground.x, ground.z) - xf.origin.y
		var new_bottom := minf(bottom, ground_y - POST_SINK)
		var stretch := (top - new_bottom) / (top - bottom)
		# Scale along y about the post's top, in the building's space
		var scale_xf := Transform3D(Basis.from_scale(Vector3(1.0, stretch, 1.0)), Vector3(0.0, top * (1.0 - stretch), 0.0))
		mi.transform = parent_xf.affine_inverse() * scale_xf * parent_xf * rest
		if with_collision:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = maxf(aabb.size.x, aabb.size.z) * 0.5
			cylinder.height = top - new_bottom
			shapes.append([Transform3D(Basis(), Vector3(c.x, (top + new_bottom) * 0.5, c.z)), cylinder])
	return shapes


## Transform of `node` relative to its ancestor `ancestor` (works outside the tree)
func _relative_transform(node: Node, ancestor: Node) -> Transform3D:
	var xf := Transform3D()
	while node != ancestor and node != null:
		if node is Node3D:
			xf = (node as Node3D).transform * xf
		node = node.get_parent()
	return xf


# --- Interaction menu ---------------------------------------------------------

## Shows a menu page, rebuilding its rows from the current situation
func _open_menu(page: StringName, index := 0) -> void:
	menu_page = page
	menu_items.clear()
	match page:
		&"root":
			menu_title.text = "Interaction"
			menu_items.append({"label": "Map", "detail": "See the island and where you are.",
					"action": _open_map})
			menu_items.append({"label": "Inventory", "submenu": true,
					"detail": "What you're carrying.", "action": _open_menu.bind(&"inventory")})
			menu_items.append({"label": "Craft", "submenu": true,
					"detail": "Make something from the resources you carry.",
					"action": _open_menu.bind(&"craft")})
			menu_target = _aimed_structure()
			if menu_target:
				var r := _recipe_of(menu_target)
				menu_items.append({"label": "Take down " + r.get("name", "structure").to_lower(),
						"detail": "Nothing to refund in free build." if inventory.free_build
								else "Refunds " + RECIPES.describe_cost(r.get("cost", {})) + ".",
						"action": _remove.bind(menu_target), "target": menu_target})
		&"inventory":
			menu_title.text = "Inventory"
			for id in inventory.items:
				if inventory.count(id) > 0:
					menu_items.append({"label": "%s   %d" % [RECIPES.RESOURCE_NAMES.get(id, String(id)), inventory.count(id)],
							"detail": "", "action": func() -> void: pass})
			if menu_items.is_empty():
				menu_items.append({"label": "Nothing yet", "enabled": false,
						"detail": "Pick things up with E: try the coconuts under the beach palms.", "action": func() -> void: pass})
		&"craft":
			menu_title.text = "Craft"
			for r: Dictionary in RECIPES.RECIPES:
				var detail := RECIPES.describe_cost(r.cost)
				if inventory.free_build:
					detail += "\nFree build: resources aren't needed yet."
				menu_items.append({"label": r.name, "detail": detail,
						"action": _choose.bind(r), "enabled": inventory.can_afford(r.cost)})
	_set_mode(Mode.MENU)
	_select(index)


func _select(index: int) -> void:
	menu_index = clampi(index, 0, menu_items.size() - 1)
	for child in menu_rows.get_children():
		menu_rows.remove_child(child)
		child.queue_free()
	for i in menu_items.size():
		var item: Dictionary = menu_items[i]
		menu_rows.add_child(_menu_row(item, i == menu_index))
	var selected: Dictionary = menu_items[menu_index]
	menu_detail.text = selected.get("detail", "")
	_highlight(selected.get("target"))


func _activate() -> void:
	var item: Dictionary = menu_items[menu_index]
	if item.get("enabled", true):
		item.action.call()


func _open_map() -> void:
	_set_mode(Mode.IDLE)
	map_view.open()


## Tints a structure so it's clear which one a menu row applies to (null clears it)
func _highlight(target: Node3D) -> void:
	if target == highlighted:
		return
	for building in [highlighted, target]:
		if building == null or not is_instance_valid(building):
			continue
		for mi: MeshInstance3D in building.find_children("*", "MeshInstance3D", true, false):
			mi.material_overlay = highlight_overlay if building == target else null
	highlighted = target


## The placed structure within reach that the camera faces most directly (within
## REMOVE_ANGLE), or the one the player is standing in
func _aimed_structure() -> Node3D:
	var cam: Camera3D = player.camera
	var forward := -cam.global_basis.z
	forward = Vector3(forward.x, 0.0, forward.z).normalized()
	var best: Node3D = null
	var best_angle := REMOVE_ANGLE
	for building: Node3D in structures.get_children():
		if building.is_queued_for_deletion():
			continue
		var to := building.global_position - player.global_position
		to.y = 0.0
		var distance := to.length()
		if distance > REMOVE_REACH:
			continue
		var angle: float = 0.0 if distance < 2.0 else forward.angle_to(to / distance)
		if angle < best_angle:
			best_angle = angle
			best = building
	return best


func _recipe_of(building: Node3D) -> Dictionary:
	for r: Dictionary in RECIPES.RECIPES:
		if r.id == building.get_meta(&"recipe", &""):
			return r
	return {}


func _remove(building: Node3D) -> void:
	var r := _recipe_of(building)
	inventory.refund(r.get("cost", {}))
	_set_mode(Mode.IDLE)
	building.queue_free()
	_toast("Took down the %s" % r.get("name", "structure").to_lower())


# --- HUD ---------------------------------------------------------------------

func _build_hud() -> void:
	hud = CanvasLayer.new()
	hud.name = "BuildHUD"
	add_child(hud)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.06, 0.72)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)

	menu_panel = PanelContainer.new()
	menu_panel.add_theme_stylebox_override("panel", style)
	menu_panel.position = Vector2(24, 24)
	menu_panel.custom_minimum_size = Vector2(320, 0)
	menu_panel.visible = false
	hud.add_child(menu_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	menu_panel.add_child(column)
	menu_title = _hud_label(Color(1, 1, 1))
	menu_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu_title.add_theme_font_size_override("font_size", 20)
	column.add_child(menu_title)
	menu_rows = VBoxContainer.new()
	menu_rows.add_theme_constant_override("separation", 2)
	column.add_child(menu_rows)
	menu_detail = _hud_label(Color(1, 1, 1, 0.65))
	menu_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(menu_detail)
	var help := _hud_label(Color(1, 1, 1, 0.4))
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	help.add_theme_font_size_override("font_size", 12)
	help.text = "Scroll  Select · Click  OK · Right-click  Back · M  Close"
	column.add_child(help)

	var bottom := VBoxContainer.new()
	bottom.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	bottom.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bottom.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bottom.offset_bottom = -20
	bottom.alignment = BoxContainer.ALIGNMENT_END
	hud.add_child(bottom)
	status_label = _hud_label(Color(1.0, 0.85, 0.6))
	bottom.add_child(status_label)
	hint_label = _hud_label(Color(1, 1, 1, 0.75))
	bottom.add_child(hint_label)
	_set_mode(Mode.IDLE)


func _hud_label(color: Color) -> Label:
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	return label


## One menu row: inverted colours when selected, greyed out when unavailable
func _menu_row(item: Dictionary, selected: bool) -> PanelContainer:
	var row := PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.92) if selected else Color(1, 1, 1, 0.06)
	bg.set_corner_radius_all(3)
	bg.content_margin_left = 10
	bg.content_margin_right = 10
	bg.content_margin_top = 4
	bg.content_margin_bottom = 4
	row.add_theme_stylebox_override("panel", bg)
	var line := HBoxContainer.new()
	row.add_child(line)
	var color := Color(0.08, 0.1, 0.09) if selected else Color(1, 1, 1)
	if not item.get("enabled", true):
		color.a = 0.4
	var label := Label.new()
	label.text = item.label
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", color)
	line.add_child(label)
	if item.get("submenu", false):
		var arrow := Label.new()
		arrow.text = "›"
		arrow.add_theme_color_override("font_color", color)
		line.add_child(arrow)
	return row


func _toast(message: String) -> void:
	status_label.text = message
	toast_time = 2.5
