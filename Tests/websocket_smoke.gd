extends SceneTree

## Smoke-test harness for the WebSocket phone path.
## Run with:
##   godot --headless -s res://Tests/websocket_smoke.gd
## It boots the REAL MainScreen/socket.gd, pushes ~861 fake tiles, and runs
## for 180 s while you open the exported web phone in a browser. It logs
## connections, team assignment, and any messages phones send back.

var sock: Node
var elapsed := 0.0
var reported := {}

func _initialize() -> void:
	sock = load("res://MainScreen/socket.gd").new()
	sock.name = "TestSocket"
	root.add_child(sock)
	sock.player_joined.connect(func(t: int) -> void: print("TEST: player_joined team=", t))
	sock.tile_clicked_remote.connect(func(c: int, r: int) -> void: print("TEST: tile_clicked_remote ", c, ",", r))
	sock.drawn_path_received.connect(func(p: Array, t: int, f: float) -> void: print("TEST: drawn_path ", p.size(), " pts team=", t, " frac=", f))
	var tiles: Array = []
	for col in range(41):
		for row in range(21):
			tiles.append({"col": col, "row": row, "color": Color(col / 41.0, row / 21.0, 0.5, 1.0), "is_wall": false})
	print("TEST: terrain ready with ", tiles.size(), " tiles (pushed lazily on request via socket cache)")
	# The socket replies from _last_tiles when a phone asks - same as the game.
	sock.send_terrain(tiles)
	print("TEST: harness running - open the web phone now (180 s window)")

func _process(delta: float) -> bool:
	elapsed += delta
	var n_ws: int = sock._ws_clients.size()
	if n_ws > 0 and not reported.has("ws"):
		reported["ws"] = true
		print("TEST: web client connected, ws_clients=", n_ws)
	if elapsed >= 180.0:
		print("TEST: done. final ws_clients=", n_ws)
		return true
	return false
