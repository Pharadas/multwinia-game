@tool
extends StaticBody3D
class_name HexTile

## A single hex terrain sector: builds its own tessellated mesh + trimesh
## collision from heightmap samples, and reports clicks on itself.
##
## Lives in its own scene (e.g. res://MainScreen/HexTile.tscn), root node
## StaticBody3D with this script attached. A spawner (see hex_terrain.gd)
## instances this scene once per grid cell and calls build() on it.
##
## --- Perf notes -------------------------------------------------------
## The selection glow used to run unconditionally every frame for every
## tile via _process():
##  - Unselected tiles called surface_set_material() every single frame
##    forever, even though the material was already correct and nothing
##    had changed.
##  - Selected tiles allocated a brand new ORMMaterial3D AND rebound it to
##    the mesh surface every frame, instead of just updating the color/
##    emission on an existing one.
## Both are expensive render-state churn multiplied across the whole grid,
## every frame, regardless of whether anything is actually happening.
## Now: select_by_team()/deselect_by_team() toggle set_process() so _process
## only runs at all while at least one team has the tile selected, and the
## glow material is created/bound ONCE per tile (cached in _glow_material)
## and then just has its properties mutated in place each pulse frame -
## surface_set_material() itself is only called on the actual selected/
## unselected transition, not continuously.

signal hex_clicked(col: int, row: int, world_position: Vector3)

var col: int = 0
var row: int = 0
var color: Color = Color.WHITE

## Per-team routed roads, keyed by an order-independent road key (see
## main_screen.gd's _road_key()). Each entry is the FULL route - an Array of
## HexTile nodes from THIS tile through every hex of the road to its end.
## Routes are stored whole on the tile they START on and are never written
## hop-by-hop onto the hexes they pass through: a darwinian that steps on a
## tile with a route picks up the entire path, and no other tile knows about
## it.
var pointing_to: Array = [{}, {}, {}, {}, {}, {}]

## One glow color per team, indexed the same way as pointing_to.
const TEAM_GLOW_COLORS: Array[Color] = [
	Color.RED,
	Color.GREEN,
	Color.BLUE,
	Color.YELLOW,
	Color.PURPLE,
	Color.CYAN
]

var t := 0.5
var contains_generator = false
var generator_instance

## Per-team selection state - a tile can be selected by any subset of teams
## at once, so this replaced the old single `selected` bool.
var selected_by_team: Array[bool] = [false, false, false, false, false, false]

## The tile's original (non-glowing) material, captured once at build time
## so it can be restored once every team deselects the tile.
var _base_material: Material = null

## The glow material - created once, lazily, then reused/mutated for the
## life of the tile instead of being reallocated every frame.
var _glow_material: ORMMaterial3D = null

## Cached at build() time instead of doing get_child(0) lookups repeatedly.
var _mesh_instance: MeshInstance3D = null

## Optional fast-build context, injected by the terrain spawner before
## build(): when set, the tile's mesh is produced by HexMeshBuilder (raw
## packed arrays, indexed) instead of the legacy SurfaceTool path - same
## output, a fraction of the build time. See HexMeshBuilder's header.
var _builder: HexMeshBuilder = null

var generator = preload("res://WorldObjects/Generator.tscn")


## Injects the shared fast mesh builder (one per terrain generation, see
## main_screen.gd's generate_terrain). Call before build(); when absent,
## build() falls back to the legacy SurfaceTool path.
func set_fast_builder(builder: HexMeshBuilder) -> void:
	_builder = builder

## Whether this tile is a solid wall: it covers the whole hexagon and
## nothing can pass through it. Set by the terrain spawner (see
## main_screen.gd's wall_tile_chance) BEFORE build() runs.
var is_wall: bool = false

## How tall a wall tile rises above the terrain, in world units.
@export var wall_height: float = 5.0

## Set by the terrain spawner: this tile must spawn exactly one generator
## (used for team corner bases).
var force_generator := false

## Set by the terrain spawner: this tile must NOT roll a random generator
## (used for team corner bases - the forced one is enough).
var no_random_generator := false

func _process(_delta: float) -> void:
	# Only ever running while is_selected() is true - see
	# select_by_team()/deselect_by_team(), which toggle set_process().
	t += 0.005
	if t > 0.7:
		t = 0.5
	on_tile_selected()


