extends Node2D

## Draw on screen with touch (or mouse). The path is simplified by
## taking 16 uniformly-spaced sample points along it and drawing
## the reduced path in yellow.

var _points := PackedVector2Array()
var _drawing := false
var _recon_points := PackedVector2Array()
var _num_samples := 16

const MARGIN := 40.0
const SPLIT_Y := 480.0
const SCREEN_W := 1080.0
const SCREEN_H := 960.0


func _ready() -> void:
	var btn := Button.new()
	btn.text = "Clear"
	btn.position = Vector2(SCREEN_W - 140, 10)
	btn.size = Vector2(120, 40)
	btn.pressed.connect(_clear)
	add_child(btn)

	var lbl := Label.new()
	lbl.text = "Draw on screen -> reduced path below"
	lbl.position = Vector2(MARGIN, 10)
	lbl.add_theme_font_size_override("font_size", 20)
	add_child(lbl)

	var btn_up := Button.new()
	btn_up.text = "+ Samples"
	btn_up.position = Vector2(MARGIN, SPLIT_Y - 35)
	btn_up.size = Vector2(100, 30)
	btn_up.pressed.connect(func(): _num_samples = mini(_num_samples + 4, 64); _recompute_recon(); queue_redraw())
	add_child(btn_up)

	var btn_dn := Button.new()
	btn_dn.text = "- Samples"
	btn_dn.position = Vector2(MARGIN + 110, SPLIT_Y - 35)
	btn_dn.size = Vector2(100, 30)
	btn_dn.pressed.connect(func(): _num_samples = maxi(_num_samples - 4, 2); _recompute_recon(); queue_redraw())
	add_child(btn_dn)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_start_draw(event.position)
		else:
			_end_draw()
		return
	if event is InputEventScreenDrag and _drawing:
		_add_point(event.position)
		return
	# Desktop fallback
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_start_draw(event.position)
		else:
			_end_draw()
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if _drawing:
			_add_point(event.position)


func _start_draw(pos: Vector2) -> void:
	_drawing = true
	_points.clear()
	_recon_points.clear()
	_add_point(pos)


func _add_point(pos: Vector2) -> void:
	if _points.size() > 0 and _points[_points.size() - 1].distance_to(pos) < 3.0:
		return
	_points.append(pos)
	queue_redraw()


func _end_draw() -> void:
	_drawing = false
	if _points.size() >= 2:
		_recompute_recon()
	queue_redraw()


func _clear() -> void:
	_points.clear()
	_recon_points.clear()
	queue_redraw()


func _recompute_recon() -> void:
	if _points.size() < 2:
		return

	# Compute cumulative arc length
	var n := _points.size()
	var cum_len := PackedFloat32Array()
	cum_len.resize(n)
	cum_len[0] = 0.0
	for i in range(1, n):
		cum_len[i] = cum_len[i - 1] + _points[i - 1].distance_to(_points[i])

	var total_len := cum_len[n - 1]
	if total_len < 0.001:
		_recon_points = PackedVector2Array(_points)
		return

	# Sample _num_samples points uniformly along arc length
	_recon_points.resize(_num_samples)
	for s in range(_num_samples):
		var target_len := total_len * float(s) / float(_num_samples - 1)
		# Find which segment this falls in
		var seg := 0
		for i in range(1, n):
			if cum_len[i] >= target_len:
				seg = i - 1
				break
			seg = i - 1
		# Interpolate within segment
		var seg_start_len := cum_len[seg]
		var seg_end_len := cum_len[mini(seg + 1, n - 1)]
		var seg_len := seg_end_len - seg_start_len
		var frac := 0.0
		if seg_len > 0.001:
			frac = (target_len - seg_start_len) / seg_len
		_recon_points[s] = _points[seg].lerp(_points[mini(seg + 1, n - 1)], frac)

	queue_redraw()


# ── Drawing ──────────────────────────────────────────────────────────────────


func _draw() -> void:
	draw_rect(Rect2(0, 0, SCREEN_W, SCREEN_H), Color(0.08, 0.08, 0.12))
	draw_line(Vector2(0, SPLIT_Y), Vector2(SCREEN_W, SPLIT_Y), Color(0.4, 0.4, 0.4), 1.0)

	draw_string(ThemeDB.fallback_font, Vector2(MARGIN, SPLIT_Y - 10),
		"PATH", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.5, 0.5, 0.5))

	# Original path
	if _points.size() > 1:
		for i in range(1, _points.size()):
			var t := float(i) / float(_points.size())
			draw_line(_points[i - 1], _points[i],
				Color.from_hsv(t * 0.6, 0.9, 1.0), 3.0)
		draw_circle(_points[0], 6.0, Color.GREEN)
		draw_circle(_points[_points.size() - 1], 6.0, Color.RED)

	# Reduced path (yellow)
	if _recon_points.size() > 1:
		for i in range(1, _recon_points.size()):
			draw_line(_recon_points[i - 1], _recon_points[i],
				Color(1.0, 0.9, 0.2, 0.8), 3.0)
		# Draw sample points as dots
		for p in _recon_points:
			draw_circle(p, 4.0, Color(1.0, 0.9, 0.2))
		draw_string(ThemeDB.fallback_font,
			Vector2(SCREEN_W - 300, SPLIT_Y - 10),
			"Yellow = %d-sample reduction" % _num_samples,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
			Color(1.0, 0.9, 0.2))
