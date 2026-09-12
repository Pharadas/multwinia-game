#@tool
extends Node3D

const darwinian_scene := preload("res://MainScreen/Darwinian.tscn")

## Experimental GPU-dot darwinian: one node that renders a cloud of dots,
## each dot's motion computed on the GPU (see GpuDarwinian.tscn and
## gpu_swarm.gdshader).
const gpu_darwinian_scene := preload("res://MainScreen/GpuDarwinian.tscn")

## The tile scene: a StaticBody3D root with hex_tile.gd attached.
## Adjust this path once you've saved that scene.
const hex_tile_scene := preload("res://MainScreen/HexTile.tscn")

## The falling crate a team captures to build a tower, and the tower itself.
const drop_box_scene := preload("res://WorldObjects/DropBox.tscn")
const tower_scene := preload("res://WorldObjects/Tower.tscn")

## Emitted when any hexagon sector is left-clicked.
signal hexagon_clicked(col: int, row: int, world_position: Vector3)

## Emitted once generate_terrain() has finished spawning every tile - other
## systems (e.g. HexGrid2D) can wait on this before reading tile colors.
signal terrain_ready

@export var heightmap_image: NoiseTexture2D
@export var height_scale: float = 10.0
@export var mesh_scale: float = 1.0

## Hexagon sector settings
@export var hex_size: float = 1.0          # radius of each hexagon, in pre-mesh_scale units
@export var grid_width: int = 20           # number of hex columns
@export var grid_depth: int = 20           # number of hex rows
@export var random_seed: int = 0           # 0 = randomize every run, non-zero = deterministic

## When true, a team that joins gets its starting darwinians as GPU dot
## swarms (GpuDarwinian) instead of 20 per-unit CharacterBody3D nodes.
@export var use_gpu_darwinians: bool = true

## How many swarms each joining team starts with when use_gpu_darwinians
## is on.
@export var gpu_swarms_per_team: int = 1

## How many dots each team starts with in the GPU swarm. Both teams use the
## same starting count, so the total army is 2 * dots_per_team. The sim caps
## it to the multimesh instance budget automatically.
@export_range(0, 200000, 1) var dots_per_team: int = 500

## Chance that an interior hex tile - outside the outermost ring and the
## team corner bases, which are always structured - becomes a solid wall.
## A wall tile covers its whole hexagon and nobody can pass through it - a
## darwinian that walks into one gives up on its current destination and
## stops (see _stop_at_wall() in DarwinianLogic.gd).
##
## Defaults to 0 so the ONLY walled structures on the map are the four team
## corner bases (and the mandatory outermost ring) - random wall clusters
## in the middle read as extra bases. Bump this up if you want scattered
## obstacles back.
@export_range(0.0, 1.0) var wall_tile_chance: float = 0.0

## How finely each hexagon is tessellated internally so it can follow the
## heightmap's detail. Independent of hex_size/grid_width/grid_depth.
@export_range(1, 1000) var hex_detail: int = 64

## Path to hex_sector.gdshader (flat normals + vertex color albedo).
@export var shader_path: String = "res://hex_sector.gdshader"

## Optional: a HexTerrainSocket node (same instance/process as this terrain)
## to push the finished terrain out over the network once generation
## completes. The 2D grid now runs in a separate instance, so this replaces
## reaching for it via a direct NodePath.
@export var hex_terrain_socket_path: NodePath

## Vector2i(col, row) -> HexTile, so other scripts can grab a specific hex.
var hex_nodes: Dictionary = {}
var spawned_teams: Dictionary = {}

## team -> Array of lattice swarm nodes, so road changes can be pushed into
## each team's army.
var _team_swarms: Dictionary = {}

## While no crate is currently on the map, one drops from the sky every
## DROP_INTERVAL seconds.
const DROP_INTERVAL := 45.0
var _drop_timer := 0.0

## One walled corner base per team, computed dynamically from the ACTUAL
## grid size (see _compute_team_bases()) so the bases are always in the four
## corners of the map, whatever grid_width/grid_depth are. Each is a
## [min_col, min_row, max_col, max_row] rectangle just inside the outermost
## (always-wall) ring, enclosed by walls with a single exit facing the map
## center, and gets exactly one generator - see _build_team_bases(). Keep
## max_teams (socket.gd) in sync with the team count (4 corners).
var team_bases: Array = []

## Team-base layout state, computed by _build_team_bases() before any tile
## is spawned. Keys are "col_row" tile keys (see _tile_key()).
var _force_walls := {}          # tiles that must be walls (base perimeters)
var _force_open := {}           # tiles that must be open (interiors, exits, corridors)
var _force_generators := {}     # tiles that must spawn exactly one generator
var _no_random_generators := {} # tiles that must NOT roll a random generator


func _ready() -> void:
	heightmap_image.noise.seed = randi()
	# The corner bases must exist before the first player can join, and they
	# must follow the ACTUAL grid size - not a hardcoded layout.
	# _compute_team_bases()
	# Required for CollisionObject3D.input_event to fire on mouse clicks.
	get_viewport().physics_object_picking = true
	_disable_legacy_collision()
	# Connected before generate_terrain() so the first crate drop isn't
	# missed if terrain generation finishes synchronously.
	terrain_ready.connect(_on_terrain_ready)
	generate_terrain()

	var socket := get_node_or_null("Socket")
	if socket and socket.has_signal("drawn_path_received"):
		socket.drawn_path_received.connect(_on_drawn_path_received)
	if socket and socket.has_signal("building_placed_remote"):
		socket.building_placed_remote.connect(_on_building_placed_remote)
	# The sim node is instanced with the scene, but its script child may not
	# exist yet during _ready - defer so the connection always lands.
	call_deferred("_connect_sim_signals")


