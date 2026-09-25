extends SceneTree

## Live GPU probe of the barrack pipeline:
##   godot --rendering-driver vulkan --resolution 320x200 --quit-after N \
##     -s res://Tests/barrack_flow_probe.gd
##
## Boots the real MainScreen scene, joins a team, drops barracks through the
## real phone placement path (_on_building_placed_remote), starts the match,
## and watches construction + production on the actual GPU sim. Everything
## is printed with the PROBE prefix. Needs a real RenderingDevice (the sim's
## buffers are created in _ready), so it does NOT run with a headless display
## driver - use a small window instead.

var main: Node = null
var ss: Node = null
var mgr: Node = null
var site_cells: Array = []      # grid cells (Vector2i) of the placed barracks
var site_hexes: Array = []      # (col,row) of each placed barrack
var site_nodes: Array = []      # their Node3D meshes
var elapsed := 0.0
var seconds := 0
var started := false

const WATCH_SECONDS := 22
const SITE_DEFS := [Vector2i(5, 5), Vector2i(20, 10)]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# The RenderingDevice only exists once the first frame has been drawn,
	# so wait for it BEFORE instancing the scene (the sim's _ready builds all
	# of its GPU buffers in one shot).
	for i in range(600):
		await process_frame
		if RenderingServer.get_rendering_device() != null:
			break
	if RenderingServer.get_rendering_device() == null:
		print("PROBE FAIL: no RenderingDevice - run WITHOUT --headless/--display-driver headless")
		quit(1)
		return

	var scene: Node = (load("res://MainScreen/MainScreen.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	main = scene
	# Wait until the terrain + sim are fully up (heightmap uploaded).
	for i in range(900):
		await process_frame
		var node := main.get_node_or_null("StupidSimple")
		var sim: Node = node.get_child(0) if node != null and node.get_child_count() > 0 else null
		if sim != null and int(sim.get("heightmap_width")) > 0 and main.hex_nodes.size() > 0:
			ss = sim
			break
	if ss == null:
		print("PROBE FAIL: sim never came up")
		quit(1)
		return
	print("PROBE sim up: grid=%dx%d dots_per_team=%d" % [main.grid_width, main.grid_depth, main.dots_per_team])

	# A phone joins (team 0), then two barracks are dropped through the real
	# placement path.
	main._on_player_joined(0)
	await process_frame
	print("PROBE team 0 active: %s  pool=%.0f" % [str(ss.is_team_active(0)), ss.get_team_resource(0)])

	for cell in SITE_DEFS:
		main._on_building_placed_remote(cell.x, cell.y, 0, 0)
		await process_frame
		site_hexes.append(cell)
	mgr = main.get_node_or_null("HexBuildingManager")
	var keys: Array = mgr._hex_buildings.keys()
	keys.sort()
	for key in keys:
		site_nodes.append(mgr._hex_buildings[key])
	print("PROBE placed %d barracks (mgr keys %s)" % [site_nodes.size(), str(keys)])
	for node in site_nodes:
		var wp: Vector3 = node.global_position
		var cx := int(floor((wp.x - ss.WORLD_MIN.x) / ss.CELL_SIZE))
		var cz := int(floor((wp.z - ss.WORLD_MIN.z) / ss.CELL_SIZE))
		site_cells.append(Vector2i(cx, cz))
		var word: int = ss.get_building_word(cx, cz)
		print("PROBE site at %s -> cell (%d,%d) word=0x%08x built=%s"
				% [str(wp), cx, cz, word, str(ss.is_building_built(cx, cz))])

	# Start the match: the sim begins stepping and the economy ticks.
	main._start_match()
	print("PROBE match started (game_started=%s)" % str(ss.game_started))
	started = true


func _process(delta: float) -> bool:
	if ss == null or not started:
		return false
	elapsed += delta
	if elapsed < 1.0:
		return false
	elapsed -= 1.0
	seconds += 1
	var alive := _team_alive(0)
	var built_flags: Array = []
	for c in site_cells:
		built_flags.append(ss.is_building_built(c.x, c.y))
	var mesh_scale := ""
	for node in site_nodes:
		if is_instance_valid(node):
			mesh_scale += " %.2f" % node.scale.x
		else:
			mesh_scale += " (freed)"
	print("PROBE t=%3ds pool=%9.0f alive=%5d built=%s mesh_scale=%s cursor=%d"
			% [seconds, ss.get_team_resource(0), alive, str(built_flags), mesh_scale, ss._slot_cursor()])
	if seconds > 10 and (seconds % 4) == 0:
		_sample_new_dots()
	if seconds == 2:
		_dump_site_details()
	if seconds >= WATCH_SECONDS:
		_verdict()
		quit(0)
		return true
	return false


func _team_alive(team: int) -> int:
	var data: PackedByteArray = ss.rd.buffer_get_data(ss.econ_stats_rid, 0, 2 * ss.num_teams * 4)
	if data.size() < 2 * ss.num_teams * 4:
		return -1
	return int(data.decode_u32(team * 2 * 4))


func _dump_site_details() -> void:
	print("PROBE POLL: pending_builds=%d timer_active=%s" % [main._pending_builds.size(), str(main._build_poll_timer != null and not main._build_poll_timer.is_stopped())])
	for i in range(site_hexes.size()):
		var cell: Vector2i = site_hexes[i]
		var c: Vector2i = site_cells[i]
		var word: int = ss.get_building_word(c.x, c.y)
		var hex := ss.world_to_hex(Vector2(ss.WORLD_MIN.x + (float(c.x) + 0.5) * ss.CELL_SIZE,
				ss.WORLD_MIN.z + (float(c.y) + 0.5) * ss.CELL_SIZE))
		# Where are this team's dots standing? Count dots inside this hex.
		var row: PackedByteArray = ss.rd.buffer_get_data(ss.state_buffers[ss.frame_parity], 0, ss.instance_count * 64)
		var dots_here := 0
		var closest := -1.0
		if row.size() >= ss.instance_count * 64:
			var site_world: Vector2 = Vector2(ss.WORLD_MIN.x + (float(c.x) + 0.5) * ss.CELL_SIZE,
					ss.WORLD_MIN.z + (float(c.y) + 0.5) * ss.CELL_SIZE)
			for id in range(ss._dots_per_team):
				if row.decode_u32(id * 64 + 48) == 0:
					continue
				var dx := row.decode_float(id * 64)
				var dz := row.decode_float(id * 64 + 8)
				var d := Vector2(dx, dz).distance_to(site_world)
				if d < 10.0:
					dots_here += 1
				if closest < 0.0 or d < closest:
					closest = d
		print("PROBE SITE hex=%s cell=%s word=0x%08x dots_within_10u=%d closest_dot=%s"
				% [str(hex), str(c), word, dots_here, "%.1f" % closest if closest >= 0.0 else "n/a"])


func _sample_new_dots() -> void:
	# Produced dots live in slots >= the seeded army size; sample some and
	# compare their Y against the terrain height at their own XZ.
	var base: int = ss._dots_per_team
	var checked := 0
	var buried := 0
	for id in range(base, mini(base + 40, ss.instance_count)):
		var row: PackedByteArray = ss.rd.buffer_get_data(ss.state_buffers[ss.frame_parity], id * 64, 64)
		if row.size() < 64:
			continue
		if row.decode_u32(48) == 0:
			continue
		var pos := Vector3(row.decode_float(0), row.decode_float(4), row.decode_float(8))
		var ground: float = ss.get_ground_height(pos.x, pos.z)
		var diff := pos.y - ground
		if diff < -1.0:
			buried += 1
			print("PROBE   produced dot %d at %s but ground %.2f (BURIED by %.2f)" % [id, str(pos), ground, -diff])
		checked += 1
	print("PROBE produced-dot sample: %d alive slots checked, %d buried" % [checked, buried])


func _verdict() -> void:
	var any_built := false
	for c in site_cells:
		if ss.is_building_built(c.x, c.y):
			any_built = true
	var pool: float = ss.get_team_resource(0)
	var spent: float = 252000.0 - pool
	print("PROBE VERDICT: barracks_built=%s pool_spent=%.0f" % [str(any_built), spent])
	if not any_built:
		print("PROBE VERDICT FAIL: dots never finished building the barracks")
	elif spent < 100.0:
		print("PROBE VERDICT FAIL: built barracks produced/revived nothing")
	else:
		print("PROBE VERDICT OK: construction + production both ran")
