extends Node3D
## SPH 3D Fluid Simulation — adapted from deni10000/Godot-3D-SPH-Fluid-Simulation
## Uses compute shaders for Smoothed Particle Hydrodynamics with spatial hashing.

@export var count: int = 40000
@export var radius: float = 0.1 / 8.0
@export var smoothing_radius: float = 0.1
@export var viscosity_multiplier: float = 20.0
@export var sim_length: float = 4.0
@export var sim_width: float = 2.0
@export var sim_height: float = 2.0

var shader_local_size: int = 256
var int_size: int = 4
var hash_oversizing: int = 2
var gravity: float = 0.4
var default_density: float = 10000.0
var pressure_multiply: float = 2.0
var damping: float = 0.3
var mass: float = 100.0

var positions: PackedVector4Array
var pipeline: RID
var sum_pipeline: RID
var uniform_set: RID
var first_step_sum_uniform_set: RID
var second_step_sum_uniform_set: RID

var rd: RenderingDevice

func _ready() -> void:
	rd = RenderingServer.get_rendering_device()
	_init_multimesh()
	set_particles()
	rebuild_buffers()

func _physics_process(delta: float) -> void:
	sim_step(delta)

func set_particles() -> void:
	positions.clear()
	for i in range(count):
		positions.append(Vector4(
			0.3 * randf() * sim_length,
			sim_height - randf() * 0.7,
			randf() * sim_width,
			0))
	rebuild_buffers()

func params_to_byte_array(params: Array) -> PackedByteArray:
	var data: PackedByteArray
	for x in params:
		if x is int:
			var dop: PackedInt32Array = [x]
			data.append_array(dop.to_byte_array())
		else:
			var dop: PackedFloat32Array = [x]
			data.append_array(dop.to_byte_array())
	return data

func get_buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var unif := RDUniform.new()
	unif.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	unif.binding = binding
	unif.add_id(buffer)
	return unif

func _load_compute_shader(path: String) -> RID:
	var f = FileAccess.open(path, FileAccess.READ)
	var text = f.get_as_text()
	f.close()
	var lines = text.split("\n")
	var filtered = PackedStringArray()
	for line in lines:
		if not line.begins_with("#["):
			filtered.append(line)
	var src = RDShaderSource.new()
	src.source_compute = "\n".join(filtered)
	var spirv = rd.shader_compile_spirv_from_source(src)
	if spirv != null:
		print("Compute compile error: '", spirv.compile_error_compute, "'")
	else:
		print("SPIR-V is null")
	return rd.shader_create_from_spirv(spirv)

func _create_dummy_sdf() -> RID:
	# Create a simple 3D texture as a collision SDF (all positive = no collision)
	var fmt := RDTextureFormat.new()
	fmt.width = 8
	fmt.height = 8
	fmt.depth = 8
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var tex = rd.texture_create(fmt, RDTextureView.new())
	# Fill with positive values (no collision)
	var data = PackedByteArray()
	data.resize(8 * 8 * 8 * 4)
	for i in range(8 * 8 * 8):
		data.encode_float(i * 4, 0.5)
	rd.texture_update(tex, 0, data)
	return tex

