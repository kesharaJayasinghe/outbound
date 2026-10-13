extends Resource

## A baked island: the generator's output saved as editable images, so the island is
## fixed, loads instantly, and can be hand-edited in an image editor (e.g. Krita).
## Created by tools/bake_island.gd. Assign it to the generator's `baked_island`.
##
## heightmap  32-bit float EXR, one value per terrain vertex. Same units as the
##            generator's `heights`: 1.0 = max_height metres; negative = below 0
##            (deep seabed). Water level is at `water_level`.
## masks      RGB float EXR (0..1), one pixel per vertex:
##              R = drainage flow (gullies, wet ground), G = sediment deposits,
##              B = lake / river coverage (1 = under inland water)
##            Stored as float rather than 8-bit so a bake reproduces the generated
##            island exactly (vegetation placement depends on these values).
## water      32-bit float EXR, the water surface height per vertex in the same units
##            as the heightmap: sea level everywhere except over lakes and rivers.
##            Optional; bakes without it have only the sea.

@export var heightmap: Texture2D
@export var masks: Texture2D
@export var water: Texture2D
## Waterfalls to draw: {top (lip position, metres), dir, drop, width} each
@export var waterfalls: Array[Dictionary] = []
@export var cell_size := 2.0
@export var max_height := 90.0
@export var water_level := 0.08
## Seed and random-number state after generation, so vegetation and anything else
## scattered from the generator's RNG comes out exactly as it did when baked.
@export var terrain_seed := 0
@export var rng_state := 0
