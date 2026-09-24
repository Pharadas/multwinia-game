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

## Number of team slices the sim runs with. FIXED at MAX_PLAYER_TEAMS + 1
## (the +1 is the reserved NPC horde, team id num_teams - 1): every team-
## indexed buffer (spatial grid, hex paths, econ stats) is sized ONCE for
## that many slices at startup, so teams never have to be configured. A
## player team only becomes real when a phone joins (activate_team seeds
## its army and grants its pool) - any number of phones up to
## MAX_PLAYER_TEAMS can play with zero configuration. Deserters convert
## into the horde; no phone is ever assigned it.
const MAX_PLAYER_TEAMS := 16
var num_teams: int = MAX_PLAYER_TEAMS + 1

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

## LOBBY GATE. The main screen owns when the match actually begins: it lists
## the phones that have joined and calls start_game() when the host is ready
## (see main_screen.gd's lobby overlay). Until then the army is still
## rendered, standing where it spawned, but NOTHING advances - no economy
## tick, miner respawns, movement, combat, desertion or building work - so
## players can join without the clock, resources or map state moving on
## without them.
var game_started: bool = false

## Last sim timestamp (params.w * 256, truncated to 24 bits) at which the
## How often the explosion buffer is read back from the GPU. Must stay well
## under BLAST_TTL (0.4 s) so a charging boid's first visual frame is never
## missed; 0.1 s is 6x the safety margin at 1/6 the readback cost.
const EXPLODE_POLL_INTERVAL := 0.1
var _explode_poll_time := -1.0

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
## "no path assigned" sentinel for the u32 path-hex field (must match the
## shader's NO_PATH and count.glsl's skip test).
const NO_PATH := 0xFFFFFFFF
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
## occupies whatever slots activate_team() claimed for it (its own range,
## independent of every other team's)
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
signal team_activated(team: int)
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
	# num_teams is FIXED at MAX_PLAYER_TEAMS + 1 and is not configurable:
	# all team-indexed buffers are sized for the maximum up front, and a
	# team only becomes real when a phone joins (activate_team). The socket
	# derives its own max_teams from this, so join-driven teams need no
	# editing here or anywhere else.

	# Armies are seeded when a phone JOINS (activate_team), not at startup,
	# so the per-team count only has to fit inside the buffer by itself.
	_dots_per_team = clampi(_dots_per_team, 0, maxi(instance_count - MINER_COUNT, 0))

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
	var init_bytes := _build_state_bytes()
	state_buffers.append(rd.storage_buffer_create(init_bytes.size(), init_bytes))
	state_buffers.append(rd.storage_buffer_create(init_bytes.size(), init_bytes))
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

	# Every team starts broke: the starting pool is granted when a phone
	# joins and its army is actually seeded (see activate_team). The NPC
	# horde slot stays broke forever, as before.
	for t in range(num_teams):
		_team_resources.append(0.0)
		_next_free_slot.append(0)

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


## Builds the initial BoidState bytes for BOTH ping-pong state buffers.
##
## Pure CPU, no RenderingDevice - Tests/economy_spawn.gd drives it directly -
## and it fills ONE preallocated PackedByteArray in place. The version this
## replaces allocated a PackedFloat32Array plus ~6 throwaway
## PackedByteArrays PER BOID (resize + encode + decode_float) just to smuggle
## a u32 into a float slot: at 100k+ slots that was over half a million
## temporary allocations before the first frame, which is what made startup
## crawl. It also had a second full scatter pass whose every field was then
## overwritten by the base spawn - that pass is gone.
##
## Slot layout (std430 BoidState, 64 B per slot - must match sim.glsl):
##   +0  pos.x   +4 pos.y   +8 pos.z   +12 pos.w = owning hex id (u32 bits)
##   +16 vel.x   +20 vel.y  +24 vel.z  +28 vel.w = wall-bump bits (0 here)
##   +32 state (u32)      +36 assigned_path_hex (u32, 0xFFFFFFFF = none)
##   +40 assigned_path_slot (u32)         +44 team (u32)
##   +48 health (u32)     +52 home_hex (s32)          +56/+60 padding
##
## EVERY slot starts dead (zero-filled = health 0): armies are seeded when
## phones join (activate_team), not here, so an empty lobby has no dots at
## all and a 17th phone can never silently overwrite an existing army.
func _build_state_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(instance_count * 64)  # zero-filled: all slots dead
	return bytes


