extends Node3D
class_name BoidSwarm

## A team's hex-grid army: dots navigate hex tiles via multi-point paths,
## with pressure-based liquid physics preventing stacking.
##
## Each dot lives on a hex grid position and follows a path (array of hex
## IDs). The compute shader (boid_compute.glsl) handles the simulation in
## 4 passes: clear density, build density, compute pressure, move dots.
## The renderer (boid_render_effect.gd) draws billboards from the position
## SSBO, depth-tested against the scene.
##
## Roads drawn for the team are baked into a flow field: every hex tile
## along a road knows which hexes it connects to via the adjacency buffer.
## A dot reads its path and follows it hop-by-hop.

const TEAM_COLORS: Array[Color] = [
	Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.PURPLE, Color.CYAN,
]

@export var dot_count: int = 3000
## How many dots get a sim turn per frame (a rotating window through the
## whole army - see BoidCompute.record_frame). Keep this at your per-frame
## sim budget; the army still looks full because every dot renders every
## frame, just not every dot moves every frame.
@export_range(64, 1_000_000, 64) var update_batch: int = 100_000
## Rendering only (dots frozen at their seed cloud) - handy to verify the
## renderer before tuning the sim.
@export var sim_enabled: bool = true
@export var team_color: Color = Color.WHITE
## Billboard half-extent in world units (the dot's radius).
@export_range(0.05, 5.0, 0.01) var dot_scale: float = 0.5
## Friend count that saturates the density brightening (1.0-2.0x base color).
@export_range(1.0, 500.0) var density_scale: float = 60.0
## How wide (in hex tiles) the seed cluster spreads around the spawn.
@export_range(2, 60) var seed_radius: int = 20

var team_number: int = 0

var _compute: BoidCompute
var _effect: BoidRenderEffect
var _compositor: Compositor
var _attached_environment: WorldEnvironment
var _initialized := false

# Terrain/hex state, resolved in initialize().
var _grid_width := 20
var _grid_depth := 20
var _hex_size := 2.0
var _mesh_scale := 8.0
var _height_scale := 10.0
var _img: Image
var _img_w := 1
var _img_h := 1
var _span := 3
var _levels := 8
var _h := 1
var _spawn_cell := Vector3i.ZERO

# Roads: road key -> Array[int] ordered, deduplicated hex-id chain (see
# _road_hex_ids). GDScript Dictionaries preserve insertion order, which
# is the order the army marches the roads in.
var _roads: Dictionary = {}
# Hex-based flow: each lattice cell knows which hex it belongs to, each hex
# knows which hexes it connects to via roads and geometric adjacency.
var _hex_id_map := PackedInt32Array()  # lattice cell -> hex_id
var _hex_count := 0                     # total hexes (grid_width * grid_depth)
var _hex_positions := PackedVector3Array()  # hex_id -> world position of hex center
# Per-hex adjacency: flat array, hex_count * 32 slots. Each hex gets 32
# int slots at hex_id * 32; unused slots are -1.
var _hex_adj := PackedInt32Array()
# Geometric adjacency base (hex neighbors within radius, never changes).
var _hex_base_adj := PackedInt32Array()
# Real hex tile positions from the main scene (col, row, position).
var _real_hex_tiles: Array = []


