class_name BuildingMarkerLayer
extends Node2D

## Draws a small hexagonal marker on every hex that carries a building,
## colored like the building. Child of the TileMapLayer so markers inherit
## the grid's transform/scale automatically. Call mark_changed() whenever
## the underlying buildings data changes - the layer redraws itself.

var buildings := {}  # Vector2i -> building id (shared reference to state)


func mark_changed() -> void:
	queue_redraw()


func _draw() -> void:
	var layer := get_parent() as TileMapLayer
	if layer == null or layer.tile_set == null:
		return
	var tile_sz := Vector2(layer.tile_set.tile_size)
	var hex_r: float = tile_sz.x / 2.0
	for cell in buildings:
		var color: Color = BuildingTypes.color_of(buildings[cell])
		draw_colored_polygon(_hex_polygon(layer.map_to_local(cell), hex_r * 0.55), color)


static func _hex_polygon(center: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(6):
		var a := deg_to_rad(60.0 * float(i))
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts
