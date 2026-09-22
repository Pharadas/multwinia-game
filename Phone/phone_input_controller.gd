class_name PhoneInputController
extends Node

## Turns raw touch/mouse input on the 2D hex map into high-level game
## intents. Drawing a path is the DEFAULT tool - there is no mode button:
##
##   press + move + release          -> path_drawn (simplified points + charge)
##   press + release without moving  -> cell_tapped (hex selection)
##   press while carrying a building -> building_dropped / carry cancelled
##   double-tap a hex, hold, drag & release on an option
##                                   -> building_selected (radial build menu)
##   hold the start hex (0.7 s)      -> building_remove_requested (barracks only)
##   hold the start hex otherwise    -> charge grows (see below)
##
## CHARGE MECHANIC (path strength): charge grows ONLY while the finger
## holds the hex the gesture started on - CHARGE_FULL_TIME of holding that
## hex = 100% of its dots. The instant the finger LEAVES the hex the charge
## freezes at its current value and the gesture becomes pure path drawing;
## the frozen fraction rides along when the path is sent on release.
##
## BUILD MENU GESTURE: a second tap on the same hex within
## DOUBLE_TAP_WINDOW arms the menu; holding that press still for
## BUILD_MENU_TIME emits build_menu_opened (the in-progress stroke is
## discarded). A quick double-tap never opens anything - the second tap
## still fires cell_tapped, which is what the wall-demolition X uses.
## While the menu is open the finger drags to one of the radial options
## (rendered by the facade's BuildRadialMenu) and releasing on one emits
## building_selected; releasing off-menu cancels. While the menu is open
## no strokes are started and no taps fire.
##
## Removal vs menu: both begin as "hold still on a hex", so the controller
## asks the facade (can_remove_at callback) whether the held hex contains
## a demolishable building. Barrack hexes are removal gestures (0.7 s, as
## before) and never open the menu; every other hex opens the menu after a
## double-tap + hold and never demolishes.
##
## The controller owns the interaction state machine and nothing else: it
## never touches sockets, data or rendering directly - it emits intents and
## the facade decides what they mean. Mouse input is polled in _process
## (mouse motion does not arrive as drag events); touch arrives via events.

signal path_drawn(points: PackedVector2Array, charge: float)
signal cell_tapped(cell: Vector2i)
signal building_dropped(cell: Vector2i, building_id: int)
signal building_remove_requested(cell: Vector2i)
## Double-tap + hold on a hex: open the radial build menu anchored there.
signal build_menu_opened(cell: Vector2i, screen_pos: Vector2)
## Release on a menu option (drag-to-select); -1 would never be emitted -
## off-menu releases just close the menu.
signal building_selected(cell: Vector2i, building_id: int)
## The open menu was cancelled (released off-menu or another gesture began).
signal build_menu_closed
## Charge mechanic: (fraction 0..1, seconds held so far) roughly every
## frame while a stroke is charging; the final fraction ships with
## path_drawn on release.
signal charge_progressed(fraction: float, seconds_held: float)
signal carry_preview_requested(local_pos: Vector2)
## Emitted with the Vector2i cell under the pointer whenever it changes
## (null = outside the grid) - the facade broadcasts this as hover.
signal pointer_cell_changed(cell)  # Vector2i or null

## Pointer moved (drag) while the build menu is open - the facade feeds
## this to the radial menu for drag-to-select highlighting.
signal build_menu_pointer_moved(screen_pos: Vector2)

const STROKE_SAMPLE_SPACING := 5.0
const STROKE_MIN_POINTS := 2
const HOLD_REMOVE_TIME := 0.7
## Seconds of accumulated pointer-down time on the start hex for a
## FULL-strength (100%) order.
const CHARGE_FULL_TIME := 1.75
## Meter grace period: a quick tap must not flash the charge ring.
const CHARGE_METER_DELAY := 0.15
## Hold duration (after the second tap of a double-tap) that opens the
## radial build menu.
const BUILD_MENU_TIME := 0.45
## Max seconds between the two taps of a double-tap, on the same hex.
const DOUBLE_TAP_WINDOW := 0.35

## Cell under the pointer right now - assigned by the owner via
## set_screen_to_cell() so the controller stays free of node references.
var screen_to_cell: Callable = Callable()

## Owner policy callback: "does this hex hold a demolishable building?"
## (Vector2i -> bool). Bind via bind_can_remove(). Barrack hexes become
## removal gestures; all other hexes charge. Unbound = nothing ever
## demolishes and every hold charges.
var can_remove_at: Callable = Callable()

