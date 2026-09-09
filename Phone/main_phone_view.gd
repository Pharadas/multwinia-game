@tool
extends Node2D
class_name HexGrid2D

## A 2D mirror of the 3D hex terrain: a hexagonal TileMapLayer where cell
## (col, row) corresponds 1:1 to the 3D grid's Hex_<col>_<row> tile.
##
## IMPORTANT: this script does NOT reimplement the hex spacing/offset math -
## it relies on `tile_map_layer`'s TileSet being configured as a hexagon
## tileset that matches the 3D layout (flat-top hexes, odd columns pushed
## down half a cell): Tile Shape = Hexagon, Tile Offset Axis = Horizontal.
## Godot's TileMapLayer then handles all the placement/click math for you -
## get the TileSet's Tile Size proportioned like the 3D grid's
## horiz_spacing/vert_spacing (hex_terrain.gd's _layout()) and the two grids
## will line up visually.

## Emitted whenever a plain (non-drag) click lands on a cell, regardless of
## whether a 3D tile existed for it.
signal hex_clicked(col: int, row: int)

## Optional: a same-process 3D terrain (hex_terrain.gd) this grid mirrors.
## Only useful for local testing with both in one scene tree - once they're
## split across instances, use socket_path instead, which does the same job
## over the network.
@export var terrain_path: NodePath

## A HexGrid2DSocket node (same instance/process as this grid) that connects
## to the 3D instance's HexTerrainSocket. When assigned, clicks are sent
## through it instead of (or as well as) calling a same-process terrain_path.
@export var socket_path: NodePath

## The TileMapLayer that draws the hex cells. Give it a hexagonal TileSet
## in the editor (Tile Shape = Hexagon, Tile Offset Axis = Horizontal,
## Tile Size matching the 3D grid) with exactly one tile painted into its
## atlas source somewhere - this script always finds and reuses that first
## tile for every cell, so you don't need to tell it which atlas
## source/coords to use.
@export var tile_map_layer: TileMapLayer

## Only used if terrain_path is empty (nothing to auto-read grid size from).
@export var grid_width: int = 20
@export var grid_depth: int = 20

## Color painted over wall tiles (is_wall) so solid hexes show up in the
## 2D view instead of looking like passable ground. Roads are still routed
## around them; this just makes the blockage visible.
@export var wall_color: Color = Color(0.16, 0.15, 0.14, 1.0)

## Name of the function to call on the 3D HexTile when its 2D cell is
## clicked, for the same-process terrain_path fallback only - the socket
## path always just forwards (col, row) and lets HexTerrainSocket decide
## what to call. The tile just needs to define a method with this name - see
## HexTile.on_tile_selected() for a ready-made stub.
@export var click_method_name: String = "on_tile_selected"

## --- Tile-to-tile connections: press on one tile, drag to another, and
## release to draw a road between their centers. Drag the same pair of
## tiles again (either direction) to delete that road instead.
@export_group("Connections")
@export var connection_line_color: Color = Color(1.0, 0.85, 0.2, 0.9)
@export var connection_line_width: float = 200.0
@export var connection_node_radius: float = 6.0
@export var pending_marker_color: Color = Color(1.0, 1.0, 1.0, 0.55)
@export var pending_marker_radius: float = 9.0
@export var preview_line_color: Color = Color(1.0, 1.0, 1.0, 0.4)

## --- Per-tile Darwinian count label, drawn centered on top of each tile.
@export_group("Darwinian Counts")
## Turn the number display off entirely without touching any other logic.
@export var show_darwinian_counts: bool = true
## Dictionary key expected on each entry passed to populate_from_data() -
## change this if HexTerrainSocket's "terrain" message uses a different
## field name for the count.
@export var darwinian_count_key: String = "darwinians"
## Property name read off the same-process 3D HexTile node (terrain_path
## fallback only, mirrors how _get_tile_color() reads "color").
@export var darwinian_count_property_name: String = "darwinian_count"
@export var darwinian_count_font_size: int = 20
@export var darwinian_count_color: Color = Color.WHITE
@export var darwinian_count_outline_color: Color = Color.BLACK
@export var darwinian_count_outline_size: int = 4
## Size of the label's bounding box, used to center it on the tile - doesn't
## need to match the tile size exactly, just wide/tall enough for the text.
@export var darwinian_count_box_size: Vector2 = Vector2(50, 24)

## Emitted once a drag has connected two tiles with a new road.
signal tiles_connected(from_cell: Vector2i, to_cell: Vector2i)
## Emitted when a drag over an already-connected pair removes that road.
signal tiles_disconnected(from_cell: Vector2i, to_cell: Vector2i)

var team_number: int

var _terrain: Node = null
var _cell_colors: Dictionary = {} # Vector2i(col, row) -> Color, from network data
var _cell_counts: Dictionary = {} # Vector2i(col, row) -> int (darwinian count), from network data
var _cell_walls: Dictionary = {} # Vector2i(col, row) -> bool, solid wall tiles, from network data
var _count_labels: Dictionary = {} # Vector2i(col, row) -> Label, the number drawn on top of that tile

