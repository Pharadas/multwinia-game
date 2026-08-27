extends CharacterBody3D
class_name Darwinian

## --- Perf notes -----------------------------------------------------
## This is the same logic as before, with a few changes aimed at cutting
## per-instance cost when there are hundreds of these on screen:
##  1. Node/material lookups ($GPUParticles3D, .process_material, etc.)
##     are resolved ONCE at spawn via @onready, instead of every _process()
##     call for every instance.
##  2. Distance-to-objective used to be computed via a sqrt (Vector2.length())
##     up to 3x per frame, unconditionally. It's now computed once per
##     frame as a squared distance (no sqrt at all) and reused.
##  3. `if curr_destination:` was checking "is this the zero vector", not
##     "has a destination been set" - Vector3(0,0,0) is a perfectly valid
##     destination that would've been silently treated as "none". Replaced
##     with an explicit has_destination bool.
##  4. Dropped the per-instance randomize() call in _ready() - reseeding
##     the GLOBAL RNG from system time on every single spawn is wasted
##     work (and doesn't make any one instance's own rolls "more random").
##     randi()/randf_range() are already randomized by the engine.
##  5. NEW: separation ("try to stay apart"). This piggybacks entirely on
##     the vision Area3D that already existed for combat detection - no
##     new collision shapes, no new physics queries, no per-frame distance
##     scan against every other Darwinian in the level. See nearby_darwinians
##     and _apply_separation() below for details and the tradeoffs made.
##  6. NEW: rank/file formation instead of a random destination scatter.
##     When a destination is issued, each Darwinian looks at its own-team
##     peers already visible in its vision area (nearby_darwinians, same
##     dict as #5 - no new tracking), sorts them by a stable per-object id
##     so every peer independently computes the SAME ordering with no
##     central squad manager, and slots itself into a grid oriented to the
##     group's direction of travel. This only runs once per destination
##     change (not per-frame), so the sort/loop cost is paid rarely and
##     over a small "currently visible peers" set, not the whole army.
##     See _formation_offset() below.
## Bigger wins beyond this script (need scene/project-level changes, not
## just this file) - see the options card above: physics LOD (skip
## move_and_slide() on some ticks for characters that aren't doing much),
## reducing GPUParticles3D amount/lifetime or pooling a shared emitter, and
## object-pooling Darwinians instead of instantiate()/queue_free() on
## spawn/death.

## Arrival radius for a destination, in world units. Deliberately small - a
## bit less than one hex across (hexes are ~1 unit radius, ~1.73 apart center
## to center), because road hops hand out the NEXT tile's center as the
## destination. A larger radius made darwinians "arrive" before ever leaving
## their current tile (they're always within a few units of the adjacent
## tile's center) and freeze on the spot, re-cycling the same destination
## forever without moving.
@export var range_to_roam_default: float = 1.0

## Used once arrival has been detected, before a fresh destination arrives -
## kept just above the arrival radius so a just-arrived darwinian doesn't
## instantly re-flag "arrived" while waiting for the road raycast.
@export var range_to_roam_close: float = 1.5

## Floor under march speed. move_to_pos() used to scale speed by remaining
## distance (clamp(distance, 0, 16)), which is a nice "arrive" for a single
## far point but crawls along per-hex paths: hops are only ~1.73 apart, so a
## darwinian was perpetually decelerating into each waypoint and never got
## above ~1.7 units/sec. The floor holds a steady speed right up to the
## arrival radius; the per-frame arrival check still catches the waypoint
## without overshooting.
const MOVE_SPEED_MIN := 6.0

## How hard neighbors push each other apart en route. Formation now does
## the heavy lifting of keeping everyone spread out (see below), so this
## is a lighter secondary nudge for local jostling/overlap - not the main
## spacing mechanism anymore, hence the lower default than before.
@export var separation_strength: float = 3.0

