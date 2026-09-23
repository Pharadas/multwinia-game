extends SceneTree

## Headless test for the phone HUD (the same scene the WEB export ships):
##   godot --headless -s res://Tests/phone_hud.gd
##
## Covers what a player reads off the phone while playing:
##   1. the team badge - "TEAM -" in neutral grey until the main screen
##      assigns a team, then that team's id AND its color (so you can tell
##      whose army you command in the web view);
##   2. the resource counter - this team's pool only, debt shown as a real
##      negative number, and other teams' broadcasts ignored;
##   3. that the HUD is driven by the socket's assignment messages (not by
##      the facade poking the palette), which is the wiring a web phone uses.
##
## Runs a real frame first: the phone builds its UI in _ready(), and nodes
## added before the first frame only receive _ready() once the loop starts.

var _view: Node = null
var _frames := 0
var _failures := 0
var _checks := 0


func _initialize() -> void:
	var packed := load("res://Phone/MainPhoneView.tscn") as PackedScene
	if packed == null:
		print("FAILED - phone scene not loadable")
		quit(1)
		return
	_view = packed.instantiate()
	root.add_child(_view)


func _process(_delta: float) -> bool:
	if _view == null:
		return true
	# Frame 1 is when _ready() runs (and with it the palette build).
	_frames += 1
	if _frames < 2:
		return false
	if _frames > 2:
		return true

	_run_checks()
	print("")
	if _failures == 0:
		print("OK - %d checks passed" % _checks)
	else:
		print("FAILED - %d of %d checks failed" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)
	return true


func _run_checks() -> void:
	var palette = _view.palette if "palette" in _view else null
	if palette == null:
		_check("palette built", "null", "BuildingPalette")
		return
	if palette._team_label == null or palette._team_swatch == null:
		_check("badge built", "missing", "label + swatch")
		return
	_check("palette is a CanvasLayer", "yes" if palette is CanvasLayer else "no", "yes")

	var socket = _view._get_socket_node() if _view.has_method("_get_socket_node") else null
	if socket == null:
		_check("phone exposes its socket", "no", "yes")
		return

	# --- before any assignment: neutral, no team claimed ------------------
	_check("badge before assignment", str(palette._team_label.text), "TEAM -")
	_check("swatch before assignment", _color_str(palette._team_swatch.color), "0.75,0.75,0.78")

	# --- the assignment a web phone gets on connect -----------------------
	# team_color(2) is the palette's blue - the message the main screen sends.
	socket._handle_message({"type": "assigned_team", "team": 2, "color": [0.2, 0.4, 0.9]})
	_check("facade team", str(_view.team_number), "2")
	_check("facade color", _color_str(_view.team_color), "0.20,0.40,0.90")
	_check("badge names the team", str(palette._team_label.text), "TEAM 2")
	_check("swatch shows the team color", _color_str(palette._team_swatch.color), "0.20,0.40,0.90")
	_check("badge text matches the swatch", _color_str(palette._team_label.get_theme_color("font_color")),
			"0.20,0.40,0.90")

	# --- resource counter: this team only ---------------------------------
	_check("counter before any broadcast", str(palette._resource_label.text), "-resources-")
	socket._handle_message({"type": "team_resources", "team": 1, "amount": 777.0})
	_check("other team's pool ignored", str(palette._resource_label.text), "-resources-")
	socket._handle_message({"type": "team_resources", "team": 2, "amount": 1234.9})
	_check("own pool shown", str(palette._resource_label.text), "◆ 1234")
	socket._handle_message({"type": "team_resources", "team": 2, "amount": -32143.0})
	_check("debt is shown, not hidden", str(palette._resource_label.text), "◆ -32143")
	_check("debt is red", _color_str(palette._resource_label.get_theme_color("font_color")),
			"1.00,0.35,0.30")

	# --- reconnect: the team can change, the badge must follow ------------
	socket._handle_message({"type": "assigned_team", "team": 1, "color": [0.2, 0.8, 0.2]})
	_check("badge follows re-assignment", str(palette._team_label.text), "TEAM 1")
	_check("swatch follows re-assignment", _color_str(palette._team_swatch.color), "0.20,0.80,0.20")
	socket._handle_message({"type": "team_resources", "team": 1, "amount": 20.0})
	_check("new team's pool shown", str(palette._resource_label.text), "◆ 20")

	# --- a server too old to send a color must not break the badge --------
	socket._handle_message({"type": "assigned_team", "team": 3})
	_check("no color -> grey badge", _color_str(palette._team_swatch.color), "0.75,0.75,0.78")
	_check("no color -> team still named", str(palette._team_label.text), "TEAM 3")


func _color_str(c: Color) -> String:
	return "%.2f,%.2f,%.2f" % [c.r, c.g, c.b]


func _check(label: String, got: String, want: String) -> void:
	_checks += 1
	if got == want:
		print("  PASS %-38s %s" % [label, got])
		return
	_failures += 1
	print("  FAIL %-38s got \"%s\" want \"%s\"" % [label, got, want])
