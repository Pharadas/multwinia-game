extends Node
class_name HexTerrainSocket

## Lives next to hex_terrain.gd (same instance/process as the 3D terrain).
## Runs a TCP server ANY NUMBER of phone (HexGrid2DSocket) clients connect
## to. Each phone gets the terrain when it asks for it, and a phone's
## drawn paths / building placements are applied to the 3D sim.
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
##   <- in:  {"type": "drawn_path", "points": Array, "team": int, ...}
##   <- in:  {"type": "building_placed", "col": int, "row": int, ...}
## UDP discovery messages are plain ASCII strings, not Variants, since they
## need to be understood before any Godot-specific handshake happens:
##   <- in:  "HEX_TERRAIN_DISCOVER"
##   -> out: "HEX_TERRAIN_HERE:<tcp_port>:<websocket_port>"
## (the second field is optional to older phones - they still read the TCP
## port as the first field: see HexGrid2DSocket.parse_discovery_reply)

## Port to listen on for the real game traffic. Must match every phone's
## HexGrid2DSocket.port.
@export var port: int = 4242

## Highest number of simultaneous teams/phones this supports - team numbers
## handed out by _assign_team() are always in range(max_teams).
## How many teams get handed out to phones. Team ids run 0..max_teams-1.
## NOTE: the GPU sim reserves one extra slot ABOVE these as the NPC horde
## (deserters) - a phone is never that team. The sim runs with
## num_teams = max_teams + 1, and the sim's num_teams (stupid_simple.gd)
## is the source of truth: main_screen.gd syncs this export to it at
## startup, so changing the team count means editing the sim, not this.
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

## Emitted whenever a new phone connects and is assigned a team number.
## A phone connected and was handed a team (see _assign_team).
signal player_joined(team: int)
## A phone disconnected: its team is free again. Sent so the main screen's
## lobby can drop the row instead of listing players who already left.
signal player_left(team: int)

## Emitted when a phone sends a free-drawn path (simplified to 16 points).
signal drawn_path_received(points: Array, team: int, fraction: float)

## Emitted when a phone drops a building on a WHOLE hex (no sub-hex coords -
## the building occupies the entire hex, centered on it).
signal building_placed_remote(col: int, row: int, building_id: int, team: int)

## Emitted when a phone double-tapped a WALL hex: mark it for demolition -
## nearby dots will tear it down (see sim.glsl's demolition block).
signal wall_delete_marked(col: int, row: int, team: int)

## Emitted when a phone picks the hexes its army starts in (lobby only).
## `cells` are the phone's own grid cells - main_screen maps them to world
## positions and is the authority on whether each one is placeable.
signal spawn_hexes_remote(team: int, cells: Array)

var _server := TCPServer.new()
var _discovery_udp := PacketPeerUDP.new()

## Latest lobby state, replayed to every phone as it finishes connecting (see
## broadcast_lobby_state).
var _lobby_started := true
var _lobby_picks: Dictionary = {}

## One entry per connected phone: {"tcp": StreamPeerTCP, "peer": PacketPeerStream}.
var _clients: Array = []

## WEB PHONES: browsers can't open raw TCP sockets, so web-exported phone
## views connect here over WebSocket instead (same messages, JSON-encoded).
## Entries are {"ws": WebSocketPeer, "team": int}. Runs alongside the raw
## TCP server on `websocket_port` - native phones and web phones coexist.
@export var websocket_port: int = 9080
var _ws_server := TCPServer.new()
## Set false to skip UPnP (e.g. when the router has no gateway or you're
## running pure-LAN sessions and don't want the router touched).
@export var enable_upnp: bool = true
## Port forwarded for OUTSIDE connections. Local phones connect over the LAN
## regardless - UPnP only matters when a web phone is coming from the internet.
@export var upnp_public_port: int = 4242
var _upnp: UPNP = null
var _upnp_external_ip := ""
var _ws_clients: Array = []

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

	# WebSocket listener for web-exported phones (browsers: TCP is banned).
	var ws_err := _ws_server.listen(websocket_port)
	if ws_err != OK:
		push_error("HexTerrainSocket: couldn't listen for WebSockets on port %d (error %d)." % [websocket_port, ws_err])
	else:
		print("HexTerrainSocket: WebSocket server listening on port %d." % websocket_port)

	if enable_lan_discovery:
		var udp_err := _discovery_udp.bind(discovery_port)
		if udp_err != OK:
			push_error("HexTerrainSocket: couldn't bind UDP discovery port %d (error %d)." % [discovery_port, udp_err])
		else:
			print("HexTerrainSocket: LAN discovery listening on UDP %d." % discovery_port)

	_print_local_addresses()

	if enable_upnp:
		# Threaded: gateway discovery can block for several seconds - don't
		# stall scene startup on it.
		_upnp = UPNP.new()
		var upnp_thread := Thread.new()
		upnp_thread.start(_setup_upnp)


