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
##
## WEB EXPORTS: browsers can't open raw TCP or UDP sockets, so on web
## builds (OS.has_feature("web")) this socket switches to a WebSocketPeer
## pointed at the main screen's WebSocket server (HexTerrainSocket's
## `websocket_port`). The message format is IDENTICAL (put_var/get_var
## dictionaries) - only the pipe changes, so every view script works
## unchanged in the browser. The target is resolved, in order, from:
##   1. the UI override (connect screen), if the player typed one
##   2. the page URL query: ?url=wss://... (verbatim) or ?host=IP&port=N
##   3. the page's own hostname - ONLY on plain-HTTP pages (i.e. the
##      export is hosted on the game machine); HTTPS hosts like github.io
##      or itch.io are CDNs, never the game server
##   4. the exported `host` as a last resort
##   The scheme follows the page protocol: HTTPS pages dial wss:// (browsers
##   block ws:// from secure pages), HTTP pages dial ws://.
## UDP LAN discovery is impossible in a browser, so it's skipped there.

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
## WebSocket port on the main screen - only used on WEB builds (must match
## HexTerrainSocket.websocket_port). Native builds keep using raw TCP.
@export var websocket_port: int = 9080
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
## Emitted whenever the 3D side broadcasts a team's resource pool (once per
## economy tick). `amount` is this phone's team's current resource count.
signal team_resources_received(team: int, amount: float)

## Emitted whenever the WebSocket goes up or down (web builds). The UI uses
## it to show/hide the manual-connect screen.
signal connection_state_changed(connected: bool)

## Emitted when the main screen hands this phone its team, with that team's
## color (the main screen owns the palette - see its assigned_team_message()).
## The UI shows it so a player always knows which army is theirs.
signal team_assigned(team: int, color: Color)

## The lobby state the main screen broadcasts: whether the match has
## started, this phone's own spawn hexes, and how many hexes each team has
## picked. Sent on join, on every pick and the moment the match starts -
## the phone shows its spawn picker while `started` is false and hides it
## afterwards.
signal lobby_state_received(started: bool, hexes: Array, picked: Array)

## Exact bytes expected on each side of the discovery handshake - see
## matching constants in HexTerrainSocket.
const DISCOVERY_REQUEST := "HEX_TERRAIN_DISCOVER"
const DISCOVERY_REPLY_PREFIX := "HEX_TERRAIN_HERE:"

var _tcp := StreamPeerTCP.new()
var _peer: PacketPeerStream = null
var _was_connected := false
var _retry_elapsed := 0.0

# --- web transport (WebSocketPeer, web exports only) -------------------------
var _is_web: bool = OS.has_feature("web")
var _ws := WebSocketPeer.new()
var _ws_url := ""
var _ws_retry_elapsed := 0.0
## Manual UI override for the WS host - non-empty wins over all URL resolution.
var remote_host_override := ""
## TLS flag for the override: true when the typed address was wss:// (needed
## whenever the page itself is HTTPS - itch.io, GitHub Pages - because
## browsers block insecure ws:// from secure pages as mixed content).
var remote_use_tls := false
## True when the typed address carried an explicit scheme (ws:// / wss://).
## A schemeless entry on an HTTPS page is forced to wss, since ws:// from a
## secure page can never work.
var remote_scheme_explicit := false
## Port typed as part of the address ("host:9080"); 0 = none given.
var remote_explicit_port := 0

var _discovery_udp := PacketPeerUDP.new()
var _discovery_elapsed := 0.0
var _server_found := false
var _discovery_total_elapsed := 0.0

func _ready() -> void:
	if _is_web:
		# Browsers: no TCP, no UDP - WebSocket only. Discovery is skipped.
		_ws_url = _resolve_web_url()
		_connect_websocket()
		return
	_peer = PacketPeerStream.new()
	_peer.stream_peer = _tcp
	# Match the server's buffer size so large terrain packets can pass through.
	_peer.output_buffer_max_size = 4 * 1024 * 1024
	_peer.input_buffer_max_size = 4 * 1024 * 1024

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
	# Last-ditch guard: a port outside the valid range (a mis-parsed discovery
	# reply, a bad typed address) only produces an opaque engine error from
	# connect_to_host, so reject it where the cause is still visible.
	if port <= 0 or port > 65535:
		push_error("HexGrid2DSocket: invalid port %d for host \"%s\" - not connecting." % [port, host])
		return
	var err := _tcp.connect_to_host(host, port)
	print("HexGrid2DSocket: connecting to %s:%d -> %s" % [host, port, error_string(err)])

