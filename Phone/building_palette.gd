class_name BuildingPalette
extends CanvasLayer

## The phone's top + bottom UI: which team this phone commands (badge), this
## team's resource counter and the always-visible building palette. Pressing a
## chip immediately puts that building "in hand" (button_down, so it can be
## dragged onto the grid) - the palette itself knows nothing about the grid,
## it just reports picks.

signal building_picked(building_id: int)

const CHIP_SIZE := Vector2(130, 64)
const PALETTE_HEIGHT := 96.0

var _resource_label: Label
## Team badge: the color + id of the team this phone commands. Grey "TEAM -"
## until the main screen assigns one (see set_team / main_phone_view.gd).
var _team_swatch: ColorRect
var _team_label: Label
## Lobby spawn picker banner: visible only while the host hasn't started the
## match, telling the player to tap hexes and how many they have picked.
var _lobby_panel: MarginContainer
var _lobby_title: Label
var _lobby_hint: Label


func _ready() -> void:
	name = "PhoneUI"
	layer = 10
	_build_team_badge()
	_build_lobby_panel()
	_build_resource_label()
	#_build_palette()
	_build_fullscreen_button()


## Shows/hides the lobby spawn picker banner and updates its counter. Called
## by the facade whenever the main screen reports the lobby state.
func set_lobby_picking(active: bool, chosen: int, max_picks: int) -> void:
	if _lobby_panel == null:
		return
	_lobby_panel.visible = active
	if not active:
		return
	_lobby_title.text = "PICK %d SPAWN HEXES  -  %d/%d" % [max_picks, chosen, max_picks]
	_lobby_hint.text = ("tap a hex to choose where your army starts" if chosen < max_picks
			else "tap a picked hex to change it - the host starts the match")


## The lobby banner: what to do while the match is still waiting to start.
## Sits under the team badge (same top-left stack), hidden by default so a
## phone that never hears from a lobby is unaffected.
func _build_lobby_panel() -> void:
	_lobby_panel = MarginContainer.new()
	_lobby_panel.name = "LobbyPanel"
	_lobby_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_lobby_panel.add_theme_constant_override("margin_left", 18)
	_lobby_panel.add_theme_constant_override("margin_top", 74)
	add_child(_lobby_panel)

	var box := HBoxContainer.new()
	box.name = "Box"
	_lobby_panel.add_child(box)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.09, 0.16, 0.88)
	style.border_color = Color(0.5, 0.85, 1.0, 0.55)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", style)
	box.add_child(panel)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 4)
	panel.add_child(column)

	_lobby_title = Label.new()
	_lobby_title.name = "LobbyTitle"
	_lobby_title.add_theme_font_size_override("font_size", 20)
	_lobby_title.add_theme_color_override("font_color", Color(0.72, 0.92, 1.0))
	_lobby_title.add_theme_color_override("font_outline_color", Color.BLACK)
	_lobby_title.add_theme_constant_override("outline_size", 4)
	column.add_child(_lobby_title)

	_lobby_hint = Label.new()
	_lobby_hint.name = "LobbyHint"
	_lobby_hint.add_theme_font_size_override("font_size", 14)
	_lobby_hint.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
	column.add_child(_lobby_hint)

	_lobby_panel.visible = false


## Shows which team this phone commands, in that team's own color, so a
## player can tell their army from the others at a glance. Called by the
## facade when the main screen announces the assignment.
func set_team(team: int, color: Color) -> void:
	if _team_label == null or _team_swatch == null:
		return
	_team_label.text = ("TEAM %d" % team) if team >= 0 else "TEAM -"
	_team_label.add_theme_color_override("font_color", color)
	_team_swatch.color = color


