extends SceneTree

## Headless test for building grounding: a building must stand on top of the
## terrain under its footprint, never inside it.
##   godot --headless -s res://Tests/building_ground.gd
##
## Uses synthetic heightmaps (random per-texel, plus a sharp ridge) rather than
## the game's noise so the test is deterministic, and compares
## HexBuildingManager._ground_y() against a brute-force maximum sampled 4x
## denser across the same footprint. Also replays the OLD sparse method
## (center + 4 cardinal points) to prove the comparison is not vacuous: on
## this terrain it buries buildings, which is the bug the dense grid fixes.

const IMG_W := 64
const IMG_H := 64
## Image spans IMG_W local units either way, so 1 texel = 1 local unit and a
## hex footprint covers barely one texel - exactly the ratio that made sparse
## sampling miss ridges on the real map.
const MESH_SCALE := 10.0
const HEIGHT_SCALE := 10.0
const HEIGHT_MAX := 40.0  # 4.0 * HEIGHT_SCALE, the sampler's ceiling

var _failures := 0
var _checks := 0


func _initialize() -> void:
	print("=== building grounding ===")
	_test_random_terrain()
	_test_ridge_terrain()
	print("")
	if _failures == 0:
		print("OK - %d checks passed" % _checks)
		quit(0)
	else:
		print("FAILED - %d of %d checks failed" % [_failures, _checks])
		quit(1)


# --- terrain fixtures ---------------------------------------------------------

func _make_manager(img: Image) -> HexBuildingManager:
	var mgr := HexBuildingManager.new()
	mgr.mesh_scale = MESH_SCALE
	mgr.height_scale = HEIGHT_SCALE
	# No heightmap source node: _active_height_scale() falls back to the
	# export above, and _ground_y() uses this image as-is.
	mgr._heightmap_img = img
	return mgr


func _random_terrain(seed_value: int) -> Image:
	var img := Image.create(IMG_W, IMG_H, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for y in IMG_H:
		for x in IMG_W:
			var v := 0.05 + rng.randf() * 0.95
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return img


func _ridge_terrain() -> Image:
	var img := Image.create(IMG_W, IMG_H, false, Image.FORMAT_RGBA8)
	for y in IMG_H:
		for x in IMG_W:
			var v := 0.15
			# A one-texel-wide diagonal ridge: the terrain feature a sparse
			# sample slides past.
			if absi(x - y) <= 0:
				v = 1.0
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return img


# --- sampling helpers ---------------------------------------------------------

## The maximum height over a footprint, sampled far denser than the manager
## does. This is the ground truth the building must clear.
func _brute_max(img: Image, world_x: float, world_z: float, radius: float, steps: int = 41) -> float:
	var inv := 1.0 / MESH_SCALE
	var best := -INF
	for ix in range(steps):
		var ox := (float(ix) / float(steps - 1) * 2.0 - 1.0) * radius
		for iz in range(steps):
			var oz := (float(iz) / float(steps - 1) * 2.0 - 1.0) * radius
			best = maxf(best, HexTile._sample_height(img, img.get_width(), img.get_height(),
					(world_x + ox) * inv, (world_z + oz) * inv, HEIGHT_SCALE))
	return best


## The OLD grounding: center + four cardinal points at the footprint radius.
## Kept here only as the failing baseline the dense grid replaced.
func _legacy_max(img: Image, world_x: float, world_z: float, radius: float) -> float:
	var inv := 1.0 / MESH_SCALE
	var best := -INF
	for off in [Vector2.ZERO, Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		best = maxf(best, HexTile._sample_height(img, img.get_width(), img.get_height(),
				(world_x + off.x * radius) * inv, (world_z + off.y * radius) * inv, HEIGHT_SCALE))
	return best


# --- cases --------------------------------------------------------------------

func _test_random_terrain() -> void:
	var mgr := _make_manager(_random_terrain(12345))
	var radius := mgr._footprint_radius(HexBuildingManager.BUILDING_BARRACK)
	_check("barrack footprint radius", "%.2f" % radius, "4.65")

	var worst_shortfall := 0.0
	var legacy_worst := 0.0
	var legacy_buried := 0
	var positions := 0
	# Sweep fractional positions so the footprint straddles texel boundaries in
	# every way it can on a real map.
	for i in range(24):
		for j in range(24):
			var wx := -200.0 + float(i) * 17.3
			var wz := -120.0 + float(j) * 11.7
			var truth := _brute_max(mgr._heightmap_img, wx, wz, radius)
			var placed := mgr._ground_y(wx, wz, radius, 0.0) - radius * HexBuildingManager.GROUND_LIFT
			worst_shortfall = maxf(worst_shortfall, truth - placed)
			var legacy := _legacy_max(mgr._heightmap_img, wx, wz, radius)
			legacy_worst = maxf(legacy_worst, truth - legacy)
			if truth - legacy > 1.0:
				legacy_buried += 1
			positions += 1

	_check("positions swept", str(positions), "576")
	# The placed base must clear the real maximum: a shortfall means the
	# building is standing inside the terrain.
	_check("never buried (worst shortfall <= 0.01)", "%.4f" % worst_shortfall,
			"<= 0.0100")
	# ...and the sparse method really was the problem, or this test is vacuous.
	_check("sparse method buries buildings by >1.0", str(legacy_buried > 0), "true")
	print("  INFO legacy sparse worst shortfall: %.2f units (of %.0f max height)"
			% [legacy_worst, HEIGHT_MAX])
	print("  INFO dense grid worst shortfall:    %.4f units" % worst_shortfall)
	mgr.free()


func _test_ridge_terrain() -> void:
	var mgr := _make_manager(_ridge_terrain())
	var radius := mgr._footprint_radius(HexBuildingManager.BUILDING_BARRACK)
	# Put a ridge texel inside a footprint that the cardinal samples miss: the
	# ridge runs along x == y, so offset the center off the diagonal.
	var buried_by_legacy := 0
	var worst := 0.0
	for i in range(40):
		var wx := float(i) * 3.1
		var wz := 0.0
		var truth := _brute_max(mgr._heightmap_img, wx, wz, radius)
		var placed := mgr._ground_y(wx, wz, radius, 0.0) - radius * HexBuildingManager.GROUND_LIFT
		worst = maxf(worst, truth - placed)
		if truth - _legacy_max(mgr._heightmap_img, wx, wz, radius) > 1.0:
			buried_by_legacy += 1
	_check("ridge never buried", str(worst <= 0.01), "true")
	_check("ridge catches the sparse method", str(buried_by_legacy > 0), "true")
	mgr.free()


# --- harness -----------------------------------------------------------------

func _check(label: String, got: String, want: String) -> void:
	_checks += 1
	var ok := true
	if want.begins_with("<="):
		ok = got.to_float() <= want.substr(2).to_float()
	else:
		ok = got == want
	if ok:
		print("  PASS %-40s %s" % [label, got])
		return
	_failures += 1
	print("  FAIL %-40s got \"%s\" want \"%s\"" % [label, got, want])