func _process(delta: float) -> void:
	if _is_web:
		_process_websocket(delta)
		return
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
				emit_signal("connection_state_changed", true)
			while _peer.get_available_packet_count() > 0:
				_handle_message(_peer.get_var())
		StreamPeerTCP.STATUS_CONNECTING:
			_was_connected = false
			# Give it time to finish the handshake - no retry needed yet.
		_: # STATUS_NONE or STATUS_ERROR - not connected, and never will be
		   # again on its own.
			if _was_connected:
				print("HexGrid2DSocket: disconnected from terrain server.")
				emit_signal("connection_state_changed", false)
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

## --- WEB EXPORT TRANSPORT (WebSocket) ---------------------------------------

## Decides where the WebSocket should connect. Deliberately free of browser
## APIs so Tests/connect_resolve.gd can drive it with synthetic
## window.location values. Returns a Dictionary:
##   {url, host, port, tls, include_port, source, usable}
## `url` is empty when there is nothing worth dialing (see the HTTPS note
## under 4); `include_port` false means the scheme's default port is used
## implicitly (443 for wss), which is what TLS tunnels need - their public
## URLs carry no port at all.
##
## Resolution order:
##   1. the address typed into the connect screen (UI override)
##   2. the page URL query: ?url=wss://... (verbatim) or ?host=IP&port=N
##   3. the page's own hostname - ONLY on plain-HTTP pages, i.e. the export
##      is served BY the game machine; an HTTPS hostname is a CDN and can
##      never be the game server
##   4. the exported `host`, again only when a plain ws:// can leave the
##      page. On an HTTPS page ws:// is blocked as mixed content, so with
##      no address supplied the result is unusable and the connect screen
##      takes over instead of dialing a guaranteed failure.
func resolve_web_target(page_href: String, page_hostname: String,
		page_protocol: String) -> Dictionary:
	var page_https := page_protocol.begins_with("https")

	# 1. Address typed into the connect screen.
	if not remote_host_override.is_empty():
		var tls := remote_use_tls
		if not remote_scheme_explicit and page_https:
			# ws:// from a secure page is blocked before it leaves the
			# browser, so a schemeless entry is treated as wss.
			tls = true
		if remote_explicit_port > 0:
			return _target(remote_host_override, remote_explicit_port, tls, true, "manual")
		if tls:
			# TLS endpoints (Cloudflare tunnels, reverse proxies) answer on
			# 443 - appending the LAN ws port would break them.
			return _target(remote_host_override, 443, true, false, "manual")
		return _target(remote_host_override, websocket_port, false, true, "manual")

	# 2. Query params on the page URL (?url= wins over ?host=).
	var params := _parse_query(page_href)
	var url_param := str(params.get("url", "")).strip_edges()
	if not url_param.is_empty():
		var tls := url_param.begins_with("wss://")
		var body := url_param.trim_prefix("wss://").trim_prefix("ws://")
		var slash := body.find("/")
		if slash >= 0:
			body = body.substr(0, slash)
		var port := 0
		var colon := body.rfind(":")
		if colon > 0:
			port = body.substr(colon + 1).to_int()
			if port > 0:
				body = body.substr(0, colon)
		if not body.is_empty():
			if port > 0:
				return _target(body, port, tls, true, "?url=")
			return _target(body, 443 if tls else websocket_port, tls, not tls, "?url=")
	var host_param := str(params.get("host", "")).strip_edges()
	if not host_param.is_empty():
		var port := int(str(params.get("port", websocket_port)))
		if port <= 0:
			port = websocket_port
		return _target(host_param, port, page_https, true, "?host=")

	# 3. The page's own hostname - plain-HTTP pages only (see the header).
	if not page_https and not page_hostname.is_empty() \
			and page_hostname != "localhost" and page_hostname != "127.0.0.1":
		return _target(page_hostname, websocket_port, false, true, "page host")

	# 4. The exported `host`, when a plain ws:// can actually leave the page.
	if not page_https:
		return _target(host, websocket_port, false, true, "exported host")

	return _target("", websocket_port, false, false, "none")


## Builds one resolution result. Single place that formats the URL, so the
## override / query / fallback paths can't drift apart.
func _target(h: String, port: int, tls: bool, include_port: bool, source: String) -> Dictionary:
	var url := ""
	if not h.is_empty():
		var scheme := "wss" if tls else "ws"
		url = ("%s://%s:%d" % [scheme, h, port]) if include_port else ("%s://%s" % [scheme, h])
	return {
		"url": url,
		"host": h,
		"port": port,
		"tls": tls,
		"include_port": include_port,
		"source": source,
		"usable": not url.is_empty(),
	}