## Called once by the main scene right after the node is added. `terrain`
## carries the terrain facts (heightmap_image, grid dims, hex_size,
## mesh_scale, height_scale) so the lattice can be sized over the map and
## the ground levels sampled.
##
## NOTE: this is now a coroutine (it awaits a physics frame before
## raycasting the hex grid - see _raycast_hex_id_map). Callers that don't
## `await` this will get the swarm node back immediately, but its compute/
## effect/compositor setup and the first flow bake happen one physics tick
## later. _initialized only flips true once that's done, and set_road() /
## remove_road() / clear_roads() already no-op while _initialized is false,
## so calling those before this finishes is safe - they just won't take
## effect until it's ready.
func initialize(team: int, spawn_world: Vector3, terrain: Dictionary) -> void:
	if _initialized:
		return
	team_number = team
	team_color = TEAM_COLORS[team] if team >= 0 and team < TEAM_COLORS.size() else Color.WHITE
	_grid_width = terrain.get("grid_width", 20)
	_grid_depth = terrain.get("grid_depth", 20)
	_hex_size = terrain.get("hex_size", 2.0)
	_mesh_scale = terrain.get("mesh_scale", 8.0)
	_height_scale = terrain.get("height_scale", 10.0)
	_real_hex_tiles = terrain.get("hex_tiles", [])
	var heightmap: NoiseTexture2D = terrain.get("heightmap_image")
	_img = heightmap.get_image() if heightmap != null else null
	if _img != null:
		_img_w = _img.get_width()
		_img_h = _img.get_height()

	# Lattice sized to the map footprint with a margin, tall enough for the
	# terrain plus stacking room.
	var horiz := _hex_size * 2.0 * 0.75
	var vert := sqrt(3.0) * _hex_size
	var total_w := (_grid_width - 1) * horiz * _mesh_scale
	var total_d := _grid_depth * vert * _mesh_scale
	var half := int(ceil(maxf(total_w, total_d) / 2.0)) + 8
	_h = maxi(half, 8)
	_span = _h * 2 + 1
	var max_terrain := 4.0 * _height_scale
	_levels = maxi(8, int(ceil(max_terrain)) + 24)

	_spawn_cell = _world_to_cell(spawn_world)

	# Build the hex_id map: every lattice cell (x, z) is assigned to whichever
	# hex tile a straight-down raycast hits.
	_hex_count = _grid_width * _grid_depth
	_hex_id_map.resize(_span * _span)
	_hex_id_map.fill(-1)
	_hex_positions.resize(_hex_count)
	await _build_hex_id_map()

	# Build geometric hex adjacency: for each hex, find all other hexes within
	# neighbor radius. This is the base graph the shader uses for pressure
	# gradients and pathfinding. Road connections are overlaid on top.
	_build_hex_adjacency()

	# Prepare seed data for the new hex-grid compute pipeline.
	var seed_data := _seed_army_new()

	_compute = BoidCompute.new()
	_compute.update_batch = update_batch
	_compute.hex_radius = _hex_size * _mesh_scale * 0.75
	# Convert hex positions to vec4 (w=0) for the shader.
	var hex_pos4 := _hex_positions_to_vec4()
	_compute.setup(dot_count, _hex_count, hex_pos4, _hex_adj,
				   seed_data.positions, seed_data.paths, seed_data.states)
	if not _compute.get_pos_rid().is_valid():
		push_error("BoidSwarm: BoidCompute failed to initialize (renderer must be Forward+ or Mobile).")
		return
	_effect = BoidRenderEffect.new()
	_effect.configure(_compute.get_pos_rid(), _compute.get_dot_count())
	_effect.bind_compute(_compute)
	_effect.team_color = team_color
	_compositor = Compositor.new()
	_compositor.compositor_effects = [_effect]
	if not _attach_compositor():
		push_error("BoidSwarm: no WorldEnvironment found in the scene; the swarm cannot render. Add a WorldEnvironment node.")
	_initialized = true
	print("BoidSwarm team %d: %d hexes, %d dots, compositor attached." % [
			team, _hex_count, _compute.get_dot_count()])


func _process(delta: float) -> void:
	if not _initialized or not _effect:
		return
	_compute.set_delta_time(delta)
	_effect.team_color = team_color
	_effect.dot_scale = dot_scale
	_effect.density_scale = density_scale
	_effect.sim_enabled = sim_enabled


## Bakes a drawn road into the hex adjacency graph. `key` is the same
## order-independent road key main_screen.gd uses; `path_tiles` is the full
## route as HexTile nodes - already the ordered hex sequence, so we just
## read col/row off each node.
func set_road(key: String, path_tiles: Array) -> void:
	if not _initialized or path_tiles.size() < 2:
		return
	_roads[key] = _road_hex_ids(path_tiles)
	_rebake_flow()


func remove_road(key: String) -> void:
	if not _initialized:
		return
	if _roads.erase(key):
		_rebake_flow()


func clear_roads() -> void:
	if not _initialized:
		return
	_roads.clear()
	_rebake_flow()


## Collapses a route's HexTile chain into its ordered, deduplicated hex ids.
func _road_hex_ids(path_tiles: Array) -> Array:
	var out: Array = []
	for tile in path_tiles:
		var t: HexTile = tile
		var hid := t.col * _grid_depth + t.row
		if out.is_empty() or out[-1] != hid:
			out.append(hid)
	return out


## Fills in each hex's world center, then raycasts every lattice column
## straight down to find which hex tile's collider it actually hits.
func _build_hex_id_map() -> void:
	if not _real_hex_tiles.is_empty():
		for tile_data in _real_hex_tiles:
			var col: int = tile_data["col"]
			var row: int = tile_data["row"]
			var pos: Vector3 = tile_data["position"]
			var hex_id := col * _grid_depth + row
			if hex_id >= 0 and hex_id < _hex_count:
				_hex_positions[hex_id] = Vector3(pos.x, 0.0, pos.z)
	else:
		# Fallback: compute positions mathematically.
		var hex_width := _hex_size * 2.0
		var hex_height := sqrt(3.0) * _hex_size
		var horiz_spacing := hex_width * 0.75
		var vert_spacing := hex_height
		var total_w := (_grid_width - 1) * horiz_spacing
		var total_d := _grid_depth * vert_spacing
		for col in range(_grid_width):
			for row in range(_grid_depth):
				var cx: float = col * horiz_spacing - total_w / 2.0
				var cz: float = row * vert_spacing + (vert_spacing * 0.5 if col % 2 == 1 else 0.0) - total_d / 2.0
				var hex_id := col * _grid_depth + row
				_hex_positions[hex_id] = Vector3(cx * _mesh_scale, 0.0, cz * _mesh_scale)
	await _raycast_hex_id_map()


