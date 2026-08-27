extends RefCounted
class_name BoidCompute

## The hex-grid army's RenderingDevice manager.
##
## The compute shader (boid_compute.glsl) runs a 4-pass pipeline each frame:
##   pass 0  Clear the density field           (one thread per hex)
##   pass 1  Build density field               (one thread per dot in the update window)
##   pass 2  Compute pressure gradient          (one thread per hex)
##   pass 3  Move dots along paths + liquid     (one thread per dot in the update window)
##
## Buffers mirror boid_compute.glsl bindings 0-8 exactly:
##   0  dot_world_position_buf   vec4[]   dot_count    xyz=world pos, w=hex ID
##   1  dot_velocity_buf         vec4[]   dot_count
##   2  dot_path_buf             int[]    dot_count * MAX_PATH_LENGTH
##   3  dot_path_state_buf       vec4[]   dot_count    x=waypoint idx, y=path len, z=team, w=action
##   4  density_field_buf        float[]  hex_count
##   5  pressure_field_buf       vec4[]   hex_count    xy=gradient
##   6  hex_world_position_buf   vec4[]   hex_count
##   7  hex_adjacency_buf        int[]    hex_count * 32
##   8  params                   struct   6 floats

## Full GPU params struct — mirror of Params in boid_compute.glsl. KEEP IN SYNC.
class SimParams:
	var dot_count: float
	var hex_count: float
	var pass_id: float
	var update_start: float
	var update_count: float
	var delta_time: float
	var hex_radius: float

	func to_buffer() -> PackedFloat32Array:
		return PackedFloat32Array([
			dot_count, hex_count, pass_id,
			update_start, update_count, delta_time,
			hex_radius,
		])

const MAX_PATH_LENGTH := 16
const HEX_ADJ_SLOTS := 32

var _rd: RenderingDevice
var _shader_rid := RID()
var _pipeline_rid := RID()
var _params_rid := RID()
var _pos_rid := RID()        # binding 0: dot_world_position
var _vel_rid := RID()        # binding 1: dot_velocity
var _path_rid := RID()       # binding 2: dot_path
var _path_state_rid := RID() # binding 3: dot_path_state
var _density_rid := RID()    # binding 4: density_field
var _pressure_rid := RID()   # binding 5: pressure_field
var _hex_pos_rid := RID()    # binding 6: hex_world_position
var _hex_adj_rid := RID()    # binding 7: hex_adjacency
var _uniform_set_rid := RID()

var _dot_count: int = 1
var _hex_count: int = 1
var _params := SimParams.new()
var update_batch: int = 100_000
var _update_cursor := 0
var _last_delta_time: float = 0.016
var hex_radius: float = 10.0

var _initialized := false
var _freed := false
var _init_sem := Semaphore.new()

# Stashed for render-thread initialisation (written on main thread, read
# on render thread by _initialize, then discarded).
var _init_pos_data := PackedVector4Array()
var _init_vel_data := PackedVector4Array()
var _init_path_data := PackedInt32Array()
var _init_path_state_data := PackedVector4Array()
var _init_hex_pos_data := PackedVector4Array()
var _init_hex_adj_data := PackedInt32Array()


## Creates all GPU resources on the render thread and blocks until done.
## After this returns, get_pos_rid() is valid and can be handed to the renderer.
##
##   dot_count        number of dots
##   hex_count        number of hex tiles
##   hex_positions    vec4 per hex (xyz=world pos, w=unused) — PackedVector4Array
##   hex_adjacency    int[hex_count * 32], -1 = unused slot
##   seed_positions   vec4 per dot (xyz=world pos, w=hex ID)
##   initial_paths    flat int array, dot_count * MAX_PATH_LENGTH, -1 = unused
##   initial_states   vec4 per dot (waypoint_idx, path_len, team_id, action_state)
func setup(dot_count_: int, hex_count: int,
		hex_positions: PackedVector4Array, hex_adjacency: PackedInt32Array,
		seed_positions: PackedVector4Array,
		initial_paths: PackedInt32Array, initial_states: PackedVector4Array) -> void:
	_dot_count = maxi(dot_count_, 1)
	_hex_count = maxi(hex_count, 1)
	# Stash everything for the render thread.
	_init_pos_data = seed_positions
	_init_vel_data.resize(_dot_count)
	_init_vel_data.fill(Vector4.ZERO)
	_init_path_data = initial_paths
	_init_path_state_data = initial_states
	_init_hex_pos_data = hex_positions
	_init_hex_adj_data = hex_adjacency
	# Block until render thread finishes.
	RenderingServer.call_on_render_thread(_initialize_on_render_thread)
	_init_sem.wait()


