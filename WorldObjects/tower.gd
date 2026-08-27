extends StaticBody3D
class_name Tower

## A tower built by a team after capturing a falling crate. It stands at an
## integer hex position, has 1000 health, and attacks ONE nearby darwinian
## of another team at a time - its laser beam (GPUParticles3D) points at
## whoever it's currently firing at, so you can always see the target.
## Enemy darwinians damage it with their own lasers, so a big enough force
## can eventually destroy it.

const TEAM_COLORS: Array[Color] = [
	Color.RED,
	Color.GREEN,
	Color.BLUE,
	Color.YELLOW,
	Color.PURPLE,
	Color.CYAN
]

## The integer hex grid position this tower stands on.
var col: int = 0
var row: int = 0

## The team this tower belongs to.
var team: int = -1

## The tower's health - enemy darwinians' lasers chip at it, and it is
## destroyed when it hits 0.
var health: float = 1000.0

## Damage dealt to the current target per attack tick.
@export var attack_damage: int = 10

var _tick := 0
var _current_target = null
var _nearby_darwinians: Dictionary = {}

@onready var _meshes: Array[MeshInstance3D] = [$Base, $Shaft, $Top]
@onready var _particles: GPUParticles3D = $GPUParticles3D
@onready var _particle_material: ParticleProcessMaterial = $GPUParticles3D.process_material
@onready var _audio: AudioStreamPlayer3D = $AudioStreamPlayer3D


## Places the tower at `pos` (the center of hex (col, row) - an integer hex
## position, never an arbitrary float) and colors it for `p_team`.
func setup(p_col: int, p_row: int, p_team: int, pos: Vector3) -> void:
	col = p_col
	row = p_row
	team = p_team
	position = pos
	var mat := StandardMaterial3D.new()
	var color: Color = TEAM_COLORS[team] if team >= 0 and team < TEAM_COLORS.size() else Color.WHITE
	color.a = 0.3
	mat.albedo_color = color
	for m in _meshes:
		m.material_override = mat
	# Tint the laser beam to the team color, same as darwinians tint theirs.
	var beam_mat: ORMMaterial3D = _particles.draw_pass_1.material
	beam_mat.albedo_color = color
	beam_mat.emission = color


func _process(_delta: float) -> void:
	if health <= 0.0:
		queue_free()
		return

	_tick += 1
	if _tick % 10 != 0:
		return

	# The tower locks onto a single enemy at a time. Drop the current target
	# if it's gone, dead, no longer an enemy, or hidden behind a wall/hill,
	# then pick the next one from whoever is in range AND has line of sight -
	# so the tower can never fire through walls.
	if _current_target == null \
			or not is_instance_valid(_current_target) \
			or _current_target.health <= 0 \
			or _current_target.team_number == team \
			or not _has_line_of_sight(_current_target):
		_current_target = null
		for d in _nearby_darwinians.values():
			if d.team_number != team and _has_line_of_sight(d):
				_current_target = d
				break

	if _current_target == null:
		_particles.emitting = false
		_audio.playing = false
		return

	# Aim the laser at the current target so everyone can see who is being
	# attacked, then fire.
	_particle_material.direction = _current_target.global_position - _particles.global_position
	_current_target.health -= attack_damage
	_particles.emitting = true
	_audio.playing = true


## Whether a straight laser line from this tower's beam origin (its top) to
## `target` is clear. The ray only extends as far as the target, and anything
## solid it hits between the two (walls, terrain hills, other towers, the
## crate) blocks the shot - hitting the target itself is fine, that's what
## we're aiming at.
func _has_line_of_sight(target: Node3D) -> bool:
	var from := _particles.global_position
	var to := target.global_position + Vector3.UP * 1.5
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 2
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider: Object = hit.get("collider")
	return collider == target


func _on_attack_area_body_entered(body: Node3D) -> void:
	if body is Darwinian:
		_nearby_darwinians[body.name] = body


func _on_attack_area_body_exited(body: Node3D) -> void:
	if body is Darwinian:
		_nearby_darwinians.erase(body.name)
		if body == _current_target:
			_current_target = null
