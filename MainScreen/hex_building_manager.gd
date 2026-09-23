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
## from), taking the MAX over a DENSE grid across the footprint plus a small
## lift, so the base always clears the ground it stands on:
##   * The center alone was not enough - on a slope part of the footprint
##     sank into rising ground.
##   * Neither was a sparse ring (center + 4 cardinal points): this heightmap
##     is 512 texels across a ~60-unit terrain, so a hex footprint only spans
##     a handful of texels and a sample that misses by half a texel misses
##     whole units of ridge. Measured on real terrain, a 5-point max put the
##     base 2.8 units UNDER a barrack only 2.25 units tall - i.e. completely
##     buried - while the true footprint maximum was 2.8 units higher.
##   * The image is re-read whenever the texture regenerates (its noise seed is
##     randomized at startup) and never cached from a previous generation:
##     sampling a stale image places buildings against terrain that no longer
##     exists and can miss by the full height range.

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

## Extra fill samples per axis across the footprint, on top of the exact
## texel-corner sampling _ground_y() does (see GROUNDING above). Small: the
## corners are what matter, this is insurance for the mesh's sub-texel
## tessellation and costs nothing at placement time.
const GROUND_FILL_SAMPLES := 5
## Base lift above the sampled maximum, as a fraction of the footprint
## radius - enough to keep the base out of the terrain mesh, small enough
## that the building still reads as standing on the ground.
const GROUND_LIFT := 0.03

## Neutral tint for ownerless (built-but-uncaptured) mines.
const NEUTRAL_COLOR := Color(0.6, 0.6, 0.62)

var _terrain: Node = null
## Node probed for heightmap_image / height_scale (heightmap_path target).
var _heightmap_source: Node = null
## The texture currently sampled for heights, and its generated image.
## NoiseTexture2D generates asynchronously, so get_image() returns null until
## it's ready; the image is dropped whenever the texture regenerates (the
## noise seed is randomized at startup, and a stale image would ground
## buildings against terrain that no longer exists).
var _heightmap_tex: NoiseTexture2D = null
var _heightmap_img: Image = null

## Building per hex, for dedup/replace: Vector2i(col,row) -> Node3D
var _hex_buildings: Dictionary = {}


func _ready() -> void:
	if terrain_path != NodePath():
		_terrain = get_node_or_null(terrain_path)
	if heightmap_path != NodePath():
		_heightmap_source = get_node_or_null(heightmap_path)
	_refresh_heightmap_texture()


## The node to read heightmap_image / height_scale from: the explicit
## heightmap_path target if set, else the terrain node.
func _height_source() -> Node:
	return _heightmap_source if _heightmap_source != null else _terrain


## Tracks the terrain's NoiseTexture2D: picks up a new texture and forgets the
## generated image whenever the texture regenerates (its `changed` signal),
## so heights are always sampled from the image the terrain is actually made
## of. Safe to call at any time.
func _refresh_heightmap_texture() -> void:
	var src := _height_source()
	if src == null:
		return
	var tex: Variant = src.get("heightmap_image")
	if not tex is NoiseTexture2D:
		return
	if tex != _heightmap_tex:
		_heightmap_tex = tex
		_heightmap_img = null
		if not tex.changed.is_connected(_on_heightmap_changed):
			tex.changed.connect(_on_heightmap_changed)


func _on_heightmap_changed() -> void:
	# Regenerated (new seed / new noise): resample on the next placement.
	_heightmap_img = null


## The terrain's current generated image, or null while it's still baking.
## Re-read per placement: NoiseTexture2D caches its own image, so this is a
## cheap accessor, not a regeneration.
func _heightmap_image() -> Image:
	_refresh_heightmap_texture()
	if _heightmap_img == null and _heightmap_tex != null:
		_heightmap_img = _heightmap_tex.get_image()
	return _heightmap_img


## The height scale that matches the terrain's sampling (the terrain node's
## own height_scale when it exposes one, else our fallback export).
func _active_height_scale() -> float:
	var src := _height_source()
	if src != null:
		var hs: Variant = src.get("height_scale")
		if hs is float:
			return hs
	return height_scale