# --- Drag state ---------------------------------------------------
var _drag_start_cell = null # Vector2i once a drag has begun, else null
var _is_dragging: bool = false
var _pending_marker: Node2D = null
var _preview_line: Line2D = null
var _last_sent_hover_cell = null # Vector2i - last cell broadcast via _send_click_over_network(), to avoid re-sending the same cell every single frame
var _touch_active: bool = false # true while a real finger (not an emulated mouse event) is down/dragging
var _touch_position: Vector2 = Vector2.ZERO # last known touch position, in the same global/viewport space as mouse position

# --- Draw mode: free-draw a path, simplify to 16 points, send over network
var _draw_mode: bool = false
var _draw_points: PackedVector2Array = []
var _draw_line: Line2D = null
var _drawn_paths: Array[Line2D] = []
const DRAW_SAMPLE_COUNT := 16

# Roads, keyed by an order-independent string so a drag from either end
# finds the same road. Each entry stores the Line2D/marker nodes that make
# up that road (so a single road can be removed without touching the rest)
# plus the routed path of hexes it passes through.
var _connections: Dictionary = {} # key -> {"from": Vector2i, "to": Vector2i, "nodes": Array[Node], "path": Array[Vector2i]}
var _connection_nodes: Array[Node] = [] # every Line2D/marker drawn so far, for cleanup on repopulate

# --- Hex detail view state ---
var _detail_view: HexDetailView = null
## Buildings placed per parent hex: Vector2i(col,row) -> {Vector2i(sub_q,sub_r) -> building_id}
var _hex_buildings: Dictionary = {}
## Node2D child of tile_map_layer that draws building markers on the grid.
var _building_marker_layer: Node2D = null
var _last_click_cell: Vector2i = Vector2i(-1, -1)
var _last_click_time: float = 0.0
const DOUBLE_CLICK_WINDOW := 0.35 # seconds


func _ready() -> void:
	if terrain_path != NodePath():
		_terrain = get_node_or_null(terrain_path)
		if _terrain:
			grid_width = _terrain.grid_width
			grid_depth = _terrain.grid_depth
			# Same-process fallback only. Once the terrain runs in a
			# separate instance, HexGrid2DSocket calls populate_from_data()
			# instead - see hex_grid_2d_socket.gd.
			if _terrain.has_signal("terrain_ready"):
				_terrain.terrain_ready.connect(populate)

	_setup_ui()
	populate()
	# Keep the grid filling the screen no matter the device or orientation -
	# re-fit whenever the viewport changes size.
	get_viewport().size_changed.connect(_fit_to_screen)


func _setup_ui() -> void:
	# Create overlay CanvasLayer for UI buttons so they render cleanly over the TileMapLayer
	var canvas := CanvasLayer.new()
	canvas.name = "PhoneUI"
	add_child(canvas)

	var btn := Button.new()
	btn.name = "ResetRoadsButton"
	btn.text = "Reset All Roads"
	btn.anchor_left = 1.0
	btn.anchor_top = 0.0
	btn.anchor_right = 1.0
	btn.anchor_bottom = 0.0
	btn.offset_left = -170.0
	btn.offset_top = 20.0
	btn.offset_right = -20.0
	btn.offset_bottom = 70.0
	btn.pressed.connect(_on_reset_roads_pressed)
	canvas.add_child(btn)

	var draw_btn := Button.new()
	draw_btn.name = "DrawModeButton"
	draw_btn.text = "Draw Path"
	draw_btn.anchor_left = 0.0
	draw_btn.anchor_top = 0.0
	draw_btn.anchor_right = 0.0
	draw_btn.anchor_bottom = 0.0
	draw_btn.offset_left = 20.0
	draw_btn.offset_top = 20.0
	draw_btn.offset_right = 150.0
	draw_btn.offset_bottom = 70.0
	draw_btn.toggle_mode = true
	draw_btn.toggled.connect(_on_draw_mode_toggled)
	canvas.add_child(draw_btn)


func _on_reset_roads_pressed() -> void:
	_clear_connections()
	_send_reset_roads_over_network()


func _on_draw_mode_toggled(pressed: bool) -> void:
	_draw_mode = pressed
	if not pressed and _draw_points.size() >= 2:
		_send_simplified_path()
	_draw_points.clear()
	if _draw_line:
		# Keep the line visible as a completed path
		_draw_line.default_color = Color(1.0, 0.3, 0.3, 0.6)
		_drawn_paths.append(_draw_line)
		_draw_line = null


func _ensure_draw_line() -> void:
	if _draw_line:
		return
	_draw_line = Line2D.new()
	_draw_line.width = 8.0
	_draw_line.default_color = Color(1.0, 0.3, 0.3, 0.9)
	_draw_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_draw_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	# Add to tile_map_layer so it scales with the hex grid
	tile_map_layer.add_child(_draw_line)