## Chosen spawn hexes per team: team -> Array of sim hex cells (Vector2i).
## Each player picks up to MAX_SPAWN_HEXES hexes on their phone while the
## lobby is open (MainScreen validates them and forwards world positions)
## and their starting army is divided among them. A team that picks nothing
## keeps the corner base its army was seeded into.
var team_spawn_hexes: Dictionary = {}
const MAX_SPAWN_HEXES := 3


## Brings team `team` to life the moment a phone is handed it: grants the
## starting pool and seeds that team's army into its corner base (or its
## lobby-picked hexes, if the picks arrived first - they're re-applied at
## start_game() anyway). Idempotent: a phone reconnecting onto the same
## team id does NOT re-seed or re-fund it. The army size is the configured
## dots-per-team, taken from the SHARED free-slot pool past the seeded
## army - no round-robin id layout anymore, teams are independent ranges.
## Returns false when the team id is out of range or the slot budget is
## exhausted (every multimesh slot already claimed).
func activate_team(team: int) -> bool:
	if team < 0 or team >= num_teams - 1:
		return false
	if _active_teams.has(team):
		return true  # already funded + seeded
	if rd == null:
		return false  # buffers not built yet; seeding is impossible
	var budget := _dots_per_team
	var cap := _army_slot_cap if _army_slot_cap > 0 else instance_count
	var taken := 0
	for other in _active_teams.values():
		taken += int(other.get("dots", 0))
	if taken + budget > cap:
		budget = maxi(cap - taken, 0)
	if budget <= 0:
		push_warning("Sim: no boid slots left for a new team (cap %d, taken %d)." % [cap, taken])
		return false

	# Grant the pool first so upkeep never sees a funded army without money.
	_team_resources[team] = STARTING_RESOURCES + float(budget) * STARTING_RESOURCES_PER_DOT

	# Seed the army into the team's corner base (the same anchors the old
	# startup seeding used). Slots come from the shared cursor so two teams
	# can never overlap.
	_compute_team_bases()
	var rect: Array = team_bases[mini(team, team_bases.size() - 1)]
	var anchors: Array = []
	for c in range(rect[0], rect[2] + 1):
		for r in range(rect[1], rect[3] + 1):
			if c == rect[0] and r == rect[1]:
				continue  # the generator tile, owned by main_screen
			anchors.append({"pos": get_hex_center(c, r), "hex": hex_to_id(c, r)})
	if anchors.is_empty():
		anchors.append({"pos": get_hex_center(rect[0], rect[1]),
				"hex": hex_to_id(rect[0], rect[1])})

	var ids: Array = []
	for i in range(budget):
		var slot := _take_free_slot()
		ids.append(slot)
		var anchor: Dictionary = anchors[i % anchors.size()]
		var center: Vector3 = anchor.pos
		var jitter := mesh_scale * 0.3
		var pos := center + Vector3(
			randf_range(-jitter, jitter), randf_range(0.0, 4.0), randf_range(-jitter, jitter))
		_write_boid_row(slot, _boid_row(pos, team, 1000, int(anchor.hex)))

	_active_teams[team] = {"dots": budget, "ids": ids}
	_team_ids[team] = ids
	print("Sim: team %d activated with %d dots (active teams: %s)." %
			[team, budget, str(_active_teams.keys())])
	team_activated.emit(team)
	resources_changed.emit(_team_resources.duplicate())
	return true


## Is this player team live (a phone holds it)? The economy tick and the
## lobby both filter through this, so inactive teams cost nothing.
func is_team_active(team: int) -> bool:
	return _active_teams.has(team)


## The sim's pool for team `team` (0.0 for never-activated teams).
func get_team_resource(team: int) -> float:
	return float(_team_resources[team]) if team >= 0 and team < _team_resources.size() else 0.0