## Hooks the GPU sim's economy signals (see stupid_simple.gd).
func _connect_sim_signals() -> void:
	var ss_node := get_node_or_null("StupidSimple")
	if ss_node == null or ss_node.get_child_count() == 0:
		return
	var ss = ss_node.get_child(0)
	if ss.has_signal("mine_collapsed") and not ss.mine_collapsed.is_connected(_on_mine_collapsed):
		ss.mine_collapsed.connect(_on_mine_collapsed)
	# Mine ownership changes drive the 3D building color + phone tile color.
	if ss.has_signal("mine_owner_changed") and not ss.mine_owner_changed.is_connected(_on_mine_owner_changed):
		ss.mine_owner_changed.connect(_on_mine_owner_changed)
	if ss.has_signal("resources_changed") and not ss.resources_changed.is_connected(_on_resources_changed):
		ss.resources_changed.connect(_on_resources_changed)
	# Size the sim's team slots to the socket's playable team count plus the
	# reserved NPC horde slot, so both sides always agree. No-op after start.
	var socket := get_node_or_null("Socket")
	if socket != null and "max_teams" in socket and ss.has_method("set_num_teams"):
		ss.set_num_teams(int(socket.max_teams) + 1)
	if ss.has_method("set_dot_count_per_team"):
		ss.set_dot_count_per_team(dots_per_team)
	# Give any already-connected phone the current pools immediately.
	if ss.has_method("get_team_resources"):
		_send_resources_to_phones(ss.get_team_resources())


## The sim's resource pools changed (once per economy tick): broadcast them
## so every phone can show its own team's amount.
func _on_resources_changed(resources: Array) -> void:
	_send_resources_to_phones(resources)


func _send_resources_to_phones(resources: Array) -> void:
	var socket := get_node_or_null("Socket")
	if socket == null or not socket.has_method("broadcast_team_resources"):
		return
	# Broadcast every pool EXCEPT the sim's reserved NPC horde slot (last
	# index) - deserters don't own resources and no phone is that team.
	var player_pools: int = maxi(resources.size() - 1, 0)
	for t in range(player_pools):
		socket.broadcast_team_resources(t, float(resources[t]))


## A depleted mine's ground tile collapsed: remove the building mesh and
## destroy the hex tile itself. The GPU sim already dropped every boid that
## was standing on it (they fell and died - see sim.glsl's collapse block).
func _on_mine_collapsed(cell: Vector2i, world_pos: Vector2) -> void:
	# The signal carries the GPU grid cell; find the hex tile nearest its
	# world position (robust against any cell/hex indexing mismatch).
	var best: HexTile = null
	var best_d := INF
	for key in hex_nodes.keys():
		var tile: HexTile = hex_nodes[key]
		var d := tile.global_position.distance_squared_to(Vector3(world_pos.x, tile.global_position.y, world_pos.y))
		if d < best_d:
			best_d = d
			best = tile
	if best == null:
		return
	var mgr := get_node_or_null("HexBuildingManager")
	if mgr and mgr.has_method("clear_hex"):
		mgr.clear_hex(best.col, best.row)
	hex_nodes.erase(Vector2i(best.col, best.row))
	best.queue_free()


func _on_player_joined(team: int) -> void:
	pass
# 	if team < 0 or team >= team_bases.size():
# 		return
# 	if spawned_teams.has(team):
# 		return
# 	spawned_teams[team] = true
# 	_spawn_team_army(team)


func _on_drawn_path_received(points: Array, team: int, fraction: float = 1.0) -> void:
	var ss = $StupidSimple.get_child(0)
	if points.is_empty():
		print("no points to draw path!")
		return
	var slot: int = ss.set_path(points, 0, 0, team)
	# Apply the follower percentage to every hex the path starts from - boids
	# claim paths at the path's start hex, so that's where the gate lives.
	var start_hex: Vector2i = ss.world_to_hex(Vector2(points[0].x, points[0].y))
	ss.set_path_fraction(start_hex.x, start_hex.y, team, fraction)
	print("Global path set: %d points for team %d (fraction %.2f)" % [points.size(), team, fraction])
	# Persistent 3D ribbon: stays until the path expires AND every boid that
	# claimed it has arrived (GPU follower count hits zero).
	if slot >= 0:
		var hex_id: int = ss.hex_to_id(start_hex.x, start_hex.y)
		_spawn_path_visual(points, hex_id, team, slot, ss.get_path_expiry(hex_id, team, slot))


# ---- drawn path visuals -----------------------------------------------------
## One entry per drawn path: {mesh, hex_id, team, slot, expiry}. The ribbon
## stays visible until the path expires AND no boids are following it
## (count.glsl's per-slot follower counters hit zero).
var _path_visuals: Array = []
var _path_visual_timer := 0.0


func _spawn_path_visual(points: Array, hex_id: int, team: int, slot: int, expiry: float) -> void:
	var imm := ImmediateMesh.new()
	imm.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var width := 0.8
	var height := 1.5
	var prev := Vector3.INF
	for p in points:
		var cur := Vector3(float(p.x), height, float(p.y))
		if prev != Vector3.INF:
			var dir := cur - prev
			dir.y = 0.0
			if dir.length() > 0.01:
				var n := Vector3(-dir.z, 0.0, dir.x).normalized() * (width * 0.5)
				imm.surface_add_vertex(prev - n)
				imm.surface_add_vertex(prev + n)
				imm.surface_add_vertex(cur + n)
				imm.surface_add_vertex(prev - n)
				imm.surface_add_vertex(cur + n)
				imm.surface_add_vertex(cur - n)
		prev = cur
	imm.surface_end()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	match team % 4:
		0: mat.albedo_color = Color(1.0, 0.25, 0.25, 0.65)
		1: mat.albedo_color = Color(0.25, 1.0, 0.25, 0.65)
		2: mat.albedo_color = Color(0.3, 0.5, 1.0, 0.65)
		_: mat.albedo_color = Color(1.0, 0.9, 0.25, 0.65)
	var mi := MeshInstance3D.new()
	mi.mesh = imm
	mi.material_override = mat
	add_child(mi)
	_path_visuals.append({"mesh": mi, "hex_id": hex_id, "team": team, "slot": slot, "expiry": expiry})


## Every 0.5 s: free a path ribbon once its expiry has passed AND the GPU
## reports no boids still following its (hex, team, slot) - i.e. every unit
## that claimed it has arrived. While stragglers remain, an expired path
## fades to 25% so it's clear no NEW boids can claim it.
func _update_path_visuals(delta: float) -> void:
	if _path_visuals.is_empty():
		return
	_path_visual_timer += delta
	if _path_visual_timer < 0.5:
		return
	_path_visual_timer = 0.0
	var ss_node := get_node_or_null("StupidSimple")
	var ss = ss_node.get_child(0) if ss_node and ss_node.get_child_count() > 0 else null
	if ss == null or not ss.has_method("get_path_followers"):
		return
	var now: float = ss._elapsed_seconds
	var i := _path_visuals.size() - 1
	while i >= 0:
		var v: Dictionary = _path_visuals[i]
		var mi: MeshInstance3D = v.mesh
		if not is_instance_valid(mi):
			_path_visuals.remove_at(i)
		else:
			var expired: bool = float(v.expiry) > 0.0 and now > float(v.expiry)
			if expired:
				var followers: int = ss.get_path_followers(int(v.hex_id), int(v.team), int(v.slot))
				if followers <= 0:
					mi.queue_free()
					_path_visuals.remove_at(i)
				else:
					var m := mi.material_override as StandardMaterial3D
					if m and m.albedo_color.a > 0.3:
						m.albedo_color.a = 0.25
		i -= 1


## A phone dropped a building on hex (col, row) as a WHOLE. It starts as a
## construction site: a ghost mesh + unbuilt flag in the GPU cell_info buffer.
## Boids from the owning team march there and flip the flag (sim.glsl's
## construction block); a poll timer then swaps in the full-size mesh.
func _on_building_placed_remote(col: int, row: int, building_id: int, team: int) -> void:
	# PAY FIRST: walls cost the placing team 100 resources. A team that
	# can't afford it gets nothing - no ghost, no GPU site, no refund.
	var ss_node := get_node_or_null("StupidSimple")
	var ss_pay = ss_node.get_child(0) if ss_node and ss_node.get_child_count() > 0 else null
	if ss_pay and ss_pay.has_method("can_afford_building") and not ss_pay.can_afford_building(building_id, team):
		print("Placement rejected: team %d can't afford building %d" % [team, building_id])
		return
	if ss_pay and ss_pay.has_method("charge_building"):
		ss_pay.charge_building(building_id, team)

	var mgr := get_node_or_null("HexBuildingManager")
	if not mgr:
		mgr = HexBuildingManager.new()
		mgr.name = "HexBuildingManager"
		mgr.hex_size = hex_size
		mgr.mesh_scale = mesh_scale
		# ".." resolves to THIS node once the manager is added as a child -
		# "." would resolve to the manager itself, which broke placement.
		mgr.terrain_path = NodePath("..")
		add_child(mgr)
	var node: Node3D = mgr.place_building(col, row, building_id, team, false)

	# Push the UNBUILT building into the GPU cell_info buffer (sim.glsl reads
	# it and sends builders). The building occupies its hex center.
	_push_building_to_cell_info(col, row, building_id, team, node, false)
	# Track the site so the poll can complete it later. placed_at feeds the
	# builder-count estimate: build work is fixed, so a site that finished
	# fast must have had many dots building it (drives the grow animation).
	_pending_builds.append({"node": node, "building_id": building_id, "team": team, "placed_at": Time.get_ticks_msec()})
	if _build_poll_timer == null:
		_build_poll_timer = Timer.new()
		_build_poll_timer.wait_time = 0.5
		_build_poll_timer.timeout.connect(_poll_building_builds)
		add_child(_build_poll_timer)
	if not _build_poll_timer.is_stopped() or _pending_builds.size() == 1:
		_build_poll_timer.start()

