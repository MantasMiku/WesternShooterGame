extends Node3D
## The level script: the test arena AND all of the multiplayer "glue" for a match.
##
## This script sits on the root node of Levels/multiplayer_test_scene.tscn. It does not move
## players or deal damage itself (that is player_controller.gd and the class scripts). Its job is:
##  - starting the network: hosting (listen server), joining (client) or running a dedicated server,
##  - spawning / removing player bodies through the MultiplayerSpawner node,
##  - picking spawn points, switching class, adding/removing bots,
##  - ammo boxes dropped by dead players,
##  - baking the navigation mesh the bots walk on,
##  - advertising the server (UDP query answers + heartbeats to the master server),
##  - going back to the main menu when the match ends or the connection is lost.
##
## WHICH PEER RUNS WHAT: this script runs on every peer (the server and each client), but most
## of the important decisions are made only on the server (peer id 1). Clients mostly just
## *ask* the server for things with RPCs (spawn me, change my class, drop ammo here) and the
## server answers by spawning / removing nodes, which the MultiplayerSpawner copies to everyone.
## Functions are labelled "Server only", "Client" or "Everyone" below.
##
## Three ways to start:
##  1. From the main menu (Scenes/UI/main_menu.tscn) - it fills `start_config` before adding this scene.
##  2. Running this scene directly - the old in-scene Host/Join menu still works (Team vs Team).
##  3. As a dedicated server (no player for the server itself, like TF2):
##       WesternShooter.exe --headless -- --server --mode=deathmatch --port=9999 [--name="Taco's DM"]
##         [--master=http://127.0.0.1:8910] [--submode="Capture the Point"] [--quit-when-empty=300]
##     It registers itself with the master server so it shows up in the server browser / Quick Play.
##     The match keeps running when any player leaves.
##     Bots: --bots=4 [--bot-difficulty=easy|normal|hard]
##     (Everything after the lone "--" is a "user argument": Godot ignores it and passes it to us,
##     see _parse_user_args().)

# --- Nodes from the scene ---------------------------------------------------------------------
# @onready means "look these up when the node is ready", i.e. after the scene tree is built.
# A "%Name" path means a node marked "Access as Unique Name" in the editor, found anywhere in the scene.

## The old in-scene Host/Join menu (only used when this scene is run directly from the editor).
@onready var mainMenu = $CanvasLayer/MainMenu
## Text box for the address to join in the old in-scene menu.
@onready var addressEntry = $CanvasLayer/MainMenu/MarginContainer/VBoxContainer/AddressEntry
## Class dropdown in the old in-scene menu (index = position in CLASS_SCENES).
@onready var classSelect: OptionButton = %ClassSelect
## Team dropdown in the old in-scene menu (0 = Red, 1 = Blue).
@onready var teamSelect: OptionButton = %TeamSelect
@onready var hud = $CanvasLayer/HUD   # Scenes/UI/hud.tscn
@onready var pause_menu = $CanvasLayer/PauseMenu   # Scenes/UI/pause_menu.tscn (Esc)
## The MultiplayerSpawner node. When the SERVER spawns a player through it, it automatically
## creates the same player on every client (also on clients that join later), and removes it
## everywhere when the server frees it. Its spawn_path points at this level node, so players
## become direct children of the level, named after their peer id ("1", "2754812", "-3"...).
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner

## Where we go back to when the match ends or the connection is lost.
const MAIN_MENU_SCENE := "res://Scenes/UI/main_menu.tscn"
# Helper scripts loaded as constants so we can call their static functions / create them with .new().
const NetConfig = preload("res://Scripts/Network/net_config.gd")
const ServerQuery = preload("res://Scripts/Network/server_query.gd")
## Map name shown in the server browser.
const MAP_NAME := "Test Arena"
const GameSettings = preload("res://Scripts/Global/game_settings.gd")
## Modes with rules. Each is a node added to the level (same name on every peer so RPCs line up).
## (An RPC is sent to "the node at this path" on the other computer, so the game mode node must
## be called "GameMode" and live under the level on the server and on every client.)
const GAME_MODE_SCRIPTS := {
	"deathmatch": preload("res://Scripts/GameModes/deathmatch.gd"),
}
## Spawns come from the Marker3D children of SpawnPoints/FFA, SpawnPoints/Red and
## SpawnPoints/Blue in the level (move them in the editor when the map changes).
## These are only fallbacks for a level without them.
## DM_SPAWN_AREA: a square on the ground (x, z from -10 to 10) to pick random free-for-all spawns in.
const DM_SPAWN_AREA := Rect2(-10, -10, 20, 20)
const BotBrain = preload("res://Scripts/AI/bot_brain.gd")
## Names given to bots (" [BOT]" is added). If all are taken, bots are called "Bot <n> [BOT]".
const BOT_NAMES := ["Jesse", "Calamity", "Wyatt", "Butch", "Annie", "Doc", "Bart", "Sundance", "Belle", "Kid", "Pearl", "Hoss"]
## Classes a bot can be (indexes into CLASS_SCENES; the plain "Player" class 0 is left out).
const BOT_CLASSES := [1, 2, 3, 4] # Medic, Sheriff, Bomber, Gunslinger
## Dedicated servers tell the master server "I'm still alive" this often (seconds).
## The master forgets a server after 20 s of silence, so a few missed heartbeats are fine.
const HEARTBEAT_SECONDS := 5.0
## The ammo box scene used for drops (the same pickup that is placed around the map).
const AMMO_DROP_SCENE := preload("res://Scenes/Pickups/ammo_pickup.tscn")
const DROP_LIFETIME := 15.0   ## Seconds a dropped ammo box stays before vanishing.
const DROP_AMOUNT := 0.35     ## Fraction of each gun's spare ammo it gives (map boxes give 0.5).

