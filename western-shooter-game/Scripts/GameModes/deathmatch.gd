extends Node
## Death Match (design notes: GameModes/Death Match.md).
## This node exists on every peer under the level, named "GameMode". The SERVER owns the rules and
## the score; clients receive updates by RPC and show them on the Death Match HUD.
##
##  - Free-for-all, max 8 players, 5 minute matches (starts once 2 players are in).
##  - Points: a kill is worth 100. A victim on a kill streak (2+ kills without dying) is worth more:
##    150 at 2 kills, 200 at 3, +50 per extra kill. A victim who died 3+ times in a row is worth
##    only 50 until they get a kill again.
##  - Every 90 s an event: Underdog Boost - the bottom 3 players get double damage and +30% speed for 10 s.
##  - Health and ammo pickups around the map.
##  - After the match: results for 10 s, then a fresh match.
##
## HOW IT FITS TOGETHER
##  The level (Scripts/Multiplayer/multiplayer_test_scene.gd, _ensure_game_mode) creates this node
##  with .new(), sets `level` and adds it with the same name on every peer. Having the same node
##  path everywhere is what makes RPCs work: an RPC is sent "to the node at this path on the other
##  machine", so the server's GameMode can call functions on each client's GameMode.
##
## WHY THE SERVER OWNS THE SCORE
##  If every client counted its own kills, two clients could disagree (lag, packet order) or a
##  cheater could just give themselves points. So only the server changes `stats` and `phase`;
##  it then sends the whole result to everybody (_sync_stats / _sync_state). Clients only ever
##  DISPLAY these values. The one thing a client tells the server is "I died, X killed me"
##  (report_death), because each player's own peer is the one that knows its health hit zero.
##
## PHASE MACHINE (string `phase`, advanced in _process on the server)
##   waiting  --(enough players)-->  countdown  --(timer ends)-->  playing
##   playing  --(5 min over)-->  results  --(10 s)-->  countdown (or waiting if players left)
##   countdown --(players left)--> waiting

## Length of one match in seconds (5 minutes).
const MATCH_SECONDS := 300.0
## How long the results screen is shown before the next round.
const RESULTS_SECONDS := 10.0
## Seconds between Underdog Boost events during a match.
const EVENT_INTERVAL := 90.0
## How long the Underdog Boost lasts.
const BOOST_SECONDS := 10.0
## Players (humans + bots) needed before a match can start.
const MIN_PLAYERS := 2
const COUNTDOWN_FIRST := 10.0   ## Warm-up before the first match (kills don't count).
const COUNTDOWN_NEXT := 5.0     ## Short countdown after the results screen.
## Points for a normal kill.
const BASE_POINTS := 100
## Extra points per kill in the victim's streak beyond the first (see worth()).
const STREAK_BONUS := 50
## Deaths in a row after which a player counts as "on a losing streak".
const LOSING_STREAK_DEATHS := 3
## What a victim on a losing streak is worth (less, so nobody farms a struggling player).
const LOSING_STREAK_POINTS := 50

## Scoreboard / banners / kill feed UI script. Only created on peers that have a screen.
const HUD_SCRIPT := preload("res://Scenes/UI/deathmatch_hud.gd")
## Which scene to spawn for each pickup kind.
const PICKUP_SCENES := {
	"health": preload("res://Scenes/Pickups/health_pickup.tscn"),
	"ammo": preload("res://Scenes/Pickups/ammo_pickup.tscn"),
}
## Fallback pickup spots, used only if the level has no "PickupSpots" node. Normally the spots
## come from the Marker3D children of the level's PickupSpots node (names starting with
## "Health" or "Ammo"), so you can move them in the editor when the map changes.
const DEFAULT_PICKUP_SPOTS := [
	["health", Vector3(5, 0.5, 0)],
	["health", Vector3(-18, 0.5, 20)],
	["health", Vector3(28, 0.5, -20)],
	["ammo", Vector3(-18, 0.5, -20)],
	["ammo", Vector3(28, 0.5, 20)],
	["ammo", Vector3(5, 0.5, -25)],
	["ammo", Vector3(5, 0.5, 25)],
]

