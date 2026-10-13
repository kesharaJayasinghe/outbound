extends Node

## Crafting and placing structures. B opens the crafting menu; picking a recipe the
## player can afford shows a see-through preview in front of them, green where it fits
## and red where it doesn't (too uneven, in water, or blocked by a tree, rock or another
## build). Click to build it, which spends the cost from the player's inventory.
## On a slope the posts (meshes named Post*) stretch down to meet the ground.
## Placed structures go under the generator's "Structures" node, with collision
## generated from their meshes.

const RECIPES = preload("res://scripts/build/recipes.gd")

const MIN_DISTANCE = 3.5     # Closest the preview's centre gets to the player (metres)
const MAX_DISTANCE = 9.0     # Furthest away the player can build
const AIM_RANGE = 30.0
const MAX_UNEVENNESS = 1.4   # Height difference across the footprint (the posts stretch)
const UPHILL_SINK = 0.25     # How far the structure may sink into the uphill side
const POST_SINK = 0.15       # How far a stretched post goes into the ground
const WATER_MARGIN = 0.1     # Ground must be this far above any water surface
const ROTATE_STEP = deg_to_rad(15.0)
const VALID_COLOR = Color(0.35, 1.0, 0.45, 0.4)
const INVALID_COLOR = Color(1.0, 0.3, 0.25, 0.4)

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
var placement := Transform3D()
var placement_ok := false
var structures: Node3D
var collision_cache := {}   # recipe id -> [[Transform3D, Shape3D], ...]

var hud: CanvasLayer
var menu_panel: PanelContainer
var menu_label: RichTextLabel
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

	_ensure_action(&"build_menu", KEY_B)
	_ensure_action(&"rotate_build", KEY_R)

	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghost_xray.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_xray.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_xray.cull_mode = BaseMaterial3D.CULL_DISABLED
	ghost_xray.no_depth_test = true
	ghost_material.next_pass = ghost_xray
	_build_hud()


## Default key for an input action, unless the project already defines it
func _ensure_action(action: StringName, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"build_menu"):
		_set_mode(Mode.MENU if mode == Mode.IDLE else Mode.IDLE)
		get_viewport().set_input_as_handled()
		return
	if mode == Mode.IDLE:
		return

	if event.is_action_pressed(&"ui_cancel"):
		_set_mode(Mode.IDLE)  # Close instead of freeing the mouse
		get_viewport().set_input_as_handled()
		return

	if mode == Mode.MENU:
		if event is InputEventKey and event.pressed and not event.echo:
			var n: int = event.physical_keycode - KEY_1
			if n >= 0 and n < RECIPES.RECIPES.size():
				_choose(RECIPES.RECIPES[n])
				get_viewport().set_input_as_handled()
		return

	# Placing
	if event.is_action_pressed(&"rotate_build"):
		rotation_offset += PI * 0.5
	elif event is InputEventMouseButton and event.pressed \
			and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				rotation_offset += ROTATE_STEP
			MOUSE_BUTTON_WHEEL_DOWN:
				rotation_offset -= ROTATE_STEP
			MOUSE_BUTTON_LEFT:
				_place()
			MOUSE_BUTTON_RIGHT:
				_set_mode(Mode.IDLE)
			_:
				return
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if mode == Mode.PLACING:
		_update_placement()
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
	if mode == Mode.MENU:
		_refresh_menu()
	match mode:
		Mode.IDLE:
			hint_label.text = "B  Craft"
		Mode.MENU:
			var n := RECIPES.RECIPES.size()
			hint_label.text = ("1" if n == 1 else "1-%d" % n) + "  Choose · B  Close"
		Mode.PLACING:
			hint_label.text = "Click  Build · Wheel / R  Rotate · Right-click / B  Cancel"
	if mode != Mode.IDLE:
		status_label.text = ""


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
	if wet:
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
	menu_panel.custom_minimum_size = Vector2(340, 0)
	menu_panel.visible = false
	hud.add_child(menu_panel)
	menu_label = RichTextLabel.new()
	menu_label.bbcode_enabled = true
	menu_label.fit_content = true
	menu_label.scroll_active = false
	menu_panel.add_child(menu_label)

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


func _refresh_menu() -> void:
	var text := "[b]Crafting[/b]"
	if inventory.free_build:
		text += "  [color=#9c9]free build: resources aren't needed yet[/color]"
	text += "\n"
	for i in RECIPES.RECIPES.size():
		var r: Dictionary = RECIPES.RECIPES[i]
		var affordable: bool = inventory.can_afford(r.cost)
		text += "\n[color=%s][b]%d[/b]  %s[/color]\n    [color=#bbb]%s[/color]" % [
			"#fff" if affordable else "#888", i + 1, r.name, RECIPES.describe_cost(r.cost)]
	menu_label.text = text


func _toast(message: String) -> void:
	status_label.text = message
	toast_time = 2.5
