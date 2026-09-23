extends Node2D

## HexGrid2D - the phone's 2D mirror of the 3D hex terrain.
##
## This is now a thin FACADE (~250 lines): it wires together small
## single-responsibility components and owns only the application policies
## (what a tap means, which drops are valid, what gets sent where).
##
##   HexMapState            plain data: colors / counts / walls / buildings
##   MapPopulator           paints the TileMapLayer, fits the grid to screen
##   CountLabelLayer        pooled per-hex darwinian count labels
##   BuildingMarkerLayer    hex markers for placed buildings
##   BuildPreviewView       carry highlight (white ok / red rejected)
##   BuildingPalette        resource counter + building chips (CanvasLayer)
##   BuildRadialMenu        screen-space radial options (double-tap + hold)
##   PhoneInputController   touch/mouse -> path / tap / drop / remove intents
##   FrontierRing           outermost surviving hex ring where mines go
##
## All network I/O lives in the sibling socket (HexGrid2DSocket); this
## node talks to it through duck-typed send_* calls so same-process
## testing without a socket keeps working.

const DRAW_SAMPLE_COUNT := 16
const PATH_LINE_COLOR := Color(1.0, 0.3, 0.3, 0.6)
## Preloaded so the facade never depends on the global class cache having
## scanned connect_screen.gd (fresh files aren't in it until a rescan).
const ConnectScreenScript := preload("res://Phone/connect_screen.gd")
## Same reason as ConnectScreenScript: a brand-new class file isn't in the
## global class cache until the next scan, so preload it by path.
const SpawnPickLayerScript := preload("res://Phone/spawn_pick_layer.gd")

@export var terrain_path: NodePath
@export var socket_path: NodePath
@export var tile_map_layer: TileMapLayer
## Only used if terrain_path is empty (nothing to auto-read grid size from).
@export var grid_width: int = 20
@export var grid_depth: int = 20
## Name of the method to call on the 3D HexTile when its cell is tapped -
## same-process terrain_path fallback only (the socket path forwards the
## tap itself).
@export var click_method_name: String = "on_tile_selected"

@export_group("Darwinian Counts")
## Dictionary key expected on each entry passed to populate_from_data().
@export var darwinian_count_key: String = "darwinians"
@export var show_darwinian_counts: bool = true
@export var darwinian_count_property_name: String = "darwinian_count"

# --- components -----------------------------------------------------------
var state := HexMapState.new()
var frontier := FrontierRing.new()
var populator: MapPopulator
var input: PhoneInputController
var palette: BuildingPalette
var spawn_marks: Node2D
var radial_menu: BuildRadialMenu
var charge_meter: ChargeMeterView
var connect_screen
var build_preview: BuildPreviewView
var markers: BuildingMarkerLayer
var count_labels: CountLabelLayer

# --- session ---------------------------------------------------------------
var team_number: int = 0
## This team's color, as sent by the main screen when it assigned the team
## (see the socket's team_assigned). Drives the HUD's team badge, so the
## player can tell which army they command at a glance.
var team_color := Color(0.75, 0.75, 0.78)
var grid_alive := false  # a terrain has been populated at least once

# --- lobby spawn picking ---------------------------------------------------
## True until the main screen starts the match (see lobby_state_received).
## While it is true, tapping a hex picks where the army starts instead of
## the normal tile click, and the HUD shows the picker banner.
var in_lobby := false
## The hexes this player picked, in pick order - the army is divided between
## them in that order (the first pick takes the largest share).
var spawn_picks: Array = []
const MAX_SPAWN_PICKS := 3

var _terrain: Node = null
var _sent_paths: Array[Line2D] = []


func _ready() -> void:
	_resolve_terrain()
	_build_components()
	_connect_input()
	_connect_socket()
	# (The populator re-fits the grid on every viewport resize itself.)


# --- component assembly ------------------------------------------------------