## Opens the game ports on the router via UPnP so web phones from OUTSIDE
## the LAN can reach this server. Only the WebSocket port strictly needs
## forwarding (browsers connect to it); the raw TCP port is forwarded too
## so native phones from other networks can also join.
func _setup_upnp() -> void:
	var err := _upnp.discover()
	if err != UPNP.UPNP_RESULT_SUCCESS:
		print("HexTerrainSocket: UPnP discovery failed (error %d) - web phones must connect over the LAN or via manual port forwarding." % err)
		return
	var gateway := _upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		print("HexTerrainSocket: UPnP found no valid gateway - web phones must connect over the LAN or via manual port forwarding.")
		return
	# Discover() must complete before any other call, and these calls are
	# only safe from one thread - this whole function runs on the worker.
	for fwd_port in [upnp_public_port, websocket_port]:
		# UDP first is pointless for this game; TCP is what both transports use.
		var tcp_err := _upnp.add_port_mapping(fwd_port, fwd_port, "hex_terrain_tcp", "TCP", 0)
		if tcp_err != OK:
			print("HexTerrainSocket: UPnP couldn't forward TCP %d (error %d)." % [fwd_port, tcp_err])
		else:
			print("HexTerrainSocket: UPnP forwarded TCP %d." % fwd_port)
	_upnp_external_ip = _upnp.query_external_address()
	print("HexTerrainSocket: public IP for internet web phones: %s (WS port %d)" % [_upnp_external_ip, websocket_port])


## Purely informational - lets you type an IP into a phone manually as a
## fallback even with discovery enabled, without digging through OS network
## settings.
func _print_local_addresses() -> void:
	for addr in get_lan_addresses():
		print("HexTerrainSocket: reachable at %s:%d" % [addr, port])
	# The public (UPnP) address is printed by _setup_upnp() on its worker
	# thread once discovery finishes - no need to block startup for it.


## The LAN addresses another device can actually reach this server on,
## best-first: private ranges (the ones a phone on the same WiFi uses)
## before anything else, loopback / link-local / IPv6 dropped entirely -
## they are meaningless to another device and unreachable through the HUD.
## Read-only: nothing here touches the network, so the lobby can call it
## every second.
func get_lan_addresses() -> Array:
	var public_like: Array = []
	var private_first: Array = []
	for addr in IP.get_local_addresses():
		# Skip loopback, link-local and IPv6 - not useful for another
		# device on the LAN to connect to.
		if addr.begins_with("127.") or addr.begins_with("169.254.") \
				or addr == "::1" or addr.contains(":"):
			continue
		if is_private_ipv4(addr):
			private_first.append(addr)
		else:
			public_like.append(addr)
	return private_first + public_like


## The router's public (external) IP as reported by UPnP - empty until the
## background discovery finishes, and empty forever on a router without
## UPnP. Shown in the lobby so the host can tell players outside the LAN
## what to dial.
func get_public_ip() -> String:
	return _upnp_external_ip


