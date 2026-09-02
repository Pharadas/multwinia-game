extends Node
class_name HexTerrainSocket

## Lives next to hex_terrain.gd (same instance/process as the 3D terrain).
## Runs a TCP server ANY NUMBER of phone (HexGrid2DSocket) clients connect
## to. Each phone gets the terrain when it asks for it, and any "new_road"
## a phone sends is applied to the 3D terrain - it is NOT rebroadcast to
## other phones, since each phone should only ever see its own roads.
##
## LAN DISCOVERY: phones don't know this machine's IP address ahead of
## time, so alongside the TCP server this also runs a tiny UDP "is anyone
## out there?" responder. A phone broadcasts a short discovery message to
## every device on the LAN; whichever machine is running this script hears
## it and replies directly to that phone with "here's my TCP port" - the
## reply itself is how the phone learns this machine's IP (it's just
## whoever the reply came from). No IP needs to be typed in anywhere.
##
## Protocol: TCP messages are Godot Variants (Dictionaries) sent via
## PacketPeerStream, which handles framing + (de)serialization for us.
##   <- in:  {"type": "request_terrain"} - a phone asking for current terrain
##   -> out: {"type": "terrain", "tiles": [{"col", "row", "color"}, ...]}
##   <- in:  {"type": "tile_clicked", "col": int, "row": int}
##   <- in:  {"type": "new_road", "from_cell": Vector2i, "to_cell": Vector2i}
## UDP discovery messages are plain ASCII strings, not Variants, since they
## need to be understood before any Godot-specific handshake happens:
##   <- in:  "HEX_TERRAIN_DISCOVER"
##   -> out: "HEX_TERRAIN_HERE:<tcp_port>"

## Port to listen on for the real game traffic. Must match every phone's
## HexGrid2DSocket.port.
@export var port: int = 4242

## Highest number of simultaneous teams/phones this supports - team numbers
## handed out by _assign_team() are always in range(max_teams). Must match
## the 4 corner bases main_screen.gd's _compute_team_bases() builds.
@export var max_teams: int = 4

## Port the UDP discovery responder listens on. Must match every phone's
## HexGrid2DSocket.discovery_port. Deliberately a different port than the
## TCP game port so discovery traffic can't be confused with it.
@export var discovery_port: int = 4243

## Turn LAN discovery off if you'd rather have phones connect to a manually
## typed IP (HexGrid2DSocket.host) instead - useful for the same-machine
## 127.0.0.1 testing setup this used to hardcode.
@export var enable_lan_discovery: bool = true

## Exact bytes a phone's broadcast has to contain before this replies -
## keeps random LAN noise/other apps' broadcasts from tricking either side.
const DISCOVERY_REQUEST := "HEX_TERRAIN_DISCOVER"
const DISCOVERY_REPLY_PREFIX := "HEX_TERRAIN_HERE:"

## The hex_terrain.gd node in THIS instance, so incoming messages can be
## resolved to actual HexTile/road calls.
@export var terrain_path: NodePath

## Name of the function to call on the HexTile when a remote (2D-side)
## click arrives for it. Must match a method HexTile actually defines - see
## HexTile.on_tile_selected() for a ready-made stub.
@export var click_method_name: String = "on_tile_selected"

## Emitted whenever a remote phone tells us a tile was clicked, in addition
## to the automatic click_method_name call.
signal tile_clicked_remote(col: int, row: int)

## Emitted whenever a remote phone reports a new road, in addition to the
## automatic terrain.set_new_road() call.
signal new_road_remote(from_cell: Vector2i, to_cell: Vector2i)

## Emitted whenever a new phone connects and is assigned a team number.
signal player_joined(team: int)

## Emitted when a phone sends a free-drawn path (simplified to 16 points).
signal drawn_path_received(points: Array, team: int)

var _server := TCPServer.new()
var _discovery_udp := PacketPeerUDP.new()

## One entry per connected phone: {"tcp": StreamPeerTCP, "peer": PacketPeerStream}.
var _clients: Array = []

## Cached so a phone that connects AFTER generation already finished still
## gets the terrain, instead of only ever seeing live pushes.
var _last_tiles: Array = []

var previously_selected_tiles: Dictionary = {}

func _ready() -> void:
	# TCPServer.listen() with no bind_address binds "*" - every network
	# interface, not just loopback - so this is already reachable from
	# other devices on the LAN as long as the OS firewall allows it.
	var err := _server.listen(port)
	if err != OK:
		push_error("HexTerrainSocket: couldn't listen on port %d (error %d)." % [port, err])

	if enable_lan_discovery:
		var udp_err := _discovery_udp.bind(discovery_port)
		if udp_err != OK:
			push_error("HexTerrainSocket: couldn't bind UDP discovery port %d (error %d)." % [discovery_port, udp_err])
		else:
			print("HexTerrainSocket: LAN discovery listening on UDP %d." % discovery_port)

	_print_local_addresses()


