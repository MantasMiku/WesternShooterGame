extends Node
## Bot "brain". Added (on the server only) as a child of a player with is_bot = true, and drives
## it the way a person would - through the same movement, look and weapon code:
##  - picks the nearest enemy it can actually see,
##  - turns toward it at a limited speed with some aim error, and waits a reaction time before shooting,
##  - strafes and keeps a good distance for its weapon (close with shotguns/melee, further with rifles),
##  - reloads, and switches to melee when completely out of ammo,
##  - goes for health packs when hurt and ammo crates when low, otherwise roams,
##  - turns toward whoever shot it, and jumps when stuck.
##
## WHERE IT LIVES / WHO RUNS IT
##  The level (Scripts/Multiplayer/multiplayer_test_scene.gd, _attach_bot_brain) creates this node
##  with BotBrain.new(), sets `player`, `level` and `difficulty`, and adds it under the bot's player
##  node. That only happens on the SERVER: bots belong to the server (they have negative peer ids),
##  so the server simulates them and their position/rotation is synced to clients like any other
##  player. Clients never run this script.
##
## HOW IT "PRESSES BUTTONS"
##  The brain never moves the body directly. Instead it fills in fake inputs on the player:
##   - player.bot_move   (Vector2, like Input.get_vector: x = right, y = back, so -1 = forward)
##   - player.bot_sprint / player.bot_jump  (bools, like holding Shift / pressing Space)
##   - player.rotation.y and player.camera.rotation.x  (like moving the mouse)
##   - weapon_manager.select_weapon() / try_primary_fire()  (like number keys / left click)
##  player_controller.gd reads these instead of the keyboard when is_bot is true, so bots obey
##  exactly the same physics, speeds, cooldowns and ammo rules as human players.
##
## THE DECISION LOOP (every physics frame, see _physics_process)
##  1. Every 0.25 s "think": choose a target (_find_target) and roll a new random aim mistake.
##  2. If there is a target -> _fight (aim, maybe shoot, pick weapon, strafe, keep distance).
##     Otherwise -> _roam (walk along a navigation path to a goal: pickup, alert spot or random point).
##  3. _check_stuck: if we want to move but aren't, jump / change strafe / pick a new goal.

## The three skill levels. Chosen by the host when adding bots.
enum Difficulty { EASY, NORMAL, HARD }

## Tuning numbers for each difficulty:
##  - aim_error:  max aiming mistake in degrees (the random _aim_offset is built from this).
##  - reaction:   seconds the target must be in view before the bot starts shooting.
##  - turn_speed: how fast the bot's view swings toward the aim point (used as a lerp factor per second).
##  - fire_cone:  bot only fires when its crosshair is within this many degrees of the aim point.
##  - view_range: enemies further than this (metres) are ignored.
##  - aim_height: height above the target's feet to aim at (1.5 is roughly head height = headshots).
const PROFILES := {
	Difficulty.EASY:   {"aim_error": 7.0, "reaction": 0.65, "turn_speed": 4.0, "fire_cone": 9.0, "view_range": 35.0, "aim_height": 1.2},
	Difficulty.NORMAL: {"aim_error": 3.5, "reaction": 0.38, "turn_speed": 7.0, "fire_cone": 6.0, "view_range": 50.0, "aim_height": 1.3},
	Difficulty.HARD:   {"aim_error": 1.5, "reaction": 0.2, "turn_speed": 12.0, "fire_cone": 4.0, "view_range": 70.0, "aim_height": 1.5},
}
## Fallback roaming area (x/z square in metres) if the level has no navigation mesh.
const ARENA := Rect2(-38, -38, 76, 76)   # fallback roaming area if the level has no navigation
## Random roam goals higher than this are rejected (navmesh bits on rooftops can't be reached on foot).
const MAX_GOAL_HEIGHT := 8.0             # ignore navmesh bits on rooftops (unreachable on foot)

var player: CharacterBody3D       ## The bot's body (set by the level).
var level: Node                   ## The level (for the player list and pickups).
## Current skill level; picks which entry of PROFILES is used.
var difficulty := Difficulty.NORMAL