## True for the IPv4 ranges a home/office LAN uses (RFC 1918 + CGNAT).
## Static and literal-only: a hostname is not an address and returns false.
static func is_private_ipv4(addr: String) -> bool:
	var parts := addr.split(".")
	if parts.size() != 4:
		return false
	for p in parts:
		if not p.is_valid_int():
			return false
		var v := int(p)
		if v < 0 or v > 255:
			return false
	var a := int(parts[0])
	if a == 10:
		return true
	if a == 192 and int(parts[1]) == 168:
		return true
	if a == 172 and int(parts[1]) >= 16 and int(parts[1]) <= 31:
		return true
	# 100.64.0.0/10 (CGNAT) - some ISPs hand these out on the LAN side.
	return a == 100 and int(parts[1]) >= 64 and int(parts[1]) <= 127


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
			if client.team >= 0:
				player_left.emit(client.team)
			continue

		while peer.get_available_packet_count() > 0:
			_handle_message(peer.get_var(), peer)

	# --- WebSocket clients (web phones) --------------------------------------
	while _ws_server.is_connection_available():
		var ws := WebSocketPeer.new()
		# The terrain message is well over the 64 KB default WS buffers (Godot
		# silently breaks above it) - match the 4 MB the TCP path uses.
		ws.inbound_buffer_size = 4 * 1024 * 1024
		ws.outbound_buffer_size = 4 * 1024 * 1024
		ws.accept_stream(_ws_server.take_connection())
		var ws_client := {"ws": ws, "team": -1}
		_ws_clients.append(ws_client)
		print("HexTerrainSocket: web phone connected (%d WS total)." % _ws_clients.size())
		_assign_team(ws_client)

	for i in range(_ws_clients.size() - 1, -1, -1):
		var client: Dictionary = _ws_clients[i]
		var ws: WebSocketPeer = client.ws
		ws.poll()
		var ws_state := ws.get_ready_state()
		if ws_state == WebSocketPeer.STATE_OPEN:
			# First OPEN after team assignment: greet now (see _assign_team).
			if not client.get("greeted", true):
				client["greeted"] = true
				_peer_send(ws, assigned_team_message(client.team))
				# What the join-time broadcast couldn't deliver (the handshake
				# wasn't up yet): whether the lobby is open and any picks this
				# team already made.
				_peer_send(ws, lobby_state_message(client.team, _lobby_started, _lobby_picks))
			while ws.get_available_packet_count() > 0:
				var packet := ws.get_packet()
				if ws.was_string_packet():
					var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
					if parsed is Dictionary:
						_handle_message(parsed, ws)
				# (binary WS packets ignored - phones always send text JSON)
		elif ws_state == WebSocketPeer.STATE_CLOSED:
			_ws_clients.remove_at(i)
			print("HexTerrainSocket: web phone disconnected (team %d freed, %d WS remaining)." % [client.team, _ws_clients.size()])
			if client.team >= 0:
				player_left.emit(client.team)


## Hands a newly-connected phone the next unused team number (0, 1, 2, ...
## up to max_teams - 1) and tells it directly, so nothing has to be typed
## in or passed via launch arguments - a phone just connects and finds out
## what team it is. "Unused" is worked out fresh from every OTHER currently
## connected client each time, so a disconnected phone's team number
## naturally becomes available again for the next one to connect.
## The message a phone gets when it joins: its team id, plus that team's
## color so the phone can show "you are the green team" without keeping its
## own copy of the palette. The main screen owns the palette
## (HexBuildingManager.team_color), so a team can never be two colors there
## and two others on the phone. Color travels as plain [r, g, b] floats - a
## Color object cannot cross the wire.
static func assigned_team_message(team: int) -> Dictionary:
	var color := HexBuildingManager.team_color(team)
	return {"type": "assigned_team", "team": team, "color": [color.r, color.g, color.b]}


func _assign_team(client: Dictionary) -> void:
	# BOTH transports share one pool of team numbers: a native (TCP) phone and
	# a web (WebSocket) phone are just as likely to be in the same match, so
	# counting only _clients here used to hand every web phone team 0.
	var used := {}
	for other in _clients:
		if other != client and other.team != -1:
			used[other.team] = true
	for other in _ws_clients:
		if other != client and other.team != -1:
			used[other.team] = true

	for team in range(max_teams):
		if not used.has(team):
			client.team = team
			if client.has("ws"):
				# Web phone: the WebSocket handshake is still in progress at
				# accept time (accept_stream only STARTS it), so sending now
				# would be silently dropped. The greeting is deferred to the
				# moment the peer first reports STATE_OPEN in _process().
				client["greeted"] = false
			else:
				# Native phone: put_var buffers fine on an accepted TCP stream.
				_peer_send(client.peer, assigned_team_message(team))
				_peer_send(client.peer, lobby_state_message(team, _lobby_started, _lobby_picks))
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
		# Two colon-separated fields: TCP port, then the WebSocket port a web
		# phone on the LAN would need. The phone splits them explicitly - the
		# whole payload must NEVER be read with to_int() ("4242:9080" parses
		# as 42429080 there, which is not a port).
		_discovery_udp.put_packet(("%s%d:%d" % [DISCOVERY_REPLY_PREFIX, port, websocket_port]).to_utf8_buffer())
		print("HexTerrainSocket: answered discovery request from %s:%d." % [sender_ip, sender_port])


