class_name MapPopulator
extends Node2D

## Paints the hex TileMapLayer from HexMapState data and keeps the grid
## fitted to the screen. Rendering only - it never decides anything.
##
## IMPORTANT: this script does NOT reimplement hex spacing/offset math -
## it relies on the TileMapLayer's TileSet being configured as a hexagon
## tileset that matches the 3D layout (Tile Shape = Hexagon, Tile Offset
## Axis = Horizontal, Tile Size proportioned like the 3D grid's spacing).
## Get that right and the 2D map lines up with the 3D terrain for free.

## Color painted over wall tiles so solid hexes read as blockages.
@export var wall_color: Color = Color(0.16, 0.15, 0.14, 1.0)

var tile_map_layer: TileMapLayer


func _ready() -> void:
	if tile_map_layer == null:
		tile_map_layer = get_parent() as TileMapLayer
	if tile_map_layer:
		get_viewport().size_changed.connect(fit_to_screen)


## Paints every cell in the (width x depth) grid from `state`: tile color
## (walls keep their own flat color), then re-fit the view.
func populate(width: int, depth: int, state: HexMapState) -> void:
	if tile_map_layer == null:
		push_warning("MapPopulator: no TileMapLayer assigned.")
		return
	var source := _find_first_tile_source()
	if source == null:
		push_warning("MapPopulator: the TileSet has no atlas source with a painted tile - add one tile to it in the TileSet editor.")
		return
	var source_id: int = source[0]
	var atlas_coords: Vector2i = source[1]
	var atlas: TileSetAtlasSource = source[2]

	for x in range(width):
		for y in range(depth):
			var cell := Vector2i(x, y)
			var color = state.color_at(cell)
			if color == null:
				continue
			var paint: Color = wall_color if state.is_wall_at(cell) else color
			var alt_id := _alt_id_for(cell, width)
			if not atlas.has_alternative_tile(atlas_coords, alt_id):
				atlas.create_alternative_tile(atlas_coords, alt_id)
			atlas.get_tile_data(atlas_coords, alt_id).modulate = paint
			tile_map_layer.set_cell(cell, source_id, atlas_coords, alt_id)

	if tile_map_layer.has_method("notify_runtime_tile_data_update"):
		tile_map_layer.notify_runtime_tile_data_update()
	tile_map_layer.queue_redraw()
	fit_to_screen()


## True when the cell has a painted tile - the single source of truth for
## "this hex still exists" (used by the frontier ring and bounds checks).
func cell_alive(cell: Vector2i) -> bool:
	return tile_map_layer != null and tile_map_layer.get_cell_source_id(cell) != -1


## Scales the TileMapLayer uniformly so the whole hex grid fits inside the
## viewport (with a little padding), then re-centers it. Children of the
## layer (labels, markers, strokes) follow the same transform.
func fit_to_screen() -> void:
	if tile_map_layer == null or tile_map_layer.tile_set == null:
		return
	var cells := tile_map_layer.get_used_cells()
	if cells.is_empty():
		return

	# Bounding box of the used cells in the layer's own (unscaled) space,
	# from cell centers so hex row/column offsets are included.
	var min_pos := tile_map_layer.map_to_local(cells[0])
	var max_pos := min_pos
	for i in range(1, cells.size()):
		var p := tile_map_layer.map_to_local(cells[i])
		min_pos = min_pos.min(p)
		max_pos = max_pos.max(p)

	var tile_size := Vector2(tile_map_layer.tile_set.tile_size)
	var grid_min := min_pos - tile_size / 2.0
	var grid_size := (max_pos - min_pos) + tile_size

	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	# Uniform scale (hexes keep their shape) with ~10% padding.
	var s := minf(viewport_size.x / grid_size.x, viewport_size.y / grid_size.y) * 0.9
	if s <= 0.0:
		return
	tile_map_layer.scale = Vector2(s, s)
	tile_map_layer.position = viewport_size / 2.0 - (grid_min + grid_size / 2.0) * s


## Deterministic, unique alternative-tile id per cell (0 means "no
## alternative", so offset by 1).
func _alt_id_for(cell: Vector2i, width: int) -> int:
	return cell.y * width + cell.x + 1


## Finds the first atlas source with at least one painted tile - the whole
## map is painted with that one tile, tinted per cell.
func _find_first_tile_source() -> Array:
	if tile_map_layer == null or tile_map_layer.tile_set == null:
		return []
	var tile_set := tile_map_layer.tile_set
	for i in range(tile_set.get_source_count()):
		var sid := tile_set.get_source_id(i)
		var candidate := tile_set.get_source(sid) as TileSetAtlasSource
		if candidate and candidate.get_tiles_count() > 0:
			return [sid, candidate.get_tile_id(0), candidate]
	return []