## Separation is capped to this speed on its own, so it's a steering nudge
## layered on top of normal movement rather than something that can
## overpower or fight the direction a Darwinian is actually walking in.
@export var separation_max_speed: float = 4.0

## How often (in ticks, same cadence system as combat/roam below) each
## Darwinian recomputes its separation push. Doesn't need to run every
## frame - "staying apart" is a slow drift, not a reflex - so this is
## intentionally infrequent to keep the cost down with hundreds on screen.
@export var separation_check_interval: int = 12

## How many units wide a single rank is before the formation wraps to the
## next rank back. Bigger = wider, shallower lines; smaller = narrower,
## deeper columns.
@export var formation_files: int = 6

## Side-to-side spacing between units in the same rank.
@export var formation_file_spacing: float = 2.0

## Front-to-back spacing between successive ranks.
@export var formation_rank_spacing: float = 2.0

## Side-to-side spacing between the parallel lanes a team marches in while
## following a road. Deliberately much tighter than formation_file_spacing
## (which scatters around a destination): a routed road is only about a hex
## wide, and wider lanes would push units into the walls lining it.
const PATH_LANE_SPACING := 1.5

## --- Wall avoidance ---------------------------------------------------
## When a darwinian walks into a wall (a solid hex tile), it doesn't give
## up immediately anymore: it backs up a few units, checks whether the left
## or right of its travel vector is clear, sidesteps that way, and tries to
## reach its destination again. It only stops for good once repeated
## attempts stop making progress (see MAX_WALL_RETRIES and
## _wall_dist_at_evade below).
const MAX_WALL_RETRIES := 6
const WALL_EVADE_SPEED := 9.0
const WALL_BACK_UP_TIME := 0.35
const WALL_SIDESTEP_TIME := 0.6
const WALL_SIDE_CHECK_DIST := 6.0

## How long a darwinian that gave up on a wall stays shut off from new road
## directions before it opens back up and tries again. Without this, one bad
## wall encounter permanently brain-deads the unit - it would never accept a
## new destination again, even if a road is later drawn under it.
const GIVE_UP_RETRY_TIME := 4.0

var curr_destination: Vector3
var has_destination: bool = false
var team_number: int
var team_color: Color
var health: int
var is_currently_in_generating := false
var darwinians_in_area: Dictionary = {} # enemies only (different team) - combat, includes towers
var range_to_roam := 1.0
var has_touched_floor_once := false

## All nearby Darwinians regardless of team, for separation - and,
## filtered to same-team, for formation peer lookups in _formation_offset().
## Populated by the SAME vision-area enter/exit signals already used for
## combat - so keeping this up to date costs one extra dictionary
## insert/erase per signal, not an extra Area3D or a per-frame distance
## scan against every Darwinian in the level.
##
## Tradeoff: this reuses the (typically fairly large) vision radius rather
## than a tight "personal space" radius, since adding a second, smaller
## Area3D per instance would mean an extra collision shape + extra
## enter/exit signal wiring for every Darwinian on screen. If in practice
## they end up spreading out too eagerly (pushing apart from things they
## can merely "see" rather than things crowding them), the fix is a
## smaller dedicated Area3D for this dictionary instead of reusing vision -
## that's a scene change, not something this script alone can fix cheaply.
var nearby_darwinians: Dictionary = {}

## Last computed separation nudge (x/z only). Stored rather than applied
## straight to velocity, because velocity gets fully overwritten elsewhere
## (move_to_pos(), roam(), the "arrived" branch in _process()) - if
## _apply_separation() wrote to velocity directly, whichever of those ran
## next would just stomp it out. Keeping it as its own cached vector lets
## every place that sets velocity blend it in instead of losing it, while
## still only recomputing it on the slow interval below.
var _separation_push: Vector3 = Vector3.ZERO

var _tick := 0 # same role as the old `x`, renamed for clarity