func _build_components() -> void:
	populator = MapPopulator.new()
	populator.tile_map_layer = tile_map_layer
	add_child(populator)

	input = PhoneInputController.new()
	input.bind_stroke_layer(tile_map_layer)
	input.bind_screen_to_cell(_screen_to_cell)
	# Hold-still gesture split: barrack hexes become removal gestures,
	# every other hex charges the order (see PhoneInputController header).
	input.bind_can_remove(_can_remove_at)
	add_child(input)

	palette = BuildingPalette.new()
	add_child(palette)

	# Radial build menu (screen space); hidden until double-tap + hold.
	radial_menu = BuildRadialMenu.new()
	add_child(radial_menu)

	# Hold-to-charge ring (screen space); hidden until a gesture charges.
	charge_meter = ChargeMeterView.new()
	add_child(charge_meter)

	# Manual-connect overlay (web builds): shown while the socket is down,
	# lets the player type the host's public IP to connect from anywhere.
	connect_screen = ConnectScreenScript.new()
	add_child(connect_screen)

	# Everything drawn in grid space is a child of the TileMapLayer so it
	# inherits the fit-to-screen transform.
	build_preview = BuildPreviewView.new()
	build_preview.hide_preview()
	tile_map_layer.add_child(build_preview)

	markers = BuildingMarkerLayer.new()
	markers.buildings = state.buildings
	markers.delete_marked = state.delete_marked
	tile_map_layer.add_child(markers)

	# Spawn picks (lobby only) live above the tile map like the markers do,
	# so they inherit the grid transform and follow every resize.
	spawn_marks = SpawnPickLayerScript.new()
	spawn_marks.color = team_color
	tile_map_layer.add_child(spawn_marks)

	count_labels = CountLabelLayer.new()
	count_labels.set_enabled(show_darwinian_counts)
	tile_map_layer.add_child(count_labels)


func _connect_input() -> void:
	palette.building_picked.connect(_on_building_picked)
	input.path_drawn.connect(_on_path_drawn)
	input.cell_tapped.connect(_on_cell_tapped)
	input.building_dropped.connect(_on_building_dropped)
	input.building_remove_requested.connect(_on_building_remove_requested)
	input.carry_preview_requested.connect(_on_carry_preview)
	input.pointer_cell_changed.connect(_on_pointer_cell_changed)
	input.build_menu_opened.connect(_on_build_menu_opened)
	input.build_menu_pointer_moved.connect(_on_build_menu_pointer_moved)
	input.build_menu_closed.connect(_on_build_menu_closed)
	input.building_selected.connect(_on_building_selected)
	input.charge_progressed.connect(_on_charge_progressed)
	# Drag-to-select lookup: the controller asks the menu which option the
	# finger is on when the gesture releases.
	input.bind_menu_lookup(radial_menu.option_at)


func _connect_socket() -> void:
	var socket := _get_socket_node()
	if socket and socket.has_signal("team_resources_received"):
		socket.team_resources_received.connect(_on_team_resources_received)
	if socket and socket.has_signal("team_assigned"):
		socket.team_assigned.connect(_on_team_assigned)
	if socket and socket.has_signal("lobby_state_received"):
		socket.lobby_state_received.connect(_on_lobby_state_received)
	# The manual-connect screen is a WEB-only fallback: native phones find the
	# server themselves over UDP LAN discovery, and is_web_connected() is
	# always false off the web, so showing it there would cover the map
	# permanently with no way to dismiss it.
	if not OS.has_feature("web"):
		if connect_screen:
			connect_screen.visible = false
		return
	if socket and socket.has_signal("connection_state_changed"):
		socket.connection_state_changed.connect(_on_connection_state_changed)
		# Initial state: a web page always starts disconnected, so show it.
		_on_connection_state_changed(
				socket.is_web_connected() if socket.has_method("is_web_connected") else false)
	if socket and connect_screen and not connect_screen.connect_requested.is_connected(_on_connect_requested):
		connect_screen.connect_requested.connect(_on_connect_requested)

