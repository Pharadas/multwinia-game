extends SceneTree

## Mouse-path regression test for PhoneInputController.
##   godot --headless -s res://Tests/mouse_stroke.gd
##
## Guards the mouse branch of _unhandled_input: the release logic used to
## sit in an `else` of the whole mouse-button check, so every OTHER event
## (motion, keys) ran it - hovering fired cell_tapped and the first motion
## ended every stroke, which killed path drawing with a mouse (web/desktop).
##
## Events are injected through Input.parse_input_event so the real engine
## dispatch (and Input's pressed-state polling, which the controller's
## _process uses to extend mouse strokes) is exercised, not the harness.

var ctl: Node
var stroke_layer: Node2D
var got_taps := 0
var got_paths: Array = []   # each entry: PackedVector2Array
var got_hovers := 0

var _frame := 0
var _failures := 0

func _initialize() -> void:
	stroke_layer = Node2D.new()
	root.add_child(stroke_layer)
	ctl = load("res://Phone/phone_input_controller.gd").new()
	root.add_child(ctl)
	ctl.bind_stroke_layer(stroke_layer)
	ctl.bind_screen_to_cell(func(pos: Vector2) -> Vector2i:
		return Vector2i(int(pos.x / 40.0), int(pos.y / 40.0)))
	ctl.cell_tapped.connect(func(_c: Vector2i) -> void: got_taps += 1)
	ctl.path_drawn.connect(func(points: PackedVector2Array, _charge: float) -> void:
		got_paths.append(points.duplicate()))
	ctl.pointer_cell_changed.connect(func(_cell) -> void: got_hovers += 1)

func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)

func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)

func _check(name: String, ok: bool, detail := "") -> void:
	if ok:
		print("MOUSE TEST: %s PASS %s" % [name, detail])
	else:
		_failures += 1
		print("MOUSE TEST: %s FAIL %s" % [name, detail])

func _process(_delta: float) -> bool:
	_frame += 1
	match _frame:
		2:
			# Pure hover across several cells: no press, so NOTHING should
			# fire - no taps, no paths.
			for i in range(6):
				_mouse_motion(Vector2(100 + i * 40.0, 200))
		4:
			_check("hover fires no taps", got_taps == 0, "taps=%d" % got_taps)
			_check("hover draws no path", got_paths.is_empty())
			# Now a real mouse stroke: press ...
			_mouse_button(Vector2(120, 200), true)
		5, 6, 7, 8, 9, 10:
			# ... drag across many cells over multiple frames ...
			_mouse_motion(Vector2(120.0 + (_frame - 4) * 40.0, 200.0 + (_frame - 4) * 8.0))
		11:
			# ... and release ON A MOTION-FREE frame (the old bug fired the
			# release path from motion events themselves).
			_mouse_button(Vector2(360, 240), false)
		13:
			_check("mouse drag draws a path", got_paths.size() == 1,
					"paths=%d" % got_paths.size())
			if got_paths.size() == 1:
				var pts: PackedVector2Array = got_paths[0]
				_check("path has real geometry", pts.size() >= 4,
						"points=%d" % pts.size())
			_check("stroke was not a tap", got_taps == 0, "taps=%d" % got_taps)
		15:
			# A click without movement IS a tap.
			_mouse_button(Vector2(80, 80), true)
		17:
			_mouse_button(Vector2(80, 80), false)
		19:
			_check("still click is a tap", got_taps == 1, "taps=%d" % got_taps)
			print("MOUSE TEST: %s" % ("ALL PASS" if _failures == 0 else "%d FAILURES" % _failures))
			quit(1 if _failures > 0 else 0)
			return true
	return false