## Purely informational - lets you type an IP into a phone manually as a
## fallback even with discovery enabled, without digging through OS network
## settings.
func _print_local_addresses() -> void:
	for addr in IP.get_local_addresses():
		# Skip loopback and link-local addresses - not useful for another
		# device on the LAN to connect to.
		if addr.begins_with("127.") or addr.begins_with("169.254.") or addr == "::1":
			continue
		print("HexTerrainSocket: reachable at %s:%d" % [addr, port])


func _process(_delta: float) -> void:
	if enable_lan_discovery:
		_poll_discovery()

	while _server.is_connection_available():
		var tcp := _server.take_connection()
		var peer := PacketPeerStream.new()
		peer.stream_peer = tcp
		# Increase output buffer to handle large terrain packets.
		peer.output_buffer_max_size = 4 * 1024 * 1024
		peer.input_buffer_max_size = 4 * 1024 * 1024
		var client := {"tcp": tcp, "peer": peer, "team": -1}
		_clients.append(client)
		print("HexTerrainSocket: phone connected (%d total)." % _clients.size())
		_assign_team(client)

	# Iterate backwards so removing a disconnected client mid-loop is safe.
	for i in range(_clients.size() - 1, -1, -1):
		var client: Dictionary = _clients[i]
		var tcp: StreamPeerTCP = client.tcp
		var peer: PacketPeerStream = client.peer

		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.remove_at(i)
			# The team this phone held is now free again - the NEXT
			# connection to come through _assign_team() will pick it back
			# up, since availability there is worked out fresh from
			# whichever clients are still in _clients at that moment.
			print("HexTerrainSocket: phone disconnected (team %d freed, %d remaining)." % [client.team, _clients.size()])
			continue

		while peer.get_available_packet_count() > 0:
			_handle_message(peer.get_var(), peer)


## Hands a newly-connected phone the next unused team number (0, 1, 2, ...
## up to max_teams - 1) and tells it directly, so nothing has to be typed
## in or passed via launch arguments - a phone just connects and finds out
## what team it is. "Unused" is worked out fresh from every OTHER currently
## connected client each time, so a disconnected phone's team number
## naturally becomes available again for the next one to connect.
func _assign_team(client: Dictionary) -> void:
	var used := {}
	for other in _clients:
		if other != client and other.team != -1:
			used[other.team] = true

	for team in range(max_teams):
		if not used.has(team):
			client.team = team
			client.peer.put_var({"type": "assigned_team", "team": team})
			print("HexTerrainSocket: assigned team %d to new phone." % team)
			player_joined.emit(team)
			return

	push_warning("HexTerrainSocket: no free team slot (max_teams=%d) - phone connected without one." % max_teams)


## Answers any correctly-formatted discovery broadcast with this machine's
## TCP port - the phone learns the IP to actually connect to from wherever
## this UDP reply came from, not from anything in the packet contents.
func _poll_discovery() -> void:
	while _discovery_udp.get_available_packet_count() > 0:
		var packet := _discovery_udp.get_packet()
		var text := packet.get_string_from_utf8()
		var sender_ip := _discovery_udp.get_packet_ip()
		var sender_port := _discovery_udp.get_packet_port()

		if text != DISCOVERY_REQUEST:
			continue

		_discovery_udp.set_dest_address(sender_ip, sender_port)
		_discovery_udp.put_packet(("%s%d" % [DISCOVERY_REPLY_PREFIX, port]).to_utf8_buffer())
		print("HexTerrainSocket: answered discovery request from %s:%d." % [sender_ip, sender_port])


func _handle_message(msg, from_peer: PacketPeerStream) -> void:
	if typeof(msg) != TYPE_DICTIONARY or not msg.has("type"):
		return

	var sender_team: int = -1
	for client in _clients:
		if client.peer == from_peer:
			sender_team = client.team
			break

	match msg.type:
		"request_terrain":
			# Reply only to whoever asked - a phone joining late shouldn't
			# make every other phone's terrain get re-sent too.
			from_peer.put_var({"type": "terrain", "tiles": _last_tiles})

		"tile_clicked":
			var col: int = msg.col
			var row: int = msg.row
			var team: int = sender_team if sender_team != -1 else msg.get("team", 0)
			tile_clicked_remote.emit(col, row)
			_call_tile_function(col, row, team)

		"new_road":
			var from_cell: Vector2i = msg.from_cell
			var to_cell: Vector2i = msg.to_cell
			var team_number: int = sender_team if sender_team != -1 else msg.get("team", 0)
			# The phone already routed this road around walls and sends the chain
			# of hexes it passes through - apply every hop of it.
			var path: Array = msg.get("path", [])
			new_road_remote.emit(from_cell, to_cell, team_number)
			_apply_new_road(from_cell, to_cell, team_number, path)
			# Deliberately NOT rebroadcast - each phone only shows its own
			# roads. The 3D terrain still gets every road via
			# _apply_new_road above, regardless of which phone it came from.

		"remove_road":
			var from_cell: Vector2i = msg.from_cell
			var to_cell: Vector2i = msg.to_cell
			var team_number: int = sender_team if sender_team != -1 else msg.get("team", 0)
			new_road_remote.emit(from_cell, to_cell, team_number)
			_apply_remove_road(from_cell, to_cell, team_number)

		"clear_roads":
			var team_number: int = sender_team if sender_team != -1 else msg.get("team", 0)
			_apply_clear_roads(team_number)

		"drawn_path":
			var points: Array = msg.points
			var team_number: int = sender_team if sender_team != -1 else msg.get("team", 0)
			var ref_cells: Array = msg.get("ref_cells", [])
			var ref_locals: Array = msg.get("ref_locals", [])
			var world_points := _tilemap_points_to_world(points, ref_cells, ref_locals)
			print("receiving path: ", world_points)
			drawn_path_received.emit(world_points, team_number)