## Typed address from the connect screen -> socket override + reconnect.
func _on_connect_requested(target: String) -> void:
	var socket := _get_socket_node()
	if socket and socket.has_method("set_remote_target"):
		socket.set_remote_target(target)

## Web only: show the overlay while the WebSocket is down, and say what is
## being dialed (or that nothing is dialable yet, which is the normal state
## of a page hosted on an HTTPS CDN until the player types an address).
func _on_connection_state_changed(connected: bool) -> void:
	if connect_screen == null or not OS.has_feature("web"):
		return
	connect_screen.set_connection_state(connected)
	if connected:
		return
	var socket := _get_socket_node()
	var url := (str(socket.get_current_ws_url())
			if socket and socket.has_method("get_current_ws_url") else "")
	if url.is_empty():
		connect_screen.set_status("Enter the game host's address to connect.")
	else:
		connect_screen.set_status("trying %s ..." % url)


# --- terrain / network data ---------------------------------------------------

func _resolve_terrain() -> void:
	if terrain_path == NodePath():
		return
	_terrain = get_node_or_null(terrain_path)
	if _terrain == null:
		return
	grid_width = _terrain.grid_width
	grid_depth = _terrain.grid_depth
	# Same-process fallback only; over the network the socket pushes
	# populate_from_data() instead.
	if _terrain.has_signal("terrain_ready"):
		_terrain.terrain_ready.connect(_on_terrain_ready)


func _on_terrain_ready() -> void:
	populate()


## Rebuilds the grid straight from network data - an Array of
## {col, row, color, is_wall, <darwinian_count_key>} dicts, exactly what
## HexTerrainSocket sends. The primary path once the 3D instance runs
## separately.
func populate_from_data(tiles: Array) -> void:
	state.clear_tiles()
	var max_col := 0
	var max_row := 0
	for entry in tiles:
		var cell := Vector2i(int(entry.col), int(entry.row))
		state.set_tile(cell, entry.color, entry.get(darwinian_count_key, 0), entry.get("is_wall", false))
		max_col = maxi(max_col, int(entry.col))
		max_row = maxi(max_row, int(entry.row))
	if not tiles.is_empty():
		grid_width = max_col + 1
		grid_depth = max_row + 1
	populate()


## Repaints the whole grid from state (startup + every fresh terrain).
func populate() -> void:
	if tile_map_layer == null:
		return
	_pull_terrain_data()
	count_labels.clear_all()
	for cell in tile_map_layer.get_used_cells():
		tile_map_layer.erase_cell(cell)
	populator.populate(grid_width, grid_depth, state)
	for cell in state.counts.keys():
		_update_count_label(cell)
	frontier.rebuild(grid_width, grid_depth, populator.cell_alive)
	grid_alive = true


## Same-process fallback: fill any missing state from the 3D HexTile nodes
## directly (colors, counts, walls). Network data always wins - this only
## fills cells the socket hasn't provided.
func _pull_terrain_data() -> void:
	if _terrain == null or not _terrain.has_method("get_hex_node"):
		return
	for x in range(grid_width):
		for y in range(grid_depth):
			var cell := Vector2i(x, y)
			var tile: Node = _terrain.get_hex_node(x, y)
			if tile == null:
				continue
			if not state.colors.has(cell) and "color" in tile:
				state.colors[cell] = tile.color
			if not state.counts.has(cell) and darwinian_count_property_name in tile:
				state.counts[cell] = tile.get(darwinian_count_property_name)
			if not state.walls.has(cell) and "is_wall" in tile:
				state.walls[cell] = tile.is_wall


# --- input intents ------------------------------------------------------------

func _on_path_drawn(points: PackedVector2Array, charge: float) -> void:
	var simplified := _simplify_path(points, DRAW_SAMPLE_COUNT)
	_seal_path_line(simplified)
	_send_drawn_path(simplified, charge)
	charge_meter.hide_meter()


