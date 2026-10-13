extends SceneTree

## Bakes a procedurally generated island to editable files under world/:
##   <name>_height.exr  32-bit float heightmap (edit in Krita etc.)
##   <name>_masks.exr   flow / deposit / lake+river masks (float RGB)
##   <name>_water.exr   water surface height (sea level, or lake / river level inland)
##   (the .tres also lists the waterfalls and islets)
##   <name>.tres        IslandData resource tying them together (assign to the
##                      generator's `baked_island`)
## Uses the generation settings on scenes/world_generator.tscn. Imports the new files
## when done.
##
##   godot --headless --path . --script res://tools/bake_island.gd -- [--seed=71195] [--name=island] [--force]
##
## Without --force it refuses to overwrite an existing bake, since that would throw
## away any hand edits made to the images.

const OUT_DIR = "res://world"


func _initialize() -> void:
	var seed_arg := -1
	var bake_name := "island"
	var force := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			seed_arg = int(arg.trim_prefix("--seed="))
		elif arg.begins_with("--name="):
			bake_name = arg.trim_prefix("--name=")
		elif arg == "--force":
			force = true

	var base := "%s/%s" % [OUT_DIR, bake_name]
	if FileAccess.file_exists(base + ".tres") and not force:
		printerr("%s.tres already exists. Pass --force to overwrite it (hand edits to its images will be lost)." % base)
		quit(1)
		return

	var gen = load("res://scenes/world_generator.tscn").instantiate()
	if seed_arg >= 0:
		gen.terrain_seed = seed_arg
	var t := Time.get_ticks_msec()
	gen.generate()
	print("Generated in %d ms" % (Time.get_ticks_msec() - t))

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var size: int = gen.size
	var height_img := Image.create_from_data(size, size, false, Image.FORMAT_RF, gen.heights.to_byte_array())
	var err := height_img.save_exr(base + "_height.exr", true)
	if err != OK:
		printerr("Couldn't write the heightmap: %s" % error_string(err))
		quit(1)
		return

	var mask := PackedFloat32Array()
	mask.resize(size * size * 3)
	for i in size * size:
		mask[i * 3] = gen.flow_map[i]
		mask[i * 3 + 1] = gen.deposit_map[i]
		mask[i * 3 + 2] = gen.inland_mask[i]
	Image.create_from_data(size, size, false, Image.FORMAT_RGBF, mask.to_byte_array()).save_exr(base + "_masks.exr")
	Image.create_from_data(size, size, false, Image.FORMAT_RF, gen.water_height.to_byte_array()).save_exr(base + "_water.exr", true)

	# Written as text so it can reference the images before they've been imported
	var tres := """[gd_resource type="Resource" load_steps=5 format=3]

[ext_resource type="Script" path="res://scripts/world/island_data.gd" id="1_data"]
[ext_resource type="Texture2D" path="%s_height.exr" id="2_height"]
[ext_resource type="Texture2D" path="%s_masks.exr" id="3_masks"]
[ext_resource type="Texture2D" path="%s_water.exr" id="4_water"]

[resource]
script = ExtResource("1_data")
heightmap = ExtResource("2_height")
masks = ExtResource("3_masks")
water = ExtResource("4_water")
cell_size = %s
max_height = %s
water_level = %s
terrain_seed = %d
rng_state = %d
waterfalls = %s
islets = %s
""" % [base, base, base, var_to_str(gen.cell_size), var_to_str(gen.max_height), var_to_str(gen.water_level), gen.terrain_seed, gen.rng.state, var_to_str(gen.waterfalls), var_to_str(gen.islets)]
	FileAccess.open(base + ".tres", FileAccess.WRITE).store_string(tres)
	var baked_seed: int = gen.terrain_seed
	gen.free()

	_import()
	_keep_lossless(base + "_height.exr")
	_keep_lossless(base + "_masks.exr")
	_keep_lossless(base + "_water.exr")
	_import()
	print("Baked seed %d (%dx%d) to %s.tres" % [baked_seed, size, size, base])
	quit()


## Runs Godot's importer on the project so the new files become usable resources.
func _import() -> void:
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--import"])


## These images are data, not textures to draw: stop the editor from ever switching
## them to lossy VRAM compression if it notices them in a 3D context.
func _keep_lossless(path: String) -> void:
	var import_path := ProjectSettings.globalize_path(path + ".import")
	var text := FileAccess.get_file_as_string(import_path)
	if text.is_empty():
		printerr("No import file for %s" % path)
		return
	FileAccess.open(import_path, FileAccess.WRITE).store_string(text.replace("detect_3d/compress_to=1", "detect_3d/compress_to=0"))