## `from_peer` is either a PacketPeerStream (native phone) or a
## WebSocketPeer (web phone) - whichever transport the message arrived on.
func _handle_message(msg, from_peer) -> void:
	if typeof(msg) != TYPE_DICTIONARY or not msg.has("type"):
		return

	var sender_team: int = -1
	for client in _clients:
		if client.peer == from_peer:
			sender_team = client.team
			break
	if sender_team == -1:
		# Not a native client - check the web (WebSocket) phones too.
		for client in _ws_clients:
			if client.ws == from_peer:
				sender_team = client.team
				break

	match msg.type:
		"request_terrain":
			# Reply only to whoever asked - a phone joining late shouldn't
			# make every other phone's terrain get re-sent too.
			_peer_send(from_peer, {"type": "terrain", "tiles": _last_tiles})

		"tile_clicked":
			var col: int = msg.col
			var row: int = msg.row
			var team: int = sender_team if sender_team != -1 else msg.get("team", 0)
			tile_clicked_remote.emit(col, row)
			_call_tile_function(col, row, team)

		"drawn_path":
			var points: Array = msg.points
			var team_number: int = sender_team if sender_team != -1 else msg.get("team", 0)
			var ref_cells: Array = msg.get("ref_cells", [])
			var ref_locals: Array = msg.get("ref_locals", [])
			var fraction: float = msg.get("fraction", 1.0)
			var world_points := _tilemap_points_to_world(points, ref_cells, ref_locals)
			print("receiving path: ", world_points)
			drawn_path_received.emit(world_points, team_number, fraction)

		"building_placed":
			var col: int = msg.col
			var row: int = msg.row
			var building_id: int = msg.building
			var team_number: int = sender_team if sender_team != -1 else msg.get("team", 0)
			building_placed_remote.emit(col, row, building_id, team_number)

		"building_delete":
			var dcol: int = msg.col
			var drow: int = msg.row
			var dteam: int = sender_team if sender_team != -1 else msg.get("team", 0)
			wall_delete_marked.emit(dcol, drow, dteam)

		"spawn_hex":
			var scells: Array = msg.get("cells", [])
			var steam: int = sender_team if sender_team != -1 else int(msg.get("team", 0))
			spawn_hexes_remote.emit(steam, scells)


func _tilemap_points_to_world(points: Array, ref_cells: Array, ref_locals: Array) -> Array:
	var terrain := _get_terrain()
	if points.is_empty():
		return []

	if ref_cells.size() >= 3 and ref_locals.size() >= 3 and terrain and terrain.has_method("get_hex_center"):
		var c0: Vector2i = _as_vec2(ref_cells[0])
		var c1: Vector2i = _as_vec2(ref_cells[1])
		var c2: Vector2i = _as_vec2(ref_cells[2])

		var l0: Vector2 = _as_vec2(ref_locals[0])
		var l1: Vector2 = _as_vec2(ref_locals[1])
		var l2: Vector2 = _as_vec2(ref_locals[2])

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
			# Web phones ship points as JSON arrays [x, y] - native ones as
			# Vector2 (or {x, y} dicts from older clients).
			var p := _as_vec2(pt)
			var wx := w0.x + (p.x - l0.x) * scale_x
			var wz := w0.y + (p.y - l0.y) * scale_y
			out.append(Vector2(wx, wz))
		return out

	return points