# --- Internal state (only this script touches these) ---
var _target: Node3D = null        # enemy we are currently fighting (null = roaming)
var _seen_for := 0.0              # how long the current target has been in sight (reaction time)
var _think_left := 0.0            # countdown to the next "think" (target search + new aim error)
var _aim_offset := Vector3.ZERO   # current aiming mistake (a direction offset; multiplied by distance when used)
var _strafe := 1.0                # current sideways direction: -1 left, 1 right, 0 none
var _strafe_left := 0.0           # seconds until we pick a new strafe direction
var _goal := Vector3.ZERO         # where we are walking to while roaming
var _goal_left := 0.0             # seconds before we give up on _goal and pick another
var _stuck_for := 0.0             # how long we've been pushing against something without moving
var _alert_pos = null             # where we got shot from (Vector3 or null)
var _alert_left := 0.0            # how much longer we keep heading toward _alert_pos
var _path := PackedVector3Array()     # navigation path to _goal
var _path_i := 0                  # index of the next corner of _path we are walking to
var _path_goal := Vector3.INF     # the goal _path was computed for (INF = no path yet)
var _repath_left := 0.0           # countdown until we recompute the path (the world/goal may change)


## Hooks up to the body's signals and chooses a first place to walk to.
func _ready() -> void:
	# Getting hurt makes the bot look toward the attacker (see _on_damage_taken).
	player.damage_taken.connect(_on_damage_taken)
	# After respawning, forget the old fight and choose a fresh goal right away.
	player.respawned.connect(func(): _target = null; _goal_left = 0.0)
	_pick_goal()


## The tuning numbers for the current difficulty (one row of PROFILES).
func _profile() -> Dictionary:
	return PROFILES[difficulty]


## Main loop, runs every physics frame on the server. Clears the one-frame "jump" input, then
## either fights or roams, and finally checks whether we are stuck.
func _physics_process(delta: float) -> void:
	# Jump is a one-frame "button press": reset it every frame, it's set again only when wanted.
	player.bot_jump = false
	# Dead bots or frozen ones (results screen) just stand still.
	if player.is_dead or player.frozen:
		player.bot_move = Vector2.ZERO
		return

	# Target left the game / switched class: forget it.
	if _target and (!is_instance_valid(_target) or !_target.is_inside_tree()):
		_target = null
	# "Thinking" is throttled to 4 times a second: raycasts for every enemy each frame would be
	# wasteful, and real players don't re-evaluate targets 60 times a second either.
	_think_left -= delta
	if _think_left <= 0.0:
		_think_left = 0.25
		_target = _find_target()
		# New random aim mistake. tan(angle) turns an angle error into "how far off sideways per
		# metre of distance"; later this gets multiplied by the distance to the target, so the
		# miss is the same ANGLE at any range (like a real shaky hand). Vertical error is smaller (0.6).
		var err: float = deg_to_rad(_profile().aim_error)
		_aim_offset = Vector3(randf_range(-1, 1), randf_range(-0.6, 0.6), randf_range(-1, 1)) * tan(err)

	if _target:
		_fight(delta)
	else:
		_seen_for = 0.0
		# Medic bots in team modes: heal a hurt teammate in sight before wandering off.
		if !_heal_teammate(delta):
			_roam(delta)
	_check_stuck(delta)


# --- Finding enemies --------------------------------------------------------------------

## Returns the closest living enemy within view_range that we have line of sight to (or null).
func _find_target() -> Node3D:
	var best: Node3D = null
	# Start with the view range as the "best distance", so anyone further away is never picked.
	var best_dist := float(_profile().view_range)
	for p in level._players():
		# Skip ourselves, dead players and teammates (team modes).
		if p == player or p.is_dead or player.is_teammate(p): continue
		var d: float = player.global_position.distance_to(p.global_position)
		# Check distance first because the raycast in _can_see is the expensive part.
		if d < best_dist and _can_see(p):
			best_dist = d
			best = p
	# A new target means the reaction timer starts again from zero.
	if best != _target: _seen_for = 0.0
	return best


## Line-of-sight test: casts a ray from the bot's eyes (camera) to the enemy's chest.
## If the ray hits nothing in the world, the enemy is visible.
func _can_see(p: Node3D) -> bool:
	var from: Vector3 = player.camera.global_position
	var to := p.global_position + Vector3.UP * 1.2
	# Collision mask 0b01 = only layer 1 (the static world), so other players don't block the
	# view. Our own body is excluded so the ray doesn't hit ourselves.
	var q := PhysicsRayQueryParameters3D.create(from, to, 0b01, [player.get_rid()])   # world only
	# Empty result = the ray reached the target without hitting a wall.
	return player.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# --- Fighting ---------------------------------------------------------------------------