## Hold-to-charge feedback: the charge grows while the finger holds the
## hex the gesture started on (CHARGE_FULL_TIME = 100%); leaving the hex
## freezes it. The meter offsets itself up-right of the pointer (see
## ChargeMeterView) so it never covers the hex being charged.
func _on_charge_progressed(fraction: float, _seconds_held: float) -> void:
	charge_meter.show_at(input.last_screen_position())
	charge_meter.set_fraction(fraction)


## Build menu lifecycle: opens on double-tap + hold, highlights the option
## under the dragging finger, and puts the chosen building in hand on
## release (the next press becomes a carry gesture - drag to the target hex
## and release to drop it there).
func _on_build_menu_opened(_cell: Vector2i, screen_pos: Vector2) -> void:
	charge_meter.hide_meter()
	radial_menu.open(screen_pos)


func _on_build_menu_pointer_moved(screen_pos: Vector2) -> void:
	radial_menu.update_pointer(screen_pos)


func _on_build_menu_closed() -> void:
	radial_menu.close()


func _on_building_selected(_cell: Vector2i, building_id: int) -> void:
	if tile_map_layer == null:
		return
	var screen_pos := input.last_screen_position()
	input.pick_up_building(building_id, screen_pos,
			func(pos: Vector2) -> Vector2: return tile_map_layer.to_local(pos))
	var cell := _screen_to_cell(screen_pos)
	build_preview.show_cell(cell, _drop_allowed(cell, building_id))


## Removal-gesture policy for the input controller: a hex is a demolish
## target only when it holds a BARRACK (mines die by collapse, walls are
## the map). Everything else becomes a charge gesture instead.
func _can_remove_at(cell: Vector2i) -> bool:
	return _cell_in_bounds(cell) and state.building_at(cell) == BuildingTypes.BARRACK


func _on_cell_tapped(cell: Vector2i) -> void:
	charge_meter.hide_meter()
	# Lobby: a tap picks a spawn hex for this army instead of selecting the
	# tile - the match hasn't started, so there is nothing to order yet.
	if in_lobby:
		toggle_spawn_pick(cell)
		return
	# A tap selects the hex: same-process tile call + network broadcast.
	# (A tap is also the first half of the double-tap that arms the build
	# menu - see PhoneInputController.)
	_call_tile_function(cell.x, cell.y)
	_send_click_over_network(cell)
	# Double-tap on a WALL marks it for demolition (an X appears); another
	# double-tap on the same wall unmarks it. Mines/barracks are untouched.
	var now := Time.get_ticks_msec() / 1000.0
	if cell == _last_tap_cell and now - _last_tap_time <= 0.4 \
			and state.is_wall_at(cell) and state.building_at(cell) == BuildingTypes.REMOVE:
		_toggle_wall_delete(cell)
	_last_tap_cell = cell
	_last_tap_time = now


# Double-tap tracking for wall-demolition marks.
var _last_tap_cell := Vector2i(-1, -1)
var _last_tap_time := 0.0


## Toggles the red X on a wall hex and tells the main screen. The dots do
## the actual tearing down - the X disappears when the wall falls.
func _toggle_wall_delete(cell: Vector2i) -> void:
	if state.delete_marked.has(cell):
		state.delete_marked.erase(cell)
	else:
		state.delete_marked[cell] = true
	markers.mark_changed()
	var socket := _get_socket_node()
	if socket and socket.has_method("send_building_delete"):
		socket.send_building_delete(cell.x, cell.y, team_number)


## A marked wall fell (the dots tore it down): drop the X and repaint.
func notify_wall_deleted(col: int, row: int) -> void:
	var cell := Vector2i(col, row)
	state.delete_marked.erase(cell)
	markers.mark_changed()