## Robust Vector2 decode for network values: native Vector2, JSON array
## [x, y], or a legacy {x, y} dictionary.
func _as_vec2(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is Dictionary:
		return Vector2(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
	return Vector2.ZERO


func _get_terrain() -> Node:
	if terrain_path != NodePath():
		var node := get_node_or_null(terrain_path)
		if node:
			return node
	return get_parent()

func _call_tile_function(col: int, row: int, team: int) -> void:
	var terrain := _get_terrain()
	if previously_selected_tiles.has(team):
		if (previously_selected_tiles[team]):
			previously_selected_tiles[team].deselect_by_team(team)

	if terrain and terrain.has_method("get_hex_node"):
		var tile = terrain.get_hex_node(col, row)
		if tile:
			tile.select_by_team(team)
			previously_selected_tiles[team] = tile


## Sends `msg` to one phone peer - either a native PacketPeerStream (put_var,
## full Variant fidelity) or a web WebSocketPeer (JSON text). Vector2 and
## Color get flattened explicitly so JSON never sees a raw Variant.
func _peer_send(peer, msg: Dictionary) -> void:
	if peer is WebSocketPeer:
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			peer.send_text(JSON.stringify(_jsonify(msg)))
	elif peer != null:
		peer.put_var(msg)


## JSON-safe conversion (mirrors HexGrid2DSocket._jsonify on the phone):
## Vector2/Vector2i -> [x, y], Color -> {r, g, b, a}, recursive.
func _jsonify(v: Variant) -> Variant:
	if v is Vector2 or v is Vector2i:
		return [v.x, v.y]
	if v is Color:
		return {"r": v.r, "g": v.g, "b": v.b, "a": v.a}
	if v is Array:
		var out: Array = []
		out.resize(v.size())
		for i in v.size():
			out[i] = _jsonify(v[i])
		return out
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = _jsonify(v[k])
		return out
	return v


## Sends `msg` to every connected phone, optionally skipping one peer (e.g.
## the phone that originated the message, so it doesn't get its own echo).
func _broadcast(msg: Dictionary, except_peer = null) -> void:
	for client in _clients:
		var peer: PacketPeerStream = client.peer
		if peer != except_peer:
			_peer_send(peer, msg)
	for client in _ws_clients:
		var peer = client.ws
		if peer != except_peer:
			_peer_send(peer, msg)


## Pushes one team's current resource pool to every connected phone so the
## player UI can display it. Called once per economy tick by main_screen -
## a phone that connects mid-game picks up its team's amount within a
## second, so no explicit request/response handshake is needed.
func broadcast_team_resources(team: int, amount: float) -> void:
	_broadcast({"type": "team_resources", "team": team, "amount": amount})


## The lobby message one phone gets: whether the match has started, which
## hexes THIS phone picked, and how many each team has picked (so the host's
## roster and every phone can show who is ready). Built static so
## Tests/spawn_pick.gd can check the wire shape without a socket.
static func lobby_state_message(team: int, started: bool, picks_by_team: Dictionary) -> Dictionary:
	var mine: Array = []
	for cell in picks_by_team.get(team, []):
		mine.append([cell.x, cell.y])
	var picked: Array = []
	for t in picks_by_team.keys():
		picked.append([int(t), (picks_by_team[t] as Array).size()])
	return {
		"type": "lobby_state",
		"started": started,
		"team": team,
		"hexes": mine,
		"picked": picked,
	}


## Pushes the lobby state to every phone, each getting its OWN picks (a phone
## only ever draws its own spawn hexes). Called whenever something changes:
## a phone joins/leaves, someone picks, and the moment the match starts.
##
## The latest state is CACHED, because a web phone cannot be told anything at
## the moment it joins: its WebSocket handshake is still in flight then, so
## the send is dropped. The greeting in _process() replays this cache to each
## phone the first time it reports STATE_OPEN (same reason assigned_team is
## deferred). Default is started=true: a phone is only put into spawn-picking
## mode by an explicit lobby broadcast.
func broadcast_lobby_state(started: bool, picks_by_team: Dictionary) -> void:
	_lobby_started = started
	_lobby_picks = picks_by_team
	for client in _clients:
		_peer_send(client.peer, lobby_state_message(client.team, started, picks_by_team))
	for client in _ws_clients:
		_peer_send(client.ws, lobby_state_message(client.team, started, picks_by_team))


## Call this once generate_terrain() finishes (or whenever the terrain
## changes) - sends the tiles to every currently connected phone, and caches
## them so any phone that connects/reconnects later gets them on request.
func send_terrain(tiles: Array) -> void:
	_last_tiles = tiles
	_broadcast({"type": "terrain", "tiles": tiles})


## A mine hex collapsed: tells every phone to erase that hex from its 2D
## map and advance its mining frontier one ring inward.
func broadcast_hex_destroyed(col: int, row: int) -> void:
	_broadcast({"type": "hex_destroyed", "col": col, "row": row})

## A wall marked for demolition has been torn down by the dots: tell every
## phone so the red X comes off the map.
func broadcast_wall_deleted(col: int, row: int) -> void:
	_broadcast({"type": "wall_deleted", "col": col, "row": row})