## The player scene for each class.
# Index must match the class order used by the menus.
const CLASS_SCENES: Array[PackedScene] = [
	preload("res://Scenes/Player/player_controller.tscn"),
	preload("res://Scenes/Medic/medic.tscn"),
	preload("res://Scenes/Sheriff/sheriff.tscn"),
	preload("res://Scenes/Bomber/bomber.tscn"),
	preload("res://Scenes/Gunslinger/gunslinger.tscn"),
]
## Display names, same order as CLASS_SCENES.
const CLASS_NAMES := ["Player", "Medic", "Sheriff", "Bomber", "Gunslinger"]
## Team 0 = Red, team 1 = Blue.
const TEAM_NAMES := ["Red", "Blue"]
## Fallback team spawn positions if the level has no SpawnPoints/Red or SpawnPoints/Blue markers.
const TEAM_SPAWNS := [Vector3(-35, 5, 0), Vector3(35, 5, 0)]
## Names of the SpawnPoints child nodes for each team (same order as TEAM_NAMES).
const TEAM_SPAWN_GROUPS := ["Red", "Blue"]

## Game modes from the design notes. Rules (timers, capture points, waves...) are not in yet -
## for now a mode decides max players and how teams work.
## teams: "chosen" = players pick Red/Blue, "everyone" = everyone for themselves,
##        "coop" = everybody on team 0 together.
## Only modes listed in GAME_MODE_SCRIPTS have real rules (score, timer...) so far.
const MODES := {
	"team_vs_team":  {name = "Team vs Team",  max_players = 12, teams = "chosen"},   # 6 v 6
	"deathmatch":    {name = "Death Match",   max_players = 8,  teams = "everyone"}, # free-for-all
	"wave_survival": {name = "Wave Survival", max_players = 4,  teams = "coop"},     # all on one team
}
const FFA_TEAM_BASE := 100   # Death Match: each player gets their own team id (100 + peer id).

## The game port (ENet, UDP) used when nothing else is chosen.
const PORT = NetConfig.DEFAULT_GAME_PORT

var start_config := {}       ## Set by the main menu: {host, mode, sub_mode, class, team, address, port, upnp}
## Current mode key (a key of MODES). The server decides it; clients get told (see _receive_mode).
var mode := "team_vs_team"
## Extra mode variant text, e.g. "Capture the Point". Only shown in menus for now.
var sub_mode := ""
## Name shown in the server browser.
var server_name := ""
## True when this game is a dedicated server (no local player, no HUD, no window with --headless).
var is_dedicated_server := false
var _server_port := PORT
var _server_id := ""            # random id so the browser/master can tell servers apart
var _master_url := ""           # dedicated servers check in here
var _heartbeat_left := 0.0      # seconds until the next heartbeat
var _heartbeat_http: HTTPRequest   # node that sends heartbeats (only on dedicated servers)
var _quit_when_empty := 0.0     # seconds; 0 = never
var _empty_for := 0.0           # how long the server has had no players
## The ENet network connection. ENet is a library that sends game messages over UDP and can make
## some of them "reliable" (resent until they arrive). The same object is used for hosting
## (create_server) and joining (create_client), then handed to Godot's `multiplayer` API.
var enet_peer := ENetMultiplayerPeer.new()
# What the local player picked in the menu, remembered until the server lets us spawn.
var _local_class := 0
var _local_team := 0
var _address := ""              # the address we joined (for messages and the pause menu)
var _join_port := PORT
var _local_name := "Player"
var game_mode: Node = null      ## Rules for the current mode (null if the mode has none yet)
var bot_difficulty := 1         ## 0 easy, 1 normal, 2 hard
var _bot_seq := 0               # counts bots ever added; bot n gets id -n
var _drop_seq := 0              # counts ammo drops so each one gets a unique node name
var _drops := {}   # server: drop name -> position (so late joiners see existing drops)