## Uniformly sample `count` points along an arc-length parameterization
## of `points`.
func _simplify_path(points: PackedVector2Array, count: int) -> PackedVector2Array:
	var n := points.size()
	if n < 2 or count < 2:
		return points

	# Cumulative arc length
	var cum := PackedFloat32Array()
	cum.resize(n)
	cum[0] = 0.0
	for i in range(1, n):
		cum[i] = cum[i - 1] + points[i - 1].distance_to(points[i])
	var total := cum[n - 1]
	if total < 0.001:
		return points

	var result := PackedVector2Array()
	result.resize(count)
	for s in range(count):
		var target := total * float(s) / float(count - 1)
		# Find segment
		var seg := 0
		for i in range(1, n):
			if cum[i] >= target:
				seg = i - 1
				break
			seg = i - 1
		var seg_len := cum[mini(seg + 1, n - 1)] - cum[seg]
		var frac := 0.0
		if seg_len > 0.001:
			frac = (target - cum[seg]) / seg_len
		result[s] = points[seg].lerp(points[mini(seg + 1, n - 1)], frac)
	return result


func _send_simplified_path() -> void:
	var simplified := _simplify_path(_draw_points, DRAW_SAMPLE_COUNT)
	# Send raw tilemap-local positions (the smooth curve) plus reference
	# cell mappings so the server can compute the affine transform to
	# world-space without snapping to hex centers.
	var ref_cells: Array = [Vector2i(0, 0), Vector2i(2, 0), Vector2i(0, 2)]
	var ref_locals: Array = []
	for c in ref_cells:
		ref_locals.append(tile_map_layer.map_to_local(c))
	_send_drawn_path_over_network(simplified, ref_cells, ref_locals)


func _send_drawn_path_over_network(points: Array, ref_cells: Array = [], ref_locals: Array = []) -> void:
	var socket := _get_socket_node()
	print("sending drawn path: ", points)
	if socket and socket.has_method("send_drawn_path"):
		socket.send_drawn_path(points, team_number, ref_cells, ref_locals)


## Rebuilds the grid straight from network data - an array of
## {"col", "row", "color", "is_wall", "<darwinian_count_key>"} dicts, exactly
## what HexTerrainSocket sends. This is the primary path once the 3D terrain
## runs in a separate instance; see hex_grid_2d_socket.gd.
func populate_from_data(tiles: Array) -> void:
	print("HexGrid2D: populate_from_data() got %d tiles." % tiles.size())
	_cell_colors.clear()
	_cell_counts.clear()
	_cell_walls.clear()
	var max_col := 0
	var max_row := 0
	for entry in tiles:
		var cell := Vector2i(entry.col, entry.row)
		_cell_colors[cell] = entry.color
		if entry.has("is_wall"):
			_cell_walls[cell] = entry.is_wall
		if entry.has(darwinian_count_key):
			_cell_counts[cell] = entry[darwinian_count_key]
		else:
			_cell_counts[cell] = 0
		max_col = maxi(max_col, entry.col)
		max_row = maxi(max_row, entry.row)

	if not tiles.is_empty():
		grid_width = max_col + 1
		grid_depth = max_row + 1

	populate()


## Fills every cell so the 2D map covers the same (col, row) range as the 3D
## grid, tinting each cell to match its 3D tile's color (if known yet -
## safe to call again once it is, e.g. via populate_from_data()). Every
## cell is painted with the SAME tile - whichever one is first found in
## the TileSet's atlas source - and colored via a per-cell "alternative
## tile" (TileMapLayer has no per-cell modulate of its own).
func populate() -> void:
	if not tile_map_layer:
		push_warning("HexGrid2D: no tile_map_layer assigned.")
		return
	if not tile_map_layer.tile_set:
		push_warning("HexGrid2D: tile_map_layer has no TileSet assigned.")
		return

	if not tile_map_layer.tile_set.is_local_to_scene():
		tile_map_layer.tile_set = tile_map_layer.tile_set.duplicate(true)

	var source_id := 0
	var source: TileSetAtlasSource = null
	var atlas_coords := Vector2i(0, 0)
	var tile_set := tile_map_layer.tile_set
	for i in range(tile_set.get_source_count()):
		var sid := tile_set.get_source_id(i)
		var candidate := tile_set.get_source(sid) as TileSetAtlasSource
		if candidate and candidate.get_tiles_count() > 0:
			source_id = sid
			source = candidate
			atlas_coords = candidate.get_tile_id(0)
			break

	if not source:
		push_warning("HexGrid2D: tile_map_layer's TileSet has no atlas source with a painted tile - add one tile to it in the TileSet editor.")
		return

	_clear_connections()
	_clear_count_labels()
	tile_map_layer.clear()

	for col in range(grid_width):
		for row in range(grid_depth):
			var alt_id := 0
			# Walls keep their own flat dark color so they read as solid
			# obstacles on the map; everything else uses the tile color.
			var color = wall_color if _get_tile_is_wall(col, row) else _get_tile_color(col, row)
			if color != null:
				alt_id = _alt_id_for(col, row)
				if not source.has_alternative_tile(atlas_coords, alt_id):
					source.create_alternative_tile(atlas_coords, alt_id)
				source.get_tile_data(atlas_coords, alt_id).modulate = color
			tile_map_layer.set_cell(Vector2i(col, row), source_id, atlas_coords, alt_id)
			_update_count_label(col, row)

	if tile_map_layer.has_method("notify_runtime_tile_data_update"):
		tile_map_layer.notify_runtime_tile_data_update()
	tile_map_layer.queue_redraw()

	_fit_to_screen()


