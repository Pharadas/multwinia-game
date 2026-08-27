extends RefCounted
class_name SeiqrSpatialHash

## SEIIQR's spatial hash as a Godot compute pipeline, owned by a SeiqrSwarm.
##
## Every frame it runs the five passes of seiqr_spatial_hash.glsl over the
## swarm's dots (clear -> count -> prefix -> fill -> search) and writes each
## dot's result - neighbor count + centroid - into an RGBA32F texture with
## one texel per dot. The particle shader samples that texture and reacts
## (separation), so dots find their nearby dots entirely on the GPU.
##
## Everything here runs on the RENDER thread via
## RenderingServer.call_on_render_thread (a blocking handoff), following
## Godot's official compute texture demo: the main RenderingDevice is driven
## by the render thread, so recording compute lists anywhere else races with
## the frame. We never call submit()/sync() - the engine flushes the
## recorded lists as part of the frame and its default barriers order the
## passes for us.

var _rd: RenderingDevice
var _shader_rid := RID()
var _pipeline_rid := RID()
var _params_rid := RID()
var _counts_rid := RID()
var _counters_rid := RID()
var _lists_rid := RID()
var _out_tex_rid := RID()
var _out_tex: Texture2DRD
var _uniform_set_rid := RID()

var _dot_count: int = 1
var _grid_w: int = 16
var _initialized := false
var _freed := false


## Creates all GPU resources (on the render thread; blocks until done). After
## this returns, get_texture() is ready to bind to the particle material.
func setup(amount: int, grid_w: int = 16, _neighbor_radius: float = 2.0) -> void:
	_dot_count = maxi(amount, 1)
	_grid_w = grid_w
	RenderingServer.call_on_render_thread(_initialize)


## Queues this frame's five dispatches on the render thread. Call once per
## frame from _process; the results are written before the frame renders.
func update(objective: Vector3, sim_time: float, neighbor_radius: float,
		half_extent: float) -> void:
	if not _initialized or _freed:
		return
	RenderingServer.call_on_render_thread(_run_frame.bind(
		objective.x, objective.y, objective.z,
		sim_time, neighbor_radius, half_extent))


