extends RefCounted
## Network settings shared by the menu, game servers and the master server.
## Use with:  const NetConfig = preload("res://Scripts/Network/net_config.gd")
##
## HOW THE NETWORK PIECES FIT TOGETHER
##  - Game server: a match that players connect to with ENet (UDP) on its game port. It is either
##    a "listen server" (a player clicked Host, they also play) or a "dedicated server" (a headless
##    copy of the game started with --server, nobody plays on it). See multiplayer_test_scene.gd.
##  - Query port: every game server also answers small UDP "who are you?" packets on
##    game port + QUERY_PORT_OFFSET with its name, mode, player count... (server_query.gd).
##    That's how LAN games are found and how ping is measured.
##  - Master server: one always-running program (master_server.gd, e.g. on an Ubuntu box) that
##    keeps a list of dedicated servers. Dedicated servers send it a "heartbeat" over HTTP every
##    few seconds; it can also start new dedicated servers for Quick Play.
##  - Server browser / Quick Play (server_browser_service.gd, in the main menu): asks the master
##    for its list over HTTP AND scans the LAN with UDP queries, then merges both.
##
## Everything here is static/constant, so all of those scripts agree on the same numbers.

const PROTOCOL_VERSION := 1             ## Bump when servers and clients stop being compatible.
## Port a game server uses if none is given (ENet, UDP).
const DEFAULT_GAME_PORT := 9999
## LAN discovery asks every port in this range, so keep game servers inside it.
## (The master server also picks ports from this range for servers it spawns.)
const GAME_PORT_MIN := 9990
const GAME_PORT_MAX := 10009
## Every game server answers info/ping queries (UDP) on its game port + this offset.
const QUERY_PORT_OFFSET := 100
## Every query packet starts with these 4 characters. Servers ignore packets that don't, so stray
## traffic on the port is not mistaken for a query. Change it together with PROTOCOL_VERSION.
const QUERY_MAGIC := "WSQ1"

## Port the master server listens on (TCP, it speaks simple HTTP).
const DEFAULT_MASTER_PORT := 8910
## Change this to your Ubuntu server's address (or a dynamic DNS name), e.g. "http://taco.duckdns.org:8910".
## Players can also change it in the server browser; that choice is saved per PC.
const DEFAULT_MASTER_URL := "http://127.0.0.1:8910"

## Where the player's chosen master server address is saved (separate from settings.cfg).
const SETTINGS_PATH := "user://network.cfg"


## The master server address this PC should use: the saved one, or DEFAULT_MASTER_URL.
static func get_master_url() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		return str(cfg.get_value("network", "master_url", DEFAULT_MASTER_URL))
	return DEFAULT_MASTER_URL


## Saves a new master server address (called by the server browser).
static func set_master_url(url: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)   # keep anything else already in the file (fails harmlessly if there's no file yet)
	cfg.set_value("network", "master_url", url.strip_edges())
	cfg.save(SETTINGS_PATH)


## The UDP query port that belongs to a game port (e.g. 9999 -> 10099).
static func query_port(game_port: int) -> int:
	return game_port + QUERY_PORT_OFFSET
