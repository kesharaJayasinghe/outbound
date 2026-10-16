extends Node

## The player's hotbar: six slots (keys 1-6) that fill up by themselves as equippable
## things are gathered (stones, for now). Press a slot's key to hold what's in it; press
## it again to put it away (empty-handed). The bar shows for a moment when something
## changes, then fades; while something's held, a small reminder stays in the corner.
##
## Held stones sit in the right hand. Click to throw one where the camera aims, in a
## slight arc: a stone that passes a coconut bunch knocks it down (pickups.gd), and one
## that lands near gulls on a beach sends them off (beach_birds.gd). Thrown stones are
## small rigid bodies that disappear a few seconds after landing.

const BUILDER = preload("res://scripts/build/builder.gd")
const RECIPES = preload("res://scripts/build/recipes.gd")

const SLOTS = 6
const EQUIPPABLE: Array[StringName] = [&"stone"]
const THROWABLE: Array[StringName] = [&"stone"]  # Shows the aiming dot while held
const SHOW_TIME = 2.5          # Seconds the bar stays up after a change
const FADE_TIME = 0.6
const THROW_SPEED = 20.0       # Metres per second
const THROW_RANGE = 70.0       # Furthest aim point
const OPEN_AIM = 30.0          # Aiming at nothing (the sky, open sea): throw for this distance
const AIM_ASSIST = 1.2         # A coconut bunch this close to the line of sight is the target
const THROW_COOLDOWN = 0.55
const STONE_LIFETIME = 6.0     # Seconds a thrown stone lasts
const STONE_SIZE = 0.12        # Metres
const SPOOK_RADIUS = 7.0       # A stone landing this close to beach gulls sends them off
const HELD_OFFSET = Vector3(0.0, 0.08, 0.03)  # From the hand bone to the palm (metres, bone axes)

var gen: Node3D
var player: CharacterBody3D
var builder: Node
var pickups: Node
var beach_birds: Node
var inventory
var stone_mesh: Mesh

var slots: Array[StringName] = []
var selected := -1             # -1: empty-handed
var held: MeshInstance3D       # What's drawn in the hand
var cooldown := 0.0
var thrown: Array[Dictionary] = []   # {body, age, landed}

var bar: HBoxContainer
var bar_alpha := 0.0
var bar_timer := 0.0
var reminder: Label
var dot: Control               # Aiming dot at the centre of the view (where throws go)
var dot_on_target := false     # A coconut bunch is lined up: drawn with a ring


func setup(generator: Node3D, player_node: CharacterBody3D, builder_node: Node, pickups_node: Node,
		beach_birds_node: Node, vegetation: Node) -> void:
	gen = generator
	player = player_node
	builder = builder_node
	pickups = pickups_node
	beach_birds = beach_birds_node
	inventory = player.inventory
	stone_mesh = vegetation.rock_meshes[0] if vegetation else null
	slots.resize(SLOTS)
	slots.fill(&"")
	for k in SLOTS:
		builder._ensure_action(StringName("hotbar_%d" % (k + 1)), KEY_1 + k)
	inventory.changed.connect(_on_inventory_changed)

	# Drawn at the hand each frame, in world units: the hand bone carries the character
	# model's scale (and mirroring), which a child would inherit
	held = MeshInstance3D.new()
	held.name = "HeldItem"
	held.mesh = stone_mesh
	held.top_level = true
	held.visible = false
	player.hand.add_child(held)
	_build_hud()
	_on_inventory_changed()


# --- Slots -------------------------------------------------------------------------

## New equippable things go in the first free slot; used-up ones leave theirs
func _on_inventory_changed() -> void:
	var changed := false
	for k in SLOTS:
		if slots[k] != &"" and inventory.count(slots[k]) <= 0:
			slots[k] = &""
			changed = true
			if selected == k:
				selected = -1
	for id in EQUIPPABLE:
		if inventory.count(id) > 0 and not slots.has(id):
			var free := slots.find(&"")
			if free >= 0:
				slots[free] = id
				changed = true
	_refresh_bar()
	if changed:
		_flash()


func _unhandled_input(event: InputEvent) -> void:
	for k in SLOTS:
		if event.is_action_pressed(StringName("hotbar_%d" % (k + 1))):
			# The same slot again puts it away
			selected = -1 if selected == k else k
			_refresh_bar()
			_flash()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED and builder.mode == BUILDER.Mode.IDLE:
		if _holding() == &"stone" and cooldown <= 0.0 and not player.is_busy():
			_throw()
			get_viewport().set_input_as_handled()


func _holding() -> StringName:
	return slots[selected] if selected >= 0 else &""


# --- Throwing ----------------------------------------------------------------------