## Builds the mesh/collision for this tile in place.
## `vertex_cache` should be the SAME Dictionary shared across every tile in a
## grid, so neighboring hexes land on bit-identical shared-edge vertices and
## you don't get seams between separate hex meshes.
func build(
	p_col: int,
	p_row: int,
	img: Image,
	width: int,
	depth: int,
	center_u: float,
	center_v: float,
	hex_size: float,
	hex_detail: int,
	height_scale: float,
	mesh_scale: float,
	color_param: Color,
	mat: Material,
	vertex_cache: Dictionary
) -> void:
	col = p_col
	row = p_row
	color = color_param
	name = "Hex_%d_%d" % [col, row]
	input_ray_pickable = true
	set_collision_layer_value(2, true)
	set_collision_mask_value(1, true)

	# Move the node itself to the hex's center (X/Z only - height varies
	# across the mesh, so there's no single "correct" Y for the origin).
	# The mesh below is built in LOCAL space relative to this same center,
	# so the two line up and global_position now reports real coordinates
	# instead of staying at (0,0,0).
	position = Vector3(center_u * mesh_scale, 0.0, center_v * mesh_scale)

	# Fast path (default when the spawner injected a builder): raw packed
	# arrays with an index buffer - same tessellation, heights, winding and
	# smoothing-group normals as the legacy path below, at a fraction of the
	# cost. generate_tangents() is dropped: hex_sector.gdshader never reads
	# tangents, and it was a large chunk of the old build time.
	var hex_mesh: ArrayMesh
	if _builder != null:
		_builder.tile_color = color_param
		hex_mesh = _builder.build(center_u, center_v, hex_size, hex_detail, mesh_scale, mat)
	else:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

		var corner_uv: Array[Vector2] = []
		for i in range(6):
			var angle := deg_to_rad(60 * i)
			corner_uv.append(Vector2(center_u + hex_size * cos(angle), center_v + hex_size * sin(angle)))

		for i in range(6):
			_add_wedge(
				st, img, width, depth, vertex_cache,
				Vector2(center_u, center_v), corner_uv[i], corner_uv[(i + 1) % 6],
				color_param, hex_detail, height_scale, mesh_scale
			)

		st.generate_normals()
		st.generate_tangents()
		hex_mesh = st.commit()
		if mat:
			hex_mesh.surface_set_material(0, mat)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "MeshInstance3D"
	mesh_instance.mesh = hex_mesh
	add_child(mesh_instance)
	_mesh_instance = mesh_instance

	# Remember the material this tile started with so we can restore it
	# once no team has the tile selected anymore.
	_base_material = mat

	var collision := CollisionShape3D.new()
	collision.shape = hex_mesh.create_trimesh_shape()
	add_child(collision)

	if not input_event.is_connected(_on_input_event):
		input_event.connect(_on_input_event)

	# A wall tile is solid - don't also drop a generator inside it, since
	# nothing could ever reach it. Team base tiles either force exactly one
	# generator (force_generator) or suppress the random roll
	# (no_random_generator).
	if not is_wall and (force_generator or (not no_random_generator and randf() < 0.1)):
		var gen = generator.instantiate()
		contains_generator = true
		generator_instance = gen
		add_child(gen)

	if is_wall:
		# Anchor the wall prism to THIS tile's terrain surface - the mesh
		# vertices are built from sampled heights in local space (origin at
		# y=0), so the surface height at the tile center is exactly the
		# sampled height. Pinning the prism to y=0 instead left walls buried
		# on hills and too short to block body-height lasers there.
		var surface_y := _sample_height(img, width, depth, center_u, center_v, height_scale)
		_build_wall(hex_size * mesh_scale, surface_y)

	# Nobody has this tile selected yet - don't run _process() at all until
	# select_by_team() actually turns it on. Without this, every tile in
	# the grid runs _process() from the moment it's built, forever, doing
	# nothing but wasted work for tiles that are never selected.
	set_process(false)