var level: Node                 ## Set by the level before adding this node.
## Player count needed to start (a variable so the level/tests can change it).
var min_players := MIN_PLAYERS
var phase := "waiting"          ## "waiting" | "countdown" | "playing" | "results"
## Seconds left in the current phase. Server is the truth; clients count down locally between syncs.
var time_left := 0.0
var stats := {}                 ## peer id -> {name, class, kills, deaths, streak, death_streak, points}
## Name of the last match's winner ("" while playing).
var winner := ""
## This peer's Death Match HUD (null on a dedicated server, which has no screen).
var hud: Control
## The player this peer controls (null on a dedicated server).
var local_player: Node

var _spots: Array = []          # [kind, position] - same order on every peer
var _event_left := EVENT_INTERVAL   # countdown to the next Underdog Boost (server)
var _sync_left := 0.0               # countdown to the next once-per-second state sync (server)


## Runs on every peer: spawns the pickups and (if this peer has a screen) the HUD.
func _ready() -> void:
	_spots = _read_pickup_spots()
	# Pickups are named Pickup0, Pickup1, ... in the same order on every peer, so the same name
	# means the same pickup everywhere - that's how the pickups' own RPCs find each other.
	for i in _spots.size():
		var pickup: Node3D = PICKUP_SCENES[_spots[i][0]].instantiate()
		pickup.name = "Pickup%d" % i
		pickup.position = _spots[i][1]
		add_child(pickup)
	# A dedicated server has no window, so it doesn't need a HUD.
	if !level.is_dedicated_server:
		hud = HUD_SCRIPT.new()
		hud.game_mode = self
		var layer: CanvasLayer = level.get_node("CanvasLayer")
		layer.add_child(hud)
		# Children of a CanvasLayer draw in order, so putting the HUD before the pause menu
		# keeps the pause menu on top of it.
		layer.move_child(hud, level.pause_menu.get_index())   # under the pause menu


## Reads pickup positions from the level's "PickupSpots" Marker3D children (kind from the node
## name), or returns DEFAULT_PICKUP_SPOTS if there are none. Returns [[kind, position], ...].
func _read_pickup_spots() -> Array:
	var holder: Node = level.get_node_or_null("PickupSpots")
	if holder == null: return DEFAULT_PICKUP_SPOTS
	var out := []
	for m in holder.get_children():
		if !(m is Node3D): continue
		var n := str(m.name).to_lower()
		if n.begins_with("health"): out.append(["health", m.global_position])
		elif n.begins_with("ammo"): out.append(["ammo", m.global_position])
	return out if !out.is_empty() else DEFAULT_PICKUP_SPOTS


## Called by the level for our own player.
## Connects the player's signals to the HUD and freezes them if we joined during the results screen.
func bind_local_player(p: Node) -> void:
	local_player = p
	hud.local_player = p
	p.died.connect(_on_local_player_died)
	p.boost_started.connect(hud.show_boost)
	p.frozen = phase == "results"


## Our own player died: show the death screen locally and tell the server who killed us
## (peer 1 is always the server).
func _on_local_player_died(killer_id: int) -> void:
	hud.show_death(stats[killer_id].name if stats.has(killer_id) else "", local_player.died_from_fall)
	report_death.rpc_id(1, killer_id)


# --- Server: players ----------------------------------------------------------------------

## Server: a player (human or bot) joined or changed class. Adds a fresh score line and sends
## the scoreboard, phase and pickup states out so the newcomer is up to date.
func register_player(id: int, player_name: String, class_name_text: String) -> void:
	if !multiplayer.is_server(): return
	if stats.has(id):   # already playing (switched class): keep the score, update the class
		stats[id].name = player_name
		# "class" is a GDScript keyword, so it can't be used with dot syntax - hence ["class"].
		stats[id]["class"] = class_name_text
		_sync_stats.rpc(stats)
		return
	stats[id] = {"name": player_name, "class": class_name_text, "kills": 0, "deaths": 0, "streak": 0, "death_streak": 0, "points": 0}
	_sync_stats.rpc(stats)
	_sync_state.rpc(phase, time_left)
	# A late joiner's pickups all start "available"; tell them which ones are currently taken.
	if id > 0 and id != multiplayer.get_unique_id():   # real remote players only (not us, not bots - bots have negative ids)
		var states := []
		for i in _spots.size(): states.append(get_node("Pickup%d" % i).available)
		_sync_pickups.rpc_id(id, states)


## Server: a player left - remove them from the scoreboard everywhere.
func unregister_player(id: int) -> void:
	if !multiplayer.is_server(): return
	stats.erase(id)
	_sync_stats.rpc(stats)


