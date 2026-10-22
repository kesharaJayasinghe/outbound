extends RefCounted

## Everything the player can craft and place. A recipe's `cost` maps resource ids to
## amounts; the ids are the ones the inventory counts (see inventory.gd).

const RESOURCE_NAMES := {
	&"wood": "Wood",
	&"palm_frond": "Palm fronds",
	&"fibre": "Fibre",
	&"coconut": "Coconuts",
	&"stone": "Stones",
	&"berries": "Berries",
	&"mango": "Mangoes",
	&"orange": "Oranges",
}

const RECIPES := [
	{
		"id": &"shelter",
		"name": "Lean-to shelter",
		"scene": preload("res://models/shelter_minimum.glb"),
		"cost": {&"wood": 11, &"palm_frond": 20, &"fibre": 8},
		## Where the posts stand (local x, z): the ground is sampled here and between them
		"footprint": Vector2(1.3, 1.0),
		## Clearance box (local space) that must be free of trees, rocks and other builds
		"clearance": AABB(Vector3(-1.95, 0.4, -1.45), Vector3(3.9, 2.0, 3.0)),
	},
	{
		"id": &"radio",
		"name": "Radio",
		"scene": preload("res://models/radio.tscn"),
		## Nothing to craft: it's the player's own radio, so there's only one to place
		"cost": {},
		"limit": 1,
		"about": "Your battered transistor radio. Set it down somewhere and switch it on.",
		"footprint": Vector2(0.15, 0.05),
		"clearance": AABB(Vector3(-0.17, 0.05, -0.06), Vector3(0.34, 0.2, 0.12)),
		## Optional overrides of the builder's placement limits
		"reach": Vector2(1.2, 5.0),
		## Sits tilted to the ground (no posts), up to this slope
		"max_slope": deg_to_rad(30.0),
		## Grass is trimmed this far around it (metres), or it would hide in it
		"grass_clearing": 0.7,
	},
]


## Human-readable cost, e.g. "Wood 11 · Palm fronds 20"
static func describe_cost(cost: Dictionary) -> String:
	if cost.is_empty():
		return "Free"
	var parts: PackedStringArray = []
	for id in cost:
		parts.append("%s %d" % [RESOURCE_NAMES.get(id, String(id)), cost[id]])
	return " · ".join(parts)
