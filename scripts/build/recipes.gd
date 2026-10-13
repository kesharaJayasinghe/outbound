extends RefCounted

## Everything the player can craft and place. A recipe's `cost` maps resource ids to
## amounts; the ids are the ones the inventory counts (see inventory.gd).

const RESOURCE_NAMES := {
	&"wood": "Wood",
	&"palm_frond": "Palm fronds",
	&"fibre": "Fibre",
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
]


## Human-readable cost, e.g. "Wood 11 · Palm fronds 20"
static func describe_cost(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	for id in cost:
		parts.append("%s %d" % [RESOURCE_NAMES.get(id, String(id)), cost[id]])
	return " · ".join(parts)
