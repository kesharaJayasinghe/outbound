extends Node3D

## Things lying about that the player can pick up: for now, the coconuts fallen under the
## beach palms (placed by vegetation.gd). Walk up to one and a prompt appears
## ("E  Pick up coconut"); picking it up adds it to the player's inventory. A picked
## coconut grows back after REGROW_TIME, but only while the player is well away, so they
## never see one appear. All the coconuts are one MultiMesh; a picked one is hidden by
## giving it a zero scale.

const BUILDER = preload("res://scripts/build/builder.gd")

const PICK_RANGE = 1.8         # Metres, horizontally, from the player
const REGROW_TIME = 600.0      # Seconds
const REGROW_CLEARANCE = 40.0  # Grow back only when the player is at least this far away

var gen: Node3D
var player: Node3D
var builder: Node
var items: Array[Dictionary] = []   # {xform, id, name, picked_at (-1 while it's there)}
var multimesh := MultiMesh.new()
var prompt: Label
var nearest := -1
var clock := 0.0
var regrow_check := 0.0


func setup(generator: Node3D, player_node: Node3D, vegetation: Node, builder_node: Node) -> void:
	gen = generator
	player = player_node
	builder = builder_node
	builder._ensure_action(&"interact", KEY_E, JOY_BUTTON_X)
	for xform: Transform3D in vegetation.fallen_coconuts:
		items.append({"xform": xform, "id": &"coconut", "name": "coconut", "picked_at": -1.0})

	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = vegetation.fallen_coconut_mesh
	multimesh.instance_count = items.size()
	for k in items.size():
		multimesh.set_instance_transform(k, items[k].xform)
	var instance := MultiMeshInstance3D.new()
	instance.name = "Coconuts"
	instance.multimesh = multimesh
	# No visibility range: Godot measures it to the middle of the whole MultiMesh, and these
	# are spread along every beach, so it would hide them all. A few dozen tiny meshes cost
	# nothing to draw anyway.
	add_child(instance)

	# The prompt, just above the builder's status line
	prompt = builder._hud_label(Color(1, 1, 1, 0.9))
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	prompt.grow_vertical = Control.GROW_DIRECTION_BEGIN
	prompt.offset_bottom = -80
	prompt.visible = false
	builder.hud.add_child(prompt)


func _process(delta: float) -> void:
	clock += delta
	regrow_check -= delta
	if regrow_check <= 0.0:
		regrow_check = 1.0
		_regrow()

	# The closest coconut within reach, if the player isn't busy in a menu
	nearest = -1
	var at := player.global_position
	var best := PICK_RANGE
	for k in items.size():
		var item: Dictionary = items[k]
		if item.picked_at >= 0.0:
			continue
		var p: Vector3 = (item.xform as Transform3D).origin
		var d := Vector2(p.x - at.x, p.z - at.z).length()
		if d < best and absf(p.y - at.y) < 1.5:
			best = d
			nearest = k
	var offer: bool = nearest >= 0 and builder.mode == BUILDER.Mode.IDLE
	prompt.visible = offer
	if offer:
		prompt.text = "E  Pick up %s" % items[nearest].name


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interact") and nearest >= 0 and builder.mode == BUILDER.Mode.IDLE:
		_pick(nearest)
		get_viewport().set_input_as_handled()


func _pick(k: int) -> void:
	var item: Dictionary = items[k]
	item.picked_at = clock
	multimesh.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3.ZERO), (item.xform as Transform3D).origin))
	var inventory = player.inventory
	inventory.add(item.id, 1)
	builder._toast("+1 %s  (%d)" % [String(item.name).capitalize(), inventory.count(item.id)])
	nearest = -1


func _regrow() -> void:
	var at := player.global_position
	for k in items.size():
		var item: Dictionary = items[k]
		if item.picked_at < 0.0 or clock - item.picked_at < REGROW_TIME:
			continue
		if (item.xform as Transform3D).origin.distance_to(at) < REGROW_CLEARANCE:
			continue
		item.picked_at = -1.0
		multimesh.set_instance_transform(k, item.xform)
