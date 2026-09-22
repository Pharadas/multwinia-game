class_name ChargeMeterView
extends Control

## Radial charge meter for the hold-to-charge order mechanic: after drawing
## a path, keeping the pointer held fills a ring 0 -> 100% over the charge
## time (1.75 s). Pure view: PhoneInputController's charge_progressed signal
## drives it; the facade positions it each frame while active.
##
## Drawn with _draw() only - no textures, no shaders.

## The ring is drawn OFFSET up-right of the pointer position passed to
## show_at() so it never sits on top of the finger / tap point.
const POINTER_OFFSET := Vector2(52.0, -52.0)

const RING_RADIUS := 34.0
const RING_WIDTH := 6.0
const COLOR_TRACK := Color(0.0, 0.0, 0.0, 0.35)
const COLOR_FILL := Color(1.0, 0.85, 0.3, 0.95)
const COLOR_FULL := Color(0.4, 1.0, 0.45, 1.0)

var _fraction := 0.0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_level = true  # screen-space, unaffected by the map's transform


func show_at(screen_pos: Vector2) -> void:
	if not visible:
		visible = true
	position = screen_pos + POINTER_OFFSET \
			- Vector2(RING_RADIUS + RING_WIDTH, RING_RADIUS + RING_WIDTH)


func set_fraction(f: float) -> void:
	if not is_equal_approx(_fraction, f):
		_fraction = clampf(f, 0.0, 1.0)
		queue_redraw()


func hide_meter() -> void:
	visible = false


func _draw() -> void:
	var center := Vector2(RING_RADIUS + RING_WIDTH, RING_RADIUS + RING_WIDTH)
	# Track
	draw_arc(center, RING_RADIUS, 0.0, TAU, 48, COLOR_TRACK, RING_WIDTH, true)
	# Fill: clockwise from 12 o'clock.
	var fill_color := COLOR_FILL.lerp(COLOR_FULL, _fraction)
	if _fraction > 0.01:
		draw_arc(center, RING_RADIUS, -PI / 2.0, -PI / 2.0 + TAU * _fraction,
				48, fill_color, RING_WIDTH, true)
	# Percentage label in the middle.
	var pct := int(round(_fraction * 100.0))
	var font := get_theme_default_font()
	var text := "%d%%" % pct
	var text_size := font.get_string_size(text,
			HORIZONTAL_ALIGNMENT_CENTER, -1, 15)
	draw_string(font, center - Vector2(text_size.x * 0.5, -text_size.y * 0.28),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
			Color(1, 1, 1, 0.95))
