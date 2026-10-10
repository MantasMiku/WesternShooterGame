extends Node
## Finds game servers for the menu:
##  - asks the master server for its list (online servers),
##  - asks the local network directly (LAN servers, works without a master server),
##  - pings every server it finds.
## Also does Quick Play: find the best server for a game mode.
##
## Runs on the PLAYER's game, in the main menu only (main_menu.gd creates it as
## "ServerBrowserService" and hands it to the server browser UI, server_browser.gd).
## It never joins a server itself: it only finds them, and the menu then starts the level with
## the chosen address and port.
##
## Two ways it talks to the outside world:
##  - HTTP to the master server (master_server.gd): GET /servers and GET /quickplay?mode=...
##  - UDP query packets to game servers' query ports (server_query.gd answers them).
##    On the LAN it doesn't know any addresses, so it "broadcasts" to 255.255.255.255,
##    which every computer on the local network receives.

signal list_changed            ## `servers` changed
## A refresh() finished waiting for LAN answers (online answers may still trickle in after).
signal refresh_finished
## {status = "found", address, port, name} | {status = "waiting", message} | {status = "none", message}
signal quick_play_result(result: Dictionary)

const NetConfig = preload("res://Scripts/Network/net_config.gd")
## How long a refresh waits for LAN servers to answer (seconds). Answers on a LAN take
## milliseconds, so this is plenty and keeps Quick Play feeling quick.
const LAN_WAIT_SECONDS := 1.2

## Master server address, like "http://1.2.3.4:8910" ("" = don't use a master server).
var master_url := ""
var servers := {}              ## id -> {id, name, mode, sub_mode, map, players, max_players, address, port, ping, source, dedicated}
var master_status := ""        ## "" (not asked), "ok", or an error description

# One UDP socket for all queries and their answers.
var _udp := PacketPeerUDP.new()
var _pending := {}             # token -> {sent, source}
# Two HTTPRequest nodes, because one node can only do one request at a time and the list
# and Quick Play may run at the same time.
var _http_list := HTTPRequest.new()
var _http_quick := HTTPRequest.new()
var _quick_mode := ""          # mode Quick Play is looking for ("" = not looking / cancelled)
var _refreshing := false


func _ready() -> void:
	master_url = NetConfig.get_master_url()
	# Port 0 = let the operating system pick any free port. Servers reply to whatever port we used.
	_udp.bind(0)
	# Needed to be allowed to send to the broadcast address 255.255.255.255.
	_udp.set_broadcast_enabled(true)
	for h in [_http_list, _http_quick]:
		h.timeout = 4.0   # seconds before giving up on the master server
		add_child(h)      # HTTPRequest is a node and only works inside the scene tree
	_http_list.request_completed.connect(_on_list_completed)
	_http_quick.request_completed.connect(_on_quick_completed)


## Changes and saves the master server address (from the browser's address box).
func set_master_url(url: String) -> void:
	master_url = url.strip_edges().trim_suffix("/")
	NetConfig.set_master_url(master_url)


# --- Listing --------------------------------------------------------------------------------

## Starts a new search: clears the list, asks the master and the LAN. Results arrive over the
## next moments through list_changed; refresh_finished fires after LAN_WAIT_SECONDS.
func refresh() -> void:
	servers.clear()
	_pending.clear()
	list_changed.emit()
	_refreshing = true
	master_status = ""
	if master_url != "":
		_http_list.cancel_request()
		# request() only starts the download; the answer comes to _on_list_completed.
		if _http_list.request(master_url + "/servers") != OK:
			master_status = "bad master server address"
	# LAN: ask every game port on the local network (broadcast) and on this PC.
	# (We don't know which port a LAN game uses, so we try the whole range. 127.0.0.1 is asked too
	# because broadcasts often don't come back to the same computer.)
	for port in range(NetConfig.GAME_PORT_MIN, NetConfig.GAME_PORT_MAX + 1):
		_send_query("255.255.255.255", port, "LAN")
		_send_query("127.0.0.1", port, "LAN")
	get_tree().create_timer(LAN_WAIT_SECONDS).timeout.connect(_finish_refresh)


## True while a refresh is still waiting for LAN answers.
func is_refreshing() -> bool:
	return _refreshing


## The best server we know of for a mode: not full, the most players (people like joining
## busy games), and on a tie the lowest ping. Empty Dictionary if there's none.
func best_server(mode: String) -> Dictionary:
	var best := {}
	for s in servers.values():
		if s.mode != mode or s.players >= s.max_players: continue
		if best.is_empty() or s.players > best.players or (s.players == best.players and _ping_or_big(s) < _ping_or_big(best)):
			best = s
	return best


func _finish_refresh() -> void:
	_refreshing = false
	refresh_finished.emit()


# The master's answer to GET /servers. Body is JSON: {"servers": [{id, name, address, port, ...}, ...]}
func _on_list_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# result = did the HTTP request work at all; code = the HTTP status (200 = OK).
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		master_status = "master server unreachable"
		list_changed.emit()
		return
	master_status = "ok"
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY: return
	for s in data.get("servers", []):
		# Add it now with unknown ping (-1), then query it directly to measure the ping.
		_add_server(s, str(s.get("address", "")), int(s.get("port", 0)), "Online", -1)
		_send_query(str(s.get("address", "")), int(s.get("port", 0)), "Online")   # for ping