## Everyone. Connects signals, then decides how to start (dedicated server / menu config / old menu).
func _ready() -> void:
	# Every peer must use the same spawn function, so set it before any spawning happens.
	# (With a custom spawn_function the spawner doesn't send the whole node over the network,
	# only the small Dictionary given to spawner.spawn(); each peer then builds the player
	# itself from that data with _spawn_player.)
	spawner.spawn_function = _spawn_player
	# Client-side signals: the server went away, or we never managed to connect.
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	# Buttons in the Esc menu.
	pause_menu.leave_requested.connect(leave_match)
	pause_menu.add_bot_requested.connect(func(): add_bot(); _update_pause_bot_info())
	pause_menu.remove_bot_requested.connect(func(): remove_bot(); _update_pause_bot_info())
	pause_menu.bot_difficulty_changed.connect(set_bot_difficulty)
	pause_menu.class_change_requested.connect(request_class_change)

	var args := _parse_user_args()
	if args.has("server"):
		_start_dedicated_server(args)
	elif !start_config.is_empty():
		# Started from the main menu: hide the old test menu and host/join right away.
		mainMenu.hide()
		var c := start_config
		_local_name = str(c.get("name", GameSettings.get_value("player_name")))
		if c.get("host", false):
			sub_mode = c.get("sub_mode", "")
			host_game(c["mode"], c["class"], c["team"], c.get("upnp", false))
		else:
			join_game(c["address"], c["class"], c["team"], int(c.get("port", PORT)))
	# Otherwise the scene was run directly: the old in-scene menu stays visible and waits for a click.


# The "quit" input action closes the whole game straight away.
func _unhandled_input(_event: InputEvent):
	if Input.is_action_just_pressed("quit"):
		get_tree().quit()


# --- Starting / joining ------------------------------------------------------------

## Listen server: this game is both the server and a player (the match ends if you leave).
## The host is always peer id 1 - in Godot the server is ALWAYS peer 1, and every client gets a
## random id when it connects. Called from _ready (main menu) or the old in-scene Host button.
func host_game(p_mode: String, class_index: int, team: int, use_upnp := false, port := PORT) -> void:
	mode = p_mode if MODES.has(p_mode) else "team_vs_team"
	_local_class = class_index
	_local_team = team
	# The host takes one of the player slots itself.
	# (create_server's second argument is how many CLIENTS may connect.)
	var err := enet_peer.create_server(port, MODES[mode].max_players - 1)
	if err != OK:
		_back_to_menu("Could not host on port %d - is another game already hosting?" % port)
		return
	# From now on RPCs and the spawner go through this ENet connection.
	multiplayer.multiplayer_peer = enet_peer
	# Server-only signals: someone joined / someone left.
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(remove_player)
	mainMenu.hide()
	hud.show()
	server_name = "%s's game" % _local_name
	# The game mode must exist before the first player is added, so it can register them.
	_ensure_game_mode()
	_start_server_services(port)   # LAN players can find this game in the browser
	_setup_navigation()   # bots need it; only the server runs bots
	# Spawn our own player. multiplayer.get_unique_id() is 1 here because we are the server.
	add_player(multiplayer.get_unique_id(), class_index, team, _local_name)
	bot_difficulty = int(start_config.get("bot_difficulty", 1))
	for i in int(start_config.get("bots", 0)): add_bot()
	if use_upnp:
		upnp_setup(port)


## Client: connect to a server. Nothing spawns yet - connecting takes a moment, and then the
## server sends us the mode (_receive_mode), and only after that we ask to be spawned.
func join_game(address: String, class_index: int, team: int, port: int = PORT) -> void:
	_local_class = class_index
	_local_team = team
	_address = address.strip_edges() if !address.strip_edges().is_empty() else "localhost"
	_join_port = port
	# create_client only STARTS connecting; success or failure arrives later as a signal
	# (connected_to_server / connection_failed). An error here means e.g. a bad address.
	var err := enet_peer.create_client(_address, port)
	if err != OK:
		_back_to_menu("Could not connect to %s." % _address)
		return
	multiplayer.multiplayer_peer = enet_peer
	multiplayer.connected_to_server.connect(_on_connected_to_server, CONNECT_ONE_SHOT)
	mainMenu.hide()
	hud.show()


## Dedicated server: no local player, no HUD. Keeps the match alive no matter who leaves.
## Reads its settings from the command line arguments (see the list at the top of the file).
## Usually started by hand on a server PC, or by the master server's --spawn option.
func _start_dedicated_server(args: Dictionary) -> void:
	is_dedicated_server = true
	mode = args.get("mode", "team_vs_team")
	if !MODES.has(mode): mode = "team_vs_team"
	sub_mode = args.get("submode", "Capture the Point" if mode == "team_vs_team" else "")
	server_name = args.get("name", "%s server" % MODES[mode].name)
	_master_url = str(args.get("master", NetConfig.DEFAULT_MASTER_URL)).trim_suffix("/")
	_quit_when_empty = float(args.get("quit-when-empty", "0"))
	var port := int(args.get("port", PORT))
	# No local player here, so every slot is free for clients.
	var err := enet_peer.create_server(port, MODES[mode].max_players)
	if err != OK:
		push_error("Dedicated server could not start on port %d (error %d)" % [port, err])
		get_tree().quit(1)   # exit code 1 = "failed", useful for scripts / the master server
		return
	multiplayer.multiplayer_peer = enet_peer
	# Two handlers on the same signal: one just logs to the console, the other does the work.
	multiplayer.peer_connected.connect(func(id): print("[server] peer %d connected" % id))
	multiplayer.peer_connected.connect(_on_peer_connected)
	_ensure_game_mode()
	multiplayer.peer_disconnected.connect(func(id): print("[server] peer %d left" % id); remove_player(id))
	mainMenu.hide()
	hud.hide()
	_start_server_services(port)
	# "easy"/"normal"/"hard" -> 0/1/2 (find() gives -1 for anything else, then we use normal).
	bot_difficulty = ["easy", "normal", "hard"].find(str(args.get("bot-difficulty", "normal")))
	if bot_difficulty < 0: bot_difficulty = 1
	_setup_navigation()
	for i in int(args.get("bots", "0")): add_bot()
	print("[server] Dedicated server running - mode: %s, port: %d, max players: %d" % [MODES[mode].name, port, MODES[mode].max_players])


