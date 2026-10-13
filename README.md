# Outbound

A third-person exploration prototype built with **Godot 4.7**: a procedurally generated tropical
island with eroded mountains, beaches, jungle, wildlife ambience and a swimmable ocean.

![Beach](docs/beach.jpg)

| | |
|---|---|
| ![Jungle](docs/jungle.jpg) | ![Swimming](docs/swimming.jpg) |

## Features

- **Procedural island**: built from layered noise, droplet-based hydraulic erosion, flattened
  beaches and lagoons, and a seabed that drops away into open ocean.
- **Lake and river**: a hillside lake drains through a meandering river, with flowing ripples
  and white water on the rapids, down to a delta on the beach. You can swim in the lake, and
  the river's current carries you along.
- **Vegetation**: coconut palms on the shore, rainforest trees, big-leaf undergrowth, scattered
  rocks and a dense GPU grass field around the player. It all sways in shared wind, and every
  mesh and leaf texture is generated in code.
- **Third-person character**, with controls in the style of GTA V: an over-the-shoulder camera,
  walk, jog and sprint, jumping, and a first-person toggle.
- **Swimming**: wade into the shallows, then swim in deep water. The character treads water when
  still and does front crawl when moving, animated procedurally.
- **Sound**: surf from the nearest shoreline, birdsong in the forest and wind at altitude.
  Footsteps match the ground (grass, sand, stone or water), and there are splashes and swim strokes.
- **Footprints in the sand** that fade away after a few seconds.

## Running

1. Install [Godot 4.7](https://godotengine.org/download) (standard build, Forward+ renderer).
2. Open `project.godot` in Godot and press **F5**. The main scene is `scenes/world_generator.tscn`.

The island loads from the baked files in `world/`, so startup is quick.

## Controls

| Key | Action |
|---|---|
| W A S D / arrow keys | Move (relative to the camera) |
| Mouse | Look / orbit camera |
| Shift | Sprint (or swim faster) |
| Alt / Option | Walk |
| Space | Jump |
| V | Toggle first / third person |
| Esc | Release the mouse (click to recapture) |

Bindings live in **Project Settings → Input Map**.

## The island: bake, then edit

The island is generated procedurally once, then **baked** to editable files in `world/`, which
the game loads at startup:

| File | Contents |
|---|---|
| `island_height.exr` | 32-bit float heightmap, one pixel per terrain vertex. 1.0 = 90 m; values below 0 are deep seabed. |
| `island_masks.exr` | Float RGB: **R** drainage flow (gullies, wet ground), **G** sediment, **B** lake and river coverage |
| `island_water.exr` | Water surface height per vertex, in the heightmap's units: sea level everywhere except over the lake and river |
| `island.tres` | Ties the images together with the cell size, height scale, water level and seed |

**Editing:** open the EXR files in an image editor that handles 32-bit float, such as Krita.
Paint, save, and Godot re-imports the changes. Vegetation, grass, sand, sounds and the player's
spawn point all follow the edited terrain.

**Baking a new island** (this overwrites the files above, including any hand edits):

```sh
godot --headless --path . --script res://tools/bake_island.gd -- --seed=71195 --force
```

Leave out `--seed` to use the generator's `terrain_seed`, or pass `--name=` to bake to a
different file. To preview random islands without baking, clear **Baked Island** on the
`WorldGenerator` node. The generator then builds a new island each run, about 4 s, and prints
its seed so you can bake one you like.

## Tweaking the world

Select the root node of `scenes/world_generator.tscn` to adjust generation in the Inspector.
These settings apply when generating or baking an island:

| Group | Settings |
|---|---|
| Shape | Resolution, cell size, max height, seed (0 = random), island mode |
| Erosion | Droplet count (more droplets carve deeper gullies but generate more slowly), brush radius |
| Water | Water level, beach flatness, beach height |
| Lake and River | Toggle, lake radius and depth, river width and depth |
| Vegetation | Toggles for vegetation and grass; tree, bush and rock density |
| Audio | Toggle for the ambient soundscape |

Colours, wind and other visual parameters are shader uniforms on the materials in `shaders/`.

## Project layout

```
scenes/          world_generator.tscn (main), player.tscn
scripts/world/   island generation, vegetation, procedural meshes, ambient audio
scripts/player/  character controller, procedural swim animation
shaders/         terrain, water, grass, foliage, bark, rock (+ shared wind include)
audio/           ambience loops and footstep / splash sounds (see audio/CREDITS.txt)
characters/      player model (see characters/human/LICENSE.txt)
world/           the baked island (heightmap + masks) the game loads
tools/           development helpers (island baking, screenshot capture), not used by the game
docs/            README images (ignored by Godot)
```

## Credits

All third-party assets are **CC0 / public domain**:

- Character: "Animated Human" by [Quaternius](https://quaternius.com)
  ([OpenGameArt](https://opengameart.org/content/animated-human-low-poly))
- Sounds from OpenGameArt by RandomMind, Spring Spring, Fantozzi, rubberduck and Peludo,
  including the river loops.
  Full details are in [`audio/CREDITS.txt`](audio/CREDITS.txt).

Everything else (terrain, vegetation, textures, wind audio) is generated by the project's own code.

## License

The project's code is released under the [MIT License](LICENSE). The bundled third-party
assets keep their own licenses (all CC0, as listed above).