## How many points killing this player gives right now.
## Losing streak wins over everything (50). Otherwise streak 2 -> 150, 3 -> 200, 4 -> 250 ...
## (100 + 50 * (streak - 1)). Static, so the HUD can call it to show "worth" next to names.
static func worth(s: Dictionary) -> int:
	if s.death_streak >= LOSING_STREAK_DEATHS: return LOSING_STREAK_POINTS
	if s.streak >= 2: return BASE_POINTS + STREAK_BONUS * (s.streak - 1)
	return BASE_POINTS


# --- Server: match flow ---------------------------------------------------------------------

## The phase machine. Runs only on the server; clients just tick their timer down for display.
func _process(delta: float) -> void:
	# Not connected (yet / any more): nothing to do.
	if multiplayer.multiplayer_peer == null: return
	if !multiplayer.is_server():
		time_left = maxf(time_left - delta, 0.0)   # smooth countdown between server updates
		return
	match phase:
		"waiting":
			if stats.size() >= min_players: _start_countdown(COUNTDOWN_FIRST)
		"countdown":
			time_left -= delta
			# Someone left during the countdown - go back to waiting.
			if stats.size() < min_players:
				phase = "waiting"
				_sync_state.rpc(phase, 0.0)
			elif time_left <= 0.0:
				_start_match()
		"playing":
			time_left -= delta
			_event_left -= delta
			if _event_left <= 0.0:
				_event_left = EVENT_INTERVAL
				_underdog_event()
			if time_left <= 0.0: _end_match()
		"results":
			time_left -= delta
			if time_left <= 0.0:
				if stats.size() >= min_players: _start_countdown(COUNTDOWN_NEXT)
				else:
					phase = "waiting"
					_match_started.rpc()   # unfreeze whoever is left
					for b in level.get_bots(): b.frozen = false
	# Once a second, re-send phase + time so clients' timers can't drift far from the server's.
	_sync_left -= delta
	if _sync_left <= 0.0:
		_sync_left = 1.0
		_sync_state.rpc(phase, maxf(time_left, 0.0))


## Warm-up: everyone can move and shoot, nothing is scored; then the match starts fresh.
## (process_death ignores deaths unless phase is "playing".)
func _start_countdown(seconds: float) -> void:
	phase = "countdown"
	time_left = seconds
	_sync_state.rpc(phase, time_left)
	_countdown_started.rpc(seconds)
	# Bots live on the server, so the server unfreezes them directly.
	for b in level.get_bots(): b.frozen = false


## Everyone: unfreeze our player and show the "GET READY" banner.
## "authority" = only the server may call it; "call_local" = it also runs on the server itself.
@rpc("authority", "call_local", "reliable")
func _countdown_started(seconds: float) -> void:
	if local_player and is_instance_valid(local_player): local_player.frozen = false
	if hud: hud.show_banner("GET READY", "Match starts in %d seconds - warm-up kills don't count." % int(seconds))


## Server: reset every score to zero, start the 5 minute timer and respawn everyone.
func _start_match() -> void:
	for s in stats.values():
		for k in ["kills", "deaths", "streak", "death_streak", "points"]: s[k] = 0
	phase = "playing"
	time_left = MATCH_SECONDS
	_event_left = EVENT_INTERVAL
	_sync_stats.rpc(stats)
	_sync_state.rpc(phase, time_left)
	# Each peer respawns its own player (see _match_started); the server respawns the bots.
	_match_started.rpc()
	for b in level.get_bots():
		b.frozen = false
		b.respawn()


## Server: time is up - find the player with the most points, announce them, freeze everyone.
func _end_match() -> void:
	phase = "results"
	time_left = RESULTS_SECONDS
	var best := ""
	var best_points := -1
	# Strict ">" means on a tie the first player found keeps the win.
	for s in stats.values():
		if s.points > best_points:
			best_points = s.points
			best = s.name
	_sync_stats.rpc(stats)
	_sync_state.rpc(phase, time_left)
	_match_ended.rpc(best)
	for b in level.get_bots(): b.frozen = true


## Victim's peer -> server: "I died, killer_id got me".
## "any_peer" = any client is allowed to call this (normally only the server can call RPCs).
## The victim is taken from the RPC sender, not from a parameter, so a client can only ever
## report its OWN death - it can't claim someone else died.
@rpc("any_peer", "call_local", "reliable")
func report_death(killer_id: int) -> void:
	if !multiplayer.is_server(): return
	var victim := multiplayer.get_remote_sender_id()
	# Sender id 0 means the call came from this same machine (the host's own player died).
	if victim == 0: victim = multiplayer.get_unique_id()
	process_death(victim, killer_id)


