extends Node3D

## Things lying about that the player can pick up, and the fruit hanging in the trees
## (all handed over by vegetation.gd):
##   - fallen coconuts: "E  Pick up coconut" (+1 coconut)
##   - loose rocks: "E  Gather rock" (+3..10 stones, by size); the player lifts a stone off
##     it and the rock is gone
##   - fruit bunches (coconuts on the beach palms, mangoes and oranges in some rainforest
##     trees): hit one with a thrown stone (hotbar.gd) and its fruit falls to the ground,
##     to be picked up like the fallen coconuts
##   - berry bushes: "E  Pick berries" (+3..6 berries); the berries are gone from the bush
##     until they grow back
## Walk up to something and a prompt appears; the player then bends down and picks it up
## (player.pick_up), and it goes into the inventory. Taken things come back after
## REGROW_TIME, but only while the player is well away, so they never see it happen.
## Each kind of thing is one MultiMesh; a taken one is hidden by giving it a zero scale.

const BUILDER = preload("res://scripts/build/builder.gd")
const VEGETATION = preload("res://scripts/world/vegetation.gd")

const PICK_RANGE = 1.8         # Metres, horizontally, from the player
const REGROW_TIME = 600.0      # Seconds
const REGROW_CLEARANCE = 40.0  # Come back only when the player is at least this far away
const STONES_PER_METRE = 7.5   # A rock gives this many stones per metre of size (3..10)
const HELD_STONE = 0.13        # Size of the stone the player lifts off a rock (metres)
const KNOCK_RADIUS = 0.9       # A stone this close to a bunch knocks it down
const BERRIES = Vector2i(3, 6) # Berries a bush gives
const BERRY_RANGE = 90.0       # Berries are too small to see further off than this (metres)
const GRAVITY = 9.8

enum State { THERE, TAKEN, FALLING, SPARE }

var gen: Node3D
var player: Node3D
var builder: Node
var vegetation: Node
## One per kind of thing: {mesh, multimesh, next (first unused slot)}
var kinds: Array[Dictionary] = []
## Everything that can be picked up: {kind, slot (instance in the kind's MultiMesh), xform,
## id, name, amount, state, taken_at, collider, regrows, velocity, reach (from the origin to
## its edge: you pick from there)}
var items: Array[Dictionary] = []
## Fruit bunches in the trees: {kind, slot, xform, nuts (world positions), fruit (id),
## down_at (-1 while up)}
var bunches: Array[Dictionary] = []
## Fallen fruit, per fruit id: {kind, spare (free slots in its MultiMesh, for knocked-down ones)}
var fruit_kinds := {}
var prompt: Label
var nearest := -1
var clock := 0.0
var regrow_check := 0.0


