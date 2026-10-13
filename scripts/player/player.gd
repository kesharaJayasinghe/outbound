extends CharacterBody3D

## Third-person character controller in the style of GTA V: an over-the-shoulder
## orbit camera, movement relative to the camera, the character turning to face where
## it moves, and walk / jog / sprint animations blended by speed. V toggles first person.
## In deep water the character swims: treading water when still, front crawl when moving.

const WALK_SPEED = 1.6
const JOG_SPEED = 4.5
const SPRINT_SPEED = 7.0
const ACCELERATION = 12.0      # How quickly the character reaches target speed
const AIR_CONTROL = 0.25
const TURN_SPEED = 10.0        # How quickly the character turns to face its movement
const JUMP_VELOCITY = 4.6
const MOUSE_SENSITIVITY = 0.0025

const CAMERA_HEIGHT = 1.55     # Pivot height above the feet (third person)
const EYE_HEIGHT = 1.62        # Camera height in first person
const SHOULDER_OFFSET = 0.45   # Over-the-shoulder offset to the right
const CAMERA_DISTANCE = 3.2
const BASE_FOV = 70.0
const SPRINT_FOV = 76.0
const CHARACTER_LAYER = 2      # Render layer for the body, hidden from the first-person camera

const ANIM_IDLE = "Human Armature|Idle"
const ANIM_WALK = "Human Armature|Walk"
const ANIM_RUN = "Human Armature|Run"
const ANIM_JUMP = "Human Armature|Jump"

# Footsteps: each set lists its left-foot sounds first, then the same number of right-foot sounds
const SOFT_STEPS = [
	preload("res://audio/footsteps/soft_l1.wav"), preload("res://audio/footsteps/soft_l2.wav"),
	preload("res://audio/footsteps/soft_l3.wav"), preload("res://audio/footsteps/soft_r1.wav"),
	preload("res://audio/footsteps/soft_r2.wav"), preload("res://audio/footsteps/soft_r3.wav"),
]
const STONE_STEPS = [
	preload("res://audio/footsteps/stone_l1.wav"), preload("res://audio/footsteps/stone_l2.wav"),
	preload("res://audio/footsteps/stone_l3.wav"), preload("res://audio/footsteps/stone_r1.wav"),
	preload("res://audio/footsteps/stone_r2.wav"), preload("res://audio/footsteps/stone_r3.wav"),
]
const SAND_STEPS = [
	preload("res://audio/footsteps/sand_l1.wav"), preload("res://audio/footsteps/sand_l2.wav"),
	preload("res://audio/footsteps/sand_l3.wav"), preload("res://audio/footsteps/sand_l4.wav"),
	preload("res://audio/footsteps/sand_l5.wav"), preload("res://audio/footsteps/sand_l6.wav"),
	preload("res://audio/footsteps/sand_r1.wav"), preload("res://audio/footsteps/sand_r2.wav"),
	preload("res://audio/footsteps/sand_r3.wav"), preload("res://audio/footsteps/sand_r4.wav"),
	preload("res://audio/footsteps/sand_r5.wav"), preload("res://audio/footsteps/sand_r6.wav"),
]
const WATER_STEPS = [
	preload("res://audio/footsteps/water_1.wav"), preload("res://audio/footsteps/water_2.wav"),
	preload("res://audio/footsteps/water_3.wav"), preload("res://audio/footsteps/water_4.wav"),
	preload("res://audio/footsteps/water_5.wav"), preload("res://audio/footsteps/water_6.wav"),
	preload("res://audio/footsteps/water_7.wav"),
]
const WATER_LANDINGS = [
	preload("res://audio/footsteps/water_land_1.wav"), preload("res://audio/footsteps/water_land_2.wav"),
	preload("res://audio/footsteps/water_land_3.wav"),
]
const SWIM_SPEED = 2.0
const SWIM_SPRINT_SPEED = 3.4
const SWIM_ACCELERATION = 2.5
const SWIM_ENTER_DEPTH = 1.3   # Start swimming when the seabed is this far below the surface (shoulder deep)
const SWIM_EXIT_DEPTH = 1.1    # Stand up again once it's shallower than this
const FLOAT_DEPTH = 1.45       # How far below the surface the feet hang while swimming
const CRAWL_PITCH = -1.35      # Body tilt (radians) when swimming flat out
const SWIM_CAMERA_HEIGHT = 0.65  # Camera pivot above the water while swimming
const SWIM_EYE_HEIGHT = 0.2

const FOOT_SPACING = 0.11      # Sideways distance from the body's centre to each footprint

