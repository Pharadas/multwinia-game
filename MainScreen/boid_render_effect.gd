class_name BoidRenderEffect
extends CompositorEffect

## Custom renderer for the boids swarm.
##
## A CompositorEffect that runs at the POST_OPAQUE stage: it first records
## the lattice army's four compute dispatches (via BoidCompute.record_frame),
## then draws every dot straight from the position SSBO with a single
## instanced billboard draw, depth-tested against the scene's depth buffer
## with additive blending.

var QUAD_CORNERS := PackedFloat32Array([
	-1.0, -1.0, 0.0,
	 1.0, -1.0, 0.0,
	-1.0,  1.0, 0.0,
	 1.0,  1.0, 0.0,
])

var _rd: RenderingDevice
var _shader_rid := RID()
var _pipeline_rid := RID()
var _vertex_buffer_rid := RID()
var _vertex_array_rid := RID()
var _vertex_format: int = -1
var _pos_rid := RID()
var _cam_ubo_rid := RID()
var _uniform_set_rid := RID()
var _dot_count: int = 0

var _compute  # BoidCompute — untyped to avoid circular parse issues
var _warned := false
var _freed := false

var team_color := Color(0.35, 0.85, 0.45)
var dot_scale := 0.5
var density_scale := 60.0
var sim_enabled := true


func _init() -> void:
	effect_callback_type = CompositorEffect.EffectCallbackType.EFFECT_CALLBACK_TYPE_POST_OPAQUE
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("BoidRenderEffect: no RenderingDevice found.")
		return
	_setup()


func _setup() -> void:
	var shader_file: RDShaderFile = load("res://MainScreen/boid_render.glsl")
	if shader_file == null:
		push_error("BoidRenderEffect: could not load boid_render.glsl")
		return
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if not shader_file.base_error.is_empty():
		push_error("BoidRenderEffect: GLSL base error: %s" % shader_file.base_error)
	if not spirv.compile_error_vertex.is_empty():
		push_error("BoidRenderEffect: vertex compile error: %s" % spirv.compile_error_vertex)
	if not spirv.compile_error_fragment.is_empty():
		push_error("BoidRenderEffect: fragment compile error: %s" % spirv.compile_error_fragment)
	_shader_rid = _rd.shader_create_from_spirv(spirv)

	var vertex_bytes := QUAD_CORNERS.to_byte_array()
	_vertex_buffer_rid = _rd.vertex_buffer_create(vertex_bytes.size(), vertex_bytes)
	var attr := RDVertexAttribute.new()
	attr.location = 0
	attr.format = RenderingDevice.DataFormat.DATA_FORMAT_R32G32B32_SFLOAT
	attr.stride = 3 * 4
	_vertex_format = _rd.vertex_format_create([attr] as Array[RDVertexAttribute])
	_vertex_array_rid = _rd.vertex_array_create(4, _vertex_format, [_vertex_buffer_rid])


func configure(pos_rid: RID, dot_count_: int) -> void:
	if _rd == null or not _shader_rid.is_valid():
		return
	_pos_rid = pos_rid
	_dot_count = dot_count_
	var zero := PackedFloat32Array()
	zero.resize(48)
	_cam_ubo_rid = _rd.uniform_buffer_create(zero.size() * 4, zero.to_byte_array())
	_uniform_set_rid = _rd.uniform_set_create([
		_storage_uniform(_pos_rid, 0),
		_uniform_uniform(_cam_ubo_rid, 1),
	], _shader_rid, 0)


func bind_compute(compute) -> void:
	_compute = compute


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _freed or not enabled or _dot_count == 0:
		return
	if callback_type != CompositorEffect.EffectCallbackType.EFFECT_CALLBACK_TYPE_POST_OPAQUE:
		return
	var scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data() as RenderSceneDataRD
	if scene_buffers == null or scene_data == null:
		return
	var size := scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	if sim_enabled and _compute != null:
		_compute.record_frame()

	for view in scene_buffers.get_view_count():
		_draw_view(scene_buffers, scene_data, view)


func _draw_view(scene_buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD, view: int) -> void:
	var color_tex := scene_buffers.get_color_layer(view)
	var depth_tex := scene_buffers.get_depth_layer(view)
	var framebuffer := FramebufferCacheRD.get_cache_multipass([color_tex, depth_tex], [], 1)
	if not framebuffer.is_valid():
		if not _warned:
			push_error("BoidRenderEffect: framebuffer invalid")
			_warned = true
		return
	if not _pipeline_rid.is_valid():
		_create_pipeline(framebuffer)
	if not _pipeline_rid.is_valid():
		if not _warned:
			push_error("BoidRenderEffect: pipeline failed to create")
			_warned = true
		return

	var cam_data := _cam_ubo_data(scene_buffers, scene_data)
	_rd.buffer_update(_cam_ubo_rid, 0, cam_data.size() * 4, cam_data.to_byte_array())

	var draw_list := _rd.draw_list_begin(framebuffer, RenderingDevice.DrawFlags.DRAW_DEFAULT_ALL)
	if draw_list < 0:
		if not _warned:
			push_error("BoidRenderEffect: draw_list_begin returned %d" % draw_list)
			_warned = true
		return
	_rd.draw_list_bind_render_pipeline(draw_list, _pipeline_rid)
	_rd.draw_list_bind_uniform_set(draw_list, _uniform_set_rid, 0)
	_rd.draw_list_bind_vertex_array(draw_list, _vertex_array_rid)
	_rd.draw_list_draw(draw_list, false, 4, _dot_count)
	_rd.draw_list_end()