# Old in-scene menu (when this scene is run directly).
# These are connected to the Host/Join buttons in the .tscn file.
func _on_host_button_pressed() -> void:
	host_game("team_vs_team", classSelect.selected, teamSelect.selected)

func _on_join_button_pressed() -> void:
	join_game(addressEntry.text, classSelect.selected, teamSelect.selected)


# Client: the connection to the server is open.
func _on_connected_to_server() -> void:
	pass   # wait for the server to tell us the mode (_receive_mode), then ask to spawn


# Server: a new peer connected -> tell it which mode we're playing first, so it can set up the
# mode's rules/HUD before anything else arrives.
# Order matters: the client must create its own "GameMode" node (same name as ours) BEFORE its
# player exists, otherwise the game mode's RPCs and the HUD binding would have nothing to land on.
# That's why the client only asks to spawn from inside _receive_mode.
func _on_peer_connected(id: int) -> void:
	# rpc_id(id, ...) = call this function on that one peer only.
	_receive_mode.rpc_id(id, mode, sub_mode)
	# Ammo boxes aren't made by the spawner, so send the newcomer the ones already lying around.
	for drop_name in _drops:
		_spawn_drop.rpc_id(id, drop_name, _drops[drop_name])


# Server -> client. "authority" means only the multiplayer authority of this node may call it
# (the level belongs to the server, peer 1), so a client can't fake it. "reliable" = ENet
# resends it until it arrives, and in order.
@rpc("authority", "reliable")
func _receive_mode(p_mode: String, p_sub_mode: String) -> void:
	mode = p_mode if MODES.has(p_mode) else "team_vs_team"
	sub_mode = p_sub_mode
	_ensure_game_mode()
	# Now we're ready: ask the server (always peer 1) to spawn us with what we picked in the menu.
	request_spawn.rpc_id(1, _local_class, _local_team, _local_name)


# Client -> server: "spawn me as this class on this team".
# "any_peer" = any client is allowed to call it, so the server must not trust it blindly:
# it only runs on the server, and uses the sender's real id instead of an id sent in the message.
@rpc("any_peer", "reliable")
func request_spawn(class_index: int, team: int, player_name := "Player") -> void:
	if !multiplayer.is_server(): return
	add_player(multiplayer.get_remote_sender_id(), class_index, team, player_name)


# Everyone: creates the rules node for the current mode once (if the mode has rules).
# Named "GameMode" on every peer so its RPCs find each other.
func _ensure_game_mode() -> void:
	if game_mode or !GAME_MODE_SCRIPTS.has(mode): return
	game_mode = GAME_MODE_SCRIPTS[mode].new()
	game_mode.name = "GameMode"
	game_mode.level = self
	add_child(game_mode)


# --- Spawning ---------------------------------------------------------------------------

# Server only. The spawner replicates the new player (and its spawn data) to every client,
# including players who join later.
# peer_id: who controls it (the peer id for people, a negative number for bots).
# dead_for: > 0 makes the player start dead and respawn after that many seconds (class switching).
func add_player(peer_id: int, class_index: int, team: int, player_name := "Player", is_bot := false, dead_for := 0.0) -> void:
	# Never trust values that came from a client: keep them in range.
	class_index = clampi(class_index, 0, CLASS_SCENES.size() - 1)
	player_name = player_name.strip_edges().left(20)
	if player_name == "": player_name = "Player %d" % peer_id
	var spawn_pos: Vector3
	# Pick the team and spawn point depending on how this mode does teams.
	match MODES[mode].teams:
		"everyone":
			# Own team per player. Bots have negative ids, so they get a range far above any peer id.
			# (Peer ids are at most about 2.1 billion, so 3 billion + bot number can never clash.)
			team = FFA_TEAM_BASE + (peer_id if peer_id > 0 else 3_000_000_000 - peer_id)
			spawn_pos = _random_ffa_spawn()
		"coop":
			team = 0
			spawn_pos = _team_spawn(0)
		_:
			if team < 0 or team >= TEAM_NAMES.size():
				team = _smaller_team()   # "Auto" (Quick Play / browser joins)
			spawn_pos = _team_spawn(team)

	# spawner.spawn() calls _spawn_player(data) here on the server, adds the result to the level,
	# and sends the same data to every client so they run _spawn_player too.
	var player = spawner.spawn({"peer_id": peer_id, "class": class_index, "team": team, "mode": mode, "pos": spawn_pos, "name": player_name, "bot": is_bot, "dead_for": dead_for})
	if game_mode:
		game_mode.register_player(peer_id, player_name, CLASS_NAMES[class_index])
	if is_bot:
		_attach_bot_brain(player)
	elif player.is_multiplayer_authority() and !is_dedicated_server:
		# This is the host's own player (peer 1). Clients set up their HUD in
		# _on_multiplayer_spawner_spawned instead, because that signal only fires on clients.
		_setup_local_hud(player)
	if !is_bot:
		_trim_bots()


