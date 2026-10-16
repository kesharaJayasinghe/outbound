extends CharacterBody3D

## Third-person character controller in the style of GTA V: an over-the-shoulder
## orbit camera, movement relative to the camera, the character turning to face where
## it moves, and walk / jog / sprint animations blended by speed. V toggles first person.
## In deep water the character swims: treading water when still, front crawl when moving.
## C sits down on the ground (and gets up again, as does moving or jumping). Picking
## something up (pick_up, from pickups.gd) walks to it, bends down and takes it in hand.

const INVENTORY = preload("res://scripts/build/inventory.gd")

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
## Swim clips (treading water, front crawl), authored for this skeleton; see tools/convert_anims.gd
const SWIM_ANIMS = preload("res://characters/human/swim_animations.res")
const ANIM_TREAD = "swim/tread"
const ANIM_CRAWL = "swim/crawl"
## Sitting on the ground: sit down (played backwards to stand up), then a seated loop
const SIT_ANIMS = preload("res://characters/human/sit_animations.res")
const ANIM_SIT_DOWN = "sit/down"
const ANIM_SIT_IDLE = "sit/idle"
## Bending down to take something off the ground with the right hand
const PICK_ANIMS = preload("res://characters/human/pick_animations.res")
const ANIM_PICK = "pick/up"

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

const STAND_UP_SPEED = 1.4     # Getting up plays the sit-down clip backwards, this much faster
const SIT_MAX_DEPTH = 0.2      # Deepest water you can sit down in
const SIT_MIN_FLOOR_Y = 0.85   # Flattest ground to sit on (floor normal's y)
# Seated, the body is behind the feet: move the camera pivot back and down with it
const SIT_CAMERA_BACK = 0.35
const SIT_CAMERA_HEIGHT = 0.95
const SIT_EYE_BACK = 0.5
const SIT_EYE_HEIGHT = 0.85

# Picking up: where the right hand grabs, from the feet (metres to the right, forward; GRAB in
# pick_clips.py), and when in the clip (fraction) it closes on the item and puts it away
const PICK_REACH = Vector2(0.15, 0.5)
const PICK_GRAB = 0.42
const PICK_STOW = 0.85
const PICK_APPROACH_TIME = 3.0  # Give up walking to the spot (blocked?) and pick from where you are

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
var tread_phase := 0.0  # Position in the treading-water cycle (0..1)
var stroke_phase := 0.0 # Position in the front-crawl cycle: left hand enters at 0, right at 0.5
enum Sit { NONE, SITTING_DOWN, SEATED, STANDING_UP }
var sit := Sit.NONE
var sit_time := 0.0     # Position in the sit-down clip (seconds); runs backwards when standing up
var sit_idle_time := 0.0
var sit_blend := 0.0    # 0 = standing, 1 = seated, following the clip (moves the camera)
enum Pick { NONE, APPROACH, PICKING }
var pick := Pick.NONE
var pick_time := 0.0          # Seconds into the approach, then into the clip
var pick_item: Transform3D    # Where the item lies
var pick_mesh: Mesh
var pick_stand := Vector3.ZERO  # Where to stand so the right hand lands on it
var pick_dir := Vector3.ZERO    # Facing while picking (pick_stand is worked out for it)
var pick_face := Vector3.ZERO   # Direction to face: where you're walking, then pick_dir
var pick_on_grab: Callable    # Called as the hand closes on it (the item leaves the ground)
var pick_on_done: Callable    # Called as it's put away
var held: MeshInstance3D      # The item while it's in the hand
var hand: BoneAttachment3D
var footprints: Node3D
var inventory = INVENTORY.new()  ## Resources carried, spent on crafting (builder.gd)

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
	for i in 2:
		var foot := AudioStreamPlayer3D.new()
		foot.bus = &"SFX"
		foot.unit_size = 4.0
		add_child(foot)
		feet.append(foot)
	_apply_view_mode()
	camera_rig.global_position = global_position + Vector3.UP * CAMERA_HEIGHT
	hand = BoneAttachment3D.new()
	hand.bone_name = "RightHand"
	model.find_child("Skeleton3D", true, false).add_child(hand)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		camera_rig.rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		pitch.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		pitch.rotation.x = clampf(pitch.rotation.x, deg_to_rad(-75), deg_to_rad(55))

	if event.is_action_pressed("toggle_view"):
		first_person = not first_person
		_apply_view_mode()

	if event.is_action_pressed("sit"):
		if sit == Sit.NONE:
			_sit_down()
		else:
			_stand_up()

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
	elif sit != Sit.NONE:
		_sitting(delta, input)
	elif pick != Pick.NONE:
		_picking(delta, input)
	else:
		_walk(delta, direction, input)

	# Face the direction of travel (or the camera direction in first person)
	var face_dir := forward if first_person else direction
	if pick != Pick.NONE:
		face_dir = pick_face
	if face_dir.length_squared() > 0.001 and sit == Sit.NONE:
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
	# Wading: deeper water drags the legs back, and a river current pushes you along
	var world := get_parent()
	var target := Vector3.ZERO
	if world and world.has_method("water_depth_at"):
		var depth: float = world.water_depth_at(global_position)
		speed *= lerpf(1.0, 0.4, smoothstep(0.3, 1.3, depth))
		if depth > 0.3 and world.has_method("water_current_at"):
			target = world.water_current_at(global_position.x, global_position.z) * smoothstep(0.3, 1.2, depth) * 0.6
	target += direction * speed * minf(input.length(), 1.0)

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
	if sit_blend > 0.0:
		var yaw := model.rotation.y
		var back := Vector3(sin(yaw), 0.0, cos(yaw))  # The model faces -Z
		target = target.lerp(global_position + back * (SIT_EYE_BACK if first_person else SIT_CAMERA_BACK) \
				+ Vector3.UP * (SIT_EYE_HEIGHT if first_person else SIT_CAMERA_HEIGHT), sit_blend)
	camera_rig.global_position = camera_rig.global_position.lerp(target, 1.0 - exp(-20.0 * delta))

	var sprinting := Input.is_action_pressed("sprint") and Vector2(velocity.x, velocity.z).length() > JOG_SPEED
	camera.fov = lerpf(camera.fov, SPRINT_FOV if sprinting else BASE_FOV, 1.0 - exp(-4.0 * delta))
	if swim_blend > 0.0:
		_update_swim_strokes(delta)
	if sit != Sit.NONE:
		_update_sit_animation(delta)
	if pick == Pick.PICKING:
		_update_pick_animation(delta)


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
	if world and world.has_method("water_surface_at"):
		return world.water_surface_at(global_position.x, global_position.z)
	return -INF