var _pending_builds: Array = []
var _build_poll_timer: Timer = null

## Every 0.5s, check the GPU built-flag for each pending construction site;
## when a boid has flipped it, swap the ghost mesh for the real building.
func _poll_building_builds() -> void:
	var ss_node := get_node_or_null("StupidSimple")
	var ss = ss_node.get_child(0) if ss_node and ss_node.get_child_count() > 0 else null
	var mgr := get_node_or_null("HexBuildingManager")
	var i := _pending_builds.size() - 1
	while i >= 0:
		var site: Dictionary = _pending_builds[i]
		var node: Node3D = site.node
		if not is_instance_valid(node):
			_pending_builds.remove_at(i)
			i -= 1
			continue
		if ss and ss.has_method("is_building_built"):
			# Resolve the site's world position back to its grid cell.
			var wp := node.global_position
			var cx := int(floor((wp.x - ss.WORLD_MIN.x) / ss.CELL_SIZE))
			var cz := int(floor((wp.z - ss.WORLD_MIN.z) / ss.CELL_SIZE))
			if ss.is_building_built(cx, cz):
				if mgr and mgr.has_method("set_built"):
					# Builder estimate: total work is fixed (BUILD_WORK = 200
					# builder-frames in sim.glsl), so work / elapsed frames
					# = how many dots were building simultaneously. Feeds the
					# grow-animation speed (crowds build -> fast growth).
					var elapsed_s := float(Time.get_ticks_msec() - int(site.get("placed_at", Time.get_ticks_msec()))) / 1000.0
					# Build work is fixed per building type (sim.glsl: 200
					# builder-frames for most, 600 for walls = ~10s), so
					# work / elapsed frames = how many dots were building
					# simultaneously (drives the grow animation speed).
					var total_work := 600.0 if int(site.get("building_id", -1)) == 2 else 200.0
					var builders := clampi(roundi(total_work / maxf(elapsed_s * 60.0, 1.0)), 1, 50)
					mgr.set_built(node, builders)
				# Re-mark the buffer built (boid already did it, this keeps
				# CPU/GPU in sync if the buffer was re-uploaded meanwhile).
				if ss.has_method("set_cell_building"):
					ss.set_cell_building(Vector2(wp.x, wp.z), site.building_id, site.team, 0, 0, true)
				_pending_builds.remove_at(i)
		i -= 1
	if _pending_builds.is_empty() and _build_poll_timer:
		_build_poll_timer.stop()


## A mine was captured (from neutral or stolen from another team). Recolor
## its 3D building mesh to the new owner's team color.
func _on_mine_owner_changed(cell: Vector2i, world_pos: Vector2, team: int) -> void:
	var mgr := get_node_or_null("HexBuildingManager")
	if mgr == null or not mgr.has_method("recolor_building_at"):
		return
	var hex := _hex_of_world(Vector2(world_pos.x, world_pos.y))
	if hex.x < 0:
		return
	mgr.recolor_building_at(hex, team)