## Parses the query string of a page URL into decoded key/value strings.
## The fragment is dropped first - otherwise it glues itself onto the last
## value ("?host=1.2.3.4#foo" -> "1.2.3.4#foo").
func _parse_query(href: String) -> Dictionary:
	var out := {}
	var query := href
	var hash := query.find("#")
	if hash >= 0:
		query = query.substr(0, hash)
	var qi := query.find("?")
	if qi < 0:
		return out
	for pair in query.substr(qi + 1).split("&", false):
		var kv := pair.split("=", true, 1)
		if kv.size() != 2:
			continue
		out[kv[0]] = kv[1].uri_decode()
	return out


## The resolved URL the phone will dial next. Empty string = nothing to
## dial yet (the connect screen is the way in).
func _resolve_web_url() -> String:
	if not OS.has_feature("web"):
		return "ws://%s:%d" % [host, websocket_port]
	# JavaScriptBridge.eval returns JS objects as opaque JavaScriptObjects -
	# NOT GDScript Dictionaries - so pull out plain strings instead.
	var target := resolve_web_target(
			str(JavaScriptBridge.eval("window.location.href", true)),
			str(JavaScriptBridge.eval("window.location.hostname", true)),
			str(JavaScriptBridge.eval("window.location.protocol", true)))
	return str(target.url)

func _connect_websocket() -> void:
	# The terrain message is well over the 64 KB default WS buffers (Godot
	# silently breaks above it) - match the 4 MB the TCP path uses.
	_ws.inbound_buffer_size = 4 * 1024 * 1024
	_ws.outbound_buffer_size = 4 * 1024 * 1024
	if _ws_url.is_empty():
		# Nothing usable to dial yet - e.g. the page is hosted on an HTTPS
		# CDN and no game address has been supplied. Retrying a guaranteed
		# failure once a second just spams the console; the connect screen
		# is what gets the player in.
		return
	var err := _ws.connect_to_url(_ws_url)
	if err == OK:
		print("HexGrid2DSocket: WebSocket connecting to %s ..." % _ws_url)
	else:
		print("HexGrid2DSocket: WebSocket connect failed (error %d), retrying..." % err)

func _process_websocket(delta: float) -> void:
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_connected:
			_was_connected = true
			_ws_retry_elapsed = 0.0
			print("HexGrid2DSocket: WebSocket connected to %s." % _ws_url)
			emit_signal("connection_state_changed", true)
			_ws.send_text(JSON.stringify({"type": "request_terrain"}))
		while _ws.get_available_packet_count() > 0:
			var parsed: Variant = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
			if parsed is Dictionary:
				_handle_message(_deref_json(parsed))
	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_connected:
			print("HexGrid2DSocket: WebSocket closed - retrying every %.1fs." % retry_interval)
			emit_signal("connection_state_changed", false)
		_was_connected = false
		_ws_retry_elapsed += delta
		if _ws_retry_elapsed >= retry_interval:
			_ws_retry_elapsed = 0.0
			_connect_websocket()

func _ws_send(msg: Dictionary) -> void:
	if _is_web and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(_jsonify(msg)))

## Manual override from the UI: point the WebSocket at a typed address,
## then reconnect immediately. Accepts "IP", "IP:port", "ws://IP:port",
## "wss://IP:port" or a full URL (wss is REQUIRED when the page itself is
## served over HTTPS - itch.io, GitHub Pages - otherwise the browser blocks
## the connection as mixed content). Overrides every automatic URL
## resolution - call with an empty string to go back to automatic.
func set_remote_target(target: String, new_port: int = 0) -> void:
	if not _is_web:
		return
	parse_remote_target(target, new_port)
	if not remote_host_override.is_empty():
		print("HexGrid2DSocket: manual target override -> %s (from \"%s\")"
				% [_resolve_web_url(), target.strip_edges()])
	else:
		print("HexGrid2DSocket: manual target cleared - back to automatic resolution.")
	reconnect_websocket()