func _tilemap_points_to_world(points: Array, ref_cells: Array, ref_locals: Array) -> Array:
	var terrain := _get_terrain()
	if points.is_empty():
		return []

	if ref_cells.size() >= 3 and ref_locals.size() >= 3 and terrain and terrain.has_method("get_hex_center"):
		var c0: Vector2i = ref_cells[0]
		var c1: Vector2i = ref_cells[1]
		var c2: Vector2i = ref_cells[2]

		var l0: Vector2 = ref_locals[0] if ref_locals[0] is Vector2 else Vector2(ref_locals[0].x, ref_locals[0].y)
		var l1: Vector2 = ref_locals[1] if ref_locals[1] is Vector2 else Vector2(ref_locals[1].x, ref_locals[1].y)
		var l2: Vector2 = ref_locals[2] if ref_locals[2] is Vector2 else Vector2(ref_locals[2].x, ref_locals[2].y)

		var w0_3d: Vector3 = terrain.get_hex_center(c0.x, c0.y)
		var w1_3d: Vector3 = terrain.get_hex_center(c1.x, c1.y)
		var w2_3d: Vector3 = terrain.get_hex_center(c2.x, c2.y)

		var w0 := Vector2(w0_3d.x, w0_3d.z)
		var w1 := Vector2(w1_3d.x, w1_3d.z)
		var w2 := Vector2(w2_3d.x, w2_3d.z)

		var dx_local := l1.x - l0.x
		var dy_local := l2.y - l0.y

		var scale_x := (w1.x - w0.x) / dx_local if absf(dx_local) > 0.001 else 1.0
		var scale_y := (w2.y - w0.y) / dy_local if absf(dy_local) > 0.001 else 1.0

		var out: Array = []
		for pt in points:
			var p: Vector2 = pt if pt is Vector2 else Vector2(float(pt.get("x", 0)), float(pt.get("y", 0)))
			var wx := w0.x + (p.x - l0.x) * scale_x
			var wz := w0.y + (p.y - l0.y) * scale_y
			out.append(Vector2(wx, wz))
		return out

	return points


func _get_terrain() -> Node:
	if terrain_path != NodePath():
		var node := get_node_or_null(terrain_path)
		if node:
			return node
	return get_parent()

func _call_tile_function(col: int, row: int, team: int) -> void:
	var terrain := _get_terrain()
	if previously_selected_tiles.has(team):
		var prev: HexTile = previously_selected_tiles[team]
		if is_instance_valid(prev):
			prev.deselect_by_team(team)

	if terrain and terrain.has_method("get_hex_node"):
		var tile = terrain.get_hex_node(col, row)
		if tile:
			tile.select_by_team(team)
			previously_selected_tiles[team] = tile

func _apply_new_road(from_cell: Vector2i, to_cell: Vector2i, team_number, path: Array = []) -> void:
	var terrain := _get_terrain()
	if terrain and terrain.has_method("set_new_road"):
		terrain.set_new_road(from_cell, to_cell, team_number, path)

func _apply_remove_road(from_cell: Vector2i, to_cell: Vector2i, team_number) -> void:
	var terrain := _get_terrain()
	if terrain and terrain.has_method("remove_road"):
		print("removing road from main side")
		terrain.remove_road(from_cell, to_cell, team_number)

func _apply_clear_roads(team_number: int) -> void:
	var terrain := _get_terrain()
	if terrain and terrain.has_method("clear_all_roads_for_team"):
		print("clearing all roads for team ", team_number)
		terrain.clear_all_roads_for_team(team_number)


## Sends `msg` to every connected phone, optionally skipping one peer (e.g.
## the phone that originated the message, so it doesn't get its own echo).
func _broadcast(msg: Dictionary, except_peer: PacketPeerStream = null) -> void:
	for client in _clients:
		var peer: PacketPeerStream = client.peer
		if peer != except_peer:
			peer.put_var(msg)


## Call this once generate_terrain() finishes (or whenever the terrain
## changes) - sends the tiles to every currently connected phone, and caches
## them so any phone that connects/reconnects later gets them on request.
func send_terrain(tiles: Array) -> void:
	_last_tiles = tiles
	_broadcast({"type": "terrain", "tiles": tiles})