func _throw() -> void:
	cooldown = THROW_COOLDOWN
	# Aim where the centre of the view points
	var cam: Camera3D = player.camera
	var from := cam.global_position
	var aim := -cam.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(from, from + aim * THROW_RANGE)
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	var target: Vector3 = hit.position if hit else from + aim * OPEN_AIM
	# Coconut bunches have no collision: aim at one if it's close to the line of sight
	if pickups:
		var reach: float = from.distance_to(target) if hit else THROW_RANGE
		var bunch: Vector3 = pickups.bunch_on_line(from, aim, reach, AIM_ASSIST)
		if bunch != Vector3.INF:
			target = bunch

	# From the right shoulder, turned towards the target
	var to_target := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
	var facing := to_target.normalized() if to_target.length() > 0.1 else Vector3(aim.x, 0.0, aim.z).normalized()
	var right := Vector3(-facing.z, 0.0, facing.x)
	var start := player.global_position + Vector3.UP * 1.55 + right * 0.25 + facing * 0.3
	var offset := target - start
	var time := maxf(offset.length() / THROW_SPEED, 0.05)
	# Aim up just enough to drop onto the target
	var velocity: Vector3 = offset / time + Vector3.UP * 0.5 * player.gravity * time

	var body := RigidBody3D.new()
	body.mass = 0.3
	body.continuous_cd = true
	body.contact_monitor = true
	body.max_contacts_reported = 1
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = STONE_SIZE * 0.45
	shape.shape = sphere
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	mesh.mesh = stone_mesh
	mesh.scale = Vector3.ONE * STONE_SIZE
	body.add_child(mesh)
	body.add_collision_exception_with(player)
	gen.add_child(body)
	body.global_position = start
	body.linear_velocity = velocity
	body.angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))
	var stone := {"body": body, "age": 0.0, "landed": false}
	body.body_entered.connect(_on_stone_hit.bind(stone))
	thrown.append(stone)
	inventory.add(&"stone", -1)


func _on_stone_hit(_other: Node, stone: Dictionary) -> void:
	if stone.landed:
		return
	stone.landed = true
	if beach_birds and beach_birds.has_method("spook"):
		beach_birds.spook((stone.body as Node3D).global_position, SPOOK_RADIUS)


func _physics_process(delta: float) -> void:
	cooldown -= delta
	for k in range(thrown.size() - 1, -1, -1):
		var stone: Dictionary = thrown[k]
		var body: RigidBody3D = stone.body
		stone.age += delta
		if not stone.landed and pickups and pickups.knock(body.global_position):
			body.linear_velocity *= 0.4  # Thud
		if stone.age > STONE_LIFETIME or body.global_position.y < -50.0:
			body.queue_free()
			thrown.remove_at(k)


# --- HUD ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	held.visible = _holding() == &"stone" and not player.is_busy()
	if held.visible:
		var hand: Node3D = player.hand
		var axes := hand.global_basis.orthonormalized()
		held.global_transform = Transform3D(axes.scaled(Vector3.ONE * STONE_SIZE), hand.global_position + axes * HELD_OFFSET)
	bar_timer -= delta
	var target := 1.0 if bar_timer > 0.0 else 0.0
	bar_alpha = move_toward(bar_alpha, target, delta / FADE_TIME)
	bar.modulate.a = bar_alpha
	bar.visible = bar_alpha > 0.0
	var holding := _holding()
	reminder.visible = holding != &"" and bar_alpha < 0.5
	_update_dot(holding)
	if holding != &"":
		reminder.text = "%d  %s  %d" % [selected + 1, RECIPES.RESOURCE_NAMES.get(holding, String(holding)), inventory.count(holding)]


func _flash() -> void:
	bar_timer = SHOW_TIME


func _build_hud() -> void:
	bar = HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.offset_bottom = -78
	bar.visible = false
	builder.hud.add_child(bar)
	for k in SLOTS:
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(64, 46)
		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 12)
		cell.add_child(label)
		bar.add_child(cell)

	reminder = builder._hud_label(Color(1, 1, 1, 0.75))
	reminder.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	reminder.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	reminder.grow_vertical = Control.GROW_DIRECTION_BEGIN
	reminder.offset_right = -20
	reminder.offset_bottom = -20
	reminder.add_theme_font_size_override("font_size", 14)
	reminder.visible = false
	builder.hud.add_child(reminder)

	dot = Control.new()
	dot.name = "AimDot"
	dot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.visible = false
	dot.draw.connect(_draw_dot)
	builder.hud.add_child(dot)


## The dot shows only while holding something throwable and free to throw it
func _update_dot(holding: StringName) -> void:
	var show_dot: bool = THROWABLE.has(holding) and not player.is_busy() and builder.mode == BUILDER.Mode.IDLE \
			and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED and not get_tree().paused
	dot.visible = show_dot
	if not show_dot:
		return
	var on_target := false
	if pickups:
		var cam: Camera3D = player.camera
		on_target = pickups.bunch_on_line(cam.global_position, -cam.global_basis.z, THROW_RANGE, AIM_ASSIST) != Vector3.INF
	if on_target != dot_on_target:
		dot_on_target = on_target
		dot.queue_redraw()


func _draw_dot() -> void:
	var centre := dot.size * 0.5
	dot.draw_circle(centre, 3.5, Color(0, 0, 0, 0.45))   # Dark edge, so it shows on sand and sky
	dot.draw_circle(centre, 2.2, Color(1, 1, 1, 0.9))
	if dot_on_target:
		dot.draw_arc(centre, 9.0, 0.0, TAU, 32, Color(1.0, 0.85, 0.35, 0.9), 1.5, true)


func _refresh_bar() -> void:
	for k in SLOTS:
		var cell: PanelContainer = bar.get_child(k)
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(4)
		style.bg_color = Color(1, 1, 1, 0.9) if k == selected else Color(0.05, 0.07, 0.06, 0.65)
		cell.add_theme_stylebox_override("panel", style)
		var label: Label = cell.get_child(0)
		var id := slots[k]
		var text := str(k + 1)
		if id != &"":
			text += "\n%s %d" % [RECIPES.RESOURCE_NAMES.get(id, String(id)), inventory.count(id)]
		label.text = text
		label.add_theme_color_override("font_color", Color(0.08, 0.1, 0.09) if k == selected else Color(1, 1, 1, 0.85))
