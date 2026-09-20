class_name FrontierRing
extends RefCounted

## The mining frontier: the outermost ring of hexes still standing on the
## map. A hex is frontier when any of its six neighbors is gone (destroyed
## by a mine collapse, or outside the original grid), so the first
## mined-out ring opens exactly the next ring inward - the map is mined
## outside-in and a mined-out hole never touches the rim.

var cells: Array[Vector2i] = []


## Rebuilds from a (width, depth) grid. `is_alive` receives a cell and
## returns whether that hex still exists; the facade passes a Callable
## that consults the TileMapLayer so the two never disagree.
func rebuild(width: int, depth: int, is_alive: Callable) -> void:
	cells.clear()
	for x in range(width):
		for y in range(depth):
			var cell := Vector2i(x, y)
			if not is_alive.call(cell):
				continue
			for nb in neighbors_of(cell):
				if not is_alive.call(nb):
					cells.append(cell)
					break
	# Deterministic order so placement logic (and screenshots) are stable.
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x))


func contains(cell: Vector2i) -> bool:
	return cells.has(cell)


## The six neighbors of `cell` in this flat-top odd-q hex layout (odd
## columns pushed down half a cell) - matching the 3D grid's spacing.
static func neighbors_of(cell: Vector2i) -> Array[Vector2i]:
	var c := cell.x
	var r := cell.y
	if c % 2 == 0:
		return [
			Vector2i(c, r - 1), Vector2i(c, r + 1),
			Vector2i(c - 1, r - 1), Vector2i(c + 1, r - 1),
			Vector2i(c - 1, r), Vector2i(c + 1, r),
		]
	return [
		Vector2i(c, r - 1), Vector2i(c, r + 1),
		Vector2i(c - 1, r), Vector2i(c + 1, r),
		Vector2i(c - 1, r + 1), Vector2i(c + 1, r + 1),
	]