## Deactivates a team whose phone left: its dots die (health 0 - the GPU
## culls them) and its pool is zeroed, so a late joiner gets a fresh start.
func deactivate_team(team: int) -> void:
	if not _active_teams.has(team):
		return
	for id in _team_ids.get(team, []):
		var data := PackedByteArray()
		data.resize(64)  # health 0 = dead, everything else default
		_write_boid_row(int(id), data)
	_team_resources[team] = 0.0
	_team_ids.erase(team)
	_active_teams.erase(team)
	# A new phone taking this team id must not inherit the previous
	# player's spawn picks - they chose where THEIR army starts.
	team_spawn_hexes.erase(team)
	resources_changed.emit(_team_resources.duplicate())


## Divides `count` dots among `k` groups as evenly as possible: the first
## `count % k` groups take the extra one, so no two groups differ by more
## than 1 dot and the parts always sum back to `count`.
static func split_spawn_counts(count: int, k: int) -> Array:
	var out: Array = []
	if k <= 0:
		return out
	if count <= 0:
		for _i in range(k):
			out.append(0)
		return out
	var base := count / k
	var extra := count % k
	for i in range(k):
		out.append(base + (1 if i < extra else 0))
	return out


## Lays `count` dots out as a phyllotaxis (golden-angle) disc of radius
## `radius` around `center`, so an entire army fits inside one hex without
## piling onto a single point - which matters because the dots' initial
## separation push is what spreads them out once the match starts. Y comes
## from `center` (the caller samples the ground once per hex). Deterministic:
## the same picks always produce the same layout.
static func spawn_positions_in_hex(center: Vector3, radius: float, count: int) -> Array:
	var out: Array = []
	const GOLDEN_ANGLE := 2.399963229728653
	for i in range(count):
		var t := (float(i) + 0.5) / float(maxi(count, 1))
		var ang := GOLDEN_ANGLE * float(i)
		var rad := radius * sqrt(t)
		out.append(Vector3(center.x + cos(ang) * rad, center.y, center.z + sin(ang) * rad))
	return out


## A player's spawn picks, arriving from the lobby. `world_positions` are hex
## centres in world XZ (the same convention set_cell_building uses), so the
## phone's grid coordinates never have to be translated here. Keeps at most
## MAX_SPAWN_HEXES DISTINCT hexes that actually exist on this map, then moves
## that team's already-seeded army into them, divided as evenly as possible.
func set_team_spawn_hexes(team: int, world_positions: Array) -> void:
	if team < 0 or team >= num_teams:
		return
	var cells: Array = []
	for entry in world_positions:
		if cells.size() >= MAX_SPAWN_HEXES:
			break
		# Callers pass XZ world points (a Vector2, like set_cell_building); a
		# Vector3 is accepted too and flattened the same way. Reading `.z` off
		# a Vector2 is a hard error, so the two are handled separately.
		var p := Vector2.ZERO
		if entry is Vector2:
			p = entry
		elif entry is Vector3:
			p = Vector2(entry.x, entry.z)
		else:
			continue
		var cell: Vector2i = world_to_hex(p)
		var id := hex_to_id(cell.x, cell.y)
		# Off the map: ignore the pick rather than strand the army outside
		# the hex layout (which would make every hex lookup on those dots
		# return a garbage cell).
		if id < 0 or id >= hex_total_cells:
			continue
		if cells.has(cell):
			continue
		cells.append(cell)
	if cells.is_empty():
		team_spawn_hexes.erase(team)
	else:
		team_spawn_hexes[team] = cells
	# Relocation needs live buffers (rd) AND a seeded army (_team_ids); both
	# are missing when a phone joins during terrain generation. The picks are
	# STILL STORED - start_game() re-applies them, so an early pick made
	# before the sim was ready used to be silently discarded here.
	if rd != null:
		_relocate_team_army(team)


## The hexes a team's starting army stands in, as sim hex cells. Empty means
## "never picked" - the army is still in its corner base.
func get_team_spawn_hexes(team: int) -> Array:
	var cells: Array = team_spawn_hexes.get(team, [])
	return cells.duplicate()


