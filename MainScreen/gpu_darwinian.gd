extends Node3D
class_name GpuDarwinian

## A darwinian that is not a character body at all: a cloud of dots rendered
## by one GPUParticles3D, with every dot's motion computed on the GPU in
## gpu_swarm.gdshader. The CPU only moves the cloud as a whole, so a whole
## army costs one node + one draw call instead of one node per unit.
##
## It speaks the same public language as the classic Darwinian - team colors,
## set_new_destination(), follow_path(), stick_to_generator(), and the same
## has_touched_floor_once/team_number/is_currently_in_generating members the
## generators, crates and towers read - so it slots into the existing game
## without changing how anything else talks to units.
##
## Known tradeoffs of the "try":
## - Dots have no collision, so the swarm passes through walls (and can't
##   be shot by towers / enemy darwinians yet - enemies only target
##   Darwinian and Tower bodies).
## - The swarm fights by draining the nearest tracked enemy's health when
##   they get close, instead of per-unit lasers.

## March speed of the swarm as a whole, in world units/second.
@export var march_speed: float = 9.0

## How fast the swarm falls in from spawn. A plain Node3D has no gravity,
## so the script drops the cloud to the ground itself.
const FALL_SPEED := 35.0

## The swarm stops once its center is within this distance of its target.
@export var arrive_radius: float = 2.5

## Every COMBAT_INTERVAL ticks, the swarm drains COMBAT_DAMAGE health from
## the closest enemy in its vision area (same cadence as a darwinian laser).
const COMBAT_INTERVAL := 10
const COMBAT_DAMAGE := 5

var team_number: int
var team_color: Color
var health: int = 100

## Swarms spawn on the ground, so they satisfy the same "has landed" checks
## the generators/crates use before capturing anything.
var has_touched_floor_once := true
var is_currently_in_generating := false

var has_destination := false
var curr_destination: Vector3

## Enemies (Darwinian/Tower of another team) inside the vision area.
var _enemies: Dictionary = {}

## The road route being walked, as ordered world positions (see
## follow_path()). Empty when not following a path.
var _path: Array = []
var _path_index := 0

var _tick := 0

@onready var _particles: GPUParticles3D = $GPUParticles3D
@onready var _raycast: RayCast3D = $GroundRay


func _ready() -> void:
	# Stagger the combat tick across swarms so they don't all fire on the
	# same frame.
	_tick = randi() % COMBAT_INTERVAL


func _process(delta: float) -> void:
	if health <= 0:
		queue_free()
		return
	_tick += 1
	if _tick % COMBAT_INTERVAL == 0:
		_process_combat_tick()


func _physics_process(delta: float) -> void:
	# Still dropping in from spawn (teams drop units from high up): fall
	# until we land, then start doing anything else. The GPU keeps the dots
	# swirling while the cloud descends.
	if global_position.y > 0.0:
		global_position.y = maxf(0.0, global_position.y - FALL_SPEED * delta)
		return

	# Garrisoned on a generator (or holding still): the GPU keeps the dots
	# swirling, the CPU does nothing.
	if is_currently_in_generating or not has_destination:
		return

	var to := curr_destination - global_position
	to.y = 0.0
	var dist := to.length()
	if dist <= arrive_radius:
		_advance_waypoint()
		return

	global_position += to / dist * march_speed * delta
	# The map is flat (height_scale = 0); snap the cloud back to ground
	# level after every move.
	global_position.y = 0.0


## Moves on to the next waypoint of a road route, or stops for good at the
## end of one.
func _advance_waypoint() -> void:
	if _path_index < _path.size() - 1:
		_path_index += 1
		curr_destination = _path[_path_index]
	else:
		_arrive()


func _arrive() -> void:
	has_destination = false
	_path = []
	_path_index = 0
	# The ground raycast is allowed to hand this swarm a fresh road route
	# again (position_logic.gd gates on this flag).
	_raycast.accepting_new_roads = true


## Orders the swarm to a point, like a darwinian's set_new_destination().
func set_new_destination(new_destination: Vector3) -> void:
	curr_destination = new_destination
	_path = []
	_path_index = 0
	has_destination = true


## Hands the swarm a whole road route to walk (called by position_logic.gd
## when the swarm steps onto a road tile), exactly like Darwinian.follow_path().
func follow_path(waypoints: Array) -> void:
	if waypoints.is_empty():
		return
	_path = waypoints.duplicate()
	_path_index = 0
	curr_destination = _path[0]
	has_destination = true
	# Don't let the raycast hand out a NEW route until this one is walked
	# off - same one-road-at-a-time rule as the classic darwinians.
	_raycast.accepting_new_roads = false


func _process_combat_tick() -> void:
	if _enemies.is_empty():
		return
	# Drain the closest living enemy. Enemies are keyed by node name, so a
	# dead/freed one has to be dropped here.
	var best = null
	var best_dist_sq := INF
	for e in _enemies.values():
		if not is_instance_valid(e) or e.health <= 0:
			continue
		var d := global_position.distance_squared_to(e.global_position)
		if d < best_dist_sq:
			best_dist_sq = d
			best = e
	if best:
		best.health -= COMBAT_DAMAGE


func _on_vision_area_body_entered(body: Node3D) -> void:
	if body == self:
		return
	if body is Darwinian and body.team_number != team_number:
		_enemies[body.name] = body
	elif body is Tower and body.team != team_number:
		_enemies[body.name] = body


func _on_vision_area_body_exited(body: Node3D) -> void:
	if body is Darwinian or body is Tower:
		_enemies.erase(body.name)


func stick_to_generator() -> void:
	is_currently_in_generating = true
	has_destination = false
	_path = []


func set_team(team: int) -> void:
	team_number = team
	match team_number:
		0: team_color = Color.RED
		1: team_color = Color.GREEN
		2: team_color = Color.BLUE
		3: team_color = Color.YELLOW
		4: team_color = Color.PURPLE
		5: team_color = Color.CYAN
		_: team_color = Color.WHITE
	var mat: StandardMaterial3D = _particles.draw_pass_1.material
	mat.albedo_color = team_color
	mat.emission = team_color