## Combat behaviour for one frame: choose a weapon, aim (with error), fire when ready,
## and move to keep a good distance while strafing.
func _fight(delta: float) -> void:
	_seen_for += delta
	var dist := player.global_position.distance_to(_target.global_position)
	var wm = player.weapon_manager
	var weapon = wm.get_current_weapon() if wm else null
	_pick_weapon(wm, weapon, dist)

	# Aim point = target's feet + aim height + aim error. The error is a per-metre offset, so
	# multiplying by distance keeps the angular mistake the same near and far.
	var aim_point: Vector3 = _target.global_position + Vector3.UP * float(_profile().aim_height) + _aim_offset * dist   # hard bots go for heads
	# Thrown weapons (dynamite) fly in an arc and drop because of gravity. bot_aim_lift (in
	# thrown_weapon.gd) uses projectile maths (drop = 1/2 * g * t^2, with t = dist / throw_speed)
	# to tell how much higher to aim. -0.9 moves the aim back down from chest height toward the feet.
	if weapon and weapon.has_method("bot_aim_lift"):   # thrown weapons: lob it so it lands at their feet
		aim_point += Vector3.UP * (weapon.bot_aim_lift(dist) - 0.9)
	_look_at(aim_point, delta)

	# Shoot once we've had time to react and the crosshair is close enough to the target.
	# The camera looks down its -Z axis; compare that with the direction to the aim point.
	var cam: Camera3D = player.camera
	var forward: Vector3 = -cam.global_basis.z
	var to_target: Vector3 = (aim_point - cam.global_position).normalized()
	var off_by: float = rad_to_deg(forward.angle_to(to_target))
	if _seen_for >= _profile().reaction and off_by <= _profile().fire_cone:
		# Also "fire" when the magazine is empty: for guns that triggers a reload, the same as a
		# player clicking with an empty gun.
		if weapon and weapon.has_method("can_fire") and (weapon.can_fire() or (weapon.uses_ammo() and weapon.ammo == 0)):
			wm.try_primary_fire()

	# Movement: keep the right distance for the weapon, strafe side to side.
	# Preferred distance by weapon type: melee (no ammo) right up close, dynamite at mid range so
	# we don't catch ourselves in the blast, shotguns (several pellets) fairly close, rifles/pistols far.
	var preferred := 16.0
	if weapon and !weapon.uses_ammo(): preferred = 1.6
	elif weapon and weapon.has_method("bot_aim_lift"): preferred = 10.0   # dynamite: not too close
	elif weapon and _pellets(weapon) > 1: preferred = 7.0
	# A +/- 2 m "dead zone" so the bot doesn't jitter back and forth around the exact distance.
	var forward_amount := 0.0
	if dist > preferred + 2.0: forward_amount = 1.0
	elif dist < preferred - 2.0: forward_amount = -0.7
	# Every 0.6-1.8 s pick a new random strafe direction (left, right or stand still) - this
	# makes bots much harder to hit than if they walked in a straight line.
	_strafe_left -= delta
	if _strafe_left <= 0.0:
		_strafe_left = randf_range(0.6, 1.8)
		_strafe = [-1.0, 1.0, 0.0].pick_random()
	# y is "backwards" in Input.get_vector style, hence the minus sign for forward.
	player.bot_move = Vector2(_strafe * 0.85, -forward_amount)
	# Sprint only when far away (sprinting usually hurts accuracy / looks silly up close).
	player.bot_sprint = dist > preferred + 8.0
	# Hard bots sometimes hop (about once every 100 frames, ~1.7 s) to dodge shots.
	if difficulty == Difficulty.HARD and randf() < 0.01: player.bot_jump = true


