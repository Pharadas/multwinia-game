extends MultiMeshInstance3D

@export var count_shader_file: RDShaderFile
@export var prefixsum_shader_file: RDShaderFile
@export var scatter_shader_file: RDShaderFile
@export var sim_shader_file: RDShaderFile
@export var render_shader_file: RDShaderFile

const CELL_SIZE := 5.0
const MAX_SPEED := 4.0
const WORLD_MIN := Vector3(-300, 10 , -170)
const WORLD_MAX := Vector3(300, 100, 170)

## Must match HexTerrain's hex_size / mesh_scale so world-space hex
## boundaries line up with the actual terrain grid. Set these (e.g. from
## the spawner, right after instantiate() and before add_child()) whenever
## the terrain doesn't use the defaults of 1.0.
@export var hex_size := 1.0
@export var mesh_scale := 10.0
@export var hex_grid_width := 20   # must match hex_terrain.grid_width
@export var hex_grid_depth := 20  # must match hex_terrain.grid_depth

var rd: RenderingDevice
var instance_count: int
var total_groups: int
var table_size: int
var grid_dims: Vector3i

# shader + pipeline RIDs
var shader_rids: Dictionary = {}    # name -> RID
var pipeline_rids: Dictionary = {}  # name -> RID

# data buffers
var state_buffers: Array[RID] = []      # [0], [1]
var cell_count_rid: RID
var cell_offset_rid: RID
var write_cursor_rid: RID
var sorted_indices_rid: RID
var mm_buffer_rid: RID
var cell_info_rid: RID
var global_paths_rid: RID

# uniform sets, ping-ponged where needed
var uniform_sets_count: Array[RID] = []
var uniform_set_prefixsum: RID
var uniform_sets_scatter: Array[RID] = []
var uniform_sets_sim: Array[RID] = []
var uniform_sets_render: Array[RID] = []

# hex grid bounds (computed in _ready), in OFFSET (col, row) space - the
# same space HexTerrain.hex_nodes is keyed by.
var hex_min_q := 0   # min offset col (kept name to minimize churn elsewhere)
var hex_min_r := 0   # min offset row
var hex_width := 0
var hex_total_cells := 0

var frame_parity := 0
var team_bases: Array = []


func _ready() -> void:
	instance_count = multimesh.instance_count
	total_groups = ceili(instance_count / 64.0)

	var world_size := WORLD_MAX - WORLD_MIN
	grid_dims = Vector3i(
		ceili(world_size.x / CELL_SIZE),
		ceili(world_size.y / CELL_SIZE),
		ceili(world_size.z / CELL_SIZE)
	)
	table_size = grid_dims.x * grid_dims.y * grid_dims.z

	# compute hex grid bounds from world corners (offset col/row space)
	var tl = world_to_hex(Vector2(WORLD_MIN.x, WORLD_MIN.z))
	var tr = world_to_hex(Vector2(WORLD_MAX.x, WORLD_MIN.z))
	var bl = world_to_hex(Vector2(WORLD_MIN.x, WORLD_MAX.z))
	var br = world_to_hex(Vector2(WORLD_MAX.x, WORLD_MAX.z))
	hex_min_q = mini(mini(tl.x, tr.x), mini(bl.x, br.x))
	hex_min_r = mini(mini(tl.y, tr.y), mini(bl.y, br.y))
	var hex_max_q = maxi(maxi(tl.x, tr.x), maxi(bl.x, br.x))
	var hex_max_r = maxi(maxi(tl.y, tr.y), maxi(bl.y, br.y))
	hex_width = hex_max_q - hex_min_q + 1
	hex_total_cells = hex_width * (hex_max_r - hex_min_r + 1)
	print("Hex grid: col=[%d..%d] row=[%d..%d] width=%d total=%d" % [hex_min_q, hex_max_q, hex_min_r, hex_max_r, hex_width, hex_total_cells])

	rd = RenderingServer.get_rendering_device()

	_load_shaders()
	_create_pipelines()
	_create_buffers()
	_compute_team_bases()
	for t in range(4):
		_spawn_team_army(t)
	_build_uniform_sets()
	_initial_dispatch()


