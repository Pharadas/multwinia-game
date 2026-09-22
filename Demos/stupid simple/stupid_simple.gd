extends MultiMeshInstance3D

@export var count_shader_file: RDShaderFile
@export var prefixsum_shader_file: RDShaderFile
@export var scatter_shader_file: RDShaderFile
@export var sim_shader_file: RDShaderFile
@export var render_shader_file: RDShaderFile

const CELL_SIZE := 5.0
const MAX_SPEED := 4.0
const WORLD_MIN := Vector3(-300, 10 , -170)
const WORLD_MAX := Vector3(300, 100, 170)

## Must match HexTerrain's hex_size / mesh_scale so world-space hex
## boundaries line up with the actual terrain grid. Set these (e.g. from
## the spawner, right after instantiate() and before add_child()) whenever
## the terrain doesn't use the defaults of 1.0.
@export var hex_size := 1.0
@export var mesh_scale := 10.0
@export var hex_grid_width := 20   # must match hex_terrain.grid_width
@export var hex_grid_depth := 20  # must match hex_terrain.grid_depth

var rd: RenderingDevice
var instance_count: int
var total_groups: int
var table_size: int
var grid_dims: Vector3i

# shader + pipeline RIDs
var shader_rids: Dictionary = {}    # name -> RID
var pipeline_rids: Dictionary = {}  # name -> RID

# data buffers
var state_buffers: Array[RID] = []      # [0], [1]
var cell_count_rid: RID
var cell_offset_rid: RID
var write_cursor_rid: RID
var sorted_indices_rid: RID
var mm_buffer_rid: RID
var cell_info_rid: RID
var global_paths_rid: RID
# Economy: 8 u32s - [t*2+1] is team t's starve flag (CPU-written, sim-read).
# [t*2] is unused on GPU; resource amounts live CPU-side in _team_resources.
var econ_res_rid: RID
# Per-frame count-pass output, 8 u32s: [t*2]=alive count, [t*2+1]=largest
# dead boid id + 1 (revival pool). Cleared every frame, read every second.
var econ_stats_rid: RID
# One u32 per HEX: 1 = ground collapsed (mine depleted). Boids whose
# current hex matches fall and die (sim.glsl). CPU-written once at collapse
# time. Hex-indexed (not cell-indexed) so the whole hexagon is lethal.
var collapse_rid: RID
var collapse_rid_size: int = 0
# Terrain heightfield uploaded from the main screen's NoiseTexture2D (see
# set_heightmap). Layout matches sim.glsl's HeightmapBuf: a 4-float header
# (map_w, map_h, height_scale, pad) followed by row-major RED samples;
# sim.glsl's terrain_height() bilinearly interpolates them so ground dots
# rest on the visible terrain. A 16-byte zero placeholder exists from
# startup (map_w == 0 -> flat-floor fallback) until the real upload lands.
var heightmap_rid: RID
var heightmap_width: int = 0   # image width in texels (0 = no upload yet)
var heightmap_depth: int = 0   # image height in texels
## Height scale pushed to the shaders every frame (sim.glsl's terrain_height
## rebuilds HexTile._sample_height's `r * 4.0 * height_scale` with it).
var terrain_height_scale: float = 10.0
## CPU copy of the uploaded samples (4-float header + w*h floats, same
## layout as the GPU buffer) so get_ground_height() can query heights
## without a per-call GPU readback.
var _heightmap_cpu := PackedFloat32Array()
## Retired heightmap buffers from previous uploads. They must stay alive
## until the uniform sets binding them are freed - freeing a buffer that a
## uniform set references invalidates that set's RID (RenderingDevice
## dependency tracking), which crashed the uniform-set rebuild.
var _heightmap_retired: Array[RID] = []
# Ping-ponged per-boid damage accumulators (uint per boid). Attackers
# atomicAdd onto the write side; victims consume last frame's read side.
var dmg_buffers: Array[RID] = []

## Death-explosion buffer (sim.glsl binding 11), GPU-ONLY: each boid owns
## slot (id %% 128) and writes a timestamped vec4(xyz = blast pos, w = sim
## time) into it when its fuse runs out. Every boid scans the slot list the
## next frame and gets flung by young, nearby blasts. Aged entries are
## skipped by timestamp, so the buffer never needs CPU polling or clearing.
var explode_buf_rid: RID
const EXPLODE_SLOTS := 128  # MUST match sim.glsl's EXPLODE_SLOTS

# uniform sets, ping-ponged where needed
var uniform_sets_count: Array[RID] = []
var uniform_set_prefixsum: RID
var uniform_sets_scatter: Array[RID] = []
var uniform_sets_sim: Array[RID] = []
var uniform_sets_render: Array[RID] = []

# hex grid bounds (computed in _ready), in OFFSET (col, row) space - the
# same space HexTerrain.hex_nodes is keyed by.
var hex_min_q := 0   # min offset col (kept name to minimize churn elsewhere)
var hex_min_r := 0   # min offset row
var hex_width := 0
var hex_total_cells := 0

var frame_parity := 0
var team_bases: Array = []

## GPU per-(hex, team, slot) follower counters (see _create_buffers).
var path_followers_rid: RID
var _path_followers_cells: int = 0

## Number of live boids per team. Both teams are seeded with the same count
## at startup; the main screen drives it through set_dot_count_per_team() so
## the army size is an explicit choice, not instance_count / 4.
var _dots_per_team: int = 0

## Number of teams this run. Generalized: any N >= 1. grid_dims.y equals
## this value (the per-team 2D grid slices), and it is pushed to every
## shader as grid_dims.w so GPU-side team indexing matches the buffer
## layouts (hex paths, followers, econ stats) exactly.
##
## One slot is always RESERVED as the NPC horde (team id num_teams - 1):
## deserters. No phone is ever assigned it, no boid spawns in it, but
## starving boids randomly defect into it and it fights everyone. Player
## teams are 0..num_teams - 2.
var num_teams: int = 5

## How fast broke teams bleed units to the horde. Each in-debt boid converts
## with per-frame chance min(deficit * DESERTION_RATE, 0.0005) (plus a slow
## trickle while merely starving, hard-coded in the shader). At 0.0000015 a
## team of 60 dots that is 100 resources in the red loses roughly one unit
## every 2 seconds - gentle leak at small debts, collapse at huge ones.
## Packed into the push constants (hex_grid.w slot) each frame.
const DESERTION_RATE := 0.0000015

## Cumulative simulated seconds, pushed to all shaders as params.w. Used by
## sim.glsl to check path expiry timestamps.
var _elapsed_seconds: float = 0.0

## Last sim timestamp (params.w * 256, truncated to 24 bits) at which the
## CPU read the explosion buffer - read_explosions() reports only blasts
## detonated after this, so each blast yields exactly one
## explosion_occurred signal. 1/256 s resolution matches sim.glsl.
var _last_blast_read_time := 0.0

## Cached BLAST_TTL copy (sim.glsl's BLAST_TTL = 0.4 s): blasts stay fresh
## in the slot list this long and are re-reported every frame while young.
const BLAST_TTL := 0.4

## How long a freshly-set path stays claimable, in seconds. Claimant boids
## finish their path regardless of expiry (see sim.glsl soft-expiry comment).
## Short-lived by design: paths fade fast, new claims pick fresh ones.
@export var path_lifetime := 10.0

# ---- economy -------------------------------------------------------------------
## ---- SPECIAL CENTER MINE + MINERS ------------------------------------------
## The map center hosts a permanent special mine worth 3x a normal mine,
## guarded by MINER_COUNT miner dots that never leave its hexagon. The mine
## is a regular neutral mine (capture rules apply) but its lifetime never
## counts down, and its owner earns SPECIAL_MINE_BONUS per living miner on
## top of the normal MINE_INCOME. Miners are NPC-team dots (team
## num_teams - 1) flagged STATE_MINER, so upkeep, starvation, desertion and
## captures never touch them - but everyone can melee them down to grab the
## mine. Dead miners respawn at the mine every MINER_RESPAWN_INTERVAL.
const MINER_COUNT := 7
const SPECIAL_MINE_BONUS := 100.0  # 3x a normal mine: 50 base + 2x50 bonus
const MINER_RESPAWN_INTERVAL := 3.0
const STATE_MINER_FLAG := 0x80     # must match sim.glsl's STATE_MINER bit
const MINER_HEALTH := 3000         # 10x a regular dot: takes focused raids

const MINE_INCOME := 50.0          # resources per second per owned mine
const UPKEEP_PER_SEC := 0.2       # each dot costs 1 resource per 5 seconds
const BARRACK_REVIVE_COST := 1.0  # resources to regenerate one dead dot
const MINE_LIFETIME := 60.0       # seconds a mine generates before collapsing
## Barracks also PRODUCE new dots from unused multimesh slots: this many
## per second per built barrack, each costing BARRACK_REVIVE_COST (so with
## the default 1.0 that's 10 dots/sec for 10 resources/sec). Revival of
## dead slots always runs first; production only fills what's left over.
const BARRACK_PROD_RATE := 10     # new dots per second per built barrack
## Placement prices, charged from the placing team's pool when the phone
## drops the building. A team that can't afford it doesn't get the site.
const WALL_COST := 100.0          # walls are expensive defensive structures
## Base starting pool per player team...
const STARTING_RESOURCES := 2000.0
## ...plus this much per dot in the team's army. Upkeep scales with army
## size (0.2/s per dot), so the starting stash must scale too - a fixed
## pool evaporates in seconds at large dot counts and every team insta-
## starves into desertion (which looked like "no starting resources").
const STARTING_RESOURCES_PER_DOT := 50.0

## CPU-side resource pool per team.
var _team_resources: Array[float] = []
## Next unused boid slot per team for barrack production. The live army
## occupies 0 .. _dots_per_team * player_teams - 1 (round-robin by team),
## so each team's production starts at its own first free slot; the base
## is computed in _create_buffers once the army size is known.
var _next_free_slot: Array[int] = []
## Highest boid id barrack production may fill. The last MINER_COUNT slots
## are reserved for the special center miners and never receive normal
## army production (set in _create_buffers).
var _army_slot_cap: int = 0
## Seconds until each mine collapses: Vector2i(cell) -> float
var _mine_timers: Dictionary = {}
var _econ_timer := 0.0
## Special center mine + its miners (set up by setup_special_mine).
var _special_mine_cell := Vector2i(-1, -1)
var _special_mine_world := Vector2.ZERO
var _special_mine_hex_id := -1
var _miner_ids: PackedInt32Array = PackedInt32Array()
var _miner_respawn_timer := 0.0
## Set by main_screen.gd (or a demo harness) to learn when a mine's ground
## tile is destroyed, so meshes/terrain can react.
signal mine_collapsed(cell: Vector2i, world_pos: Vector2)
## Emitted when a mine's owner changes (captured from neutral or stolen
## from another team) so UIs can recolor it. team = new owner, always a
## real team (never the neutral marker).
signal mine_owner_changed(cell: Vector2i, world_pos: Vector2, team: int)
## Emitted once per economy tick with a copy of the per-team resource pools
## (index = team id) so UIs (the phone) can display them.
signal resources_changed(resources: Array)
## Emitted each frame for every fresh death explosion the CPU reads back off
## the GPU (read_explosions). pos is the blast's world position, team is the
## exploding dot's owner (colorize VFX by it), age is seconds since the blast
## (0.0 on the frame it lands, within BLAST_TTL afterwards).
signal explosion_occurred(pos: Vector3, team: int, age: float)