## Picks the best weapon for the moment:
##  - Out of ammo -> another gun with ammo, else melee.
##  - Shotguns up close, single-shot guns at range.
##  - Explosives are for mid range: switch off them when the target is too close (we'd blow
##    ourselves up) and back to them once there's room again.
## The rules below are checked in order; `want` stays -1 until one of them finds a better
## slot, and the first rule that finds one wins.
func _pick_weapon(wm, weapon, dist := 10.0) -> void:
	if wm == null or weapon == null: return
	# Hurt and carrying a self-heal (Medic's syringe in Death Match)? Use it.
	# A "non-attack" weapon that can fire is a self-use item such as the syringe.
	var heal_i := _find_weapon(wm, func(w): return w.has_method("is_self_use") and w.is_self_use() and w.can_fire())
	if heal_i >= 0 and player.health < player.max_health * 0.6 and player.get_heal_time_left() <= 0.0:
		# First frame: switch to it. Next frames (once it's in hand): use it.
		if wm.current_index != heal_i: wm.select_weapon(heal_i)
		else: wm.try_primary_fire()
		return
	var want := -1
	# Small helper lambdas (Callables) used as tests for _find_weapon:
	#  has_ammo  - an attack weapon that still has bullets in the magazine or in reserve
	#  is_thrown - a thrown explosive (has the bot_aim_lift method)
	var has_ammo := func(w): return _is_attack(w) and w.uses_ammo() and (w.ammo > 0 or w.reserve > 0)
	var is_thrown := func(w): return w.has_method("bot_aim_lift")
	# Rule 1: current gun is completely empty -> any other weapon with ammo (but not dynamite at
	# point-blank range), otherwise fall back to a melee weapon that hurts enemies.
	if weapon.uses_ammo() and !has_ammo.call(weapon):
		want = _find_weapon(wm, func(w): return has_ammo.call(w) and !(is_thrown.call(w) and dist < 5.0))
		if want < 0: want = _find_weapon(wm, func(w): return !w.uses_ammo() and w.get("damages_enemies"))
	# Rule 2: holding dynamite but the enemy is too close -> switch to a normal gun.
	elif is_thrown.call(weapon) and dist < 4.5:
		want = _find_weapon(wm, func(w): return has_ammo.call(w) and !is_thrown.call(w))
	# Rule 3: enemy at mid/long range and we have dynamite with ammo -> use it.
	# (4.5 vs 7.0 is a gap on purpose, so the bot doesn't flip between weapons every frame.)
	elif !is_thrown.call(weapon) and dist > 7.0:
		want = _find_weapon(wm, func(w): return is_thrown.call(w) and has_ammo.call(w))
	# Guns: shotgun up close, single-shot guns at range (if we have both).
	var is_spread := func(w): return has_ammo.call(w) and !is_thrown.call(w) and _pellets(w) > 1
	var is_single := func(w): return has_ammo.call(w) and !is_thrown.call(w) and _pellets(w) == 1
	if want < 0 and is_single.call(weapon) and dist < 5.0:
		want = _find_weapon(wm, func(w): return is_spread.call(w) and w.ammo > 0)
	elif want < 0 and is_spread.call(weapon) and dist > 12.0:
		want = _find_weapon(wm, func(w): return is_single.call(w) and has_ammo.call(w))
	# Last rule: holding melee or a self-use item while fighting -> go back to a gun if we have ammo.
	if want < 0 and (!weapon.uses_ammo() or !_is_attack(weapon)):
		want = _find_weapon(wm, func(w): return has_ammo.call(w) and !(is_thrown.call(w) and dist < 5.0))
	if want >= 0: wm.select_weapon(want)


## Returns true for normal attack weapons, false for healing items (the Medic's syringe, which
## heals yourself in Death Match and fires healing darts at teammates in team modes).
func _is_attack(w) -> bool:
	return !w.has_method("is_self_use")


# --- Healing teammates (Medic bots in team modes) -----------------------------------------

## The teammate we are currently trying to heal (null = none).
var _heal_mate: Node3D = null

## Medic bot with healing darts: picks a hurt teammate it can see, turns to them, walks closer
## if they're far, and fires darts. Returns false when there is nobody to heal (or no darts),
## so the caller roams instead.
func _heal_teammate(delta: float) -> bool:
	var wm = player.weapon_manager
	if wm == null: return false
	# A dart syringe with darts loaded or spares to reload (clicking it empty starts the reload).
	var i := _find_weapon(wm, func(w): return w.has_method("bot_dart_lift") and !w.is_self_use() and (w.ammo > 0 or w.reserve > 0))
	if i < 0: return false
	# Re-pick the teammate on the same 4-times-a-second "think" as targets (cheap raycasts).
	if _think_left >= 0.24 or _heal_mate == null or !is_instance_valid(_heal_mate) or !_needs_heal(_heal_mate):
		_heal_mate = _find_hurt_teammate()
	if _heal_mate == null: return false
	if wm.current_index != i:
		wm.select_weapon(i)
		return true
	var dart = wm.weapons[i]
	var dist := player.global_position.distance_to(_heal_mate.global_position)
	# Aim at the chest, raised by the dart's drop over that distance.
	var aim_point: Vector3 = _heal_mate.global_position + Vector3.UP * (1.1 + float(dart.bot_dart_lift(dist)))
	_look_at(aim_point, delta)
	# Walk toward them if far, otherwise stand and shoot.
	player.bot_move = Vector2(0, -1) if dist > 18.0 else Vector2.ZERO
	player.bot_sprint = dist > 25.0
	var forward: Vector3 = -player.camera.global_basis.z
	var to_mate: Vector3 = (aim_point - player.camera.global_position).normalized()
	if rad_to_deg(forward.angle_to(to_mate)) <= 4.0 and (dart.can_fire() or dart.ammo == 0):
		wm.try_primary_fire()   # with an empty syringe this starts a reload, like a player clicking
	return true