func rebuild_buffers() -> void:
	if not is_inside_tree():
		return

	# Create multimesh
	var mm: MultiMesh = $MultiMeshInstance3D.multimesh
	if mm == null:
		mm = MultiMesh.new()
		mm.use_colors = true
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.instance_count = count
		var sphere := SphereMesh.new()
		sphere.radius = radius
		sphere.height = 2.0 * radius
		sphere.radial_segments = 8
		sphere.rings = 4
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		sphere.material = mat
		mm.mesh = sphere
		$MultiMeshInstance3D.multimesh = mm
	else:
		mm.instance_count = count

	var aabb = AABB($MultiMeshInstance3D.global_position, Vector3(sim_length * 8, sim_height * 8, sim_width * 8))
	mm.custom_aabb = aabb
	$MultiMeshInstance3D.multimesh = mm

	var mm_rid = RenderingServer.multimesh_get_buffer_rd_rid(mm.get_rid())

	# Compile compute shaders
	var shader = _load_compute_shader("res://Demos/sph_fluid/compute_fluid.glsl")
	pipeline = rd.compute_pipeline_create(shader)

	var sum_shader = _load_compute_shader("res://Demos/sph_fluid/pref_sum.glsl")
	sum_pipeline = rd.compute_pipeline_create(sum_shader)

	# Prefix sum buffers
	var pref_sum_hash_count_buffer = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	var pref_sum_hash_count_buffer2 = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	var unif1 := get_buffer_uniform(0, pref_sum_hash_count_buffer)
	var unif2 := get_buffer_uniform(1, pref_sum_hash_count_buffer2)
	first_step_sum_uniform_set = rd.uniform_set_create([unif1, unif2], sum_shader, 0)
	unif1.binding = 1
	unif2.binding = 0
	second_step_sum_uniform_set = rd.uniform_set_create([unif1, unif2], sum_shader, 0)

	# Particle buffers
	var data = positions.to_byte_array()
	var positions_buffer = rd.storage_buffer_create(data.size(), data)
	var predicated_positions_buffer = rd.storage_buffer_create(data.size())
	var velocity_buffer = rd.storage_buffer_create(data.size())
	var density_buffer = rd.storage_buffer_create(int_size * positions.size())
	var hash_count_buffer = rd.storage_buffer_create(int_size * hash_oversizing * positions.size())
	var hash_indexes_buffer = rd.storage_buffer_create(int_size * positions.size())
	var force_buffer = rd.storage_buffer_create(data.size())

	# SDF sampler
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var sampler_rid: RID = rd.sampler_create(sampler_state)

	var dummy_sdf = _create_dummy_sdf()
	var sdf_uniform := RDUniform.new()
	sdf_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	sdf_uniform.binding = 11
	sdf_uniform.add_id(sampler_rid)
	sdf_uniform.add_id(dummy_sdf)

	# Build uniform set
	var positions_uniform = get_buffer_uniform(0, positions_buffer)
	var predicated_positions_uniform = get_buffer_uniform(1, predicated_positions_buffer)
	var velocity_uniform = get_buffer_uniform(2, velocity_buffer)
	var density_uniform = get_buffer_uniform(3, density_buffer)
	var hash_count_uniform = get_buffer_uniform(4, hash_count_buffer)
	var pref_sum_hash_count_uniform = get_buffer_uniform(5, pref_sum_hash_count_buffer)
	var hash_indexes_uniform = get_buffer_uniform(6, hash_indexes_buffer)
	var pref_sum_hash_count_uniform2 = get_buffer_uniform(7, pref_sum_hash_count_buffer2)
	var force_buffer_uniform = get_buffer_uniform(9, force_buffer)
	var mm_uniform = get_buffer_uniform(10, mm_rid)

	uniform_set = rd.uniform_set_create([
		positions_uniform,
		predicated_positions_uniform,
		velocity_uniform,
		density_uniform,
		hash_count_uniform,
		pref_sum_hash_count_uniform,
		hash_indexes_uniform,
		pref_sum_hash_count_uniform2,
		force_buffer_uniform,
		mm_uniform,
		sdf_uniform,
	], shader, 0)

func sim_step(delta: float) -> void:
	if not rd or not uniform_set.is_valid():
		return

	var global_size: int = (count / shader_local_size) + 1
	var hash_size: int = ((count * hash_oversizing) / shader_local_size) + 1
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	var params = [0, radius, smoothing_radius, gravity, default_density, pressure_multiply,
		damping, count, count * hash_oversizing, mass, delta, sim_length, sim_width, sim_height,
		viscosity_multiplier, 0, 0, 0, 0, 0]
	var data: PackedByteArray

	# Case 0: Clear hash buffer
	params[0] = 0
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, hash_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)

	# Case 1: Predict positions & fill hash count
	params[0] = 1
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)

	# Prefix sum
	rd.compute_list_bind_compute_pipeline(compute_list, sum_pipeline)
	var step = 1
	var ln = count * hash_oversizing * 2
	var i = 1
	while step < ln:
		if i % 2:
			rd.compute_list_bind_uniform_set(compute_list, first_step_sum_uniform_set, 0)
		else:
			rd.compute_list_bind_uniform_set(compute_list, second_step_sum_uniform_set, 0)
		i += 1
		data = params_to_byte_array([step, 0, 0, 0])
		rd.compute_list_set_push_constant(compute_list, data, data.size())
		rd.compute_list_dispatch(compute_list, hash_size, 1, 1)
		rd.compute_list_add_barrier(compute_list)
		step *= 2

	# Rebind main pipeline
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	# Case 2: Fill hash indexes
	params[0] = 2
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)

	# Case 4: Compute density
	params[0] = 4
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)

	# Case 5: Compute forces
	params[0] = 5
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)

	# Case 6: Correct & draw
	params[0] = 6
	data = params_to_byte_array(params)
	rd.compute_list_set_push_constant(compute_list, data, data.size())
	rd.compute_list_dispatch(compute_list, global_size, 1, 1)
	rd.compute_list_add_barrier(compute_list)

	rd.compute_list_end()

func _init_multimesh() -> void:
	if not has_node("MultiMeshInstance3D"):
		var mm_node = MultiMeshInstance3D.new()
		mm_node.name = "MultiMeshInstance3D"
		add_child(mm_node)
		mm_node.owner = get_tree().edited_scene_root if Engine.is_editor_hint() else null
