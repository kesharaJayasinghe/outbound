---
name: godot-verify
description: Launch, screenshot and verify the Outbound Godot project without the editor. Use after any change to terrain, vegetation, shaders, the player, audio or scenes, or whenever asked to run, test, screenshot or check the game.
---

# Verifying Outbound changes

There is no automated test suite. Verify by running the real game from the command line and
inspecting screenshots and printed state.

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
```

## 1. Import (after adding/moving assets or editing `.import` files)

```sh
$GODOT --headless --path . --import
```

## 2. Visual check: screenshots

Run windowed. Headless mode doesn't compile shaders, so its screenshots come out blank.

```sh
$GODOT --path . --audio-driver Dummy --resolution 1280x720 \
  --script res://tools/screenshot.gd -- --out=<scratch dir> --seed=12345 --views=player,overview,beach,peak
```

- Prints generation times, then `fps`, `draw_calls` and `primitives` per view. The first views
  read low FPS while shaders warm up.
- Read the PNGs to judge the result. For before/after comparisons, render both with the same
  `--seed`, then put them side by side:
  `ffmpeg -i a.png -i b.png -filter_complex "[0]scale=640:360[a];[1]scale=640:360[b];[a][b]hstack" cmp.png`
- For a view that isn't built in, add a case to `_set_view` in `tools/screenshot.gd`, or write
  a temporary script as below.

## 3. Behaviour check: temporary scripts

Write a throwaway `extends SceneTree` script inside the project (e.g. `res://tools/_check.gd`).
It must be under `res://`. Run it with `--script`, then delete it **and its `.uid`**.

```gdscript
extends SceneTree
var frame := 0
var world
func _initialize() -> void:
	world = load("res://scenes/world_generator.tscn").instantiate()
	world.terrain_seed = 12345
	root.add_child(world)
func _physics_process(_d: float) -> bool:
	frame += 1
	var p = world.get_node("Player")
	if frame == 30: Input.action_press("move_forward")   # simulate input
	if frame == 300: print(p.global_position, " on_floor=", p.is_on_floor())
	return frame >= 300                                   # true = quit
```

- The world's `_ready` runs after `_initialize`, so query terrain on a later frame.
- Simulate input with `Input.action_press/release`, or `Input.parse_input_event` for
  `is_action_pressed` events such as `toggle_view`.
- Set the camera direction with `p.camera_rig.rotation.y` (movement is camera-relative).
- Teleport with `p.global_position`. Find targets (beaches, deep water, peaks) by scanning
  `world.heights` rather than hard-coding coordinates, which change with the seed.
- Audio can't be heard. Check it by logging which stream each player starts:
  `stream.resource_path`, `volume_db`, and `playing` with a playback-position reset.

## 4. Things to always do

- Pass `--audio-driver Dummy` on every run.
- Use `--headless` only when no rendering is needed (faster).
- Ignore "resources still in use" / "ObjectDB instances leaked" at exit. Any other `ERROR`,
  `SCRIPT ERROR` or shader error is real.
- If the Godot editor is open (`pgrep -fl "Godot.*--editor"`), don't move or rename project
  files until the user closes it.
- Report what was actually observed (numbers, screenshots), including anything that looked
  wrong.