## Raycasts straight down through every lattice column (x, z) to find which
## hex tile's collider it hits.
func _raycast_hex_id_map() -> void:
	await get_tree().physics_frame
	var space_state := get_world_3d().direct_space_state
	var top_y := float(_levels) + 50.0
	var bottom_y := -50.0
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = 2
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var misses := 0
	for z in range(-_h, _h + 1):
		for x in range(-_h, _h + 1):
			query.from = Vector3(x, top_y, z)
			query.to = Vector3(x, bottom_y, z)
			var result := space_state.intersect_ray(query)
			var hid := -1
			if result:
				var collider = result.get("collider")
				if collider is HexTile:
					hid = collider.col * _grid_depth + collider.row
			if hid == -1:
				misses += 1
			_hex_id_map[_column_index(x, z)] = hid

	# Fill any raycast seams/misses within the grid footprint with the nearest hex center
	var max_hex_reach_sq := (_hex_size * _mesh_scale * 1.5) * (_hex_size * _mesh_scale * 1.5)
	for z in range(-_h, _h + 1):
		for x in range(-_h, _h + 1):
			var col_idx := _column_index(x, z)
			if _hex_id_map[col_idx] == -1:
				var best_hid := -1
				var best_d_sq := INF
				for hid in range(_hex_count):
					var hpos := _hex_positions[hid]
					var dx := float(x) - hpos.x
					var dz := float(z) - hpos.z
					var d_sq := dx * dx + dz * dz
					if d_sq < best_d_sq:
						best_d_sq = d_sq
						best_hid = hid
				if best_d_sq <= max_hex_reach_sq:
					_hex_id_map[col_idx] = best_hid
					misses -= 1
	if misses > 0:
		push_warning("BoidSwarm: %d/%d lattice columns hit no hex tile." % [misses, _hex_id_map.size()])


## Builds geometric hex adjacency: for each hex, finds all other hexes within
## neighbor radius (slightly more than the max inter-hex distance). This forms
## the base graph the shader uses for pressure gradients and pathfinding.
func _build_hex_adjacency() -> void:
	var neighbor_radius := _hex_size * _mesh_scale * 2.2
	var neighbor_radius_sq := neighbor_radius * neighbor_radius
	_hex_base_adj.resize(_hex_count * BoidCompute.HEX_ADJ_SLOTS)
	_hex_base_adj.fill(-1)
	for hid in range(_hex_count):
		var pos := _hex_positions[hid]
		var slot := 0
		for other in range(_hex_count):
			if other == hid:
				continue
			var other_pos := _hex_positions[other]
			var dx := pos.x - other_pos.x
			var dz := pos.z - other_pos.z
			var d_sq := dx * dx + dz * dz
			if d_sq < neighbor_radius_sq:
				_hex_base_adj[hid * BoidCompute.HEX_ADJ_SLOTS + slot] = other
				slot += 1
				if slot >= BoidCompute.HEX_ADJ_SLOTS:
					break
	# _hex_adj starts as a copy of the base.
	_hex_adj = _hex_base_adj.duplicate()


## Rebuilds the full adjacency: geometric base + road connections, then
## pushes to the compute shader.
func _rebake_flow() -> void:
	# Start from geometric adjacency base.
	_hex_adj = _hex_base_adj.duplicate()
	# Overlay road connections (may link non-adjacent hexes via roads).
	for key in _roads.keys():
		var hex_ids: Array = _roads[key]
		for i in range(1, hex_ids.size()):
			var from_hid: int = hex_ids[i - 1]
			var to_hid: int = hex_ids[i]
			if from_hid < 0 or from_hid >= _hex_count:
				continue
			if to_hid < 0 or to_hid >= _hex_count:
				continue
			# Check if already connected (avoid duplicates).
			var already := false
			for s in range(BoidCompute.HEX_ADJ_SLOTS):
				var existing := _hex_adj[from_hid * BoidCompute.HEX_ADJ_SLOTS + s]
				if existing == -1:
					break
				if existing == to_hid:
					already = true
					break
			if not already:
				# Find a free slot.
				for s in range(BoidCompute.HEX_ADJ_SLOTS):
					if _hex_adj[from_hid * BoidCompute.HEX_ADJ_SLOTS + s] == -1:
						_hex_adj[from_hid * BoidCompute.HEX_ADJ_SLOTS + s] = to_hid
						break
	# Push to compute (convert hex positions to vec4).
	var hex_pos4 := _hex_positions_to_vec4()
	_compute.update_hex_flow(hex_pos4, _hex_adj)