## Moves team `team`'s live army dots into its chosen spawn hexes, evenly
## divided, with each dot's home hex set to the hex it lands in (so the
## stay-in-your-hex rule keeps the army there until it is ordered out).
## Meant for the lobby, where the sim is not stepping - the relocation is
## then simply what renders, and the player sees their army move to the
## hexes they picked.
func _relocate_team_army(team: int) -> void:
	var hexes: Array = team_spawn_hexes.get(team, [])
	if hexes.is_empty():
		return
	# Teams own their slots outright since the join-driven rework: whatever
	# activate_team() claimed for this team is exactly what moves.
	var ids: Array = _team_ids.get(team, [])
	if ids.is_empty():
		return
	var counts := split_spawn_counts(ids.size(), hexes.size())
	# Dots are placed inside 75% of the hex's circumradius so none of them
	# start past the wall of their own hex.
	var spread := hex_size * mesh_scale * 0.75
	var cursor := 0
	var placed: Array = []
	var checks: Array = []
	for h in range(hexes.size()):
		var cell: Vector2i = hexes[h]
		# get_hex_center returns the terrain height at the centre: one ground
		# sample per hex instead of one per dot.
		var center := get_hex_center(cell.x, cell.y)
		var hex_id := hex_to_id(cell.x, cell.y)
		var first_id := -1
		for p in spawn_positions_in_hex(center, spread, counts[h]):
			if cursor >= ids.size():
				break
			var pos: Vector3 = p
			var boid_id: int = ids[cursor]
			cursor += 1
			if first_id < 0:
				first_id = boid_id
			_write_boid_row(boid_id, _boid_row(pos, team, 1000, hex_id))
		placed.append(counts[h])
		checks.append(_verify_placed(first_id, cell, hex_id, spread))
	print("Sim: team %d spawns in %d hex(es) %s - dots split %s | read back: %s"
			% [team, hexes.size(), str(hexes), str(placed), str(checks)])


## Reads one dot back out of the state buffer and reports whether it really
## landed in the hex it was written to (position inside the hex, owning hex
## id matching). Cheap - one 16-byte readback per hex - and it turns "the
## army moved" from a claim into something the log states outright.
func _verify_placed(boid_id: int, cell: Vector2i, hex_id: int, spread: float) -> String:
	if boid_id < 0 or rd == null:
		return "no dot"
	var row := rd.buffer_get_data(state_buffers[frame_parity], boid_id * 64, 64)
	if row.size() < 64:
		return "unreadable"
	var pos := Vector3(row.decode_float(0), row.decode_float(4), row.decode_float(8))
	var center := get_hex_center(cell.x, cell.y)
	var off_hex := Vector2(pos.x - center.x, pos.z - center.z).length() > spread + 0.01
	if row.decode_u32(12) != hex_id:
		return "(%d,%d) WRONG HEX" % [cell.x, cell.y]
	if off_hex:
		return "(%d,%d) OFF HEX" % [cell.x, cell.y]
	return "(%d,%d) ok" % [cell.x, cell.y]


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


## Opens the lobby gate: sim time starts from ZERO here, because everything
## time-based (path expiry, blast ages, mine lifetimes, desertion pacing) is
## measured against _elapsed_seconds and lobby time is not match time.
## Idempotent - the main screen can call it more than once.
func start_game() -> void:
	if game_started:
		return
	game_started = true
	_elapsed_seconds = 0.0
	_econ_timer = 0.0
	# Safety net: re-apply every team's spawn picks right before the sim takes
	# over, so a pick that arrived while the lobby was open is guaranteed to
	# be in effect no matter what order things happened in.
	for t in team_spawn_hexes.keys():
		_relocate_team_army(int(t))


func _process(delta: float) -> void:
	# Lobby gate: while the host hasn't started the match, keep rendering the
	# (unmoving) army so joining players see the map, but step nothing.
	var simulate := game_started
	if simulate:
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
	if simulate:
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

	# The sim pass itself is what the lobby gate withholds: skipping it leaves
	# every boid exactly where the seed put it. count/prefixsum/scatter still
	# run so the following render pass has valid cell data to draw them from.
	if simulate:
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
	# Both created in _create_buffers and previously never freed: cell_info
	# (~330 KB) and the global path table (num_cells * num_teams * 1368 B,
	# several MB). Harmless at app quit, a real leak on any scene reload.
	if cell_info_rid.is_valid():
		rd.free_rid(cell_info_rid)
	if global_paths_rid.is_valid():
		rd.free_rid(global_paths_rid)
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


