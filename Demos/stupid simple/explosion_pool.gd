class_name ExplosionPool
extends Node3D

## CPU-side death-explosion VFX for the GPU sim. Connects to
## stupid_simple.gd's explosion_occurred(pos, team, age) signal and spawns a
## short animated blast at each explosion's world position:
##
##   1. FLASH   - an emissive sphere that pops to full size in ~0.1 s, then
##                fades and shrinks away (the "bang")
##   2. RING    - an expanding flat shockwave torus along the ground,
##                fading as it grows
##   3. DEBRIS  - one shared GPUParticles3D pool, one emission at the blast
##                point per explosion (sparks with gravity + drag)
##
## Everything is pooled: MAX_ACTIVE concurrent blasts, oldest recycled.
## Draw cost when idle is zero (all nodes hidden, emitter off).

## Team colors matching the rest of the project (DarwinianLogic, boid_swarm).
const TEAM_COLORS: Array[Color] = [
	Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.PURPLE, Color.CYAN,
]

const MAX_ACTIVE := 24
const FLASH_COLOR := Color(1.0, 0.85, 0.4)
const RING_COLOR := Color(1.0, 0.6, 0.25)

@export var sim_node_path: NodePath
@export var flash_duration := 0.55
@export var ring_duration := 0.7
@export var flash_max_radius := 3.5
## Mirrors sim.glsl's BLAST_RADIUS - the ring expands out to the blast's
## actual gameplay reach.
@export var ring_max_radius := 25.0

## Resolved in _ready: the stupid_simple node emitting explosion_occurred.
var _sim: Node
var _flashes: Array[MeshInstance3D] = []
var _rings: Array[MeshInstance3D] = []
var _flash_mats: Array[StandardMaterial3D] = []
var _ring_mats: Array[StandardMaterial3D] = []
var _slot_timer: PackedFloat32Array = PackedFloat32Array()
var _next_flash := 0
var _next_ring := 0
var _debris: GPUParticles3D

## Mirrors sim.glsl's BLAST_TTL - signals older than this are dropped.
const BLAST_TTL_RUNTIME := 0.4


func _ready() -> void:
	_sim = _resolve_sim()
	if _sim != null:
		_sim.explosion_occurred.connect(_on_explosion)
	else:
		push_warning("ExplosionPool: no node with explosion_occurred found - "
			+ "check sim_node_path (got: %s)" % sim_node_path)
	_setup_pools()


## Finds the node that actually emits explosion_occurred. The sim script may
## sit one or more levels below the node the path points at (e.g. MainScreen
## navigates StupidSimple/ArmyLogic via get_child(0)), so after the explicit
## path we walk the subtree - and if the path is empty/wrong, the whole
## current scene. Returns null when nothing emits the signal.
func _resolve_sim() -> Node:
	if sim_node_path != NodePath():
		var from := get_node_or_null(sim_node_path)
		if from != null:
			var found := _find_signal_emitter(from)
			if found != null:
				return found
	var scene := get_tree().current_scene
	if scene != null:
		return _find_signal_emitter(scene)
	return null


func _find_signal_emitter(from: Node) -> Node:
	if from.has_signal("explosion_occurred"):
		return from
	for child in from.get_children():
		var found := _find_signal_emitter(child)
		if found != null:
			return found
	return null