## Swim once the seabed drops away (walking out, or falling in); stand up again
## when it gets shallow enough to wade.
func _update_swim_state() -> void:
	var surface := _water_surface()
	var world := get_parent()
	if surface == -INF or not world.has_method("get_height"):
		swimming = false
		return
	if world.has_method("is_underground") and world.is_underground(global_position):
		surface = -INF  # In a cave: any river is overhead, not around us
	var bed_depth: float = surface - world.get_height(global_position.x, global_position.z)
	if not swimming and bed_depth > SWIM_ENTER_DEPTH and global_position.y < surface - SWIM_EXIT_DEPTH:
		swimming = true
		swim_time = 0.0
		sit = Sit.NONE
		sit_blend = 0.0
		_end_pick()
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
	var world := get_parent()
	if world.has_method("water_current_at"):
		target += world.water_current_at(global_position.x, global_position.z)  # Rivers carry you along
	var horizontal := Vector2(velocity.x, velocity.z).lerp(Vector2(target.x, target.z), 1.0 - exp(-SWIM_ACCELERATION * delta))
	velocity.x = horizontal.x
	velocity.z = horizontal.y

	# Buoyancy: spring towards floating height (head above water) with a gentle bob,
	# never lower than the seabed in water that's only just deep enough to swim
	var float_y := _water_surface() - FLOAT_DEPTH + sin(swim_time * 1.7) * 0.04
	float_y = maxf(float_y, world.get_height(global_position.x, global_position.z) + 0.05)
	velocity.y = lerpf(velocity.y, (float_y - global_position.y) * 4.0, 1.0 - exp(-5.0 * delta))
	move_and_slide()


## Plays the swim clips at the stroke rate, which picks up with speed. Each clip is sought
## to its phase every frame, so the hands meet the water exactly when the splashes play.
func _update_swim_strokes(delta: float) -> void:
	var swim_speed := Vector2(velocity.x, velocity.z).length()
	var tread_length := SWIM_ANIMS.get_animation("tread").length
	var crawl_length := SWIM_ANIMS.get_animation("crawl").length
	tread_phase = fposmod(tread_phase + delta / tread_length, 1.0)
	# The clip's own pace (one cycle per crawl_length) is the stroke rate at SWIM_SPEED
	var before := floori(stroke_phase * 2.0)
	stroke_phase += delta / crawl_length * lerpf(0.65, 1.0, swim_speed / SWIM_SPEED)
	if floori(stroke_phase * 2.0) != before and crawl > 0.4 and swimming:
		_play_stroke_splash(swim_speed / SWIM_SPRINT_SPEED)
	stroke_phase = fposmod(stroke_phase, 1.0)
	anim_tree.set("parameters/tread_seek/seek_request", tread_phase * tread_length)
	anim_tree.set("parameters/crawl_seek/seek_request", stroke_phase * crawl_length)
	anim_tree.set("parameters/swim/blend_amount", crawl)