func _ready() -> void:
	# The editor serializes the multimesh's instance buffer into the .tscn on
	# every save (2+ MB of stale garbage). On load, that buffer's size can
	# disagree with instance_count and the dots silently vanish. Force a clean
	# reallocation: setting instance_count clears + re-zeroes the buffer, so
	# whatever the editor saved is discarded before the GPU touches anything.
	instance_count = multimesh.instance_count
	if instance_count <= 0:
		instance_count = 10766  # fallback default

	# Pull the scene-wide configuration BEFORE the army is seeded: this node
	# is a child of MainScreen, and child _ready runs before the parent's -
	# by the time main_screen got around to calling set_dot_count_per_team()
	# (deferred), the army had already been seeded with the fallback size.
	# Reading the ancestor directly here makes the export the source of truth.
	var ms := get_tree().root.get_node_or_null("MainScreen")
	if ms == null:
		var anc := get_parent()
		while anc != null and ms == null:
			if "dots_per_team" in anc:
				ms = anc
			anc = anc.get_parent()
	if ms != null and "dots_per_team" in ms:
		set_dot_count_per_team(int(ms.dots_per_team))
	# num_teams is NOT read from the socket: it is the SOURCE OF TRUTH for
	# the whole run (buffer layouts, team coloring, seeding all key off it
	# and it is frozen once _create_buffers runs). The socket follows the
	# sim instead - main_screen.gd hands phones team ids 0..num_teams-2 -
	# so editing num_teams here is all it takes to change the team count.

	# Upper bound: we never need more slots than the multimesh can hold.
	# Both teams get the same count, so the total must fit in the pool.
	var wanted := _dots_per_team * (num_teams - 1)
	if wanted > instance_count:
		wanted = instance_count
	if wanted <= 0:
		wanted = instance_count
	_dots_per_team = wanted / (num_teams - 1)

	multimesh.instance_count = 0
	multimesh.instance_count = instance_count
	total_groups = ceili(instance_count / 64.0)
	# The compute shader writes instance transforms straight into the GPU
	# buffer, so Godot never recomputes the multimesh's AABB from real
	# positions. A zeroed (or garbage) buffer yields a degenerate/huge AABB:
	# zeroed -> the whole swarm gets FRUSTUM-CULLED and every dot silently
	# vanishes. Pin an AABB covering the world so it's never culled.
	multimesh.custom_aabb = AABB(WORLD_MIN, WORLD_MAX - WORLD_MIN)

	var world_size := WORLD_MAX - WORLD_MIN
	grid_dims = Vector3i(
		ceili(world_size.x / CELL_SIZE),
			num_teams,  # 2D grid: x*z cells per team slice
		ceili(world_size.z / CELL_SIZE)
	)
	table_size = grid_dims.x * grid_dims.y * grid_dims.z  # num_teams × x × z

	# compute hex grid bounds from world corners (offset col/row space)
	var tl = world_to_hex(Vector2(WORLD_MIN.x, WORLD_MIN.z))
	var tr = world_to_hex(Vector2(WORLD_MAX.x, WORLD_MIN.z))
	var bl = world_to_hex(Vector2(WORLD_MIN.x, WORLD_MAX.z))
	var br = world_to_hex(Vector2(WORLD_MAX.x, WORLD_MAX.z))
	hex_min_q = mini(mini(tl.x, tr.x), mini(bl.x, br.x))
	hex_min_r = mini(mini(tl.y, tr.y), mini(bl.y, br.y))
	var hex_max_q = maxi(maxi(tl.x, tr.x), maxi(bl.x, br.x))
	var hex_max_r = maxi(maxi(tl.y, tr.y), maxi(bl.y, br.y))
	hex_width = hex_max_q - hex_min_q + 1
	hex_total_cells = hex_width * (hex_max_r - hex_min_r + 1)
	print("Hex grid: col=[%d..%d] row=[%d..%d] width=%d total=%d" % [hex_min_q, hex_max_q, hex_min_r, hex_max_r, hex_width, hex_total_cells])

	rd = RenderingServer.get_rendering_device()

	_load_shaders()
	_create_pipelines()
	_create_buffers()
	_build_uniform_sets()
	_initial_dispatch()