## Terrain height under a building footprint: the MAX heightmap sample over the
## footprint's bounding square, so a building straddling a ridge or a slope
## never has part of its base buried in rising ground (see the GROUNDING note
## at the top of this file for the measured failure).
##
## The heightmap sampler is bilinear, so its maximum over any rectangle is
## attained at a corner of one of the texels that rectangle covers, or where
## its own edges cross texel lines - NOT at an arbitrary point of a fixed grid.
## Sampling only a spread of points (dense grid or center + cardinal points)
## therefore always underprices a ridge that crosses the footprint, so this
## samples exactly those kink points: the square's four corners, every texel
## corner inside it, and the texel-line crossings along its edges. A small
## interior fill is kept as insurance for the terrain mesh's sub-texel
## tessellation (which samples the same bilinear function, and so can never
## exceed these values).
##
## `fallback` is used while the heightmap image isn't generated yet: pass the
## hex's own sampled height so a building placed during startup still lands on
## the (flat, placeholder) terrain instead of at y = 0.
func _ground_y(world_x: float, world_z: float, footprint_radius: float, fallback: float = 0.0) -> float:
	var img := _heightmap_image()
	if img == null:
		return fallback
	var hs := _active_height_scale()
	var inv_scale := 1.0 / maxf(mesh_scale, 0.001)
	var img_w := img.get_width()
	var img_h := img.get_height()

	# Footprint square in the sampler's own input space.
	var u0 := (world_x - footprint_radius) * inv_scale
	var u1 := (world_x + footprint_radius) * inv_scale
	var v0 := (world_z - footprint_radius) * inv_scale
	var v1 := (world_z + footprint_radius) * inv_scale

	# The sampler offsets its input by half the image, so texel centres live
	# at integer (u + img_w * 0.5).
	var half_w := float(img_w) * 0.5
	var half_h := float(img_h) * 0.5
	var best := -INF
	best = maxf(best, _sample_at(img, u0, v0, hs))
	best = maxf(best, _sample_at(img, u0, v1, hs))
	best = maxf(best, _sample_at(img, u1, v0, hs))
	best = maxf(best, _sample_at(img, u1, v1, hs))

	var tx0 := ceili(u0 + half_w)
	var tx1 := floori(u1 + half_w)
	var tz0 := ceili(v0 + half_h)
	var tz1 := floori(v1 + half_h)
	for tx in range(tx0, tx1 + 1):
		for tz in range(tz0, tz1 + 1):
			best = maxf(best, _sample_at(img, float(tx) - half_w, float(tz) - half_h, hs))

	# Texel-line crossings along the footprint's edges: the kinks that lie ON
	# the boundary, which the interior texel corners don't cover.
	for tx in range(tx0, tx1 + 1):
		var eu := clampf(float(tx) - half_w, u0, u1)
		best = maxf(best, _sample_at(img, eu, v0, hs))
		best = maxf(best, _sample_at(img, eu, v1, hs))
	for tz in range(tz0, tz1 + 1):
		var ev := clampf(float(tz) - half_h, v0, v1)
		best = maxf(best, _sample_at(img, u0, ev, hs))
		best = maxf(best, _sample_at(img, u1, ev, hs))

	# Interior fill (see the comment above).
	var n := GROUND_FILL_SAMPLES
	for ix in range(n):
		var fu: float = lerpf(u0, u1, float(ix) / float(n - 1))
		for iz in range(n):
			best = maxf(best, _sample_at(img, fu, lerpf(v0, v1, float(iz) / float(n - 1)), hs))

	return best + footprint_radius * GROUND_LIFT


func _sample_at(img: Image, u: float, v: float, height_scale_value: float) -> float:
	return HexTile._sample_height(img, img.get_width(), img.get_height(), u, v, height_scale_value)


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
	# Y comes from the heightmap over the whole footprint, NOT from the hex
	# center alone: a center sample ignores the footprint's reach, so a
	# building on a ridge or slope sank into rising ground.
	var ground := _ground_y(center.x, center.z, _footprint_radius(building_id), center.y)
	building.position = Vector3(center.x, ground, center.z)
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
	mat.albedo_color = NEUTRAL_COLOR if team < 0 else team_color(team)
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
	mat.albedo_color = NEUTRAL_COLOR if team < 0 else team_color(team)
	mat.roughness = 0.8
	building.get_child(0).material_override = mat


## The one team palette: buildings, the lobby's player list and anything else
## showing "which team is this" use it, so a team is never two colors.
## Static so callers don't need a live manager instance.
static func team_color(team: int) -> Color:
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