## Scales the TileMapLayer uniformly so the whole hex grid fits inside the
## viewport (with a little padding), then re-centers it. Runs on startup,
## after every populate(), and whenever the viewport resizes - so the grid
## never spills off-screen regardless of phone size or orientation. Input
## keeps working because _cell_under_mouse() converts through the layer's
## own transform, and roads/count labels are children of the layer so they
## follow the same scale.
func _fit_to_screen() -> void:
	if not tile_map_layer or not tile_map_layer.tile_set:
		return
	var cells := tile_map_layer.get_used_cells()
	if cells.is_empty():
		return

	# Bounding box of the used cells in the layer's own (unscaled) space -
	# computed from every cell center so hex row/column offsets are included.
	var min_pos := tile_map_layer.map_to_local(cells[0])
	var max_pos := min_pos
	for i in range(1, cells.size()):
		var p := tile_map_layer.map_to_local(cells[i])
		min_pos = min_pos.min(p)
		max_pos = max_pos.max(p)

	# tile_size is Vector2i in Godot - widen it so the math below stays in
	# Vector2 space.
	var tile_size := Vector2(tile_map_layer.tile_set.tile_size)
	var grid_min := min_pos - tile_size / 2.0
	var grid_size := (max_pos - min_pos) + tile_size

	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	# Uniform scale (hexes keep their shape) so the grid fits, with ~10%
	# padding so it never touches the screen edges.
	var scale := minf(viewport_size.x / grid_size.x, viewport_size.y / grid_size.y) * 0.9
	if scale <= 0.0:
		return

	tile_map_layer.scale = Vector2(scale, scale)
	# Center the grid in the viewport.
	tile_map_layer.position = viewport_size / 2.0 - (grid_min + grid_size / 2.0) * scale


## Deterministic, unique alternative-tile id per cell (0 means "no
## alternative", so offset by 1).
func _alt_id_for(col: int, row: int) -> int:
	return row * grid_width + col + 1


## Creates the label for one tile if it doesn't have one yet, otherwise
## just updates its text in place - so this is safe to call constantly
## (e.g. every time a fresh count arrives over the network) without
## piling up duplicate labels or doing a full rebuild.
func _update_count_label(col: int, row: int) -> void:
	if not tile_map_layer:
		return
	var cell := Vector2i(col, row)
	if not show_darwinian_counts:
		_remove_count_label(cell)
		return

	var count = _get_tile_count(col, row)
	if count == null:
		# No data (yet) for this cell - clear any stale label rather than
		# leaving an outdated number showing.
		_remove_count_label(cell)
		return

	var label: Label = _count_labels.get(cell)
	if not label:
		label = Label.new()
		label.size = darwinian_count_box_size
		label.position = tile_map_layer.map_to_local(cell) - darwinian_count_box_size / 2.0
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", darwinian_count_font_size)
		label.add_theme_color_override("font_color", darwinian_count_color)
		label.add_theme_color_override("font_outline_color", darwinian_count_outline_color)
		label.add_theme_constant_override("outline_size", darwinian_count_outline_size)
		# Otherwise this Control would swallow clicks before they ever reach
		# _unhandled_input, breaking tile clicks/drags under any tile with a count.
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile_map_layer.add_child(label)
		_count_labels[cell] = label

	label.text = str(count)


## Removes one cell's label (if it has one).
func _remove_count_label(cell: Vector2i) -> void:
	if not _count_labels.has(cell):
		return
	var label = _count_labels[cell]
	if is_instance_valid(label):
		label.queue_free()
	_count_labels.erase(cell)


## Removes every count label so populate() can rebuild them from scratch.
func _clear_count_labels() -> void:
	for label in _count_labels.values():
		if is_instance_valid(label):
			label.queue_free()
	_count_labels.clear()


## Live update for a single cell's darwinian count - does NOT touch tile
## colors, roads, or any other cell, so it's cheap enough to call
## constantly as counts change (e.g. once per network message), unlike
## populate()/populate_from_data() which rebuild the whole grid.
func update_darwinian_count(col: int, row: int, count) -> void:
	_cell_counts[Vector2i(col, row)] = count
	_update_count_label(col, row)


## Batch version of update_darwinian_count() - entries need at least "col",
## "row", and darwinian_count_key (same shape as populate_from_data(), but
## a count-only message doesn't need "color" too). Only the included cells'
## labels are touched.
func update_darwinian_counts(entries: Array) -> void:
	for entry in entries:
		if not entry.has(darwinian_count_key):
			continue
		update_darwinian_count(entry.col, entry.row, entry[darwinian_count_key])



