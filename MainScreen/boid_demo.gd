extends Node3D

## Self-contained demo for the hex-grid boid compute + render pipeline.
##
## Builds a flat hex grid entirely in code, seeds dots at random hexes
## (some with random paths so they actually move), wires up BoidCompute
## and BoidRenderEffect directly, and adds WASD/QE camera movement.
##
## No terrain, no HexTile collisions, no networking required.

@export var hex_cols: int = 15
@export var hex_rows: int = 15
@export var hex_size: float = 2.0
@export var dot_count: int = 500
@export var dot_scale: float = 0.4
@export var team_color_a := Color(0.2, 0.9, 0.4)
@export var team_color_b := Color(0.9, 0.3, 0.3)
@export var camera_speed: float = 30.0
@export var zoom_speed: float = 5.0

const HEX_ADJ_SLOTS := 32
const MAX_PATH_LENGTH := 16

var _compute: BoidCompute
var _effect: BoidRenderEffect
var _hex_count: int
var _hex_positions: PackedVector3Array

# ── Entry point ──────────────────────────────────────────────────────────

func _ready() -> void:
	print("[BoidDemo] _ready — starting setup")
	_hex_count = hex_cols * hex_rows
	_hex_positions.resize(_hex_count)

	var hex_pos4 := _build_hex_grid()
	# Build adjacency once (used for seeding and sent to compute).
	_build_cached_adj()
	var hex_adj := _cached_adj

	print("[BoidDemo] Grid built: %d hexes, adjacency size=%d" % [_hex_count, hex_adj.size()])

	# Seed dots: each gets a random hex, and ~40% get random paths.
	var seed_data := _seed_dots()
	print("[BoidDemo] Dots seeded: %d positions, %d paths" % [seed_data.positions.size(), seed_data.paths.size()])

	# --- BoidCompute (GPU simulation) ---
	_compute = BoidCompute.new()
	_compute.hex_radius = hex_size * 0.82
	_compute.setup(dot_count, _hex_count, hex_pos4, hex_adj,
				   seed_data.positions, seed_data.paths, seed_data.states)
	print("[BoidCompute] setup done — pos_rid valid=%s, dot_count=%d" % [str(_compute.get_pos_rid()), _compute.get_dot_count()])

	# --- BoidRenderEffect (GPU billboard renderer) ---
	_effect = BoidRenderEffect.new()
	print("[BoidRenderEffect] created — shader_rid valid=%s" % [str(_effect._shader_rid)])
	_effect.configure(_compute.get_pos_rid(), _compute.get_dot_count())
	print("[BoidRenderEffect] configured — uniform_set valid=%s" % [str(_effect._uniform_set_rid)])
	_effect.bind_compute(_compute)
	_effect.dot_scale = dot_scale
	_effect.team_color = team_color_a
	_effect.sim_enabled = true

	# --- Attach compositor to the scene's WorldEnvironment ---
	var attached := _attach_compositor()
	print("[BoidDemo] Compositor attached: %s" % str(attached))
	print("BoidDemo: %d hexes, %d dots — WASD/QE move camera, scroll zooms, R randomizes paths." % [_hex_count, dot_count])


var _frame := 0

func _process(delta: float) -> void:
	_frame += 1
	if _frame == 2:
		print("[BoidDemo] frame 2 — pos_rid=%s dot_count=%d effect_enabled=%s" % [
			str(_compute.get_pos_rid()) if _compute else "null",
			_compute.get_dot_count() if _compute else 0,
			str(_effect.enabled) if _effect else "null"])
	if _compute:
		_compute.set_delta_time(delta)
	# Push latest values to the render thread each frame.
	if _effect:
		_effect.dot_scale = dot_scale
		_effect.team_color = team_color_a

	_handle_camera(delta)

	# R to randomize paths (edge-triggered, fires once per press).
	if Input.is_key_pressed(KEY_R) and not _r_was_down:
		_randomize_paths()
	_r_was_down = Input.is_key_pressed(KEY_R)


# ── Hex grid construction ────────────────────────────────────────────────

func _build_hex_grid() -> PackedVector4Array:
	## Flat-top hex layout: even columns at normal row positions,
	## odd columns shifted down by half a row.
	var hex_height := sqrt(3.0) * hex_size
	var horiz := hex_size * 1.5
	var total_w := float(hex_cols - 1) * horiz
	var total_d := float(hex_rows) * hex_height

	var out := PackedVector4Array()
	out.resize(_hex_count)

	for col in range(hex_cols):
		for row in range(hex_rows):
			var x := float(col) * horiz - total_w * 0.5
			var z := float(row) * hex_height + (hex_height * 0.5 if col % 2 == 1 else 0.0) - total_d * 0.5
			var hex_id := col * hex_rows + row
			out[hex_id] = Vector4(x, 0.0, z, 0.0)
			_hex_positions[hex_id] = Vector3(x, 0.0, z)

	return out


# ── Dot seeding ──────────────────────────────────────────────────────────

