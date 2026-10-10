extends Node
## Master server: keeps the list of running game servers and answers Quick Play.
## Game servers check in every few seconds (POST /heartbeat); the game menu asks for the list
## (GET /servers) or for the best server of a mode (GET /quickplay?mode=...).
## Open http://<host>:8910/ in a web browser to see what's running.
##
## Launch (same exported game file as the game servers):
##   WesternShooter.x86_64 --headless -- --master
## Options:
##   --master-port=8910       port for this master server (TCP)
##   --spawn                  start new dedicated servers on this machine when Quick Play finds none
##   --max-servers=6          max servers started by --spawn
##   --idle-quit=300          spawned servers shut down after this many seconds with nobody playing
##
## WHERE IT RUNS: on its own, as a separate copy of the game (usually on an always-on server PC).
## main_menu.gd sees "--master" and switches to Scenes/Network/master_server.tscn, whose root node
## has this script. It is NOT part of a match and doesn't use Godot's multiplayer API at all.
##
## HOW IT TALKS: it is a tiny hand-made web (HTTP) server built on Godot's TCPServer, because
## Godot has an HTTP *client* (HTTPRequest) but no HTTP server. It only understands the few simple
## requests our own game sends: one request per connection, answer, close.
##   POST /heartbeat     body: the game server's info as JSON  -> {"ok": true}
##   GET  /servers       optional ?mode=...                     -> {"servers": [...]}
##   GET  /quickplay     ?mode=...  -> {"status": "found", address, port, name} | {"status": "starting"} | {"status": "none"}
##   GET  /              a small HTML status page for humans
## Game servers are found by the browser through this list; joining then goes straight to the
## game server (the master is never in the middle of a match).

const NetConfig = preload("res://Scripts/Network/net_config.gd")
## The level that spawned dedicated servers run.
const LEVEL_SCENE := "res://Levels/multiplayer_test_scene.tscn"
const STALE_SECONDS := 20.0        ## Drop servers that stop checking in.
const SPAWN_GRACE_SECONDS := 20.0  ## How long a freshly started server has to register.

@export var autostart := false     ## True in master_server.tscn: read options from the command line.

## TCP port we listen on (from --master-port).
var port := NetConfig.DEFAULT_MASTER_PORT
## --spawn given: start new dedicated servers on this machine for Quick Play.
var spawn_enabled := false
## Most servers --spawn may have running at once.
var max_spawned := 6
## Seconds an empty spawned server waits before quitting (passed to it as --quit-when-empty).
var idle_quit := 300

var servers := {}      # id -> info + {source_ip, last_seen}
var _spawned := {}     # game port -> {pid, mode, started}
var _tcp := TCPServer.new()
var _clients: Array = []   # open connections: [{stream, buf (bytes received so far), since, done}]


func _ready() -> void:
	if autostart:
		# Same idea as the level's _parse_user_args: "--key=value" after "--" -> {key: value}.
		var args := {}
		for a in OS.get_cmdline_user_args():
			var kv := a.trim_prefix("--").split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "true"
		start(args)


## Reads the options and starts listening for HTTP connections. Returns false if the port is taken.
func start(options: Dictionary = {}) -> bool:
	port = int(options.get("master-port", port))
	spawn_enabled = options.has("spawn")
	max_spawned = int(options.get("max-servers", max_spawned))
	idle_quit = int(options.get("idle-quit", idle_quit))
	var err := _tcp.listen(port)
	if err != OK:
		push_error("[master] Could not listen on port %d (error %d)" % [port, err])
		return false
	print("[master] Master server listening on port %d. Spawning: %s" % [port, "on (max %d)" % max_spawned if spawn_enabled else "off"])
	return true


# When the master closes, also close the servers it started (so no orphan processes stay running).
func _exit_tree() -> void:
	_tcp.stop()
	for s in _spawned.values():
		OS.kill(s.pid)


# --- HTTP plumbing (tiny, only what our own game sends) ---------------------------------------