const MIN_SPLASH_DEPTH = 0.03  # Water this shallow (metres) still sounds like wet sand
const MAX_WADE_DEPTH = 1.4     # Deeper than this the body is submerged and steps are silent
# Distance covered per step, matched to the walk and run animation cycles
const WALK_STRIDE = 0.82
const RUN_STRIDE = 1.42

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var first_person := false
var air_time := 0.0
var step_distance := 0.0
var left_foot := true
var was_on_floor := true
var was_in_water := false
var last_splash: AudioStream
var last_step: Array[AudioStream] = [null, null]  # Per foot, to avoid immediate repeats
var feet: Array[AudioStreamPlayer3D] = []
var swimming := false
var swim_blend := 0.0   # 0 = on foot, 1 = fully in the swimming pose
var crawl := 0.0        # 0 = treading water, 1 = front crawl
var swim_time := 0.0
var swim_modifier: SkeletonModifier3D
var footprints: Node3D

@onready var model: Node3D = $Model
@onready var camera_rig: Node3D = $CameraRig
@onready var pitch: Node3D = $CameraRig/Pitch
@onready var spring_arm: SpringArm3D = $CameraRig/Pitch/SpringArm3D
@onready var camera: Camera3D = $CameraRig/Pitch/SpringArm3D/Camera3D
@onready var anim_tree := _build_animation_tree()


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	spring_arm.add_excluded_object(get_rid())
	camera.current = true
	_setup_character_visuals(model)
	footprints = preload("res://scripts/player/footprints.gd").new()
	footprints.name = "Footprints"
	add_child(footprints)
	footprints.set_excluded_layers(1 << (CHARACTER_LAYER - 1))  # Don't print onto our own feet
	swim_modifier = preload("res://scripts/player/swim_modifier.gd").new()
	swim_modifier.influence = 0.0
	model.find_child("Skeleton3D", true, false).add_child(swim_modifier)
	for i in 2:
		var foot := AudioStreamPlayer3D.new()
		foot.bus = &"SFX"
		foot.unit_size = 4.0
		add_child(foot)
		feet.append(foot)
	_apply_view_mode()
	camera_rig.global_position = global_position + Vector3.UP * CAMERA_HEIGHT


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		camera_rig.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		pitch.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		pitch.rotation.x = clampf(pitch.rotation.x, deg_to_rad(-75), deg_to_rad(55))

	if event.is_action_pressed("toggle_view"):
		first_person = not first_person
		_apply_view_mode()

	# Escape frees the mouse cursor; click to recapture it
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseButton and event.pressed:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
	# Movement is relative to where the camera is looking
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var cam_basis := camera_rig.global_transform.basis
	var forward := Vector3(-cam_basis.z.x, 0.0, -cam_basis.z.z).normalized()
	var right := Vector3(cam_basis.x.x, 0.0, cam_basis.x.z).normalized()
	var direction := (right * input.x - forward * input.y).normalized()

	_update_swim_state()
	if swimming:
		_swim(delta, direction, input)
	else:
		_walk(delta, direction, input)

	# Face the direction of travel (or the camera direction in first person)
	var face_dir := forward if first_person else direction
	if face_dir.length_squared() > 0.001:
		var target_yaw := atan2(-face_dir.x, -face_dir.z)
		model.rotation.y = lerp_angle(model.rotation.y, target_yaw, 1.0 - exp(-TURN_SPEED * delta))
	_update_swim_pose(delta)


func _walk(delta: float, direction: Vector3, input: Vector2) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
		air_time += delta
	else:
		air_time = 0.0

	var jumped := false
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
		jumped = true

	var speed := JOG_SPEED
	if Input.is_action_pressed("sprint"):
		speed = SPRINT_SPEED
	elif Input.is_action_pressed("walk"):
		speed = WALK_SPEED
	# Wading: deeper water drags the legs back
	var world := get_parent()
	if world and world.has_method("water_depth_at"):
		speed *= lerpf(1.0, 0.4, smoothstep(0.3, 1.3, world.water_depth_at(global_position)))
	var target := direction * speed * minf(input.length(), 1.0)

	var accel := ACCELERATION * (1.0 if is_on_floor() else AIR_CONTROL)
	var horizontal := Vector2(velocity.x, velocity.z).lerp(Vector2(target.x, target.z), 1.0 - exp(-accel * delta))
	velocity.x = horizontal.x
	velocity.z = horizontal.y
	var impact_speed := velocity.y
	move_and_slide()
	_update_footsteps(delta, impact_speed)
	_update_animation(Vector2(velocity.x, velocity.z).length(), jumped)