## Scoring for one death (server). Public so tests / future modes can reuse it.
## Victim: +1 death, kill streak reset, losing streak +1. Killer: +1 kill, streak +1, losing
## streak reset, and gets the victim's worth. Suicides / falls (killer == victim or unknown)
## only count against the victim.
func process_death(victim: int, killer_id: int) -> void:
	if phase != "playing" or !stats.has(victim): return
	var v: Dictionary = stats[victim]
	var value := worth(v)          # value is decided BEFORE the victim's streak resets
	v.deaths += 1
	v.streak = 0
	v.death_streak += 1
	var points := 0
	var killer_name := ""
	if stats.has(killer_id) and killer_id != victim:
		var k: Dictionary = stats[killer_id]
		k.kills += 1
		k.streak += 1
		k.death_streak = 0
		k.points += value
		points = value
		killer_name = k.name
	_sync_stats.rpc(stats)
	_kill_feed.rpc(killer_name, v.name, points, killer_id, victim)


## Event: the bottom 3 (never the leader) get a short boost.
## Sorting by points ascending puts the weakest players first; at most size-1 players are boosted
## so the top player never is (with 2 players only the last one gets it).
func _underdog_event() -> void:
	var ids := stats.keys()
	if ids.size() < 2: return
	ids.sort_custom(func(a, b): return stats[a].points < stats[b].points)
	var names := PackedStringArray()
	for i in mini(3, ids.size() - 1):
		var id: int = ids[i]
		names.append(stats[id].name)
		# Player nodes are named after their peer id. The boost is sent to whoever controls that
		# player (its multiplayer authority) because that peer runs its movement and damage.
		var p = level.get_node_or_null(str(id))
		if p: p.receive_boost.rpc_id(p.get_multiplayer_authority(), BOOST_SECONDS)
	# "%%" is how you write a literal % sign inside a format string.
	_announce.rpc("UNDERDOG BOOST", "%s get double damage and +30%% speed for %d s!" % [", ".join(names), int(BOOST_SECONDS)])


# --- Everyone: updates from the server -------------------------------------------------------
# All of these are "authority" RPCs: only the server can send them. "reliable" means they are
# guaranteed to arrive and in order (important for scores; a lost update would leave a wrong score).

## Replace our copy of the scoreboard with the server's and redraw the HUD.
@rpc("authority", "call_local", "reliable")
func _sync_stats(new_stats: Dictionary) -> void:
	stats = new_stats
	if hud: hud.refresh()


## Receive the current phase + timer. Players are frozen only on the results screen.
@rpc("authority", "call_local", "reliable")
func _sync_state(new_phase: String, new_time_left: float) -> void:
	phase = new_phase
	time_left = new_time_left
	if local_player: local_player.frozen = phase == "results"


## A match started (or we went back to waiting): unfreeze and respawn our player.
@rpc("authority", "call_local", "reliable")
func _match_started() -> void:
	winner = ""
	if local_player:
		local_player.frozen = false
		local_player.respawn()   # everyone starts fresh: full health, ammo, new spawn
	if hud and phase == "playing":
		hud.show_banner("DRAW!", "Most points in 5 minutes wins.")


## The match ended: remember the winner, freeze our player and show the banner.
@rpc("authority", "call_local", "reliable")
func _match_ended(winner_name: String) -> void:
	winner = winner_name
	if local_player: local_player.frozen = true
	if hud: hud.show_banner("MATCH OVER", "%s wins!" % winner_name if winner_name != "" else "")


## Add a line to the kill feed (killer_name is "" for suicides / falls).
@rpc("authority", "call_local", "reliable")
func _kill_feed(killer_name: String, victim_name: String, points: int, killer_id: int, victim_id: int) -> void:
	if hud: hud.add_kill(killer_name, victim_name, points, killer_id, victim_id)


## Show a big announcement banner (used by events like Underdog Boost).
@rpc("authority", "call_local", "reliable")
func _announce(title: String, text: String) -> void:
	if hud: hud.show_banner(title, text)


## Late joiner only (no call_local): mark which pickups are currently taken. Index i matches
## the node "Pickup<i>", which is why _spots must be in the same order on every peer.
@rpc("authority", "reliable")
func _sync_pickups(states: Array) -> void:
	for i in mini(states.size(), _spots.size()):
		get_node("Pickup%d" % i).set_available_local(states[i])