## Parses a typed address into the override state, WITHOUT connecting -
## split out from set_remote_target() so Tests/connect_resolve.gd can
## exercise the parsing headlessly. Accepts "IP", "IP:port",
## "ws://host[:port][/path]" and "wss://host[:port][/path]"; an empty
## string clears the override and returns to automatic resolution.
func parse_remote_target(target: String, new_port: int = 0) -> void:
	var t := target.strip_edges()
	# Full URL form: pull host:port out of it and remember the scheme.
	remote_use_tls = false
	remote_scheme_explicit = false
	remote_explicit_port = new_port if new_port > 0 else 0
	if t.begins_with("wss://"):
		remote_use_tls = true
		remote_scheme_explicit = true
		t = t.trim_prefix("wss://")
	elif t.begins_with("ws://"):
		remote_scheme_explicit = true
		t = t.trim_prefix("ws://")
	# Strip any path ("wss://host/whatever" -> "host"); we dial the root.
	var slash := t.find("/")
	if slash >= 0:
		t = t.substr(0, slash)
	# "host:port" form: split the port off.
	var colon := t.rfind(":")
	if colon > 0:
		var p := t.substr(colon + 1).to_int()
		if p > 0:
			remote_explicit_port = p
			t = t.substr(0, colon)
	remote_host_override = t

## Tear down the current WebSocket (if any) and start a fresh connection
## using the current target resolution. Safe to call at any time.
func reconnect_websocket() -> void:
	if not _is_web:
		return
	_ws.close()
	_ws_url = _resolve_web_url() # re-resolve: the target may have just changed
	_ws_retry_elapsed = retry_interval # force an immediate reconnect attempt
	_process_websocket(0.0)

## True while the WebSocket is open (web builds).
func is_web_connected() -> bool:
	return _is_web and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN

## The ws:// / wss:// URL the phone will dial next (for UI display). Empty
## while nothing usable has been resolved - the UI turns that into a prompt.
func get_current_ws_url() -> String:
	return _resolve_web_url()

## Human-readable explanation of where the current target came from - handy
## in the connect screen and in logs. See resolve_web_target().
func get_target_source() -> String:
	if not OS.has_feature("web"):
		return "native tcp"
	return str(resolve_web_target(
			str(JavaScriptBridge.eval("window.location.href", true)),
			str(JavaScriptBridge.eval("window.location.hostname", true)),
			str(JavaScriptBridge.eval("window.location.protocol", true))).source)

## JSON-safe conversion: put_var ships Variants (Vector2, Color...) natively
## over the TCP path, but JSON can't. Vector2/Vector2i -> [x, y],
## Color -> {r, g, b, a}. Applied recursively to every outgoing message.
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

## Inverse of _jsonify for incoming tiles: a JSON Color arrives as an
## {r,g,b,a} dict - put a real Color back so the map populator can use it.
func _deref_json(msg: Dictionary) -> Dictionary:
	if msg.get("type", "") == "terrain":
		for entry in msg.get("tiles", []):
			if entry is Dictionary and entry.get("color") is Dictionary:
				var c: Dictionary = entry.color
				entry.color = Color(float(c.get("r", 1.0)), float(c.get("g", 1.0)),
						float(c.get("b", 1.0)), float(c.get("a", 1.0)))
	return msg

## Parses the payload of a discovery reply - "<tcp_port>" from servers that
## predate the WebSocket transport, "<tcp_port>:<ws_port>" from current ones -
## into {"port": int, "websocket_port": int}, or {} for anything unusable.
##
## The fields must be split explicitly: to_int() on the whole "4242:9080"
## absorbs the colon and returns 42429080, which is not a valid port, so every
## native phone rejected its LAN server and fell back to 127.0.0.1.
## Kept static so it can be tested without real sockets (Tests/connect_resolve.gd).
static func parse_discovery_reply(text: String, fallback_ws_port: int) -> Dictionary:
	if not text.begins_with(DISCOVERY_REPLY_PREFIX):
		return {}
	var fields := text.trim_prefix(DISCOVERY_REPLY_PREFIX).split(":", false)
	if fields.is_empty():
		return {}
	var tcp_port := int(fields[0])
	if tcp_port <= 0 or tcp_port > 65535:
		return {}
	var ws_port := fallback_ws_port
	if fields.size() > 1:
		var parsed_ws := int(fields[1])
		# A malformed second field must not throw away a good TCP port.
		if parsed_ws > 0 and parsed_ws <= 65535:
			ws_port = parsed_ws
	return {"port": tcp_port, "websocket_port": ws_port}


## Listens for a discovery reply and, once one arrives, switches over to
## the normal TCP connect flow using whatever IP it came from.
func _poll_discovery(delta: float) -> void:
	while _discovery_udp.get_available_packet_count() > 0:
		var packet := _discovery_udp.get_packet()
		var text := packet.get_string_from_utf8()
		var reply := parse_discovery_reply(text, websocket_port)
		if reply.is_empty():
			continue

		var found_host := _discovery_udp.get_packet_ip()
		var found_port: int = reply["port"]
		websocket_port = reply["websocket_port"]

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