func _initialize_on_render_thread() -> void:
	_initialize()
	_init_sem.post()


## Called every frame from the render thread (via BoidRenderEffect).
func record_frame() -> void:
	if not _initialized or _freed:
		return
	var batch := clampi(update_batch, 1, _dot_count)
	if _update_cursor >= _dot_count:
		_update_cursor = 0
	_params.dot_count = float(_dot_count)
	_params.hex_count = float(_hex_count)
	_params.update_start = float(_update_cursor)
	_params.update_count = float(batch)
	_params.delta_time = _last_delta_time
	_params.hex_radius = hex_radius
	# Pass 0: clear density field (hex_count threads)
	_run_pass(0.0, _hex_count)
	# Pass 1: build density field (dot subset)
	_run_pass(1.0, batch)
	# Pass 2: compute pressure gradient (hex_count threads)
	_run_pass(2.0, _hex_count)
	# Pass 3: move dots along paths with liquid physics (dot subset)
	_run_pass(3.0, batch)
	_update_cursor = (_update_cursor + batch) % _dot_count


## Sets the delta time for the next frame's physics. Call from main thread
## before record_frame() runs (e.g. in BoidSwarm._process).
func set_delta_time(dt: float) -> void:
	_last_delta_time = dt


## Pushes updated hex data to the GPU. Called when roads change (new/removed
## connections modify the adjacency graph). Hex positions rarely change, but
## adjacency is rebuilt every time roads are baked.
func update_hex_flow(hex_positions: PackedVector4Array,
		hex_adjacency: PackedInt32Array) -> void:
	if not _initialized or _freed:
		return
	var hp := hex_positions
	var hadj := hex_adjacency
	RenderingServer.call_on_render_thread(func() -> void:
		if _rd == null:
			return
		if hp.size() > 0 and _hex_pos_rid != RID():
			_rd.buffer_update(_hex_pos_rid, 0, hp.size() * 16, hp.to_byte_array())
		if hadj.size() > 0 and _hex_adj_rid != RID():
			_rd.buffer_update(_hex_adj_rid, 0, hadj.size() * 4, hadj.to_byte_array())
	)


## Sets a path for a single dot. Called from the main thread when a dot
## picks up a road route.
func set_dot_path(dot_id: int, path_hex_ids: PackedInt32Array,
		team_id: int, action_state: int) -> void:
	if not _initialized or _freed:
		return
	var path_len := mini(path_hex_ids.size(), MAX_PATH_LENGTH)
	var dot := dot_id
	var team := team_id
	var action := action_state
	var pth := path_hex_ids
	RenderingServer.call_on_render_thread(func() -> void:
		if _rd == null:
			return
		# Write path data (up to MAX_PATH_LENGTH ints).
		var path_bytes := PackedInt32Array()
		path_bytes.resize(MAX_PATH_LENGTH)
		path_bytes.fill(-1)
		for i in range(path_len):
			path_bytes[i] = pth[i]
		var offset := dot * MAX_PATH_LENGTH * 4
		_rd.buffer_update(_path_rid, offset, MAX_PATH_LENGTH * 4, path_bytes.to_byte_array())
		# Write path state: (waypoint_idx=0, path_len, team_id, action_state).
		var state := PackedFloat32Array([0.0, float(path_len), float(team), float(action)])
		var state_offset := dot * 16
		_rd.buffer_update(_path_state_rid, state_offset, 16, state.to_byte_array())
	)


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _run_pass(pass_id: float, threads: int) -> void:
	if not _uniform_set_rid.is_valid():
		return
	_params.pass_id = pass_id
	var buf := _params.to_buffer()
	_rd.buffer_update(_params_rid, 0, buf.size() * 4, buf.to_byte_array())
	var groups := ceili(float(threads) / 64.0)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(list, _uniform_set_rid, 0)
	_rd.compute_list_dispatch(list, groups, 1, 1)
	_rd.compute_list_end()


