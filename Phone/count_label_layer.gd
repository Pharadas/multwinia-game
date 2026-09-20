class_name CountLabelLayer
extends Node2D

## Draws the per-hex darwinian count labels centered on each cell.
## create/update/remove are safe to call constantly (e.g. on every network
## update) - labels are pooled per cell and updated in place instead of
## rebuilt, so repeated calls never pile up duplicates.

@export var font_size: int = 20
@export var font_color: Color = Color.WHITE
@export var outline_color: Color = Color.BLACK
@export var outline_size: int = 4
## Bounding box used to center the text on the tile - doesn't need to match
## the tile size exactly, just wide/tall enough for the text.
@export var box_size: Vector2 = Vector2(50, 24)

var _labels := {}  # Vector2i -> Label
var _enabled := true


func set_enabled(enabled: bool) -> void:
	_enabled = enabled


## Creates the label for one cell if missing, otherwise updates its text.
func update_count(cell: Vector2i, count) -> void:
	if not _enabled or count == null:
		remove_label(cell)
		return
	var label: Label = _labels.get(cell)
	if not label:
		label = _make_label(cell)
		_labels[cell] = label
	label.text = str(count)


func remove_label(cell: Vector2i) -> void:
	if not _labels.has(cell):
		return
	var label = _labels[cell]
	if is_instance_valid(label):
		label.queue_free()
	_labels.erase(cell)


func clear_all() -> void:
	for label in _labels.values():
		if is_instance_valid(label):
			label.queue_free()
	_labels.clear()


func _make_label(cell: Vector2i) -> Label:
	var label := Label.new()
	label.size = box_size
	label.position = cell_center(cell) - box_size / 2.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", font_color)
	label.add_theme_color_override("font_outline_color", outline_color)
	label.add_theme_constant_override("outline_size", outline_size)
	# Let clicks/drags pass through to the grid input handler.
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label


func cell_center(cell: Vector2i) -> Vector2:
	var layer := get_parent() as TileMapLayer
	if layer == null:
		return Vector2.ZERO
	return layer.map_to_local(cell)