## Darwinian count for a cell: prefers network data (populate_from_data()),
## falls back to reading the same-process 3D HexTile directly if
## terrain_path is set. Returns null if neither has an answer yet.
func _get_tile_count(col: int, row: int):
	var cell := Vector2i(col, row)
	if _cell_counts.has(cell):
		return _cell_counts[cell]

	if not _terrain or not _terrain.has_method("get_hex_node"):
		return null
	var tile: Node = _terrain.get_hex_node(col, row)
	if tile and darwinian_count_property_name in tile:
		return tile.get(darwinian_count_property_name)
	return null


## Color for a cell: prefers network data (populate_from_data()), falls back
## to reading the same-process 3D HexTile directly if terrain_path is set.
## Returns null if neither has an answer yet.
func _get_tile_color(col: int, row: int):
	var cell := Vector2i(col, row)
	if _cell_colors.has(cell):
		return _cell_colors[cell]

	if not _terrain or not _terrain.has_method("get_hex_node"):
		return null
	var tile: Node = _terrain.get_hex_node(col, row)
	if tile and "color" in tile:
		return tile.color
	return null


## Whether cell (col, row) is a solid wall tile: prefers network data
## (populate_from_data()), falls back to reading the same-process 3D HexTile
## directly if terrain_path is set. Used to route drawn roads around walls.
func _get_tile_is_wall(col: int, row: int) -> bool:
	var cell := Vector2i(col, row)
	if _cell_walls.has(cell):
		return _cell_walls[cell]

	if not _terrain or not _terrain.has_method("get_hex_node"):
		return false
	var tile: Node = _terrain.get_hex_node(col, row)
	if tile and "is_wall" in tile:
		return tile.is_wall
	return false


## The six cells adjacent to `cell` in this hex grid (flat-top hexes, odd
## columns pushed down half a cell - matching the 3D layout). Prefers the
## TileSet's own hex neighbor query when available so it can never disagree
## with how the drawn map places cells; falls back to hand-rolled odd/even
## column offsets otherwise.
func _neighbor_cells(cell: Vector2i) -> Array:
	if tile_map_layer and tile_map_layer.has_method("get_surrounding_cells"):
		return tile_map_layer.get_surrounding_cells(cell)

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


## Routes a road from `from_cell` to `to_cell` as a chain of adjacent hexes
## that avoids wall tiles, so the darwinians - which only ever know the next
## hop on the tile they're standing on - march around walls instead of into
## them. BFS over the hex grid (small - at most grid_width*grid_depth cells),
## computed once per drawn road and shared by every darwinian. Returns an
## empty Array if no clear route exists (e.g. an endpoint is a wall, or the
## start is completely boxed in).
func _find_path(from_cell: Vector2i, to_cell: Vector2i) -> Array:
	if from_cell == to_cell:
		return [from_cell]
	if _get_tile_is_wall(from_cell.x, from_cell.y) or _get_tile_is_wall(to_cell.x, to_cell.y):
		return []

	var came_from := {from_cell: Vector2i(-1, -1)}
	var frontier: Array = [from_cell]
	var fi := 0
	while fi < frontier.size():
		var current: Vector2i = frontier[fi]
		fi += 1
		if current == to_cell:
			break
		for nb in _neighbor_cells(current):
			if not _cell_in_bounds(nb) or came_from.has(nb):
				continue
			if _get_tile_is_wall(nb.x, nb.y):
				continue
			came_from[nb] = current
			frontier.append(nb)

	if not came_from.has(to_cell):
		return []

	# Walk back from the destination to rebuild the chain, then flip it.
	var path: Array = [to_cell]
	var cur := to_cell
	while cur != from_cell:
		cur = came_from[cur]
		path.append(cur)
	path.reverse()
	return path
## Opens the full-screen HexDetailView for `cell` - a standalone "scene"
## showing that hex as a honeycomb of sub-hexagons, tinted with the hex's
## own color. Back returns to the grid view.
func _open_hex_detail(cell: Vector2i) -> void:
	if _detail_view and is_instance_valid(_detail_view):
		_detail_view.queue_free()
		_detail_view = null

	var color = _get_tile_color(cell.x, cell.y)
	if color == null:
		color = Color(0.4, 0.6, 0.8)
	var is_wall: bool = _get_tile_is_wall(cell.x, cell.y)

	_detail_view = HexDetailView.new()
	_detail_view.setup(cell.x, cell.y, color, is_wall)
	_detail_view.z_index = 100
	_detail_view.back_pressed.connect(_close_hex_detail)
	_detail_view.building_placed.connect(_on_building_placed)
	# Restore any buildings previously placed in this hex (local + synced).
	var saved: Dictionary = _hex_buildings.get(cell, {})
	if not saved.is_empty():
		_detail_view.set_buildings(saved)
	add_child(_detail_view)