func _cam_ubo_data(scene_buffers: RenderSceneBuffersRD, scene_data: RenderSceneDataRD) -> PackedFloat32Array:
	var cam_transform := scene_data.get_cam_transform()
	var view_mat := Projection(cam_transform.affine_inverse())
	var proj_mat := scene_data.get_cam_projection()
	var basis := cam_transform.basis
	var size := scene_buffers.get_internal_size()
	return PackedFloat32Array([
		view_mat.x.x, view_mat.x.y, view_mat.x.z, view_mat.x.w,
		view_mat.y.x, view_mat.y.y, view_mat.y.z, view_mat.y.w,
		view_mat.z.x, view_mat.z.y, view_mat.z.z, view_mat.z.w,
		view_mat.w.x, view_mat.w.y, view_mat.w.z, view_mat.w.w,
		proj_mat.x.x, proj_mat.x.y, proj_mat.x.z, proj_mat.x.w,
		proj_mat.y.x, proj_mat.y.y, proj_mat.y.z, proj_mat.y.w,
		proj_mat.z.x, proj_mat.z.y, proj_mat.z.z, proj_mat.z.w,
		proj_mat.w.x, proj_mat.w.y, proj_mat.w.z, proj_mat.w.w,
		basis.x.x, basis.x.y, basis.x.z, 0.0,
		basis.y.x, basis.y.y, basis.y.z, 0.0,
		float(size.x), float(size.y),
		dot_scale, density_scale,
		team_color.r, team_color.g, team_color.b, 0.0,
	])


func _create_pipeline(framebuffer: RID) -> void:
	var raster := RDPipelineRasterizationState.new()
	raster.cull_mode = RenderingDevice.PolygonCullMode.POLYGON_CULL_DISABLED
	var multisample := RDPipelineMultisampleState.new()
	var fb_format := _rd.framebuffer_get_format(framebuffer)
	multisample.sample_count = _rd.framebuffer_format_get_texture_samples(fb_format, 0)
	var attachment := RDPipelineColorBlendStateAttachment.new()
	attachment.enable_blend = true
	attachment.color_blend_op = RenderingDevice.BlendOperation.BLEND_OP_ADD
	attachment.alpha_blend_op = RenderingDevice.BlendOperation.BLEND_OP_ADD
	attachment.src_color_blend_factor = RenderingDevice.BlendFactor.BLEND_FACTOR_SRC_ALPHA
	attachment.dst_color_blend_factor = RenderingDevice.BlendFactor.BLEND_FACTOR_ONE
	attachment.src_alpha_blend_factor = RenderingDevice.BlendFactor.BLEND_FACTOR_SRC_ALPHA
	attachment.dst_alpha_blend_factor = RenderingDevice.BlendFactor.BLEND_FACTOR_ONE
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [attachment]
	var depth_stencil := RDPipelineDepthStencilState.new()
	depth_stencil.enable_depth_test = true
	depth_stencil.enable_depth_write = false
	depth_stencil.depth_compare_operator = RenderingDevice.CompareOperator.COMPARE_OP_GREATER_OR_EQUAL
	_pipeline_rid = _rd.render_pipeline_create(
		_shader_rid,
		fb_format,
		_vertex_format,
		RenderingDevice.RenderPrimitive.RENDER_PRIMITIVE_TRIANGLE_STRIPS,
		raster,
		multisample,
		depth_stencil,
		blend)


func _storage_uniform(rid: RID, binding: int) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UniformType.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


func _uniform_uniform(rid: RID, binding: int) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UniformType.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


func get_rd() -> RenderingDevice:
	return _rd


func teardown() -> void:
	if _freed:
		return
	_freed = true
	if _rd != null and _shader_rid.is_valid():
		RenderingServer.call_on_render_thread(_free_resources)


func _free_resources() -> void:
	if _rd == null:
		return
	for rid in [_uniform_set_rid, _cam_ubo_rid, _pipeline_rid, _shader_rid,
			_vertex_array_rid, _vertex_buffer_rid]:
		if rid != RID():
			_rd.free_rid(rid)
	_uniform_set_rid = RID()
	_cam_ubo_rid = RID()
	_pipeline_rid = RID()
	_shader_rid = RID()
	_vertex_array_rid = RID()
	_vertex_buffer_rid = RID()