# --- runtime state ------------------------------------------------------
enum Mode { IDLE, STROKING, CARRYING }

var _mode: int = Mode.IDLE
var _carry_building_id: int = -1
# Charge mechanic: accumulates ONLY while the pointer is held on the start
# hex; ships with path_drawn on release (each gesture charges from zero).
var _charge_seconds: float = 0.0
var _stroke_points := PackedVector2Array()
var _stroke_line: Line2D = null
var _stroke_layer: Node2D = null

# long-press removal tracking (touch only). After a removal fires, the
# press continues; release must NOT turn into a tap/select.
var _press_started_at: float = 0.0
var _press_start_cell := Vector2i(-1, -1)
var _press_remove_fired: bool = false
var _suppress_next_tap := false

# --- build menu (double-tap + hold) ------------------------------------------
# True when the CURRENT press started within DOUBLE_TAP_WINDOW of a tap on
# the same hex (the armed cell). Holding that press still for
# BUILD_MENU_TIME opens the menu; the menu swallows the gesture.
var _menu_pending := false
# True once build_menu_opened has fired for the current press.
var _menu_open := false
# The hex the open/pending menu was anchored on.
var _menu_cell := Vector2i(-1, -1)

# This gesture's classification, decided once at press start:
# true = removal gesture (held hex is a demolish target, never a menu).
var _is_removal_gesture := false
# Resolved at press start; true when the finger is still on _press_start_cell.
var _holding_start_hex := true

# Double-tap arming: the cell and deadline of a recent tap that may be the
# first tap of a double-tap.
var _tap_arm_cell := Vector2i(-1, -1)
var _tap_arm_until := 0.0
# Wall-clock press start (drives long-press and menu timing).
var _press_time := 0.0

# true while a real finger (not an emulated mouse event) is down
var _touch_active := false
var _touch_position := Vector2.ZERO


func _ready() -> void:
	set_process_unhandled_input(true)


## The Node2D strokes' preview lines are added to (so they inherit the
## grid's transform). Call once after the owner resolves its layer.
func bind_stroke_layer(layer: Node2D) -> void:
	_stroke_layer = layer


## Owner provides "Vector2i cell under this screen position". Used by
## taps, long-press and hover broadcasting.
func bind_screen_to_cell(lookup: Callable) -> void:
	screen_to_cell = lookup


## Owner provides "is this hex a demolish target?" - splits hold-still
## into barrack-removal (true) vs build menu (false). See the header.
func bind_can_remove(lookup: Callable) -> void:
	can_remove_at = lookup


## Owner provides "int building id under this screen point while the radial
## menu is open" (Vector2 -> int, -1 = none). Bind via bind_menu_lookup().
var menu_option_at: Callable = Callable()

func bind_menu_lookup(lookup: Callable) -> void:
	menu_option_at = lookup


func current_cell() -> Vector2i:
	if not screen_to_cell.is_valid():
		return Vector2i(-1, -1)
	var screen_pos := _touch_position if _touch_active else get_viewport().get_mouse_position()
	return screen_to_cell.call(screen_pos)


## True when the pointer is currently holding a building from the palette.
func is_carrying() -> bool:
	return _mode == Mode.CARRYING


func carried_building() -> int:
	return _carry_building_id


# --- palette (carrying) ---------------------------------------------------

## Press on a palette chip: pick the building up. `screen_pos` feeds the
## first preview; chips bind only the id.
func pick_up_building(building_id: int, screen_pos: Vector2, to_local: Callable) -> void:
	_mode = Mode.CARRYING
	_carry_building_id = building_id
	_update_carry_preview(to_local.call(screen_pos))


func _update_carry_preview(local_pos: Vector2) -> void:
	carry_preview_requested.emit(local_pos)


func cancel_carry() -> void:
	_mode = Mode.IDLE
	_carry_building_id = -1


# --- strokes ---------------------------------------------------------------

func _begin_stroke(local_pos: Vector2) -> void:
	_mode = Mode.STROKING
	_charge_seconds = 0.0
	_stroke_points.clear()
	_stroke_points.append(local_pos)
	_ensure_stroke_line()
	_stroke_line.points = _stroke_points


func _extend_stroke(local_pos: Vector2) -> void:
	if _stroke_points.is_empty() \
			or _stroke_points[_stroke_points.size() - 1].distance_to(local_pos) > STROKE_SAMPLE_SPACING:
		_stroke_points.append(local_pos)
		_ensure_stroke_line()
		_stroke_line.points = _stroke_points