# Wall-avoidance state (see the constants above).
var _wall_evading := false
var _wall_evade_phase := 0 # 0 = backing up, 1 = sidestepping
var _wall_evade_timer := 0.0
var _wall_evade_dir := Vector3.ZERO
var _wall_retries := 0
var _wall_dist_at_evade := 0.0

# Countdown while a given-up unit stays shut off from new roads; when it
# hits zero the unit opens back up and can try a fresh destination.
var _give_up_timer := 0.0

# The full route this darwinian is currently walking, as ordered world
# positions (each waypoint is a hex center along the road). Handed over as a
# whole by follow_path() - the darwinian walks every waypoint in sequence
# without re-querying the tile graph between hops, and only the LAST waypoint
# counts as "arrived". Empty when not following a path.
var _path: Array = []
var _path_index := 0

# The route's final hex center (unshifted by any lane offset), kept so the
# fan-out on arrival spreads around the actual objective, not a lane point.
var _path_objective := Vector3.ZERO

# True while this unit is walking to its spread-out spot after reaching the
# end of a route - the arrival that follows is the real stop.
var _dispersing := false

# Resolved once at spawn instead of every frame.
@onready var _particles: GPUParticles3D = $GPUParticles3D
@onready var _particle_material: ParticleProcessMaterial = $GPUParticles3D.process_material
@onready var _audio: AudioStreamPlayer3D = $AudioStreamPlayer3D
@onready var _raycast: RayCast3D = $RayCast3D
@onready var _sprite: Sprite3D = $Sprite3D


func _ready() -> void:
	# randi() % 20 already staggers each instance's tick offset so hundreds
	# of them don't all do their heavy checks on the same frame.
	_tick = randi() % 20
	health = 100


func _process(_delta: float) -> void:
	if health <= 0:
		queue_free()
		return

	if is_currently_in_generating:
		_particles.emitting = false
		velocity = Vector3.ZERO
		return

	_tick += 1

	if _give_up_timer > 0.0:
		_give_up_timer -= _delta
		if _give_up_timer <= 0.0:
			# Cooldown over - open back up to road directions so a unit that
			# once gave up on a wall gets another chance instead of standing
			# brain-dead forever.
			_raycast.accepting_new_roads = true
			_wall_retries = 0

	if _tick % 10 == 0:
		_process_combat_tick()

	if _tick % separation_check_interval == 0:
		_apply_separation()

	if has_destination and not _wall_evading:
		# Computed once and reused below - no sqrt, and only one call
		# instead of up to three separate get_xy_distance_from_objective()
		# calls the original had.
		var dist_sq := _xz_distance_sq_to_objective()
		var range_sq := range_to_roam * range_to_roam

		if _tick % 20 == 0 and dist_sq > range_sq:
			range_to_roam = range_to_roam_default
			move_to_pos(curr_destination)

		if dist_sq < range_sq:
			if _path_index < _path.size() - 1:
				# Still waypoints left on the assigned route - turn toward
				# the next one and re-aim immediately so the march stays
				# smooth through corners instead of drifting on the old
				# heading for up to a tick batch. The path was handed to us
				# in full, so no tile re-query is needed between hops.
				_path_index += 1
				curr_destination = _path[_path_index]
				range_to_roam = range_to_roam_default
				move_to_pos(curr_destination)
			elif not _path.is_empty() and not _dispersing:
				# Reached the end of the route - fan out around the final hex
				# instead of piling onto its center, then stop. Each unit walks
				# to its own ring slot around the objective, so the whole team
				# spreads out on arrival.
				_dispersing = true
				curr_destination = _path_objective + _disperse_offset(_path_objective)
				range_to_roam = range_to_roam_default
				move_to_pos(curr_destination)
			else:
				range_to_roam = range_to_roam_close
				_raycast.accepting_new_roads = true
				has_destination = false
				_dispersing = false
				_path = []
				_path_index = 0
				# Was a hard stop (0,0) - now settles to the separation push
				# instead, so a Darwinian that arrives into a crowd still
				# visibly jostles apart rather than freezing on top of others.
				velocity.x = _separation_push.x
				velocity.z = _separation_push.z
	elif _tick % 500 == 0:
		roam()

	if _tick % 50 == 0:
		_tick = 0


