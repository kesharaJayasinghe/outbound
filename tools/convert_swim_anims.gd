extends SceneTree

## Converts the swim clips exported from Blender into an AnimationLibrary for human.fbx.
##
## The clips are authored in player-swim.blend (keyed by its `swim_clips.py` text block) on a
## Blender import of human.fbx, and exported as a glb with one NLA track per clip:
## `swim_tread`, `swim_crawl`, and `check_idle` (the FBX's own Idle, used to verify this
## conversion). Godot reads the same bone frames from both files; only the root (Hips) bone's
## tracks differ, being relative to differently oriented and scaled parent nodes, so they're
## mapped across. Only rotations (plus the Hips position) are kept.
##
##   Godot --headless --path . --script res://tools/convert_swim_anims.gd -- --in=<swim_source.glb>

const FBX = "res://characters/human/human.fbx"
const OUT = "res://characters/human/swim_animations.res"
const CLIPS = {"swim_tread": "tread", "swim_crawl": "crawl"}  # glb name -> library name
const ROOT_BONE = "Hips"


func _init() -> void:
	var src := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--in="):
			src = arg.substr(5)
	if src.is_empty():
		push_error("Pass --in=<glb exported from player-swim.blend>")
		quit(1)
		return

	var fbx: Node = (load(FBX) as PackedScene).instantiate()
	var fbx_skel: Skeleton3D = fbx.find_child("Skeleton3D", true, false)
	var fbx_player: AnimationPlayer = fbx.find_child("AnimationPlayer", true, false)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(src, state) != OK:
		push_error("Couldn't read " + src)
		quit(1)
		return
	var glb: Node = doc.generate_scene(state)
	var glb_skel: Skeleton3D = glb.find_child("Skeleton3D", true, false)
	var glb_player: AnimationPlayer = glb.find_child("AnimationPlayer", true, false)
	var skel_path := String(fbx_player.get_node(fbx_player.root_node).get_path_to(fbx_skel))

	# The root bone's tracks are relative to the skeleton's parent nodes, which differ: the glb
	# has Blender's Y-up conversion and scale, the FBX its own unit scale. Map one into the other.
	var to_fbx := _scene_transform(fbx_skel).affine_inverse() * _scene_transform(glb_skel)
	var mapping := {"rot": to_fbx.basis.get_rotation_quaternion(), "xform": to_fbx}

	var check := _convert(glb_player.get_animation("check_idle"), skel_path, mapping)
	if not _verify(check, fbx_player.get_animation("Human Armature|Idle")):
		push_error("Converted Idle doesn't match the FBX Idle; not writing " + OUT)
		quit(1)
		return

	var lib := AnimationLibrary.new()
	for glb_name in CLIPS:
		var anim := _convert(glb_player.get_animation(glb_name), skel_path, mapping)
		# The last key repeats the first; end the loop there instead of one frame later
		anim.length = _last_key_time(anim)
		anim.loop_mode = Animation.LOOP_LINEAR
		lib.add_animation(CLIPS[glb_name], anim)
		print("%s: %.2f s, %d tracks" % [CLIPS[glb_name], anim.length, anim.get_track_count()])
	var err := ResourceSaver.save(lib, OUT)
	print("Saved " + OUT if err == OK else "Save failed: %d" % err)
	fbx.free()
	glb.free()
	quit()


func _last_key_time(anim: Animation) -> float:
	var last := 0.0
	for t in anim.get_track_count():
		last = maxf(last, anim.track_get_key_time(t, anim.track_get_key_count(t) - 1))
	return last


## Transform of `node` relative to the root of its (not yet added) scene.
func _scene_transform(node: Node) -> Transform3D:
	var xform := Transform3D.IDENTITY
	while node:
		if node is Node3D:
			xform = (node as Node3D).transform * xform
		node = node.get_parent()
	return xform


func _convert(src: Animation, skel_path: String, m: Dictionary) -> Animation:
	var out := Animation.new()
	out.length = src.length
	for t in src.get_track_count():
		var type := src.track_get_type(t)
		var bone := String(src.track_get_path(t)).get_slice(":", 1)
		var is_root := bone == ROOT_BONE
		if type != Animation.TYPE_ROTATION_3D and not (type == Animation.TYPE_POSITION_3D and is_root):
			continue
		var nt := out.add_track(type)
		out.track_set_path(nt, NodePath(skel_path + ":" + bone))
		out.track_set_interpolation_type(nt, Animation.INTERPOLATION_LINEAR)
		for k in src.track_get_key_count(t):
			var time := src.track_get_key_time(t, k)
			var v = src.track_get_key_value(t, k)
			if type == Animation.TYPE_ROTATION_3D:
				out.rotation_track_insert_key(nt, time, (m.rot * v).normalized() if is_root else v)
			else:
				out.position_track_insert_key(nt, time, m.xform * v)
	return out


## Compares the converted Idle with the FBX's Idle at the start of the clip.
func _verify(converted: Animation, original: Animation) -> bool:
	var worst_angle := 0.0
	var worst_pos := 0.0
	for t in converted.get_track_count():
		var path := converted.track_get_path(t)
		var type := converted.track_get_type(t)
		var o := original.find_track(path, type)
		if o < 0:
			continue
		if type == Animation.TYPE_ROTATION_3D:
			var a: Quaternion = converted.rotation_track_interpolate(t, 0.0)
			var b: Quaternion = original.rotation_track_interpolate(o, 0.0)
			worst_angle = maxf(worst_angle, a.angle_to(b))
		else:
			var a: Vector3 = converted.position_track_interpolate(t, 0.0)
			var b: Vector3 = original.position_track_interpolate(o, 0.0)
			worst_pos = maxf(worst_pos, a.distance_to(b) / maxf(b.length(), 1e-6))
	print("Idle check: worst rotation error %.4f rad, Hips position error %.2f%%" % [worst_angle, worst_pos * 100.0])
	return worst_angle < 0.01 and worst_pos < 0.02