# Runs on the server and every client with the same data, so all peers build the same player.
# Must return the node WITHOUT adding it to the tree - the spawner adds it under the level itself.
func _spawn_player(data: Dictionary) -> Node:
	mode = data.get("mode", mode)   # clients learn the server's mode from here
	var player = CLASS_SCENES[data["class"]].instantiate()
	# The node name is the peer id. player_controller.gd reads it in _enter_tree to set who
	# controls this player (its multiplayer authority), and RPCs use it to find the same node.
	player.name = str(data["peer_id"])
	player.team = data["team"]
	player.spawn_position = data["pos"]
	player.position = data["pos"]
	player.player_name = data.get("name", "Player")
	player.is_bot = data.get("bot", false)
	player.start_dead_for = data.get("dead_for", 0.0)
	# Remember the class on the node, so class switching / the HUD can check it later.
	player.set_meta("class_index", data["class"])
	return player


## Where a player comes back after dying (called on the player's own peer).
## Free-for-all picks a fresh safe spot each time; team modes reuse the player's team spawn.
func get_respawn_position(player: Node) -> Vector3:
	if MODES[mode].teams == "everyone":
		return _random_ffa_spawn()
	return player.spawn_position


## Spawn points placed in the level (Marker3D children of SpawnPoints/<group>).
## Returns their world positions, or an empty array if the group doesn't exist.
func get_spawn_points(group: String) -> Array:
	var holder := get_node_or_null("SpawnPoints/" + group)
	if holder == null: return []
	return holder.get_children().filter(func(m): return m is Node3D).map(func(m): return m.global_position)


# A free-for-all spawn: one of the 3 spawn points furthest from everyone alive (a bit random
# so people don't always appear in the same spot).
func _random_ffa_spawn() -> Vector3:
	var points := get_spawn_points("FFA")
	if points.is_empty():
		# No markers in the level: make up 8 random points inside DM_SPAWN_AREA, 1 m above the ground.
		for i in 8: points.append(Vector3(randf_range(DM_SPAWN_AREA.position.x, DM_SPAWN_AREA.end.x), 1.0, randf_range(DM_SPAWN_AREA.position.y, DM_SPAWN_AREA.end.y)))
	# Score each point by the distance to the closest living player (bigger = safer).
	var scored := []
	for p in points:
		var nearest := INF
		for other in _players():
			if !other.is_dead: nearest = minf(nearest, p.distance_to(other.global_position))
		scored.append([nearest, p])
	# Safest first, then pick randomly among the top 3.
	scored.sort_custom(func(a, b): return a[0] > b[0])
	return scored[randi() % mini(3, scored.size())][1]


# A random spawn point of this team (or the fallback position with a little sideways spread).
func _team_spawn(team: int) -> Vector3:
	var points := get_spawn_points(TEAM_SPAWN_GROUPS[clampi(team, 0, 1)])
	if points.is_empty(): return TEAM_SPAWNS[clampi(team, 0, 1)] + Vector3(0, 0, randf_range(-4.0, 4.0))
	return points.pick_random()


# --- Navigation for bots -------------------------------------------------------------------

## Bakes a navigation mesh from the FuncGodotMap's collision, so bots can find their way
## through doors and up stairs. Runs once on the server when the game starts (about a second
## for a map this size). Re-done automatically whenever the map changes, nothing to maintain.
## A navigation mesh is a simplified "walkable floor" made of polygons; bots ask the
## NavigationServer for a path across it (see bot_brain.gd). Clients don't need it.
func _setup_navigation() -> void:
	if has_node("Navigation"): return
	var map_root := get_node_or_null("FuncGodotMap")
	if map_root == null: return
	var nm := NavigationMesh.new()
	# The size of the "agent" (a bot) - the mesh keeps this far from walls and skips gaps it can't fit through.
	nm.agent_radius = 0.5           # metres; how close to a wall a bot's centre may get
	nm.agent_height = 2.0           # metres; places with a lower ceiling are not walkable
	nm.agent_max_climb = 0.5        # the stair steps are 0.5 m (keep these multiples of cell_height)
	nm.agent_max_slope = 46.0       # degrees; steeper ramps count as walls
	# The baker works on a grid of little boxes ("voxels"): smaller = more exact but slower to bake.
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	# Build it from the static collision shapes (not the visible meshes), only physics layer 1
	# (the world), and look through every child of the map node, not just the node itself.
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = 0b01
	nm.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	# Two steps: collect the geometry from the scene, then bake the mesh from it.
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(nm, source, map_root)
	NavigationServer3D.bake_from_source_geometry_data(nm, source)
	# A NavigationRegion3D puts the baked mesh into the world so pathfinding can use it.
	var region := NavigationRegion3D.new()
	region.name = "Navigation"
	region.navigation_mesh = nm
	add_child(region)