## Nearest hex to a world-space XZ point (Vector2 = x, z), or (-1,-1).
func _hex_of_world(world_pos: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := INF
	for key in hex_nodes.keys():
		var tile: HexTile = hex_nodes[key]
		var d := tile.global_position.distance_squared_to(Vector3(world_pos.x, tile.global_position.y, world_pos.y))
		if d < best_d:
			best_d = d
			best = key
	return best


## Writes packed info into the cell covering the hex's center. Buildings are
## whole-hex now, so the world position is the hex center itself.
func _push_building_to_cell_info(col: int, row: int, building_id: int, team: int, node: Node3D, built: bool = true) -> void:
	var ss_node := get_node_or_null("StupidSimple")
	if not ss_node or ss_node.get_child_count() == 0:
		return
	var ss = ss_node.get_child(0)
	if not ss.has_method("set_cell_building"):
		return
	# node.global_position IS the hex center (the manager places it there);
	# resolve that to its grid cell. set_cell_building takes the XZ plane.
	var wp := node.global_position
	ss.set_cell_building(Vector2(wp.x, wp.z), building_id, team, 0, 0, built)

## The old single-mesh version of this script wrote the whole terrain's
## collision into a CollisionShape3D sibling (under the parent StaticBody3D).
## That node still exists in older scenes and is stale now that collision is
## per-hex - if left alone it keeps blocking clicks (its input_ray_pickable
## defaults to true) and gives characters a floating/mismatched ground to
## stand on. Disable it so it stops interfering; safe to delete by hand too.
func _disable_legacy_collision() -> void:
	var legacy_shape := get_node_or_null("../CollisionShape3D")
	if legacy_shape and legacy_shape is CollisionShape3D:
		legacy_shape.disabled = true
		legacy_shape.shape = null

	var legacy_body := get_parent()
	if legacy_body is StaticBody3D:
		legacy_body.input_ray_pickable = false


## Layout constants shared by generation and coordinate lookup.
func _layout() -> Dictionary:
	var hex_width := hex_size * 2.0
	var hex_height := sqrt(3.0) * hex_size
	var horiz_spacing := hex_width * 0.75
	var vert_spacing := hex_height
	return {
		"horiz_spacing": horiz_spacing,
		"vert_spacing": vert_spacing,
		"total_width": (grid_width - 1) * horiz_spacing,
		"total_depth": grid_depth * vert_spacing,
	}


## Returns the world-space center of a given hex sector (useful for highlight
## overlays, camera focusing, etc).
func get_hex_center(col: int, row: int) -> Vector3:
	var l := _layout()
	var center_u: float = col * l.horiz_spacing - l.total_width / 2.0
	var center_v: float = row * l.vert_spacing + (l.vert_spacing * 0.5 if col % 2 == 1 else 0.0) - l.total_depth / 2.0

	var y := 0.0
	if heightmap_image:
		var img := heightmap_image.get_image()
		if img:
			y = HexTile._sample_height(img, img.get_width(), img.get_height(), center_u, center_v, height_scale)

	return Vector3(center_u * mesh_scale, y, center_v * mesh_scale)


## Returns the HexTile for a given hex sector, or null if out of range.
func get_hex_node(col: int, row: int) -> HexTile:
	return hex_nodes.get(Vector2i(col, row))


func generate_terrain() -> void:
	if not heightmap_image:
		return
	# NoiseTexture2D generates its image on a background thread. If it
	# finished BEFORE we get here, `changed` already fired and will never
	# fire again - awaiting it unconditionally would hang forever with zero
	# tiles and no error. Only wait if there's genuinely no image yet.
	if not heightmap_image.get_image():
		await heightmap_image.changed

	_clear_hexes()

	var img: Image = heightmap_image.get_image()
	var width: int = img.get_width()
	var depth: int = img.get_height()

	var rng := RandomNumberGenerator.new()
	if random_seed != 0:
		rng.seed = random_seed
	else:
		rng.randomize()

	var l := _layout()

	# One shared material for every hex - fine since coloring comes from
	# per-vertex COLOR baked into each hex's own mesh, not a material uniform.
	var shared_mat := ShaderMaterial.new()
	var shader_res := load(shader_path)
	if shader_res is Shader:
		shared_mat.shader = shader_res
	else:
		push_warning("hex_terrain.gd: couldn't load shader at %s, falling back to vertex-color material." % shader_path)
		var fallback := StandardMaterial3D.new()
		fallback.vertex_color_use_as_albedo = true
		shared_mat = null

	# Work out the team base walls/exits/generators before any tile spawns,
	# so each tile below can consult them.
	_build_team_bases()

	# Cache of already-computed vertices, keyed by a rounded (u,v) position, so
	# neighboring hexagons that share an edge/corner get bit-identical
	# positions and heights -> no seams between separate hex meshes.
	var vertex_cache := {}

	for col in range(grid_width):
		for row in range(grid_depth):
			var center_u: float = col * l.horiz_spacing - l.total_width / 2.0
			var center_v: float = row * l.vert_spacing + (l.vert_spacing * 0.5 if col % 2 == 1 else 0.0) - l.total_depth / 2.0
			var sector_color := Color(float(col) / float(grid_width), rng.randf(), float(row) / float(grid_depth))
			var key := _tile_key(col, row)
			# The outermost layer is ALWAYS walls; the center hub tile and the
			# team base interiors/exits/corridors are always open. Everything
			# else rolls against wall_tile_chance.
			var is_outer := col == 0 or col == grid_width - 1 or row == 0 or row == grid_depth - 1
			var forced_wall := is_outer or _force_walls.has(key)
			var forced_open := (col == grid_width / 2 and row == grid_depth / 2) or _force_open.has(key)
			var is_wall := forced_wall
			if not forced_wall and not forced_open:
				is_wall = rng.randf() < wall_tile_chance
			_spawn_hex(col, row, img, width, depth, center_u, center_v, sector_color, shared_mat, vertex_cache, is_wall)

	terrain_ready.emit()
	_push_over_network()


## Actively pushes the freshly-generated terrain out through
## hex_terrain_socket_path, if one is assigned, so the (now separate) 2D
## instance can rebuild its view from it.
func _push_over_network() -> void:
	print(hex_terrain_socket_path)
	if hex_terrain_socket_path == NodePath():
		return
	var socket := $Socket
	if socket and socket.has_method("send_terrain"):
		socket.send_terrain(_gather_tile_data())


## Builds a plain-data (col, row, color) array suitable for sending over the
## network - no node references, just Variants HexGrid2DSocket can encode.
func _gather_tile_data() -> Array:
	var tiles: Array = []
	for key in hex_nodes.keys():
		var tile: HexTile = hex_nodes[key]
		# is_wall rides along so the phone can route drawn roads around wall
		# tiles instead of beelining straight through them.
		tiles.append({"col": tile.col, "row": tile.row, "color": tile.color, "is_wall": tile.is_wall})
	return tiles


func _clear_hexes() -> void:
	for child in get_children():
		if String(child.name).begins_with("Hex_"):
			child.queue_free()
	hex_nodes.clear()


## Returns a stable string key for a tile (used by the team-base dicts).
static func _tile_key(col: int, row: int) -> String:
	return "%d_%d" % [col, row]


## Returns whichever tile in `tiles` is closest to `center`.
func _nearest_to_center(tiles: Array, center: Vector2i) -> Vector2i:
	var best: Vector2i = tiles[0]
	var best_dist := INF
	for t in tiles:
		var d: float = (t - center).length_squared()
		if d < best_dist:
			best_dist = d
			best = t
	return best


## The six hex-adjacent tiles of (col, row) under this grid's staggered
## layout (odd columns are offset half a row, see get_hex_center()). Used
## to pick a base exit that actually borders the interior - a naive
## "closest to center" pick can land on a diagonal corner tile that never
## touches the room, leaving the team sealed in.
static func _hex_neighbors(col: int, row: int) -> Array:
	var out: Array = [Vector2i(col, row - 1), Vector2i(col, row + 1)]
	if col % 2 == 0:
		# Even column: diagonal neighbors sit at the same row and the row
		# above (odd columns are shifted down half a row).
		out.append(Vector2i(col - 1, row - 1))
		out.append(Vector2i(col - 1, row))
		out.append(Vector2i(col + 1, row - 1))
		out.append(Vector2i(col + 1, row))
	else:
		# Odd column: diagonal neighbors sit at the same row and the row
		# below.
		out.append(Vector2i(col - 1, row))
		out.append(Vector2i(col - 1, row + 1))
		out.append(Vector2i(col + 1, row))
		out.append(Vector2i(col + 1, row + 1))
	return out


## Precomputes the team corner bases: which tiles are forced walls (the
## perimeter ring around each base), which are forced open (base interiors,
## each base's single exit facing the map center, plus a short corridor from
## the exit toward the center), and which tile spawns each base's one
## generator. Called once at the start of generate_terrain().
func _build_team_bases() -> void:
	_force_walls.clear()
	_force_open.clear()
	_force_generators.clear()
	_no_random_generators.clear()

	var center_tile := Vector2i(grid_width / 2, grid_depth / 2)
	var exits: Array = []

	# First pass: interiors, perimeters, exits, and generators for every
	# base - all exits are known before any wall is laid down, so an exit
	# always wins over a neighboring base's perimeter wall.
	for base in team_bases:
		var min_c: int = base[0]
		var min_r: int = base[1]
		var max_c: int = base[2]
		var max_r: int = base[3]

		# Interior: always open, and never rolls a random generator.
		for c in range(min_c, max_c + 1):
			for r in range(min_r, max_r + 1):
				_force_open[_tile_key(c, r)] = true
				_no_random_generators[_tile_key(c, r)] = true

		# The corner-most interior tile hosts this base's one generator -
		# away from the spawn point (base center) and the exit.
		_force_generators[_tile_key(min_c, min_r)] = true

		# Perimeter ring: tiles just outside the base, restricted to the map
		# interior (the outermost ring is walls anyway).
		var perimeter: Array = []
		for c in range(min_c - 1, max_c + 2):
			for r in range(min_r - 1, max_r + 2):
				var on_ring := c == min_c - 1 or c == max_c + 1 or r == min_r - 1 or r == max_r + 1
				if not on_ring:
					continue
				if c < 1 or c > grid_width - 2 or r < 1 or r > grid_depth - 2:
					continue
				perimeter.append(Vector2i(c, r))

		# One exit: the perimeter tile closest to the map center that is
		# ACTUALLY hex-adjacent to the interior. Picking purely by distance
		# can land on a diagonal corner tile (e.g. top-right base's (25,3))
		# that borders the perimeter ring but never the room - the door
		# opens into a walled-off pocket and the team can never reach it.
		var exit_candidates: Array = []
		for p in perimeter:
			for n in _hex_neighbors(p.x, p.y):
				if n.x >= min_c and n.x <= max_c and n.y >= min_r and n.y <= max_r:
					exit_candidates.append(p)
					break
		exits.append({"perimeter": perimeter, "exit": _nearest_to_center(exit_candidates, center_tile)})

	# Second pass: open the exits + their corridors, then wall every other
	# perimeter tile (anything already in _force_open always wins).
	for entry in exits:
		var exit_tile: Vector2i = entry.exit
		_force_open[_tile_key(exit_tile.x, exit_tile.y)] = true
		# A short open corridor beyond the door toward the center, so the
		# exit isn't immediately sealed off by a random wall. Two tiles is
		# enough to clear the door while staying far short of any other
		# base on a corner-based map.
		var dir := Vector2i(signi(center_tile.x - exit_tile.x), signi(center_tile.y - exit_tile.y))
		var step := exit_tile + dir
		for _i in range(2):
			if step.x >= 1 and step.x <= grid_width - 2 and step.y >= 1 and step.y <= grid_depth - 2:
				_force_open[_tile_key(step.x, step.y)] = true
			step += dir

		for p in entry.perimeter:
			if not _force_open.has(_tile_key(p.x, p.y)):
				_force_walls[_tile_key(p.x, p.y)] = true


## Instances the tile scene and hands it everything it needs to build itself.
func _spawn_hex(col: int, row: int, img: Image, width: int, depth: int, center_u: float, center_v: float, color: Color, mat: Material, vertex_cache: Dictionary, is_wall: bool) -> void:
	var tile: HexTile = hex_tile_scene.instantiate()
	add_child(tile)
	var key := _tile_key(col, row)
	tile.is_wall = is_wall
	# tile.force_generator = _force_generators.get(key, false)
	tile.force_generator = false
	# tile.no_random_generator = _no_random_generators.has(key)
	tile.no_random_generator = true
	tile.build(col, row, img, width, depth, center_u, center_v, hex_size, hex_detail, height_scale, mesh_scale, color, mat, vertex_cache)
	tile.hex_clicked.connect(_on_hex_clicked)

	if tile.col == grid_width / 2 and tile.row == grid_depth / 2:
		# NOTE: this runs before hex_nodes[Vector2i(col, row)] = tile below,
		# and the grid is filled column-by-column, so pointing_to only ends
		# up with whichever hexes were already spawned earlier in the loop -
		# not the full grid. Say the word if you want it to wait for every
		# tile instead (e.g. hook this off terrain_ready).
		for hex_pos in hex_nodes.keys():
			tile.pointing_to.append(hex_nodes[hex_pos])

	hex_nodes[Vector2i(col, row)] = tile


func _on_hex_clicked(col: int, row: int, world_position: Vector3) -> void:
	hexagon_clicked.emit(col, row, world_position)
	print(world_position)


## Stores a road between two hexes. `path` is the wall-avoiding chain of hex
## cells the phone routed (each consecutive pair adjacent, no wall tiles). The
## WHOLE route is stored on the starting tile only - no intermediate hex gets
## its own path entry. A darwinian that steps on the start tile picks up the
## complete route and walks it, and nothing is written to the hexes the route
## passes through. A path with fewer than two cells (older callers, or a
## straight shot) falls back to a direct two-tile route.
func set_new_road(from_cell: Vector2i, to_cell: Vector2i, team_num: int, path: Array = []) -> void:
	if team_num < 0 or team_num >= team_bases.size():
		return
	var from_tile := get_hex_node(from_cell.x, from_cell.y)
	if from_tile == null:
		return
	var cells: Array = path if path.size() >= 2 else [from_cell, to_cell]

	# Resolve the routed cells to their tile nodes so the stored route is a
	# ready-to-walk chain. A re-drawn pair just overwrites the old entry
	# (the phone toggles roads anyway, so this is only defensive).
	var path_tiles: Array = []
	for c in cells:
		var t := get_hex_node(c.x, c.y)
		if t:
			path_tiles.append(t)
	if path_tiles.size() < 2:
		return

	var road_key := _road_key(from_cell, to_cell)
	from_tile.pointing_to[team_num][road_key] = path_tiles
	_notify_swarm_road(team_num, road_key, path_tiles)

## Removes a road. The route lives whole on whichever tile it started from, so
## this just erases that tile's entry (order-independent - the drag that
## removes a road can come from either end).
func remove_road(from_cell: Vector2i, to_cell: Vector2i, team_num: int) -> void:
	if team_num < 0 or team_num >= team_bases.size():
		return
	var key := _road_key(from_cell, to_cell)
	for c in [from_cell, to_cell]:
		var tile := get_hex_node(c.x, c.y)
		if tile and tile.pointing_to[team_num].has(key):
			tile.pointing_to[team_num].erase(key)
			_notify_swarm_remove(team_num, key)
			return

func clear_all_roads_for_team(team_num: int) -> void:
	if team_num < 0 or team_num >= team_bases.size():
		return
	for tile in hex_nodes.values():
		if tile:
			tile.pointing_to[team_num].clear()
	for swarm in _team_swarms.get(team_num, []):
		swarm.clear_roads()

## Pushes a newly drawn road into every lattice army of `team_num` so the
## dots re-route (the flow field gets rebuilt with the new road on the end).
func _notify_swarm_road(team_num: int, road_key: String, path_tiles: Array) -> void:
	for swarm in _team_swarms.get(team_num, []):
		swarm.set_road(road_key, path_tiles)

## Removes a road from every lattice army of `team_num`.
func _notify_swarm_remove(team_num: int, road_key: String) -> void:
	for swarm in _team_swarms.get(team_num, []):
		swarm.remove_road(road_key)

## Canonical, order-independent key for a (from, to) pair, so a road drawn
## either direction is found as the same road by remove_road().
static func _road_key(a: Vector2i, b: Vector2i) -> String:
	if a.y < b.y or (a.y == b.y and a.x <= b.x):
		return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
	return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]