func _initial_dispatch() -> void:
	# Run the full pipeline once at startup so mm_buffer has real positions
	# before Godot renders the first frame (avoids center flash from garbage data).
	rd.buffer_clear(cell_count_rid, 0, table_size * 4)
	var push_bytes := _build_push_constants(0.0)
	var cl = rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["count"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_count[0], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["prefixsum"])
	rd.compute_list_bind_uniform_set(cl, uniform_set_prefixsum, 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["scatter"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_scatter[0], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["sim"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_sim[0], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["render"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_render[0], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)

	rd.compute_list_end()
	frame_parity = 1


func _load_shaders() -> void:
	var files := {
		"count": count_shader_file,
		"prefixsum": prefixsum_shader_file,
		"scatter": scatter_shader_file,
		"sim": sim_shader_file,
		"render": render_shader_file,
	}
	for name in files:
		var f: RDShaderFile = files[name]
		var spirv: RDShaderSPIRV = f.get_spirv()
		if spirv == null:
			push_error("%s: failed to get SPIR-V" % name)
			continue
		var err_text := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if err_text != "":
			push_error("%s: GLSL compile error: %s" % [name, err_text])
			continue
		shader_rids[name] = rd.shader_create_from_spirv(spirv)


func _create_pipelines() -> void:
	for name in shader_rids:
		pipeline_rids[name] = rd.compute_pipeline_create(shader_rids[name])


func _create_buffers() -> void:
	var cell_hexes := PackedInt32Array()
	cell_hexes.resize(table_size)

	# --- initalize grid values ---
	for i in range(table_size):
		var cell = Vector3(
			i % grid_dims.x,
			(i / grid_dims.x) % grid_dims.y,
			i / (grid_dims.x * grid_dims.y)
		)

		var world_pos = Vector2(cell.x + 0.5, cell.y + 0.5) * CELL_SIZE + Vector2(WORLD_MIN.x, WORLD_MIN.z)
		# Same world_to_hex call, same units, as the per-boid hex id below -
		# no more silent /10.0 rescale between the two.
		var hex = world_to_hex(world_pos)
		var id = hex_to_id(hex.x, hex.y)
		cell_hexes[i] = id

	var cell_hexes_bytes := cell_hexes.to_byte_array()

	#print(len(cell_hexes_bytes), " ", table_size)
	cell_info_rid = rd.storage_buffer_create(table_size * 4, cell_hexes_bytes)

	# std430 pads {vec4 pos; vec4 vel; uint state;} to 48 bytes (rounds up to 16-byte multiple)
	var floats_per_boid := 12  # 4 (pos) + 4 (vel) + 1 (state) + 3 padding floats
	var state_bytes := instance_count * floats_per_boid * 4  # 48 bytes/boid

	var init_state := PackedFloat32Array()
	init_state.resize(instance_count * floats_per_boid)

	for i in range(instance_count):
		var team := i % 4
		var base := i * floats_per_boid
		var p := Vector3(
			randf_range(WORLD_MIN.x, WORLD_MAX.x),
			randf_range(WORLD_MIN.y, WORLD_MAX.y),
			randf_range(WORLD_MIN.z, WORLD_MAX.z)
		)
		var v := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized() * randf_range(1.0, MAX_SPEED)
		init_state[base + 0] = p.x
		init_state[base + 1] = p.y
		init_state[base + 2] = p.z
		init_state[base + 3] = 0.0
		init_state[base + 4] = v.x
		init_state[base + 5] = 0.0 #v.y
		init_state[base + 6] = v.z
		init_state[base + 7] = 0.0

		# hex id
		var bytes = PackedByteArray()
		bytes.resize(4)
		var hex = world_to_hex(Vector2(p.x, p.z))
		bytes.encode_u32(0, hex_to_id(hex.x, hex.y))
		init_state[base + 8] = bytes.decode_float(0)

		# assigned_path_hex (0xFFFFFFFF = NO_PATH)
		var no_path_bytes := PackedByteArray()
		no_path_bytes.resize(4)
		no_path_bytes.encode_u32(0, 0xFFFFFFFF)
		init_state[base + 9] = no_path_bytes.decode_float(0)
		init_state[base + 10] = 0.0  # assigned_path_slot
		init_state[base + 11] = float(team)  # team (0, 1, 2, or 3)


	var init_bytes := init_state.to_byte_array()
	#print(init_bytes)

	state_buffers.append(rd.storage_buffer_create(state_bytes, init_bytes))
	state_buffers.append(rd.storage_buffer_create(state_bytes, init_bytes))
	# --- grid buffers, zero-initialized, sized exactly to grid_dims ---
	cell_count_rid = rd.storage_buffer_create(table_size * 4)
	cell_offset_rid = rd.storage_buffer_create(table_size * 4)
	write_cursor_rid = rd.storage_buffer_create(table_size * 4)
	sorted_indices_rid = rd.storage_buffer_create(instance_count * 4)

	# Global paths: 4 teams per hex cell. Each team-hex has HexPaths struct (1368B)
	var num_cells := hex_total_cells if hex_total_cells > 0 else (hex_grid_width * hex_grid_depth)
	var global_paths_bytes := PackedByteArray()
	global_paths_bytes.resize(num_cells * 4 * 1368)
	global_paths_rid = rd.storage_buffer_create(global_paths_bytes.size(), global_paths_bytes)

	mm_buffer_rid = RenderingServer.multimesh_get_buffer_rd_rid(multimesh.get_rid())


func _make_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


func _build_uniform_sets() -> void:
	for parity in range(2):
		var other = 1 - parity

		# count.glsl: binding0=state(read), binding1=cell_count
		uniform_sets_count.append(rd.uniform_set_create(
			[_make_uniform(0, state_buffers[parity]), _make_uniform(1, cell_count_rid)],
			shader_rids["count"], 0
		))

		# scatter.glsl: binding0=state(read), binding1=write_cursor, binding2=sorted_idx
		uniform_sets_scatter.append(rd.uniform_set_create(
			[_make_uniform(0, state_buffers[parity]), _make_uniform(1, write_cursor_rid), _make_uniform(2, sorted_indices_rid)],
			shader_rids["scatter"], 0
		))

		# sim.glsl: binding0=read_state,1=write_state,2=cell_offset,3=cell_count,4=sorted_idx
		uniform_sets_sim.append(rd.uniform_set_create(
			[
				_make_uniform(0, state_buffers[parity]),
				_make_uniform(1, state_buffers[other]),
				_make_uniform(2, cell_offset_rid),
				_make_uniform(3, cell_count_rid),
				_make_uniform(4, sorted_indices_rid),
				_make_uniform(5, cell_info_rid),
				_make_uniform(6, global_paths_rid)
			],
			shader_rids["sim"], 0
		))

		# render.glsl: binding0 = freshly-simulated state (state_buffers[other] after sim writes it), binding1=mm_buffer
		uniform_sets_render.append(rd.uniform_set_create(
			[_make_uniform(0, state_buffers[other]), _make_uniform(1, mm_buffer_rid)],
			shader_rids["render"], 0
		))

	# prefixsum.glsl: binding0=cell_count,1=cell_offset,2=write_cursor — no ping-pong dependency
	uniform_set_prefixsum = rd.uniform_set_create(
		[_make_uniform(0, cell_count_rid), _make_uniform(1, cell_offset_rid), _make_uniform(2, write_cursor_rid)],
		shader_rids["prefixsum"], 0
	)


func _build_push_constants(delta: float) -> PackedByteArray:
	# Must match the GLSL struct exactly, in all 5 shaders:
	# vec4 params      (dt, instance_count, cell_size, unused)
	# vec4 world_min   (x, y, z, unused)
	# ivec4 grid_dims  (x, y, z, unused)
	# vec4 hex_params  (hex_size, mesh_scale, min_q, min_r)
	# ivec4 hex_grid   (grid_width, grid_depth, hex_width, -)
	var floats := PackedFloat32Array([
		delta, float(instance_count), CELL_SIZE, 0.0,
		WORLD_MIN.x, WORLD_MIN.y, WORLD_MIN.z, 0.0,
	])
	var bytes := floats.to_byte_array()

	var ints := PackedInt32Array([grid_dims.x, grid_dims.y, grid_dims.z, 0])
	bytes.append_array(ints.to_byte_array())

	var hex_floats := PackedFloat32Array([
		hex_size, mesh_scale, float(hex_min_q), float(hex_min_r)
	])
	bytes.append_array(hex_floats.to_byte_array())

	var hex_ints := PackedInt32Array([hex_grid_width, hex_grid_depth, hex_width, 0])
	bytes.append_array(hex_ints.to_byte_array())

	return bytes


func _process(delta: float) -> void:
	var read_i = frame_parity
	var write_i = 1 - frame_parity

	rd.buffer_clear(cell_count_rid, 0, table_size * 4)

	var push_bytes := _build_push_constants(delta)

	var cl = rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["count"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_count[read_i], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["prefixsum"])
	rd.compute_list_bind_uniform_set(cl, uniform_set_prefixsum, 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["scatter"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_scatter[read_i], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["sim"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_sim[read_i], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["render"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_render[read_i], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)

	rd.compute_list_end()
	frame_parity = write_i


func _exit_tree() -> void:
	if not rd:
		return
	for name in pipeline_rids:
		rd.free_rid(pipeline_rids[name])
	for name in shader_rids:
		rd.free_rid(shader_rids[name])
	for rid in state_buffers:
		rd.free_rid(rid)
	rd.free_rid(cell_count_rid)
	rd.free_rid(cell_offset_rid)
	rd.free_rid(write_cursor_rid)
	rd.free_rid(sorted_indices_rid)
	for rid in uniform_sets_count: rd.free_rid(rid)
	for rid in uniform_sets_scatter: rd.free_rid(rid)
	for rid in uniform_sets_sim: rd.free_rid(rid)
	for rid in uniform_sets_render: rd.free_rid(rid)
	rd.free_rid(uniform_set_prefixsum)


## Returns the offset hex coordinates Vector2i(col, row) for a given 2D
## world position, using FLAT-TOP axial math and matching HexTerrain's
## hex_nodes keying (odd-q: odd columns are shifted down half a row).
## Effective hex size accounts for mesh_scale so this lines up with the
## terrain's real world-space hex boundaries, not just its pre-scale units.
func world_to_hex(world_pos: Vector2) -> Vector2i:
	var SQRT_3 := sqrt(3.0)
	var horiz_spacing := hex_size * 1.5
	var vert_spacing := SQRT_3 * hex_size

	var total_width := float(hex_grid_width - 1) * horiz_spacing
	var total_depth := float(hex_grid_depth) * vert_spacing

	# Undo mesh_scale, then undo the -total_width/2 / -total_depth/2 offset
	var u := world_pos.x / mesh_scale + total_width * 0.5
	var v := world_pos.y / mesh_scale + total_depth * 0.5

	# Axial coordinates (flat-top)
	var q: float = (2.0 / 3.0 * u) / hex_size
	var r: float = (-1.0 / 3.0 * u + SQRT_3 / 3.0 * v) / hex_size
	var s: float = -q - r

	# Cube round
	var rq: int = roundi(q)
	var rr: int = roundi(r)
	var rs: int = roundi(s)

	var q_diff: float = abs(float(rq) - q)
	var r_diff: float = abs(float(rr) - r)
	var s_diff: float = abs(float(rs) - s)

	if q_diff > r_diff and q_diff > s_diff:
		rq = -rr - rs
	elif r_diff > s_diff:
		rr = -rq - rs

	var col := rq
	var row := rr + (rq - (rq & 1)) / 2

	return Vector2i(col, row)


func hex_to_id(col: int, row: int) -> int:
	return (col - hex_min_q) + (row - hex_min_r) * hex_width


func id_to_hex(id: int) -> Vector2i:
	return Vector2i(
		id % hex_width + hex_min_q,
		id / hex_width + hex_min_r
	)
var _hex_path_counts: Dictionary = {}

## Set the number of available paths stored for a given hex cell and team.
func set_hex_path_count(col: int, row: int, team: int, path_count: int) -> void:
	team = clampi(team, 0, 3)
	var hex_id := hex_to_id(col, row)
	var team_hex_key := "%d_%d" % [hex_id, team]
	_hex_path_counts[team_hex_key] = path_count

	var team_hex_idx := hex_id * 4 + team
	var hex_offset := team_hex_idx * 1368
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_s32(0, path_count)
	var total_max := (hex_total_cells if hex_total_cells > 0 else hex_grid_width * hex_grid_depth) * 4 * 1368
	if hex_offset + 4 <= total_max:
		rd.buffer_update(global_paths_rid, hex_offset, buf.size(), buf)


## Write a global path of world-space Vector2 points for a hex cell, team, and path slot.
## `points` is an Array of Vector2 (xz positions in main view world space).
func set_path(points: Array, col: int = 0, row: int = 0, team: int = 0, path_slot: int = -1, total_hex_paths: int = -1) -> void:
	if points.is_empty():
		return

	team = clampi(team, 0, 3)

	# Extract start point
	var p0: Vector2
	if points[0] is Vector2:
		p0 = points[0]
	elif points[0] is Vector2i:
		p0 = Vector2(points[0].x, points[0].y)
	elif points[0] is Dictionary:
		p0 = Vector2(float(points[0].get("x", 0.0)), float(points[0].get("y", 0.0)))
	else:
		p0 = Vector2.ZERO

	# Auto-detect starting hex if col/row are defaulted to (0,0)
	if col == 0 and row == 0:
		var start_hex := world_to_hex(p0)
		col = start_hex.x
		row = start_hex.y

	var hex_id := hex_to_id(col, row)
	var team_hex_key := "%d_%d" % [hex_id, team]

	if path_slot < 0:
		var current_cnt: int = _hex_path_counts.get(team_hex_key, 0)
		path_slot = current_cnt % 10
		total_hex_paths = min(current_cnt + 1, 10)
		_hex_path_counts[team_hex_key] = total_hex_paths
	else:
		path_slot = clampi(path_slot, 0, 9)
		if total_hex_paths < 0:
			total_hex_paths = max(path_slot + 1, _hex_path_counts.get(team_hex_key, 1))
		_hex_path_counts[team_hex_key] = total_hex_paths

	var team_hex_idx := hex_id * 4 + team
	var hex_offset := team_hex_idx * 1368
	var total_max := (hex_total_cells if hex_total_cells > 0 else hex_grid_width * hex_grid_depth) * 4 * 1368

	# Update the team-hex's path_count
	var count_buf := PackedByteArray()
	count_buf.resize(4)
	count_buf.encode_s32(0, total_hex_paths)
	if hex_offset + 4 <= total_max:
		rd.buffer_update(global_paths_rid, hex_offset, count_buf.size(), count_buf)

	# GLSL layout for Path struct: vec2 points[16] (128 bytes) + int count (4 bytes) = 132, padded to 136
	var buf := PackedByteArray()
	buf.resize(136)
	var count := mini(points.size(), 16)
	for i in range(count):
		var p: Vector2
		if points[i] is Vector2:
			p = points[i]
		elif points[i] is Vector2i:
			p = Vector2(points[i].x, points[i].y)
		elif points[i] is Dictionary:
			p = Vector2(float(points[i].get("x", 0.0)), float(points[i].get("y", 0.0)))
		else:
			p = Vector2.ZERO
		buf.encode_float(i * 8, p.x)
		buf.encode_float(i * 8 + 4, p.y)
	# int count at byte offset 128
	buf.encode_s32(128, count)

	var path_offset := hex_offset + 8 + path_slot * 136
	if path_offset + buf.size() <= total_max:
		rd.buffer_update(global_paths_rid, path_offset, buf.size(), buf)


## Computes the four corner base rectangles for the ACTUAL grid, so every
## team always spawns in a real corner regardless of grid_width/grid_depth.
## Returns the world-space Vector3 center of hex cell (col, row).
func get_hex_center(col: int, row: int) -> Vector3:
	var SQRT_3 := sqrt(3.0)
	var horiz_spacing := hex_size * 1.5
	var vert_spacing := SQRT_3 * hex_size
	var total_width := float(hex_grid_width - 1) * horiz_spacing
	var total_depth := float(hex_grid_depth) * vert_spacing

	# offset (col,row) -> axial (q,r)
	var q := col
	var r := row - (col - (col & 1)) / 2

	# axial -> pixel (flat-top)
	var u := hex_size * (3.0 / 2.0 * float(q))
	var v := hex_size * (SQRT_3 / 2.0 * float(q) + SQRT_3 * float(r))

	# apply mesh_scale and center offset (inverse of world_to_hex)
	var wx := (u - total_width * 0.5) * mesh_scale
	var wz := (v - total_depth * 0.5) * mesh_scale

	return Vector3(wx, WORLD_MIN.y, wz)

## Computes the four corner base rectangles for the ACTUAL grid, so every
## team always spawns in a real corner regardless of grid_width/grid_depth.
func _compute_team_bases() -> void:
	var bw := 3 # base width in tiles
	var bh := 2 # base height in tiles
	var max_c := hex_grid_width - 1
	var max_r := hex_grid_depth - 1
	team_bases = [
		[1, 1, bw, bh],                                    # team 0 - top-left
		[max_c - bw, 1, max_c - 1, bh],                    # team 1 - top-right
		[max_c - bw, max_r - bh, max_c - 1, max_r - 1],    # team 2 - bottom-right
		[1, max_r - bh, bw, max_r - 1],                    # team 3 - bottom-left
	]


## Drops `team`'s starting units into its walled corner base.
func _spawn_team_army(team: int) -> void:
	# Collect spawn tiles for this team's corner base.
	var base: Array = team_bases[team]
	var spawn_tiles: Array = []
	for c in range(base[0], base[2] + 1):
		for r in range(base[1], base[3] + 1):
			if c == base[0] and r == base[1]:
				continue # skip the generator tile
			spawn_tiles.append(Vector2i(c, r))

	# Find all boids belonging to this team (boid i has team = i % 4).
	var team_boids: Array = []
	for i in range(instance_count):
		if i % 4 == team:
			team_boids.append(i)

	var jitter := mesh_scale * 0.3
	var floats_per_boid := 12

	for bi in range(team_boids.size()):
		var boid_id: int = team_boids[bi]
		var cell: Vector2i = spawn_tiles[bi % spawn_tiles.size()]
		var center := get_hex_center(cell.x, cell.y)
		var offset := Vector3(randf_range(-jitter, jitter), randf_range(0.0, 4.0), randf_range(-jitter, jitter))
		var pos := center + offset

		var hex := world_to_hex(Vector2(pos.x, pos.z))
		var hex_id := hex_to_id(hex.x, hex.y)

		# Build a single boid row as floats, matching the state buffer layout.
		var row := PackedFloat32Array()
		row.resize(floats_per_boid)
		row[0] = pos.x
		row[1] = pos.y
		row[2] = pos.z
		# hex_id stored as raw uint32 reinterpreted as float
		var hb := PackedByteArray()
		hb.resize(4)
		hb.encode_u32(0, hex_id)
		row[3] = hb.decode_float(0)
		# vel = zero
		row[4] = 0.0
		row[5] = 0.0
		row[6] = 0.0
		row[7] = 0.0
		# state = 0
		row[8] = 0.0
		# assigned_path_hex = 0xFFFFFFFF (NO_PATH)
		var np := PackedByteArray()
		np.resize(4)
		np.encode_u32(0, 0xFFFFFFFF)
		row[9] = np.decode_float(0)
		# assigned_path_slot = 0
		row[10] = 0.0
		# team
		row[11] = float(team)

		var buf := row.to_byte_array()
		var byte_offset := boid_id * floats_per_boid * 4
		for sbuf in state_buffers:
			rd.buffer_update(sbuf, byte_offset, buf.size(), buf)
