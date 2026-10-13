extends SceneTree

## Development helper: runs the main scene, saves screenshots from a few standard views
## and prints generation / performance stats. Not used by the game itself.
##
## Usage (windowed, so shaders actually render):
##   godot --path . --audio-driver Dummy --resolution 1280x720 \
##       --script res://tools/screenshot.gd -- --out=/tmp/shots [--seed=12345] [--views=player,overview,beach,peak]
##
## By default it shows the baked island the game loads. --seed generates that seed
## instead (use it to preview generator changes before re-baking).
##
## Views:
##   player    the player's own third-person camera
##   overview  high above the island
##   beach     standing on the nearest beach, looking along the shore
##   peak      from the highest point, looking back towards the centre

const SETTLE_FRAMES = 60   # Let physics, the camera and shader compilation settle first

var out_dir := "user://screenshots"
var views: PackedStringArray = ["player", "overview", "beach", "peak"]
var world: Node3D
var cam: Camera3D
var frame := 0
var view_index := 0


func _initialize() -> void:
	var seed_arg := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--seed="):
			seed_arg = int(arg.trim_prefix("--seed="))
		elif arg.begins_with("--views="):
			views = arg.trim_prefix("--views=").split(",")
	DirAccess.make_dir_recursive_absolute(out_dir)

	world = load(ProjectSettings.get_setting("application/run/main_scene")).instantiate()
	if seed_arg != 0:
		world.baked_island = null
		world.terrain_seed = seed_arg
	root.add_child(world)
	cam = Camera3D.new()
	cam.far = 4000.0
	root.add_child(cam)


func _process(_delta: float) -> bool:
	frame += 1
	if frame < SETTLE_FRAMES:
		return false
	if view_index >= views.size():
		return true
	# Position on the first frame of each view, capture a few frames later
	var local := (frame - SETTLE_FRAMES) % 20
	if local == 0:
		_set_view(views[view_index])
	elif local == 19:
		var path := "%s/%s.png" % [out_dir, views[view_index]]
		root.get_texture().get_image().save_png(path)
		print("%-9s fps=%d draw_calls=%d primitives=%d -> %s" % [views[view_index], Engine.get_frames_per_second(),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME), path])
		view_index += 1
	return false


func _set_view(view: String) -> void:
	var player: Node3D = world.get_node("Player")
	var water: float = world.water_surface() if world.water_enabled else 0.0
	match view:
		"player":
			player.camera.current = true
			return
		"overview":
			_look(Vector3(0, 420, 420), Vector3.ZERO)
		"beach":
			var spot := _find(func(h: float) -> bool: return h > water + 0.8 and h < water + 1.5)
			var out := Vector3(spot.x, 0, spot.z).normalized()
			_look(spot + Vector3.UP * 1.7, spot + out.cross(Vector3.UP) * 40.0 + Vector3.UP)
		"peak":
			var top := _find(func(h: float) -> bool: return true, true)
			_look(top + Vector3.UP * 3.0, Vector3(0, water, 0))
		_:
			push_warning("Unknown view '%s'" % view)


func _look(from: Vector3, to: Vector3) -> void:
	cam.current = true
	cam.global_position = from
	cam.look_at(to)


## Grid point nearest the centre whose height passes `test` (or the highest point).
func _find(test: Callable, highest := false) -> Vector3:
	var size: int = world.size
	var half := (size - 1) * 0.5
	var best := Vector3.ZERO
	var found := false
	for z in range(0, size, 2):
		for x in range(0, size, 2):
			var h: float = world.heights[z * size + x] * world.max_height
			var p := Vector3((x - half) * world.cell_size, h, (z - half) * world.cell_size)
			var better := p.y > best.y if highest else p.length() < best.length()
			if test.call(h) and (not found or better):
				best = p
				found = true
	return best
