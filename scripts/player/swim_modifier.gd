extends SkeletonModifier3D

## Procedural swimming for the character skeleton, applied on top of whatever the
## AnimationTree produced (the model has no swim animation of its own).
## Blends between treading water (crawl = 0) and front crawl (crawl = 1); the player
## controller drives `crawl`, `phase` and the modifier's `influence`.
##
## Limbs are aimed at target directions in skeleton space rather than rotated by fixed
## amounts, so the result doesn't depend on the base pose:
##   +Y = towards the head, +Z = the front of the body, +X = the character's left.

var crawl := 0.0   # 0 = treading water, 1 = front crawl
var phase := 0.0   # Stroke cycle position (one arm cycle per 1.0)

var _bones := {}


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if _bones.is_empty():
		for b in ["LeftArm", "LeftForeArm", "LeftHand", "RightArm", "RightForeArm", "RightHand",
				"LeftUpLeg", "LeftLeg", "LeftFoot", "RightUpLeg", "RightLeg", "RightFoot", "Neck", "Head"]:
			_bones[b] = sk.find_bone(b)

	var a := phase * TAU
	for side in [1.0, -1.0]:  # Left, right
		var prefix := "Left" if side > 0.0 else "Right"
		var arm_phase := a if side > 0.0 else a + PI

		# Front crawl: the arm sweeps head-ward -> under the chest -> hip -> back over
		# the top, with the elbow bending and the hand leading during the recovery
		var crawl_arm := Vector3(0.22 * side, cos(arm_phase), sin(arm_phase)).normalized()
		var recovery := maxf(0.0, -sin(arm_phase))
		var crawl_fore := (crawl_arm + Vector3(0.0, 0.9, 0.3) * recovery).normalized()
		# Treading water: arms out to the sides, sculling back and forth
		var tread_arm := Vector3((0.8 + 0.2 * sin(a)) * side, -0.5, 0.35 + 0.3 * cos(a)).normalized()
		var tread_fore := Vector3(0.35 * side, -0.25, 0.9).normalized()

		_aim(sk, prefix + "Arm", prefix + "ForeArm", tread_arm.slerp(crawl_arm, crawl))
		_aim(sk, prefix + "ForeArm", prefix + "Hand", tread_fore.slerp(crawl_fore, crawl))

		# Legs: a quick flutter kick for the crawl, a slow cycling kick when treading
		var kick := 0.35 * sin(2.0 * a + (0.0 if side > 0.0 else PI))
		var crawl_thigh := Vector3(0.08 * side, -cos(kick), sin(kick)).normalized()
		var crawl_shin := (crawl_thigh + Vector3(0.0, 0.0, -0.25)).normalized()
		var cycle := a + (0.0 if side > 0.0 else PI)
		var tread_thigh := Vector3(0.15 * side, -0.85, 0.35 + 0.3 * sin(cycle)).normalized()
		var tread_shin := Vector3(0.1 * side, -0.9, -0.4 + 0.3 * cos(cycle)).normalized()
		_aim(sk, prefix + "UpLeg", prefix + "Leg", tread_thigh.slerp(crawl_thigh, crawl))
		_aim(sk, prefix + "Leg", prefix + "Foot", tread_shin.slerp(crawl_shin, crawl))

	# Lift the head to look ahead when lying flat in the water
	var lift := 0.9 * crawl
	_aim(sk, "Neck", "Head", Vector3(0.0, cos(lift), -sin(lift)))


## Rotates `bone` (about its own joint) so the direction towards `child` points along `dir`.
func _aim(sk: Skeleton3D, bone: String, child: String, dir: Vector3) -> void:
	var b: int = _bones[bone]
	var c: int = _bones[child]
	if b < 0 or c < 0:
		return
	var pose := sk.get_bone_global_pose(b)
	var current := (sk.get_bone_global_pose(c).origin - pose.origin).normalized()
	if current.is_zero_approx() or current.is_equal_approx(dir):
		return
	pose.basis = Basis(Quaternion(current, dir)) * pose.basis
	sk.set_bone_global_pose(b, pose)