# Sends one query packet: "WSQ1" + a random token, to the server's query port.
# The token is remembered with the send time so the answer can be matched and timed.
func _send_query(address: String, game_port: int, source: String) -> void:
	if address == "" or game_port <= 0: return
	var token := str(randi())
	_pending[token] = {sent = Time.get_ticks_msec(), source = source}
	_udp.set_dest_address(address, NetConfig.query_port(game_port))
	_udp.put_packet((NetConfig.QUERY_MAGIC + token).to_utf8_buffer())


# Every frame: read the answers that game servers sent back.
func _process(_delta: float) -> void:
	while _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		var from_ip := _udp.get_packet_ip()   # who answered = the address to join
		var info = JSON.parse_string(packet.get_string_from_utf8())
		if typeof(info) != TYPE_DICTIONARY: continue
		# Find our question by the echoed token: ping = now - when we sent it (milliseconds).
		var req: Dictionary = _pending.get(str(info.get("echo", "")), {})
		var ping := Time.get_ticks_msec() - int(req.sent) if !req.is_empty() else -1
		_add_server(info, from_ip, int(info.get("port", 0)), req.get("source", "LAN"), ping)


# Adds a server to `servers` or updates it. The same server can be found several ways (master
# list, LAN broadcast, 127.0.0.1), so entries are merged by the server's id.
func _add_server(info: Dictionary, address: String, port: int, source: String, ping: int) -> void:
	# A server running a different game version can't be joined, so don't list it.
	if int(info.get("v", NetConfig.PROTOCOL_VERSION)) != NetConfig.PROTOCOL_VERSION: return
	var id := str(info.get("id", "%s:%d" % [address, port]))
	var e: Dictionary = servers.get(id, {})
	e.id = id
	for k in ["name", "mode", "sub_mode", "map", "dedicated"]:
		if info.has(k): e[k] = info[k]
	e.players = int(info.get("players", e.get("players", 0)))
	e.max_players = int(info.get("max_players", e.get("max_players", 0)))
	e.port = port
	# A game on this same PC answers on 127.0.0.1 as well - that's the most reliable address to use.
	if !e.has("address") or e.address == "" or address == "127.0.0.1": e.address = address
	# Seen on the local network beats "online" - it's the faster route.
	e.source = "LAN" if source == "LAN" or e.get("source", "") == "LAN" else "Online"
	# Keep the best (lowest) ping we've measured; -1 means "not measured yet".
	if ping >= 0:
		e.ping = ping if !e.has("ping") or e.ping < 0 else mini(e.ping, ping)
	elif !e.has("ping"):
		e.ping = -1
	# Fill in any missing fields with defaults (false = don't overwrite ones we already have).
	e.merge({name = "Unnamed server", mode = "", sub_mode = "", map = "", dedicated = false}, false)
	servers[id] = e
	list_changed.emit()


# Ping for sorting: unknown ping counts as very slow.
func _ping_or_big(s: Dictionary) -> int:
	return s.ping if s.get("ping", -1) >= 0 else 9999


# --- Quick Play ------------------------------------------------------------------------------

## Ask for a game of this mode. Answers through quick_play_result. Call again to retry.
## First asks the master server (it knows online servers and can start a new one); if there is no
## master or it can't help, falls back to searching the LAN.
func quick_play(mode: String) -> void:
	_quick_mode = mode
	if master_url != "":
		_http_quick.cancel_request()
		# uri_encode makes the mode safe to put in a URL (spaces, symbols...).
		if _http_quick.request(master_url + "/quickplay?mode=" + mode.uri_encode()) == OK:
			return   # answer arrives in _on_quick_completed
	_quick_play_lan()


## Stops a running Quick Play (the player pressed Cancel).
func cancel_quick_play() -> void:
	_quick_mode = ""
	_http_quick.cancel_request()


# The master's answer to GET /quickplay. Body is JSON with a "status":
#   "found"    -> {address, port, name} of a server to join,
#   "starting" -> the master is launching a new server; the menu waits and calls quick_play again,
#   "none"     -> nothing available (we then try the LAN).
func _on_quick_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _quick_mode == "": return   # cancelled while we waited
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_quick_play_lan()   # master unreachable -> look on the local network instead
		return
	var r = JSON.parse_string(body.get_string_from_utf8())
	if typeof(r) != TYPE_DICTIONARY:
		_quick_play_lan()
		return
	match str(r.get("status", "")):
		"found":
			quick_play_result.emit({status = "found", address = str(r.address), port = int(r.port), name = str(r.get("name", ""))})
		"starting":
			quick_play_result.emit({status = "waiting", message = "Starting a new server..."})
		_:
			_quick_play_lan()


# Quick Play without the master: do a normal refresh, wait for it, and pick best_server().
# This is a coroutine: `await` pauses here until refresh_finished fires, without freezing the game.
func _quick_play_lan() -> void:
	var mode := _quick_mode
	refresh()
	await refresh_finished
	if _quick_mode != mode: return   # cancelled or changed meanwhile
	var best := best_server(mode)
	if best.is_empty():
		quick_play_result.emit({status = "none", message = "No open servers for this mode right now."})
	else:
		quick_play_result.emit({status = "found", address = best.address, port = best.port, name = best.name})
