extends Node3D
class_name HexBuildingManager

## Spawns 3D building meshes (barrack / mine / wall) on whole hex cells when a
## phone drags one onto a hex in the hex detail view. Attach as a child of the
## terrain (or anywhere in the main scene) and call place_building().
##
## GRANULARITY: whole parent hexes only. There are no sub-hex coordinates
## anymore - a building occupies the entire hex it is dropped on, is centered
## at that hex's center, and each hex holds at most one building (re-dropping
## replaces it).
##
## GROUNDING: every building is snapped to the terrain heightmap directly
## (HexTile._sample_height - the exact bilinear the terrain mesh is built
## from). get_hex_center() alone was never enough: it samples ONLY the hex's
## center point, so on slopes part of a footprint could sink into rising
## ground, and while the NoiseTexture2D is still generating asynchronously it
## falls back to y = 0.0 (buildings appeared underground). Instead the
## building's Y is the MAX heightmap sample over its footprint, plus a small
## lift so the base never z-fights with the terrain mesh.

## World-space circumradius of one parent hex cell. The terrain's hex tiles
## have a pre-scale circumradius of ~hex_size (center-to-corner), scaled up
## by mesh_scale - same numbers the terrain scripts use.
@export var hex_size: float = 1.0
@export var mesh_scale: float = 10.0

## Assign the terrain/main-screen node so buildings sit on the actual terrain
## height instead of a flat plane. Optional.
@export var terrain_path: NodePath
## Node that owns the heightmap NoiseTexture2D (`heightmap_image` property)
## and `height_scale` - usually the same node as terrain_path. Optional; when
## unset the terrain node is probed for the same properties.
@export var heightmap_path: NodePath
## Fallback height scale for heightmap sampling when the source node doesn't
## expose one. Must match the terrain's height_scale to sit on its surface.
@export var height_scale: float = 10.0

# Building ids - must match BuildingTypes on the phone and sim.glsl's ids.
const BUILDING_BARRACK := 0
const BUILDING_MINE := 1
const BUILDING_WALL := 2

## Footprint of each building as a fraction of the PARENT hex circumradius.
## All buildings live inside their hex (whole-hex placement), so these stay
## <= 1.0: a wall is a low fat hex prism filling most of the hex, the barrack
## a round mid-size tower, the mine a low triangular prism.
const BUILDING_HEX_FRACTION := {
	BUILDING_WALL: 0.85,
	BUILDING_BARRACK: 0.62,
	BUILDING_MINE: 0.7,
}

## Height of each building, as a fraction of the world (parent) hex radius.
const BUILDING_HEIGHT_FRAC := {
	BUILDING_WALL: 0.15,
	BUILDING_BARRACK: 0.3,
	BUILDING_MINE: 0.18,
}

## Global size dial: multiplies footprint radius and height.
@export_range(0.1, 2.0) var size_multiplier := 0.75

## Neutral tint for ownerless (built-but-uncaptured) mines.
const NEUTRAL_COLOR := Color(0.6, 0.6, 0.62)

var _terrain: Node = null
## Node probed for heightmap_image / height_scale (heightmap_path target).
var _heightmap_source: Node = null
## Cached heightmap image. NoiseTexture2D generates asynchronously, so
## get_image() returns null until it's ready - we keep the first non-null
## result and use it for every later placement.
var _heightmap_img: Image = null

## Building per hex, for dedup/replace: Vector2i(col,row) -> Node3D
var _hex_buildings: Dictionary = {}


func _ready() -> void:
	if terrain_path != NodePath():
		_terrain = get_node_or_null(terrain_path)
	if heightmap_path != NodePath():
		_heightmap_source = get_node_or_null(heightmap_path)
	_heightmap_img = _fetch_heightmap_image()


## The node to read heightmap_image / height_scale from: the explicit
## heightmap_path target if set, else the terrain node.
func _height_source() -> Node:
	return _heightmap_source if _heightmap_source != null else _terrain


## Grabs the terrain's NoiseTexture2D image. Returns null while the texture
## is still generating - callers must handle that (we cache once it exists).
func _fetch_heightmap_image() -> Image:
	var src := _height_source()
	if src == null:
		return null
	var tex: Variant = src.get("heightmap_image")
	if tex is NoiseTexture2D:
		return tex.get_image()
	return null