func make_new_darwinian(pos, team):
	var darwinian := darwinian_scene.instantiate()
	add_child(darwinian)
	darwinian.set_team(team)
	darwinian.global_position = Vector3(pos)


## Spawns a GPU dot swarm (GpuDarwinian) for `team` at `pos` - the "dots
## instanced and controlled by the GPU" darwinian variant.
func make_new_gpu_darwinian(pos, team):
	var swarm := gpu_darwinian_scene.instantiate()
	add_child(swarm)
	swarm.set_team(team)
	swarm.global_position = Vector3(pos)


## Spawns a lattice army (BoidSwarm) for `team` at `pos`, sized over the
## map's terrain. Roads drawn for the team are baked into its lattice flow
## field (see set_new_road).
func make_new_lattice_swarm(pos: Vector3, team: int, dot_count: int = 256) -> void:
	var swarm_scene := preload("res://MainScreen/BoidSwarm.tscn")
	var swarm := swarm_scene.instantiate()
	add_child(swarm)
	swarm.dot_count = maxi(dot_count, 1)
	swarm.global_position = pos
	print("Lattice army: team %d, %d dots, spawn at %s" % [team, swarm.dot_count, pos])
	# Collect real hex tile positions so the swarm's lattice maps
	# exactly to the actual hex grid (no coordinate math mismatches).
	var real_hex_positions := []
	for key in hex_nodes.keys():
		var tile: HexTile = hex_nodes[key]
		real_hex_positions.append({
			"col": tile.col,
			"row": tile.row,
			"position": tile.global_position,
		})
	var terrain := {
		"heightmap_image": heightmap_image,
		"grid_width": grid_width,
		"grid_depth": grid_depth,
		"hex_size": hex_size,
		"mesh_scale": mesh_scale,
		"height_scale": height_scale,
		"hex_tiles": real_hex_positions,
	}
	swarm.initialize(team, pos, terrain)
	if not _team_swarms.has(team):
		_team_swarms[team] = []
	_team_swarms[team].append(swarm)