## A building was dropped on sub-hex (sub_q, sub_r) of the open hex. Remember
## it locally and forward it to the main screen, which spawns the 3D mesh.
func _on_building_placed(sub_q: int, sub_r: int, building_id: int) -> void:
	if not _detail_view:
		return
	var cell := Vector2i(_detail_view.hex_col, _detail_view.hex_row)
	var buildings: Dictionary = _hex_buildings.get(cell, {})
	buildings[Vector2i(sub_q, sub_r)] = building_id
	_hex_buildings[cell] = buildings
	_update_building_markers()

	var socket := _get_socket_node()
	if socket and socket.has_method("send_building_placed"):
		socket.send_building_placed(cell.x, cell.y, sub_q, sub_r, building_id, team_number)


## Rebuilds (or creates) the Node2D that draws a small hexagonal marker on
## every parent hex that has buildings - one marker per building, colored
## like the building and positioned at its sub-hex location within the hex.
func _update_building_markers() -> void:
	if not tile_map_layer:
		return
	if not _building_marker_layer or not is_instance_valid(_building_marker_layer):
		_building_marker_layer = Node2D.new()
		_building_marker_layer.name = "BuildingMarkers"
		tile_map_layer.add_child(_building_marker_layer)

	var layer := _building_marker_layer
	layer.queue_redraw()
	# Rebind the draw callback to the latest data (replacing any old one).
	layer.draw.connect(func():
		var tile_sz := Vector2(tile_map_layer.tile_set.tile_size)
		var hex_r: float = tile_sz.x / 2.0
		var sub_r: float = hex_r / 4.0  # 3-ring honeycomb spans ~4 sub radii
		for hex_cell in _hex_buildings:
			var buildings: Dictionary = _hex_buildings[hex_cell]
			var base := tile_map_layer.map_to_local(hex_cell)
			for sub_cell in buildings:
				var bid: int = buildings[sub_cell]
				var q = sub_cell.x
				var r = sub_cell.y
				var off := Vector2(sub_r * 1.5 * float(q), sub_r * sqrt(3.0) * (float(r) + float(q) * 0.5))
				_draw_small_hex(layer, base + off, sub_r * 0.9, HexDetailView.BUILDING_COLORS.get(bid, Color.WHITE))
	, CONNECT_REFERENCE_COUNTED)