## Hex ids are used as OFFSETS into the GPU path table, so they must be
## clamped before use. world_to_hex() does not clamp, and a drawn path can
## start slightly outside the hex layout (the phone extrapolates grid space
## to world space), which produced a NEGATIVE id - and a negative offset
## passes the "offset + size <= total" upper-bound check the path writers
## used, reaching buffer_update() as an invalid parameter.
func _clamp_hex_id(id: int) -> int:
	var total := hex_total_cells if hex_total_cells > 0 else (hex_grid_width * hex_grid_depth)
	return clampi(id, 0, maxi(total - 1, 0))


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
	# THROTTLED: buffer_get_data is a synchronous GPU->CPU readback and stalls
	# the pipe, so doing it every frame cost more than the whole rest of the
	# CPU side. Nothing is lost by polling slower - slot timestamps are only
	# ever compared against the previous read, so any blast that happened
	# since then is still reported, and the poll stays far below the visual's
	# BLAST_TTL so charge-up effects never look late.
	if _elapsed_seconds - _explode_poll_time < EXPLODE_POLL_INTERVAL:
		return
	_explode_poll_time = _elapsed_seconds
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

## Live player teams: team id -> {"dots": int, "ids": Array}. Filled by
## activate_team() as phones join; a team not in here has no army, no pool
## and costs nothing. The NPC horde (num_teams - 1) is never in here.
var _active_teams: Dictionary = {}
## Per-team boid slot lists for the active teams (deactivation kills them).
var _team_ids: Dictionary = {}

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
	# ONE bulk readback of the whole cell_info table for the entire tick.
	# buffer_get_data is a synchronous GPU->CPU stall, and the old code did a
	# separate one per mine per second - a map with a few hundred mines spent
	# hundreds of stalls a second reading four bytes each.
	var cell_words := rd.buffer_get_data(cell_info_rid, 0, table_size * 8)
	var have_cell_words := cell_words.size() >= table_size * 8
	for cell in _active_mines.keys():
		var mine: Dictionary = _active_mines[cell]
		# Live packed building word: team-0 slice, +4 skips the hex_id word.
		# Clamped: the special mine's recorded cell is computed without one.
		var cx := clampi(cell.x, 0, grid_dims.x - 1)
		var cz := clampi(cell.y, 0, grid_dims.z - 1)
		var word_off := (cz * grid_dims.x + cx) * 8 + 4
		var owner := -1
		if have_cell_words:
			var packed_live: int = cell_words.decode_u32(word_off)
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
	# Only ACTIVE teams pay upkeep; a team slice with no phone costs nothing
	# (its econ_stats counter is irrelevant since nothing is seeded there).
	var stats := rd.buffer_get_data(econ_stats_rid, 0, 2 * num_teams * 4)
	if stats.size() >= 2 * num_teams * 4:
		for t in _active_teams.keys():
			var team := int(t)
			upkeep[team] = float(stats.decode_u32(team * 2 * 4)) * UPKEEP_PER_SEC

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
		# Inactive teams (no phone) stay at 0 and never starve - nothing is
		# seeded in their slice anyway. The NPC horde (never in _active_teams)
		# keeps its always-zero pool: deserters live off the land.
		if not _active_teams.has(t):
			continue
		_team_resources[t] += income[t] - upkeep[t]
		# The pool is NOT floored at zero: the balance IS the running debt,
		# which is the whole point of the mechanic - sim.glsl scales the
		# desertion chance by this number, so a mildly broke team leaks units
		# slowly and one drowning in debt collapses, and earning more than
		# upkeep pays the balance back toward zero. Flooring it (the old
		# behavior) capped the deficit at a single tick's shortfall, so every
		# broke team converted at exactly the same constant rate and the
		# phone never showed the negative counter players are meant to watch.
		var balance: float = _team_resources[t]
		if balance < 0.0:
			flags.encode_u32(t * 3 * 4 + 4, 1)  # starve: sim bleeds boid health
			flags.encode_float(t * 3 * 4 + 8, -balance)  # cumulative debt

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
	# EVERY barrack produces from its OWN position - the count used to be
	# multiplied per team and then all dots appeared at one arbitrary
	# barrack, so a second barrack charged full price and produced nothing.
	var sites_by_team := _barrack_sites_by_team()
	for t in _active_teams.keys():
		var team := int(t)
		var sites: Array = sites_by_team[team]
		if sites.is_empty():
			continue  # no barrack: nothing can spawn or revive for this team
		var dead_id := stats.decode_u32((team * 2 + 1) * 4) if stats.size() >= 2 * num_teams * 4 else 0
		if dead_id != 0 and _team_resources[team] >= BARRACK_REVIVE_COST:
			_team_resources[team] -= BARRACK_REVIVE_COST
			_revive_boid(team, dead_id - 1, _nearest_site(sites, _boid_last_position(dead_id - 1)))
		# --- new-dot production, per barrack ---
		for site_world in sites:
			var prod: int = BARRACK_PROD_RATE
			while prod > 0 and _team_resources[team] >= BARRACK_REVIVE_COST \
					and _slot_cursor() < _army_slot_cap:
				_team_resources[team] -= BARRACK_REVIVE_COST
				# Production slots (>= army size) were never alive, so no
				# overlap with the revive pool can happen.
				var prod_slot := _take_free_slot()
				_revive_boid(team, prod_slot, site_world)
				# Bookkeeping: produced dots must join the team's id list, or
				# deactivate_team() leaves them alive on the map as an
				# orphaned army (its pool is gone but the dots persist).
				if _team_ids.has(team):
					_team_ids[team].append(prod_slot)
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
	# Armies are seeded per joining team now (activate_team), so the count
	# only has to fit the multimesh budget by itself, not times team count.
	_dots_per_team = n

