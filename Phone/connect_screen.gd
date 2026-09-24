extends CanvasLayer
class_name ConnectScreen

## Full-screen manual-connect overlay for web phones. Shown whenever the
## socket is disconnected (and once at startup until the first connection);
## hidden the moment the WebSocket opens.
##
## It only appears when AUTOMATIC connection failed - a page served by the
## game itself (http://<game-pc>:9095) connects with no input at all, and
## the socket also sweeps the local network for a running game. So this
## screen is the last resort, and on the web it has NO text box: the
## engine's LineEdit can't reliably take keyboard focus inside a browser
## canvas, and touch devices have no keyboard to open for it - the address
## is typed into the browser's own prompt() dialog instead.

signal connect_requested(target: String)

const BG_COLOR := Color(0.05, 0.05, 0.08, 0.97)
const ACCENT := Color(0.95, 0.75, 0.2)

var _panel: Control
var _status: Label
var _input: LineEdit
var _connect_btn: Button
var _fullscreen_btn: Button
var _spinner_time := 0.0
var _visible_connected := false
## Non-empty = show this exact message instead of the animated
## "connecting..." spinner (e.g. "nothing dialable yet" or "trying wss://...").
var _status_override := ""

func _ready() -> void:
	layer = 50
	_build_ui()

func _build_ui() -> void:
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)

	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(520, 0)
	box.add_theme_constant_override("separation", 18)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.add_child(box)

	var title := Label.new()
	title.text = "Connect to game"
	title.add_theme_font_size_override("font_size", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var hint := Label.new()
	if OS.has_feature("web"):
		hint.text = "No game found yet.\nClick the button and type the host's address\nin the browser's own prompt box - IP:port, or a\nwss:// address for a page hosted on itch.io."
	else:
		hint.text = "Enter the host's IP (e.g. 203.0.113.7), IP:port,\nor a full ws:// or wss:// address."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	box.add_child(hint)

	# NO text box on the web: a browser canvas LineEdit frequently never
	# receives keystrokes, and a touch device has no keyboard to open for it.
	# The browser's own prompt() dialog is the input method there (see
	# _try_connect), so showing a box that silently eats typing would only
	# confuse. Desktop/native runs keep the normal field.
	if not OS.has_feature("web"):
		_input = LineEdit.new()
		_input.placeholder_text = "IP / IP:port / ws://..."
		_input.add_theme_font_size_override("font_size", 24)
		_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
		_input.text_submitted.connect(_on_text_submitted)
		box.add_child(_input)

	_connect_btn = Button.new()
	_connect_btn.text = "Connect"
	_connect_btn.add_theme_font_size_override("font_size", 24)
	_connect_btn.pressed.connect(_try_connect)
	box.add_child(_connect_btn)
	if OS.has_feature("web"):
		_connect_btn.text = "Enter address && connect"
	_fullscreen_btn = Button.new()
	_fullscreen_btn.text = "Toggle fullscreen"
	_fullscreen_btn.add_theme_font_size_override("font_size", 20)
	_fullscreen_btn.pressed.connect(_toggle_fullscreen)
	box.add_child(_fullscreen_btn)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", ACCENT)
	box.add_child(_status)

func _on_text_submitted(_t: String) -> void:
	_try_connect()

func _toggle_fullscreen() -> void:
	# On web this maps to the browser's requestFullscreen; it must be
	# called from a user gesture (a button press is one).
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

## Browser prompt() - the reliable way to type text in a web export (the
## engine's own LineEdit loses keyboard focus to the page in several
## browsers, and touch devices have no keyboard to open for it).
func _web_prompt_text() -> String:
	if not OS.has_feature("web"):
		return ""
	var result = JavaScriptBridge.eval(
			"window.prompt('Host address (IP:port or wss://...)','')", true)
	return str(result) if result != null else ""

func _process(delta: float) -> void:
	if not visible:
		return
	_spinner_time += delta
	if not _status_override.is_empty():
		return # a fixed message is more useful than the spinner right now
	var dots := ".".repeat(1 + int(_spinner_time * 2.0) % 3)
	_status.text = "connecting%s" % dots

## Show while disconnected, hide once connected. Re-shows if the link drops.
func set_connection_state(connected: bool) -> void:
	_visible_connected = connected
	visible = not connected
	if connected:
		_status_override = ""
		_status.text = ""
		if _input:
			_input.release_focus()
	elif _input:
		# The whole point of this screen is typing an address, so put the
		# caret in the field right away - the player never has to tap it
		# first (and a desktop player can just start typing).
		_input.grab_focus()

## Replaces the animated spinner with a fixed message (call with "" to go
## back to the spinner).
func set_status(msg: String) -> void:
	_status_override = msg
	_status.text = msg

func _try_connect() -> void:
	var target := ""
	if _input != null:
		target = _input.text.strip_edges()
	# Web: the browser's own prompt dialog IS the input (there is no text box
	# - see _build_ui). It must be opened from a real user gesture, which a
	# button press is.
	if OS.has_feature("web"):
		var typed = JavaScriptBridge.eval(
				"window.prompt('Host address (IP:port or wss://...)','')", true)
		if typed != null and not str(typed).strip_edges().is_empty():
			target = str(typed).strip_edges()
			if _input != null:
				_input.text = target
	if target.is_empty():
		set_status("type an address first")
		return
	set_status("")
	connect_requested.emit(target)