## Seals the stroke: a real stroke emits path_drawn with the charge
## fraction accumulated so far (the facade draws the permanent simplified
## line and sends the order); a tap emits cell_tapped. Either way the
## controller's preview line is discarded - it never owns permanent map
## geometry.
func _end_stroke() -> void:
	_mode = Mode.IDLE
	var points := _stroke_points.duplicate()
	var was_stroke := points.size() >= STROKE_MIN_POINTS
	_discard_stroke()
	if _suppress_next_tap:
		# This press already fired a long-press removal - not a tap.
		_suppress_next_tap = false
	elif was_stroke:
		path_drawn.emit(points, clampf(_charge_seconds / CHARGE_FULL_TIME, 0.0, 1.0))
	else:
		var cell := current_cell()
		if cell.x >= 0:
			cell_tapped.emit(cell)
			# Double-tap arming: a tap on the same hex within the window arms
			# the build menu; the NEXT press's hold opens it. The arm cell
			# STAYS set - the press-matching check compares against it and its
			# deadline, so nothing here may clear it. Tapping a different hex
			# (or after the window) restarts arming from there.
			var now := Time.get_ticks_msec() / 1000.0
			if not (cell == _tap_arm_cell and now <= _tap_arm_until):
				_tap_arm_cell = cell
			_tap_arm_until = now + DOUBLE_TAP_WINDOW


## Abandons the in-progress stroke and removes its preview line.
func _discard_stroke() -> void:
	if _stroke_line:
		_stroke_line.queue_free()
		_stroke_line = null
	_stroke_points.clear()


## Resolves the build menu on release: releasing on an option emits
## building_selected (the facade puts that building in hand); anything
## else just closes. Also cleans up a pending menu that never opened.
func _end_menu() -> void:
	var was_open := _menu_open
	_menu_open = false
	_menu_pending = false
	_mode = Mode.IDLE
	build_menu_closed.emit()
	if was_open and menu_option_at.is_valid():
		var opt := int(menu_option_at.call(last_screen_position()))
		if opt >= 0:
			building_selected.emit(_menu_cell, opt)


func _ensure_stroke_line() -> void:
	if _stroke_line:
		return
	_stroke_line = Line2D.new()
	_stroke_line.width = 8.0
	_stroke_line.default_color = Color(1.0, 0.3, 0.3, 0.9)
	_stroke_line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_stroke_line.end_cap_mode = Line2D.LINE_CAP_ROUND
	_stroke_layer.add_child(_stroke_line)


# --- event handling ---------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.index != 0:
			return
		_touch_position = event.position
		_touch_active = true
		if event.pressed:
			_press_started_at = Time.get_ticks_msec() / 1000.0
			_press_time = _press_started_at
			_press_start_cell = current_cell()
			_press_remove_fired = false
			_is_removal_gesture = _is_removal_target(_press_start_cell)
			_holding_start_hex = true
			# Double-tap armed? A press on the armed cell within the window
			# becomes a menu press (hold still to open). Menu presses never
			# start a stroke or a removal.
			_menu_pending = not _is_removal_gesture \
					and _press_start_cell == _tap_arm_cell \
					and _press_time <= _tap_arm_until
			if _menu_pending:
				_menu_cell = _press_start_cell
				_tap_arm_cell = Vector2i(-1, -1)
				_tap_arm_until = 0.0
				return
			if _mode != Mode.CARRYING:
				_begin_stroke(_to_local(event.position))
		else:
			if _menu_open:
				_end_menu()
				_press_start_cell = Vector2i(-1, -1)
				_touch_active = false
				return
			if _menu_pending:
				# Released before the menu opened (quick double-tap): treat as
				# a normal tap so cell_tapped (wall-demolition X) still fires.
				_menu_pending = false
			if _mode == Mode.CARRYING:
				building_dropped.emit(current_cell(), _carry_building_id)
				cancel_carry()
			else:
				_end_stroke()
			# Release-branch cleanup only - a press must keep its own state.
			_press_start_cell = Vector2i(-1, -1)
			_touch_active = false
		return

	if event is InputEventScreenDrag:
		if event.index != 0:
			return
		_touch_position = event.position
		if _menu_open:
			build_menu_pointer_moved.emit(event.position)
			return
		if _menu_pending:
			# Sliding off the start hex before the menu opens cancels it.
			_holding_start_hex = current_cell() == _press_start_cell
			if not _holding_start_hex:
				_menu_pending = false
			return
		if _mode == Mode.CARRYING:
			_update_carry_preview(_to_local(event.position))
		else:
			_extend_stroke(_to_local(event.position))
			_holding_start_hex = current_cell() == _press_start_cell
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if _touch_active:
			return  # real touch already handled this press
		if event.pressed:
			_press_started_at = Time.get_ticks_msec() / 1000.0
			_press_time = _press_started_at
			_press_start_cell = current_cell()
			_press_remove_fired = false
			_is_removal_gesture = _is_removal_target(_press_start_cell)
			_holding_start_hex = true
			_menu_pending = not _is_removal_gesture \
					and _press_start_cell == _tap_arm_cell \
					and _press_time <= _tap_arm_until
			if _menu_pending:
				_menu_cell = _press_start_cell
				_tap_arm_cell = Vector2i(-1, -1)
				_tap_arm_until = 0.0
				return
			if _mode != Mode.CARRYING:
				_begin_stroke(_to_local(get_viewport().get_mouse_position()))
	else:
		_press_start_cell = Vector2i(-1, -1)
		if _menu_open:
			_end_menu()
			return
		if _menu_pending:
			# Quick double-tap: not a menu - a normal tap (see touch branch).
			_menu_pending = false
		if _mode == Mode.CARRYING:
			building_dropped.emit(current_cell(), _carry_building_id)
			cancel_carry()
		else:
			_end_stroke()