func _on_building_picked(building_id: int) -> void:
	if tile_map_layer == null:
		return
	input.pick_up_building(building_id, get_viewport().get_mouse_position(),
			func(screen_pos: Vector2) -> Vector2: return tile_map_layer.to_local(screen_pos))
	build_preview.show_cell(_screen_to_cell(get_viewport().get_mouse_position()), true)


func _on_carry_preview(local_pos: Vector2) -> void:
	if tile_map_layer == null:
		return
	var cell := tile_map_layer.local_to_map(local_pos)
	var valid: bool = _drop_allowed(cell, input.carried_building())
	build_preview.show_cell(cell, valid)


func _on_building_dropped(cell: Vector2i, building_id: int) -> void:
	build_preview.hide_preview()
	if _drop_allowed(cell, building_id):
		_place_building(cell, building_id)


func _on_building_remove_requested(cell: Vector2i) -> void:
	# Only barracks can be demolished: mines are the frontier economy (they
	# die by collapse), walls are the map itself.
	if state.building_at(cell) != BuildingTypes.BARRACK:
		return
	state.remove_building(cell)
	markers.mark_changed()
	var socket := _get_socket_node()
	if socket and socket.has_method("send_building_placed"):
		socket.send_building_placed(cell.x, cell.y, BuildingTypes.REMOVE, team_number)


func _drop_allowed(cell: Vector2i, building_id: int) -> bool:
	if not _cell_in_bounds(cell):
		return false
	# Mines are only allowed on the frontier ring - the map is mined
	# outside-in, and the main screen enforces the same rule server-side.
	if building_id == BuildingTypes.MINE:
		return frontier.contains(cell)
	return true


func _place_building(cell: Vector2i, building_id: int) -> void:
	state.place_building(cell, building_id)
	markers.mark_changed()
	var socket := _get_socket_node()
	if socket and socket.has_method("send_building_placed"):
		socket.send_building_placed(cell.x, cell.y, building_id, team_number)


# --- network push ---------------------------------------------------------------


## The main screen told us which team we command, and what color it is: show
## it on the HUD (the team badge) and keep the facade's copy in sync, since
## orders are tagged with it and the resource HUD filters broadcasts by it.
func _on_team_assigned(team: int, color: Color) -> void:
	team_number = team
	team_color = color
	if palette:
		palette.set_team(team, color)
	if spawn_marks:
		spawn_marks.color = color
		spawn_marks.mark_changed()


# --- lobby spawn picking ----------------------------------------------------


## The main screen's lobby state: whether the match has started, which hexes
## THIS phone has picked, and how many each team has picked. Until the match
## starts, taps choose spawn hexes (see _on_cell_tapped).
func _on_lobby_state_received(started: bool, hexes: Array, _picked: Array) -> void:
	in_lobby = not started
	spawn_picks = []
	if not started:
		for h in hexes:
			if h is Array and (h as Array).size() >= 2:
				spawn_picks.append(Vector2i(int(h[0]), int(h[1])))
	_apply_lobby_ui()


## Adds/removes one spawn hex and tells the main screen about the new set.
## Returns true when the picks actually changed. Refuses wall hexes (an army
## spawned inside a wall would be stuck) and a fourth pick, and picking a hex
## that is already chosen removes it.
func toggle_spawn_pick(cell: Vector2i) -> bool:
	if not in_lobby or state.is_wall_at(cell):
		return false
	if spawn_picks.has(cell):
		spawn_picks.erase(cell)
	elif spawn_picks.size() >= MAX_SPAWN_PICKS:
		return false
	else:
		spawn_picks.append(cell)
	_apply_lobby_ui()
	var socket := _get_socket_node()
	if socket and socket.has_method("send_spawn_hexes"):
		socket.send_spawn_hexes(spawn_picks, team_number)
	return true


func _apply_lobby_ui() -> void:
	if palette:
		palette.set_lobby_picking(in_lobby, spawn_picks.size(), MAX_SPAWN_PICKS)
	if spawn_marks:
		spawn_marks.picks = [] if not in_lobby else spawn_picks.duplicate()
		spawn_marks.color = team_color
		spawn_marks.mark_changed()


func _on_team_resources_received(team: int, amount: float) -> void:
	if team != team_number:
		return
	palette.set_team_resources(amount)


func _on_pointer_cell_changed(cell) -> void:
	_send_click_over_network(cell)


func _send_click_over_network(cell) -> void:
	if cell == null:
		return
	var socket := _get_socket_node()
	if socket and socket.has_method("send_tile_clicked"):
		socket.send_tile_clicked(cell.x, cell.y, team_number)


func _send_drawn_path(points: PackedVector2Array, fraction: float) -> void:
	if not grid_alive or tile_map_layer == null:
		return
	# Send raw tilemap-local positions plus reference cell mappings so the
	# server can compute the affine transform to world-space.
	var ref_cells: Array = [Vector2i(0, 0), Vector2i(2, 0), Vector2i(0, 2)]
	var ref_locals: Array = []
	for c in ref_cells:
		ref_locals.append(tile_map_layer.map_to_local(c))
	var socket := _get_socket_node()
	if socket and socket.has_method("send_drawn_path"):
		socket.send_drawn_path(points, team_number, ref_cells, ref_locals, fraction)


func _get_socket_node() -> Node:
	if socket_path != NodePath():
		var node := get_node_or_null(socket_path)
		if node:
			return node
	return get_node_or_null("Socket")


# --- count labels -----------------------------------------------------------

func _update_count_label(cell: Vector2i) -> void:
	count_labels.update_count(cell, state.count_at(cell))


func update_darwinian_count(col: int, row: int, count) -> void:
	var cell := Vector2i(col, row)
	state.counts[cell] = count
	count_labels.update_count(cell, count)


## Batch version of update_darwinian_count() - a count-only network message.
func update_darwinian_counts(entries: Array) -> void:
	for entry in entries:
		if not entry.has(darwinian_count_key):
			continue
		update_darwinian_count(int(entry.col), int(entry.row), entry[darwinian_count_key])


# --- hex destruction (mined-out frontier hexes) ---------------------------------

## A mine hex collapsed on the 3D side: forget the hex and advance the
## mining frontier one ring inward.
func notify_hex_destroyed(col: int, row: int) -> void:
	var cell := Vector2i(col, row)
	state.erase_cell(cell)
	count_labels.remove_label(cell)
	if populator.cell_alive(cell):
		tile_map_layer.erase_cell(cell)
		markers.mark_changed()
	frontier.rebuild(grid_width, grid_depth, populator.cell_alive)


# --- helpers -----------------------------------------------------------------------

func _screen_to_cell(screen_pos: Vector2) -> Vector2i:
	if tile_map_layer == null:
		return Vector2i(-1, -1)
	return tile_map_layer.local_to_map(tile_map_layer.to_local(screen_pos))


func _cell_in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < grid_width and cell.y >= 0 and cell.y < grid_depth


## Same-process fallback: call click_method_name on the 3D HexTile.
func _call_tile_function(col: int, row: int) -> void:
	if not _terrain or not _terrain.has_method("get_hex_node"):
		return
	var tile: Node = _terrain.get_hex_node(col, row)
	if tile and tile.has_method(click_method_name):
		tile.call(click_method_name)


## Seals a sent path as a permanent line on the map (grid-space Line2D).
func _seal_path_line(points: PackedVector2Array) -> void:
	var line := Line2D.new()
	line.width = 8.0
	line.default_color = PATH_LINE_COLOR
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	line.points = points
	tile_map_layer.add_child(line)
	_sent_paths.append(line)


## Uniformly samples `count` points along an arc-length parameterization
## of `points` - the 3D side follows exactly these points.
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