func _process(delta: float) -> void:
	# The rig is top-level so it doesn't inherit the body's rotation; follow smoothly.
	# While swimming the feet hang FLOAT_DEPTH below the surface, so lift the pivot.
	var height := EYE_HEIGHT if first_person else CAMERA_HEIGHT
	var swim_height := FLOAT_DEPTH + (SWIM_EYE_HEIGHT if first_person else SWIM_CAMERA_HEIGHT)
	height = lerpf(height, swim_height, swim_blend)
	var target := global_position + Vector3.UP * height
	camera_rig.global_position = camera_rig.global_position.lerp(target, 1.0 - exp(-20.0 * delta))

	var sprinting := Input.is_action_pressed("sprint") and Vector2(velocity.x, velocity.z).length() > JOG_SPEED
	camera.fov = lerpf(camera.fov, SPRINT_FOV if sprinting else BASE_FOV, 1.0 - exp(-4.0 * delta))


func _apply_view_mode() -> void:
	if first_person:
		spring_arm.spring_length = 0.0
		spring_arm.position.x = 0.0
		camera.cull_mask &= ~(1 << (CHARACTER_LAYER - 1))
	else:
		spring_arm.spring_length = CAMERA_DISTANCE
		spring_arm.position.x = SHOULDER_OFFSET
		camera.cull_mask |= 1 << (CHARACTER_LAYER - 1)


