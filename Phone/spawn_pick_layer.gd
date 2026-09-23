class_name SpawnPickLayer
extends Node2D

## Marks the hexes a player picked for their starting army while the lobby is
## open. Child of the TileMapLayer, so the marks inherit the grid's
## transform/scale like every other grid-space overlay - see
## BuildingMarkerLayer for the same pattern. Call mark_changed() whenever the
## picks or the team color change; the layer redraws itself.

var picks: Array = []            # Array[Vector2i] in pick order
var color := Color(0.9, 0.9, 0.95)


func mark_changed() -> void:
	queue_redraw()


func _draw() -> void:
	var layer := get_parent() as TileMapLayer
	if layer == null or layer.tile_set == null or picks.is_empty():
		return
	var hex_r: float = float(layer.tile_set.tile_size.x) / 2.0
	for index in range(picks.size()):
		var center: Vector2 = layer.map_to_local(picks[index])
		# First pick is the biggest share of the army, so it gets the
		# strongest mark; the fill fades for the later, smaller shares.
		var weight := 1.0 - 0.18 * float(index)
		draw_colored_polygon(_hex_polygon(center, hex_r * 0.8),
				Color(color.r, color.g, color.b, 0.22 * weight))
		_draw_outline(center, hex_r * 0.8, weight)


## A hexagon outline, drawn as six 2-pixel segments so the mark reads on top
## of any tile color (the same "outline, don't fill" trick the charge ring
## uses for legibility).
func _draw_outline(center: Vector2, r: float, weight: float) -> void:
	var line := Color(color.r, color.g, color.b, 0.85 * weight)
	var pts := _hex_polygon(center, r)
	for i in range(pts.size()):
		draw_line(pts[i], pts[(i + 1) % pts.size()], line, 3.0)
	draw_circle(center, maxf(r * 0.1, 2.0), line)


static func _hex_polygon(center: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(6):
		var a := deg_to_rad(60.0 * float(i))
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts
