extends Node2D
class_name HexDetailView

## Full-screen overlay that shows the clicked hex's data as a honeycomb:
## smaller hexagons tiled so their overall silhouette is also a hexagon.
## Set up via setup() BEFORE adding to the scene tree so _ready() has all the data.
##
## BUILDINGS: drag one of the palette buttons (bottom bar) onto the honeycomb
## to place it. Buildings occupy WHOLE hexes - there are no sub-hex positions.
## Dropping anywhere inside the grid claims the entire hex for that building
## (one building per hex; dropping again replaces it). Placements are local
## until `building_placed` is relayed to the main screen by whoever listens.

signal back_pressed
## Emitted when a building is dropped on this hex.
## building_id: 0 = castle, 1 = tower, 2 = wall.
signal building_placed(building_id: int)

# ---- buildings ---------------------------------------------------------------
## id -> display name
const BUILDING_NAMES := {0: "Castle", 1: "Tower", 2: "Wall"}
## id -> palette/dot color on the phone
const BUILDING_COLORS := {
	0: Color(0.95, 0.85, 0.2),   # castle - gold
	1: Color(0.6, 0.6, 0.7),     # tower  - steel grey
	2: Color(0.55, 0.4, 0.3),    # wall   - brown
}
## id -> relative size of the icon dot drawn inside a sub-hex
const BUILDING_SIZES := {0: 0.55, 1: 0.38, 2: 0.22}

# ---- data from the parent hex -----------------------------------------------
var hex_col: int = 0
var hex_row: int = 0
var hex_color: Color = Color(0.4, 0.6, 0.8)
var hex_is_wall: bool = false

# ---- visual config ----------------------------------------------------------
## Number of rings around the center (1 = 7 cells, 2 = 19, 3 = 37, 4 = 61).
@export_range(1, 7) var rings: int = 3
## Fraction of the shorter screen dimension the whole hex grid should occupy.
@export_range(0.3, 0.95) var fill_fraction: float = 0.78
## Drawn border between sub-hexes.
@export var border_color: Color = Color(1.0, 1.0, 1.0, 0.30)
@export var border_width: float = 2.0
## Solid dark background behind the hex grid.
@export var bg_color: Color = Color(0.07, 0.07, 0.10, 1.0)
@export var label_font_size: int = 24
## Height of the building palette bar at the bottom of the screen.
@export var palette_height: float = 92.0

# ---- internal ---------------------------------------------------------------
var _cells: Array[Vector2i] = []
var _unit_positions: Dictionary = {}   # Vector2i -> Vector2

# Layout of the honeycomb (filled in _draw, kept so drag-drop can hit-test).
var _last_center: Vector2 = Vector2.ZERO
var _last_hex_r: float = 1.0

## The building occupying this whole hex (building_id), or -1 for none.
## Whole-hex granularity: one building per hex, no sub-hex coordinates.
var _building: int = -1

# Drag state: currently held building id, and where the finger/mouse is.
var _dragging_building: int = -1
var _drag_pos: Vector2 = Vector2.ZERO
var _drag_hot_cell: Vector2i = Vector2i(9999, 9999)  # sub-hex under drag, if any


## Call this BEFORE add_child so _ready() sees the hex data.
func setup(col: int, row: int, color: Color, is_wall: bool = false) -> void:
	hex_col = col
	hex_row = row
	hex_color = color
	hex_is_wall = is_wall


## Set the whole-hex building from synced state (e.g. when re-opening a hex
## that already has a building synced from the main screen).
## Accepts the legacy {Vector2i -> id} map too, using its first entry.
func set_building(building_id: int) -> void:
	_building = building_id
	queue_redraw()


func set_buildings(buildings: Dictionary) -> void:
	if buildings.is_empty():
		_building = -1
	else:
		var first = buildings.values()[0]
		_building = int(first) if first is int else -1
	queue_redraw()


func _ready() -> void:
	_build_cells()
	_setup_ui()
	queue_redraw()
	get_viewport().size_changed.connect(queue_redraw)


# ---- hex grid generation ----------------------------------------------------

func _build_cells() -> void:
	_cells.clear()
	_unit_positions.clear()
	for q in range(-rings, rings + 1):
		var r_min := maxi(-rings, -q - rings)
		var r_max := mini(rings,  -q + rings)
		for r in range(r_min, r_max + 1):
			var cell := Vector2i(q, r)
			_cells.append(cell)
			_unit_positions[cell] = _axial_to_pixel(q, r, 1.0)


## Flat-top hex layout: column q steps right 1.5 units; row r steps down
## sqrt(3) units, staggered by half a row per odd column.
static func _axial_to_pixel(q: int, r: int, hex_r: float) -> Vector2:
	return Vector2(
		hex_r * 1.5 * float(q),
		hex_r * sqrt(3.0) * (float(r) + float(q) * 0.5)
	)


## Six corners of a flat-top hexagon centered at `center` with circumradius `r`.
static func _hex_polygon(center: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(6):
		var a := deg_to_rad(60.0 * float(i))
		pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts


## Screen position of a sub-hex center (uses the layout cached by _draw()).
func _cell_screen_pos(cell: Vector2i) -> Vector2:
	return _last_center + (_unit_positions.get(cell, Vector2.ZERO) as Vector2) * _last_hex_r


## Which sub-hex contains the screen point `p`, or Vector2i(9999,9999) for none.
## Converts p into the unit hex layout and cube-rounds. Hexes are pointy-
## cornered flat-top (matching _hex_polygon): corner angles at 0,60,...
func _cell_at(p: Vector2) -> Vector2i:
	if _cells.is_empty():
		return Vector2i(9999, 9999)
	var local := (p - _last_center) / _last_hex_r
	# flat-top axial from pixel
	var qf := (2.0 / 3.0 * local.x)
	var rf := (-1.0 / 3.0 * local.x + sqrt(3.0) / 3.0 * local.y)
	return _cube_round(qf, rf)


static func _cube_round(qf: float, rf: float) -> Vector2i:
	var sf := -qf - rf
	var q := roundi(qf)
	var r := roundi(rf)
	var s := roundi(sf)
	var dq := absf(float(q) - qf)
	var dr := absf(float(r) - rf)
	var ds := absf(float(s) - sf)
	if dq > dr and dq > ds:
		q = -r - s
	elif dr > ds:
		r = -q - s
	return Vector2i(q, r)


# ---- drawing ----------------------------------------------------------------

func _draw() -> void:
	var vp := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, vp), bg_color)

	if _cells.is_empty():
		return

	# Find the farthest unit-radius corner so we can auto-scale to fill_fraction.
	var max_unit_dist := 0.0
	for cell in _cells:
		var p: Vector2 = _unit_positions[cell]
		max_unit_dist = maxf(max_unit_dist, p.length() + 1.0)

	# Leave room at the bottom for the building palette bar.
	var usable_h := vp.y - palette_height
	var screen_radius := minf(vp.x, usable_h) * fill_fraction * 0.5
	var hex_r := screen_radius / maxf(max_unit_dist, 0.001)
	var center := vp * 0.5

	# Cache layout for hit-testing.
	_last_center = center
	_last_hex_r = hex_r

	for cell in _cells:
		var q: int = cell.x
		var r: int = cell.y
		var ring_dist: int = maxi(abs(q), maxi(abs(r), abs(q + r)))
		var t := float(ring_dist) / float(maxi(rings, 1))

		# Brightest at center, darker towards the rim.
		var fill := hex_color.lerp(hex_color.darkened(0.5), t)
		fill.a = lerp(0.92, 0.60, t)

		# Highlight the cell currently targeted by a drag.
		if _dragging_building >= 0 and cell == _drag_hot_cell:
			fill = fill.lerp(Color.WHITE, 0.45)

		var pos := center + (_unit_positions[cell] as Vector2) * hex_r
		# Tiny gap between hexes via a slightly smaller polygon.
		var poly := _hex_polygon(pos, hex_r * 0.96)
		draw_polygon(poly, PackedColorArray([fill]))
		for i in range(6):
			draw_line(poly[i], poly[(i + 1) % 6], border_color, border_width)

		# Draw the building occupying this whole hex (a stylized icon at center).
		if _building >= 0 and cell == Vector2i.ZERO:
			_draw_building_icon(pos, hex_r, _building)

	# Dragged building follows the finger above everything.
	if _dragging_building >= 0:
		_draw_building_icon(_drag_pos, hex_r, _dragging_building, 0.85)


## Stylized 2D icon per building type, sized relative to the sub-hex radius.
func _draw_building_icon(pos: Vector2, hex_r: float, building_id: int, alpha: float = 1.0) -> void:
	var color: Color = BUILDING_COLORS.get(building_id, Color.WHITE)
	color.a = alpha
	var s: float = hex_r * float(BUILDING_SIZES.get(building_id, 0.4))

	match building_id:
		0:  # Castle - wide body + two corner towers + battlements
			var body := Rect2(pos + Vector2(-s, -s * 0.7), Vector2(s * 2.0, s * 1.4))
			draw_rect(body, color)
			# crenellations
			for i in range(3):
				var notch := Rect2(pos + Vector2(-s + i * s * 0.8, -s * 1.1), Vector2(s * 0.45, s * 0.45))
				draw_rect(notch, color)
			draw_rect(body, Color(0, 0, 0, 0.5 * alpha), false, 2.0)
		1:  # Tower - tall thin body + pointed roof
			var body := Rect2(pos + Vector2(-s * 0.55, -s * 0.2), Vector2(s * 1.1, s * 1.7))
			draw_rect(body, color)
			var roof := PackedVector2Array([
				pos + Vector2(-s * 0.75, -s * 0.2),
				pos + Vector2(s * 0.75, -s * 0.2),
				pos + Vector2(0.0, -s * 1.2),
			])
			draw_polygon(roof, PackedColorArray([color]))
			draw_rect(body, Color(0, 0, 0, 0.5 * alpha), false, 2.0)
		2:  # Wall - horizontal slab
			var body := Rect2(pos + Vector2(-s, -s * 0.45), Vector2(s * 2.0, s * 0.9))
			draw_rect(body, color)
			draw_rect(body, Color(0, 0, 0, 0.5 * alpha), false, 2.0)


