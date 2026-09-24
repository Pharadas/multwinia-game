extends SceneTree

## Headless test for the web phone's connection targeting:
##   godot --headless -s res://Tests/connect_resolve.gd
##
## Covers the two things that decide whether a browser phone can reach the
## game at all:
##   1. HexGrid2DSocket.resolve_web_target() - which host/scheme/port a page
##      resolves to, for every kind of page it can be hosted on (plain HTTP
##      on the game machine, HTTPS on a CDN, query-param overrides, typed
##      addresses).
##   2. HexTerrainSocket._assign_team() - the server handing out team numbers
##      across BOTH transports (native TCP + web WebSocket) from one pool.
##   3. That the assigned team actually REACHES the phone facade, which is
##      what filters the resource HUD and tags every outgoing order.
##
## Native TCP paths need real sockets, so this is intentionally limited to
## pure logic plus one headless scene instantiation - the end-to-end browser
## test covers the live transport.

var _failures := 0
var _checks := 0

func _initialize() -> void:
	var phone := HexGrid2DSocket.new()
	var server := HexTerrainSocket.new()

	print("=== resolve_web_target ===")
	_test_resolution(phone)
	print("=== _assign_team (both transports) ===")
	_test_team_assignment(server)
	print("=== LAN sweep candidates ===")
	_test_sweep_candidates()
	print("=== discovery reply parsing ===")
	_test_discovery_reply()
	print("=== facade learns its team ===")
	_test_facade_team_sync()
	print("=== server's assignment message ===")
	_test_assignment_message()
	phone.free()
	server.free()

	print("")
	if _failures == 0:
		print("OK - %d checks passed" % _checks)
		quit(0)
	else:
		print("FAILED - %d of %d checks failed" % [_failures, _checks])
		quit(1)


# --- 1c. browser LAN sweep candidates ----------------------------------------

## The web phone can't broadcast UDP, so it scans the page host's own /24 for
## a game. That scan must stay inside the LAN: a public page host (itch.io, a
## CDN, a bare IP on the internet) has no subnet worth probing, and on an
## HTTPS page every ws:// is blocked before it leaves the browser anyway.
func _test_sweep_candidates() -> void:
	var lan: Array = HexGrid2DSocket.sweep_candidates("192.168.1.82")
	_check("lan /24 size", str(lan.size()), "253")
	_check("skips the page host itself", str(lan.has("192.168.1.82")), "false")
	_check("includes the first host", str(lan.has("192.168.1.1")), "true")
	_check("includes the last host", str(lan.has("192.168.1.254")), "true")
	_check("nothing outside the subnet",
		str(lan.all(func(a): return str(a).begins_with("192.168.1."))), "true")
	_check("10.x /24 size", str(HexGrid2DSocket.sweep_candidates("10.0.0.5").size()), "253")
	_check("172.16.x is private", str(HexGrid2DSocket.sweep_candidates("172.16.5.5").size()), "253")
	_check("172.32.x is not private", str(HexGrid2DSocket.sweep_candidates("172.32.5.5").size()), "0")
	# A dead address the socket is already retrying must not be probed twice.
	var skipped: Array = HexGrid2DSocket.sweep_candidates("192.168.1.82",
			["192.168.1.82", "192.168.1.10"])
	_check("skip list honoured",
		"%d/%s" % [skipped.size(), str(skipped.has("192.168.1.10"))], "252/false")
	# Nothing to sweep: a public IPv4, a hostname, an IPv6 literal, empty.
	_check("public IPv4", str(HexGrid2DSocket.sweep_candidates("8.8.8.8").size()), "0")
	_check("hostname", str(HexGrid2DSocket.sweep_candidates("pharadas.itch.io").size()), "0")
	_check("IPv6 literal", str(HexGrid2DSocket.sweep_candidates("fe80::1").size()), "0")
	_check("empty host", str(HexGrid2DSocket.sweep_candidates("").size()), "0")
	_check("over-long octet", str(HexGrid2DSocket.sweep_candidates("192.168.1.999").size()), "0")


# --- 1b. discovery reply parsing --------------------------------------------