func _process_combat_tick() -> void:
	if darwinians_in_area.is_empty():
		_audio.playing = false
		return

	# Pick the first enemy with a clear laser line - never fire at one that's
	# hidden behind a wall/hill, even if it entered the vision area first.
	var curr_enemy = null
	for e in darwinians_in_area.values():
		if _has_line_of_sight(e):
			curr_enemy = e
			break
	if curr_enemy == null:
		_particles.emitting = false
		_audio.playing = false
		return
	_particle_material.direction = curr_enemy.global_position - global_position
	curr_enemy.health -= 5
	_particles.emitting = true
	_audio.playing = true


## Whether a straight laser line from this darwinian to `target` is clear.
## The ray only extends as far as the target, and anything solid it hits
## between the two (walls, terrain hills, other towers, the crate) blocks the
## shot - hitting the target itself is fine, that's what we're aiming at.
## Other darwinians aren't on the ray's collision mask, so they never block.
func _has_line_of_sight(target: Node3D) -> bool:
	var from := global_position + Vector3.UP * 1.5
	var to := target.global_position + Vector3.UP * 1.5
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 2
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider: Object = hit.get("collider")
	return collider == target


## Recomputes _separation_push from nearby Darwinians (any team). Runs on
## its own infrequent interval rather than every frame/tick - "staying
## apart" is a slow drift, not something that needs frame-perfect physics.
## Writes only to the cached _separation_push, never to velocity directly
## - see the comment on that variable for why.
func _apply_separation() -> void:
	if nearby_darwinians.is_empty():
		_separation_push = Vector3.ZERO
		return

	# Sum of "away from neighbor" vectors, each weighted by 1/dist_sq so
	# closer neighbors push harder than far ones. Dividing by dist_sq
	# instead of dist (i.e. skipping the normalize) avoids a sqrt per
	# neighbor - the resulting vector isn't a perfectly uniform direction,
	# but for a steering nudge (not a physics-accurate force) that's a fine
	# trade for not doing up to N sqrt calls per Darwinian per interval.
	var push := Vector3.ZERO
	for other in nearby_darwinians.values():
		var away = global_position - other.global_position
		var dist_sq = away.x * away.x + away.z * away.z
		if dist_sq > 0.0001:
			push += away / dist_sq

	push.x *= separation_strength
	push.z *= separation_strength
	push.y = 0.0

	# Cap separation's own contribution so it can only ever nudge, never
	# overpower or fight whatever direction move_to_pos() is walking in.
	var xz := Vector2(push.x, push.z)
	if xz.length() > separation_max_speed:
		xz = xz.normalized() * separation_max_speed
		push.x = xz.x
		push.z = xz.y

	_separation_push = push


func roam() -> void:
	# Was a hard (0,0) stop - now settles to the cached separation push so
	# idle/roaming Darwinians still drift apart instead of standing frozen
	# in a clump. If there's nothing nearby, _separation_push is just
	# Vector3.ZERO and this behaves exactly like before.
	velocity.x = _separation_push.x
	velocity.z = _separation_push.z


## Final fallback when a darwinian keeps hitting walls without making any
## progress toward its destination (see MAX_WALL_RETRIES). It drops the
## destination, stops moving, and stops accepting new roads - so it just
## stands where it gave up instead of jittering against the wall forever.
func _stop_at_wall() -> void:
	has_destination = false
	_dispersing = false
	_path = []
	_path_index = 0
	velocity.x = 0.0
	velocity.z = 0.0
	# Keep the road raycast from handing this unit a fresh destination for a
	# while - it would just march straight back into the same wall. After
	# GIVE_UP_RETRY_TIME it opens back up (see _process) and tries again, so
	# a give-up is a pause, not a permanent brain-death.
	_raycast.accepting_new_roads = false
	_give_up_timer = GIVE_UP_RETRY_TIME