## True if this teammate is alive, hurt, and not already being healed (the green sparkles flag
## is synced to every peer, so this works for human teammates on other computers too).
func _needs_heal(p) -> bool:
	return !p.is_dead and p.health < p.max_health and (p.status_flags & p.STATUS_HEALING) == 0


## The closest hurt teammate within 35 m that we can see, or null.
func _find_hurt_teammate() -> Node3D:
	var best: Node3D = null
	var best_dist := 35.0
	for p in level._players():
		if p == player or !player.is_teammate(p) or !_needs_heal(p): continue
		var d: float = player.global_position.distance_to(p.global_position)
		if d < best_dist and _can_see(p):
			best_dist = d
			best = p
	return best


## How many pellets one shot fires (shotguns > 1). Weapons without the property count as 1.
func _pellets(w) -> int:
	# w.get() returns null if the weapon script has no "pellet_count" variable.
	var n = w.get("pellet_count")
	return int(n) if n != null else 1


## Index of the first weapon in the weapon manager for which `test` returns true, or -1.
func _find_weapon(wm, test: Callable) -> int:
	for i in wm.weapons.size():
		if test.call(wm.weapons[i]): return i
	return -1


# --- Roaming ----------------------------------------------------------------------------

## No enemy in sight: run (sprinting) along the navigation path toward the current goal,
## picking a new goal when we arrive or the goal times out.
func _roam(delta: float) -> void:
	_alert_left -= delta
	if _alert_pos != null and _alert_left > 0.0:
		# Someone shot us from out of sight: turn and head that way.
		_goal = _alert_pos
	_goal_left -= delta
	# Distance on the ground only (x/z), so height differences (stairs, slopes) don't matter.
	var flat_dist := Vector2(_goal.x - player.global_position.x, _goal.z - player.global_position.z).length()
	if _goal_left <= 0.0 or flat_dist < 2.0:
		_pick_goal()
	var wp := _next_waypoint(_goal, delta)
	# Look at the next path corner at eye height (so the bot looks straight ahead, not at the floor),
	# then just walk "forward" - turning the view is what steers the bot, like a player with a mouse.
	_look_at(Vector3(wp.x, player.camera.global_position.y, wp.z), delta)
	player.bot_move = Vector2(0, -1)
	player.bot_sprint = true


## Chooses where to walk next: the nearest health pack if hurt (< 40% health), the nearest ammo
## crate if low on ammo, otherwise a random reachable point on the navigation mesh.
func _pick_goal() -> void:
	_goal_left = randf_range(6.0, 12.0)
	var want := ""
	if player.health < player.max_health * 0.4: want = "health"
	elif _low_on_ammo(): want = "ammo"
	if want != "" and level.game_mode:
		# Pickups are children of the game mode node (see deathmatch.gd). We recognise them by
		# their set_available_local method, and skip ones that were already taken (respawning).
		var best = null
		var best_d := INF
		for child in level.game_mode.get_children():
			if !child.has_method("set_available_local") or !child.available: continue
			# kind 0 = health pickup, anything else = ammo. Skip the kind we don't want.
			if (want == "health") != (child.kind == 0): continue
			var d: float = player.global_position.distance_to(child.global_position)
			if d < best_d:
				best_d = d
				best = child
		if best:
			_goal = best.global_position
			return
	# Somewhere random we can actually walk to (on the navigation mesh), else anywhere.
	var map := _nav_map()
	# Iteration id 0 means the navigation map was never built (level has no NavigationRegion3D).
	if NavigationServer3D.map_get_iteration_id(map) > 0:
		# Try up to 8 random navmesh points (navigation layer 1); reject rooftop ones.
		for i in 8:
			var p := NavigationServer3D.map_get_random_point(map, 1, false)
			if p.y < MAX_GOAL_HEIGHT:
				_goal = p
				return
	# No navmesh (or only rooftop points found): random spot inside the ARENA rectangle.
	_goal = Vector3(randf_range(ARENA.position.x, ARENA.end.x), 1.0, randf_range(ARENA.position.y, ARENA.end.y))