# Server (connected to peer_disconnected) and for removing bots: frees the player's node.
# Because the node was made by the spawner, freeing it on the server removes it on every client too.
func remove_player(peer_id):
	if game_mode and multiplayer.is_server():
		game_mode.unregister_player(peer_id)
	var player = get_node_or_null(str(peer_id))
	if player:
		player.queue_free()


# Client: the spawner's "spawned" signal (connected in the .tscn) fires on clients whenever the
# server's spawner created a node here. If it is OUR player (we are its authority), hook up the HUD.
func _on_multiplayer_spawner_spawned(node):
	if node.is_multiplayer_authority():
		_setup_local_hud(node)


# Everyone except dedicated servers: connects the HUD, pause menu and game mode to the local player.
func _setup_local_hud(player) -> void:
	hud.bind_player(player)
	var side := "Team %s" % TEAM_NAMES[player.team] if MODES[mode].teams == "chosen" else ("Co-op" if MODES[mode].teams == "coop" else "Free for all")
	_local_class = player.get_meta("class_index", _local_class)
	hud.set_class_text("%s  |  %s  |  %s" % [MODES[mode].name, CLASS_NAMES[_local_class], side])
	pause_menu.set_current_class(_local_class)
	var where := "Hosting on port %d" % _server_port if multiplayer.is_server() else "Connected to %s:%d" % [_address, _join_port]
	pause_menu.bind(player, multiplayer.is_server(), "%s  |  %s" % [MODES[mode].name, where])
	_update_pause_bot_info()
	if game_mode:
		game_mode.bind_local_player(player)


# --- Switching class (Esc menu > Change class, or the , key) -------------------------------

## Asks the server to swap our player for one of another class. Your score is kept.
## If you're alive, it counts as a death and you come back after the normal respawn wait
## (so switching can't be used to escape a fight at full health); if you're already dead,
## you come back as the new class when your respawn timer runs out.
## Runs on the local player's peer (client or host).
func request_class_change(class_index: int) -> void:
	var me = get_node_or_null(str(multiplayer.get_unique_id()))
	if me == null or me.get_meta("class_index", -1) == class_index: return
	# How long the new body should stay dead: what's left of the current timer (at least 0.3 s),
	# or a full respawn wait if we're alive.
	var dead_for: float = maxf(me._respawn_left, 0.3) if me.is_dead else me.respawn_delay
	_change_class.rpc_id(1, class_index, dead_for)


# Server only. "call_local" lets the host call this on itself with the same rpc_id(1, ...) line
# a client uses (without it, Godot refuses to run an RPC aimed at your own peer id).
@rpc("any_peer", "call_local", "reliable")
func _change_class(class_index: int, dead_for: float) -> void:
	if !multiplayer.is_server(): return
	# Who asked. Safety net: if there's no remote sender (0), the call came from this machine, so it's us.
	var id := multiplayer.get_remote_sender_id()
	if id == 0: id = multiplayer.get_unique_id()
	var old = get_node_or_null(str(id))
	# Ignore bad requests (class 0, the plain "Player", can't be picked here) and no-op switches.
	if old == null or class_index < 1 or class_index >= CLASS_SCENES.size(): return
	if old.get_meta("class_index", -1) == class_index: return
	if !old.is_dead and game_mode:
		game_mode.process_death(id, 0)   # switching mid-fight counts as a death (nobody gets points)
	var team: int = old.team
	var nm: String = old.player_name
	# Take the old body out first, so its despawn reaches clients before the new spawn
	# (both use the same node name).
	# queue_free alone would only delete it at the end of the frame, so the new player (also
	# called "<id>") would get renamed by Godot to avoid the clash and stop matching on clients.
	remove_child(old)
	old.queue_free()
	# clampf: the dead time came from a client, so keep it sensible (0.3 - 10 s).
	add_player(id, class_index, team, nm, false, clampf(dead_for, 0.3, 10.0))


# --- Ammo drops: everyone who dies leaves an ammo box ----------------------------------------

## Called on the peer of a player who just died.
## (The dying player's own peer notices the death, but only the server may create drops.)
func request_ammo_drop(pos: Vector3) -> void:
	if multiplayer.multiplayer_peer == null: return
	if multiplayer.is_server(): _drop_ammo(pos)
	else: _request_drop.rpc_id(1, pos)


# Client -> server: "I died here, please drop a box".
@rpc("any_peer", "reliable")
func _request_drop(pos: Vector3) -> void:
	if multiplayer.is_server(): _drop_ammo(pos)


# Server only: finds the ground and tells everyone to create the box.
func _drop_ammo(pos: Vector3) -> void:
	# Put it on the ground under where they died (they might have died mid-air).
	# A ray from just above the body straight down up to 40 m, hitting only physics layer 1 (the world).
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.5, pos + Vector3.DOWN * 40.0, 0b01)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty(): return   # died over the void (fell off): nowhere to put it
	pos = hit.position
	_drop_seq += 1
	# .rpc() without an id = call on every peer; "call_local" below makes it run on the server too.
	_spawn_drop.rpc("Drop%d" % _drop_seq, pos)