## Starts the wall-avoidance maneuver when this darwinian collides with a
## wall while en route: back up out of it, check whether the left or right
## of the destination vector is clear, sidestep that way, and try the
## destination again.
func _on_wall_hit(normal: Vector3) -> void:
	if _wall_evading:
		return
	# If the last sidestep actually got us closer to the destination, the
	# maneuver is working - refresh the retry budget so a long wall can be
	# worked around instead of exhausting the budget on one wall.
	if _xz_distance_sq_to_objective() < _wall_dist_at_evade:
		_wall_retries = 0
	if _wall_retries >= MAX_WALL_RETRIES:
		_stop_at_wall()
		return

	_wall_evading = true
	_wall_evade_phase = 0
	_wall_evade_timer = 0.0
	_wall_dist_at_evade = _xz_distance_sq_to_objective()

	# While working around the wall, stay open to new road directions: the
	# raycast can hand us a fresh route (follow_path or set_new_destination,
	# both of which cancel this maneuver) instead of us being locked onto
	# the old one.
	_raycast.accepting_new_roads = true

	# "Walk a bit back": move along the wall's collision normal, which
	# points away from the wall toward this darwinian.
	var away := Vector3(normal.x, 0.0, normal.z)
	if away.length_squared() < 0.0001:
		away = -velocity
		away.y = 0.0
		if away.length_squared() < 0.0001:
			away = Vector3.FORWARD
	_wall_evade_dir = away.normalized()


## Drives the back-up / sidestep phases of the wall-avoidance maneuver and
## owns horizontal velocity while it runs. When it finishes, it steers
## straight back at the destination ("try again").
func _process_wall_evade(delta: float) -> void:
	_wall_evade_timer += delta

	if _wall_evade_phase == 0:
		# Backing up; once enough time has passed, pick a clear side and
		# start stepping that way.
		if _wall_evade_timer >= WALL_BACK_UP_TIME:
			_wall_evade_phase = 1
			_wall_evade_timer = 0.0
			_pick_sidestep_dir()
		else:
			velocity.x = _wall_evade_dir.x * WALL_EVADE_SPEED
			velocity.z = _wall_evade_dir.z * WALL_EVADE_SPEED
			return

	if _wall_evade_timer >= WALL_SIDESTEP_TIME:
		_wall_evading = false
		_wall_retries += 1
		if has_destination:
			move_to_pos(curr_destination)
	else:
		velocity.x = _wall_evade_dir.x * WALL_EVADE_SPEED
		velocity.z = _wall_evade_dir.z * WALL_EVADE_SPEED


## Chooses which way to sidestep: left or right relative to the vector from
## this darwinian to its destination, whichever is clear (random if both
## are, so a crowd doesn't all funnel to the same side).
func _pick_sidestep_dir() -> void:
	var to_dest := curr_destination - global_position
	to_dest.y = 0.0
	if to_dest.length_squared() < 0.0001:
		to_dest = Vector3.FORWARD
	else:
		to_dest = to_dest.normalized()

	# Perpendicular directions in the XZ plane.
	var left := Vector3(-to_dest.z, 0.0, to_dest.x)
	var right := -left
	var left_free := _side_is_free(left, WALL_SIDE_CHECK_DIST)
	var right_free := _side_is_free(right, WALL_SIDE_CHECK_DIST)

	if left_free and right_free:
		_wall_evade_dir = left if randf() < 0.5 else right
	elif left_free:
		_wall_evade_dir = left
	elif right_free:
		_wall_evade_dir = right
	else:
		# Boxed in - try left anyway; move_and_slide() just pushes us
		# along, and the retry budget eventually gives up.
		_wall_evade_dir = left