## Converts the PackedVector3Array hex positions to PackedVector4Array (w=0).
func _hex_positions_to_vec4() -> PackedVector4Array:
	var out := PackedVector4Array()
	out.resize(_hex_count)
	for i in range(_hex_count):
		var p := _hex_positions[i]
		out[i] = Vector4(p.x, p.y, p.z, 0.0)
	return out


## Seeds the army as a dense cluster around the spawn hex. Returns per-dot
## initial data: world positions with hex IDs, empty paths, and hold states.
func _seed_army_new() -> Dictionary:
	var positions := PackedVector4Array()
	var paths := PackedInt32Array()
	var states := PackedVector4Array()
	positions.resize(dot_count)
	var path_size := dot_count * BoidCompute.MAX_PATH_LENGTH
	paths.resize(path_size)
	paths.fill(-1)
	states.resize(dot_count)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var taken := {}
	for i in dot_count:
		var pos := Vector3.ZERO
		var hex_id := 0
		var found := false
		for _tries in 32:
			var x := clampi(_spawn_cell.x + rng.randi_range(-seed_radius, seed_radius), -_h, _h)
			var z := clampi(_spawn_cell.z + rng.randi_range(-seed_radius, seed_radius), -_h, _h)
			var y := _ground_at(x, z)
			var col_idx := _column_index(x, z)
			var hid: int = _hex_id_map[col_idx]
			if hid < 0 or hid >= _hex_count:
				continue
			var key := Vector3i(x, y, z)
			if not taken.has(key):
				taken[key] = true
				pos = Vector3(x, y, z)
				hex_id = hid
				found = true
				break
		if not found:
			# Fallback: linear probe from the spawn column upward.
			var x := _spawn_cell.x
			var z := _spawn_cell.z
			var y := _ground_at(x, z)
			var col_idx := _column_index(x, z)
			var hid: int = _hex_id_map[col_idx]
			if hid < 0:
				hid = 0
			pos = Vector3(x, y, z)
			hex_id = hid
		positions[i] = Vector4(pos.x, pos.y, pos.z, float(hex_id))
		# Initial state: waypoint_idx=0, path_len=0, team, action=hold(0)
		states[i] = Vector4(0.0, 0.0, float(team_number), 0.0)
	return { "positions": positions, "paths": paths, "states": states }


## The terrain surface height (in lattice cells) at lattice column (x, z).
func _ground_at(x: int, z: int) -> int:
	if _img == null:
		return 0
	var u := float(x) / _mesh_scale
	var v := float(z) / _mesh_scale
	var y := HexTile._sample_height(_img, _img_w, _img_h, u, v, _height_scale)
	return clampi(int(round(y)), 0, _levels - 1)


## The lattice cell a world position rests on: the terrain ground of its
## column (world y is ignored - gravity settles dots onto the surface).
func _world_to_cell(w: Vector3) -> Vector3i:
	var x := clampi(roundi(w.x), -_h, _h)
	var z := clampi(roundi(w.z), -_h, _h)
	return Vector3i(x, _ground_at(x, z), z)


## Linear lattice cell index, mirroring cell_index() in boid_compute.glsl
## (KEEP IN SYNC).
func _cell_index(c: Vector3i) -> int:
	return c.y * _span * _span + (c.z + _h) * _span + (c.x + _h)


## Linear index of a lattice column (x, z).
func _column_index(x: int, z: int) -> int:
	return (z + _h) * _span + (x + _h)


## Attaches the compositor to the scene's WorldEnvironment so the render
## callback fires during the main viewport's rendering.
func _attach_compositor() -> bool:
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	for child in root.find_children("*", "WorldEnvironment"):
		var environment := child as WorldEnvironment
		if environment.compositor == null:
			environment.compositor = Compositor.new()
		var effects: Array = environment.compositor.compositor_effects
		if not effects.has(_effect):
			effects.append(_effect)
		environment.compositor.compositor_effects = effects
		_attached_environment = environment
		return true
	return false


func _exit_tree() -> void:
	if _attached_environment and _attached_environment.compositor:
		var effects: Array = _attached_environment.compositor.compositor_effects
		if _effect and effects.has(_effect):
			effects.erase(_effect)
		_attached_environment = null
	if _effect:
		_effect.teardown()
		_effect = null
	if _compute:
		_compute.teardown()
		_compute = null
	_compositor = null
