class_name BuildRadialMenu
extends Node2D

## Screen-space radial build menu: double-tap a hex and hold, and the three
## building options (Barrack / Mine / Wall) fan out around the held point.
## Drag toward an option and release on it to choose; release elsewhere (or
## lift without moving) cancels. Drawn with _draw() only - no textures.
##
## Lives as a top-level child of the phone view so it renders above the map
## in SCREEN pixels: it is a small ring around the finger, so it can never
## cover the map the way a full-width palette bar could.

## Distance from the held point to each option's center.
const MENU_RADIUS := 10.0
## Radius of one option circle.
const OPTION_RADIUS := 5.0
## Extra forgiving hit area around an option circle.
const HIT_PADDING := 12.0
## Option angles (radians): up, upper-left, upper-right - ordered by
## BuildingTypes id (BARRACK, MINE, WALL).
const ANGLES := [-PI * 0.5, -PI * 0.85, -PI * 0.15]

var _open := false
var _anchor := Vector2.ZERO
var _pointer := Vector2.ZERO


func _ready() -> void:
	visible = false
	top_level = true  # screen space, unaffected by the map's transform
	z_index = 60


func open(screen_pos: Vector2) -> void:
	_anchor = screen_pos
	_pointer = screen_pos
	_open = true
	visible = true
	queue_redraw()


func close() -> void:
	_open = false
	visible = false


func update_pointer(screen_pos: Vector2) -> void:
	if _open and _pointer.distance_to(screen_pos) > 0.5:
		_pointer = screen_pos
		queue_redraw()


## Building id under `screen_pos` (drag-to-select), or -1 when the pointer
## is not on any option (release = cancel).
func option_at(screen_pos: Vector2) -> int:
	if not _open:
		return -1
	var best := -1
	var best_d := INF
	for id in BuildingTypes.NAMES:
		var bid := int(id)
		if bid < 0 or bid >= ANGLES.size():
			continue
		var center := _anchor + Vector2.from_angle(ANGLES[bid]) * MENU_RADIUS
		var d := center.distance_to(screen_pos)
		if d <= OPTION_RADIUS + HIT_PADDING and d < best_d:
			best_d = d
			best = bid
	return best


func _draw() -> void:
	if not _open:
		return
	var font := ThemeDB.fallback_font
	var hover := option_at(_pointer)
	for id in BuildingTypes.NAMES:
		var bid := int(id)
		if bid < 0 or bid >= ANGLES.size():
			continue
		var center := _anchor + Vector2.from_angle(ANGLES[bid]) * MENU_RADIUS
		var col: Color = BuildingTypes.color_of(bid)
		var selected := bid == hover
		draw_circle(center, OPTION_RADIUS + (4.0 if selected else 0.0),
				Color(col.r, col.g, col.b, 0.95 if selected else 0.8))
		if selected:
			draw_arc(center, OPTION_RADIUS + 7.0, 0.0, TAU, 40,
					Color(1, 1, 1, 0.9), 3.0, true)
		# Label with a soft shadow so it reads on any option color.
		var text := BuildingTypes.name_of(bid)
		var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, 14)
		var base := center - Vector2(ts.x * 0.5, -ts.y * 0.3)
		draw_string(font, base + Vector2(1, 1), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0, 0, 0, 0.7))
		draw_string(font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Color(1, 1, 1, 0.95))
	# Anchor pip at the held hex.
	draw_circle(_anchor, 5.0, Color(1, 1, 1, 0.85))