func _test_discovery_reply() -> void:
	# (label, payload, expected tcp port, expected ws port) - 0 means "rejected".
	var cases: Array = [
		# Current server: both ports. to_int() on this exact string used to
		# yield 42429080, so every native phone on the LAN gave up on its
		# discovered server and fell back to 127.0.0.1.
		["current server (tcp:ws)", "HEX_TERRAIN_HERE:4242:9080", 4242, 9080],
		["custom ports", "HEX_TERRAIN_HERE:5000:6000", 5000, 6000],
		# Servers older than the WebSocket transport only send one field.
		["old server (tcp only)", "HEX_TERRAIN_HERE:4242", 4242, 9080],
		["old server, custom port", "HEX_TERRAIN_HERE:5555", 5555, 9080],
		# Junk must be rejected, never dialled: a bad port is an opaque
		# engine error at connect time.
		["wrong prefix", "HEX_TERRAIN_HI:4242:9080", 0, 0],
		["empty payload", "HEX_TERRAIN_HERE:", 0, 0],
		["non-numeric port", "HEX_TERRAIN_HERE:abc:9080", 0, 0],
		["port too large", "HEX_TERRAIN_HERE:70000:9080", 0, 0],
		["port zero", "HEX_TERRAIN_HERE:0:9080", 0, 0],
		# A broken second field must not cost us a good TCP port.
		["bad ws field, good tcp", "HEX_TERRAIN_HERE:4242:xyz", 4242, 9080],
		["ws port out of range", "HEX_TERRAIN_HERE:4242:99999", 4242, 9080],
	]
	for case in cases:
		var label: String = case[0]
		var reply := HexGrid2DSocket.parse_discovery_reply(case[1], 9080)
		var got := "%d/%d" % [int(reply.get("port", 0)), int(reply.get("websocket_port", 0))]
		_check("reply %s" % label, got, "%d/%d" % [case[2], case[3]])


# --- 1. URL resolution -------------------------------------------------------

