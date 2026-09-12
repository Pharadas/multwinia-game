extends Node3D
class_name HexBuildingManager

## Spawns 3D building meshes (castle / tower / wall) on whole hex cells when a
## phone drags one onto a hex in the hex detail view. Attach as a child of the
## terrain (or anywhere in the main scene) and call place_building().
##
## GRANULARITY: whole parent hexes only. There are no sub-hex coordinates
## anymore - a building occupies the entire hex it is dropped on, is centered
## at that hex's center, and each hex holds at most one building (re-dropping
## replaces it).

## World-space circumradius of one parent hex cell. The terrain's hex tiles
## have a pre-scale circumradius of ~hex_size (center-to-corner), scaled up
## by mesh_scale - same numbers the terrain scripts use.
@export var hex_size: float = 1.0
@export var mesh_scale: float = 10.0

## Assign a terrain node (hex_terrain.gd) so buildings sit on the actual
## terrain height instead of a flat plane. Optional.
@export var terrain_path: NodePath

# Building ids - must match HexDetailView.BUILDING_NAMES keys on the phone.
const BUILDING_BARRACK := 0
const BUILDING_MINE := 1
const BUILDING_WALL := 2

## Footprint of each building as a fraction of the PARENT hex circumradius.
## All buildings live inside their hex (whole-hex placement), so these stay
## <= 1.0: a wall is a low fat disc filling most of the hex, the barrack is
## a mid-size squat house, the mine is a low wide pit.
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

var _terrain: Node = null

## Building per hex, for dedup/replace: Vector2i(col,row) -> Node3D
var _hex_buildings: Dictionary = {}


func _ready() -> void:
	if terrain_path != NodePath():
		_terrain = get_node_or_null(terrain_path)


## World-space circumradius of a parent hex.
func _hex_world_radius() -> float:
	return hex_size * mesh_scale


## Place (or replace) the building that occupies hex (col, row) as a whole.
## building_id: 0 = barrack, 1 = mine, 2 = wall. The prism is centered on
## the hex's center point - not a sub-hex position.
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
	building.position = center
	add_child(building)
	_hex_buildings[hex_key] = building
	return building


## Neutral tint for ownerless (built-but-uncaptured) mines.
const NEUTRAL_COLOR := Color(0.6, 0.6, 0.62)


## Remove the building inside one hex (e.g. when the hex is destroyed).
func clear_hex(col: int, row: int) -> void:
	var hex_key := Vector2i(col, row)
	if _hex_buildings.has(hex_key) and is_instance_valid(_hex_buildings[hex_key]):
		_hex_buildings[hex_key].queue_free()
	_hex_buildings.erase(hex_key)


# ---- mesh construction -------------------------------------------------------

## Every building is a 6-sided prism (a big hex) whose circumradius is
## BUILDING_HEX_FRACTION[id] of the PARENT hex radius, centered on the hex -
## so each building visually "is" its hexagon.
func _make_building_mesh(building_id: int, team: int, built: bool = true) -> Node3D:
	var root := Node3D.new()

	var hex_r := _hex_world_radius()
	var radius: float = hex_r * float(BUILDING_HEX_FRACTION.get(building_id, 0.8)) * size_multiplier
	var height: float = hex_r * float(BUILDING_HEIGHT_FRAC.get(building_id, 0.3)) * size_multiplier

	var base_color: Color
	match building_id:
		BUILDING_BARRACK:
			base_color = Color(0.85, 0.45, 0.15) # rust orange
		BUILDING_MINE:
			base_color = Color(0.55, 0.3, 0.75)  # deep purple
		_:
			base_color = Color(0.55, 0.4, 0.3)   # brown (wall)

	# Team tint blended into the building color so ownership is visible.
	# team < 0 = neutral (ownerless mine): no tint, plain gray.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color if team < 0 else base_color.lerp(_team_color(team), 0.35)
	if team < 0:
		mat.albedo_color = base_color.lerp(NEUTRAL_COLOR, 0.85)
	mat.roughness = 0.8

	# Construction site: tiny translucent ghost at ground level. set_built()
	# animates it up to full size with an opaque material.
	if not built:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.35
		height *= 0.15

	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 6
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
	var bid: int = building.get_meta("building_id", 0)
	var mat := StandardMaterial3D.new()
	var base_color: Color
	match bid:
		BUILDING_BARRACK:
			base_color = Color(0.85, 0.45, 0.15)
		BUILDING_MINE:
			base_color = Color(0.55, 0.3, 0.75)
		_:
			base_color = Color(0.55, 0.4, 0.3)
	mat.albedo_color = base_color.lerp(_team_color(team), 0.75)
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