# Every frame: accept connections, collect their bytes, answer complete requests, and clean up.
# Nothing here blocks - a request that hasn't fully arrived yet is just checked again next frame.
func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	while _tcp.is_connection_available():
		_clients.append({stream = _tcp.take_connection(), buf = PackedByteArray(), since = now, done = false})

	for c in _clients:
		var s: StreamPeerTCP = c.stream
		s.poll()   # update the connection's status
		# Drop connections that closed, or that took more than 5 s to send a request.
		if s.get_status() != StreamPeerTCP.STATUS_CONNECTED or now - c.since > 5.0:
			c.done = true
			continue
		var n := s.get_available_bytes()
		if n > 0:
			# get_data returns [error, bytes].
			var got := s.get_data(n)
			if got[0] == OK:
				var b: PackedByteArray = c.buf   # packed arrays are copied on read, so write back
				b.append_array(got[1])
				c.buf = b
		var req := _parse_request(c.buf)
		if !req.is_empty():
			# A whole request has arrived: answer it and close (one request per connection).
			var res := _handle(req, _clean_ip(s.get_connected_host()))
			_send_response(s, res)
			s.disconnect_from_host()
			c.done = true
	_clients = _clients.filter(func(c): return !c.done)

	# Forget servers that stopped checking in, and spawned processes that exited.
	for id in servers.keys():
		if now - servers[id].last_seen > STALE_SECONDS:
			print("[master] '%s' timed out" % servers[id].get("name", id))
			servers.erase(id)
	for p in _spawned.keys():
		if !OS.is_process_running(_spawned[p].pid):
			_spawned.erase(p)


