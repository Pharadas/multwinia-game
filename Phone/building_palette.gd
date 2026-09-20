class_name BuildingPalette
extends CanvasLayer

## The phone's top + bottom UI: this team's resource counter and the
## always-visible building palette. Pressing a chip immediately puts that
## building "in hand" (button_down, so it can be dragged onto the grid) -
## the palette itself knows nothing about the grid, it just reports picks.

signal building_picked(building_id: int)

const CHIP_SIZE := Vector2(130, 64)
const PALETTE_HEIGHT := 96.0

var _resource_label: Label


func _ready() -> void:
	name = "PhoneUI"
	layer = 10
	_build_resource_label()
	_build_palette()


## The main screen broadcasts each team's resource pool once per economy
## tick; this shows this phone's team's amount.
func set_team_resources(amount: float) -> void:
	_resource_label.text = "◆ %d" % int(floor(amount)) if amount >= 0.0 else "-resources-"


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