## Whether the space `distance` units along `dir` (at body height) is free
## of walls. Terrain and other obstacles don't count - only the "wall"
## group blocks this check, since the point is to get around walls.
func _side_is_free(dir: Vector3, distance: float) -> bool:
	var from := global_position + Vector3.UP * 1.0
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * distance)
	query.collision_mask = 2
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider: Object = hit.get("collider")
	return not (collider is Node and collider.is_in_group("wall"))


func move_to_pos(pos: Vector3) -> void:
	var distance := pos - global_position
	var fall_speed := velocity.y
	if is_on_floor():
		# Steady march speed: scale down from the cap with distance but never
		# below MOVE_SPEED_MIN, so short path hops don't turn into a crawl.
		#var travel = distance.normalized() * clamp(distance.length(), MOVE_SPEED_MIN, 16.0)
		var travel = distance.normalized() * 12.0
		# Blend in the cached separation push so a Darwinian walking
		# through/near others visibly leans away from them instead of
		# beelining straight through - then re-clamp so separation can
		# only ever nudge the path, never make travel faster than normal.
		travel.x += _separation_push.x
		travel.z += _separation_push.z
		var xz := Vector2(travel.x, travel.z)
		if xz.length() > 16.0:
			xz = xz.normalized() * 16.0
			travel.x = xz.x
			travel.z = xz.y
		velocity = travel
	velocity.y = fall_speed


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	else:
		has_touched_floor_once = true
		velocity.y = -1.0

	# While dodging a wall, the avoidance maneuver owns horizontal velocity.
	if _wall_evading:
		_process_wall_evade(delta)

	move_and_slide()

	# Hitting a wall starts an avoidance maneuver (back up, sidestep around,
	# try again) instead of immediately giving up on the destination - it
	# only stops for good once repeated attempts stop making progress. Only
	# colliders in the "wall" group count - sliding along the terrain or
	# brushing other darwinians is normal movement.
	if has_destination and get_slide_collision_count() > 0:
		for i in range(get_slide_collision_count()):
			var collider := get_slide_collision(i).get_collider()
			if collider is Node and collider.is_in_group("wall"):
				_on_wall_hit(get_slide_collision(i).get_normal())
				break


func stick_to_generator() -> void:
	is_currently_in_generating = true
	velocity = Vector3.ZERO
	# Stop _physics_process() entirely rather than just zeroing velocity -
	# zeroing velocity alone doesn't guarantee they stay put, since
	# _physics_process() would still apply gravity (if is_on_floor() ever
	# reads false for a stuck Darwinian) and still call move_and_slide()
	# every tick regardless. With physics processing off, nothing can move
	# this body at all - the only thing that changes a generating
	# Darwinian's fate from here is dying (health <= 0 in _process(),
	# which keeps running and calls queue_free() as normal).
	set_physics_process(false)


func _on_vision_area_body_entered(body: Node) -> void:
	# body != self (identity) instead of comparing .name strings - cheaper
	# and also correct even if two nodes happen to share a name.
	var is_enemy := false
	if body is Darwinian and body != self:
		# Tracked for separation regardless of team.
		nearby_darwinians[body.name] = body
		is_enemy = body.team_number != team_number
	elif body is Tower:
		# Enemy towers are attacked with the same laser (particles + audio)
		# as enemy darwinians - they just sit in the same combat dict.
		is_enemy = body.team != team_number

	if is_enemy:
		darwinians_in_area[body.name] = body
		# Only aim the beam - don't switch it on here. _process_combat_tick()
		# decides whether to actually fire based on line of sight, so an
		# enemy appearing behind a wall doesn't make the laser flash through
		# it for a few frames.
		_particle_material.direction = (body.global_position - global_position).normalized()


func _on_vision_area_body_exited(body: Node3D) -> void:
	if body is Darwinian and body != self:
		nearby_darwinians.erase(body.name)
		if body.team_number != team_number:
			darwinians_in_area.erase(body.name)
	elif body is Tower:
		darwinians_in_area.erase(body.name)
	if darwinians_in_area.is_empty():
		_particles.emitting = false