func setup(generator: Node3D, player_node: Node3D, vegetation_node: Node, builder_node: Node) -> void:
	gen = generator
	player = player_node
	vegetation = vegetation_node
	builder = builder_node
	builder._ensure_action(&"interact", KEY_E, JOY_BUTTON_X)

	# Fallen fruit (coconuts under the palms), with spare room for the fruit knocked out of
	# the trees
	var hanging := {&"coconut": 0}  # Fruit id -> how many hang in the trees
	for b in vegetation.coconut_bunches:
		hanging[&"coconut"] += (vegetation.coconut_cluster_meshes[b.kind].get_meta(&"nuts") as PackedVector3Array).size()
	for b in vegetation.tree_fruit:
		var mesh: Mesh = vegetation.tree_fruit_meshes[b.kind]
		var fruit: StringName = mesh.get_meta(&"fruit")
		hanging[fruit] = hanging.get(fruit, 0) + (mesh.get_meta(&"nuts") as PackedVector3Array).size()
	var fallen: Array[Transform3D] = vegetation.fallen_coconuts
	for fruit: StringName in hanging:
		var lying := fallen.size() if fruit == &"coconut" else 0
		var mesh: Mesh = vegetation.fallen_coconut_mesh if fruit == &"coconut" else vegetation.fallen_fruit_meshes[fruit]
		var kind := _add_kind(mesh, lying + hanging[fruit])
		var spare: Array[int] = []
		for k in hanging[fruit]:
			spare.append(lying + k)
		fruit_kinds[fruit] = {"kind": kind, "spare": spare}
	for xform in fallen:
		_add_item(fruit_kinds[&"coconut"].kind, xform, &"coconut", "coconut", 1, -1, true)

	# Loose rocks, one MultiMesh per rock shape
	var rock_kinds: Array[int] = []
	for r in vegetation.rock_meshes.size():
		var count := 0
		for rock in vegetation.loose_rocks:
			if rock.kind == r:
				count += 1
		rock_kinds.append(_add_kind(vegetation.rock_meshes[r], count))
	for rock: Dictionary in vegetation.loose_rocks:
		var stones := clampi(roundi(rock.size * STONES_PER_METRE), 3, 10)
		var xform: Transform3D = rock.xform
		_add_item(rock_kinds[rock.kind], xform, &"stone", "rock", stones, rock.collider, true,
				xform.basis.get_scale().x * 0.5)

	# Berries, one MultiMesh per bush shape and scatter chunk: there are a lot of them, and
	# chunks can be culled by distance (a visibility range on one island-wide MultiMesh would
	# hide them all)
	var berry_kinds := {}  # Vector3i(shape, chunk x, chunk z) -> [kind, bushes]
	for bush: Dictionary in vegetation.berry_bushes:
		var p: Vector3 = (bush.xform as Transform3D).origin
		var key := Vector3i(bush.kind, floori(p.x / VEGETATION.CHUNK_SIZE), floori(p.z / VEGETATION.CHUNK_SIZE))
		if not berry_kinds.has(key):
			berry_kinds[key] = []
		berry_kinds[key].append(bush)
	var berry_rng := RandomNumberGenerator.new()
	berry_rng.seed = gen.terrain_seed + 4410
	for key: Vector3i in berry_kinds:
		var group: Array = berry_kinds[key]
		var mesh: Mesh = vegetation.berry_meshes[key.x]
		var kind := _add_kind(mesh, group.size(), BERRY_RANGE)
		for bush: Dictionary in group:
			var xform: Transform3D = bush.xform
			var reach: float = mesh.get_meta(&"radius") * xform.basis.get_scale().x
			_add_item(kind, xform, &"berries", "berries", berry_rng.randi_range(BERRIES.x, BERRIES.y), -1, true, reach)

	# Fruit bunches, one MultiMesh per cluster mesh (each drawn with its tree's transform, so
	# it sways with it)
	_add_bunches(vegetation.coconut_cluster_meshes, vegetation.coconut_bunches)
	_add_bunches(vegetation.tree_fruit_meshes, vegetation.tree_fruit)

	# The prompt, above the hotbar and the builder's status line
	prompt = builder._hud_label(Color(1, 1, 1, 0.9))
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	prompt.grow_vertical = Control.GROW_DIRECTION_BEGIN
	prompt.offset_bottom = -150
	prompt.visible = false
	builder.hud.add_child(prompt)


## `list` holds {kind (index into `meshes`), xform} for each bunch
func _add_bunches(meshes: Array[Mesh], list: Array[Dictionary]) -> void:
	var bunch_kinds: Array[int] = []
	for c in meshes.size():
		var count := 0
		for b in list:
			if b.kind == c:
				count += 1
		bunch_kinds.append(_add_kind(meshes[c], count) if count > 0 else -1)
	for b: Dictionary in list:
		var kind: int = bunch_kinds[b.kind]
		var slot: int = kinds[kind].next
		kinds[kind].next = slot + 1
		var xform: Transform3D = b.xform
		var mesh: Mesh = meshes[b.kind]
		var nuts := PackedVector3Array()
		for p in (mesh.get_meta(&"nuts") as PackedVector3Array):
			nuts.append(xform * p)
		(kinds[kind].multimesh as MultiMesh).set_instance_transform(slot, xform)
		bunches.append({"kind": kind, "slot": slot, "xform": xform, "nuts": nuts,
				"fruit": mesh.get_meta(&"fruit", &"coconut"), "down_at": -1.0})


func _add_kind(mesh: Mesh, capacity: int, vis_end := 0.0) -> int:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = capacity
	for k in capacity:
		mm.set_instance_transform(k, _hidden(Vector3.ZERO))
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = mm
	# Only chunked kinds get a visibility range: Godot measures it to the middle of the whole
	# MultiMesh, so on one spread across the island it would hide them all
	if vis_end > 0.0:
		instance.visibility_range_end = vis_end
		instance.visibility_range_end_margin = 10.0
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(instance)
	kinds.append({"mesh": mesh, "multimesh": mm, "next": 0})
	return kinds.size() - 1