## Turns this tile into a solid wall: a hexagonal prism (collision + mesh)
## covering the whole tile footprint, so nothing can walk onto or through
## the tile. Tagged "wall" so a darwinian treats contact with it as a hard
## stop (see _stop_at_wall() in DarwinianLogic.gd).
##
## `radius` is the hexagon's circumradius in local/world units, matching
## the tile's own terrain mesh so the wall exactly covers the tile, and
## `surface_y` is this tile's terrain height at its center (in local space,
## same space the mesh vertices use) so the prism always rises out of its
## own ground instead of floating or burying itself on hills.
func _build_wall(radius: float, surface_y: float) -> void:
	add_to_group("wall")

	# The prism spans from just below this tile's terrain surface up to
	# wall_height above it - a solid column nothing can walk through and
	# no body-height laser can pass over.
	var bottom := surface_y - 2.0
	var top := surface_y + wall_height

	# Hexagonal-prism collision: one ring of 6 vertices at the bottom and
	# one at the top, same radius/angles as the tile's own mesh so the wall
	# blocks the entire tile, from every side.
	var points := PackedVector3Array()
	for i in range(6):
		var angle := TAU * float(i) / 6.0
		var x := cos(angle) * radius
		var z := sin(angle) * radius
		points.append(Vector3(x, bottom, z))
		points.append(Vector3(x, top, z))
	var wall_shape := ConvexPolygonShape3D.new()
	wall_shape.points = points
	var wall_collision := CollisionShape3D.new()
	wall_collision.shape = wall_shape
	wall_collision.rotate_y(deg_to_rad(90.0))
	add_child(wall_collision)

	# Same silhouette for the visible mesh: a cylinder with 6 radial
	# segments is exactly a hexagonal prism. The mesh is centered on the
	# node it's attached to, so shift it up to sit between bottom and top.
	var prism := CylinderMesh.new()
	prism.top_radius = radius
	prism.bottom_radius = radius
	prism.height = top - bottom
	prism.radial_segments = 6
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.35, 0.32, 0.3)
	prism.material = wall_mat
	var wall_mesh := MeshInstance3D.new()
	wall_mesh.name = "WallMesh"
	wall_mesh.mesh = prism
	wall_mesh.position.y = (top + bottom) / 2.0
	wall_mesh.rotate_y(deg_to_rad(90.0))
	add_child(wall_mesh)