## Tilts the body flat for the crawl, pivoting about the chest, not the feet.
func _update_swim_pose(delta: float) -> void:
	swim_blend = move_toward(swim_blend, 1.0 if swimming else 0.0, delta * 2.5)
	var target_crawl := clampf(Vector2(velocity.x, velocity.z).length() / 1.2, 0.0, 1.0) if swimming else 0.0
	crawl = lerpf(crawl, target_crawl, 1.0 - exp(-3.0 * delta))

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


# --- Sitting -------------------------------------------------------------------

func _sit_down() -> void:
	var world := get_parent()
	var depth := 0.0
	if world and world.has_method("water_depth_at"):
		depth = world.water_depth_at(global_position)
	if swimming or pick != Pick.NONE or not is_on_floor() or get_floor_normal().y < SIT_MIN_FLOOR_Y \
			or depth > SIT_MAX_DEPTH:
		return
	sit = Sit.SITTING_DOWN
	sit_time = 0.0
	anim_tree.set("parameters/sit/blend_amount", 0.0)
	anim_tree.set("parameters/state/transition_request", "sit")


func _stand_up() -> void:
	if sit == Sit.SITTING_DOWN or sit == Sit.SEATED:
		sit = Sit.STANDING_UP


## Seated: the body stays put. Moving, jumping or losing the ground gets you up again.
func _sitting(delta: float, input: Vector2) -> void:
	if input.length() > 0.3 or Input.is_action_just_pressed("jump"):
		_stand_up()
	velocity.x = 0.0
	velocity.z = 0.0
	velocity.y -= gravity * delta
	move_and_slide()
	if is_on_floor():
		velocity.y = 0.0
	elif velocity.y < -3.0:  # Slid off an edge: drop straight into the fall
		sit = Sit.NONE
		sit_blend = 0.0


## Advances the sit clips: sit down, loop the seated idle, or play the sit-down backwards to get up.
func _update_sit_animation(delta: float) -> void:
	var down_length := SIT_ANIMS.get_animation("down").length
	match sit:
		Sit.SITTING_DOWN:
			sit_time += delta
			if sit_time >= down_length:
				sit_time = down_length
				sit_idle_time = 0.0  # The idle loop starts on the sit-down's last pose
				sit = Sit.SEATED
		Sit.SEATED:
			sit_idle_time = fmod(sit_idle_time + delta, SIT_ANIMS.get_animation("idle").length)
		Sit.STANDING_UP:
			sit_time -= delta * STAND_UP_SPEED
			if sit_time <= 0.0:
				sit_time = 0.0
				sit = Sit.NONE
				anim_tree.set("parameters/state/transition_request", "ground")
	sit_blend = smoothstep(0.0, 1.0, sit_time / down_length)
	# Fade into the idle loop once seated, and out of it (wherever it is) when getting up
	var idle_weight: float = anim_tree.get("parameters/sit/blend_amount")
	idle_weight = move_toward(idle_weight, 1.0 if sit == Sit.SEATED else 0.0, delta * 4.0)
	anim_tree.set("parameters/sit/blend_amount", idle_weight)
	anim_tree.set("parameters/sit_down_seek/seek_request", sit_time)
	anim_tree.set("parameters/sit_idle_seek/seek_request", sit_idle_time)


# --- Picking things up ---------------------------------------------------------

## True while sitting, swimming, in the air or already picking something up.
func is_busy() -> bool:
	return swimming or sit != Sit.NONE or pick != Pick.NONE or not is_on_floor()


## Walks over to the item lying at `item`, bends down and picks it up, drawing `mesh` in the
## right hand from the grab. Calls `on_grab` when it leaves the ground and `on_done` when
## it's put away. Returns false (doing nothing) if the player is busy. Moving cancels the
## walk over, but not the pick itself.
func pick_up(item: Transform3D, mesh: Mesh, on_grab: Callable, on_done: Callable) -> bool:
	if is_busy():
		return false
	pick = Pick.APPROACH
	pick_time = 0.0
	pick_item = item
	pick_mesh = mesh
	pick_on_grab = on_grab
	pick_on_done = on_done
	var to := Vector3(item.origin.x - global_position.x, 0.0, item.origin.z - global_position.z)
	pick_dir = to.normalized() if to.length() > 0.05 else model.global_basis.z * -1.0
	pick_face = pick_dir
	var right := Vector3(-pick_dir.z, 0.0, pick_dir.x)
	pick_stand = item.origin - pick_dir * PICK_REACH.y - right * PICK_REACH.x
	return true