func _initial_dispatch() -> void:
	# Run the full pipeline once at startup so mm_buffer has real positions
	# before Godot renders the first frame (avoids center flash from garbage data).
	rd.buffer_clear(cell_count_rid, 0, table_size * 4)
	rd.buffer_clear(econ_stats_rid, 0, 2 * num_teams * 4)
	rd.buffer_clear(path_followers_rid, 0, _path_followers_cells * num_teams * 10 * 4)
	rd.buffer_clear(explode_buf_rid, 0, EXPLODE_SLOTS * 16 + 16)
	rd.buffer_clear(dmg_buffers[0], 0, instance_count * 4)
	rd.buffer_clear(dmg_buffers[1], 0, instance_count * 4)
	var push_bytes := _build_push_constants(0.0)
	var cl = rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["count"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_count[0], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["prefixsum"])
	rd.compute_list_bind_uniform_set(cl, uniform_set_prefixsum, 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["scatter"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_scatter[0], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["sim"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_sim[0], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["render"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_render[0], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)

	rd.compute_list_end()
	frame_parity = 1


func _load_shaders() -> void:
	var files := {
		"count": count_shader_file,
		"prefixsum": prefixsum_shader_file,
		"scatter": scatter_shader_file,
		"sim": sim_shader_file,
		"render": render_shader_file,
	}
	for name in files:
		var f: RDShaderFile = files[name]
		var spirv: RDShaderSPIRV = f.get_spirv()
		if spirv == null:
			push_error("%s: failed to get SPIR-V" % name)
			continue
		var err_text := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if err_text != "":
			push_error("%s: GLSL compile error: %s" % [name, err_text])
			continue
		shader_rids[name] = rd.shader_create_from_spirv(spirv)


func _create_pipelines() -> void:
	for name in shader_rids:
		pipeline_rids[name] = rd.compute_pipeline_create(shader_rids[name])


func _create_buffers() -> void:
	# Cell info: TWO uints per grid cell (hex id + packed building info),
	# replicated across all 4 team slices. Building field layout must match
	# sim.glsl's CellInfo:
	#   bits  0-7 : building id
	#   bits  8-15: owning team
	#   bit  31   : BUILT flag
	# (bits 16-30 hold the GPU build-progress counter - never written by CPU
	# except as zero.)
	var cell_hexes := PackedInt32Array()
	cell_hexes.resize(table_size * 2)  # [hex_id, building] pairs
	var building_none := 0xFF  # "no building" sentinel

	# --- initalize grid values (2D per-team layout) ---
	# grid_dims.y = num_teams. For each team t, cells[t*xz..t*xz+xz] are
	# that team's 2D grid. Spatial layout is the same for all teams.
	var xz := grid_dims.x * grid_dims.z
	for i in range(xz):
		var cx := i % grid_dims.x
		var cz := i / grid_dims.x
		var world_pos = Vector2(float(cx) + 0.5, float(cz) + 0.5) * CELL_SIZE + Vector2(WORLD_MIN.x, WORLD_MIN.z)
		var hex = world_to_hex(world_pos)
		var hex_id = hex_to_id(hex.x, hex.y)
		# Write same hex mapping (and empty building) for every team slice
		for t in range(num_teams):
			var ci := t * xz + i
			cell_hexes[ci * 2] = hex_id
			cell_hexes[ci * 2 + 1] = building_none

	var cell_hexes_bytes := cell_hexes.to_byte_array()

	#print(len(cell_hexes_bytes), " ", table_size)
	cell_info_rid = rd.storage_buffer_create(table_size * 8, cell_hexes_bytes)

	# BoidState (std430): pos(16B) vel(16B) + 7 uints/int (28B) = 60B,
	# rounded up to the vec4 alignment = 64 bytes = 16 floats per boid.
	# CPU field order MUST match: pos(0-3) vel(4-7) state(8) path_hex(9)
	# path_slot(10) team(11) health(12) home_hex(13) pad(14-15).
	var floats_per_boid := 16
	var state_bytes := instance_count * floats_per_boid * 4  # 48 bytes/boid

	var init_state := PackedFloat32Array()
	init_state.resize(instance_count * floats_per_boid)

	# Only seed the live army: PLAYER teams only (0..num_teams-2) - the last
	# slot is the reserved NPC horde, which starts empty and fills up purely
	# through desertion. Every team gets the same count, assigned round-robin.
	var player_teams := maxi(num_teams - 1, 1)
	var live_count := _dots_per_team * player_teams
	for i in range(live_count):
		var team := i % player_teams
		var base := i * floats_per_boid
		var p := Vector3(
			randf_range(WORLD_MIN.x, WORLD_MAX.x),
			randf_range(WORLD_MIN.y, WORLD_MAX.y),
			randf_range(WORLD_MIN.z, WORLD_MAX.z)
		)
		var v := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized() * randf_range(1.0, MAX_SPEED)
		init_state[base + 0] = p.x
		init_state[base + 1] = p.y
		init_state[base + 2] = p.z
		init_state[base + 3] = 0.0
		init_state[base + 4] = v.x
		init_state[base + 5] = 0.0
		init_state[base + 6] = v.z
		init_state[base + 7] = 0.0

		var bytes = PackedByteArray()
		bytes.resize(4)
		var hex = world_to_hex(Vector2(p.x, p.z))
		bytes.encode_u32(0, hex_to_id(hex.x, hex.y))
		init_state[base + 8] = bytes.decode_float(0)

		var no_path_bytes := PackedByteArray()
		no_path_bytes.resize(4)
		no_path_bytes.encode_u32(0, 0xFFFFFFFF)
		init_state[base + 9] = no_path_bytes.decode_float(0)
		init_state[base + 10] = 0.0
		var tb := PackedByteArray()
		tb.resize(4)
		tb.encode_u32(0, team)
		init_state[base + 11] = tb.decode_float(0)

		var health := PackedByteArray()
		health.resize(4)
		health.encode_u32(0, 1000)
		init_state[base + 12] = health.decode_float(0)
		var hh := PackedByteArray()
		hh.resize(4)
		hh.encode_s32(0, hex_to_id(hex.x, hex.y))
		init_state[base + 13] = hh.decode_float(0)




	# --- spawn teams into their corner bases (CPU-side, no buffer_update needed) ---
	_compute_team_bases()
	for team in range(num_teams - 1):
		var base_arr: Array = team_bases[team]
		var spawn_tiles: Array = []
		for c in range(base_arr[0], base_arr[2] + 1):
			for r in range(base_arr[1], base_arr[3] + 1):
				if c == base_arr[0] and r == base_arr[1]:
					continue  # skip generator tile
				spawn_tiles.append(Vector2i(c, r))
		var team_boids: Array = []
		for i in range(_dots_per_team * (num_teams - 1)):
			if i % (num_teams - 1) == team:
				team_boids.append(i)
		var jitter := mesh_scale * 0.3
		for bi in range(team_boids.size()):
			var boid_id: int = team_boids[bi]
			var cell: Vector2i = spawn_tiles[bi % spawn_tiles.size()]
			var center := get_hex_center(cell.x, cell.y)
			var offset := Vector3(randf_range(-jitter, jitter), randf_range(0.0, 4.0), randf_range(-jitter, jitter))
			var pos := center + offset
			var hex := world_to_hex(Vector2(pos.x, pos.z))
			var hex_id := hex_to_id(hex.x, hex.y)
			var b := boid_id * floats_per_boid
			init_state[b + 0] = pos.x
			init_state[b + 1] = pos.y
			init_state[b + 2] = pos.z
			var hb := PackedByteArray()
			hb.resize(4)
			hb.encode_u32(0, hex_id)
			init_state[b + 3] = hb.decode_float(0)
			init_state[b + 4] = 0.0  # vel.x
			init_state[b + 5] = 0.0  # vel.y
			init_state[b + 6] = 0.0  # vel.z
			init_state[b + 7] = 0.0
			init_state[b + 8] = 0.0  # state
			var np := PackedByteArray()
			np.resize(4)
			np.encode_u32(0, 0xFFFFFFFF)
			init_state[b + 9] = np.decode_float(0)  # assigned_path_hex = NO_PATH
			init_state[b + 10] = 0.0  # assigned_path_slot
			var tb := PackedByteArray()
			tb.resize(4)
			tb.encode_u32(0, team)
			init_state[b + 11] = tb.decode_float(0)
			var health := PackedByteArray()
			health.resize(4)
			health.encode_u32(0, 1000)
			init_state[b + 12] = health.decode_float(0)
			# home_hex = spawn hex
			var shh := PackedByteArray()
			shh.resize(4)
			shh.encode_s32(0, hex_id)
			init_state[b + 13] = shh.decode_float(0)

	var init_bytes := init_state.to_byte_array()
	#print(init_bytes)

	state_buffers.append(rd.storage_buffer_create(state_bytes, init_bytes))
	state_buffers.append(rd.storage_buffer_create(state_bytes, init_bytes))
	# Damage accumulators: one uint per boid, ping-ponged like the state
	# buffers. Zero-initialized (no data passed in).
	dmg_buffers.append(rd.storage_buffer_create(instance_count * 4))
	dmg_buffers.append(rd.storage_buffer_create(instance_count * 4))
	# --- grid buffers, zero-initialized, sized exactly to grid_dims ---
	cell_count_rid = rd.storage_buffer_create(table_size * 4)
	cell_offset_rid = rd.storage_buffer_create(table_size * 4)
	write_cursor_rid = rd.storage_buffer_create(table_size * 4)
	sorted_indices_rid = rd.storage_buffer_create(instance_count * 4)

	# Global paths: num_teams team slices per hex cell. Each team-hex has a
	# HexPaths struct (1368B)
	# (path_count 4B + claim_chance 4B + 10 x 136B paths = 1368B; claim_chance
	# defaults to 0.0 = "everyone may claim" until set_path_fraction overrides it)
	var num_cells := hex_total_cells if hex_total_cells > 0 else (hex_grid_width * hex_grid_depth)
	var global_paths_bytes := PackedByteArray()
	global_paths_bytes.resize(num_cells * num_teams * 1368)
	global_paths_rid = rd.storage_buffer_create(global_paths_bytes.size(), global_paths_bytes)
	# Follower counters: one u32 per (hex, team, slot) = num_cells * num_teams * 10.
	# count.glsl atomicAdds boids still following each path; the CPU clears it
	# every frame and reads it to know when a drawn path is fully walked.
	_path_followers_cells = num_cells
	path_followers_rid = rd.storage_buffer_create(num_cells * num_teams * 10 * 4)

	# Economy buffers: starve flags (CPU->GPU), per-frame alive/dead stats
	# (GPU->CPU), collapse flags (CPU->GPU). All zero-initialized.
	# econ_res: 3 u32 per team slot - [t*2+1] = starve flag,
	# [t*2+2] = resource deficit as a float (drives desertion chance).
	econ_res_rid = rd.storage_buffer_create(num_teams * 3 * 4)
	# econ_stats: what count.glsl writes - 2 u32 per team (alive, largest-dead+1).
	econ_stats_rid = rd.storage_buffer_create(2 * num_teams * 4)
	collapse_rid = rd.storage_buffer_create(table_size * 4)
	collapse_rid_size = table_size * 4
	# Death explosions: 128 timestamped vec4 slots (GPU-only shockwave list).
	# std430: 128*16 + 4 for count, padded to 16 = 2064 bytes.
	explode_buf_rid = rd.storage_buffer_create(EXPLODE_SLOTS * 16 + 16)

	# Heightfield placeholder: 4-float header (map_w, map_h, height_scale,
	# pad) all zero - sim.glsl's terrain_height() sees map_w < 1.0 and falls
	# back to the flat world floor until set_heightmap() uploads the real
	# terrain. std430 keeps the 16-byte buffer at exactly 16 bytes.
	var zero_bytes := PackedByteArray()
	zero_bytes.resize(16)  # zero-filled 4-float header
	heightmap_rid = rd.storage_buffer_create(16, zero_bytes)

	# Player teams start with a pool that scales with their army size; the
	# reserved NPC horde slot starts broke and stays broke: no mines pay it
	# (it never owns mines), no income, no revivals.
	var starting_pool := STARTING_RESOURCES + float(_dots_per_team) * STARTING_RESOURCES_PER_DOT
	for t in range(num_teams):
		_team_resources.append(0.0 if t == num_teams - 1 else starting_pool)
		_next_free_slot.append(0)
	# Boid id t + k*player_teams belongs to team t (round-robin spawn), so
	# team t's production starts after the last round dealt to ANY team.
	var army_end := _dots_per_team * (num_teams - 1)
	for t in range(num_teams):
		_next_free_slot[t] = army_end

	# Reserve the last MINER_COUNT boid slots for the special center miners.
	# They stay dead/unrendered until setup_special_mine() activates them,
	# so the seed loop above (live_count = army size) never touches them.
	_army_slot_cap = instance_count - MINER_COUNT
	for k in range(MINER_COUNT):
		_miner_ids.append(instance_count - 1 - k)

	# Clear the starve flags buffer at startup so boids aren't starving before
	# the first economy tick.
	var clear := PackedByteArray()
	clear.resize(num_teams * 3 * 4)
	rd.buffer_update(econ_res_rid, 0, clear.size(), clear)

	mm_buffer_rid = RenderingServer.multimesh_get_buffer_rd_rid(multimesh.get_rid())


func _make_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


## Storage-buffer uniform for the sim's optional bindings (e.g. binding 12,
## the heightmap). A null/invalid RID binds the placeholder buffer instead so
## the uniform set never has a hole and the shader's map_w == 0 fallback
## kicks in.
func _sim_uniform(binding: int, rid: RID) -> RDUniform:
	return _make_uniform(binding, rid if rid.is_valid() else heightmap_rid)


func _build_uniform_sets() -> void:
	for parity in range(2):
		var other = 1 - parity

		# count.glsl: binding0=state(read), binding1=cell_count, binding2=econ_stats,
		# binding3=path_followers
		uniform_sets_count.append(rd.uniform_set_create(
			[_make_uniform(0, state_buffers[parity]), _make_uniform(1, cell_count_rid), _make_uniform(2, econ_stats_rid), _make_uniform(3, path_followers_rid)],
			shader_rids["count"], 0
		))

		# scatter.glsl: binding0=state(read), binding1=write_cursor, binding2=sorted_idx
		uniform_sets_scatter.append(rd.uniform_set_create(
			[_make_uniform(0, state_buffers[parity]), _make_uniform(1, write_cursor_rid), _make_uniform(2, sorted_indices_rid)],
			shader_rids["scatter"], 0
		))

		# sim.glsl: binding0=read_state,1=write_state,2=cell_offset,3=cell_count,4=sorted_idx
		# 5=cell_info,6=global_paths,7=dmg_write(this frame),8=dmg_read(last frame)
		# 9=econ_res,10=collapse,11=death explosions,12=terrain heightmap.
		# Binding 12 always gets a buffer (placeholder until set_heightmap			# uploads the real image - the shader sees map_w == 0 then).
		uniform_sets_sim.append(rd.uniform_set_create(
			[
				_make_uniform(0, state_buffers[parity]),
				_make_uniform(1, state_buffers[other]),
				_make_uniform(2, cell_offset_rid),
				_make_uniform(3, cell_count_rid),
				_make_uniform(4, sorted_indices_rid),
				_make_uniform(5, cell_info_rid),
				_make_uniform(6, global_paths_rid),
				_make_uniform(7, dmg_buffers[other]),   # write side: becomes next frame's read
				_make_uniform(8, dmg_buffers[parity]),  # read side: last frame's totals
				_make_uniform(9, econ_res_rid),         # starve flags (CPU-managed)
				_make_uniform(10, collapse_rid),        # collapsed-tile flags
				_make_uniform(11, explode_buf_rid),     # death-explosion ring buffer
				_sim_uniform(12, heightmap_rid),        # terrain heightfield
			],
			shader_rids["sim"], 0
		))

		# render.glsl: binding0 = freshly-simulated state (state_buffers[other] after sim writes it), binding1=mm_buffer
		uniform_sets_render.append(rd.uniform_set_create(
			[_make_uniform(0, state_buffers[other]), _make_uniform(1, mm_buffer_rid)],
			shader_rids["render"], 0
		))

	# prefixsum.glsl: binding0=cell_count,1=cell_offset,2=write_cursor — no ping-pong dependency
	uniform_set_prefixsum = rd.uniform_set_create(
		[_make_uniform(0, cell_count_rid), _make_uniform(1, cell_offset_rid), _make_uniform(2, write_cursor_rid)],
		shader_rids["prefixsum"], 0
	)


func _build_push_constants(delta: float) -> PackedByteArray:
	# Must match the GLSL struct exactly, in all 5 shaders:
	# vec4 params      (dt, instance_count, cell_size, elapsed sim seconds)
	# vec4 world_min   (x, y, z, height_scale - sim.glsl's terrain_height
	#                   reads it from here; hex_params.w must stay hex_min_r)
	# ivec4 grid_dims  (x, y, z, unused)
	# vec4 hex_params  (hex_size, mesh_scale, min_q, min_r)
	# ivec4 hex_grid   (grid_width, grid_depth, hex_width, desertion rate bits)
	var floats := PackedFloat32Array([
		delta, float(instance_count), CELL_SIZE, _elapsed_seconds,
		WORLD_MIN.x, WORLD_MIN.y, WORLD_MIN.z, terrain_height_scale,
	])
	var bytes := floats.to_byte_array()

	var ints := PackedInt32Array([grid_dims.x, grid_dims.y, grid_dims.z, num_teams])
	bytes.append_array(ints.to_byte_array())

	var hex_floats := PackedFloat32Array([
		hex_size, mesh_scale, float(hex_min_q), float(hex_min_r)
	])
	bytes.append_array(hex_floats.to_byte_array())

	# hex_grid.w carries the desertion rate as raw float bits (the slot was
	# unused). sim.glsl does intBitsToFloat on it - 0.0 falls back to the
	# shader's built-in default, so leaving it zero is safe.
	var rate_bits := PackedFloat32Array([DESERTION_RATE]).to_byte_array().decode_s32(0)
	var hex_ints := PackedInt32Array([hex_grid_width, hex_grid_depth, hex_width, rate_bits])
	bytes.append_array(hex_ints.to_byte_array())

	return bytes


func _process(delta: float) -> void:
	_elapsed_seconds += delta
	_econ_timer += delta
	if _econ_timer >= 1.0:
		_econ_timer -= 1.0
		_economy_tick()
	var read_i = frame_parity
	var write_i = 1 - frame_parity

	rd.buffer_clear(cell_count_rid, 0, table_size * 4)
	rd.buffer_clear(econ_stats_rid, 0, 2 * num_teams * 4)
	rd.buffer_clear(path_followers_rid, 0, _path_followers_cells * num_teams * 10 * 4)
	# Zero this frame's damage write-accumulator before attackers atomicAdd
	# onto it. The read side holds last frame's totals - consumed, not cleared.
	rd.buffer_clear(dmg_buffers[write_i], 0, instance_count * 4)

	var push_bytes := _build_push_constants(delta)
	# Special miners: respawn dead guards on a timer (cheap CPU check).
	_update_miners(delta)

	var cl = rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["count"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_count[read_i], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["prefixsum"])
	rd.compute_list_bind_uniform_set(cl, uniform_set_prefixsum, 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["scatter"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_scatter[read_i], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["sim"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_sim[read_i], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)
	rd.compute_list_add_barrier(cl)

	rd.compute_list_bind_compute_pipeline(cl, pipeline_rids["render"])
	rd.compute_list_bind_uniform_set(cl, uniform_sets_render[read_i], 0)
	rd.compute_list_set_push_constant(cl, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(cl, total_groups, 1, 1)

	rd.compute_list_end()
	frame_parity = write_i

	# Post-dispatch CPU readback: picks up blasts detonated THIS frame by
	# the sim (see read_explosions). GPU results are not guaranteed visible
	# to buffer_get_data until the compute list ends, so this must stay
	# after compute_list_end().
	read_explosions()


func _exit_tree() -> void:
	if not rd:
		return
	for name in pipeline_rids:
		rd.free_rid(pipeline_rids[name])
	for name in shader_rids:
		rd.free_rid(shader_rids[name])
	# Uniform sets FIRST: freeing a buffer auto-frees the uniform sets bound
	# to it (RenderingDevice dependency tracking), so freeing the buffers
	# before the sets would make every set free below hit an invalid ID.
	for rid in uniform_sets_count: rd.free_rid(rid)
	for rid in uniform_sets_scatter: rd.free_rid(rid)
	for rid in uniform_sets_sim: rd.free_rid(rid)
	for rid in uniform_sets_render: rd.free_rid(rid)
	rd.free_rid(uniform_set_prefixsum)
	for rid in state_buffers:
		rd.free_rid(rid)
	rd.free_rid(cell_count_rid)
	rd.free_rid(cell_offset_rid)
	rd.free_rid(write_cursor_rid)
	rd.free_rid(sorted_indices_rid)
	rd.free_rid(path_followers_rid)
	rd.free_rid(econ_res_rid)
	rd.free_rid(econ_stats_rid)
	rd.free_rid(collapse_rid)
	rd.free_rid(explode_buf_rid)
	if heightmap_rid.is_valid():
		rd.free_rid(heightmap_rid)
	for rid in _heightmap_retired:
		if rid.is_valid():
			rd.free_rid(rid)
	for rid in dmg_buffers:
		rd.free_rid(rid)


## Returns the offset hex coordinates Vector2i(col, row) for a given 2D
## world position, using FLAT-TOP axial math and matching HexTerrain's
## hex_nodes keying (odd-q: odd columns are shifted down half a row).
## Effective hex size accounts for mesh_scale so this lines up with the
## terrain's real world-space hex boundaries, not just its pre-scale units.
func world_to_hex(world_pos: Vector2) -> Vector2i:
	var SQRT_3 := sqrt(3.0)
	var horiz_spacing := hex_size * 1.5
	var vert_spacing := SQRT_3 * hex_size

	var total_width := float(hex_grid_width - 1) * horiz_spacing
	var total_depth := float(hex_grid_depth) * vert_spacing

	# Undo mesh_scale, then undo the -total_width/2 / -total_depth/2 offset
	var u := world_pos.x / mesh_scale + total_width * 0.5
	var v := world_pos.y / mesh_scale + total_depth * 0.5

	# Axial coordinates (flat-top)
	var q: float = (2.0 / 3.0 * u) / hex_size
	var r: float = (-1.0 / 3.0 * u + SQRT_3 / 3.0 * v) / hex_size
	var s: float = -q - r

	# Cube round
	var rq: int = roundi(q)
	var rr: int = roundi(r)
	var rs: int = roundi(s)

	var q_diff: float = abs(float(rq) - q)
	var r_diff: float = abs(float(rr) - r)
	var s_diff: float = abs(float(rs) - s)

	if q_diff > r_diff and q_diff > s_diff:
		rq = -rr - rs
	elif r_diff > s_diff:
		rr = -rq - rs

	var col := rq
	var row := rr + (rq - (rq & 1)) / 2

	return Vector2i(col, row)


func hex_to_id(col: int, row: int) -> int:
	return (col - hex_min_q) + (row - hex_min_r) * hex_width


func id_to_hex(id: int) -> Vector2i:
	return Vector2i(
		id % hex_width + hex_min_q,
		id / hex_width + hex_min_r
	)
var _hex_path_counts: Dictionary = {}

## Writes the packed building info into the cell_info buffer for the grid
## cell containing `world_pos` (XZ). Replicated across all 4 team slices.
## building_id 0 = castle, 1 = tower, 2 = wall; pass -1 to clear.
## `built`: false = construction site (boids will march there and build it).
## Layout must match sim.glsl's CellInfo comments - bit 31 is the BUILT flag.
## Whole-hex granularity: there are no sub-hex coordinates anymore (bits
## 16-30 are the GPU build-progress counter and must start at zero).
const BUILDING_BUILT_FLAG := 0x80000000
## Bit 30 of the packed word: "marked for demolition" (phone double-tapped
## the wall). Dots near a marked wall chip its build progress to zero and
## the word gets wiped. Must match sim.glsl's DELETE_MARK_BIT.
const BUILDING_DELETE_MARK_FLAG := 0x40000000

func set_cell_building(world_pos: Vector2, building_id: int, team: int, built: bool = true, mark_for_delete: bool = false) -> void:
	var packed: int
	if building_id < 0:
		packed = 0xFF  # "none"
	else:
		packed = (building_id & 0xFF) | ((team & 0xFF) << 8)
	if built:
		packed |= BUILDING_BUILT_FLAG
	if mark_for_delete:
		packed |= BUILDING_DELETE_MARK_FLAG

	# Which grid cell does this building's center fall in?
	# NOTE: world_pos is an XZ Vector2 (x = world x, y = world z), so the
	# row index must use WORLD_MIN.z - using WORLD_MIN.y (the Y floor, 10)
	# offset every building ~36 rows and the GPU never saw walls where
	# boids actually walk.
	var cx := int(floor((world_pos.x - WORLD_MIN.x) / CELL_SIZE))
	var cz := int(floor((world_pos.y - WORLD_MIN.z) / CELL_SIZE))
	cx = clampi(cx, 0, grid_dims.x - 1)
	cz = clampi(cz, 0, grid_dims.z - 1)

	# MINES: go NEUTRAL (team byte 0xFF) the moment they finish building -
	# production and the collapse countdown only start once a team's dots
	# stand on it and capture it (sim.glsl's capture block treats 0xFF as
	# "no owner, free to take"). BUT if the GPU already finished this mine
	# and a boid CAPTURED it before this re-mark ran, keep the live team
	# byte: blindly forcing neutral here silently undid captures that
	# happened in the window between the GPU's built-flip and the CPU poll
	# (dots standing on the mine, ownership flickering back to neutral -
	# captures looked like they "didn't take").
	if built and building_id == 1:
		var live := rd.buffer_get_data(cell_info_rid, (cz * grid_dims.x + cx) * 8 + 4, 4)
		var live_packed: int = live.decode_u32(0) if live.size() >= 4 else 0
		if (live_packed & BUILDING_BUILT_FLAG) != 0:
			packed = (packed & ~(0xFF << 8)) | (live_packed & 0xFF00)  # keep live owner
		else:
			packed = (packed & ~(0xFF << 8)) | (0xFF << 8)  # fresh completion: neutral

	# WALLS cover their whole hex: a wall hexagon (~20 world units across,
	# hex_size * mesh_scale circumradius) spans several 5-unit grid cells,
	# so writing only the center cell let boids walk straight through most
	# of the wall's face. Every grid cell whose center lies inside the
	# hex's inscribed circle gets the packed word. ONLY for built walls:
	# an unbuilt site must stay center-cell only, or builder progress
	# would split across all covered cells (the sim accumulates progress
	# per cell). The build poll re-marks the wall built=true on completion,
	# which is what fans the blocking word out over the whole hex.
	var covered: Array = [Vector2i(cx, cz)]
	if building_id == 2 and built:
		var inner_r := hex_size * mesh_scale * 0.8660254
		var half := ceili(inner_r / CELL_SIZE)
		for dx in range(-half, half + 1):
			for dz in range(-half, half + 1):
				if dx == 0 and dz == 0:
					continue
				var tx := clampi(cx + dx, 0, grid_dims.x - 1)
				var tz := clampi(cz + dz, 0, grid_dims.z - 1)
				var wx := (float(tx) + 0.5) * CELL_SIZE + WORLD_MIN.x
				var wz := (float(tz) + 0.5) * CELL_SIZE + WORLD_MIN.z
				if Vector2(wx, wz).distance_to(world_pos) <= inner_r:
					covered.append(Vector2i(tx, tz))

	var xz := grid_dims.x * grid_dims.z
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_u32(0, packed)
	# One 4-byte update per team slice per covered cell (slices are not
	# contiguous). Rare (player clicks), so per-cell updates are fine.
	for cell_v in covered:
		var cell_idx = cell_v.y * grid_dims.x + cell_v.x
		for t in range(num_teams):
			var byte_off = (t * xz + cell_idx) * 8 + 4  # skip hex_id, write building
			rd.buffer_update(cell_info_rid, byte_off, 4, buf)

	# Remember where this building lives so get_building_build_state()
	# can find it again when a boid finishes constructing it. Built mines
	# also join the economy: they pay income and count down to collapse.
	if building_id >= 0:
		_building_sites[Vector2i(cx, cz)] = {"packed": packed, "world": world_pos}
		if building_id == 1 and built:
			# team = live owner if a capture already landed on the GPU
			# (see the preserve block above), else -1 (neutral).
			var start_team := -1
			if (packed >> 8) & 0xFF != 0xFF:
				start_team = (packed >> 8) & 0xFF
			_active_mines[Vector2i(cx, cz)] = {"team": start_team, "world": world_pos, "life": MINE_LIFETIME}
		elif building_id == 1 and not built:
			_active_mines.erase(Vector2i(cx, cz))
	else:
		_building_sites.erase(Vector2i(cx, cz))
		_active_mines.erase(Vector2i(cx, cz))


## Removes a player-placed BARRACK at world_pos (XZ): clears the GPU
## building word, forgets the site, and reports success. Everything else
## refuses - mines are the frontier economy (they die by collapse, not by
## deletion) and walls are the map itself. Production stops naturally:
## the economy tick only revives/produces while a team owns a barrack.
## Returns true if a barrack was actually removed.
func remove_building_at(world_pos: Vector2) -> bool:
	var cx := int(floor((world_pos.x - WORLD_MIN.x) / CELL_SIZE))
	var cz := int(floor((world_pos.y - WORLD_MIN.z) / CELL_SIZE))
	var key := Vector2i(cx, cz)
	if not _building_sites.has(key):
		return false
	# Barracks only (id 0). The packed site word carries the building id.
	if (_building_sites[key].get("packed", 0xFF) & 0xFF) != 0:
		return false
	_building_sites.erase(key)
		# Clear the building word in every team slice (barracks occupy exactly
	# their center cell - only walls fan out over multiple cells).
	var xz := grid_dims.x * grid_dims.z
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_u32(0, 0xFF)  # "no building"
	for t in range(num_teams):
		var byte_off := (t * xz + cz * grid_dims.x + cx) * 8 + 4
		rd.buffer_update(cell_info_rid, byte_off, 4, buf)
	return true

## Uploads the terrain heightmap the dots' ground clamp samples on the GPU.
## img: the same Image HexTile._sample_height ran on (the main screen's
## NoiseTexture2D RED channel); height_scale: its exported scale.
##
## Layout (must match sim.glsl's HeightmapBuf): 4-float header -
##   [0] map_w, [1] map_h, [2] height_scale, [3] pad
## then row-major RED samples (w * h, x fastest), NATIVE image resolution.
## The shader maps world XZ to texels with u = x / mesh_scale,
## v = z / mesh_scale, fx = u + map_w * 0.5, fz = v + map_h * 0.5 - exactly
## HexTile._sample_height's centered mapping (image texel (0,0) is the map
## corner at (-half_width, -half_depth) in mesh_scale units) - and expands
## with `r * 4.0 * height_scale`. Out-of-map coordinates clamp to the edge
## texel on both CPU and GPU.
##
## Safe to call again at any time (e.g. re-generated terrain): the old buffer
## is RETIRED (not freed) and the new one becomes heightmap_rid; the next
## rebuild_sim_uniform_sets() (or _exit_tree) frees the retired buffers only
## AFTER the uniform sets that referenced them are gone. Freeing the buffer
## here would instantly invalidate the sim uniform sets still bound to it
## (RenderingDevice dependency tracking), and the rebuild would then crash
## on "Attempted to free invalid ID".
func set_heightmap(img: Image, height_scale: float = 10.0) -> void:
	if rd == null:
		push_warning("set_heightmap: sim not started (rd == null) - ignored.")
		return
	if img == null:
		return
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return
	# Native resolution upload - no resampling, no square padding. Texel
	# (0,0) is the map corner at (-half_width, -half_depth) in mesh_scale
	# units, matching the mesh sampler (see the layout comment above).
	var data := PackedFloat32Array()
	data.resize(4 + w * h)
	data[0] = float(w)
	data[1] = float(h)
	data[2] = height_scale
	data[3] = 0.0
	# Raw byte decode of the red channel (RGBA8/L8 fast paths, generic
	# get_pixel fallback otherwise) - one get_data() instead of millions of
	# marshaled get_pixel calls, which visibly stalled startup.
	var fmt := img.get_format()
	var bytes := img.get_data()
	if fmt == Image.FORMAT_RGBA8:
		for i in w * h:
			data[4 + i] = float(bytes[i * 4]) / 255.0
	elif fmt == Image.FORMAT_L8:
		for i in w * h:
			data[4 + i] = float(bytes[i]) / 255.0
	else:
		for y in range(h):
			for x in range(w):
				data[4 + y * w + x] = img.get_pixel(x, y).r
	var new_rid := rd.storage_buffer_create(data.size() * 4, data.to_byte_array())
	# Retire - do NOT free here: the sim uniform sets still bind this rid and
	# freeing it would invalidate them (see the doc comment above).
	if heightmap_rid.is_valid():
		_heightmap_retired.append(heightmap_rid)
	heightmap_rid = new_rid
	heightmap_width = w
	heightmap_depth = h
	terrain_height_scale = height_scale
	_heightmap_cpu = data  # cache for get_ground_height()
	print("Heightmap uploaded: %dx%d samples (native res), height_scale %.1f" % [w, h, height_scale])

## Rebuilds every uniform set so the sim sets bind the CURRENT heightmap
## rid. Needed right after set_heightmap() swaps the buffer when you want
## the new terrain sampled immediately (otherwise the swap lands naturally
## within one frame's ping-pong). Frees and rebuilds ALL sets - the builder
## only appends, so clearing just the sim arrays would leave stale
## count/scatter/render sets shadowing the fresh ones at the ping-pong
## indices _process indexes with.
func rebuild_sim_uniform_sets() -> void:
	if rd == null or not shader_rids.has("sim"):
		return
	for rid in uniform_sets_count: rd.free_rid(rid)
	for rid in uniform_sets_scatter: rd.free_rid(rid)
	for rid in uniform_sets_sim: rd.free_rid(rid)
	for rid in uniform_sets_render: rd.free_rid(rid)
	if uniform_set_prefixsum.is_valid():
		rd.free_rid(uniform_set_prefixsum)
	uniform_sets_count.clear()
	uniform_sets_scatter.clear()
	uniform_sets_sim.clear()
	uniform_sets_render.clear()
	# Sets are gone - only NOW is it safe to free the heightmap buffers they
	# referenced (see set_heightmap's retirement comment).
	for rid in _heightmap_retired:
		if rid.is_valid():
			rd.free_rid(rid)
	_heightmap_retired.clear()
	_build_uniform_sets()

## CPU-side twin of sim.glsl's terrain_height(): the terrain surface Y at a
## world XZ position. World coordinates convert to heightmap texels with
## u = x / mesh_scale, v = z / mesh_scale, fx = u + width * 0.5,
## fz = v + depth * 0.5 - exactly HexTile._sample_height's centered mapping
## (the shader does the same) - then bilinear over the uploaded samples with
## HexTile's `r * 4.0 * height_scale` expansion. Returns the flat world
## floor before any upload - same fallback as the shader. Reads the cached
## CPU copy, so it's cheap enough to call per revived dot.
func get_ground_height(x: float, z: float) -> float:
	if heightmap_width <= 1 or heightmap_depth <= 1 \
			or _heightmap_cpu.size() < 4 + heightmap_width * heightmap_depth:
		return WORLD_MIN.y
	var mw := float(heightmap_width)
	var mh := float(heightmap_depth)
	var u := x / mesh_scale
	var v := z / mesh_scale
	var fx := clampf(u + mw * 0.5, 0.0, mw - 1.0)
	var fz := clampf(v + mh * 0.5, 0.0, mh - 1.0)
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var x1 := mini(x0 + 1, heightmap_width - 1)
	var z1 := mini(z0 + 1, heightmap_depth - 1)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var hs := _heightmap_cpu[2]
	var c00 := _heightmap_cpu[4 + z0 * heightmap_width + x0]
	var c10 := _heightmap_cpu[4 + z0 * heightmap_width + x1]
	var c01 := _heightmap_cpu[4 + z1 * heightmap_width + x0]
	var c11 := _heightmap_cpu[4 + z1 * heightmap_width + x1]
	var top := lerpf(c00, c10, tx)
	var bottom := lerpf(c01, c11, tx)
	return lerpf(top, bottom, tz) * 4.0 * hs


## CPU readback of the GPU death-explosion buffer (sim.glsl binding 11):
## EXPLODE_SLOTS vec4 slots, xyz = blast world position, w = packed
## team<<24 | sim-time-of-blast * 256 (see the DETONATE write in sim.glsl).
## Called once per frame from _process AFTER the compute dispatch, so it
## sees this frame's detonations. Emits explosion_occurred for every blast
## detonated since the previous call (one signal per blast, ever).
## Reading the whole 2 KB list is nothing; there is no need for a count or
## a clear - timestamp filtering does all the work.
func read_explosions() -> void:
	var now := floorf(_elapsed_seconds * 256.0)
	var data := rd.buffer_get_data(explode_buf_rid, 0, EXPLODE_SLOTS * 16)
	if data.size() < EXPLODE_SLOTS * 16:
		return
	var prev_read := _last_blast_read_time
	_last_blast_read_time = now
	for s in EXPLODE_SLOTS:
		var off := s * 16
		var w := data.decode_s32(off + 12) & 0xFFFFFFFF  # treat as unsigned u32
		var blast_time := float(w & 0x00FFFFFF)
		# Fresh blast = detonated after our previous read (age 0 this frame)
		# or still within BLAST_TTL from a slot we never saw (age > 0).
		if blast_time <= prev_read or blast_time > now:
			continue
		var pos := Vector3(
			data.decode_float(off),
			data.decode_float(off + 4),
			data.decode_float(off + 8)
		)
		var team := (w >> 24) & 0xFF
		explosion_occurred.emit(pos, team, max(0.0, _elapsed_seconds - blast_time / 256.0))


## Bulk-writes terrain wall hexes into the cell_info buffer: ONE read + ONE
## full-buffer update per call instead of thousands of tiny buffer_update
## calls (which stalled startup for ~800 wall tiles × team slices).
## Walls: Array of Vector2 world positions (x, z) of wall hex centers.
## Packed word: building 2 (wall), team byte 255 = "terrain" (blocks every
## team; the shader's hostile scan skips it so boids don't attack scenery).
func set_terrain_walls(walls: Array) -> void:
	var xz := grid_dims.x * grid_dims.z
	var size_bytes := table_size * 8
	var data := rd.buffer_get_data(cell_info_rid, 0, size_bytes)
	if data.size() < size_bytes:
		push_warning("set_terrain_walls: buffer size mismatch (%d < %d)" % [data.size(), size_bytes])
		return
	var packed_wall := (2 & 0xFF) | ((255 & 0xFF) << 8) | BUILDING_BUILT_FLAG
	# Same whole-hex coverage as set_cell_building: every grid cell whose
	# center lies inside a wall hex's inscribed circle gets the word, so
	# boids can't slip between adjacent wall-hex center cells.
	var inner_r := hex_size * mesh_scale * 0.8660254
	var half := ceili(inner_r / CELL_SIZE)
	for wp in walls:
		var ccx := clampi(int(floor((wp.x - WORLD_MIN.x) / CELL_SIZE)), 0, grid_dims.x - 1)
		var ccz := clampi(int(floor((wp.y - WORLD_MIN.z) / CELL_SIZE)), 0, grid_dims.z - 1)
		for dx in range(-half, half + 1):
			for dz in range(-half, half + 1):
				var tx := ccx + dx
				var tz := ccz + dz
				if tx < 0 or tx >= grid_dims.x or tz < 0 or tz >= grid_dims.z:
					continue
				var wx := (float(tx) + 0.5) * CELL_SIZE + WORLD_MIN.x
				var wz := (float(tz) + 0.5) * CELL_SIZE + WORLD_MIN.z
				if Vector2(wx, wz).distance_to(wp) > inner_r:
					continue
				var cell_idx := tz * grid_dims.x + tx
				for t in range(num_teams):
					var byte_off := (t * xz + cell_idx) * 8 + 4  # skip hex_id, write building
					data.encode_u32(byte_off, packed_wall)
	rd.buffer_update(cell_info_rid, 0, size_bytes, data)


## Per-cell building bookkeeping for the build flow:
## Vector2i(cell_x, cell_z) -> {"packed": int, "world": Vector2}
var _building_sites: Dictionary = {}

## Every cell containing a BUILT mine, for the economy tick + collapse:
## Vector2i(cell_x, cell_z) -> {"team": int, "world": Vector2}
var _active_mines: Dictionary = {}

## Runs once per simulated second: mines pay out, upkeep drains, starve
## flags update, and each barrack revives one dead dot if the team can pay.
func _economy_tick() -> void:
	var income := []
	var upkeep := []
	for t in range(num_teams):
		income.append(0.0)
		upkeep.append(0.0)
	var mines_to_collapse: Array = []

	# --- mine income + lifetime countdown ---
	# Mines are DISABLED until built (a placed mine produces nothing and
	# never collapses on its own). Once built they're NEUTRAL (team byte
	# 0xFF in cell_info): any team's dot standing on it captures it, which
	# starts income and the MINE_LIFETIME countdown. Stealing it resets the
	# countdown. Ownership is read LIVE from the GPU each tick so captures
	# are credited the same second they happen (the old code paid a cached
	# placement-time owner that never changed).
	var _special_owner := -1  # set in the loop below when the special mine pays out
	for cell in _active_mines.keys():
		var mine: Dictionary = _active_mines[cell]
		# Live packed building word: team-0 slice, +4 skips the hex_id word.
		var live := rd.buffer_get_data(cell_info_rid, (cell.y * grid_dims.x + cell.x) * 8 + 4, 4)
		var owner := -1
		if live.size() >= 4:
			var packed_live: int = live.decode_u32(0)
			if (packed_live & 0xFF) == 1 and (packed_live & BUILDING_BUILT_FLAG) != 0:
				var bt: int = (packed_live >> 8) & 0xFF
				if bt != 0xFF:
					owner = bt  # neutral (0xFF) = uncaptured, no income
		if owner < 0:
			continue  # neutral: disabled, countdown frozen
		if owner != int(mine.get("team", -1)):
			# (Re)captured: the new owner gets a fresh 60 s and the color.
			mine.team = owner
			mine.life = MINE_LIFETIME
			mine_owner_changed.emit(cell, mine.world, owner)
		income[clampi(owner, 0, num_teams - 1)] += MINE_INCOME
		if cell == _special_mine_cell:
			# The special center mine: permanent (no lifetime countdown), and
			# its owner earns SPECIAL_MINE_BONUS per LIVING miner on top of the
			# normal income - 7 miners = 3x a regular mine (150/s total).
			_special_owner = owner
			continue
		var life: float = mine.get("life", MINE_LIFETIME) - 1.0
		mine.life = life
		if life <= 0.0:
			mines_to_collapse.append(cell)

	# --- upkeep: every LIVING dot costs 1 resource / 5 seconds ---
	var stats := rd.buffer_get_data(econ_stats_rid, 0, 2 * num_teams * 4)
	if stats.size() >= 2 * num_teams * 4:
		for t in range(num_teams):
			# The reserved NPC horde pays nothing: deserters live off the land,
			# so their pool never goes into debt and never starves.
			upkeep[t] = 0.0 if t == num_teams - 1 \
				else float(stats.decode_u32(t * 2 * 4)) * UPKEEP_PER_SEC

	# SPECIAL MINE: pay the per-living-miner bonus to its owner. Added to
	# income[] BEFORE the apply loop so the same tick's pool update and
	# deficit math see it. Full crew of 7 = 3x a regular mine (150/s total).
	if _special_mine_cell.x >= 0 and _special_owner >= 0:
		var living := 0
		for mid in _miner_ids:
			if mid >= 0 and _is_boid_alive(mid):
				living += 1
		income[clampi(_special_owner, 0, num_teams - 1)] += float(living) * SPECIAL_MINE_BONUS

	# --- apply, set starve flags + deficits, revive via barracks ---
	# Layout MUST match sim.glsl's econ_res reads: [t*3+1] = starve flag,
	# [t*3+2] = resource deficit encoded as a float. The deficit is the
	# team's CUMULATIVE debt: every second it can't pay, the shortfall is
	# added to the balance (negative money). It doubles as the desertion
	# driver - the deeper the debt, the faster boids randomly defect to the
	# NPC horde (see sim.glsl's DESERTION block). Earning while in debt
	# climbs back toward 0 and shrinks the conversion chance; hitting 0
	# clears the starve flag the same tick.
	var flags := PackedByteArray()
	flags.resize(num_teams * 3 * 4)
	for t in range(num_teams):
		_team_resources[t] += income[t] - upkeep[t]
		var deficit := 0.0
		if _team_resources[t] < 0.0:
			deficit = -_team_resources[t]       # cumulative debt (always > 0)
			_team_resources[t] = 0.0            # visible pool floors at zero
			flags.encode_u32(t * 3 * 4 + 4, 1)  # starve: sim bleeds boid health
		if deficit > 0.0:
			flags.encode_float(t * 3 * 4 + 8, deficit)

	# NPC horde pays no upkeep: deserters are hostile wanderers living off
	# the land. The revive loop below naturally skips them (no barracks and
	# an always-zero resource pool).
	for cell in mines_to_collapse:
		_collapse_mine(cell)

	# Revive: dead slots come back first (one per second per team, costs 1).
	# The count pass leaves the largest dead boid id + 1 in stats[t*2+1].
	# THEN production: each built barrack spawns BARRACK_PROD_RATE fresh
	# dots per second from unused slots (id >= live army size), same price
	# per dot. Barracks therefore both replace losses and grow the army.
	var barracks := []
	for t in range(num_teams):
		barracks.append(0)
	for cell in _building_sites.keys():
		var packed: int = _building_sites[cell].packed
		if (packed & 0xFF) == 0 and (packed & BUILDING_BUILT_FLAG) != 0:
			barracks[clampi((packed >> 8) & 0xFF, 0, num_teams - 1)] += 1
	for t in range(num_teams):
		var dead_id := stats.decode_u32((t * 2 + 1) * 4) if stats.size() >= 2 * num_teams * 4 else 0
		if barracks[t] > 0 and dead_id != 0 and _team_resources[t] >= BARRACK_REVIVE_COST:
			_team_resources[t] -= BARRACK_REVIVE_COST
			_revive_boid(t, dead_id - 1)
		# --- new-dot production ---
		if barracks[t] <= 0:
			continue  # no barrack: nothing can spawn for this team
		var prod: int = barracks[t] * BARRACK_PROD_RATE
		while prod > 0 and _team_resources[t] >= BARRACK_REVIVE_COST \
				and _next_free_slot[t] < _army_slot_cap:
			_team_resources[t] -= BARRACK_REVIVE_COST
			# _revive_boid spawns into the given slot at the team's first
			# barrack; production slots (>= army size) were never alive, so
			# no overlap with the revive pool can happen.
			_revive_boid(t, _next_free_slot[t])
			_next_free_slot[t] += 1
			prod -= 1

	rd.buffer_update(econ_res_rid, 0, flags.size(), flags)

	resources_changed.emit(_team_resources.duplicate())

## Whether the placing team can afford this building. Walls have a real
## price (WALL_COST); everything else is free to place.
func can_afford_building(building_id: int, team: int) -> bool:
	if building_id != 2:  # BUILDING_WALL
		return true
	if team < 0 or team >= _team_resources.size():
		return false
	return _team_resources[team] >= WALL_COST


## Deducts a building's placement price from the team's pool. Call only
## after can_afford_building() passed (placement is otherwise rejected).
func charge_building(building_id: int, team: int) -> void:
	if building_id != 2 or team < 0 or team >= _team_resources.size():
		return
	_team_resources[team] -= WALL_COST
	resources_changed.emit(_team_resources.duplicate())


## Sets the number of boids each team starts with. Both teams use the same
## count. The value is clamped to the multimesh instance budget; if the
## multimesh hasn't been sized yet, the value is stored and applied in
## _ready() when the budget is known.
## Sets how many team slots the sim runs with. MUST include one reserved
## NPC-horde slot on top of the playable teams (main_screen passes
## socket.max_teams + 1). Only effective before _ready - buffers are sized
## from num_teams at startup.
func set_num_teams(n: int) -> void:
	if rd != null:
		push_warning("set_num_teams called after the sim started - ignored.")
		return
	if n < 2:
		n = 2  # at least one player team + the horde
	num_teams = n


func set_dot_count_per_team(n: int) -> void:
	if rd != null:
		push_warning("set_dot_count_per_team called after the sim started - ignored.")
		return
	if n < 0:
		n = 0
	# Keep the total army inside the multimesh capacity for ANY team count
	# (player teams only - the NPC horde fills by desertion, not spawning).
	if instance_count > 0 and n * maxi(num_teams - 1, 1) > instance_count:
		n = instance_count / maxi(num_teams - 1, 1)
	_dots_per_team = n

func _revive_boid(team: int, boid_id: int) -> void:
	if boid_id < 0 or boid_id >= instance_count:
		return
	var barrack_pos := Vector2.ZERO
	var found := false
	for cell in _building_sites.keys():
		var packed: int = _building_sites[cell].packed
		if (packed & 0xFF) == 0 and (packed & BUILDING_BUILT_FLAG) != 0 \
				and ((packed >> 8) & 0xFF) == team:
			barrack_pos = _building_sites[cell].world
			found = true
			break
	if not found:
		return
	var floats_per_boid := 16
	var row := PackedFloat32Array()
	row.resize(floats_per_boid)
	row[0] = barrack_pos.x + randf_range(-2.0, 2.0)
	row[1] = get_ground_height(row[0], row[2])
	row[2] = barrack_pos.y + randf_range(-2.0, 2.0)
	row[3] = 0.0
	# vel = 0
	row[4] = 0.0; row[5] = 0.0; row[6] = 0.0; row[7] = 0.0
	row[8] = 0.0  # state
	var np := PackedByteArray()
	np.resize(4)
	np.encode_u32(0, 0xFFFFFFFF)
	row[9] = np.decode_float(0)
	row[10] = 0.0
	var tb := PackedByteArray()
	tb.resize(4)
	tb.encode_u32(0, team)
	row[11] = tb.decode_float(0)
	var hp := PackedByteArray()
	hp.resize(4)
	hp.encode_u32(0, 1000)
	row[12] = hp.decode_float(0)
	# Home hex = the hex the barrack stands in, NOT 0: a hardcoded 0 made
	# revived/produced dots walk to hex 0's center after their first fight.
	var spawn_hex := world_to_hex(barrack_pos)
	var hh := PackedByteArray()
	hh.resize(4)
	hh.encode_s32(0, hex_to_id(spawn_hex.x, spawn_hex.y))
	row[13] = hh.decode_float(0)
	var buf := row.to_byte_array()
	var byte_offset := boid_id * floats_per_boid * 4
	for sbuf in state_buffers:
		rd.buffer_update(sbuf, byte_offset, buf.size(), buf)

## Cheap CPU-side liveness probe for one boid slot (reads just the health
## word, 4 bytes). Used for the special miners.
func _is_boid_alive(boid_id: int) -> bool:
	if boid_id < 0 or boid_id >= instance_count:
		return false
	var data := rd.buffer_get_data(state_buffers[frame_parity], boid_id * 64 + 48, 4)
	return data.size() == 4 and data.decode_u32(0) > 0

## Activates the special center mine + its MINER_COUNT guardian dots. The
## mine is a normal neutral built mine (existing capture rules) except:
##   - its lifetime never counts down (permanent, never collapses),
##   - its owner earns SPECIAL_MINE_BONUS per living miner (3x at full crew),
##   - its hexagon hosts the miners, who never leave it (STATE_MINER).
## Call AFTER set_terrain_walls() (the mine word overwrites the center).
func setup_special_mine(world_pos: Vector2) -> void:
	if rd == null:
		return
	# The mine: neutral (team 0xFF), already built. Active mines live in
	# _active_mines; the special one is excluded from the lifetime countdown
	# in _economy_tick and pays the per-miner bonus instead.
	set_cell_building(world_pos, 1, 0xFF, true)
	var c := world_to_hex(world_pos)
	_special_mine_cell = Vector2i(int(floor((world_pos.x - WORLD_MIN.x) / CELL_SIZE)), \
		int(floor((world_pos.y - WORLD_MIN.z) / CELL_SIZE)))
	_special_mine_world = world_pos
	_special_mine_hex_id = hex_to_id(c.x, c.y)
	# The 7 miners: NPC-team dots with STATE_MINER, packed around the mine.
	for k in range(MINER_COUNT):
		# Spread the crew from mid-ring to near the rim (ring 0.35 .. 1.0).
		_spawn_miner(_miner_ids[k], 0.35 + 0.65 * float(k) / float(MINER_COUNT - 1))
	_miner_respawn_timer = MINER_RESPAWN_INTERVAL

## Seeds one miner boid slot: NPC team, STATE_MINER, positioned on a ring
## around the mine's hex center. `ring` 0..1 controls how close to the
## center it spawns (0 = center, 1 = near the hex rim).
func _spawn_miner(boid_id: int, ring: float) -> void:
	if boid_id < 0 or boid_id >= instance_count:
		return
	var floats_per_boid := 16
	var row := PackedFloat32Array()
	row.resize(floats_per_boid)
	var ang := TAU * float(boid_id % 7) / 7.0 + 0.45
	var pos_x := _special_mine_world.x + cos(ang) * (hex_size * mesh_scale * 0.55) * ring
	var pos_z := _special_mine_world.y + sin(ang) * (hex_size * mesh_scale * 0.55) * ring
	row[0] = pos_x
	row[1] = get_ground_height(pos_x, pos_z)
	row[2] = pos_z
	row[3] = 0.0
	row[4] = 0.0; row[5] = 0.0; row[6] = 0.0; row[7] = 0.0
	# state: miner. MUST be bit-packed like every other uint field here:
	# assigning the int directly stored float 128.0 (bits 0x43000000), which
	# shares NO bits with STATE_MINER (0x80). The 7 miners therefore spawned
	# as plain NPC dots - gray "deserters" roaming out of the map center -
	# instead of gold, hex-locked miners (the sim's miner early-out never
	# fired, so nothing re-set the flag either).
	var sb := PackedByteArray()
	sb.resize(4)
	sb.encode_u32(0, STATE_MINER_FLAG)
	row[8] = sb.decode_float(0)
	var np := PackedByteArray(); np.resize(4); np.encode_u32(0, 0xFFFFFFFF)
	row[9] = np.decode_float(0)  # no path
	row[10] = 0.0                # slot
	var tb := PackedByteArray(); tb.resize(4); tb.encode_u32(0, num_teams - 1)
	row[11] = tb.decode_float(0)  # NPC team: no upkeep/desertion/capture
	var hp := PackedByteArray(); hp.resize(4); hp.encode_u32(0, MINER_HEALTH)
	row[12] = hp.decode_float(0)
	var hh := PackedByteArray(); hh.resize(4); hh.encode_s32(0, _special_mine_hex_id)
	row[13] = hh.decode_float(0)  # home = the mine's hex
	var buf := row.to_byte_array()
	var byte_offset := boid_id * floats_per_boid * 4
	for sbuf in state_buffers:
		rd.buffer_update(sbuf, byte_offset, buf.size(), buf)

## Called from _process: respawns dead miners at the mine on a timer.
func _update_miners(delta: float) -> void:
	if _special_mine_cell.x < 0 or _miner_ids.size() == 0:
		return
	_miner_respawn_timer -= delta
	if _miner_respawn_timer > 0.0:
		return
	_miner_respawn_timer = MINER_RESPAWN_INTERVAL
	for k in range(_miner_ids.size()):
		var mid: int = _miner_ids[k]
		if not _is_boid_alive(mid):
			# dead: respawn on the ring at the same angle
			_spawn_miner(mid, 0.65 + 0.35 * float(k) / 6.0)
	# (living miners are left untouched)


## Depletes a mine: clears the building from cell_info, flags the tile
## collapsed (boids on it fall and die in sim.glsl), frees the site record.
func _collapse_mine(cell: Vector2i) -> void:
	if not _active_mines.has(cell):
		return
	var mine: Dictionary = _active_mines[cell]
	_active_mines.erase(cell)
	# 1. Remove the building from the GPU cell_info (every team slice).
	var xz := grid_dims.x * grid_dims.z
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_u32(0, 0xFF)  # "no building"
	for t in range(num_teams):
		var byte_off := (t * xz + cell.y * grid_dims.x + cell.x) * 8 + 4
		rd.buffer_update(cell_info_rid, byte_off, 4, buf)
	# 2. Flag the hex collapsed - sim indexes this flag by HEX id (not grid
	# cell) so EVERY dot on the hexagon falls, including dots that wander
	# onto it after the collapse (one hex spans several grid cells).
	var hex := world_to_hex(mine.world)
	var hex_id := hex_to_id(hex.x, hex.y)
	var total_hexes := hex_total_cells if hex_total_cells > 0 else (hex_grid_width * hex_grid_depth)
	hex_id = clampi(hex_id, 0, total_hexes - 1)
	var cbuf := PackedByteArray()
	cbuf.resize(4)
	cbuf.encode_u32(0, 1)
	if hex_id * 4 + 4 <= collapse_rid_size:
		rd.buffer_update(collapse_rid, hex_id * 4, 4, cbuf)
	# 3. Forget the site so barracks/build scans stop seeing it.
	_building_sites.erase(cell)
	mine_collapsed.emit(cell, mine.world)

## Reads the raw packed building word for grid cell (cx, cz) (team 0
## slice). Returns -1 when the buffer read fails. Bits match sim.glsl's
## CellInfo layout: 0-7 id, 8-15 team, 16-29 build progress, 30 delete
## mark, 31 built.
func get_building_word(cx: int, cz: int) -> int:
	var xz := grid_dims.x * grid_dims.z
	var byte_off := (0 * xz + cz * grid_dims.x + cx) * 8 + 4  # team 0 slice
	var data := rd.buffer_get_data(cell_info_rid, byte_off, 4)
	if data.size() < 4:
		return -1
	return data.decode_u32(0)

## Reads the BUILT flag back from the GPU for the building in grid cell
## (cx, cz). Returns true when a boid has finished constructing it, false
## while it's still a site. Empty cell -> true (nothing to wait for).
func is_building_built(cx: int, cz: int) -> bool:
	var key := Vector2i(cx, cz)
	if not _building_sites.has(key):
		return true
	var xz := grid_dims.x * grid_dims.z
	var byte_off := (0 * xz + cz * grid_dims.x + cx) * 8 + 4  # team 0 slice
	var data := rd.buffer_get_data(cell_info_rid, byte_off, 4)
	if data.size() < 4:
		return true
	var packed := data.decode_u32(0)
	return (packed & BUILDING_BUILT_FLAG) != 0

## True when the grid cell (cx, cz) holds no building anymore (word emptied
## to 0xFF). Used by the wall-demolition poll: the sim wipes a marked
## wall's word once dots have fully chipped it down.
func is_building_cleared(cx: int, cz: int) -> bool:
	var xz := grid_dims.x * grid_dims.z
	var byte_off := (0 * xz + cz * grid_dims.x + cx) * 8 + 4  # team 0 slice
	var data := rd.buffer_get_data(cell_info_rid, byte_off, 4)
	if data.size() < 4:
		return false
	return (data.decode_u32(0) & 0xFF) == 0xFF

## Clears the building word (back to empty 0xFF) in every team slice of
## every grid cell whose center lies inside the hex at `world_pos` - the
## inverse of set_cell_building()'s built-wall coverage fan-out. Used when
## a marked wall is torn down so no blocking word survives on the GPU.
func clear_building_at_hex(world_pos: Vector2) -> void:
	var cx := int(floor((world_pos.x - WORLD_MIN.x) / CELL_SIZE))
	var cz := int(floor((world_pos.y - WORLD_MIN.z) / CELL_SIZE))
	cx = clampi(cx, 0, grid_dims.x - 1)
	cz = clampi(cz, 0, grid_dims.z - 1)
	var inner_r := hex_size * mesh_scale * 0.8660254
	var half := ceili(inner_r / CELL_SIZE)
	var covered: Array = []
	for dx in range(-half, half + 1):
		for dz in range(-half, half + 1):
			var tx := clampi(cx + dx, 0, grid_dims.x - 1)
			var tz := clampi(cz + dz, 0, grid_dims.z - 1)
			var wx := (float(tx) + 0.5) * CELL_SIZE + WORLD_MIN.x
			var wz := (float(tz) + 0.5) * CELL_SIZE + WORLD_MIN.z
			if Vector2(wx, wz).distance_to(world_pos) <= inner_r:
				covered.append(Vector2i(tx, tz))
	var xz := grid_dims.x * grid_dims.z
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_u32(0, 0xFF)
	for cell_v in covered:
		var cell_idx: int = cell_v.y * grid_dims.x + cell_v.x
		_building_sites.erase(Vector2i(cell_v.x, cell_v.y))
		for t in range(num_teams):
			var byte_off: int = (t * xz + cell_idx) * 8 + 4
			rd.buffer_update(cell_info_rid, byte_off, 4, buf)

## Set the number of available paths stored for a given hex cell and team.
func set_hex_path_count(col: int, row: int, team: int, path_count: int) -> void:
	team = clampi(team, 0, num_teams - 1)
	var hex_id := hex_to_id(col, row)
	var team_hex_key := "%d_%d" % [hex_id, team]
	_hex_path_counts[team_hex_key] = path_count

	var team_hex_idx := hex_id * num_teams + team
	var hex_offset := team_hex_idx * 1368
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_s32(0, path_count)
	var total_max := (hex_total_cells if hex_total_cells > 0 else hex_grid_width * hex_grid_depth) * num_teams * 1368
	if hex_offset + 4 <= total_max:
		rd.buffer_update(global_paths_rid, hex_offset, buf.size(), buf)

## Set what fraction (0.0 - 1.0) of boids may claim paths on the hex at
## (col, row) for `team`. 0 (or <= 0) means every boid may claim. Affects
## only NEW claims - boids already following a path finish it.
func set_path_fraction(col: int, row: int, team: int, fraction: float) -> void:
	team = clampi(team, 0, num_teams - 1)
	var hex_id := hex_to_id(col, row)
	var team_hex_idx := hex_id * num_teams + team
	var offset := team_hex_idx * 1368 + 4  # claim_chance sits after path_count
	var total_max := (hex_total_cells if hex_total_cells > 0 else hex_grid_width * hex_grid_depth) * num_teams * 1368
	if offset + 4 <= total_max:
		var buf := PackedByteArray()
		buf.resize(4)
		buf.encode_float(0, clampf(fraction, 0.0, 1.0))
		rd.buffer_update(global_paths_rid, offset, 4, buf)


## Write a global path of world-space Vector2 points for a hex cell, team, and path slot.
## `points` is an Array of Vector2 (xz positions in main view world space).
## Returns the slot the path was written to (0..9), or -1 if rejected -
## callers keep it so they can later ask get_path_followers() when the
## path's visual should disappear.
func set_path(points: Array, col: int = 0, row: int = 0, team: int = 0, path_slot: int = -1, total_hex_paths: int = -1) -> int:
	if points.is_empty():
		return -1

	team = clampi(team, 0, num_teams - 1)

	# Extract start point
	var p0: Vector2
	if points[0] is Vector2:
		p0 = points[0]
	elif points[0] is Vector2i:
		p0 = Vector2(points[0].x, points[0].y)
	elif points[0] is Dictionary:
		p0 = Vector2(float(points[0].get("x", 0.0)), float(points[0].get("y", 0.0)))
	else:
		p0 = Vector2.ZERO

	# Auto-detect starting hex if col/row are defaulted to (0,0)
	if col == 0 and row == 0:
		var start_hex := world_to_hex(p0)
		col = start_hex.x
		row = start_hex.y

	var hex_id := hex_to_id(col, row)
	var team_hex_key := "%d_%d" % [hex_id, team]

	if path_slot < 0:
		var current_cnt: int = _hex_path_counts.get(team_hex_key, 0)
		path_slot = current_cnt % 10
		total_hex_paths = min(current_cnt + 1, 10)
		_hex_path_counts[team_hex_key] = total_hex_paths
	else:
		path_slot = clampi(path_slot, 0, 9)
		if total_hex_paths < 0:
			total_hex_paths = max(path_slot + 1, _hex_path_counts.get(team_hex_key, 1))
		_hex_path_counts[team_hex_key] = total_hex_paths

	var team_hex_idx := hex_id * num_teams + team
	var hex_offset := team_hex_idx * 1368
	var total_max := (hex_total_cells if hex_total_cells > 0 else hex_grid_width * hex_grid_depth) * num_teams * 1368

	# Update the team-hex's path_count
	var count_buf := PackedByteArray()
	count_buf.resize(4)
	count_buf.encode_s32(0, total_hex_paths)
	if hex_offset + 4 <= total_max:
		rd.buffer_update(global_paths_rid, hex_offset, count_buf.size(), count_buf)

	# GLSL layout for Path struct: vec2 points[16] (128 bytes) + int count (4)
	# + float expiry (4) = 136-byte stride. expiry is the elapsed-sim-time
	# deadline after which NEW boids can't claim the path (boids that already
	# claimed it finish it regardless). <= 0 means never expires.
	var buf := PackedByteArray()
	buf.resize(136)
	var count := mini(points.size(), 16)
	for i in range(count):
		var p: Vector2
		if points[i] is Vector2:
			p = points[i]
		elif points[i] is Vector2i:
			p = Vector2(points[i].x, points[i].y)
		elif points[i] is Dictionary:
			p = Vector2(float(points[i].get("x", 0.0)), float(points[i].get("y", 0.0)))
		else:
			p = Vector2.ZERO
		buf.encode_float(i * 8, p.x)
		buf.encode_float(i * 8 + 4, p.y)
	# int count at byte offset 128
	buf.encode_s32(128, count)
	# float expiry at byte offset 132 (was std430 padding)
	buf.encode_float(132, _elapsed_seconds + path_lifetime if path_lifetime > 0.0 else 0.0)

	var path_offset := hex_offset + 8 + path_slot * 136
	if path_offset + buf.size() <= total_max:
		rd.buffer_update(global_paths_rid, path_offset, buf.size(), buf)
	return path_slot


## How many boids are still following the path at (hex_id, team, slot)?
## Counted by count.glsl every frame (one atomicAdd per pathed boid).
func get_path_followers(hex_id: int, team: int, slot: int) -> int:
	if path_followers_rid.is_valid() and _path_followers_cells > 0:
		var idx := ((hex_id * num_teams) + clampi(team, 0, num_teams - 1)) * 10 + clampi(slot, 0, 9)
		var total := _path_followers_cells * num_teams * 10
		if idx >= 0 and idx < total:
			var data := rd.buffer_get_data(path_followers_rid, idx * 4, 4)
			if data.size() >= 4:
				return int(data.decode_u32(0))
	return 0


## Sim-time when the path at (hex_id, team, slot) expires (<= 0 = never).
func get_path_expiry(hex_id: int, team: int, slot: int) -> float:
	var num_cells := hex_total_cells if hex_total_cells > 0 else (hex_grid_width * hex_grid_depth)
	var team_hex_idx := hex_id * num_teams + clampi(team, 0, num_teams - 1)
	var offset := team_hex_idx * 1368 + 8 + clampi(slot, 0, 9) * 136 + 132
	var total_max := num_cells * num_teams * 1368
	if offset + 4 <= total_max:
		var data := rd.buffer_get_data(global_paths_rid, offset, 4)
		if data.size() >= 4:
			return data.decode_float(0)
	return 0.0


## Computes the four corner base rectangles for the ACTUAL grid, so every
## team always spawns in a real corner regardless of grid_width/grid_depth.
## Returns the world-space Vector3 center of hex cell (col, row).
func get_hex_center(col: int, row: int) -> Vector3:
	var SQRT_3 := sqrt(3.0)
	var horiz_spacing := hex_size * 1.5
	var vert_spacing := SQRT_3 * hex_size
	var total_width := float(hex_grid_width - 1) * horiz_spacing
	var total_depth := float(hex_grid_depth) * vert_spacing

	# offset (col,row) -> axial (q,r)
	var q := col
	var r := row - (col - (col & 1)) / 2

	# axial -> pixel (flat-top)
	var u := hex_size * (3.0 / 2.0 * float(q))
	var v := hex_size * (SQRT_3 / 2.0 * float(q) + SQRT_3 * float(r))

	# apply mesh_scale and center offset (inverse of world_to_hex)
	var wx := (u - total_width * 0.5) * mesh_scale
	var wz := (v - total_depth * 0.5) * mesh_scale

	# Terrain height at the center, not the flat world floor: callers
	# (miner placement, mine setup) need world positions ON the visible
	# terrain, matching the dots' own ground clamp (get_ground_height).
	return Vector3(wx, get_ground_height(wx, wz), wz)

## Computes the four corner base rectangles for the ACTUAL grid, so every
## team always spawns in a real corner regardless of grid_width/grid_depth.
func _compute_team_bases() -> void:
	var bw := 3 # base width in tiles
	var bh := 2 # base height in tiles
	# Base rects are laid out in TERRAIN tile coordinates (matching
	# main_screen.gd's grid_width/grid_depth), then converted into the sim's
	# hex-id space by adding hex_min_q/hex_min_r. The sim's hex id space spans
	# the WORLD box, which is wider than the terrain (corner scan gave
	# col=[-10..30] for a 40-col terrain), so bounding the rects by the scan's
	# max col/row parks the right/bottom bases ON the terrain's outer wall
	# ring - they must hug the terrain's interior edge (grid-2) instead.
	var ter_w := hex_grid_width
	var ter_d := hex_grid_depth
	var ms := get_tree().root.get_node_or_null("MainScreen")
	if ms == null:
		var anc := get_parent()
		while anc != null and ms == null:
			if "grid_width" in anc:
				ms = anc
			anc = anc.get_parent()
	if ms != null and "grid_width" in ms and "grid_depth" in ms:
		ter_w = int(ms.grid_width)
		ter_d = int(ms.grid_depth)
	else:
		# Fallback: derive the terrain size from the world box (both are
		# centered on the origin).
		ter_w = maxi(3, roundi((WORLD_MAX.x - WORLD_MIN.x) / (hex_size * 1.5 * mesh_scale)))
		ter_d = maxi(3, roundi((WORLD_MAX.z - WORLD_MIN.z) / (sqrt(3.0) * hex_size * mesh_scale)))
	var min_c := hex_min_q
	var min_r := hex_min_r
	# Terrain interior (inside the always-wall outer ring) is
	# 1..ter_w-2 x 1..ter_d-2; the right/bottom bases hug that edge.
	var right_c := min_c + ter_w - 2 - bw  # left col of the right-hand bases
	var bot_r := min_r + ter_d - 2 - bh    # top row of the bottom bases
	var edge_c := min_c + ter_w - 2
	var edge_r := min_r + ter_d - 2
	# The four corners are fixed so 1-4 team games keep the classic layout.
	team_bases = [
		[min_c + 1, min_r + 1, min_c + bw, min_r + bh],        # team 0 - top-left
		[right_c, min_r + 1, edge_c, min_r + bh],              # team 1 - top-right
		[right_c, bot_r, edge_c, edge_r],                      # team 2 - bottom-right
		[min_c + 1, bot_r, min_c + bw, edge_r],                # team 3 - bottom-left
	]
	# Teams beyond 4 get bases on a ring around the map center, evenly
	# spaced, so ANY team count spawns somewhere valid on the grid.
	var mid_c := (min_c + 1 + edge_c - bw) / 2.0
	var mid_r := (min_r + 1 + edge_r - bh) / 2.0
	var extra := maxi(num_teams - 4, 1)
	for t in range(4, num_teams):
		var angle := TAU * float(t - 4) / float(extra) - PI / 2.0
		var cc := clampi(roundi(mid_c * (1.0 + cos(angle) * 0.9)), min_c + 1, edge_c - bw)
		var cr := clampi(roundi(mid_r * (1.0 + sin(angle) * 0.9)), min_r + 1, edge_r - bh)
		team_bases.append([cc, cr, cc + bw - 1, cr + bh - 1])


## Drops `team`'s starting units into its walled corner base. `team` must
## be 0 or 1 (the live teams; team slots 2 and 3 are unused for now).
## This version builds a single boid row and copies it into the state buffer
## at the correct offset; it does NOT touch `init_state` directly.
func _spawn_team_army(team: int) -> void:
	# Collect spawn tiles for this team's corner base.
	var base: Array = team_bases[team]
	var spawn_tiles: Array = []
	for c in range(base[0], base[2] + 1):
		for r in range(base[1], base[3] + 1):
			if c == base[0] and r == base[1]:
				continue # skip the generator tile
			spawn_tiles.append(Vector2i(c, r))

	# Find all boids belonging to this team (boid i has team = i % player_teams).
	var team_boids: Array = []
	for i in range(_dots_per_team * (num_teams - 1)):
		if i % (num_teams - 1) == team:
			team_boids.append(i)

	var jitter := mesh_scale * 0.3
	var floats_per_boid := 16

	for bi in range(team_boids.size()):
		var boid_id: int = team_boids[bi]
		var cell: Vector2i = spawn_tiles[bi % spawn_tiles.size()]
		var center := get_hex_center(cell.x, cell.y)
		var offset := Vector3(randf_range(-jitter, jitter), randf_range(0.0, 4.0), randf_range(-jitter, jitter))
		var pos := center + offset

		var hex := world_to_hex(Vector2(pos.x, pos.z))
		var hex_id := hex_to_id(hex.x, hex.y)

		var row := PackedFloat32Array()
		row.resize(floats_per_boid)
		row[0] = pos.x
		row[1] = pos.y
		row[2] = pos.z
		var hb := PackedByteArray()
		hb.resize(4)
		hb.encode_u32(0, hex_id)
		row[3] = hb.decode_float(0)
		row[4] = 0.0
		row[5] = 0.0
		row[6] = 0.0
		row[7] = 0.0
		row[8] = 0.0
		var np := PackedByteArray()
		np.resize(4)
		np.encode_u32(0, 0xFFFFFFFF)
		row[9] = np.decode_float(0)
		row[10] = 0.0
		var tb := PackedByteArray()
		tb.resize(4)
		tb.encode_u32(0, team)
		row[11] = tb.decode_float(0)
		var hp := PackedByteArray()
		hp.resize(4)
		hp.encode_u32(0, 1000)
		row[12] = hp.decode_float(0)
		var shh := PackedByteArray()
		shh.resize(4)
		shh.encode_s32(0, hex_id)
		row[13] = shh.decode_float(0)

		var buf := row.to_byte_array()
		var byte_offset := boid_id * floats_per_boid * 4
		for sbuf in state_buffers:
			rd.buffer_update(sbuf, byte_offset, buf.size(), buf)


## Current per-team resource pools (for UIs). Index = team id.
func get_team_resources() -> Array:
	return _team_resources.duplicate()
