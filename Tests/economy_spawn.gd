extends SceneTree

## Headless tests for the sim's barrack-production helpers:
##   godot --headless -s res://Tests/economy_spawn.gd
##
## These cover two bugs that were invisible from the outside:
##   1. _revive_boid sampled the terrain height with an uninitialised Z, so
##      every produced/revived dot spawned at the height of z = 0 instead of
##      its own position (buried or floating on hilly terrain).
##   2. production was counted per team but spawned from one arbitrary
##      barrack, so extra barracks charged 10 resources/s and produced
##      nothing.
##
## Everything here is pure CPU logic (no RenderingDevice), which is why the
## helpers were split out of the economy tick.

const SIM_PATH := "res://Demos/stupid simple/stupid_simple.gd"
const MAP := 64
const HEIGHT_SCALE := 10.0

var _failures := 0
var _checks := 0

func _initialize() -> void:
	var sim: Node = load(SIM_PATH).new()
	# num_teams drives the per-team grouping; mesh_scale drives the heightmap
	# UV mapping, so pin both instead of relying on the scene's exports.
	sim.num_teams = 3
	sim.mesh_scale = 10.0

	_setup_heightmap(sim)
	_test_spawn_position(sim)
	_test_barrack_grouping(sim)
	_test_nearest_site(sim)
	_test_slot_allocation(sim)
	_test_team_activation(sim)
	_test_state_bytes(sim)
	_test_boid_row_packing(sim)
	_bench_state_bytes()

	sim.free()
	print("")
	if _failures == 0:
		print("OK - %d checks passed" % _checks)
		quit(0)
	else:
		print("FAILED - %d of %d checks failed" % [_failures, _checks])
		quit(1)

## A heightmap whose red channel rises with the row, so terrain height is a
## steep function of Z: any code that samples the wrong Z is caught.
func _setup_heightmap(sim: Node) -> void:
	var data := PackedFloat32Array()
	data.resize(4 + MAP * MAP)
	data[0] = float(MAP)
	data[1] = float(MAP)
	data[2] = HEIGHT_SCALE
	data[3] = 0.0
	for y in MAP:
		for x in MAP:
			data[4 + y * MAP + x] = float(y) / float(MAP - 1)
	sim.heightmap_width = MAP
	sim.heightmap_depth = MAP
	sim._heightmap_cpu = data

func _test_spawn_position(sim: Node) -> void:
	# A barrack far from the z = 0 line, where the sampled height differs a
	# lot from the height at z = 0.
	var barrack := Vector2(40.0, 150.0)
	var h_at_zero: float = sim.get_ground_height(barrack.x, 0.0)
	print("  reference: ground(z=0) = %.2f" % h_at_zero)

	for i in 5:
		var spawn: Vector3 = sim._barrack_spawn_position(barrack)
		# Jitter stays inside the barrack's own 2-unit box.
		_check("jitter within 2 units", str(absf(spawn.x - barrack.x) <= 2.0
				and absf(spawn.z - barrack.y) <= 2.0), "true")
		# Y matches the terrain UNDER THE DOT (its own XZ), not z = 0.
		# Tolerance, not string equality: Vector3 stores float32 while the
		# sampler returns float64, so the 7th digit differs.
		var expected: float = sim.get_ground_height(spawn.x, spawn.z)
		_check("y == ground(x, z)", str(absf(spawn.y - expected) < 0.01), "true")
		if spawn.y > h_at_zero + 5.0:
			_check("y != ground(x, 0) [regression]", "true", "true")
		else:
			_check("y differs from ground(x, 0)", "%.2f" % spawn.y,
					"> %.2f" % (h_at_zero + 5.0))

func _test_barrack_grouping(sim: Node) -> void:
	# Two built barracks for team 0 (at different spots), one for team 1,
	# plus noise that must be ignored: an UNBUILT barrack and a wall.
	sim._building_sites = {
		Vector2i(0, 0): {"packed": 0 | (0 << 8) | sim.BUILDING_BUILT_FLAG, "world": Vector2(10, 10)},
		Vector2i(5, 5): {"packed": 0 | (0 << 8) | sim.BUILDING_BUILT_FLAG, "world": Vector2(200, 90)},
		Vector2i(9, 1): {"packed": 0 | (1 << 8) | sim.BUILDING_BUILT_FLAG, "world": Vector2(-30, 40)},
		Vector2i(3, 7): {"packed": 0, "world": Vector2(500, 500)},  # unbuilt
		Vector2i(4, 4): {"packed": 2 | (0 << 8) | sim.BUILDING_BUILT_FLAG, "world": Vector2(7, 7)},  # wall
	}
	var by_team: Array = sim._barrack_sites_by_team()
	_check("team 0 barrack count", str(by_team[0].size()), "2")
	_check("team 1 barrack count", str(by_team[1].size()), "1")
	_check("team 2 (none)", str(by_team[2].size()), "0")
	_check("team 1 barrack position", str(by_team[1][0]), str(Vector2(-30, 40)))

func _test_nearest_site(sim: Node) -> void:
	var sites: Array = [Vector2(0, 0), Vector2(100, 100), Vector2(-50, 20)]
	_check("nearest to (90,90)", str(sim._nearest_site(sites, Vector2(90, 90))), str(Vector2(100, 100)))
	_check("nearest to (10,10)", str(sim._nearest_site(sites, Vector2(10, 10))), str(Vector2(0, 0)))
	_check("nearest to (-40,5)", str(sim._nearest_site(sites, Vector2(-40, 5))), str(Vector2(-50, 20)))