func _process(delta: float) -> void:
	_update_path_visuals(delta)
	# Keep the crate supply going: drop a new one every so often, but never
	# stack multiple crates at once.
	if hex_nodes.is_empty():
		return
	_drop_timer += delta
	# if _drop_timer >= DROP_INTERVAL:
	# 	_drop_timer = 0.0
	# 	if not _has_active_box():
	# 		_spawn_drop_box()


func _on_terrain_ready() -> void:
	# Mirror the terrain's wall hexes into the sim's cell_info buffer so
	# GPU-side boids actually collide with them. The shader's wall-block
	# only knows walls written to that buffer - without this it only ever
	# saw player-placed buildings, so dots walked straight through every
	# terrain wall. Team byte 255 = "terrain": it blocks every team, and
	# sim.glsl's hostile-building scan skips walls with that team so boids
	# don't march on the map's own scenery.
	var ss_node := get_node_or_null("StupidSimple")
	if ss_node == null or ss_node.get_child_count() == 0:
		return
	var ss = ss_node.get_child(0)
	# Bulk path: one read + one write of the whole cell_info buffer (~800
	# walls). Per-tile buffer_update calls stalled startup badly.
	if ss.has_method("set_terrain_walls"):
		var walls: Array = []
		for key in hex_nodes:
			var tile: HexTile = hex_nodes[key]
			if tile == null or not tile.is_wall:
				continue
			var center := get_hex_center(key.x, key.y)
			walls.append(Vector2(center.x, center.z))
		ss.set_terrain_walls(walls)
		return
	# Fallback: per-tile writes (older sim without the bulk method).
	if not ss.has_method("set_cell_building"):
		return
	for key in hex_nodes:
		var tile: HexTile = hex_nodes[key]
		if tile == null or not tile.is_wall:
			continue
		var center := get_hex_center(key.x, key.y)
		ss.set_cell_building(Vector2(center.x, center.z), 2, 255, 0, 0, true)
	# _spawn_drop_box()