func _test_resolution(phone: HexGrid2DSocket) -> void:
	# (label, page href, page hostname, protocol, typed override, expected url)
	var cases: Array = [
		# --- plain-HTTP page served BY the game machine (the LAN case) ---
		["lan page", "http://192.168.1.82:8000/index.html", "192.168.1.82", "http:", "",
			"ws://192.168.1.82:9080"],
		# A stray query param must not disable the hostname fallback.
		["lan page + unrelated query", "http://192.168.1.82:8000/index.html?x=1",
			"192.168.1.82", "http:", "", "ws://192.168.1.82:9080"],
		# localhost is never the LAN address to dial - use the exported host.
		["lan page on localhost", "http://localhost:8000/index.html", "localhost", "http:", "",
			"ws://127.0.0.1:9080"],
		["?host= on http page", "http://192.168.1.82:8000/?host=203.0.113.7", "192.168.1.82",
			"http:", "", "ws://203.0.113.7:9080"],
		["?host=&port= on http page", "http://192.168.1.82:8000/?host=203.0.113.7&port=9100",
			"192.168.1.82", "http:", "", "ws://203.0.113.7:9100"],
		# Fragment must not glue itself onto the last query value.
		["?host= with fragment", "http://192.168.1.82:8000/?host=10.0.0.5#frag", "192.168.1.82",
			"http:", "", "ws://10.0.0.5:9080"],

		# --- HTTPS page on a CDN (github.io / itch.io) ---------------------
		# No address supplied, and ws:// would be blocked as mixed content:
		# nothing to dial, the connect screen is the way in.
		["https cdn page, no target", "https://pharadas.github.io/multiwinia-game/",
			"pharadas.github.io", "https:", "", ""],
		# A typed wss:// tunnel URL has NO port - appending the LAN ws port
		# would produce wss://host:9080 which can never answer.
		["typed wss tunnel (no port)",
			"https://pharadas.github.io/multiwinia-game/", "pharadas.github.io", "https:",
			"wss://abc.trycloudflare.com", "wss://abc.trycloudflare.com"],
		["typed wss tunnel + path",
			"https://pharadas.itch.io/multiwinian", "pharadas.itch.io", "https:",
			"wss://abc.trycloudflare.com/phone/", "wss://abc.trycloudflare.com"],
		["typed wss tunnel with port", "https://pharadas.itch.io/multiwinian",
			"pharadas.itch.io", "https:", "wss://tunnel.example.com:8443",
			"wss://tunnel.example.com:8443"],
		# Schemeless entry on a secure page: ws:// could never work, so wss.
		["typed bare host on https page", "https://pharadas.itch.io/multiwinian",
			"pharadas.itch.io", "https:", "tunnel.example.com", "wss://tunnel.example.com"],
		# Explicitly typed ws:// is honoured (player knows better).
		["typed explicit ws:// on https page", "https://pharadas.itch.io/multiwinian",
			"pharadas.itch.io", "https:", "ws://192.168.1.82:9080",
			"ws://192.168.1.82:9080"],
		# Typed bare host on a LAN page keeps ws:// and the ws port.
		["typed bare host on http page", "http://192.168.1.82:8000/index.html",
			"192.168.1.82", "http:", "203.0.113.7", "ws://203.0.113.7:9080"],
		["typed host:port on http page", "http://192.168.1.82:8000/index.html",
			"192.168.1.82", "http:", "203.0.113.7:9999", "ws://203.0.113.7:9999"],
		# ?url= wins over ?host= and carries its scheme.
		["?url= beats ?host=", "http://192.168.1.82:8000/?url=ws://10.1.1.1:9081&host=9.9.9.9",
			"192.168.1.82", "http:", "", "ws://10.1.1.1:9081"],
		["?url= wss on https page", "https://pharadas.itch.io/multiwinian?url=wss://abc.trycloudflare.com",
			"pharadas.itch.io", "https:", "", "wss://abc.trycloudflare.com"],
		# Query host on an https page: scheme follows the page (wss).
		["?host= on https page", "https://pharadas.itch.io/multiwinian?host=203.0.113.7&port=9080",
			"pharadas.itch.io", "https:", "", "wss://203.0.113.7:9080"],
	]

	for case in cases:
		var label: String = case[0]
		phone.parse_remote_target(case[4])
		var got: Dictionary = phone.resolve_web_target(case[1], case[2], case[3])
		_check(label, str(got.url), str(case[5]))

	# Clearing the override must fall back to automatic resolution.
	phone.parse_remote_target("wss://abc.trycloudflare.com")
	_check("override set", str(phone.resolve_web_target(
			"https://pharadas.itch.io/x", "pharadas.itch.io", "https:").url),
			"wss://abc.trycloudflare.com")
	phone.parse_remote_target("")
	_check("override cleared", str(phone.resolve_web_target(
			"http://192.168.1.82:8000/index.html", "192.168.1.82", "http:").url),
			"ws://192.168.1.82:9080")

	# The reported source is what the UI/logs use to explain the choice.
	phone.parse_remote_target("wss://abc.trycloudflare.com")
	_check("source is manual", str(phone.resolve_web_target("", "", "").source), "manual")
	phone.parse_remote_target("")
	_check("source is page host", str(phone.resolve_web_target(
			"http://192.168.1.82:8000/", "192.168.1.82", "http:").source), "page host")
	_check("source is none on https", str(phone.resolve_web_target(
			"https://pharadas.itch.io/x", "pharadas.itch.io", "https:").source), "none")

	# The TLS flag must match the URL scheme (the UI shows it).
	phone.parse_remote_target("wss://abc.trycloudflare.com")
	var t: Dictionary = phone.resolve_web_target("https://x.io/", "x.io", "https:")
	_check("tls flag true", str(t.tls), "true")
	_check("include_port false", str(t.include_port), "false")
	phone.parse_remote_target("")


# --- 2. team assignment ------------------------------------------------------