# Server -> everyone: create the ammo box. Every peer makes its own copy with the same name,
# so picking it up (handled by the pickup script) refers to the same node everywhere.
@rpc("authority", "call_local", "reliable")
func _spawn_drop(drop_name: String, pos: Vector3) -> void:
	# Drops go under the game mode when there is one (bots look for pickups there), else the level.
	var parent: Node = game_mode if game_mode else self
	if parent.has_node(drop_name): return   # already have it (e.g. sent twice to a late joiner)
	var d = AMMO_DROP_SCENE.instantiate()
	d.name = drop_name
	d.single_use = true
	d.lifetime = DROP_LIFETIME
	d.amount = DROP_AMOUNT
	d.scale = Vector3.ONE * 0.8   # a bit smaller than map boxes, so you can tell them apart
	parent.add_child(d)
	d.global_position = pos
	if multiplayer.is_server():
		# Remember it for players who join later (see _on_peer_connected); forget it when it's gone.
		_drops[drop_name] = pos
		d.tree_exiting.connect(func(): _drops.erase(drop_name))


# Everyone: all player bodies currently in the level (players are CharacterBody3D children).
# Ones that are about to be deleted are skipped so counts are right during the same frame.
func _players() -> Array:
	return get_children().filter(func(n): return n is CharacterBody3D and !n.is_queued_for_deletion())


# --- Bots (server only) ---------------------------------------------------------------------
# Bots are normal player scenes with is_bot = true and a BotBrain child that "presses the keys".
# They live on the server, which is their multiplayer authority, and their movement is synced
# to clients just like a human player's. They get NEGATIVE ids (-1, -2, ...) so they can never
# clash with a real peer id (those are always positive) and so code can spot them easily.

## All bot players in the level.
func get_bots() -> Array:
	return _players().filter(func(p): return p.is_bot)


## Adds one bot if there's room. Returns false if the server is full.
func add_bot() -> bool:
	if !multiplayer.is_server(): return false
	if _players().size() >= MODES[mode].max_players: return false
	_bot_seq += 1
	# Pick the first western name no current bot is using.
	var used := get_bots().map(func(b): return b.player_name)
	var bot_name := ""
	for n in BOT_NAMES:
		if not used.has("%s [BOT]" % n):
			bot_name = "%s [BOT]" % n
			break
	if bot_name == "": bot_name = "Bot %d [BOT]" % _bot_seq
	# team -1 = "Auto": add_player puts the bot on the smaller team.
	add_player(-_bot_seq, BOT_CLASSES.pick_random(), -1, bot_name, true)   # bots have negative ids
	return true


## Removes the newest bot (server only; does nothing if there are none).
func remove_bot() -> void:
	var bots := get_bots()
	if multiplayer.is_server() and !bots.is_empty():
		remove_player(bots[-1].combat_id)


## Changes how well all bots play (0 easy, 1 normal, 2 hard). Called from the Esc menu.
## A listen-server host's choice is also saved as their default for next time.
func set_bot_difficulty(level_index: int) -> void:
	bot_difficulty = clampi(level_index, 0, 2)
	if !is_dedicated_server: GameSettings.set_value("bot_difficulty", bot_difficulty)
	for b in get_bots():
		var brain = b.get_node_or_null("BotBrain")
		if brain: brain.difficulty = bot_difficulty
	_update_pause_bot_info()


# Server: gives a freshly spawned bot body its AI.
func _attach_bot_brain(player: Node) -> void:
	var brain = BotBrain.new()
	brain.name = "BotBrain"
	brain.player = player
	brain.level = self
	brain.difficulty = bot_difficulty
	player.add_child(brain)
	# A bot added while the end-of-match results are showing stands still like everyone else.
	player.frozen = game_mode != null and game_mode.phase == "results"
	# Bots die on the server, so they report straight to the game mode.
	# (Human players report their own death from their own peer through an RPC instead.)
	player.died.connect(_on_bot_died.bind(player.combat_id))


# The "died" signal gives the killer's id; bind() added the bot's own id as the second argument.
func _on_bot_died(killer_id: int, bot_id: int) -> void:
	if game_mode: game_mode.process_death(bot_id, killer_id)


# A person joined and the server is over its player limit: a bot makes room (like TF2's bot quota).
func _trim_bots() -> void:
	while _players().size() > MODES[mode].max_players and !get_bots().is_empty():
		remove_bot()


# Shows the current bot count and difficulty in the Esc menu.
func _update_pause_bot_info() -> void:
	pause_menu.set_bot_info(get_bots().size(), bot_difficulty)


# The team (0 Red / 1 Blue) with fewer players; Red on a tie. Used for "Auto" team.
func _smaller_team() -> int:
	var counts := [0, 0]
	for p in _players():
		if p.team >= 0 and p.team < counts.size(): counts[p.team] += 1
	return 0 if counts[0] <= counts[1] else 1


# --- Server listing: query answers, master heartbeats, idle shutdown -------------------------
# How players find servers:
#  - Every game server (dedicated or a player hosting) runs a ServerQuery node that answers small
#    UDP "who are you?" packets on game port + 100. LAN browsing and ping use this.
#  - Dedicated servers ALSO send a heartbeat (HTTP POST with _server_info()) to the master server
#    every HEARTBEAT_SECONDS, so they show up in the online list and Quick Play.
#  - Listen servers (a player hosting) only appear on the LAN; they don't contact the master.