# ---- building palette UI ------------------------------------------------------

func _setup_ui() -> void:
	# CanvasLayer so the UI always renders on top and ignores parent transforms.
	var canvas := CanvasLayer.new()
	canvas.name = "DetailUI"
	add_child(canvas)

	var root_ctrl := Control.new()
	root_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(root_ctrl)

	# ── Back button ──────────────────────────────────────────────────────
	var back_btn := Button.new()
	back_btn.text = "← Back"
	back_btn.anchor_left   = 0.0
	back_btn.anchor_top    = 0.0
	back_btn.anchor_right  = 0.0
	back_btn.anchor_bottom = 0.0
	back_btn.offset_left   = 16.0
	back_btn.offset_top    = 16.0
	back_btn.offset_right  = 150.0
	back_btn.offset_bottom = 58.0
	back_btn.mouse_filter  = Control.MOUSE_FILTER_STOP
	back_btn.pressed.connect(func() -> void: back_pressed.emit())
	root_ctrl.add_child(back_btn)

	# ── Hex info label ───────────────────────────────────────────────────
	var info := Label.new()
	info.text = "Hex  [%d, %d]%s" % [
		hex_col, hex_row,
		"  (wall)" if hex_is_wall else ""
	]
	info.add_theme_font_size_override("font_size", label_font_size)
	info.add_theme_color_override("font_color", Color.WHITE)
	info.add_theme_color_override("font_outline_color", Color.BLACK)
	info.add_theme_constant_override("outline_size", 4)
	info.anchor_left   = 0.5
	info.anchor_top    = 0.0
	info.anchor_right  = 0.5
	info.anchor_bottom = 0.0
	info.offset_left   = -160.0
	info.offset_top    = 16.0
	info.offset_right  = 160.0
	info.offset_bottom = 58.0
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(info)

	# ── Color swatch ─────────────────────────────────────────────────────
	var swatch := ColorRect.new()
	swatch.color = hex_color
	swatch.anchor_left   = 1.0
	swatch.anchor_top    = 0.0
	swatch.anchor_right  = 1.0
	swatch.anchor_bottom = 0.0
	swatch.offset_left   = -58.0
	swatch.offset_top    = 16.0
	swatch.offset_right  = -16.0
	swatch.offset_bottom = 58.0
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.add_child(swatch)

	# ── Building palette (bottom bar) ────────────────────────────────────
	var palette := PanelContainer.new()
	palette.anchor_left = 0.0
	palette.anchor_right = 1.0
	palette.anchor_top = 1.0
	palette.anchor_bottom = 1.0
	palette.offset_top = -palette_height
	palette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	palette.add_child(row)
	for id in BUILDING_NAMES:
		var chip := Button.new()
		chip.text = "%s" % BUILDING_NAMES[id]
		chip.custom_minimum_size = Vector2(110, 60)
		chip.mouse_filter = Control.MOUSE_FILTER_STOP
		# Tint chip text with the building color so the palette reads at a glance.
		chip.add_theme_color_override("font_color", BUILDING_COLORS[id])
		# Press-and-hold begins a drag from the palette.
		chip.button_down.connect(_on_palette_chip_down.bind(id))
		row.add_child(chip)
	canvas.add_child(palette)


func _on_palette_chip_down(building_id: int) -> void:
	_dragging_building = building_id
	var mouse := get_viewport().get_mouse_position()
	_drag_pos = mouse
	_drag_hot_cell = _cell_at(mouse)
	queue_redraw()


## Remove the building on this hex.
func remove_building() -> void:
	if _building >= 0:
		_building = -1
		queue_redraw()


# ---- input: drag from palette onto a sub-hex ---------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _dragging_building < 0:
		# Tap on the hex (it has a building) removes it (nice-to-have undo).
		if event is InputEventScreenTouch and not event.pressed:
			var cell := _cell_at(event.position)
			if _cells.has(cell) and _building >= 0:
				_building = -1
				queue_redraw()
		elif event is InputEventMouseButton and not event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			var cell := _cell_at(event.position)
			if _cells.has(cell) and _building >= 0:
				_building = -1
				queue_redraw()
		return

	# --- dragging a building from the palette ---
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		if event.pressed:
			return  # drag already started via button_down
		# Release: drop onto the hot cell (if any) and notify.
		var cell := _cell_at(event.position)
		_drop_building(cell)
	elif event is InputEventScreenDrag or event is InputEventMouseMotion:
		if _dragging_building >= 0:
			var pos: Vector2 = event.position
			_drag_pos = pos
			var new_hot := _cell_at(pos)
			if new_hot != _drag_hot_cell:
				_drag_hot_cell = new_hot
			queue_redraw()


func _drop_building(cell: Vector2i) -> void:
	var id := _dragging_building
	_dragging_building = -1
	_drag_hot_cell = Vector2i(9999, 9999)
	# Whole-hex placement: any drop inside the grid claims the ENTIRE hex.
	if _cells.has(cell):
		_building = id
		building_placed.emit(id)
	queue_redraw()