func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("BoidCompute: no RenderingDevice found (renderer must be Forward+ or Mobile).")
		return

	# binding 0: dot_world_position (vec4 per dot)
	_pos_rid = _rd.storage_buffer_create(_dot_count * 16, _init_pos_data.to_byte_array())
	# binding 1: dot_velocity (vec4 per dot, starts zeroed)
	_vel_rid = _rd.storage_buffer_create(_dot_count * 16, _init_vel_data.to_byte_array())
	# binding 2: dot_path (int[dot_count * MAX_PATH_LENGTH])
	_path_rid = _rd.storage_buffer_create(
		_init_path_data.size() * 4, _init_path_data.to_byte_array())
	# binding 3: dot_path_state (vec4 per dot)
	_path_state_rid = _rd.storage_buffer_create(
		_init_path_state_data.size() * 16, _init_path_state_data.to_byte_array())
	# binding 4: density_field (float per hex, starts zeroed)
	var zero_density := PackedFloat32Array()
	zero_density.resize(_hex_count)
	zero_density.fill(0.0)
	_density_rid = _rd.storage_buffer_create(_hex_count * 4, zero_density.to_byte_array())
	# binding 5: pressure_field (vec4 per hex, starts zeroed)
	var zero_pressure := PackedVector4Array()
	zero_pressure.resize(_hex_count)
	_pressure_rid = _rd.storage_buffer_create(_hex_count * 16, zero_pressure.to_byte_array())
	# binding 6: hex_world_position (vec4 per hex)
	_hex_pos_rid = _rd.storage_buffer_create(
		_init_hex_pos_data.size() * 16, _init_hex_pos_data.to_byte_array())
	# binding 7: hex_adjacency (int[hex_count * 32])
	_hex_adj_rid = _rd.storage_buffer_create(
		_init_hex_adj_data.size() * 4, _init_hex_adj_data.to_byte_array())
	# binding 8: params (7 floats)
	var zero_params := PackedFloat32Array()
	zero_params.resize(7)
	_params_rid = _rd.storage_buffer_create(28, zero_params.to_byte_array())

	# Load and compile shader.
	var shader_file: RDShaderFile = load("res://MainScreen/boid_compute.glsl")
	if shader_file == null:
		push_error("BoidCompute: could not load res://MainScreen/boid_compute.glsl")
		return
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not shader_file.base_error.is_empty():
		push_error("BoidCompute: GLSL base error: %s" % shader_file.base_error)
	if not spirv.compile_error_compute.is_empty():
		push_error("BoidCompute: GLSL compute compile error: %s" % spirv.compile_error_compute)
	_shader_rid = _rd.shader_create_from_spirv(spirv)
	_pipeline_rid = _rd.compute_pipeline_create(_shader_rid)

	# Uniform set — bindings 0-8 exactly matching the shader layout.
	_uniform_set_rid = _rd.uniform_set_create([
		_storage_uniform(_pos_rid, 0),
		_storage_uniform(_vel_rid, 1),
		_storage_uniform(_path_rid, 2),
		_storage_uniform(_path_state_rid, 3),
		_storage_uniform(_density_rid, 4),
		_storage_uniform(_pressure_rid, 5),
		_storage_uniform(_hex_pos_rid, 6),
		_storage_uniform(_hex_adj_rid, 7),
		_storage_uniform(_params_rid, 8),
	], _shader_rid, 0)

	_initialized = true


func _storage_uniform(rid: RID, binding: int) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UniformType.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


## The position SSBO the renderer draws from. Valid after setup() returns.
func get_pos_rid() -> RID:
	return _pos_rid


## The effective dot count after setup() (may be clamped to lattice capacity).
func get_dot_count() -> int:
	return _dot_count


## Frees every RenderingDevice resource (on the render thread).
func teardown() -> void:
	if _freed:
		return
	_freed = true
	if _initialized:
		RenderingServer.call_on_render_thread(_free_resources)


func _free_resources() -> void:
	if _rd == null:
		return
	for rid in [_uniform_set_rid, _pipeline_rid, _shader_rid, _params_rid,
			_pos_rid, _vel_rid, _path_rid, _path_state_rid,
			_density_rid, _pressure_rid, _hex_pos_rid, _hex_adj_rid]:
		if rid != RID():
			_rd.free_rid(rid)
	_uniform_set_rid = RID()
	_pipeline_rid = RID()
	_shader_rid = RID()
	_params_rid = RID()
	_pos_rid = RID()
	_vel_rid = RID()
	_path_rid = RID()
	_path_state_rid = RID()
	_density_rid = RID()
	_pressure_rid = RID()
	_hex_pos_rid = RID()
	_hex_adj_rid = RID()
