extends Node
class_name WebFileServer

## A tiny static-file HTTP server that serves the exported web build over
## the LAN, straight from the game process.
##
## WHY: a web phone auto-connects to the game when the PAGE ITSELF is served
## by the game machine (see HexGrid2DSocket.resolve_web_target, case 3 - a
## plain-HTTP page dials ws://<its own host>:9080). Hosting the build on an
## external HTTPS site (itch.io) can never auto-connect - the browser blocks
## ws:// from secure pages - but a player on the same WiFi who opens
##     http://<game-pc-ip>:9095
## gets the game AND the automatic connection for free.
##
## Minimal on purpose: GET only, no caching, no compression, no keep-alive;
## every connection is answered and closed. Files come from the export
## directory (res://Builds/Web globalized), so re-exporting the build is
## picked up with no restart.

## Directory served over HTTP. Overridable for tests.
var base_dir: String = ""
## TCP port to listen on. 0 = set in _ready from this default.
var port: int = 9095

var _server := TCPServer.new()
var _pending: Array[StreamPeerTCP] = []

const MIME := {
	"html": "text/html",
	"js": "text/javascript",
	"mjs": "text/javascript",
	"wasm": "application/wasm",
	"pck": "application/octet-stream",
	"png": "image/png",
	"jpg": "image/jpeg",
	"ico": "image/x-icon",
	"json": "application/json",
	"worklet.js": "text/javascript",
}


func _ready() -> void:
	if base_dir.is_empty():
		var local := ProjectSettings.globalize_path("res://Builds/Web")
		base_dir = local if DirAccess.dir_exists_absolute(local) else ""
	if base_dir.is_empty() or not DirAccess.dir_exists_absolute(base_dir):
		print("WebFileServer: no web build at res://Builds/Web - not serving.")
		queue_free()
		return
	var err := _server.listen(port)
	if err != OK:
		push_error("WebFileServer: can't listen on port %d (error %d)." % [port, err])
		queue_free()
		return
	for ip in IP.get_local_addresses():
		if ip.begins_with("192.168.") or ip.begins_with("10.") or ip.count(".") == 3 and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			print("WebFileServer: phone on the same WiFi -> http://%s:%d" % [ip, port])
			break


func _process(_delta: float) -> void:
	if _server.is_listening():
		while _server.is_connection_available():
			_pending.append(_server.take_connection())
	var still: Array[StreamPeerTCP] = []
	for peer in _pending:
		peer.poll()
		match peer.get_status():
			StreamPeerTCP.STATUS_CONNECTED:
				if not _answer(peer):
					still.append(peer)  # request not fully arrived yet
			StreamPeerTCP.STATUS_CONNECTING:
				still.append(peer)
			_:
				peer.disconnect_from_host()
	_pending = still


## Reads one GET request if it has fully arrived; answers and closes it.
## Returns false while still waiting for bytes.
func _answer(peer: StreamPeerTCP) -> bool:
	var avail := peer.get_available_bytes()
	if avail <= 0:
		return false
	var req := peer.get_utf8_string(mini(avail, 8192))
	var head_end := req.find("\r\n\r\n")
	if head_end < 0:
		return false  # headers incomplete - wait for more
	var line := req.substr(0, req.find("\r\n"))
	var parts := line.split(" ")
	if parts.size() < 2 or parts[0] != "GET":
		_send(peer, 405, "text/plain", "method not allowed")
		return true
	var path := parts[1].split("?")[0].uri_decode()
	if path == "/" or path.is_empty():
		path = "/index.html"
	# Path traversal guard: resolve and require the result to stay inside
	# the served directory.
	var cleaned := base_dir + "/" + path.trim_prefix("/")
	var target := ProjectSettings.globalize_path(cleaned.simplify_path())
	if not target.begins_with(ProjectSettings.globalize_path(base_dir).simplify_path()):
		_send(peer, 403, "text/plain", "forbidden")
		return true
	if FileAccess.file_exists(target):
		var f := FileAccess.open(target, FileAccess.READ)
		var body := f.get_buffer(f.get_length())
		var ext := target.get_extension().to_lower()
		_send(peer, 200, MIME.get(ext, "application/octet-stream"), "", body)
	else:
		_send(peer, 404, "text/plain", "not found")
	return true


func _send(peer: StreamPeerTCP, code: int, mime: String, text: String, body: PackedByteArray = PackedByteArray()) -> void:
	if body.is_empty() and not text.is_empty():
		body = text.to_utf8_buffer()
	var status: String = {200: "OK", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"}.get(code, "OK")
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n" % [
			code, status, mime, body.size()]
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(body)
	peer.poll()
	peer.disconnect_from_host()