func _initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("SeiqrSpatialHash: no RenderingDevice found (renderer must be Forward+ or Mobile).")
		return

	# Params: 9 floats, rewritten every frame.
	var params := PackedFloat32Array()
	params.resize(9)
	_params_rid = _rd.storage_buffer_create(params.size() * 4, params.to_byte_array())

	var ncells := _grid_w * _grid_w
	var zero_bytes := PackedByteArray()
	zero_bytes.resize(ncells * 4)
	_counts_rid = _rd.storage_buffer_create(ncells * 4, zero_bytes)
	_counters_rid = _rd.storage_buffer_create(ncells * 4, zero_bytes)
	zero_bytes.resize(_dot_count * 4)
	_lists_rid = _rd.storage_buffer_create(_dot_count * 4, zero_bytes)

	# Per-dot result texture: one rgba32f texel per dot, written by the
	# compute shader, sampled by the particle shader. Zero-initialized so the
	# particle shader reads "no neighbors" before the first dispatch (e.g.
	# during the swarm's preprocess), instead of garbage memory.
	var zero_tex := PackedByteArray()
	zero_tex.resize(_dot_count * 16) # rgba32f = 16 bytes per texel
	# (RDTextureFormat defaults: 2D, 1 sample, 1 mip, depth/layers 1.)
	var tex_format := RDTextureFormat.new()
	tex_format.format = RenderingDevice.DataFormat.DATA_FORMAT_R32G32B32A32_SFLOAT
	tex_format.usage_bits = RenderingDevice.TextureUsageBits.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TextureUsageBits.TEXTURE_USAGE_SAMPLING_BIT
	tex_format.width = _dot_count
	_out_tex_rid = _rd.texture_create(tex_format, RDTextureView.new(), [zero_tex])
	_out_tex = Texture2DRD.new()
	_out_tex.texture_rd_rid = _out_tex_rid

	var shader_file: RDShaderFile = load("res://MainScreen/seiqr_spatial_hash.glsl")
	if shader_file == null:
		push_error("SeiqrSpatialHash: could not load res://MainScreen/seiqr_spatial_hash.glsl")
		return
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not shader_file.base_error.is_empty():
		push_error("SeiqrSpatialHash: GLSL base error: %s" % shader_file.base_error)
	if not spirv.compile_error_compute.is_empty():
		push_error("SeiqrSpatialHash: GLSL compute compile error: %s" % spirv.compile_error_compute)
	_shader_rid = _rd.shader_create_from_spirv(spirv)
	_pipeline_rid = _rd.compute_pipeline_create(_shader_rid)

	var u_params := RDUniform.new()
	u_params.uniform_type = RenderingDevice.UniformType.UNIFORM_TYPE_STORAGE_BUFFER
	u_params.binding = 0
	u_params.add_id(_params_rid)

	var u_counts := RDUniform.new()
	u_counts.uniform_type = RenderingDevice.UniformType.UNIFORM_TYPE_STORAGE_BUFFER
	u_counts.binding = 1
	u_counts.add_id(_counts_rid)

	var u_counters := RDUniform.new()
	u_counters.uniform_type = RenderingDevice.UniformType.UNIFORM_TYPE_STORAGE_BUFFER
	u_counters.binding = 2
	u_counters.add_id(_counters_rid)

	var u_lists := RDUniform.new()
	u_lists.uniform_type = RenderingDevice.UniformType.UNIFORM_TYPE_STORAGE_BUFFER
	u_lists.binding = 3
	u_lists.add_id(_lists_rid)

	var u_image := RDUniform.new()
	u_image.uniform_type = RenderingDevice.UniformType.UNIFORM_TYPE_IMAGE
	u_image.binding = 4
	u_image.add_id(_out_tex_rid)

	_uniform_set_rid = _rd.uniform_set_create(
		[u_params, u_counts, u_counters, u_lists, u_image], _shader_rid, 0)

	_initialized = true


func _run_frame(ox: float, oy: float, oz: float, sim_time: float,
		neighbor_radius: float, half_extent: float) -> void:
	if not _initialized or not _pipeline_rid.is_valid():
		return
	var params := PackedFloat32Array([
		ox, oy, oz, 0.0,
		neighbor_radius, half_extent, float(_grid_w), float(_dot_count), sim_time,
	])
	_run(params, 0.0, _grid_w * _grid_w)
	_run(params, 1.0, _dot_count)
	_run(params, 2.0, 1)
	_run(params, 3.0, _dot_count)
	_run(params, 4.0, _dot_count)


func _run(params: PackedFloat32Array, pass_id: float, threads: int) -> void:
	params[3] = pass_id
	_rd.buffer_update(_params_rid, 0, params.size() * 4, params.to_byte_array())
	var groups := ceili(float(threads) / 64.0)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline_rid)
	_rd.compute_list_bind_uniform_set(list, _uniform_set_rid, 0)
	_rd.compute_list_dispatch(list, groups, 1, 1)
	_rd.compute_list_end()
	# No submit()/sync(): only local devices may do that. On the main
	# RenderingDevice the engine flushes these lists as part of the frame
	# and its default barriers order the passes.


## The per-dot result texture to bind to the particle shader's
## neighbor_tex sampler. Valid after setup() returns.
func get_texture() -> Texture2DRD:
	return _out_tex


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
			_counts_rid, _counters_rid, _lists_rid, _out_tex_rid]:
		if rid != RID():
			_rd.free_rid(rid)
	_uniform_set_rid = RID()
	_pipeline_rid = RID()
	_shader_rid = RID()
	_params_rid = RID()
	_counts_rid = RID()
	_counters_rid = RID()
	_lists_rid = RID()
	_out_tex_rid = RID()
	_out_tex = null
