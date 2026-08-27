extends CharacterBody3D
class_name DropBox

## A supply crate that falls from the sky onto a random hex. The first
## darwinian to reach it captures it for its team; the owning team's
## darwinians then build a tower in that same hex by standing in it (see
## _process()'s build progress). Once enough build progress has piled up,
## the parent scene spawns a tower at the crate's integer hex position and
## this crate is removed.

## Emitted when a darwinian captures this crate for its team.
signal box_captured(team: int, pos: Vector3)

## Emitted once enough of the owning team's darwinians have stood in the
## hex - the parent scene should spawn a tower at (col, row).
signal tower_built(col: int, row: int, team: int)

const TEAM_COLORS: Array[Color] = [
	Color.RED,
	Color.GREEN,
	Color.BLUE,
	Color.YELLOW,
	Color.PURPLE,
	Color.CYAN
]

## The integer hex grid position this crate landed on / the tower will be
## built on. Set by the terrain spawner at spawn time.
var col: int = 0
var row: int = 0

## The team that captured this crate, or -1 while unclaimed.
var team: int = -1

## Total build progress required before the tower is constructed.
@export var build_required: float = 300.0

## Build progress gained per owning-team darwinian standing in the hex, per
## second.
@export var build_speed: float = 5.0

var _landed := false
var _captured := false
var _build_progress := 0.0
var _nearby_darwinians: Dictionary = {}

@onready var _mat: StandardMaterial3D = $MeshInstance3D.material_override


func _ready() -> void:
	# Default crate look; recolored to the capturing team's color on capture.
	_mat.albedo_color = Color(0.62, 0.5, 0.28)


func _physics_process(delta: float) -> void:
	# Fall from the sky until the crate hits the ground, then stay put.
	if _landed:
		return
	if not is_on_floor():
		velocity += get_gravity() * delta
	move_and_slide()
	if is_on_floor():
		velocity = Vector3.ZERO
		_landed = true


func _process(delta: float) -> void:
	# Once captured, the tower is built by the owning team's darwinians
	# being in the same hex - every one of them standing inside the capture
	# area contributes build progress.
	if not _captured:
		return
	var builders := 0
	for d in _nearby_darwinians.values():
		if d.team_number == team:
			builders += 1
	_build_progress += builders * build_speed * delta
	if _build_progress >= build_required:
		tower_built.emit(col, row, team)
		queue_free()


func _on_capture_area_body_entered(body: Node3D) -> void:
	if not (body is Darwinian or body is GpuDarwinian):
		return
	_nearby_darwinians[body.name] = body
	if not _captured and _landed and body.has_touched_floor_once:
		_capture(body)


func _on_capture_area_body_exited(body: Node3D) -> void:
	if body is Darwinian or body is GpuDarwinian:
		_nearby_darwinians.erase(body.name)


func _capture(body: Node3D) -> void:
	_captured = true
	team = body.team_number
	if team >= 0 and team < TEAM_COLORS.size():
		_mat.albedo_color = TEAM_COLORS[team]
	else:
		_mat.albedo_color = Color.WHITE
	box_captured.emit(team, global_position)