static func _draw_small_hex(target: CanvasItem, center: Vector2, r: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in range(6):
		var a := deg_to_rad(60.0 * float(i))
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	target.draw_colored_polygon(pts, color)


## Removes the hex detail view and returns to the grid.
func _close_hex_detail() -> void:
	if _detail_view and is_instance_valid(_detail_view):
		_detail_view.queue_free()
	_detail_view = null

# --- Input handling ---------------------------------------------------
# Press (mouse or a first finger) on a cell to start a drag, drag anywhere,
# release to resolve it:
#   - release on the same cell you started on -> treated as a plain click
#   - release on a different cell -> toggles a road between the two cells
# The endpoint is always computed fresh via _cell_under_mouse() - no
# separate hover-event tracking - and _process() polls it every frame while
# dragging so the preview line follows the pointer instead of waiting on
# motion/drag input events.
func _unhandled_input(event: InputEvent) -> void:
	if not tile_map_layer:
		return
	# While the hex detail view is open, the grid ignores all input -
	# the detail view's own back button is the only way out.
	if _detail_view and is_instance_valid(_detail_view):
		return

	if event is InputEventScreenTouch:
		if event.index != 0:
			return
		_touch_position = event.position
		_touch_active = true
		if event.pressed:
			if _draw_mode:
				_draw_points.clear()
				_draw_points.append(tile_map_layer.to_local(event.position))
				_ensure_draw_line()
			else:
				_start_drag()
		else:
			if _draw_mode:
				if _draw_points.size() >= 2:
					_send_simplified_path()
				_draw_points.clear()
			else:
				_end_drag()
			_touch_active = false
		return

	if event is InputEventScreenDrag:
		if event.index != 0:
			return
		_touch_position = event.position
		if _draw_mode:
			var local_pos = tile_map_layer.to_local(event.position)
			if _draw_points.size() == 0 or _draw_points[_draw_points.size() - 1].distance_to(local_pos) > 5.0:
				_draw_points.append(local_pos)
				_ensure_draw_line()
				_draw_line.points = _draw_points
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if _touch_active:
			return
		if event.pressed:
			if _draw_mode:
				_draw_points.clear()
				_draw_points.append(tile_map_layer.to_local(event.position))
				_ensure_draw_line()
			else:
				_start_drag()
		else:
			if _draw_mode:
				if _draw_points.size() >= 2:
					_send_simplified_path()
				_draw_points.clear()
			else:
				_end_drag()


func _process(_delta: float) -> void:
	if not tile_map_layer:
		return
	if _detail_view and is_instance_valid(_detail_view):
		return

	# In draw mode with mouse held, capture mouse motion as draw points
	if _draw_mode and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _touch_active:
		var local_pos = tile_map_layer.to_local(get_viewport().get_mouse_position())
		if _draw_points.size() == 0 or _draw_points[_draw_points.size() - 1].distance_to(local_pos) > 5.0:
			_draw_points.append(local_pos)
			_ensure_draw_line()
			_draw_line.points = _draw_points

	# Continuously broadcast whatever cell the pointer (mouse or touch) is
	# over right now, so the receiver always has an up-to-date hover
	# position - not just on click/drag-end.
	var cell := _cell_under_mouse()
	if cell != _last_sent_hover_cell:
		_last_sent_hover_cell = cell
		_send_click_over_network()

	if _is_dragging:
		_update_preview_line()


## The cell under the pointer right now - mouse or touch, whichever is
## active - pulled into one place so drag-start, drag-preview, and
## drag-end all agree on "where the pointer is".
func _cell_under_mouse() -> Vector2i:
	var local_pos: Vector2
	if _touch_active:
		local_pos = tile_map_layer.to_local(_touch_position)
	else:
		local_pos = tile_map_layer.get_local_mouse_position()
	return tile_map_layer.local_to_map(local_pos)



func _cell_in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < grid_width and cell.y >= 0 and cell.y < grid_depth


func _start_drag() -> void:
	var cell := _cell_under_mouse()
	if not _cell_in_bounds(cell):
		return

	_drag_start_cell = cell
	_is_dragging = true
	_show_pending_marker(_drag_start_cell)
	_update_preview_line()


func _end_drag() -> void:
	if not _is_dragging or _drag_start_cell == null:
		_cancel_drag()
		return

	var start_cell: Vector2i = _drag_start_cell
	var end_cell := _cell_under_mouse()
	_cancel_drag()

	if not _cell_in_bounds(end_cell):
		return
	if end_cell == start_cell:
		print("gaming time")
		# No real drag — check for double-click to open the hex detail view.
		var now := Time.get_ticks_msec() / 1000.0
		if end_cell == _last_click_cell and (now - _last_click_time) < DOUBLE_CLICK_WINDOW:
			_last_click_cell = Vector2i(-1, -1)
			_open_hex_detail(end_cell)
			return
		_last_click_cell = end_cell
		_last_click_time = now
		# Plain single-click.
		_call_tile_function(start_cell.x, start_cell.y)
		_send_click_over_network()
		hex_clicked.emit(start_cell.x, start_cell.y)
		return

	_toggle_connection(start_cell, end_cell)


func _cancel_drag() -> void:
	_clear_pending_marker()
	_clear_preview_line()
	_drag_start_cell = null
	_is_dragging = false


## Looks up the matching 3D HexTile via the terrain's get_hex_node(col, row)
## and calls click_method_name on it - same-process fallback only.
func _call_tile_function(col: int, row: int) -> void:
	if not _terrain or not _terrain.has_method("get_hex_node"):
		return
	var tile: Node = _terrain.get_hex_node(col, row)
	if tile and tile.has_method(click_method_name):
		tile.call(click_method_name)


func _get_socket_node() -> Node:
	if socket_path != NodePath():
		var node := get_node_or_null(socket_path)
		if node:
			return node
	return get_node_or_null("Socket")


## Sends the click to the 3D instance over the network via socket_path, if
## one is assigned. This is the normal path once the two run separately.
## Always sends whatever cell the mouse is hovering over right now (via
## _cell_under_mouse()) rather than trusting a passed-in/cached position.
func _send_click_over_network() -> void:
	var socket := _get_socket_node()
	if not socket or not socket.has_method("send_tile_clicked"):
		return
	var cell := _cell_under_mouse()
	socket.send_tile_clicked(cell.x, cell.y, team_number)


## Sends a locally-made connection to the 3D instance over socket_path, if
## one is assigned - the server applies it and rebroadcasts it to every
## other connected phone.
func _send_connection_over_network(from_cell: Vector2i, to_cell: Vector2i, team_num: int, path: Array = []) -> void:
	var socket := _get_socket_node()
	if socket and socket.has_method("send_new_connection"):
		socket.send_new_connection(from_cell, to_cell, team_num, path)


## Sends a locally-made removal to the 3D instance over socket_path, if one
## is assigned - mirror of _send_connection_over_network for deletions.
func _send_connection_removed_over_network(from_cell: Vector2i, to_cell: Vector2i, team_num: int) -> void:
	var socket := _get_socket_node()
	if socket and socket.has_method("send_connection_removed"):
		socket.send_connection_removed(from_cell, to_cell, team_num)


## Sends a road reset request for this team to the 3D instance over socket_path.
func _send_reset_roads_over_network() -> void:
	var socket := _get_socket_node()
	if  socket and socket.has_method("send_clear_roads"):
		socket.send_clear_roads(team_number)


## Draws a connection that originated elsewhere (e.g. another phone) - just
## the visuals, no re-sending over the network and no touching this phone's
## own drag state. NOT currently called by anything - phones only draw
## their own roads, not other phones' - but left here in case you want an
## "admin/spectator view" that shows every road later.
func add_remote_connection(from_cell: Vector2i, to_cell: Vector2i) -> void:
	_draw_connection(from_cell, to_cell)


## Removal counterpart to add_remote_connection(), for the same future use.
func remove_remote_connection(from_cell: Vector2i, to_cell: Vector2i) -> void:
	_remove_connection(_connection_key(from_cell, to_cell))


## Order-independent key so a drag from either end finds the same road.
func _connection_key(a: Vector2i, b: Vector2i) -> String:
	if a.y < b.y or (a.y == b.y and a.x <= b.x):
		return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
	return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]


