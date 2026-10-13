# CLAUDE.md

Godot 4.7 (GDScript, Forward+, Jolt physics) third-person exploration prototype on a procedurally
generated tropical island. See README.md for features and controls.

## Running and verifying

Godot binary: `/Applications/Godot.app/Contents/MacOS/Godot`. There is no test suite, so verify
changes by running the game. The `godot-verify` skill (`.claude/skills/godot-verify/`) has the
full workflow. In short:

```sh
# Re-import after adding or moving assets, or after editing *.import files
Godot --headless --path . --import

# Screenshots of standard views + fps/draw-call stats (windowed: headless can't render)
Godot --path . --audio-driver Dummy --resolution 1280x720 \
  --script res://tools/screenshot.gd -- --out=<dir> --seed=12345
```

- Always pass `--audio-driver Dummy` so test runs don't play sound on the user's speakers.
- `--headless` uses a dummy renderer: shaders aren't compiled and screenshots are blank. Use
  it for logic checks, and a windowed run for anything visual.
- Use a fixed `--seed` when comparing before/after.
- Close the Godot editor before moving or renaming files outside it.
- Temporary test scripts must live inside the project (`res://`). Delete them and their `.uid`
  afterwards.
- "N resources still in use at exit" and "ObjectDB instances leaked" at the end of
  `--script` runs are harness noise, not game bugs.

## Architecture

Everything is built at runtime from `scripts/world/world_generator.gd` (`_ready`):

1. `_generate_heightmap`: warped fBm + ridged noise + island falloff → `heights` (0..1, row-major
   `z * size + x`). It also records `island_edge`.
2. `_erode`: droplet hydraulic erosion, which also fills `flow_map` and `deposit_map`
   (passed to the terrain shader as vertex colours).
3. `_shape_beaches`: a monotonic height remap that flattens the band around sea level.
   `_sink_seabed` then drops the seabed away from the coast.
4. `_build_terrain`: mesh with analytic normals (`normal_map`) + `HeightMapShape3D`
   collision (uniformly scaled by `cell_size`).
5. `_build_water`, `_place_player`, then `vegetation.gd` (`build(gen)`) and
   `ambient_audio.gd` (`setup(gen, vegetation)`).

The generator is the source of truth for terrain queries. Use these rather than re-deriving:
`get_height(x, z)` (same triangle split as the mesh), `grid_index`, `surface_at`,
`water_surface`, `water_depth_at`.

- `vegetation.gd`: jittered-grid scattering into chunked MultiMeshes, plus one shared
  `StaticBody3D` with shape owners for collision. Grass is a camera-following GPU field:
  `grass.gdshader` reads the heightmap texture and a density mask.
- `proc_mesh.gd`: procedural palms, broadleaf trees, bushes, rocks, grass clumps and leaf
  textures. Vertex conventions: `UV2.x` = wind sway weight, `UV2.y` = leaf flutter,
  `COLOR.r` = per-leaf variation.
- `shaders/wind.gdshaderinc`: the shared wind model, used by grass, foliage and bark so they
  move together.
- `scripts/player/player.gd`: CharacterBody3D controller, an AnimationTree built in code
  (ground/air/swim transition), footsteps and splashes, swimming. `swim_modifier.gd` is a
  `SkeletonModifier3D` that aims limbs for treading water / front crawl; the model has no swim
  clip.

## Conventions and gotchas

- **No `class_name`**: cross-script references use `const X = preload("res://…")`, so scripts
  work in `--script` runs without the editor's class cache. Accessing members through an
  untyped reference (e.g. `gen` in vegetation.gd) gives Variants, so declare those locals with
  explicit types (`var h: float = gen.get_height(...)`). `:=` fails to infer.
- **Name collisions with built-ins**: don't name methods after Node methods (`get_index` broke
  the build) or locals after Node3D properties (`basis`, `position`) or global functions
  (`seed`, `len`). When renaming a shadowing local, update every use; a leftover silently
  reads the node's property instead.
- **Keep terrain sampling consistent**: CPU `_sample`, the grass shader's `terrain_height` and
  the mesh all split each cell along the same diagonal. Change all three together.
- **Import settings are part of the source**. Edit the `.import` file, then re-import:
  - Ambience WAVs need `edit/loop_mode=2`.
  - Palette PNGs need `detect_3d/compress_to=0`, or VRAM compression smears the colours.
- **Commit the `.import` and `.uid` files**; never commit `.godot/`.
- Style: tabs, typed GDScript, `##` doc comments on scripts and non-obvious functions. Tunables
  go in `@export` groups on the generator or in named constants.
- Third-party assets must be CC0 and recorded in `audio/CREDITS.txt` or next to the asset. The
  `cc0-assets` skill has the sourcing and processing pipeline.
- The user's shell is zsh: unquoted `$var` does not word-split, and `$1:c` is a history
  modifier (write `${1}`).
