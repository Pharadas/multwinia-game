extends Node
class_name HexGrid2DSocket
## Lives next to hex_grid_2d.gd (same instance/process as the 2D view).
## Connects to the 3D instance's HexTerrainSocket, hands off received
## terrain data to HexGrid2D, and forwards local clicks back over the wire.
##
## LAN DISCOVERY: rather than typing the main screen's IP into every phone,
## this broadcasts a short UDP message to the whole LAN asking "is anyone
## running the terrain server?". Whichever machine replies (see
## HexTerrainSocket._poll_discovery()) is used as the connection target -
## the IP comes from where the reply arrived FROM, not from typed config.
## Set use_lan_discovery = false to fall back to the old behavior of
## connecting straight to a manually-set `host` (e.g. "127.0.0.1" for
## same-machine testing).

## Manually-set target - only used if use_lan_discovery is false, or as the
## last-known-good address discovery fills in once a reply arrives.
@export var host: String = "127.0.0.1"
## Must match HexTerrainSocket.port on the main screen.
@export var port: int = 4242

## Whether to find the main screen automatically over the LAN instead of
## connecting straight to `host`.
@export var use_lan_discovery: bool = true
## Must match HexTerrainSocket.discovery_port.
@export var discovery_port: int = 4243
## How often to (re-)broadcast a discovery request while no server has been
## found yet.
@export var discovery_broadcast_interval: float = 1.0

## How often to retry the TCP connection if not connected (seconds). The
## two instances are separate processes with no guaranteed startup order,
## so the first connect_to_host() attempt very plausibly happens before the
## 3D server is even listening yet - that attempt fails, and StreamPeerTCP
## does NOT retry on its own, so without this it just sits disconnected
## forever.
@export var retry_interval: float = 1.0
## How many seconds to wait for a LAN discovery reply before giving up
## and falling back to connecting directly to `host` (127.0.0.1).
## On the same machine, UDP broadcasts to 255.255.255.255 often don't
## loop back, so without this fallback the phone hangs forever.
@export var discovery_timeout: float = 3.0
## The HexGrid2D node in THIS instance to push received terrain data into.
@export var hex_grid_2d_path: NodePath
## Emitted whenever a "terrain" message arrives, in case anything else wants
## the raw tile array without going through HexGrid2D.
signal terrain_received(tiles: Array)

## Exact bytes expected on each side of the discovery handshake - see
## matching constants in HexTerrainSocket.
const DISCOVERY_REQUEST := "HEX_TERRAIN_DISCOVER"
const DISCOVERY_REPLY_PREFIX := "HEX_TERRAIN_HERE:"

var _tcp := StreamPeerTCP.new()
var _peer: PacketPeerStream = null
var _was_connected := false
var _retry_elapsed := 0.0

var _discovery_udp := PacketPeerUDP.new()
var _discovery_elapsed := 0.0
var _server_found := false
var _discovery_total_elapsed := 0.0

func _ready() -> void:
	_peer = PacketPeerStream.new()
	_peer.stream_peer = _tcp

	if use_lan_discovery:
		_start_discovery()
	else:
		_try_connect()

func _start_discovery() -> void:
	_discovery_total_elapsed = 0.0
	_discovery_udp.set_broadcast_enabled(true)
	# Bind to any free local port - we only need an outgoing socket that can
	# also receive the reply that comes back to it.
	var err := _discovery_udp.bind(0)
	if err != OK:
		push_error("HexGrid2DSocket: couldn't open UDP socket for discovery (error %d)." % err)
		_try_connect() # fall back to manually-set host
		return
	_broadcast_discovery_request()

func _broadcast_discovery_request() -> void:
	_discovery_udp.set_dest_address("255.255.255.255", discovery_port)
	_discovery_udp.put_packet(DISCOVERY_REQUEST.to_utf8_buffer())
	print("HexGrid2DSocket: broadcast discovery request on UDP %d." % discovery_port)

func _try_connect() -> void:
	var err := _tcp.connect_to_host(host, port)
	print("HexGrid2DSocket: connecting to %s:%d -> %s" % [host, port, error_string(err)])

func _process(delta: float) -> void:
	if use_lan_discovery and not _server_found:
		_poll_discovery(delta)
		return # nothing to do on the TCP side until a server is found

	_tcp.poll()
	var status := _tcp.get_status()
	match status:
		StreamPeerTCP.STATUS_CONNECTED:
			if not _was_connected:
				print("HexGrid2DSocket: connected to terrain server.")
				_peer.put_var({"type": "request_terrain"})
			_was_connected = true
			_retry_elapsed = 0.0
			while _peer.get_available_packet_count() > 0:
				_handle_message(_peer.get_var())
		StreamPeerTCP.STATUS_CONNECTING:
			_was_connected = false
			# Give it time to finish the handshake - no retry needed yet.
		_: # STATUS_NONE or STATUS_ERROR - not connected, and never will be
		   # again on its own.
			if _was_connected:
				print("HexGrid2DSocket: disconnected from terrain server.")
			_was_connected = false
			_retry_elapsed += delta
			if _retry_elapsed >= retry_interval:
				_retry_elapsed = 0.0
				print("HexGrid2DSocket: retrying connection (status was %d)..." % status)
				_tcp.disconnect_from_host()
				if use_lan_discovery:
					# The server's IP may have changed (different network,
					# restarted machine, etc) - look for it again from
					# scratch rather than assuming the old address still
					# holds.
					_server_found = false
					_start_discovery()
				else:
					_try_connect()

