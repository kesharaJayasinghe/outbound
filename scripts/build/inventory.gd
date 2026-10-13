extends RefCounted

## What the player is carrying: resource id -> count. Crafting asks `can_afford` and
## `spend`. Gathering isn't in the game yet, so `free_build` makes every recipe
## affordable and free; turn it off once resources can be collected.

signal changed

var free_build := true
var items: Dictionary = {}


func count(id: StringName) -> int:
	return items.get(id, 0)


func add(id: StringName, amount: int) -> void:
	items[id] = count(id) + amount
	changed.emit()


func can_afford(cost: Dictionary) -> bool:
	if free_build:
		return true
	for id in cost:
		if count(id) < cost[id]:
			return false
	return true


## Removes the cost from the inventory. Returns false (and takes nothing) if it can't.
func spend(cost: Dictionary) -> bool:
	if not can_afford(cost):
		return false
	if not free_build:
		for id in cost:
			items[id] = count(id) - cost[id]
		changed.emit()
	return true