func _add_item(kind: int, xform: Transform3D, id: StringName, name_: String, amount: int, collider: int,
		regrows: bool, reach := 0.0) -> void:
	var slot: int = kinds[kind].next
	kinds[kind].next = slot + 1
	(kinds[kind].multimesh as MultiMesh).set_instance_transform(slot, xform)
	items.append({"kind": kind, "slot": slot, "xform": xform, "id": id, "name": name_, "amount": amount,
			"state": State.THERE, "taken_at": -1.0, "collider": collider, "regrows": regrows,
			"velocity": Vector3.ZERO, "reach": reach})


static func _hidden(at: Vector3) -> Transform3D:
	return Transform3D(Basis.from_scale(Vector3.ZERO), at)


func _show(item: Dictionary, xform: Transform3D) -> void:
	(kinds[item.kind].multimesh as MultiMesh).set_instance_transform(item.slot, xform)


func _process(delta: float) -> void:
	clock += delta
	regrow_check -= delta
	if regrow_check <= 0.0:
		regrow_check = 1.0
		_regrow()
	_fall(delta)

	# The closest thing within reach (rocks and bushes: from their edge), unless the player is busy
	nearest = -1
	var at := player.global_position
	var best := INF
	for k in items.size():
		var item: Dictionary = items[k]
		if item.state != State.THERE:
			continue
		var xform: Transform3D = item.xform
		var p := xform.origin
		var d := Vector2(p.x - at.x, p.z - at.z).length() - float(item.reach)
		if d < PICK_RANGE and d < best and absf(p.y - at.y) < 1.8:
			best = d
			nearest = k
	var offer: bool = nearest >= 0 and builder.mode == BUILDER.Mode.IDLE and not player.is_busy()
	prompt.visible = offer
	if offer:
		var item: Dictionary = items[nearest]
		match item.id:
			&"stone":
				prompt.text = "E  Gather rock  (+%d stones)" % item.amount
			&"berries":
				prompt.text = "E  Pick berries  (+%d)" % item.amount
			_:
				prompt.text = "E  Pick up %s" % item.name


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interact") and nearest >= 0 and builder.mode == BUILDER.Mode.IDLE:
		var item: Dictionary = items[nearest]
		var take: Transform3D = item.xform
		var mesh: Mesh = kinds[item.kind].mesh
		if item.id == &"stone":
			# Lift a hand-sized stone off the near side of the rock
			var xform: Transform3D = item.xform
			var size := xform.basis.get_scale().x
			var to_player := Vector3(player.global_position.x - xform.origin.x, 0.0, player.global_position.z - xform.origin.z).normalized()
			var at := xform.origin + to_player * size * 0.45
			at.y = gen.get_height(at.x, at.z) + 0.03
			take = Transform3D(xform.basis.orthonormalized().scaled(Vector3.ONE * HELD_STONE), at)
		elif item.id == &"berries":
			# A handful from the low branches on the near side of the bush
			var xform: Transform3D = item.xform
			var to_player := Vector3(player.global_position.x - xform.origin.x, 0.0, player.global_position.z - xform.origin.z).normalized()
			var at := xform.origin + to_player * float(item.reach) * 0.8
			at.y = gen.get_height(at.x, at.z) + 0.02
			take = Transform3D(Basis(Vector3.UP, randf() * TAU), at)
			mesh = vegetation.berry_handful_mesh
		if player.pick_up(take, mesh, _lift.bind(nearest), _collect.bind(nearest)):
			nearest = -1
		get_viewport().set_input_as_handled()


## The player's hand has it: take it off the ground (the player draws it in hand now)
func _lift(k: int) -> void:
	var item: Dictionary = items[k]
	item.state = State.TAKEN
	item.taken_at = clock
	_show(item, _hidden((item.xform as Transform3D).origin))
	if item.collider >= 0:
		vegetation.body.shape_owner_set_disabled(item.collider, true)


func _collect(k: int) -> void:
	var item: Dictionary = items[k]
	var inventory = player.inventory
	inventory.add(item.id, item.amount)
	builder._toast("+%d %s  (%d)" % [item.amount, _item_name(item.id, item.amount), inventory.count(item.id)])
	if not item.regrows:
		# Knocked-down fruit: its slot goes back for the next bunch
		item.state = State.SPARE
		(fruit_kinds[item.id].spare as Array[int]).append(item.slot)