func _build_team_badge() -> void:
	var anchor := MarginContainer.new()
	anchor.name = "TeamBadge"
	anchor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	anchor.add_theme_constant_override("margin_left", 18)
	anchor.add_theme_constant_override("margin_top", 18)
	add_child(anchor)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.08, 0.8)
	style.border_color = Color(1.0, 1.0, 1.0, 0.16)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 12.0
	style.content_margin_right = 14.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", style)
	anchor.add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	_team_swatch = ColorRect.new()
	_team_swatch.custom_minimum_size = Vector2(22, 22)
	_team_swatch.color = Color(0.75, 0.75, 0.78)
	_team_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_team_swatch)

	_team_label = Label.new()
	_team_label.text = "TEAM -"
	_team_label.add_theme_font_size_override("font_size", 22)
	_team_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	_team_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_team_label.add_theme_constant_override("outline_size", 5)
	row.add_child(_team_label)


## The main screen broadcasts each team's resource pool once per economy
## tick; this shows this phone's team's amount. A NEGATIVE pool is real and
## meaningful - it's the team's running debt, and the deeper it goes the
## faster boids desert to the NPC horde - so it's shown (in red) instead of
## falling back to the "-resources-" placeholder, which made a broke team
## look like a phone that simply never received any data.
func set_team_resources(amount: float) -> void:
	var shown := int(floor(amount)) if amount >= 0.0 else -int(ceil(-amount))
	_resource_label.text = "◆ %d" % shown
	_resource_label.add_theme_color_override("font_color",
			Color(1.0, 0.85, 0.2) if amount >= 0.0 else Color(1.0, 0.35, 0.3))


func _build_resource_label() -> void:
	_resource_label = Label.new()
	_resource_label.name = "ResourceLabel"
	_resource_label.text = "-resources-"
	_resource_label.anchor_left = 0.5
	_resource_label.anchor_top = 0.0
	_resource_label.anchor_right = 0.5
	_resource_label.anchor_bottom = 0.0
	_resource_label.offset_left = -80.0
	_resource_label.offset_top = 20.0
	_resource_label.offset_right = 80.0
	_resource_label.offset_bottom = 70.0
	_resource_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_resource_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_resource_label.add_theme_font_size_override("font_size", 28)
	_resource_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_resource_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_resource_label.add_theme_constant_override("outline_size", 6)
	add_child(_resource_label)


func _build_palette() -> void:
	var palette := PanelContainer.new()
	palette.name = "BuildPalette"
	palette.anchor_left = 0.0
	palette.anchor_right = 1.0
	palette.anchor_top = 1.0
	palette.anchor_bottom = 1.0
	palette.offset_top = -PALETTE_HEIGHT
	palette.offset_bottom = -12.0
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 24)
	palette.add_child(row)
	for id in BuildingTypes.NAMES:
		var chip := Button.new()
		chip.text = BuildingTypes.name_of(id)
		chip.custom_minimum_size = CHIP_SIZE
		chip.add_theme_color_override("font_color", BuildingTypes.color_of(id))
		# button_down fires on press so the building is in hand while dragging.
		chip.button_down.connect(func() -> void: building_picked.emit(id))
		chip.mouse_default_cursor_shape = Control.CURSOR_DRAG
		row.add_child(chip)
	add_child(palette)


## Web only: a tiny always-available fullscreen toggle (top-right). The
## browser's requestFullscreen must come from a user gesture, so a button
## is the only dependable way in; hidden on native where F11/window mode
## already exists.
func _build_fullscreen_button() -> void:
	if not OS.has_feature("web"):
		return
	var btn := Button.new()
	btn.name = "FullscreenButton"
	btn.text = "Full screen"   # ASCII: the default web font lacks the fullscreen glyph
	btn.custom_minimum_size = Vector2(96, 40)
	btn.add_theme_font_size_override("font_size", 14)
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.offset_left = -108.0
	btn.offset_top = 12.0
	btn.offset_right = -12.0
	btn.offset_bottom = 52.0
	btn.pressed.connect(func() -> void:
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN))
	add_child(btn)