func _test_team_assignment(server: HexTerrainSocket) -> void:
	server.max_teams = 4

	# A native phone already holds team 0; the next WEB phone must get 1.
	var native := {"peer": null, "team": 0}
	server._clients = [native]
	var web := {"ws": null, "team": -1}
	server._ws_clients = [web]
	server._assign_team(web)
	_check("web phone after native phone", str(web.team), "1")

	# And the reverse: a web phone holds team 0, the next native phone gets 1.
	var web0 := {"ws": null, "team": 0}
	server._ws_clients = [web0]
	var native2 := {"peer": null, "team": -1}
	server._clients = [native2]
	server._assign_team(native2)
	_check("native phone after web phone", str(native2.team), "1")

	# A freed team number is reused.
	var native3 := {"peer": null, "team": -1}
	server._clients = [{"peer": null, "team": 0}]
	server._assign_team(native3)
	_check("freed team reused", str(native3.team), "1")

	# Filling up: teams 0 and 1 taken -> next is 2.
	server._clients = [{"peer": null, "team": 0}, {"peer": null, "team": 1}]
	var third := {"peer": null, "team": -1}
	server._assign_team(third)
	_check("next free team", str(third.team), "2")

	server._clients = []
	server._ws_clients = []


## The message the main screen hands a joining phone, and the palette it is
## built from: the phone must be told the SAME color the main screen shows,
## otherwise a player sees a different color than their army on the map.
func _test_assignment_message() -> void:
	var msg := HexTerrainSocket.assigned_team_message(2)
	_check("message type", str(msg.get("type")), "assigned_team")
	_check("message team", str(msg.get("team")), "2")
	var color: Array = msg.get("color", [])
	_check("color is 3 floats", str(color.size()), "3")
	_check("color matches the palette",
			_color_str(Color(float(color[0]), float(color[1]), float(color[2]))),
			_color_str(HexBuildingManager.team_color(2)))
	# Team 0's classic color, so a regression in the palette is visible here.
	var c0 := HexBuildingManager.team_color(0)
	_check("team 0 is red", _color_str(c0), "0.90,0.20,0.20")


# --- 3. the assigned team reaches the facade ---------------------------------

## The socket reports the assigned team by writing it onto the node it treats
## as the 2D grid - and in the phone scene that node IS the facade
## (MainPhoneView implements the grid interface, and the socket's grid lookup
## falls back to its parent). So the facade's team_number follows the
## assignment, which is what it filters the resource HUD by and tags every
## outgoing order with. Locked in here because the failure is silent and
## lopsided: if that lookup ever resolves to a separate grid node instead,
## every phone is left at its team-0 default and a team-1/2/3 player watches
## someone else's resource pool all match.
func _test_facade_team_sync() -> void:
	var packed := load("res://Phone/MainPhoneView.tscn") as PackedScene
	if packed == null:
		_check("phone scene loadable", "null", "PackedScene")
		return
	var view := packed.instantiate()
	root.add_child(view)
	var socket = view._get_socket_node() if view.has_method("_get_socket_node") else null
	if socket == null:
		_check("phone exposes its socket", "no", "yes")
		view.queue_free()
		return
	_check("facade starts at team 0", str(view.team_number), "0")

	# The assignment carries the team's color, so the phone can show "you are
	# the green team" without keeping its own copy of the palette. (What the
	# HUD *does* with it is covered by Tests/phone_hud.gd - the phone's UI is
	# built in _ready(), which hasn't run yet at this point in a headless run.)
	socket._handle_message({"type": "assigned_team", "team": 2, "color": [0.2, 0.8, 0.2]})
	_check("facade follows assignment", str(view.team_number), "2")
	_check("facade took the team color", _color_str(view.team_color), "0.20,0.80,0.20")

	# Every reconnect re-announces the team - the facade must follow that too.
	socket._handle_message({"type": "assigned_team", "team": 1, "color": [0.2, 0.8, 0.2]})
	_check("facade follows re-assignment", str(view.team_number), "1")

	# A server that predates the color field: neutral grey, not a broken HUD.
	socket._handle_message({"type": "assigned_team", "team": 3})
	_check("missing color falls back to grey", _color_str(view.team_color), "0.75,0.75,0.78")
	view.queue_free()


func _color_str(c: Color) -> String:
	return "%.2f,%.2f,%.2f" % [c.r, c.g, c.b]


# --- harness -----------------------------------------------------------------

func _check(label: String, got: String, want: String) -> void:
	_checks += 1
	if got == want:
		print("  PASS %-38s %s" % [label, got])
		return
	_failures += 1
	print("  FAIL %-38s got \"%s\" want \"%s\"" % [label, got, want])