static func _item_name(id: StringName, amount: int) -> String:
	match id:
		&"stone":
			return "Stone" if amount == 1 else "Stones"
		&"coconut":
			return "Coconut" if amount == 1 else "Coconuts"
		&"berries":
			return "Berry" if amount == 1 else "Berries"
		&"mango":
			return "Mango" if amount == 1 else "Mangoes"
		&"orange":
			return "Orange" if amount == 1 else "Oranges"
	return String(id).capitalize()


## The middle of the closest standing fruit bunch within `tolerance` metres of a line of
## sight (from `from` along `dir`, up to `reach`), or Vector3.INF. Bunches have no
## collision, so a throw aims at them this way.
func bunch_on_line(from: Vector3, dir: Vector3, reach: float, tolerance: float) -> Vector3:
	var best := Vector3.INF
	var best_along := reach
	for b in bunches:
		if b.down_at >= 0.0:
			continue
		var centre := _bunch_centre(b)
		var along := (centre - from).dot(dir)
		if along < 1.0 or along > best_along:
			continue
		if (from + dir * along).distance_to(centre) < tolerance:
			best_along = along
			best = centre
	return best


func _bunch_centre(b: Dictionary) -> Vector3:
	var centre := Vector3.ZERO
	for p in (b.nuts as PackedVector3Array):
		centre += p
	return centre / (b.nuts as PackedVector3Array).size()


## A thrown stone at `point`: knocks down a fruit bunch it passes close to, dropping its
## fruit. Returns true if it did.
func knock(point: Vector3) -> bool:
	for b in bunches:
		if b.down_at >= 0.0:
			continue
		var nuts: PackedVector3Array = b.nuts
		var centre := _bunch_centre(b)
		if centre.distance_to(point) > KNOCK_RADIUS:
			continue
		b.down_at = clock
		(kinds[b.kind].multimesh as MultiMesh).set_instance_transform(b.slot, _hidden(centre))
		var fruit: StringName = b.fruit
		var fallen: Dictionary = fruit_kinds[fruit]
		var spare: Array[int] = fallen.spare
		for p in nuts:
			if spare.is_empty():
				break
			var slot: int = spare.pop_back()
			var xform := Transform3D(Basis(Vector3.UP, randf() * TAU), p)
			(kinds[fallen.kind].multimesh as MultiMesh).set_instance_transform(slot, xform)
			items.append({"kind": fallen.kind, "slot": slot, "xform": xform, "id": fruit, "name": String(fruit),
					"amount": 1, "state": State.FALLING, "taken_at": -1.0, "collider": -1, "regrows": false,
					"velocity": Vector3(randf_range(-1.2, 1.2), randf_range(0.0, 1.0), randf_range(-1.2, 1.2)), "reach": 0.0})
		return true
	return false


## Knocked-down fruit drops to the ground, bounce a little and come to rest
func _fall(delta: float) -> void:
	for item in items:
		if item.state != State.FALLING:
			continue
		var v: Vector3 = item.velocity
		v.y -= GRAVITY * delta
		var xform: Transform3D = item.xform
		var p := xform.origin + v * delta
		var ground: float = gen.get_height(p.x, p.z)
		if p.y <= ground:
			p.y = ground
			if absf(v.y) < 1.5:
				item.state = State.THERE
				item.xform = Transform3D(Basis(Vector3.UP, randf() * TAU), Vector3(p.x, ground - 0.01, p.z))
				_show(item, item.xform)
				continue
			v = Vector3(v.x * 0.5, -v.y * 0.3, v.z * 0.5)
		item.velocity = v
		item.xform = Transform3D(xform.basis.rotated(Vector3.RIGHT, delta * 6.0), p)
		_show(item, item.xform)


func _regrow() -> void:
	var at := player.global_position
	for item in items:
		if item.state != State.TAKEN or not item.regrows or clock - item.taken_at < REGROW_TIME:
			continue
		if (item.xform as Transform3D).origin.distance_to(at) < REGROW_CLEARANCE:
			continue
		item.state = State.THERE
		_show(item, item.xform)
		if item.collider >= 0:
			vegetation.body.shape_owner_set_disabled(item.collider, false)
	for b in bunches:
		if b.down_at < 0.0 or clock - b.down_at < REGROW_TIME:
			continue
		if (b.xform as Transform3D).origin.distance_to(at) < REGROW_CLEARANCE:
			continue
		b.down_at = -1.0
		(kinds[b.kind].multimesh as MultiMesh).set_instance_transform(b.slot, b.xform)
