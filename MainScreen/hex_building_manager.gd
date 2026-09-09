extends Node3D
class_name HexBuildingManager

## Spawns 3D building meshes (castle / tower / wall) inside hex cells when a
## phone drags one onto a sub-hex in the hex detail view. Attach as a child
## of the terrain (or anywhere in the main scene) and call place_building().

## Sub-hex layout inside a parent hex MUST match Phone/hex_detail_view.gd:
## 3 rings, flat-top axial, unit circumradius scaled to the parent hex size.
const SUB_RINGS := 3

## World-space circumradius of one parent hex cell. The terrain's hex tiles
## have a pre-scale circumradius of ~hex_size (center-to-corner), scaled up
## by mesh_scale - same numbers the terrain scripts use.
@export var hex_size: float = 1.0
@export var mesh_scale: float = 10.0

## Assign a terrain node (hex_terrain.gd) so buildings sit on the actual
## terrain height instead of a flat plane. Optional.
@export var terrain_path: NodePath

# Building ids - must match HexDetailView.BUILDING_* constants on the phone.
const BUILDING_CASTLE := 0
const BUILDING_TOWER := 1
const BUILDING_WALL := 2

## Footprint radius of each building, in SUB-HEX radii (the small hexes of
## the honeycomb view): a wall fills its sub-hex, a tower covers that
## sub-hex plus ~1 ring around it, a castle ~2 rings. The parent hex itself
## is only ever covered by the biggest buildings near its center.
const BUILDING_HEX_RADIUS := {
	BUILDING_WALL: 1,
	BUILDING_TOWER: 2,
	BUILDING_CASTLE: 3,
}

## Height of each building, as a fraction of the world (parent) hex radius.
const BUILDING_HEIGHT_FRAC := {
	BUILDING_WALL: 0.15,
	BUILDING_TOWER: 0.6,
	BUILDING_CASTLE: 0.35,
}

## Global size dial: multiplies footprint radius and height. 1.0 = footprint
## radius exactly BUILDING_HEX_RADIUS sub-hexes.
@export_range(0.1, 2.0) var size_multiplier := 0.75

var _terrain: Node = null

## Buildings per hex, for dedup/replace: Vector2i(col,row) -> {Vector2i(sub_q,sub_r) -> Node3D}
var _hex_buildings: Dictionary = {}


func _ready() -> void:
	if terrain_path != NodePath():
		_terrain = get_node_or_null(terrain_path)


## World-space circumradius of a parent hex.
func _hex_world_radius() -> float:
	return hex_size * mesh_scale


## World-space circumradius of a sub-hex (unit axial layout scaled to fit
## the parent hex's ring-3 extent, exactly like the phone's _draw()).
func _sub_hex_world_radius() -> float:
	# The phone fits ring `rings` (3) inside fill_fraction of the parent hex.
	# Its max unit distance is (rings + 1) for corner cells in axial pixel
	# space; the parent hex circumradius corresponds to that extent.
	var max_unit_dist := float(SUB_RINGS + 1)
	return _hex_world_radius() / max_unit_dist


## Convert sub-hex axial (q, r) inside a parent hex to a world-space offset
## from the parent hex center, on the XZ plane. Flat-top layout matching
## HexDetailView._axial_to_pixel().
static func _sub_axial_to_world_offset(q: int, r: int, sub_r_world: float) -> Vector3:
	return Vector3(
		sub_r_world * 1.5 * float(q),
		0.0,
		sub_r_world * sqrt(3.0) * (float(r) + float(q) * 0.5)
	)


## Place (or replace) a building inside hex (col, row) at sub-hex (sub_q, sub_r).
## building_id: 0 = castle, 1 = tower, 2 = wall. The prism is centered on the
## sub-hex's world position and extends footprint_radius hexes in every
## direction, covering multiple terrain hexes.
func place_building(col: int, row: int, sub_q: int, sub_r: int, building_id: int, team: int) -> Node3D:
	var hex_key := Vector2i(col, row)
	var sub_key := Vector2i(sub_q, sub_r)
	var hex_map: Dictionary = _hex_buildings.get(hex_key, {})

	# Replace if this sub-hex already has one.
	if hex_map.has(sub_key) and is_instance_valid(hex_map[sub_key]):
		hex_map[sub_key].queue_free()
		hex_map.erase(sub_key)

	var center := Vector3.ZERO
	if _terrain and _terrain.has_method("get_hex_center"):
		center = _terrain.get_hex_center(col, row)

	var sub_r_world := _sub_hex_world_radius()
	var offset := _sub_axial_to_world_offset(sub_q, sub_r, sub_r_world)

	var building := _make_building_mesh(building_id, team)
	building.position = center + offset
	add_child(building)

	hex_map[sub_key] = building
	_hex_buildings[hex_key] = hex_map
	return building


## Remove every building inside one hex (e.g. when the hex is destroyed).
func clear_hex(col: int, row: int) -> void:
	var hex_key := Vector2i(col, row)
	var hex_map: Dictionary = _hex_buildings.get(hex_key, {})
	for node in hex_map.values():
		if is_instance_valid(node):
			node.queue_free()
	_hex_buildings.erase(hex_key)


# ---- mesh construction -------------------------------------------------------

## Every building is a 6-sided prism (a big hex) whose circumradius is
## BUILDING_HEX_RADIUS[id] SUB-hexes - so a wall fills one small honeycomb
## cell, a tower covers it plus a ring, a castle two rings. Scaled against
## the SUB-hex world radius, never the parent hex, so a center tower is a
## fraction of the parent hex, not the whole thing.
func _make_building_mesh(building_id: int, team: int) -> Node3D:
	var root := Node3D.new()

	var sub_r := _sub_hex_world_radius()
	var hex_r := _hex_world_radius()
	var footprint: float = float(BUILDING_HEX_RADIUS.get(building_id, 1))
	var radius := sub_r * footprint * 0.96 * size_multiplier
	var height := hex_r * float(BUILDING_HEIGHT_FRAC.get(building_id, 0.3)) * size_multiplier

	var base_color: Color
	match building_id:
		BUILDING_CASTLE:
			base_color = Color(0.95, 0.85, 0.2)  # gold
		BUILDING_TOWER:
			base_color = Color(0.6, 0.6, 0.7)    # steel grey
		_:
			base_color = Color(0.55, 0.4, 0.3)   # brown

	# Team tint blended into the building color so ownership is visible.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color.lerp(_team_color(team), 0.35)
	mat.roughness = 0.8

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
	return root


func _team_color(team: int) -> Color:
	match team % 4:
		0: return Color(0.9, 0.2, 0.2)   # red
		1: return Color(0.2, 0.8, 0.2)   # green
		2: return Color(0.2, 0.4, 0.9)   # blue
		_: return Color(0.9, 0.8, 0.2)   # yellow
