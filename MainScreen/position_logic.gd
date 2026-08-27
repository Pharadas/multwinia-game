extends RayCast3D

var x := randi() % 20
var last_tile_checked: HexTile
var accepting_new_roads = true

func _ready() -> void:
	pass # Replace with function body.

func _process(delta: float) -> void:
	x += 1
	# Was `if x % 20:` - that's true on 19 out of 20 frames (anything
	# nonzero) and only false on the one frame that's an exact multiple of
	# 20, which is backwards from "check every 20 frames". Fixed to
	# actually match that intent.
	if x % 20 == 0:
		x = 0
		# Cache once instead of calling get_collider() three separate
		# times - it's just reading the RayCast3D's last cached hit, so
		# repeated calls can't disagree with each other within one frame,
		# but there's no reason to ask three times either.
		var collider = get_collider()
		if collider is HexTile and collider.should_move($"..".team_number):
			# Hand the WHOLE route to the darwinian: get_route() returns the
			# complete stored path (every hex from this tile to the road's
			# end), and follow_path() walks each waypoint in order. The route
			# lives only on this starting tile - a darwinian picks it up here
			# and carries it, and nothing is written to the hexes it passes
			# through.
			var path_tiles: Array = collider.get_route($"..".team_number)
			if path_tiles.size() > 1 and accepting_new_roads:
				var waypoints: Array = []
				for t in path_tiles:
					waypoints.append(t.global_position)
				$"..".follow_path(waypoints)
				last_tile_checked = collider
				accepting_new_roads = false
