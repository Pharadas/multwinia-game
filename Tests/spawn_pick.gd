extends SceneTree

## Headless test for the lobby spawn picking (each player chooses up to 3
## hexes their starting army is divided across):
##   godot --headless -s res://Tests/spawn_pick.gd
##
##   1. split_spawn_counts()      - the army divides evenly, remainder first
##   2. spawn_positions_in_hex()  - every dot lands inside its own hex
##   3. HexTerrainSocket.lobby_state_message() - the wire shape a phone reads
##   4. the real phone scene      - taps pick up to 3 hexes, walls are refused,
##                                  picks can be undone, and picking stops the
##                                  moment the match starts
##
## The GPU side of the relocation (set_team_spawn_hexes moving the seeded
## dots) needs a RenderingDevice, so it is covered live against a running
## game instead - see Tests/spawn_pick_live.py.

const StupidSimpleScript := preload("res://Demos/stupid simple/stupid_simple.gd")

var _view: Node = null
var _frames := 0
var _failures := 0
var _checks := 0


func _initialize() -> void:
	print("=== split_spawn_counts (army division) ===")
	_test_split()
	print("=== spawn_positions_in_hex (layout) ===")
	_test_positions()
	print("=== lobby_state_message (wire shape) ===")
	_test_lobby_message()
	print("=== phone spawn picking (real scene) ===")
	var packed := load("res://Phone/MainPhoneView.tscn") as PackedScene
	if packed == null:
		_check("phone scene loadable", "null", "PackedScene")
		_finish()
		return
	_view = packed.instantiate()
	root.add_child(_view)


func _process(_delta: float) -> bool:
	if _view == null:
		return true
	_frames += 1
	# Frame 1 is when _ready() runs, and with it the palette + marker layers.
	if _frames < 2:
		return false
	_test_phone_picking()
	_finish()
	return true