## Listens for a discovery reply and, once one arrives, switches over to
## the normal TCP connect flow using whatever IP it came from.
func _poll_discovery(delta: float) -> void:
	while _discovery_udp.get_available_packet_count() > 0:
		var packet := _discovery_udp.get_packet()
		var text := packet.get_string_from_utf8()
		if not text.begins_with(DISCOVERY_REPLY_PREFIX):
			continue

		var found_host := _discovery_udp.get_packet_ip()
		var found_port := text.trim_prefix(DISCOVERY_REPLY_PREFIX).to_int()
		if found_port <= 0:
			continue

		print("HexGrid2DSocket: found terrain server at %s:%d." % [found_host, found_port])
		host = found_host
		port = found_port
		_server_found = true
		_discovery_udp.close()
		_try_connect()
		return

	_discovery_elapsed += delta
	_discovery_total_elapsed += delta
	if _discovery_total_elapsed >= discovery_timeout:
		print("HexGrid2DSocket: discovery timed out after %.1fs, falling back to %s:%d." % [discovery_timeout, host, port])
		_discovery_udp.close()
		_server_found = true
		_try_connect()
		return

	if _discovery_elapsed >= discovery_broadcast_interval:
		_discovery_elapsed = 0.0
		_broadcast_discovery_request()

func _get_grid_2d() -> Node:
	if hex_grid_2d_path != NodePath():
		var node := get_node_or_null(hex_grid_2d_path)
		if node:
			return node
	return get_parent()

func _handle_message(msg) -> void:
	if typeof(msg) != TYPE_DICTIONARY or not msg.has("type"):
		return

	var grid_2d := _get_grid_2d()

	if msg.type == "terrain":
		var tiles: Array = msg.tiles
		terrain_received.emit(tiles)
		if grid_2d and grid_2d.has_method("populate_from_data"):
			grid_2d.populate_from_data(tiles)
		return

	# Lightweight, high-frequency counterpart to "terrain" - only carries
	# darwinian counts, so it updates just the affected labels instead of
	# rebuilding the whole grid (tiles/colors/roads) on every message.
	# Adjust the "type" string here if the 3D side sends it under a
	# different name.
	if msg.type == "darwinian_counts":
		var tiles: Array = msg.tiles
		if grid_2d and grid_2d.has_method("update_darwinian_counts"):
			grid_2d.update_darwinian_counts(tiles)
		return

	# The main screen assigns this the moment our TCP connection is
	# accepted (see HexTerrainSocket._assign_team()) - nothing on this end
	# has to request it or figure it out itself beyond just listening here.
	if msg.type == "assigned_team":
		var team: int = msg.team
		print("HexGrid2DSocket: assigned team %d." % team)
		if grid_2d:
			grid_2d.team_number = team
		return

## Called by HexGrid2D when a cell is clicked - tells the 3D side which
## tile to run its click function on.
func send_tile_clicked(col: int, row: int, team_number: int) -> void:
	#print("sending info col and row from phone socket!")
	if _peer and _was_connected:
		_peer.put_var({"type": "tile_clicked", "col": col, "row": row, "team": team_number})
## Called by HexGrid2D when the local player connects two tiles - tells the
## server, which applies it to the 3D terrain and rebroadcasts it to every
## OTHER connected phone.
func send_new_connection(from_cell: Vector2i, to_cell: Vector2i, team_number: int, path: Array = []) -> void:
	print("sending new connection from phone socket!", from_cell, to_cell)
	if _peer and _was_connected:
		_peer.put_var({"type": "new_road", "from_cell": from_cell, "to_cell": to_cell, "team": team_number, "path": path})
## Called by HexGrid2D when a road is removed - mirror of
## send_new_connection() for deletions. Type string matches
## HexTerrainSocket's "remove_road" match arm.
func send_connection_removed(from_cell: Vector2i, to_cell: Vector2i, team_number: int) -> void:
	print("sending connection removal from phone socket!", from_cell, to_cell)
	if _peer and _was_connected:
		_peer.put_var({"type": "remove_road", "from_cell": from_cell, "to_cell": to_cell, "team": team_number})

## Called by HexGrid2D when the player clicks the reset roads button - tells the
## server to remove all roads for this team.
func send_clear_roads(team_number: int) -> void:
	print("sending clear roads request from phone socket for team ", team_number)
	if _peer and _was_connected:
		_peer.put_var({"type": "clear_roads", "team": team_number})