## Mouse strokes: mouse motion is not a drag event, so poll the button.
func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var mouse_held := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not _touch_active
	var holding := _mode == Mode.STROKING and (_touch_active or mouse_held)
	var held_for := now - _press_started_at

	# Open the build menu: double-tap-armed press held still on its hex for
	# BUILD_MENU_TIME (barrack hexes are removal gestures instead).
	if not _menu_open and _menu_pending and not _is_removal_gesture \
			and _holding_start_hex and held_for >= BUILD_MENU_TIME:
		_menu_pending = false
		_menu_open = true
		_discard_stroke()
		_mode = Mode.IDLE
		build_menu_opened.emit(_menu_cell, last_screen_position())

	# While the menu is open everything else is suspended; the facade feeds
	# update_pointer() and the release path closes/commits the menu.
	if _menu_open:
		return

	# Mouse strokes: motion events don't arrive as drags (and can be eaten
	# by hovered Controls), so extend the stroke from the polled position
	# instead. _extend_stroke's spacing check makes this cheap when still.
	if mouse_held and _mode == Mode.STROKING:
		_extend_stroke(_to_local(get_viewport().get_mouse_position()))

	# Is the finger still on the hex the gesture started on? Polled here so
	# mouse motion (no drag events) and touch drags both stay current.
	if holding:
		_holding_start_hex = current_cell() == _press_start_cell

	# Long-press removal: ONLY on gestures that started on a demolishable
	# hex (barrack), ONLY while the finger still holds that hex, after
	# HOLD_REMOVE_TIME. Build-menu gestures (any other hex) never demolish.
	if holding and _is_removal_gesture and not _press_remove_fired \
			and _press_start_cell.x >= 0 and _holding_start_hex \
			and held_for >= HOLD_REMOVE_TIME:
		_press_remove_fired = true
		_suppress_next_tap = true
		_discard_stroke()
		building_remove_requested.emit(_press_start_cell)

	# Charge mechanic: grows ONLY while the finger holds the START hex of
	# the gesture (0..1 over CHARGE_FULL_TIME). The moment it leaves, the
	# charge freezes and the gesture is pure path drawing; the frozen
	# fraction ships with path_drawn on release.
	if holding and not _is_removal_gesture and _holding_start_hex \
			and held_for >= CHARGE_METER_DELAY:
		_charge_seconds += delta
		charge_progressed.emit(
				clampf(_charge_seconds / CHARGE_FULL_TIME, 0.0, 1.0), _charge_seconds)

	# Hover broadcast: emit whenever the cell under the pointer changes.
	if screen_to_cell.is_valid():
		var cell := current_cell()
		if cell != _last_hover_cell:
			_last_hover_cell = cell
			pointer_cell_changed.emit(cell if cell.x >= 0 else null)

var _last_hover_cell = null


## Asks the facade whether this hex is a demolish target (removal gesture)
## - unbound callback means never.
func _is_removal_target(cell: Vector2i) -> bool:
	return can_remove_at.is_valid() and cell.x >= 0 \
			and bool(can_remove_at.call(cell))


func _to_local(screen_pos: Vector2) -> Vector2:
	return _stroke_layer.to_local(screen_pos) if _stroke_layer else screen_pos


## Screen-space pointer position (for the facade's charge meter placement).
func last_screen_position() -> Vector2:
	return _touch_position if _touch_active else get_viewport().get_mouse_position()
