extends CanvasLayer
class_name ConnectScreen

## Full-screen manual-connect overlay for web phones. Shown whenever the
## socket is disconnected (and once at startup until the first connection);
## hidden the moment the WebSocket opens. Typing an IP (or host:port, or a
## full ws:// URL) calls the socket's set_remote_target() to dial it.

signal connect_requested(target: String)

const BG_COLOR := Color(0.05, 0.05, 0.08, 0.97)
const ACCENT := Color(0.95, 0.75, 0.2)

var _panel: Control
var _status: Label
var _input: LineEdit
var _connect_btn: Button
var _spinner_time := 0.0
var _visible_connected := false

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
	hint.text = "Enter the host's IP (e.g. 203.0.113.7),\nIP:port, or a full ws:// address."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	box.add_child(hint)

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

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_color", ACCENT)
	box.add_child(_status)

func _on_text_submitted(_t: String) -> void:
	_try_connect()

func _process(delta: float) -> void:
	if visible:
		_spinner_time += delta
		var dots := ".".repeat(1 + int(_spinner_time * 2.0) % 3)
		var state_txt := "connecting%s" % dots
		if not _visible_connected:
			_status.text = state_txt

## Show while disconnected, hide once connected. Re-shows if the link drops.
func set_connection_state(connected: bool) -> void:
	_visible_connected = connected
	visible = not connected
	if connected:
		_status.text = ""

func set_status(msg: String) -> void:
	_status.text = msg

func _try_connect() -> void:
	var target := _input.text.strip_edges()
	if target.is_empty():
		set_status("type an address first")
		return
	connect_requested.emit(target)
	set_status("dialing %s ..." % target)