## The navigation map of the 3D world the bot is in (built from the level's NavigationRegion3D).
func _nav_map() -> RID:
	return player.get_world_3d().navigation_map


## The next corner of the navigation path to `goal` (or the goal itself without navigation).
## The path is a list of points around obstacles computed by NavigationServer3D. We walk to
## the first point we haven't reached yet; reached points are skipped.
func _next_waypoint(goal: Vector3, delta: float) -> Vector3:
	_repath_left -= delta
	# Recompute the path when the goal moved noticeably, or once per second anyway (the bot
	# may have been pushed off the path, e.g. by strafing in a fight or by an explosion).
	if _path_goal.distance_to(goal) > 1.5 or _repath_left <= 0.0:
		_repath_left = 1.0
		_path_goal = goal
		# `true` = optimise the path (string-pulling), giving straight lines between corners.
		_path = NavigationServer3D.map_get_path(_nav_map(), player.global_position, goal, true)
		_path_i = 0
	# Skip every corner we are already within 0.9 m of (measured on the ground plane).
	while _path_i < _path.size():
		var p: Vector3 = _path[_path_i]
		if Vector2(p.x - player.global_position.x, p.z - player.global_position.z).length() < 0.9:
			_path_i += 1
		else:
			return p
	# Path finished or empty (no navmesh): head straight for the goal.
	return goal


## True if any attack weapon has less than 30% of its full reserve ammo.
func _low_on_ammo() -> bool:
	var wm = player.weapon_manager
	if wm == null: return false
	for w in wm.weapons:
		if w.uses_ammo() and _is_attack(w) and w.reserve < w.reserve_ammo * 0.3: return true
	return false


## Called when the bot gets hurt. If it wasn't already fighting someone, it remembers where the
## shot came from for 3 s and heads/looks that way (see _roam), and searches for targets immediately.
func _on_damage_taken(_amount: int, attacker_position) -> void:
	# attacker_position is null for damage without a source position (e.g. falling).
	if attacker_position is Vector3 and _target == null:
		_alert_pos = attacker_position
		_alert_left = 3.0
		_think_left = 0.0   # look for them right away


# --- Helpers ----------------------------------------------------------------------------

## Turn body (yaw) and head (pitch) toward a point, no faster than turn_speed allows.
## Like a player: the whole body turns left/right, only the camera tilts up/down.
func _look_at(point: Vector3, delta: float) -> void:
	var eye: Vector3 = player.camera.global_position
	var d := point - eye
	# Point is (almost) exactly at our eyes: no direction to look in.
	if d.length_squared() < 0.0001: return
	# Yaw: angle around the Y axis. Godot's "forward" is -Z, hence atan2(-x, -z).
	var yaw := atan2(-d.x, -d.z)
	# Pitch: angle up/down = atan2(height difference, horizontal distance).
	var pitch := atan2(d.y, Vector2(d.x, d.z).length())
	# Move a fraction t of the way toward the wanted angles each frame. Because it's a fraction
	# of the REMAINING angle, turning is fast when far off and slows down when nearly on target
	# (smooth, human-like). lerp_angle takes the short way round (e.g. 350 deg -> 10 deg goes +20, not -340).
	var t: float = clampf(_profile().turn_speed * delta, 0.0, 1.0)
	player.rotation.y = lerp_angle(player.rotation.y, yaw, t)
	# Clamp pitch to just under straight up/down, like the player's mouse look.
	player.camera.rotation.x = clampf(lerp_angle(player.camera.rotation.x, pitch, t), deg_to_rad(-89), deg_to_rad(89))


## Detects "walking into a wall": we are pressing a direction but barely moving while on the floor.
## After 0.6 s: jump and reverse the strafe. After 1.5 s: give up on the goal and choose a new one.
func _check_stuck(delta: float) -> void:
	var bot_move: Vector2 = player.bot_move
	var trying: bool = bot_move.length() > 0.5
	# Horizontal speed only; falling/jumping speed doesn't count as "moving".
	var moving: bool = Vector2(player.velocity.x, player.velocity.z).length() > 1.0
	if trying and !moving and player.is_on_floor():
		_stuck_for += delta
		if _stuck_for > 0.6:
			player.bot_jump = true
			# Flip strafe direction (or start strafing right if we weren't strafing).
			_strafe = -_strafe if _strafe != 0.0 else 1.0
			if _stuck_for > 1.5:
				_pick_goal()
				_repath_left = 0.0   # force a new path on the next frame
				_stuck_for = 0.0
	else:
		_stuck_for = 0.0