## Orders this darwinian to a point. `use_formation` is on by default (used
## when a whole team is ordered somewhere, so they march in lines), but road
## hops pass false - a per-hex path destination is the NEXT TILE's center,
## and scattering into a rank/file grid around it would fling units off the
## path and into the walls lining it.
func set_new_destination(new_destination: Vector3, use_formation: bool = true) -> void:
	curr_destination = new_destination + (_formation_offset(new_destination) if use_formation else Vector3.ZERO)
	has_destination = true
	# A fresh destination means a fresh start on the wall-avoidance budget.
	_wall_evading = false
	_wall_retries = 0
	_give_up_timer = 0.0
	# An explicit order replaces whatever route was being walked.
	_path = []
	_path_index = 0
	_dispersing = false

	# Without this, range_to_roam can still be sitting at
	# range_to_roam_close (widened on the *previous* arrival) and only
	# narrows back down inside the "still traveling" branch in _process() -
	# which requires dist_sq > range_sq to even run. If the new (offset)
	# destination happens to land within that lingering wide radius of
	# where the Darwinian currently is, dist_sq > range_sq never becomes
	# true, so move_to_pos() never gets called and the arrival check just
	# re-flags "arrived" instantly, on repeat, forever. Resetting here
	# guarantees every fresh destination starts from the tight radius.
	range_to_roam = range_to_roam_default


## Assigns a full route - the ordered world positions of every hex along a
## road, handed over as a whole by the road raycast when this darwinian walks
## over a road tile. It walks each waypoint in sequence and only the last one
## counts as arrival, so it follows the whole path instead of stopping to
## re-query the tile graph at every hex.
func follow_path(waypoints: Array) -> void:
	if waypoints.is_empty():
		return
	_path_objective = waypoints[waypoints.size() - 1]
	_dispersing = false
	# Fan the column out into parallel lanes across the road corridor
	# (perpendicular to the route's overall heading) so a team marches in a
	# visible formation instead of single file. Lanes are small on purpose -
	# the corridor is only about a hex wide, so a full rank/file grid would
	# push units onto the walls lining it.
	var lane := _path_lane_offset(waypoints)
	_path = []
	for w in waypoints:
		_path.append(w + lane)
	_path_index = 0
	_wall_evading = false
	_wall_retries = 0
	_give_up_timer = 0.0
	range_to_roam = range_to_roam_default
	curr_destination = _path[0]
	has_destination = true


## Slots this Darwinian into a rank/file grid around the requested target,
## instead of a random scatter, so a group ordered to the same point marches
## in lines rather than piling into a ball. Fully decentralized - there's
## no squad manager telling each unit which slot to take. Instead:
##
##  1. The "peer group" is whichever same-team Darwinians are currently in
##     this unit's own vision area - the exact same nearby_darwinians dict
##     already maintained for separation, so no extra tracking cost.
##  2. Peers are sorted by get_instance_id(), a stable per-object id. Since
##     every peer runs this same deterministic sort over (roughly) the same
##     visible set, they each land on the same ordering independently, with
##     no communication needed - that's what turns "N units each picking a
##     slot" into "N units picking DIFFERENT slots that tile a grid".
##  3. The grid is oriented using the group's own average position as the
##     origin (not each unit's individual position) so every peer computes
##     the same facing direction and the ranks/files line up consistently,
##     rather than each unit skewing the grid toward its own vantage point.
##
## Cost: one sort + one loop over "peers currently in vision", paid once
## per destination change - not per frame, and not over every Darwinian in
## the level, only the (typically small) visible cluster.
func _formation_offset(target: Vector3) -> Vector3:
	var peers: Array = [self]
	var centroid := global_position

	for other in nearby_darwinians.values():
		if other.team_number == team_number:
			peers.append(other)
			centroid += other.global_position

	if peers.size() <= 1:
		return Vector3.ZERO

	centroid /= peers.size()

	peers.sort_custom(func(a, b): return a.get_instance_id() < b.get_instance_id())
	var index := peers.find(self)

	var rank := index / formation_files
	var file := index % formation_files
	# Center the block of files on the target line instead of skewing the
	# whole formation to one side.
	var centered_file := float(file) - (float(formation_files - 1) / 2.0)

	# Facing basis built from the group's centroid to the target, so it's
	# shared by every peer regardless of where in the vision area they
	# happen to be standing right now.
	var forward := target - centroid
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var right := forward.cross(Vector3.UP)

	var offset := (right * centered_file * formation_file_spacing) \
		- (forward * rank * formation_rank_spacing)

	# Scale the slot down when the target is close: a slot flung beyond the
	# target is useless, and a slot flung sideways onto a wall just makes the
	# unit hit it and give up. Only a per-destination-change cost (one sqrt),
	# not on the per-frame hot path.
	var dist_to_target := (target - global_position).length()
	if dist_to_target > 0.01 and offset.length() > dist_to_target * 0.5:
		offset = offset.normalized() * (dist_to_target * 0.5)

	return offset