## The height scale that matches the terrain's sampling (the terrain node's
## own height_scale when it exposes one, else our fallback export).
func _active_height_scale() -> float:
	var src := _height_source()
	if src != null:
		var hs: Variant = src.get("height_scale")
		if hs is float:
			return hs
	return height_scale


## Terrain height under a building footprint: the MAX of the heightmap
## sample at the center and at four points offset by the footprint radius.
## Max (not just the center) so a building straddling a slope never has part
## of its base buried in rising ground. A small lift keeps the base just
## above the surface so it never z-fights with the terrain mesh.
func _ground_y(world_x: float, world_z: float, footprint_radius: float) -> float:
	var img := _heightmap_img
	if img == null:
		img = _fetch_heightmap_image()
		_heightmap_img = img
	if img == null:
		return 0.0
	var hs := _active_height_scale()
	var inv_scale := 1.0 / maxf(mesh_scale, 0.001)
	var best := -INF
	for off in [Vector2.ZERO, Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
		var x = world_x + off.x * footprint_radius
		var z = world_z + off.y * footprint_radius
		best = maxf(best, HexTile._sample_height(img, img.get_width(), img.get_height(), x * inv_scale, z * inv_scale, hs))
	return best + footprint_radius * 0.03


## World-space circumradius of a parent hex.
func _hex_world_radius() -> float:
	return hex_size * mesh_scale


## Footprint radius of one building type in world units.
func _footprint_radius(building_id: int) -> float:
	return _hex_world_radius() * float(BUILDING_HEX_FRACTION.get(building_id, 0.8)) * size_multiplier


## Place (or replace) the building that occupies hex (col, row) as a whole.
## building_id: 0 = barrack, 1 = mine, 2 = wall. The mesh is centered on the
## hex's center point and snapped to the terrain heightmap.
## `built`: false = construction site - spawns as a small translucent ghost;
## call set_built() on the returned node once boids finish building it and
## the mesh grows to full size.
func place_building(col: int, row: int, building_id: int, team: int, built: bool = true) -> Node3D:
	var hex_key := Vector2i(col, row)

	# One building per hex: replace whatever is there.
	if _hex_buildings.has(hex_key) and is_instance_valid(_hex_buildings[hex_key]):
		_hex_buildings[hex_key].queue_free()

	var center := Vector3.ZERO
	if _terrain and _terrain.has_method("get_hex_center"):
		center = _terrain.get_hex_center(col, row)
	var building := _make_building_mesh(building_id, team, built)
	# Y comes from the heightmap, NOT get_hex_center(): the single center
	# sample ignores the footprint's reach (buildings sank into slopes), and
	# it returns 0.0 while the heightmap texture is still generating.
	building.position = Vector3(center.x, _ground_y(center.x, center.z, _footprint_radius(building_id)), center.z)
	add_child(building)
	_hex_buildings[hex_key] = building
	return building


## Remove the building inside one hex (e.g. when the hex is destroyed).
func clear_hex(col: int, row: int) -> void:
	var hex_key := Vector2i(col, row)
	if _hex_buildings.has(hex_key) and is_instance_valid(_hex_buildings[hex_key]):
		_hex_buildings[hex_key].queue_free()
	_hex_buildings.erase(hex_key)


# ---- mesh construction -------------------------------------------------------

## Every building is a vertical prism centered on its hex, whose circumradius
## is BUILDING_HEX_FRACTION[id] of the PARENT hex radius, so the shape fits
## inside its hexagon: the WALL is a 6-sided hexagonal prism, the BARRACK a
## smooth circle (32-segment cylinder), the MINE a triangle (3-segment
## cylinder = vertical triangular prism, flat face resting on the ground).
func _make_building_mesh(building_id: int, team: int, built: bool = true) -> Node3D:
	var root := Node3D.new()

	var radius: float = _footprint_radius(building_id)
	var height: float = _hex_world_radius() * float(BUILDING_HEIGHT_FRAC.get(building_id, 0.3)) * size_multiplier

	var mat := StandardMaterial3D.new()
	# Owned buildings wear their team's FULL color (same palette as the
	# dots). team < 0 = ownerless (uncaptured mine): plain gray.
	mat.albedo_color = NEUTRAL_COLOR if team < 0 else _team_color(team)
	mat.roughness = 0.8

	# Construction site: tiny translucent ghost at ground level. set_built()
	# animates it up to full size with an opaque material.
	if not built:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.35
		height *= 0.15

	var cyl := CylinderMesh.new()
	match building_id:
		BUILDING_MINE:
			cyl.radial_segments = 3   # triangle
		BUILDING_WALL:
			cyl.radial_segments = 6   # hex prism
		_:
			cyl.radial_segments = 32  # smooth circle
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.rings = 1

	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mat
	# Rotate so the prism's flats line up with the terrain's flat-top hexes
	# (cylinder vertices start at +X; the grid needs a 30-degree twist).
	mi.rotation.y = deg_to_rad(30.0)
	# Base of the prism sits on the ground (cylinder is centered on its own origin).
	mi.position.y = height * 0.5
	root.add_child(mi)

	# Stash build metadata on the root so set_built() can rebuild the mesh.
	root.set_meta("building_id", building_id)
	root.set_meta("team", team)
	root.set_meta("built", built)
	return root


## Flip a construction-site building to built: animates the mesh GROWING
## from the small ghost to full size over BUILD_ANIM_TIME (faster when more
## dots helped build - pass the number of builders), then swaps in the
## opaque full-size mesh.
const BUILD_ANIM_TIME := 0.8  # seconds for one builder
func set_built(building: Node3D, builders: int = 1) -> void:
	if not is_instance_valid(building) or building.get_meta("built", true):
		return
	var parent := building.get_parent()
	var pos := building.position
	var bid: int = building.get_meta("building_id")
	var team: int = building.get_meta("team")
	building.queue_free()
	# Mines always finish NEUTRAL - ownership comes from capture, not from
	# who placed it. Every other building keeps its placing team's color.
	var use_team := -1 if bid == BUILDING_MINE else team
	var full := _make_building_mesh(bid, use_team, true)
	# The ghost was already heightmap-grounded in place_building(); the full
	# mesh keeps exactly that position.
	full.position = pos
	parent.add_child(full)
	# Grow-in: start small and tween to full scale. More builders = faster.
	var t := BUILD_ANIM_TIME / maxf(float(builders), 1.0)
	t = clampf(t, 0.15, BUILD_ANIM_TIME * 2.0)
	full.scale = Vector3.ONE * 0.15
	var tw := full.create_tween()
	tw.tween_property(full, "scale", Vector3.ONE, t) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# Swap the reference in _hex_buildings so future replaces target the new node.
	for hex_key in _hex_buildings:
		if _hex_buildings[hex_key] == building:
			_hex_buildings[hex_key] = full
			return


## Recolors the building standing on `hex_key` to `team`'s color (mines
## change owner when captured). Rebuilds the material in place - the mesh
## node is reused, so the grow animation and any in-flight tween survive.
func recolor_building_at(hex_key: Vector2i, team: int) -> void:
	if not _hex_buildings.has(hex_key):
		return
	var building: Node3D = _hex_buildings[hex_key]
	if not is_instance_valid(building):
		return
	building.set_meta("team", team)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = NEUTRAL_COLOR if team < 0 else _team_color(team)
	mat.roughness = 0.8
	building.get_child(0).material_override = mat


func _team_color(team: int) -> Color:
	# First four teams keep the classic colors; any team beyond gets an
	# evenly spaced hue (golden-angle) so ANY team count gets distinct
	# colors. The NPC horde never owns buildings, so it needs no entry.
	if team >= 4:
		return Color.from_hsv(fmod(float(team) * 0.618034, 1.0), 0.75, 0.9)
	match team % 4:
		0: return Color(0.9, 0.2, 0.2)   # red
		1: return Color(0.2, 0.8, 0.2)   # green
		2: return Color(0.2, 0.4, 0.9)   # blue
		_: return Color(0.9, 0.8, 0.2)   # yellow