# Turns raw bytes into {method, path, query, headers, body}, or {} if the request isn't complete yet.
# An HTTP request looks like:
#   POST /heartbeat HTTP/1.1\r\n          <- first line: method, target, version
#   Host: 1.2.3.4:8910\r\n                <- headers, one per line
#   Content-Length: 123\r\n
#   \r\n                                  <- empty line = end of headers
#   {"id": ...}                           <- body (exactly Content-Length bytes)
func _parse_request(buf: PackedByteArray) -> Dictionary:
	var text := buf.get_string_from_ascii()
	var head_end := text.find("\r\n\r\n")
	if head_end < 0: return {}   # headers not finished yet
	var lines := text.substr(0, head_end).split("\r\n")
	var first := lines[0].split(" ")
	if first.size() < 2: return {method = "BAD", path = "", query = {}, headers = {}, body = ""}
	# Header names are case-insensitive in HTTP, so store them lower-case.
	var headers := {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon > 0: headers[lines[i].substr(0, colon).strip_edges().to_lower()] = lines[i].substr(colon + 1).strip_edges()
	var body_len := int(headers.get("content-length", "0"))
	var body_bytes := buf.slice(head_end + 4)   # + 4 skips the "\r\n\r\n"
	if body_bytes.size() < body_len: return {}   # wait for the rest
	# Split "/quickplay?mode=deathmatch" into the path and the query values.
	var target := first[1]
	var qpos := target.find("?")
	var query := {}
	if qpos >= 0:
		for pair in target.substr(qpos + 1).split("&"):
			var kv := pair.split("=", true, 1)
			query[kv[0].uri_decode()] = kv[1].uri_decode() if kv.size() > 1 else ""
	return {
		method = first[0], path = target.substr(0, qpos) if qpos >= 0 else target,
		query = query, headers = headers, body = body_bytes.slice(0, body_len).get_string_from_utf8(),
	}


# Writes an HTTP response. `res` is [status line text, content type, body text].
# "Connection: close" tells the other side we hang up after this answer.
# "Access-Control-Allow-Origin: *" lets web pages on other sites read our JSON too.
func _send_response(s: StreamPeerTCP, res: Array) -> void:
	var body: PackedByteArray = res[2].to_utf8_buffer()
	var head := "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n" % [res[0], res[1], body.size()]
	s.put_data(head.to_utf8_buffer())
	s.put_data(body)


# Shortcut for a "200 OK" JSON answer.
func _json(data) -> Array:
	return ["200 OK", "application/json", JSON.stringify(data)]


# --- Routes ------------------------------------------------------------------------------------

# Decides what to answer, based on method + path. from_ip = who connected to us.
func _handle(req: Dictionary, from_ip: String) -> Array:
	# The address the client typed to reach us (e.g. "taco.duckdns.org:8910"); see _public().
	var host_header: String = req.headers.get("host", "")
	match [req.method, req.path]:
		["POST", "/heartbeat"]:
			return _heartbeat(req.body, from_ip)
		["GET", "/servers"]:
			var mode: String = req.query.get("mode", "")
			var list := []
			for s in servers.values():
				if mode == "" or s.mode == mode: list.append(_public(s, host_header))
			return _json({servers = list})
		["GET", "/quickplay"]:
			return _json(_quick_play(req.query.get("mode", ""), host_header))
		["GET", "/"]:
			return ["200 OK", "text/html; charset=utf-8", _status_page()]
	return ["404 Not Found", "application/json", JSON.stringify({error = "not found"})]


# A game server checking in. The body is its _server_info() from multiplayer_test_scene.gd.
# We remember it with the IP it came from and the time, and forget it after STALE_SECONDS of silence.
func _heartbeat(body: String, from_ip: String) -> Array:
	var info = JSON.parse_string(body)
	if typeof(info) != TYPE_DICTIONARY or !info.has("id") or !info.has("port"):
		return ["400 Bad Request", "application/json", JSON.stringify({error = "bad heartbeat"})]
	# A server from an older/newer game build: refuse it, players couldn't join it anyway.
	if int(info.get("v", 0)) != NetConfig.PROTOCOL_VERSION:
		return ["409 Conflict", "application/json", JSON.stringify({error = "version mismatch"})]
	var id := str(info.id)
	if !servers.has(id):
		print("[master] + '%s' (%s) at %s:%d" % [info.get("name", "?"), info.get("mode", "?"), from_ip, int(info.port)])
	info.source_ip = from_ip
	info.last_seen = Time.get_ticks_msec() / 1000.0
	servers[id] = info
	return _json({ok = true})


## What clients see. A server running on this same machine checks in from 127.0.0.1, which
## means nothing to other PCs - so we hand out the address the client used to reach us instead.
## (A heartbeat may also include "public_address" to set the address by hand; our game servers
## don't send one at the moment.)
func _public(s: Dictionary, host_header: String) -> Dictionary:
	var address: String = s.get("public_address", "")
	if address == "":
		address = s.source_ip
		if address == "127.0.0.1" or address == "::1":
			address = _host_without_port(host_header)
	return {
		id = s.id, name = s.get("name", "Unnamed server"), mode = s.get("mode", ""), sub_mode = s.get("sub_mode", ""),
		map = s.get("map", ""), players = int(s.get("players", 0)), max_players = int(s.get("max_players", 0)),
		dedicated = s.get("dedicated", true), address = address, port = int(s.port), v = NetConfig.PROTOCOL_VERSION,
	}


# Quick Play: the fullest server of this mode that still has room. If there's none and --spawn
# is on, start a new server and answer "starting" (the player's game asks again a moment later
# and by then the new server has sent its first heartbeat).
func _quick_play(mode: String, host_header: String) -> Dictionary:
	if mode == "": return {status = "none"}
	var best := {}
	for s in servers.values():
		if s.get("mode", "") != mode or int(s.players) >= int(s.max_players): continue
		if best.is_empty() or int(s.players) > int(best.players):
			best = s
	if !best.is_empty():
		var p := _public(best, host_header)
		return {status = "found", address = p.address, port = p.port, name = p.name}
	if !spawn_enabled:
		return {status = "none"}
	# A server for this mode is already starting up? Tell the client to hold on.
	# (Without this, every retry would start yet another server.)
	var now := Time.get_ticks_msec() / 1000.0
	for s in _spawned.values():
		if s.mode == mode and now - s.started < SPAWN_GRACE_SECONDS:
			return {status = "starting"}
	if _spawned.size() >= max_spawned:
		return {status = "none"}
	return {status = "starting"} if _spawn_server(mode) else {status = "none"}


# Starts a new dedicated server process on this machine: the same game program, run headless with
# --server and a free port from the game port range. Returns false if it couldn't.
func _spawn_server(mode: String) -> bool:
	# Collect ports already in use (registered servers + ones we started that may not have registered yet).
	var used := {}
	for s in servers.values(): used[int(s.port)] = true
	for p in _spawned.keys(): used[p] = true
	var game_port := -1
	for p in range(NetConfig.GAME_PORT_MIN, NetConfig.GAME_PORT_MAX + 1):
		if !used.has(p):
			game_port = p
			break
	if game_port < 0: return false
	# Build the command line. --headless = no window or sound.
	var args := ["--headless"]
	# When testing from the editor, the "executable" is the Godot editor itself, so it also
	# needs to be told where the project is.
	if OS.has_feature("editor"):
		args += ["--path", ProjectSettings.globalize_path("res://")]
	# The scene to open directly, then "--" and our own options for the level's _start_dedicated_server.
	# It reports to this master on 127.0.0.1 (same machine) and quits after idle_quit seconds empty.
	args += [LEVEL_SCENE, "--", "--server", "--mode=" + mode, "--port=%d" % game_port,
		"--master=http://127.0.0.1:%d" % port, "--quit-when-empty=%d" % idle_quit,
		"--name=Official %s #%d" % [mode.capitalize(), _spawned.size() + 1]]
	# create_process starts it in the background and returns its process id (pid), or -1 on failure.
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid <= 0:
		push_error("[master] Failed to start a server process")
		return false
	_spawned[game_port] = {pid = pid, mode = mode, started = Time.get_ticks_msec() / 1000.0}
	print("[master] Started %s server on port %d (pid %d)" % [mode, game_port, pid])
	return true


# The HTML page at http://<host>:8910/ - a table of running servers. The <meta refresh> tag makes
# the browser reload it every 5 seconds. xml_escape stops a server name from injecting HTML.
func _status_page() -> String:
	var rows := ""
	for s in servers.values():
		rows += "<tr><td>%s</td><td>%s</td><td>%s</td><td>%d / %d</td><td>%s:%d</td></tr>" % [
			str(s.get("name", "")).xml_escape(), s.get("mode", ""), s.get("sub_mode", ""),
			int(s.players), int(s.max_players), s.source_ip, int(s.port)]
	if rows == "": rows = "<tr><td colspan=5>No servers running.</td></tr>"
	return """<!doctype html><html><head><meta http-equiv="refresh" content="5"><title>Western Shooter - servers</title>
<style>body{font-family:sans-serif;background:#1e140e;color:#eee2c8;padding:24px}table{border-collapse:collapse}
td,th{border:1px solid #6b4c30;padding:6px 12px}th{background:#3a2616}</style></head><body>
<h1>Western Shooter master server</h1><table><tr><th>Name</th><th>Mode</th><th>Sub-mode</th><th>Players</th><th>Address</th></tr>%s</table>
<p>Spawning: %s. Updates every 5 s.</p></body></html>""" % [rows, "on" if spawn_enabled else "off"]


# "example.com:8910" -> "example.com", "[::1]:8910" -> "::1" (IPv6 addresses are in brackets).
func _host_without_port(host: String) -> String:
	if host.begins_with("["): return host.substr(1, host.find("]") - 1)   # [IPv6]:port
	var colon := host.rfind(":")
	return host.substr(0, colon) if colon > 0 else host


# An IPv4 address arriving over IPv6 looks like "::ffff:1.2.3.4"; turn it back into "1.2.3.4".
func _clean_ip(ip: String) -> String:
	return ip.trim_prefix("::ffff:")