## Builds the shared debris emitter and the pooled flash/ring meshes.
func _setup_pools() -> void:
	# Shared debris particle system: one emitter, repositioned per blast.
	_debris = GPUParticles3D.new()
	_debris.emitting = false
	_debris.one_shot = true
	_debris.explosiveness = 1.0
	_debris.amount = 64
	_debris.lifetime = 0.7
	_debris.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 14.0
	pm.initial_velocity_max = 30.0
	pm.gravity = Vector3(0, -25, 0)
	pm.damping_min = 4.0
	pm.damping_max = 8.0
	pm.scale_min = 0.25
	pm.scale_max = 0.6
	pm.color = FLASH_COLOR
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.9, 0.5, 1.0))
	grad.set_color(1, Color(0.9, 0.25, 0.05, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	_debris.process_material = pm
	var debris_mesh := SphereMesh.new()
	debris_mesh.radius = 0.16
	debris_mesh.height = 0.32
	debris_mesh.radial_segments = 8
	debris_mesh.rings = 4
	var debris_mat := StandardMaterial3D.new()
	debris_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	debris_mat.albedo_color = Color(1.0, 0.8, 0.4)
	debris_mat.emission_enabled = true
	debris_mat.emission = Color(1.0, 0.55, 0.15)
	debris_mat.emission_energy_multiplier = 3.0
	debris_mesh.material = debris_mat
	_debris.draw_pass_1 = debris_mesh
	add_child(_debris)

	# Pooled flash + ring meshes, all hidden until claimed.
	for i in MAX_ACTIVE:
		var flash := MeshInstance3D.new()
		var fmat := StandardMaterial3D.new()
		fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fmat.albedo_color = FLASH_COLOR
		fmat.emission_enabled = true
		fmat.emission = FLASH_COLOR
		fmat.emission_energy_multiplier = 4.0
		fmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		fmat.disable_receive_shadows = true
		var fmesh := SphereMesh.new()
		fmesh.radius = 1.0
		fmesh.height = 2.0
		fmesh.radial_segments = 12
		fmesh.rings = 6
		fmesh.material = fmat
		flash.mesh = fmesh
		flash.visible = false
		flash.top_level = true
		add_child(flash)
		_flashes.append(flash)
		_flash_mats.append(fmat)

		var ring := MeshInstance3D.new()
		var rmat := StandardMaterial3D.new()
		rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		rmat.albedo_color = RING_COLOR
		rmat.emission_enabled = true
		rmat.emission = RING_COLOR
		rmat.emission_energy_multiplier = 2.0
		rmat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
		rmat.disable_receive_shadows = true
		var rmesh := TorusMesh.new()
		rmesh.inner_radius = 0.92
		rmesh.outer_radius = 1.0
		rmesh.rings = 24
		rmesh.ring_segments = 6
		rmesh.material = rmat
		ring.mesh = rmesh
		ring.visible = false
		ring.top_level = true
		ring.scale = Vector3(0.01, 0.01, 0.01)
		add_child(ring)
		_rings.append(ring)
		_ring_mats.append(rmat)

	_slot_timer.resize(MAX_ACTIVE)


## Signal handler: claim a slot and start its animation.
func _on_explosion(pos: Vector3, team: int, age: float) -> void:
	# Late/aged deliveries (slow frame, signal connected a beat late) are
	# skipped - the blast would pop in already-half-done.
	if age > BLAST_TTL_RUNTIME * 0.5:
		return

	var tint := FLASH_COLOR
	if team >= 0 and team < TEAM_COLORS.size():
		tint = TEAM_COLORS[team].lerp(FLASH_COLOR, 0.65)

	# FLASH slot
	var fi := _next_flash
	_next_flash = (_next_flash + 1) % MAX_ACTIVE
	_flashes[fi].global_position = pos
	_flashes[fi].visible = true
	_slot_timer[fi] = 0.0
	_flash_mats[fi].albedo_color = tint
	_flash_mats[fi].emission = tint

	# RING slot
	var ri := _next_ring
	_next_ring = (_next_ring + 1) % MAX_ACTIVE
	_rings[ri].global_position = Vector3(pos.x, pos.y + 0.4, pos.z)
	_rings[ri].visible = true
	_slot_timer[ri] = 0.0
	_ring_mats[ri].albedo_color = tint

	# DEBRIS: reposition the shared one-shot emitter and fire it.
	_debris.global_position = pos
	_debris.restart()

	# A short light punch sells the blast against bright terrain.
	var light := OmniLight3D.new()
	light.light_color = tint
	light.light_energy = 8.0
	light.omni_range = flash_max_radius * 4.0
	light.position = pos + Vector3(0, 2, 0)
	light.top_level = true
	add_child(light)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(light, "light_energy", 0.0, flash_duration)
	tw.chain().tween_callback(light.queue_free)


func _process(delta: float) -> void:
	for i in MAX_ACTIVE:
		# Flash: fast pop-in (0-10%), hold, then fade + shrink to zero.
		if _flashes[i].visible:
			_slot_timer[i] += delta
			var t := _slot_timer[i] / flash_duration
			if t >= 1.0:
				_flashes[i].visible = false
			else:
				var grow: float
				if t < 0.1:
					grow = t / 0.1  # snap open
				else:
					grow = 1.0 - (t - 0.1) / 0.9  # ease out over the rest
				var s := flash_max_radius * maxf(grow, 0.001)
				_flashes[i].scale = Vector3(s, s, s)
				var alpha := 1.0 - t * t
				_flash_mats[i].albedo_color.a = alpha
				_flash_mats[i].emission_energy_multiplier = 4.0 * alpha

		# Ring: linear expansion to the blast's gameplay radius, fading.
		if _rings[i].visible:
			_slot_timer[i] += delta
			var t2 := _slot_timer[i] / ring_duration
			if t2 >= 1.0:
				_rings[i].visible = false
				_rings[i].scale = Vector3(0.01, 0.01, 0.01)
			else:
				var r := ring_max_radius * t2
				# Torus lies in XZ; thickness constant, radius grows.
				_rings[i].scale = Vector3(maxf(r, 0.01), 1.0, maxf(r, 0.01))
				_ring_mats[i].albedo_color.a = 1.0 - t2
				_ring_mats[i].emission_energy_multiplier = 2.0 * (1.0 - t2)
