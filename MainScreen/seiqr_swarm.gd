extends Node3D
class_name SeiqrSwarm

## A swarm that is completely GPU-controlled: every dot's motion - orbiting,
## bobbing, streaming to new targets, and reacting to its neighbors - is
## computed in shaders. The CPU never touches a dot and the node never
## moves: dots fly in world space (local_coords = false), steered entirely
## by the GPU.
##
## The whole public API is set_objective(): hand it a world position and the
## GPU flies the entire cloud there. It's the SEIIQR idea applied to a
## swarm: the host sends a tiny bit of state (one vec3) and the GPU owns
## everything else.
##
## Neighbor sensing works exactly like SEIIQR's spatial hash: every frame a
## compute shader (seiqr_spatial_hash.glsl) builds a grid over the dots,
## counts them per cell, prefix-sums, packs them into cell lists, then each
## dot searches the 3x3 cells around it and gets (count, centroid) of nearby
## dots - written to a texture the particle shader reads to push apart.
## Five small dispatches, one texture, zero CPU involvement per dot.

## Where the swarm is heading, in world space. Set at spawn from the
## inspector; changed at runtime via set_objective().
@export var objective: Vector3 = Vector3.ZERO

## How many dots make up the swarm.
@export var amount: int = 1200

## Spatial hash (SEIIQR port) on/off. When off, dots only chase their orbit
## slots and the compute pipeline is not created.
@export var spatial_hash_enabled: bool = true

## Spatial hash grid: cells per side. Cells are exactly one neighbor_radius
## wide (half_extent is derived), which keeps the 3x3 neighbor search sound.
@export var grid_w: int = 16

## How close a dot has to be to count as a neighbor (world units).
@export var neighbor_radius: float = 2.0

## How hard crowded dots push apart (tuned on the particle shader too).
@export var separation_strength: float = 2.5

## The neighbor count that saturates the separation push (swarm density
## scales with amount and SWARM_RADIUS, so tune this if you change either).
@export var neighbor_scale: float = 8.0

@onready var _particles: GPUParticles3D = $GPUParticles3D
@onready var _material: ShaderMaterial = _particles.process_material

var _spatial_hash: SeiqrSpatialHash


func _ready() -> void:
	_particles.amount = amount
	if _material:
		_material.set_shader_parameter("objective", objective)
		_material.set_shader_parameter("dot_count", amount)
		_material.set_shader_parameter("separation_strength", separation_strength)
		_material.set_shader_parameter("neighbor_scale", neighbor_scale)
		# Bind a black texture first so the unbound-sampler default never
		# reads as "a neighbor at world origin" while the hash initializes.
		_material.set_shader_parameter("neighbor_tex", _make_black_texture())
		if spatial_hash_enabled:
			# setup() runs on the render thread (blocking), so the texture
			# is ready to bind when it returns.
			_spatial_hash = SeiqrSpatialHash.new()
			_spatial_hash.setup(amount, grid_w, neighbor_radius)
			if _spatial_hash.get_texture() != null:
				_material.set_shader_parameter("neighbor_tex", _spatial_hash.get_texture())
		# sim_time must be set before the first particle preprocess render so
		# the slots the compute hash and the particle shader derive agree.
		_material.set_shader_parameter("sim_time", _now())


func _process(_delta: float) -> void:
	# Drive the shared simulation clock, then run the spatial hash so the
	# neighbor results are fresh for this frame's particle pass.
	var t := _now()
	if _material:
		_material.set_shader_parameter("sim_time", t)
	if _spatial_hash:
		# Grid centered on the objective; half_extent derived so each cell is
		# exactly one neighbor_radius wide (never smaller than the cloud).
		var half_extent := maxf(grid_w * neighbor_radius / 2.0, 12.0)
		_spatial_hash.update(objective, t, neighbor_radius, half_extent)


func _exit_tree() -> void:
	if _spatial_hash:
		_spatial_hash.teardown()
		_spatial_hash = null


## The only interface the CPU has with the swarm: hand it a new objective in
## world space. Every dot on the GPU re-targets itself next frame and the
## cloud streams over - no CPU steering involved.
func set_objective(pos: Vector3) -> void:
	objective = pos
	if _material:
		_material.set_shader_parameter("objective", pos)


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _make_black_texture() -> ImageTexture:
	var black := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	black.fill(Color.BLACK)
	return ImageTexture.create_from_image(black)
