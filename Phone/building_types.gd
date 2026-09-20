class_name BuildingTypes
extends RefCounted

## Canonical building ids and their presentation data.
##
## These ids cross process boundaries (phone -> socket -> main screen ->
## GPU cell_info buffer) and must stay in sync with:
##   - sim.glsl's cell_building_id() consumers (barrack/mine/wall handling)
##   - HexBuildingManager's BUILDING_* constants
##   - stupid_simple.gd's set_cell_building() / remove_building_at()

const BARRACK := 0
const MINE := 1
const WALL := 2

## Sentinel sent instead of an id when a building is being REMOVED.
const REMOVE := -1

const NAMES := {
	BARRACK: "Barrack",
	MINE: "Mine",
	WALL: "Wall",
}

const COLORS := {
	BARRACK: Color(0.85, 0.45, 0.15),  # rust orange
	MINE: Color(0.55, 0.3, 0.75),      # deep purple
	WALL: Color(0.55, 0.4, 0.3),       # brown
}


static func name_of(id: int) -> String:
	return NAMES.get(id, "?")


static func color_of(id: int) -> Color:
	return COLORS.get(id, Color.WHITE)