## The next unclaimed production slot. Slots come from ONE shared pool -
## every team's watermark starts at the end of the seeded army - so they
## must be handed out from the highest watermark, not per team. Allocating
## per team independently made two producing teams write the SAME slot
## every second: the later buffer_update won, so each team's growth
## silently cancelled the other's (and the slot's team byte flipped).
func _slot_cursor() -> int:
	var cursor := 0
	for t in range(_next_free_slot.size()):
		cursor = maxi(cursor, _next_free_slot[t])
	return cursor


## Claims the next shared production slot and advances every team's
## watermark past it, so the next claim - whichever team makes it - lands
## on a different slot.
func _take_free_slot() -> int:
	var slot := _slot_cursor()
	for t in range(_next_free_slot.size()):
		_next_free_slot[t] = slot + 1
	return slot


## Per-team list of BUILT barrack world positions (XZ). The economy tick
## produces from every one of them, so a team with several barracks grows
## dots at each - the old code always spawned at whichever barrack the
## dictionary happened to yield first.
func _barrack_sites_by_team() -> Array:
	var out: Array = []
	for t in range(num_teams):
		out.append([])
	for cell in _building_sites.keys():
		var packed: int = _building_sites[cell].packed
		if (packed & 0xFF) == 0 and (packed & BUILDING_BUILT_FLAG) != 0:
			var t := clampi((packed >> 8) & 0xFF, 0, num_teams - 1)
			out[t].append(_building_sites[cell].world)
	return out


## The site in `sites` closest to `at` - used so a revived dot comes back
## at the barrack nearest where it died rather than across the map.
func _nearest_site(sites: Array, at: Vector2) -> Vector2:
	var best: Vector2 = sites[0]
	var best_d := best.distance_squared_to(at)
	for i in range(1, sites.size()):
		var d: float = (sites[i] as Vector2).distance_squared_to(at)
		if d < best_d:
			best_d = d
			best = sites[i]
	return best


## Jittered spawn position for a dot produced by the barrack at
## `barrack_world`, resting on the terrain surface. Split out of
## _revive_boid so the ordering that matters - the Z jitter MUST be decided
## before the ground sample - is testable without a RenderingDevice:
## reading the ground height first sampled z = 0, which buried or floated
## every produced/revived dot on hilly terrain.
func _barrack_spawn_position(barrack_world: Vector2) -> Vector3:
	var sx := barrack_world.x + randf_range(-2.0, 2.0)
	var sz := barrack_world.y + randf_range(-2.0, 2.0)
	return Vector3(sx, get_ground_height(sx, sz), sz)