## Drops a crate from the sky onto a random, non-wall hex. The crate lands
## at the hex's exact center (an integer grid position), so the tower built
## from it is guaranteed to sit on a real hex rather than an arbitrary spot.
func _spawn_drop_box() -> void:
	var col := 0
	var row := 0
	# Retry a few times to avoid landing a crate on a wall tile nobody can
	# reach.
	for attempt in range(50):
		col = randi_range(0, grid_width - 1)
		row = randi_range(0, grid_depth - 1)
		var tile := get_hex_node(col, row)
		if tile and not tile.is_wall:
			break

	var center := get_hex_center(col, row)
	var box := drop_box_scene.instantiate()
	add_child(box)
	box.col = col
	box.row = row
	box.global_position = center + Vector3(0, 120, 0)
	box.box_captured.connect(_on_box_captured)
	box.tower_built.connect(_on_tower_built)


## How many of the capturing team's darwinians march to a captured crate
## to build the tower there. Only the nearest BUILD_SQUAD_SIZE units are
## ordered - the rest of the team stays where it is instead of the whole
## army streaming across the map.
const BUILD_SQUAD_SIZE := 3

func _on_box_captured(team: int, pos: Vector3) -> void:
	# Only a small squad builds the tower: the nearest BUILD_SQUAD_SIZE
	# darwinians on the capturing team march to the crate's hex and stand
	# in it. Sending the whole team would strip the rest of the map of its
	# defenders for no reason.
	var squad: Array = []
	for child in get_children():
		if (child is Darwinian or child is GpuDarwinian) and child.team_number == team:
			squad.append(child)
	squad.sort_custom(func(a, b): return a.global_position.distance_squared_to(pos) < b.global_position.distance_squared_to(pos))
	for i in range(mini(BUILD_SQUAD_SIZE, squad.size())):
		squad[i].set_new_destination(pos)


func _on_tower_built(col: int, row: int, team: int) -> void:
	build_tower_at(col, row, team)


## Spawns a tower for `team` at the center of hex (col, row) - an integer
## hex position, never an arbitrary world coordinate.
func build_tower_at(col: int, row: int, team: int) -> void:
	var tower := tower_scene.instantiate()
	add_child(tower)
	tower.setup(col, row, team, get_hex_center(col, row))


func _has_active_box() -> bool:
	for child in get_children():
		if child is DropBox:
			return true
	return false