func _on_input_event(_camera: Node, event: InputEvent, click_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		hex_clicked.emit(col, row, click_position)
		print("gaming!!!")


## Marks this tile as selected by `team`. Safe to call for a team that
## already has it selected. Other teams' selections are untouched, so a
## tile can be lit up by several teams at once.
func select_by_team(team: int) -> void:
	var was_selected := is_selected()
	selected_by_team[team] = true
	if not was_selected:
		# Transitioning from "nobody has this" to "somebody has this" -
		# the only point where the mesh's material actually needs to
		# change, and the only point _process() needs to start running.
		_show_glow_material()
		set_process(true)


## Clears `team`'s selection of this tile. The tile keeps glowing as long as
## at least one other team still has it selected.
func deselect_by_team(team: int) -> void:
	if team >= 0 and team < selected_by_team.size():
		selected_by_team[team] = false
	if not is_selected():
		# Transitioning from "somebody has this" to "nobody has this" -
		# restore the original material once, and stop running _process()
		# entirely until it's selected again.
		_restore_base_material()
		set_process(false)


## Whether any team currently has this tile selected.
func is_selected() -> bool:
	for s in selected_by_team:
		if s:
			return true
	return false


## Binds the (lazily-created, then reused) glow material to the mesh -
## called once on the unselected->selected transition, never per-frame.
func _show_glow_material() -> void:
	if not _mesh_instance:
		return
	if not _glow_material:
		_glow_material = ORMMaterial3D.new()
		_glow_material.emission_enabled = true
	_mesh_instance.mesh.surface_set_material(0, _glow_material)


## Restores the tile's original material - called once on the
## selected->unselected transition, never per-frame.
func _restore_base_material() -> void:
	if _base_material != null and _mesh_instance:
		_mesh_instance.mesh.surface_set_material(0, _base_material)
	t = 0.0


## Called by HexGrid2D (the 2D mirror) when this tile's 2D cell is clicked
## (same-process terrain_path fallback only), AND continuously by
## _process() every pulse frame while selected. Both just need "make the
## glow material match the current selection state right now" - the
## material itself is only allocated/bound lazily via _show_glow_material(),
## never here, so repeat calls are cheap (just a few float writes).
##
## Glow behavior: every team that currently has this tile selected
## contributes its own color, blended together, and each additional team
## multiplies the overall glow strength - so a tile two teams both want
## glows noticeably brighter (and more contested-looking) than one only a
## single team has picked.
func on_tile_selected() -> void:
	if not _glow_material:
		# External call (e.g. a same-process 2D click) can arrive before
		# any select_by_team() has run - stay self-sufficient rather than
		# assuming the normal select/deselect path already set this up.
		_show_glow_material()
	if not _glow_material:
		return

	var blended_color := Color(0, 0, 0)
	var selecting_teams := 0
	for team in range(selected_by_team.size()):
		if selected_by_team[team]:
			blended_color += TEAM_GLOW_COLORS[team]
			selecting_teams += 1

	if selecting_teams == 0:
		return

	blended_color /= selecting_teams

	_glow_material.albedo_color = blended_color * t
	_glow_material.emission = blended_color
	# Multiplies with team count: 1 team pulses up to 1x, 2 teams up to 2x,
	# and so on, so overlapping claims visibly stack rather than just
	# re-tinting the same brightness.
	_glow_material.emission_energy_multiplier = t * selecting_teams


## Static so the spawner can reuse it (e.g. for get_hex_center) without
## needing a live HexTile instance.
static func _sample_height(img: Image, width: int, depth: int, u: float, v: float, height_scale: float) -> float:
	var fx: float = clamp(u + width / 2.0, 0.0, width - 1.0)
	var fz: float = clamp(v + depth / 2.0, 0.0, depth - 1.0)

	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var x1 := mini(x0 + 1, width - 1)
	var z1 := mini(z0 + 1, depth - 1)
	var tx := fx - x0
	var tz := fz - z0

	var c00 := img.get_pixel(x0, z0).r
	var c10 := img.get_pixel(x1, z0).r
	var c01 := img.get_pixel(x0, z1).r
	var c11 := img.get_pixel(x1, z1).r

	var top = lerp(c00, c10, tx)
	var bottom = lerp(c01, c11, tx)
	var r = lerp(top, bottom, tz)

	return r * 4.0 * height_scale


static func _get_vertex(cache: Dictionary, img: Image, width: int, depth: int, u: float, v: float, height_scale: float, mesh_scale: float) -> Vector3:
	# Quantize the key so two hexagons that arrive at the "same" corner via
	# different float arithmetic still hit the same cache entry.
	var key := "%d_%d" % [roundi(u * 100.0), roundi(v * 100.0)]
	if cache.has(key):
		return cache[key]
	var y := _sample_height(img, width, depth, u, v, height_scale)
	var vert := Vector3(u * mesh_scale, y, v * mesh_scale)
	cache[key] = vert
	return vert


## Tessellates the triangle (center, a, b) into hex_detail^2 small triangles
## using barycentric subdivision, sampling real height at every point.
static func _add_wedge(
	st: SurfaceTool, img: Image, width: int, depth: int, vertex_cache: Dictionary,
	center_uv: Vector2, a_uv: Vector2, b_uv: Vector2, color: Color,
	hex_detail: int, height_scale: float, mesh_scale: float
) -> void:
	# _get_vertex caches/returns GLOBAL positions (so two hexes sharing an
	# edge agree on it bit-for-bit). This tile's node now sits at its own
	# center though, so every vertex fed to the mesh has to be re-expressed
	# relative to that center - otherwise the mesh renders twice-offset.
	var local_origin := Vector3(center_uv.x * mesh_scale, 0.0, center_uv.y * mesh_scale)

	var n := hex_detail
	var grid: Array = []
	for row_i in range(n + 1):
		var row_points: Array[Vector3] = []
		for col_i in range(n + 1 - row_i):
			var w_center: float = float(n - row_i - col_i) / float(n)
			var w_a: float = float(row_i) / float(n)
			var w_b: float = float(col_i) / float(n)
			var pu: float = center_uv.x * w_center + a_uv.x * w_a + b_uv.x * w_b
			var pv: float = center_uv.y * w_center + a_uv.y * w_a + b_uv.y * w_b
			var global_vert := _get_vertex(vertex_cache, img, width, depth, pu, pv, height_scale, mesh_scale)
			row_points.append(global_vert - local_origin)
		grid.append(row_points)

	for row_i in range(n):
		var this_row: Array[Vector3] = grid[row_i]
		var next_row: Array[Vector3] = grid[row_i + 1]
		for col_i in range(n - row_i):
			_add_tri(st, color, this_row[col_i], this_row[col_i + 1], next_row[col_i])
			if col_i < n - row_i - 1:
				_add_tri(st, color, this_row[col_i + 1], next_row[col_i + 1], next_row[col_i])


static func _add_tri(st: SurfaceTool, color: Color, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	st.set_color(color)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(p1)
	st.set_color(color)
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(p3)
	st.set_color(color)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(p2)


## Returns the first stored route for `team` that starts on THIS tile - the
## full chain of HexTile nodes from this tile through the road to its end,
## exactly as it was stored (see main_screen.gd's set_new_road()). Paths live
## whole on their starting hex; intermediate hexes have no entry of their
## own, so a darwinian that steps on a mid-path tile won't find anything
## here. (Named get_route, not get_path - the latter is a built-in Node
## method and can't be overridden.)
func get_route(team: int) -> Array:
	var roads: Dictionary = pointing_to[team]
	if roads.is_empty():
		return []
	var keys = roads.keys()
	return roads[keys[0]]

func should_move(team_number: int):
	return len(pointing_to[team_number]) > 0