func _finish() -> void:
	print("")
	if _failures == 0:
		print("OK - %d checks passed" % _checks)
	else:
		print("FAILED - %d of %d checks failed" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


# --- 1. the division ---------------------------------------------------------

func _test_split() -> void:
	var cases: Array = [
		# (label, count, groups, expected, expected groups)
		["5000 over 3 picks", 5000, 3, [1667, 1667, 1666], 3],
		["5000 over 1 pick", 5000, 1, [5000], 1],
		["5000 over 2 picks", 5000, 2, [2500, 2500], 2],
		["7 over 3 picks", 7, 3, [3, 2, 2], 3],
		["2 over 3 picks", 2, 3, [1, 1, 0], 3],
		["no dots", 0, 3, [0, 0, 0], 3],
		["no picks", 10, 0, [], 0],
	]
	for case in cases:
		var got: Array = StupidSimpleScript.split_spawn_counts(case[1], case[2])
		_check("split %s" % case[0], str(got), str(case[3]))
		# The parts must always add back up to the whole army. No picks at all
		# means "leave the army where it is", so there is nothing to sum.
		if int(case[2]) > 0:
			var total := 0
			for n in got:
				total += int(n)
			_check("split %s sums" % case[0], str(total), str(maxi(int(case[1]), 0)))


# --- 2. the in-hex layout ----------------------------------------------------

func _test_positions() -> void:
	var center := Vector3(120.0, 33.0, -48.0)
	var radius := 7.5
	for count in [1, 2, 7, 1667]:
		var pts: Array = StupidSimpleScript.spawn_positions_in_hex(center, radius, count)
		_check("count %d placed" % count, str(pts.size()), str(count))
		var worst := 0.0
		var off_center := 0
		for p in pts:
			var d := Vector2(p.x - center.x, p.z - center.z).length()
			worst = maxf(worst, d)
			if absf(p.y - center.y) > 0.0001:
				off_center += 1
		# Every dot must be inside its own hex (never past the wall), and all
		# of them take the hex's ground height.
		_check("count %d inside hex" % count, "yes" if worst <= radius + 0.001 else "no", "yes")
		_check("count %d on the ground" % count, str(off_center), "0")
	# The layout must be deterministic: the same picks always look the same.
	var a: Array = StupidSimpleScript.spawn_positions_in_hex(center, radius, 50)
	var b: Array = StupidSimpleScript.spawn_positions_in_hex(center, radius, 50)
	_check("layout is deterministic", "same" if a == b else "differs", "same")
	# ...and dots must not all sit on one point.
	var first: Vector3 = a[0]
	var last: Vector3 = a[a.size() - 1]
	_check("layout separates dots", "yes" if first.distance_to(last) > radius * 0.5 else "no", "yes")


# --- 3. the wire shape -------------------------------------------------------

func _test_lobby_message() -> void:
	var picks := {
		0: [Vector2i(3, 4), Vector2i(5, 6), Vector2i(7, 8)],
		2: [Vector2i(1, 1)],
	}
	var msg := HexTerrainSocket.lobby_state_message(0, false, picks)
	_check("message type", str(msg.get("type")), "lobby_state")
	_check("started flag", str(msg.get("started")), "false")
	_check("own team", str(msg.get("team")), "0")
	_check("own picks (ordered)", str(msg.get("hexes")), "[[3, 4], [5, 6], [7, 8]]")
	var picked: Array = msg.get("picked", [])
	picked.sort()
	_check("per-team counts", str(picked), "[[0, 3], [2, 1]]")

	# A phone with no picks yet gets an empty list, not a missing field.
	var empty := HexTerrainSocket.lobby_state_message(1, true, {})
	_check("no picks = empty list", str(empty.get("hexes")), "[]")
	_check("started is carried", str(empty.get("started")), "true")


# --- 4. the phone scene ------------------------------------------------------

func _test_phone_picking() -> void:
	var socket = _view._get_socket_node() if _view.has_method("_get_socket_node") else null
	if socket == null or _view.palette == null or _view.spawn_marks == null:
		_check("phone exposes socket + palette + spawn layer", "no", "yes")
		return
	_check("no picker before the lobby message", "hidden" if not _view.palette._lobby_panel.visible else "shown", "hidden")
	_check("not in the lobby by default", str(_view.in_lobby), "false")
	# Taps pick nothing until the main screen says the match hasn't started.
	_check("tap before lobby state", str(_view.toggle_spawn_pick(Vector2i(9, 9))), "false")

	# The main screen says: lobby is open, no picks yet.
	socket._handle_message({"type": "assigned_team", "team": 1, "color": [0.2, 0.8, 0.2]})
	socket._handle_message({"type": "lobby_state", "started": false, "team": 1,
			"hexes": [], "picked": []})
	_check("in the lobby", str(_view.in_lobby), "true")
	_check("picker shown", "shown" if _view.palette._lobby_panel.visible else "hidden", "shown")
	_check("picker counts from 0", str(_view.palette._lobby_title.text), "PICK 3 SPAWN HEXES  -  0/3")

	# Three picks land; the fourth is refused rather than dropping one.
	_check("pick 1", str(_view.toggle_spawn_pick(Vector2i(3, 3))), "true")
	_check("pick 2", str(_view.toggle_spawn_pick(Vector2i(4, 4))), "true")
	_check("pick 3", str(_view.toggle_spawn_pick(Vector2i(5, 5))), "true")
	_check("pick 4 refused", str(_view.toggle_spawn_pick(Vector2i(6, 6))), "false")
	_check("picks kept", str(_view.spawn_picks), "[(3, 3), (4, 4), (5, 5)]")
	_check("picker counts 3", str(_view.palette._lobby_title.text), "PICK 3 SPAWN HEXES  -  3/3")
	_check("marks follow the picks", str(_view.spawn_marks.picks), "[(3, 3), (4, 4), (5, 5)]")
	_check("marks use the team color", "%.2f,%.2f,%.2f" % [_view.spawn_marks.color.r,
			_view.spawn_marks.color.g, _view.spawn_marks.color.b], "0.20,0.80,0.20")

	# Tapping a picked hex takes it back (so a mistake isn't permanent).
	_check("unpick", str(_view.toggle_spawn_pick(Vector2i(4, 4))), "true")
	_check("picks after unpick", str(_view.spawn_picks), "[(3, 3), (5, 5)]")

	# Walls are never allowed: an army inside a wall hex would be stuck.
	_view.state.walls[Vector2i(1, 1)] = true
	_check("wall refused", str(_view.toggle_spawn_pick(Vector2i(1, 1))), "false")
	_check("wall not added", str(_view.spawn_picks), "[(3, 3), (5, 5)]")

	# A reconnect re-sends the picks the server actually accepted.
	socket._handle_message({"type": "lobby_state", "started": false, "team": 1,
			"hexes": [[3, 3], [7, 7]], "picked": [[1, 2]]})
	_check("server picks adopted", str(_view.spawn_picks), "[(3, 3), (7, 7)]")

	# The host starts: picker gone, taps are orders again.
	socket._handle_message({"type": "lobby_state", "started": true, "team": 1,
			"hexes": [[3, 3], [7, 7]], "picked": []})
	_check("lobby closed", str(_view.in_lobby), "false")
	_check("picker hidden", "hidden" if not _view.palette._lobby_panel.visible else "shown", "hidden")
	_check("marks cleared", str(_view.spawn_marks.picks), "[]")
	_check("tap after start is not a pick", str(_view.toggle_spawn_pick(Vector2i(8, 8))), "false")


# --- harness -----------------------------------------------------------------

func _check(label: String, got: String, want: String) -> void:
	_checks += 1
	if got == want:
		print("  PASS %-40s %s" % [label, got])
		return
	_failures += 1
	print("  FAIL %-40s got \"%s\" want \"%s\"" % [label, got, want])
