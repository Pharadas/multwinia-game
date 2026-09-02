extends MultiMeshInstance3D
## Place this on a MultiMeshInstance3D with a MultiMesh already set up.
## Creates a flat, 2D (XZ-only) grid of cubes and colors each one by hex
## cell ID so you can visually verify the hex mapping - all cubes that fall
## in the same hex get the SAME random color, so a correct mapping reads as
## clean solid hex-shaped blocks of color.

## Match the main scene's world bounds and cell spacing
const WORLD_MIN := Vector3(-300, 10, -170)
const WORLD_MAX := Vector3(300, 100, 170)
const CELL_SIZE := 5.0

## These must match HexTerrain's own exported values exactly - hex_terrain.gd
## offsets every tile by -total_width/2, -total_depth/2 (see its _layout()/
## get_hex_center()), which depends on grid_width and grid_depth. If this
## script doesn't replicate that same offset, the axial math here solves for
## a same-SIZE grid that's shifted relative to the real one - which shows up
## as a rendered hex being split cleanly into 2-3 debug colors instead of one.
@export var hex_size := 1.0
@export var mesh_scale := 10.0
@export var grid_width := 20
@export var grid_depth := 20

## World-space Y to draw the debug cubes at, since this is a flat 2D
## overlay, not a stack of cubes through the world's full height.
@export var debug_y: float = 12.0

var hex_min_q := 0
var hex_min_r := 0
var hex_width := 0

# Premesh-unit layout offset, computed once in _ready() to exactly mirror
# hex_terrain.gd's _layout(): total_width/total_depth are subtracted (via
# /2) before scaling, so we undo that same subtraction here.
var _total_width := 0.0
var _total_depth := 0.0


func _ready() -> void:
	# Mirror hex_terrain.gd's _layout() so world_to_hex solves against the
	# SAME origin the real terrain tiles are actually placed at.
	var horiz_spacing := hex_size * 1.5
	var vert_spacing := sqrt(3.0) * hex_size
	_total_width = (grid_width - 1) * horiz_spacing
	_total_depth = grid_depth * vert_spacing

	# 2D only: one layer of cells across X/Z, no Y iteration at all.
	var grid_w := ceili((WORLD_MAX.x - WORLD_MIN.x) / CELL_SIZE)
	var grid_d := ceili((WORLD_MAX.z - WORLD_MIN.z) / CELL_SIZE)
	var total := grid_w * grid_d

	# compute hex grid bounds
	var tl := world_to_hex(Vector2(WORLD_MIN.x, WORLD_MIN.z))
	var tr := world_to_hex(Vector2(WORLD_MAX.x, WORLD_MIN.z))
	var bl := world_to_hex(Vector2(WORLD_MIN.x, WORLD_MAX.z))
	var br := world_to_hex(Vector2(WORLD_MAX.x, WORLD_MAX.z))
	hex_min_q = mini(mini(tl.x, tr.x), mini(bl.x, br.x))
	hex_min_r = mini(mini(tl.y, tr.y), mini(bl.y, br.y))
	var hex_max_q := maxi(maxi(tl.x, tr.x), maxi(bl.x, br.x))
	var hex_max_r := maxi(maxi(tl.y, tr.y), maxi(bl.y, br.y))
	hex_width = hex_max_q - hex_min_q + 1
	var hex_height := hex_max_r - hex_min_r + 1
	var total_hexes := hex_width * hex_height
	print("Hex debug: grid %dx%d = %d cubes (2D), hex cells %dx%d = %d" % [
		grid_w, grid_d, total, hex_width, hex_height, total_hexes
	])

	# set up the multimesh
	# IMPORTANT: use_colors (and any other format flag) must be set BEFORE
	# instance_count - Godot allocates the instance buffer's layout the
	# moment instance_count is assigned, using whatever format flags are
	# set at that point.
	multimesh.use_colors = true
	multimesh.instance_count = total

	# Per-instance color is also ignored unless the mesh's material actually
	# reads it. Force one that does, so this works regardless of how the
	# mesh resource was set up in the editor.
	if multimesh.mesh:
		var debug_mat := StandardMaterial3D.new()
		debug_mat.vertex_color_use_as_albedo = true
		debug_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		multimesh.mesh.surface_set_material(0, debug_mat)
	else:
		push_warning("hex_debug.gd: multimesh.mesh is null - assign a mesh in the editor before running.")

	var rng := RandomNumberGenerator.new()
	rng.seed = 42  # deterministic so colors are stable across runs

	# One color per HEX, not per cube - cached here so every cube that maps
	# to the same hex id gets the exact same color instead of rolling a new
	# random hue every cube.
	var hex_colors: Dictionary = {}

	var idx := 0
	for gz in range(grid_d):
		for gx in range(grid_w):
			var pos := Vector3(
				gx * CELL_SIZE + WORLD_MIN.x + CELL_SIZE * 0.5,
				debug_y,
				gz * CELL_SIZE + WORLD_MIN.z + CELL_SIZE * 0.5
			)
			# which hex is this? (hex grid is 2D on XZ)
			var hex := world_to_hex(Vector2(pos.x, pos.z))
			var hex_key := hex # Vector2i hashes fine as a Dictionary key

			var cell_color: Color
			if hex_colors.has(hex_key):
				cell_color = hex_colors[hex_key]
			else:
				cell_color = Color(rng.randf(), rng.randf(), rng.randf())
				hex_colors[hex_key] = cell_color

			multimesh.set_instance_transform(idx, Transform3D(Basis.IDENTITY, pos))
			multimesh.set_instance_color(idx, cell_color)
			idx += 1

	print("Hex debug: placed %d cubes across %d distinct hexes" % [total, hex_colors.size()])


## Flat-top, offset (odd-q) axial conversion - matches hex_terrain.gd's
## actual hex orientation AND origin. World position is first un-scaled and
## un-translated back into the same premesh (u, v) space hex_terrain.gd
## generates tile centers in, so this solves against the exact same grid
## the terrain actually placed, not just one of the same size/shape.
func world_to_hex(world_pos: Vector2) -> Vector2i:
	# Undo mesh_scale, then undo the -total_width/2 / -total_depth/2 offset
	# hex_terrain.gd applies before scaling (see get_hex_center()).
	var u: float = world_pos.x / mesh_scale + _total_width * 0.5
	var v: float = world_pos.y / mesh_scale + _total_depth * 0.5

	var q: float = (2.0 / 3.0 * u) / hex_size
	var r: float = (-1.0 / 3.0 * u + sqrt(3.0) / 3.0 * v) / hex_size
	var s: float = -q - r
	var rq := roundi(q)
	var rr := roundi(r)
	var rs := roundi(s)
	var q_diff = abs(rq - q)
	var r_diff = abs(rr - r)
	var s_diff = abs(rs - s)
	if q_diff > r_diff and q_diff > s_diff:
		rq = -rr - rs
	elif r_diff > s_diff:
		rr = -rq - rs
	# Axial -> offset (odd-q): matches hex_terrain.gd's Vector2i(col, row).
	var col := rq
	var row := rr + (rq - (rq & 1)) / 2
	return Vector2i(col, row)
