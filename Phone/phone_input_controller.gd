class_name PhoneInputController
extends Node

## Turns raw touch/mouse input on the 2D hex map into high-level game
## intents. Drawing a path is the DEFAULT tool - there is no mode button:
##
##   press + move + release          -> path_drawn (simplified points)
##   press + release without moving  -> cell_tapped (hex selection)
##   press while carrying a building -> building_dropped / carry cancelled
##   hold the start hex (0.7 s)      -> building_remove_requested (barracks only)
##   hold the start hex otherwise    -> charge grows (see below)
##
## CHARGE MECHANIC (path strength): charge grows ONLY while the finger
## holds the hex the gesture started on - CHARGE_FULL_TIME (3 s) of holding
## that hex = 100% of its dots. The instant the finger LEAVES the hex the
## charge freezes at its current value and the gesture becomes pure path
## drawing; the frozen fraction rides along when the path is sent on
## release (one gesture = one order; a new press starts from 0%).
##
## Removal vs charge: both begin as "hold still on a hex", so the
## controller asks the facade (can_remove_at callback) whether the held hex
## contains a demolishable building. Barrack hexes are removal gestures
## (0.7 s, as before) and never charge; every other hex charges and never
## demolishes.
##
## The controller owns the interaction state machine and nothing else: it
## never touches sockets, data or rendering directly - it emits intents and
## the facade decides what they mean. Mouse input is polled in _process
## (mouse motion does not arrive as drag events); touch arrives via events.

signal path_drawn(points: PackedVector2Array, charge: float)
signal cell_tapped(cell: Vector2i)
signal building_dropped(cell: Vector2i, building_id: int)
signal building_remove_requested(cell: Vector2i)
signal carry_preview_requested(local_pos: Vector2)
## Emitted with the Vector2i cell under the pointer whenever it changes
## (null = outside the grid) - the facade broadcasts this as hover.
signal pointer_cell_changed(cell)  # Vector2i or null

## Charge mechanic: (fraction 0..1, seconds held so far) roughly every
## frame while a stroke is charging; then path_drawn carries the final
## fraction on release. Emitted ONLY after something has actually been
## drawn (never for plain taps).
signal charge_progressed(fraction: float, seconds_held: float)

const STROKE_SAMPLE_SPACING := 5.0
const STROKE_MIN_POINTS := 2
const HOLD_REMOVE_TIME := 0.7
## Seconds of accumulated pointer-down time for a FULL-strength (100%)
## order. Hold shorter for fewer followers.
const CHARGE_FULL_TIME := 3.0
## Meter grace period: a quick tap must not flash the charge ring.
const CHARGE_METER_DELAY := 0.15

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
var _stroke_points := PackedVector2Array()
var _stroke_line: Line2D = null
var _stroke_layer: Node2D = null

# long-press removal tracking (touch only). After a removal fires, the
# press continues; release must NOT turn into a tap/select.
var _press_started_at: float = 0.0
var _press_start_cell := Vector2i(-1, -1)
var _press_remove_fired: bool = false
var _suppress_next_tap := false

# --- charge mechanic (path strength via hold time) ---------------------------
# _charge_seconds accumulates ONLY while the pointer is held after something
# has been drawn (not during an initial tap-hold); lifting mid-gesture keeps
# the total, pressing again resumes. Released to the facade with path_drawn.
var _charge_seconds: float = 0.0
# This gesture's classification, decided once at press start:
# true = removal gesture (held hex is a demolish target, never charges),
# false = charge gesture (charges while the finger holds the start hex).
var _is_removal_gesture := false
# Resolved at press start; true when the finger is still on _press_start_cell.
var _holding_start_hex := true

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
## into barrack-removal (true) vs charge (false). See the header.
func bind_can_remove(lookup: Callable) -> void:
	can_remove_at = lookup


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
	_stroke_points.clear()
	_stroke_points.append(local_pos)
	_ensure_stroke_line()
	_stroke_line.points = _stroke_points
	# Each gesture charges from zero: the order is sent on release with
	# THIS gesture's accumulated hold time.
	_charge_seconds = 0.0


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


## Abandons the in-progress stroke and removes its preview line.
func _discard_stroke() -> void:
	if _stroke_line:
		_stroke_line.queue_free()
		_stroke_line = null
	_stroke_points.clear()


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
			_press_start_cell = current_cell()
			_press_remove_fired = false
			_is_removal_gesture = _is_removal_target(_press_start_cell)
			_holding_start_hex = true
			if _mode != Mode.CARRYING:
				_begin_stroke(_to_local(event.position))
		else:
			if _mode == Mode.CARRYING:
				building_dropped.emit(current_cell(), _carry_building_id)
				cancel_carry()
			else:
				_end_stroke()
		_press_start_cell = Vector2i(-1, -1)
		_touch_active = false
		return

	if event is InputEventScreenDrag:
		if event.index != 0:
			return
		_touch_position = event.position
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
			_press_start_cell = current_cell()
			_press_remove_fired = false
			_is_removal_gesture = _is_removal_target(_press_start_cell)
			_holding_start_hex = true
			if _mode != Mode.CARRYING:
				_begin_stroke(_to_local(get_viewport().get_mouse_position()))
		else:
			_press_start_cell = Vector2i(-1, -1)
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
	# HOLD_REMOVE_TIME. Charge gestures (any other hex) never demolish.
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