## Revives/creates the dot in slot `boid_id` for `team` at the given
## barrack's world position (XZ). Callers pass the barrack that paid for
## it - see _economy_tick.
func _revive_boid(team: int, boid_id: int, barrack_world: Vector2) -> void:
	if boid_id < 0 or boid_id >= instance_count:
		return
	var spawn := _barrack_spawn_position(barrack_world)
	# Home hex = the hex the barrack stands in, NOT 0: a hardcoded 0 made
	# revived/produced dots walk to hex 0's center after their first fight.
	var spawn_hex := world_to_hex(Vector2(spawn.x, spawn.z))
	_write_boid_row(boid_id, _boid_row(spawn, team, 1000, hex_to_id(spawn_hex.x, spawn_hex.y)))


## One 64-byte BoidState row, built with explicit bit packing. THE single
## place that knows the GPU layout - the seeding, revives and miners all go
## through here, so the three can't drift apart (packing an int straight
## into a float slot once made the special miners spawn as plain dots).
## `pos_w` is scratch as far as the shader is concerned (it only ever reads
## pos.xyz); the CPU keeps the owning hex id there, as the seed does.
func _boid_row(pos: Vector3, team: int, health: int, home_hex_id: int,
		state: int = 0, path_hex: int = NO_PATH, path_slot: int = 0) -> PackedByteArray:
	var row := PackedByteArray()
	row.resize(64)  # std430 BoidState = 16 floats
	var hex := world_to_hex(Vector2(pos.x, pos.z))
	row.encode_float(0, pos.x)
	row.encode_float(4, pos.y)
	row.encode_float(8, pos.z)
	row.encode_u32(12, hex_to_id(hex.x, hex.y))
	# vel (16..28) stays zero
	row.encode_u32(32, state)
	row.encode_u32(36, path_hex)
	row.encode_u32(40, path_slot)
	row.encode_u32(44, team)
	row.encode_u32(48, health)
	row.encode_s32(52, home_hex_id)
	return row


## Copies one prepared BoidState row into BOTH ping-pong state buffers, so
## the slot is consistent no matter which one is read next frame.
func _write_boid_row(boid_id: int, row: PackedByteArray) -> void:
	var byte_offset := boid_id * row.size()
	for sbuf in state_buffers:
		rd.buffer_update(sbuf, byte_offset, row.size(), row)

## CPU-side read of one boid slot's last known world position (XZ). Used to
## pick the revive barrack nearest a dead dot. Falls back to the origin when
## the slot has no usable position yet, which _nearest_site handles fine
## (every distance is then measured from the same point).
func _boid_last_position(boid_id: int) -> Vector2:
	if boid_id < 0 or boid_id >= instance_count or rd == null:
		return Vector2.ZERO
	var data := rd.buffer_get_data(state_buffers[frame_parity], boid_id * 64, 12)
	if data.size() < 12:
		return Vector2.ZERO
	var p := Vector2(data.decode_float(0), data.decode_float(8))
	return p if p.is_finite() else Vector2.ZERO


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
	var ang := TAU * float(boid_id % MINER_COUNT) / float(MINER_COUNT) + 0.45
	var pos_x := _special_mine_world.x + cos(ang) * (hex_size * mesh_scale * 0.55) * ring
	var pos_z := _special_mine_world.y + sin(ang) * (hex_size * mesh_scale * 0.55) * ring
	var pos := Vector3(pos_x, get_ground_height(pos_x, pos_z), pos_z)
	# NPC team (no upkeep/desertion/capture) + the miner state flag, which the
	# sim uses to hex-lock them and keep them gold. Home = the mine's hex.
	_write_boid_row(boid_id, _boid_row(pos, num_teams - 1, MINER_HEALTH,
			_special_mine_hex_id, STATE_MINER_FLAG))

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
	var hex_id := _clamp_hex_id(hex_to_id(col, row))
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
	var hex_id := _clamp_hex_id(hex_to_id(col, row))
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

	var hex_id := _clamp_hex_id(hex_to_id(col, row))
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
	# Tree-optional: headless tests call this outside the scene tree (where
	# get_tree() is null), and the parent scan below still finds the main
	# screen when there is one.
	var ms: Node = null
	if is_inside_tree():
		ms = get_tree().root.get_node_or_null("MainScreen")
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
func get_team_resources() -> Array:
	return _team_resources.duplicate()