## A drag between two different cells either creates a new road, or - if
## that exact pair already has one - deletes it. This is what makes
## "draw the same road twice" act as a delete instead of piling up a
## duplicate line on top of the first.
func _toggle_connection(from_cell: Vector2i, to_cell: Vector2i) -> void:
	var key := _connection_key(from_cell, to_cell)
	if _connections.has(key):
		_remove_connection(key)
		tiles_disconnected.emit(from_cell, to_cell)
		_send_connection_removed_over_network(from_cell, to_cell, team_number)
		return

	# Route the road around wall tiles first - the darwinians follow this
	# per-hex chain, so the drawn line IS the path they'll march along. If no
	# route exists (dragging onto a wall, a boxed-in start, ...) nothing is
	# drawn or sent.
	var path := _find_path(from_cell, to_cell)
	if path.is_empty():
		return
	_draw_connection(from_cell, to_cell, path)
	tiles_connected.emit(from_cell, to_cell)
	_send_connection_over_network(from_cell, to_cell, team_number, path)


func _show_pending_marker(cell: Vector2i) -> void:
	_clear_pending_marker()
	var marker := Node2D.new()
	marker.position = tile_map_layer.map_to_local(cell)
	var radius := pending_marker_radius
	var color := pending_marker_color
	marker.draw.connect(func(): marker.draw_circle(Vector2.ZERO, radius, color))
	tile_map_layer.add_child(marker)
	marker.queue_redraw()
	_pending_marker = marker


func _clear_pending_marker() -> void:
	if _pending_marker:
		_pending_marker.queue_free()
		_pending_marker = null


## Live line from the drag's start cell to wherever the mouse is currently
## hovering, so the drag has visual feedback before you release.
func _update_preview_line() -> void:
	if _drag_start_cell == null:
		return
	if not _preview_line:
		_preview_line = Line2D.new()
		_preview_line.width = connection_line_width
		_preview_line.default_color = preview_line_color
		_preview_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
		_preview_line.end_cap_mode = Line2D.LINE_CAP_ROUND
		tile_map_layer.add_child(_preview_line)

	var from_pos := tile_map_layer.map_to_local(_drag_start_cell)
	# Raw pointer position (mouse or touch) rather than a snapped cell
	# center, so the preview line follows the cursor/finger smoothly
	# instead of jumping cell-to-cell.
	var to_pos: Vector2
	if _touch_active:
		to_pos = tile_map_layer.to_local(_touch_position)
	else:
		to_pos = tile_map_layer.get_local_mouse_position()
	_preview_line.points = PackedVector2Array([from_pos, to_pos])


func _clear_preview_line() -> void:
	if _preview_line:
		_preview_line.queue_free()
		_preview_line = null


## Draws a road as a polyline through every cell of its routed path (one dot
## per hex, so the per-hexagon route is visible), remembers the nodes under
## this pair's key (so it can be found and removed later), and also tracks
## them in _connection_nodes for blanket cleanup on repopulate. Without a
## path (e.g. add_remote_connection) it falls back to a straight line between
## the two cells, matching the old behavior.
func _draw_connection(from_cell: Vector2i, to_cell: Vector2i, path: Array = []) -> void:
	var cells: Array = path if path.size() >= 2 else [from_cell, to_cell]

	var points := PackedVector2Array()
	for cell in cells:
		points.append(tile_map_layer.map_to_local(cell))

	var line := Line2D.new()
	line.width = connection_line_width
	line.default_color = connection_line_color
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	line.points = points
	tile_map_layer.add_child(line)

	var nodes: Array[Node] = [line]
	for cell in cells:
		var node_marker := Node2D.new()
		node_marker.position = tile_map_layer.map_to_local(cell)
		var radius := connection_node_radius
		var color := connection_line_color
		node_marker.draw.connect(func(): node_marker.draw_circle(Vector2.ZERO, radius, color))
		tile_map_layer.add_child(node_marker)
		node_marker.queue_redraw()
		nodes.append(node_marker)

	_connection_nodes.append_array(nodes)
	_connections[_connection_key(from_cell, to_cell)] = {
		"from": from_cell,
		"to": to_cell,
		"nodes": nodes,
		"path": cells,
	}


## Removes one specific road (by key) and its nodes, without touching any
## others.
func _remove_connection(key: String) -> void:
	if not _connections.has(key):
		return
	var entry = _connections[key]
	for node in entry.nodes:
		if is_instance_valid(node):
			_connection_nodes.erase(node)
			node.queue_free()
	_connections.erase(key)


## Removes every road drawn so far, plus any in-progress drag - called
## before a repopulate so old roads don't pile up or end up pointing at
## stale positions if the grid's dimensions changed.
func _clear_connections() -> void:
	_cancel_drag()
	for node in _connection_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_connection_nodes.clear()
	_connections.clear()