## The team color the main screen sent alongside the assignment, as [r,g,b]
## floats. A server that predates the color field just means a neutral grey
## badge instead of no badge at all.
static func _color_from_message(msg: Dictionary) -> Color:
	var arr: Variant = msg.get("color")
	if arr is Array and (arr as Array).size() >= 3:
		return Color(float(arr[0]), float(arr[1]), float(arr[2]))
	return Color(0.75, 0.75, 0.78)


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
		var team_color := _color_from_message(msg)
		print("HexGrid2DSocket: assigned team %d." % team)
		if grid_2d:
			grid_2d.team_number = team
			if "team_color" in grid_2d:
				grid_2d.team_color = team_color
		team_assigned.emit(team, team_color)
		return

	# Once-per-second economy updates from the main screen: how many
	# resources each team holds. The phone view displays its own team's
	# amount (see main_phone_view.gd).
	if msg.type == "lobby_state":
		lobby_state_received.emit(bool(msg.get("started", true)), msg.get("hexes", []),
				msg.get("picked", []))
		return

	if msg.type == "team_resources":
		team_resources_received.emit(int(msg.team), float(msg.amount))
		return

	# A mine hex collapsed on the 3D side: erase it from the 2D map and
	# recompute the mining frontier (new outermost ring becomes placeable).
	if msg.type == "hex_destroyed":
		if grid_2d and grid_2d.has_method("notify_hex_destroyed"):
			grid_2d.notify_hex_destroyed(int(msg.col), int(msg.row))
		return

	# A marked wall was torn down by the dots: drop its red X from the map.
	if msg.type == "wall_deleted":
		if grid_2d and grid_2d.has_method("notify_wall_deleted"):
			grid_2d.notify_wall_deleted(int(msg.col), int(msg.row))
		return

## Called by HexGrid2D when a cell is clicked (tap or hover) - tells the
## 3D side which tile to run its click function on.
## The hexes this phone wants its starting army divided across (lobby only,
## up to 3, in pick order). The main screen validates them - walls and hexes
## off the map are dropped there, and it echoes the accepted list back in
## the next lobby_state.
func send_spawn_hexes(cells: Array, team_number: int) -> void:
	var payload: Array = []
	for cell in cells:
		payload.append([int(cell.x), int(cell.y)])
	if _is_web:
		_ws_send({"type": "spawn_hex", "cells": payload, "team": team_number})
	else:
		_peer.put_var({"type": "spawn_hex", "cells": payload, "team": team_number})


func send_tile_clicked(col: int, row: int, team_number: int) -> void:
	if _is_web:
		_ws_send({"type": "tile_clicked", "col": col, "row": row, "team": team_number})
		return
	if _peer and _was_connected:
		_peer.put_var({"type": "tile_clicked", "col": col, "row": row, "team": team_number})
## Called by HexGrid2D when the player draws a path on the 2D grid - tells
## the 3D side to set it as the team's active path (simplified to 16
## points).
func send_drawn_path(points: Array, team_number: int, ref_cells: Array = [], ref_locals: Array = [], fraction: float = 1.0) -> void:
	if _is_web:
		_ws_send({"type": "drawn_path", "points": points, "team": team_number, "ref_cells": ref_cells, "ref_locals": ref_locals, "fraction": fraction})
		return
	if _peer and _was_connected:
		_peer.put_var({"type": "drawn_path", "points": points, "team": team_number, "ref_cells": ref_cells, "ref_locals": ref_locals, "fraction": fraction})

## Called by the building flow when a building is dropped on a hex.
## Whole-hex granularity: the main screen places the 3D mesh centered on
## that hex - there are no sub-hex coordinates.
func send_building_placed(col: int, row: int, building_id: int, team_number: int) -> void:
	if _is_web:
		_ws_send({"type": "building_placed", "col": col, "row": row, "building": building_id, "team": team_number})
		return
	if _peer and _was_connected:
		_peer.put_var({"type": "building_placed", "col": col, "row": row, "building": building_id, "team": team_number})

## Called when a player double-tapped a WALL hex: the main screen marks it
## for demolition and nearby dots tear it down.
func send_building_delete(col: int, row: int, team_number: int) -> void:
	if _is_web:
		_ws_send({"type": "building_delete", "col": col, "row": row, "team": team_number})
		return
	if _peer and _was_connected:
		_peer.put_var({"type": "building_delete", "col": col, "row": row, "team": team_number})