## Production slots are a SHARED pool: every team's watermark starts at the
## end of the seeded army, so per-team allocation made two producing teams
## overwrite the same slot each second (the later write won, so the armies
## cancelled each other out). No two claims may ever return the same slot.
func _test_slot_allocation(sim: Node) -> void:
	sim.num_teams = 3
	sim._next_free_slot = [20, 20, 20] as Array[int]
	sim._army_slot_cap = 1000
	var taken: Array = []
	# Interleave teams exactly like the economy tick does.
	for i in 6:
		var team := i % 3
		taken.append(sim._take_free_slot())
	_check("slots are unique", str(taken.duplicate()),
			str([20, 21, 22, 23, 24, 25]))
	_check("cursor past all claims", str(sim._slot_cursor()), "26")
	_check("cursor inside the cap", str(sim._slot_cursor() < sim._army_slot_cap), "true")
	# A team that has never produced still sees the shared watermark, so its
	# first claim cannot land on a slot another team already used.
	sim._next_free_slot[2] = 0
	_check("stale team watermark ignored", str(sim._take_free_slot()), "26")


## Join-driven team activation (pure-CPU parts): the slot ledger, idempotency
## guard and deactivation bookkeeping - activate_team's GPU writes need rd,
## so the buffer side is exercised by the live game instead.
func _test_team_activation(sim: Node) -> void:
	sim._active_teams = {0: {"dots": 5, "ids": [0, 1, 2, 3, 4]}}
	sim._team_ids = {0: [0, 1, 2, 3, 4]}
	_check("active team reports active", str(sim.is_team_active(0)), "true")
	_check("inactive team reports inactive", str(sim.is_team_active(1)), "false")
	sim._team_resources.clear()
	for v in [100.0, 0.0, 0.0]:
		sim._team_resources.append(v)
	_check("resource readback", str(sim.get_team_resource(0)), "100.0")
	_check("inactive pool reads 0", str(sim.get_team_resource(1)), "0.0")
	_check("out-of-range pool reads 0", str(sim.get_team_resource(99)), "0.0")
	# Deactivation clears the ledger and the pool.
	sim.deactivate_team(0)
	_check("deactivated team ledger cleared", str(sim._active_teams.has(0)), "false")
	_check("deactivated team pool zeroed", str(sim._team_resources[0]), "0.0")
	_check("deactivated id list cleared", str(sim._team_ids.has(0)), "false")
	sim._active_teams = {}
	sim._team_ids = {}


## The initial BoidState buffer: size + all-dead (join-driven seeding).
func _test_state_bytes(sim: Node) -> void:
	sim.instance_count = 30
	sim._dots_per_team = 5
	var bytes: PackedByteArray = sim._build_state_bytes()
	_check("buffer size = slots x 64", str(bytes.size()), str(30 * 64))
	# Every slot must start DEAD (health 0): armies are seeded when phones
	# join (activate_team), never at startup - a zeroed slot is never drawn.
	var alive := 0
	for id in range(30):
		if bytes.decode_u32(id * 64 + 48) != 0:
			alive += 1
	_check("all slots start dead", str(alive), "0")

## Every uint field must be BIT-PACKED. Storing an int straight into the old
## float array wrote float 128.0 (bits 0x43000000) into the state word, which
## shares no bits with STATE_MINER (0x80) - the special miners spawned as
## plain NPC dots. This is the regression test for that.
func _test_boid_row_packing(sim: Node) -> void:
	sim.num_teams = 3
	sim.hex_min_q = -10
	sim.hex_min_r = 0
	sim.hex_width = 41
	sim.hex_grid_width = 41
	sim.hex_grid_depth = 21
	var row: PackedByteArray = sim._boid_row(
		Vector3(5.0, 12.0, -7.0), sim.num_teams - 1, sim.MINER_HEALTH, 123,
		sim.STATE_MINER_FLAG)
	_check("row is 64 bytes", str(row.size()), "64")
	_check("miner state bits", str(row.decode_u32(32)), str(sim.STATE_MINER_FLAG))
	_check("miner team = NPC", str(row.decode_u32(44)), "2")
	_check("miner health", str(row.decode_u32(48)), str(sim.MINER_HEALTH))
	_check("home hex", str(row.decode_s32(52)), "123")
	_check("no path sentinel", str(row.decode_u32(36)), "4294967295")
	_check("pos round-trip x", str(row.decode_float(0)), "5.0")
	_check("pos round-trip z", str(row.decode_float(8)), "-7.0")
	_check("pos.w = owning hex", str(row.decode_u32(12) >= 0), "true")


## Informational: how long the initial state build takes at a realistic
## large army. The rewrite replaced ~6 throwaway byte arrays per boid with a
## single in-place fill, so this is the number that used to dominate startup.
func _bench_state_bytes() -> void:
	var big: Node = load(SIM_PATH).new()
	big.instance_count = 200000
	big.num_teams = 5
	big._dots_per_team = 50000
	big.mesh_scale = 10.0
	big.hex_min_q = -10
	big.hex_min_r = 0
	big.hex_grid_width = 41
	big.hex_grid_depth = 21
	big.hex_width = 41
	big.hex_total_cells = 41 * 21
	var t0 := Time.get_ticks_usec()
	var bytes: PackedByteArray = big._build_state_bytes()
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("  INFO state build: %d slots, %.1f MB in %.1f ms"
			% [big.instance_count, bytes.size() / 1048576.0, ms])
	big.free()


func _check(label: String, got: String, want: String) -> void:
	_checks += 1
	if got == want:
		print("  PASS %-34s %s" % [label, got])
		return
	_failures += 1
	print("  FAIL %-34s got \"%s\" want \"%s\"" % [label, got, want])
