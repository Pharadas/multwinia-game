class_name HexMapState
extends RefCounted

## The 2D map's data layer - plain dictionaries keyed by Vector2i cells,
## with no rendering and no I/O. View nodes read it; the facade writes it.
## Keeping this separate means populate/destroy/placement flows are pure
## data operations that are easy to reason about and test.

var colors := {}      # Vector2i -> Color (from network data / terrain)
var counts := {}      # Vector2i -> int (darwinian count)
var walls := {}       # Vector2i -> bool (solid terrain tile)
var buildings := {}   # Vector2i -> int building id (whole-hex, one per hex)
## Vector2i set: walls marked "to be deleted" (double-tapped by the player;
## dots on the 3D side tear them down).
var delete_marked := {}


func clear_tiles() -> void:
	colors.clear()
	counts.clear()
	walls.clear()


func set_tile(cell: Vector2i, color, count, is_wall) -> void:
	if color != null:
		colors[cell] = color
	if count != null:
		counts[cell] = count
	if is_wall != null:
		walls[cell] = is_wall


func color_at(cell: Vector2i):
	return colors.get(cell)


func count_at(cell: Vector2i):
	return counts.get(cell)


func is_wall_at(cell: Vector2i) -> bool:
	return walls.get(cell, false)


func place_building(cell: Vector2i, building_id: int) -> void:
	buildings[cell] = building_id


func remove_building(cell: Vector2i) -> void:
	buildings.erase(cell)


func building_at(cell: Vector2i) -> int:
	return buildings.get(cell, BuildingTypes.REMOVE)


## Forgets everything known about one cell (a mined-out hex).
func erase_cell(cell: Vector2i) -> void:
	colors.erase(cell)
	counts.erase(cell)
	walls.erase(cell)
	buildings.erase(cell)
	delete_marked.erase(cell)