func _seed_dots() -> Dictionary:
	var positions := PackedVector4Array()
	positions.resize(dot_count)
	var paths := PackedInt32Array()
	paths.resize(dot_count * MAX_PATH_LENGTH)
	paths.fill(-1)
	var states := PackedVector4Array()
	states.resize(dot_count)

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for i in range(dot_count):
		var hex_id := rng.randi_range(0, _hex_count - 1)
		var pos := _hex_positions[hex_id]
		positions[i] = Vector4(pos.x, pos.y, pos.z, float(hex_id))

		# ~40 % of dots get a random path so we can watch them move.
		if rng.randf() < 0.4:
			var path_len := rng.randi_range(3, MAX_PATH_LENGTH)
			var cur := hex_id
			for w in range(path_len):
				# Pick a random neighbor from the adjacency list.
				var candidates: Array[int] = []
				for s in range(HEX_ADJ_SLOTS):
					var n: int = _hex_adj_at(cur, s)
					if n >= 0:
						candidates.append(n)
				if candidates.is_empty():
					break
				cur = candidates[rng.randi() % candidates.size()]
				paths[i * MAX_PATH_LENGTH + w] = cur
			states[i] = Vector4(0.0, float(path_len), 0.0, 1.0)  # team 0, action=move
		else:
			states[i] = Vector4(0.0, 0.0, 0.0, 0.0)  # team 0, action=hold

	return { "positions": positions, "paths": paths, "states": states }


## Read a single adjacency slot from the locally-built adjacency cache.
func _hex_adj_at(hid: int, slot: int) -> int:
	if hid * HEX_ADJ_SLOTS + slot < _cached_adj.size():
		return _cached_adj[hid * HEX_ADJ_SLOTS + slot]
	return -1


var _cached_adj := PackedInt32Array()
var _r_was_down := false

func _build_cached_adj() -> void:
	var neighbor_radius_sq := pow(hex_size * 2.2, 2)
	_cached_adj.resize(_hex_count * HEX_ADJ_SLOTS)
	_cached_adj.fill(-1)
	for hid in range(_hex_count):
		var pos := _hex_positions[hid]
		var slot := 0
		for other in range(_hex_count):
			if other == hid:
				continue
			var oth := _hex_positions[other]
			var dx := pos.x - oth.x
			var dz := pos.z - oth.z
			if dx * dx + dz * dz < neighbor_radius_sq:
				_cached_adj[hid * HEX_ADJ_SLOTS + slot] = other
				slot += 1
				if slot >= HEX_ADJ_SLOTS:
					break


# ── Path randomization (press R) ─────────────────────────────────────────

func _randomize_paths() -> void:
	if not _compute:
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(dot_count):
		var hex_id := rng.randi_range(0, _hex_count - 1)
		var path_len := rng.randi_range(4, MAX_PATH_LENGTH)
		var path_ids := PackedInt32Array()
		path_ids.resize(MAX_PATH_LENGTH)
		path_ids.fill(-1)
		var cur := hex_id
		for w in range(path_len):
			var candidates: Array[int] = []
			for s in range(HEX_ADJ_SLOTS):
				var n := _cached_adj[cur * HEX_ADJ_SLOTS + s]
				if n >= 0:
					candidates.append(n)
			if candidates.is_empty():
				break
			cur = candidates[rng.randi() % candidates.size()]
			path_ids[w] = cur
		_compute.set_dot_path(i, path_ids, 0, 1)


# ── Camera controls ──────────────────────────────────────────────────────

func _handle_camera(delta: float) -> void:
	var cam := $Camera3D
	if cam == null:
		return
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input_dir.z -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input_dir.z += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input_dir.x += 1.0
	if Input.is_key_pressed(KEY_Q):
		input_dir.y -= 1.0
	if Input.is_key_pressed(KEY_E):
		input_dir.y += 1.0

	# Move in the camera's local XZ plane (ignore the look direction).
	var forward = -cam.global_transform.basis.z
	var right = cam.global_transform.basis.x
	var move = (right * input_dir.x + Vector3.UP * input_dir.y + forward * input_dir.z)
	if move.length_squared() > 0.001:
		cam.global_position += move.normalized() * camera_speed * delta

	# Mouse-wheel zoom (move along the camera's forward axis).
	var zoom := 0.0
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_UP):
		zoom += 1.0
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_DOWN):
		zoom -= 1.0
	if absf(zoom) > 0.001:
		cam.global_position += forward * zoom * zoom_speed


# ── Compositor wiring ────────────────────────────────────────────────────

func _attach_compositor() -> bool:
	for child in get_tree().current_scene.find_children("*", "WorldEnvironment"):
		var env := child as WorldEnvironment
		if env == null:
			continue
		if env.compositor == null:
			env.compositor = Compositor.new()
		var effects: Array = env.compositor.compositor_effects
		if not effects.has(_effect):
			effects.append(_effect)
			env.compositor.compositor_effects = effects
		return true
	push_warning("BoidDemo: no WorldEnvironment found — dots won't render.")
	return false


func _exit_tree() -> void:
	if _effect:
		_effect.teardown()
		_effect = null
	if _compute:
		_compute.teardown()
		_compute = null
