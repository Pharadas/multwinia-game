class_name BuildPreviewView
extends Node2D

## Draws the hex highlight that follows a carried building. White = valid
## drop, red = the drop would be rejected (mines only on the frontier
## ring). Pure view: the controller emits positions, the facade decides
## validity; this node only draws what it is told.

const VALID_COLOR := Color(1.0, 1.0, 1.0, 0.6)
const INVALID_COLOR := Color(1.0, 0.15, 0.15, 0.7)

var _cell := Vector2i(-1, -1)
var _valid := true


## Snap the highlight to `cell` (which must map through the parent
## TileMapLayer's transform) and color it for validity.
func show_cell(cell: Vector2i, valid: bool) -> void:
	_cell = cell
	_valid = valid
	visible = cell.x >= 0
	queue_redraw()


func hide_preview() -> void:
	show_cell(Vector2i(-1, -1), true)


func _draw() -> void:
	if _cell.x < 0 or not is_inside_tree():
		return
	var layer := get_parent() as TileMapLayer
	if layer == null:
		return
	var tile_sz := Vector2(layer.tile_set.tile_size)
	var pts := PackedVector2Array()
	var r := tile_sz.x * 0.55
	for i in range(6):
		var a := deg_to_rad(60.0 * float(i))
		pts.append(Vector2(cos(a), sin(a)) * r)
	position = layer.map_to_local(_cell)
	draw_colored_polygon(pts, VALID_COLOR if _valid else INVALID_COLOR)