## The parallel-lane offset for this unit while marching a road route: a
## small sideways step perpendicular to the route's overall heading, so a
## whole team following the same road spreads into several lanes instead of
## single-file. Which lane a unit takes comes from the same deterministic
## peer sort as _formation_offset(), so everyone independently agrees who
## is in which lane.
func _path_lane_offset(waypoints: Array) -> Vector3:
	if waypoints.size() < 2:
		return Vector3.ZERO
	var heading = waypoints[waypoints.size() - 1] - waypoints[0]
	heading.y = 0.0
	if heading.length_squared() < 0.0001:
		return Vector3.ZERO
	heading = heading.normalized()
	var right := Vector3(-heading.z, 0.0, heading.x)

	# Reuse the formation slot resolution (same peer sort) so the lane a
	# unit picks is stable and shared: file index -> lateral offset.
	var peers: Array = [self]
	for other in nearby_darwinians.values():
		if other.team_number == team_number:
			peers.append(other)
	if peers.size() <= 1:
		return Vector3.ZERO
	peers.sort_custom(func(a, b): return a.get_instance_id() < b.get_instance_id())
	var index := peers.find(self)
	var file := index % formation_files
	var centered_file := float(file) - (float(formation_files - 1) / 2.0)
	return right * centered_file * PATH_LANE_SPACING


## The fan-out spot for this unit once it reaches the end of a route: a
## point on a ring around `objective`, spread by the same deterministic
## peer sort, so a team that arrives together spreads out around the
## objective instead of piling onto the last hex's center. The ring radius
## is a few units, so units end up scattered around the objective but still
## within reach of it.
func _disperse_offset(objective: Vector3) -> Vector3:
	var peers: Array = [self]
	for other in nearby_darwinians.values():
		if other.team_number == team_number:
			peers.append(other)
	if peers.size() <= 1:
		# Alone: still walk a little off the objective so it doesn't look
		# like the unit is standing exactly on top of it.
		return Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))
	peers.sort_custom(func(a, b): return a.get_instance_id() < b.get_instance_id())
	var index := peers.find(self)
	var count := peers.size()
	var angle := TAU * float(index) / float(count)
	var radius := 4.0 + float(index % 3) * 2.0
	return Vector3(cos(angle), 0.0, sin(angle)) * radius


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
	_sprite.modulate = team_color * randf_range(0.6, 1.0)
	var mat: ORMMaterial3D = _particles.draw_pass_1.material
	mat.albedo_color = team_color
	mat.emission = team_color


func _xz_distance_sq_to_objective() -> float:
	var diff := global_position - curr_destination
	return diff.x * diff.x + diff.z * diff.z


## Kept in case anything outside this script calls it directly - same
## result as before, it's just no longer used internally on the hot path.
func get_xy_distance_from_objective() -> float:
	return sqrt(_xz_distance_sq_to_objective())
