extends SceneTree

## Headless gesture test for PhoneInputController.
##   godot --headless -s res://Tests/gesture_smoke.gd
## Feeds touch events through the REAL controller and asserts:
##   1. quick tap                -> cell_tapped
##   2. tap, tap, hold 0.6 s     -> build_menu_opened (double-tap + hold)
##   3. press + hold 2.0 s       -> charge_progressed + path_drawn(charge>0)
##   4. quick double-tap         -> two cell_tapped (wall-X path survives)
##   5. long hold on "removable" -> building_remove_requested

var ctl: Node
var stroke_layer: Node2D

# observed results (snapshotted per scenario)
var got_tap := 0
var got_menu_open := false
var got_charge := 0.0
var got_path_charge := -1.0
var got_remove := false
var removable := false

var steps: Array = []  # [{wait: ms, body: Callable}] (wall-clock waits)

func _initialize() -> void:
	stroke_layer = Node2D.new()
	root.add_child(stroke_layer)
	ctl = load("res://Phone/phone_input_controller.gd").new()
	root.add_child(ctl)
	ctl.bind_stroke_layer(stroke_layer)
	ctl.bind_screen_to_cell(func(pos: Vector2) -> Vector2i:
		# 40 px hexes: col = x/40, row = y/40 (cell 5,5 centered at 200..239)
		return Vector2i(int(pos.x / 40.0), int(pos.y / 40.0)))
	ctl.bind_can_remove(func(_c: Vector2i) -> bool: return removable)
	ctl.path_drawn.connect(func(_points: PackedVector2Array, charge: float) -> void:
		got_path_charge = charge)
	ctl.cell_tapped.connect(func(_c: Vector2i) -> void:
		got_tap += 1
		print("  [harness] frame=%d cell_tapped #%d" % [_frame, got_tap]))
	ctl.build_menu_opened.connect(func(_c: Vector2i, _p: Vector2) -> void:
		got_menu_open = true)
	ctl.charge_progressed.connect(func(f: float, _s: float) -> void:
		got_charge = maxf(got_charge, f))
	ctl.building_remove_requested.connect(func(_c: Vector2i) -> void: got_remove = true)

	ctl.set_meta("probe", 0)
	ctl.pointer_cell_changed.connect(func(c) -> void:
		ctl.set_meta("probe", int(ctl.get_meta("probe")) + 1))
	# --- scenario 1: quick tap -> cell_tapped ------------------------------
	seq([
		[30, func() -> void: _touch(Vector2(220, 220), true)],
		[80, func() -> void: _touch(Vector2(220, 220), false)],
		[50, func() -> void: _check("scenario1 tap", func() -> bool: return got_tap == 1)],
	])

	# --- scenario 2: double-tap + hold -> build menu ------------------------
	seq([
		[50, func() -> void: _touch(Vector2(300, 300), true)],
		[80, func() -> void: _touch(Vector2(300, 300), false)],
		[50, func() -> void: _touch(Vector2(300, 300), true)],
		[900, func() -> void: pass],  # hold 0.9 s > BUILD_MENU_TIME (0.45)
		[50, func() -> void: _check("scenario2 menu", func() -> bool: return got_menu_open)],
		[50, func() -> void: _touch(Vector2(300, 300), false)],
	])

	# --- scenario 3: press, hold 2 s, drag, release -> charged path ---------
	seq([
		[50, func() -> void:
			got_menu_open = false; got_charge = 0.0; got_path_charge = -1.0
			_touch(Vector2(100, 100), true)],
		[1900, func() -> void: pass],  # hold ~1.9 s: charge grows on the start hex
		[50, func() -> void: _drag(Vector2(150, 150))],  # now draw a short stroke
		[50, func() -> void: _touch(Vector2(150, 150), false)],
		[50, func() -> void: _check("scenario3 charge", func() -> bool:
			return got_charge > 0.5 and got_path_charge > 0.5)],
	])

	# --- scenario 4: quick double-tap -> two taps (wall-X survives) ---------
	seq([
		[50, func() -> void:
			got_menu_open = false
			_touch(Vector2(340, 340), true)],
		[80, func() -> void: _touch(Vector2(340, 340), false)],
		[50, func() -> void: _touch(Vector2(340, 340), true)],
		[80, func() -> void: _touch(Vector2(340, 340), false)],
		[50, func() -> void: _check("scenario4 dbl-tap", func() -> bool:
			return got_tap == 4 and not got_menu_open)],  # 1+1 prior + 2 now
	])

	# --- scenario 5: hold on removable hex -> removal, no menu --------------
	seq([
		[50, func() -> void:
			got_remove = false
			removable = true],
		[50, func() -> void: _touch(Vector2(380, 380), true)],
		[1000, func() -> void: pass],  # hold 1.0 s > HOLD_REMOVE_TIME (0.7)
		[50, func() -> void: _touch(Vector2(380, 380), false)],
		[50, func() -> void: _check("scenario5 removal", func() -> bool: return got_remove)],
	])

func seq(pairs: Array) -> void:
	for p in pairs:
		steps.append({"wait": float(p[0]) / 1000.0, "body": p[1]})

func _touch(pos: Vector2, pressed: bool) -> void:
	print("  [harness] frame=%d %s at %s" % [_frame, "PRESS" if pressed else "RELEASE", pos])
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.position = pos
	ev.pressed = pressed
	ctl._unhandled_input(ev)


func _drag(pos: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = 0
	ev.position = pos
	ctl._unhandled_input(ev)

var failures := 0
var _frame := 0

func _check(name: String, cond: Callable) -> void:
	if bool(cond.call()):
		print("GESTURE TEST: %s PASS" % name)
	else:
		failures += 1
		print("GESTURE TEST: %s FAIL (taps=%d menu=%s charge=%.2f path=%.2f remove=%s)" %
				[name, got_tap, got_menu_open, got_charge, got_path_charge, got_remove])

func _process(delta: float) -> bool:
	_frame += 1
	# -s SceneTree scripts don't auto-tick child nodes; drive the controller.
	ctl._process(delta)
	if steps.is_empty():
		print("GESTURE TEST: probe_frames=", ctl.get_meta("probe"))
		print("GESTURE TEST: %s" % ("ALL PASS" if failures == 0 else "%d FAILURES" % failures))
		quit(1 if failures > 0 else 0)
		return true
	steps[0].wait -= delta
	if steps[0].wait <= 0.0:
		var body: Callable = steps.pop_front().body
		body.call()
	return false