func _picking(delta: float, input: Vector2) -> void:
	var to := Vector3(pick_stand.x - global_position.x, 0.0, pick_stand.z - global_position.z)
	if pick == Pick.APPROACH:
		pick_time += delta
		if input.length() > 0.3:
			pick = Pick.NONE  # Walked off instead
			return
		if to.length() > 0.08 and pick_time < PICK_APPROACH_TIME:
			# Walk over, slowing for the last step; face where you're going until there
			if to.length() > 0.4:
				pick_face = to.normalized()
			_walk(delta, to.normalized(), Vector2(0.0, clampf(to.length() * 0.8, 0.12, 0.36)))
			return
		pick = Pick.PICKING
		pick_time = 0.0
		pick_face = pick_dir
		anim_tree.set("parameters/state/transition_request", "pick")
	# Picking: stay put, easing onto the exact spot
	var nudge := to * 6.0
	velocity.x = nudge.x if nudge.length() < 1.0 else nudge.normalized().x
	velocity.z = nudge.z if nudge.length() < 1.0 else nudge.normalized().z
	velocity.y = 0.0 if is_on_floor() else velocity.y - gravity * delta
	move_and_slide()


func _update_pick_animation(delta: float) -> void:
	var length := PICK_ANIMS.get_animation("up").length
	var before := pick_time / length
	pick_time += delta
	var now := pick_time / length
	if before < PICK_GRAB and now >= PICK_GRAB:
		# The item leaves the ground in the hand, exactly where it lay
		held = MeshInstance3D.new()
		held.mesh = pick_mesh
		add_child(held)
		held.global_transform = pick_item
		held.reparent(hand, true)
		pick_on_grab.call()
	if before < PICK_STOW and now >= PICK_STOW:
		_stow()
	anim_tree.set("parameters/pick_seek/seek_request", minf(pick_time, length))
	if now >= 1.0:
		pick = Pick.NONE
		anim_tree.set("parameters/state/transition_request", "ground")


func _stow() -> void:
	if held:
		held.queue_free()
		held = null
		pick_on_done.call()


## Cuts a pick short (fell into deep water): anything already in hand still counts.
func _end_pick() -> void:
	_stow()
	pick = Pick.NONE


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
##   tread / crawl clips (each sought to its phase), blended by speed --/
##   sit-down clip (sought, also backwards) / seated idle loop, blended -/
##   pick-up clip (sought) ----------------------------------------------/
func _build_animation_tree() -> AnimationTree:
	var player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	player.add_animation_library("swim", SWIM_ANIMS)
	player.add_animation_library("sit", SIT_ANIMS)
	player.add_animation_library("pick", PICK_ANIMS)
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
	state.add_input("sit")
	state.add_input("pick")
	state.xfade_time = 0.15

	var graph := AnimationNodeBlendTree.new()
	graph.add_node("locomotion", locomotion)
	graph.add_node("speed_scale", AnimationNodeTimeScale.new())
	graph.add_node("jump", _clip(ANIM_JUMP))
	graph.add_node("jump_seek", AnimationNodeTimeSeek.new())
	graph.add_node("tread", _clip(ANIM_TREAD))
	graph.add_node("tread_seek", AnimationNodeTimeSeek.new())
	graph.add_node("crawl", _clip(ANIM_CRAWL))
	graph.add_node("crawl_seek", AnimationNodeTimeSeek.new())
	graph.add_node("swim", AnimationNodeBlend2.new())
	graph.add_node("sit_down", _clip(ANIM_SIT_DOWN))
	graph.add_node("sit_down_seek", AnimationNodeTimeSeek.new())
	graph.add_node("sit_idle", _clip(ANIM_SIT_IDLE))
	graph.add_node("sit_idle_seek", AnimationNodeTimeSeek.new())
	graph.add_node("sit", AnimationNodeBlend2.new())
	graph.add_node("pick", _clip(ANIM_PICK))
	graph.add_node("pick_seek", AnimationNodeTimeSeek.new())
	graph.add_node("state", state)
	graph.connect_node("speed_scale", 0, "locomotion")
	graph.connect_node("jump_seek", 0, "jump")
	graph.connect_node("tread_seek", 0, "tread")
	graph.connect_node("crawl_seek", 0, "crawl")
	graph.connect_node("swim", 0, "tread_seek")
	graph.connect_node("swim", 1, "crawl_seek")
	graph.connect_node("sit_down_seek", 0, "sit_down")
	graph.connect_node("sit_idle_seek", 0, "sit_idle")
	graph.connect_node("sit", 0, "sit_down_seek")
	graph.connect_node("sit", 1, "sit_idle_seek")
	graph.connect_node("state", 0, "speed_scale")
	graph.connect_node("state", 1, "jump_seek")
	graph.connect_node("state", 2, "swim")
	graph.connect_node("state", 3, "sit")
	graph.connect_node("pick_seek", 0, "pick")
	graph.connect_node("state", 4, "pick_seek")
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