# Server (listen or dedicated): starts the query responder and, for dedicated servers, heartbeats.
func _start_server_services(port: int) -> void:
	_server_port = port
	# A unique-enough id: current time + a random number. The same server reached two ways
	# (LAN and online) has the same id, so the browser shows it only once.
	_server_id = "%d-%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	var query = ServerQuery.new()
	query.name = "ServerQuery"
	query.info_provider = _server_info   # the query node calls this to get fresh info for each answer
	add_child(query)
	query.start(port)
	if is_dedicated_server and _master_url != "":
		_heartbeat_http = HTTPRequest.new()
		_heartbeat_http.timeout = 4.0   # seconds; give up on a slow master before the next beat
		add_child(_heartbeat_http)
		_heartbeat_left = 0.0   # first heartbeat right away


# The info this server advertises (to UDP queries and in heartbeats). "v" is the protocol version:
# browsers and the master ignore servers with a different one.
func _server_info() -> Dictionary:
	return {
		v = NetConfig.PROTOCOL_VERSION, id = _server_id, name = server_name, mode = mode, sub_mode = sub_mode,
		map = MAP_NAME, players = _players().size(), max_players = MODES[mode].max_players,
		port = _server_port, dedicated = is_dedicated_server,
	}


# Dedicated server only: sends heartbeats and shuts down after being empty for too long.
func _process(delta: float) -> void:
	if !is_dedicated_server: return
	if _heartbeat_http:
		_heartbeat_left -= delta
		if _heartbeat_left <= 0.0:
			_heartbeat_left = HEARTBEAT_SECONDS
			# An HTTPRequest node can only do one request at a time, so drop a stuck old one first.
			_heartbeat_http.cancel_request()
			# POST <master>/heartbeat with our info as JSON. We don't wait for or read the answer.
			_heartbeat_http.request(_master_url + "/heartbeat", ["Content-Type: application/json"],
				HTTPClient.METHOD_POST, JSON.stringify(_server_info()))
	if _quit_when_empty > 0.0:
		# Bots count as players here, so a server with bots never counts as empty.
		_empty_for = _empty_for + delta if _players().is_empty() else 0.0
		if _empty_for >= _quit_when_empty:
			print("[server] Nobody played for %d s - shutting down." % int(_quit_when_empty))
			get_tree().quit()


# The computer's login name ("USERNAME" on Windows, "USER" on Linux/macOS).
# Not used at the moment - GameSettings.get_value("player_name") does the same thing.
func _user_name() -> String:
	var n := OS.get_environment("USERNAME")
	if n == "": n = OS.get_environment("USER")
	return n if n != "" else "Player"


# --- Leaving / errors ---------------------------------------------------------------------

## Leave on purpose (pause menu). If we're hosting, everyone else gets sent back to their menu.
## (Closing the host's connection makes every client's server_disconnected signal fire.)
func leave_match() -> void:
	enet_peer.close()
	_back_to_menu("")


# Client: the server shut down or the host left.
func _on_server_disconnected() -> void:
	_back_to_menu("Lost connection: the server closed or the host left.")

# Client: joining failed (wrong address, server full or not running, firewall...).
func _on_connection_failed() -> void:
	_back_to_menu("Could not connect to %s." % _address)


# Ends networking and returns to the main menu, showing `message` there (empty = no message).
func _back_to_menu(message: String) -> void:
	multiplayer.multiplayer_peer = null   # stop all networking for this game instance
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if ResourceLoader.exists(MAIN_MENU_SCENE):
		# `notice` is a static variable on the menu script, so it survives the scene change;
		# the menu shows it when it opens.
		load("res://Scenes/UI/main_menu.gd").notice = message
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	else:
		push_warning(message)
		get_tree().reload_current_scene()


# --- Helpers ---------------------------------------------------------------------------------

# Arguments after "--" on the command line, e.g. -- --server --mode=deathmatch --port=9999
# Turned into a Dictionary: {"server": "true", "mode": "deathmatch", "port": "9999"}
# (all values are strings; a flag without "=" gets "true").
func _parse_user_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return out


## Opens the port on your router so people outside your network can join. Optional:
## not needed for LAN / same-PC testing, and many routers don't support it.
## UPnP lets a program ask the home router to forward a port to this PC automatically.
## Note: discover() can take a few seconds and freezes the game while it runs.
func upnp_setup(port: int) -> void:
	var upnp := UPNP.new()
	var discover_result := upnp.discover()
	if discover_result != UPNP.UPNP_RESULT_SUCCESS:
		push_warning("UPnP discovery failed (error %s) - forward port %d manually to play over the internet." % [discover_result, port])
		return
	if !(upnp.get_gateway() and upnp.get_gateway().is_valid_gateway()):
		push_warning("UPnP: no valid gateway found.")
		return
	# Forwards the game port only (the query port, game port + 100, is not opened).
	if upnp.add_port_mapping(port) != UPNP.UPNP_RESULT_SUCCESS:
		push_warning("UPnP: port mapping failed.")
		return
	print("UPnP OK! Join address: %s" % upnp.query_external_address())