## Puts the body on its own render layer and applies the palette texture
## (the FBX's texture reference doesn't survive import).
func _setup_character_visuals(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			child.layers = 1 << (CHARACTER_LAYER - 1)
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = preload("res://characters/human/ClothedLightSkin.png")
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			mat.roughness = 0.85
			child.material_override = mat
		_setup_character_visuals(child)


# --- Swimming ------------------------------------------------------------------

func _water_surface() -> float:
	var world := get_parent()
	return world.water_surface() if world and world.has_method("water_surface") else -INF


## Swim once the seabed drops away (walking out, or falling in); stand up again
## when it gets shallow enough to wade.
func _update_swim_state() -> void:
	var surface := _water_surface()
	var world := get_parent()
	if surface == -INF or not world.has_method("get_height"):
		swimming = false
		return
	var bed_depth: float = surface - world.get_height(global_position.x, global_position.z)
	if not swimming and bed_depth > SWIM_ENTER_DEPTH and global_position.y < surface - SWIM_EXIT_DEPTH:
		swimming = true
		swim_time = 0.0
		if velocity.y < -2.5:
			_play_splash(1.0, 1.0, true)  # Fell or jumped in
		velocity.y *= 0.3
		anim_tree.set("parameters/state/transition_request", "swim")
	elif swimming and bed_depth < SWIM_EXIT_DEPTH:
		swimming = false
		was_on_floor = false
		anim_tree.set("parameters/state/transition_request", "ground")


func _swim(delta: float, direction: Vector3, input: Vector2) -> void:
	swim_time += delta
	var speed := SWIM_SPRINT_SPEED if Input.is_action_pressed("sprint") else SWIM_SPEED
	var target := direction * speed * minf(input.length(), 1.0)
	var horizontal := Vector2(velocity.x, velocity.z).lerp(Vector2(target.x, target.z), 1.0 - exp(-SWIM_ACCELERATION * delta))
	velocity.x = horizontal.x
	velocity.z = horizontal.y

	# Buoyancy: spring towards floating height (head above water) with a gentle bob,
	# never lower than the seabed in water that's only just deep enough to swim
	var float_y := _water_surface() - FLOAT_DEPTH + sin(swim_time * 1.7) * 0.04
	var world := get_parent()
	float_y = maxf(float_y, world.get_height(global_position.x, global_position.z) + 0.05)
	velocity.y = lerpf(velocity.y, (float_y - global_position.y) * 4.0, 1.0 - exp(-5.0 * delta))
	move_and_slide()

	# Advance the stroke; arms enter the water twice per cycle, each with a small splash
	var swim_speed := horizontal.length()
	var before := floori(swim_modifier.phase * 2.0)
	swim_modifier.phase += delta * lerpf(0.35, 0.45 + 0.3 * swim_speed / SWIM_SPEED, crawl)
	if floori(swim_modifier.phase * 2.0) != before and crawl > 0.4:
		_play_stroke_splash(swim_speed / SWIM_SPRINT_SPEED)


## Tilts the body flat for the crawl (pivoting about the chest, not the feet) and
## drives the procedural swim pose.
func _update_swim_pose(delta: float) -> void:
	swim_blend = move_toward(swim_blend, 1.0 if swimming else 0.0, delta * 2.5)
	var target_crawl := clampf(Vector2(velocity.x, velocity.z).length() / 1.2, 0.0, 1.0) if swimming else 0.0
	crawl = lerpf(crawl, target_crawl, 1.0 - exp(-3.0 * delta))
	swim_modifier.influence = swim_blend
	swim_modifier.crawl = crawl

	var tilt := CRAWL_PITCH * crawl * swim_blend
	model.rotation.x = tilt
	# The model's pivot is at its feet; keep its middle (0.9 m up) on a point that
	# rises to just under the waterline as the body goes flat
	var middle := Vector3(0.0, lerpf(0.9, FLOAT_DEPTH - 0.15, crawl * swim_blend), 0.0)
	model.position = middle - Basis.from_euler(Vector3(tilt, model.rotation.y, 0.0)) * Vector3(0.0, 0.9, 0.0)


func _play_stroke_splash(intensity: float) -> void:
	var foot := feet[0 if left_foot else 1]
	left_foot = not left_foot
	var stream: AudioStream = WATER_STEPS.pick_random()
	while stream == last_splash:
		stream = WATER_STEPS.pick_random()
	last_splash = stream
	foot.stream = stream
	foot.pitch_scale = randf_range(1.05, 1.25)
	foot.volume_db = linear_to_db(lerpf(0.3, 0.6, clampf(intensity, 0.0, 1.0)))
	foot.play()


# --- Footsteps -----------------------------------------------------------------

func _update_footsteps(delta: float, impact_speed: float) -> void:
	var on_floor := is_on_floor()
	if on_floor and not was_on_floor and impact_speed < -3.0:
		_play_step(clampf(-impact_speed / 8.0, 0.6, 1.2), true)  # Landing
		step_distance = 0.0
	was_on_floor = on_floor
	if not on_floor:
		return

	var speed := Vector2(velocity.x, velocity.z).length()
	var stride := lerpf(WALK_STRIDE, RUN_STRIDE, clampf((speed - WALK_SPEED) / (JOG_SPEED - WALK_SPEED), 0.0, 1.0))
	if speed < 0.3:
		step_distance = stride * 0.6  # So the first step comes soon after setting off
		return
	step_distance += speed * delta
	if step_distance >= stride:
		step_distance -= stride
		_play_step(clampf(speed / SPRINT_SPEED, 0.35, 1.0), false)


func _play_step(intensity: float, landing: bool) -> void:
	var world := get_parent()
	var depth := 0.0
	if world and world.has_method("water_depth_at"):
		depth = world.water_depth_at(global_position)
	var entering := depth > MIN_SPLASH_DEPTH and not was_in_water
	was_in_water = depth > MIN_SPLASH_DEPTH
	if depth > MIN_SPLASH_DEPTH:
		_play_splash(intensity, depth, landing or entering)
		return

	var surface := &"grass"
	if world and world.has_method("surface_at"):
		surface = world.surface_at(global_position, _floor_collider())
	var pool: Array = SOFT_STEPS
	if surface == &"stone":
		pool = STONE_STEPS
	elif surface == &"sand":
		pool = SAND_STEPS
	var half := pool.size() / 2
	# Landing hits with both feet; otherwise alternate left and right
	var sides := [0, 1] if landing else [0 if left_foot else 1]
	left_foot = not left_foot
	for side in sides:
		var foot := feet[side]
		var stream: AudioStream = pool[side * half + randi() % half]
		if stream == last_step[side]:
			stream = pool[side * half + (pool.find(stream) - side * half + 1 + randi() % (half - 1)) % half]
		last_step[side] = stream
		foot.stream = stream
		if surface == &"sand":
			_leave_footprint(side == 0)
		# Grass uses the "soft" recording, pitched down and quieter
		foot.pitch_scale = randf_range(0.92, 1.08) * (0.88 if surface == &"grass" else 1.0)
		foot.volume_db = linear_to_db(intensity) + (-5.0 if surface == &"grass" else -1.0 if surface == &"sand" else 0.0) \
				+ (2.0 if landing else 0.0)
		foot.play()


func _leave_footprint(left: bool) -> void:
	var yaw := model.global_rotation.y
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var pos := global_position + right * (-FOOT_SPACING if left else FOOT_SPACING)
	var world := get_parent()
	if world and world.has_method("get_height"):
		pos.y = world.get_height(pos.x, pos.z)
	footprints.add(pos, yaw, left)


## Wading: splashes get louder and deeper-pitched as the water gets deeper. Jumping in,
## or the first step into the water, makes a bigger splash.
func _play_splash(intensity: float, depth: float, big: bool) -> void:
	if depth > MAX_WADE_DEPTH and not big:
		return
	var wade := clampf(depth / 0.8, 0.0, 1.0)
	var foot := feet[0 if left_foot else 1]
	left_foot = not left_foot
	var pool: Array = WATER_LANDINGS if big else WATER_STEPS
	var stream: AudioStream = pool.pick_random()
	while stream == last_splash:  # Never the same splash twice in a row
		stream = pool.pick_random()
	last_splash = stream
	foot.stream = stream
	foot.pitch_scale = randf_range(0.94, 1.06) * lerpf(1.1, 0.85, wade)
	foot.volume_db = linear_to_db(maxf(intensity, 0.5) * lerpf(0.6, 1.25, wade)) + (1.0 if big else 0.0)
	foot.play()


func _floor_collider() -> Object:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		if collision.get_normal().y > 0.7:
			return collision.get_collider()
	return null


# --- Animation ---------------------------------------------------------------

## Builds the animation graph:
##   locomotion (blend space idle -> walk -> run by speed) -> time scale --\
##   jump clip (seekable) ------------------------------------------------> ground/air/swim transition
##   idle clip (base pose for swimming) ---------------------------------/
func _build_animation_tree() -> AnimationTree:
	var player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	for anim_name in [ANIM_IDLE, ANIM_WALK, ANIM_RUN]:
		player.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
	_flatten_jump_hips(player.get_animation(ANIM_JUMP))

	var locomotion := AnimationNodeBlendSpace1D.new()
	locomotion.sync = true
	locomotion.add_blend_point(_clip(ANIM_IDLE), 0.0, -1, &"idle")
	locomotion.add_blend_point(_clip(ANIM_WALK), WALK_SPEED, -1, &"walk")
	locomotion.add_blend_point(_clip(ANIM_RUN), JOG_SPEED, -1, &"run")
	locomotion.max_space = SPRINT_SPEED

	var state := AnimationNodeTransition.new()
	state.add_input("ground")
	state.add_input("air")
	state.add_input("swim")
	state.xfade_time = 0.15

	var graph := AnimationNodeBlendTree.new()
	graph.add_node("locomotion", locomotion)
	graph.add_node("speed_scale", AnimationNodeTimeScale.new())
	graph.add_node("jump", _clip(ANIM_JUMP))
	graph.add_node("jump_seek", AnimationNodeTimeSeek.new())
	graph.add_node("swim", _clip(ANIM_IDLE))  # Base pose; swim_modifier.gd moves the limbs
	graph.add_node("state", state)
	graph.connect_node("speed_scale", 0, "locomotion")
	graph.connect_node("jump_seek", 0, "jump")
	graph.connect_node("state", 0, "speed_scale")
	graph.connect_node("state", 1, "jump_seek")
	graph.connect_node("state", 2, "swim")
	graph.connect_node("output", 0, "state")

	var tree := AnimationTree.new()
	tree.name = "AnimationTree"
	tree.tree_root = graph
	model.add_child(tree)
	tree.anim_player = tree.get_path_to(player)
	tree.active = true
	return tree


func _clip(anim_name: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = anim_name
	return node


## The jump clip lifts the hips by about 0.75 m. Physics already moves the body, so
## keep the tuck and crouch but drop the extra height.
func _flatten_jump_hips(anim: Animation) -> void:
	for t in anim.get_track_count():
		if anim.track_get_type(t) == Animation.TYPE_POSITION_3D and str(anim.track_get_path(t)).ends_with(":Hips"):
			var rest_y: float = anim.track_get_key_value(t, 0).y
			for k in anim.track_get_key_count(t):
				var p: Vector3 = anim.track_get_key_value(t, k)
				p.y = minf(p.y, rest_y)
				anim.track_set_key_value(t, k, p)


func _update_animation(ground_speed: float, jumped: bool) -> void:
	anim_tree.set("parameters/locomotion/blend_position", ground_speed)
	# Sprinting reuses the run cycle, played faster
	anim_tree.set("parameters/speed_scale/scale", maxf(1.0, ground_speed / JOG_SPEED))
	if jumped:
		# Skip the crouch at the start of the clip; the body is already leaving the ground
		anim_tree.set("parameters/jump_seek/seek_request", 0.25)
		anim_tree.set("parameters/state/transition_request", "air")
	elif not is_on_floor() and air_time > 0.2:
		if anim_tree.get("parameters/state/current_state") != "air":
			anim_tree.set("parameters/jump_seek/seek_request", 0.4)  # Walked off a ledge
			anim_tree.set("parameters/state/transition_request", "air")
	elif is_on_floor():
		anim_tree.set("parameters/state/transition_request", "ground")
