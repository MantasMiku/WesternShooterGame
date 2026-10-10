extends CharacterBody3D
class_name PlayerController
## The base player: movement, looking around, health, death/respawn, buffs and healing.
##
## WHERE IT IS USED
## This script sits on the root node (a CharacterBody3D) of Scenes/Player/player_controller.tscn.
## Every playable class (Medic, Sheriff, Gunslinger, Bomber) is a scene that uses a script which
## [code]extends[/code] this one, so they all share this movement and health code and only add
## their own weapons (a WeaponManager child node) and passive abilities on top.
## Players are created by the MultiplayerSpawner in Scripts/Multiplayer/multiplayer_test_scene.gd
## ([code]_spawn_player()[/code]), which names each player node after its id and fills in
## team, spawn_position, player_name, is_bot and start_dead_for before it enters the tree.
##
## MOVEMENT STYLE
## The movement copies the Source engine / Quake feel (Half-Life, Counter-Strike, TF2):
## ground acceleration + friction, very little air control but "air strafing" and bunny hopping
## are possible, the player steps up/down stairs smoothly, can crouch (and crouch-jump),
## swim, and (debug builds only) fly through walls with noclip.
##
## MULTIPLAYER - WHO RUNS WHAT
## Each player node has a "multiplayer authority" = the peer that owns and controls it:
##  - a real person's player is owned by that person's peer (their computer),
##  - a bot is owned by the server (peer id 1).
## Only the owner runs the movement in _physics_process and reads the keyboard/mouse. The
## MultiplayerSynchronizer child node (set up in player_controller.tscn) then copies the owner's
## position, rotation, camera pitch, is_dead, health and status_flags to every other peer, so
## everyone sees the same thing. This is "client-authoritative" movement: simple and lag-free
## for the person playing, at the cost of trusting each client.
## Damage, healing, ammo and buffs are delivered with RPCs (remote procedure calls) sent to the
## owner's peer, because the owner is the one who "owns" the health value.

# --- Signals (the HUD, kill cam and game modes connect to these) ---------------------------

## Health changed (damage, healing, respawn). health_value is the new health. (Owner's peer only.)
signal  health_changed(health_value)
## You got hit. attacker_position is the attacker's world position, or null if unknown. (Owner's peer only.)
signal damage_taken(amount: int, attacker_position: Variant)
## Your attack landed. world_position is where it hit; is_heal for healing weapons. (Owner's peer only.)
signal damage_dealt(amount: int, world_position: Vector3, is_heal: bool, is_headshot: bool)
## Health hit zero. killer_id = peer id of whoever dealt the last hit (0 if unknown). (Owner's peer only.)
signal died(killer_id: int)
## Came back after dying (or was reset at the start of a match). (Owner's peer only.)
signal respawned
## Temporary buff started (e.g. Death Match underdog boost). (Owner's peer only.)
signal boost_started(seconds: float)

# --- Node references ---------------------------------------------------------------------
# @onready means "fill this in right before _ready() runs", when the child nodes exist.
# $Path finds a child by its path; %Name finds a node marked "Access as Unique Name" in the scene.

## Plays the "idle", "move" and "shoot" animations of the built-in shotgun view model.
@onready var animator = $AnimationPlayer
## Muzzle flash particles of the built-in shotgun (only used by the base class, see _primary_fire).
@onready var shootParticle = $"HeadOriginalPosition/Head/CameraSmooth/Camera3D/Pump-Shotgun-Long/MuzzleFlash"
## Ray pointing straight out of the camera; what it touches is what the built-in shotgun hits.
@onready var raycast = $HeadOriginalPosition/Head/CameraSmooth/Camera3D/RayCast3D
## The first-person camera. It only rotates up/down (pitch); left/right turns the whole body.
@onready var camera: Camera3D = %Camera3D
## Classes with a WeaponManager child node (Medic, Sheriff...) use it for attacks instead of the built-in shotgun.
## get_node_or_null returns null (instead of an error) when the node doesn't exist.
@onready var weapon_manager = get_node_or_null("WeaponManager")
## Hit detection: the CollisionShape3D capsule is the body, this sphere around the head is the
## head. Bullets that pass through it count as headshots (see hitscan_weapon.gd).
## Tip: Debug > Visible Collision Shapes in the editor shows both while playing.
@onready var head_hitbox: Area3D = get_node_or_null("HeadOriginalPosition/Head/HeadHitbox")
## Physics layer 3 (bit value 4) holds the head hitboxes, so weapon rays can look for them separately.
const HITBOX_LAYER := 0b100

## Saved options (mouse sensitivity, field of view...). preload loads the script once at compile time.
const GameSettings = preload("res://Scripts/Global/game_settings.gd")
## False while a menu (e.g. the pause menu) is open: no moving, looking or shooting.
var input_enabled := true
## Option: guns reload by themselves (Esc > Options > Auto reload). Bots always have it on.
var auto_reload_enabled := true
## True while the game mode holds everyone still (e.g. the results screen after a match).
var frozen := false

# --- Death and respawn -------------------------------------------------------------------

@export var respawn_delay := 3.0   ## Seconds dead before respawning.
## Safety net under every map: falling below this height (metres, world Y) kills you even without a death zone.
@export var kill_height := -80.0
## Falling to your death within this many seconds of being hurt gives the kill to whoever hurt you.
const FALL_CREDIT_SECONDS := 6.0
## combat_id of the last player who hurt us (0 = nobody). Used to give credit for fall deaths.
var _last_attacker := 0
## Time (seconds since the game started) when we were last hurt by someone.
var _last_attacked_at := -100.0
var died_from_fall := false   ## How the last death happened (for the death screen).
var death_weapon := ""        ## What dealt the killing blow (for the kill cam).
var _fall_safe_until := 0.0   # just respawned: the death zone may still "see" where we died
## Dead players are hidden and can't be hit. Synced to everyone by the MultiplayerSynchronizer.
## "set = _set_dead" is a setter: every time is_dead is assigned (here or by the synchronizer
## on another peer), _set_dead() runs, which hides/shows the body.
var is_dead := false: set = _set_dead
var player_name := "Player"        ## Set by the spawner.
var damage_multiplier := 1.0       ## Buffs (weapons multiply their damage by this).
var speed_multiplier := 1.0        ## Buffs (multiplies the move speed, see get_move_speed()).
## Seconds left until respawn while dead (counted down in _tick_timers).
var _respawn_left := 0.0
## Seconds left of the current damage/speed buff (0 = no buff).
var _boost_left := 0.0
## Spawn as already dead and come back after this many seconds (used when you switch class
## while dead, so switching doesn't skip the respawn wait). Set by the spawner.
var start_dead_for := 0.0

# --- Visible status effects ----------------------------------------------------------------

## Visible states other players should see (synced): STATUS_FIRE = boosted, STATUS_HEALING.
## They are bit flags, so both can be on at once: flags |= X turns X on, flags &= ~X turns it off.
const STATUS_FIRE := 1
const STATUS_HEALING := 2
## Which status effects are active (bit flags above). Synced to everyone "on change" by the
## MultiplayerSynchronizer; the setter updates the visible effect on every peer.
var status_flags := 0: set = _set_status_flags
## The node that draws the flames / healing effect on our body (created in _ready).
var _status_fx: Node3D
const StatusEffects = preload("res://Scripts/Effects/status_effects.gd")

# --- Heal over time (HoT) ------------------------------------------------------------------

## Heal over time (e.g. the Medic's syringe in Death Match). Can go above max_health up to
## _hot_cap ("overheal"); overheal slowly drains away again once the effect ends.
## This value is how fast the overheal drains: HP per second.
@export var overheal_decay_per_second := 3.0
var _hot_rate := 0.0     # HP per second
var _hot_left := 0.0     # seconds
var _hot_cap := 0        # highest health the current HoT may heal up to
# Health is a whole number but the HoT heals fractions per frame (e.g. 0.4 HP), so the
# fractions are collected here and only whole points are added to health.
var _hot_accum := 0.0
var _decay_accum := 0.0  # same idea for the overheal drain

## Render layer used only to hide your own body from your own camera (layer 20, chosen to stay out of your way).
## 1 << 19 means "bit number 19" = render layer 20 in the editor (the editor counts from 1).
const OWN_BODY_RENDER_LAYER := 1 << 19

# --- Health and team -----------------------------------------------------------------------

## Full health. Each class scene sets its own value in the Inspector (e.g. Sheriff 200).
@export var max_health := 100
## Current health. Only the owner changes it; the synchronizer copies it to everyone else.
var health := 100
@export var shot_damage := 34   ## Damage of the base class's built-in shotgun.

const TEAM_COLORS := [Color(0.85, 0.2, 0.2), Color(0.2, 0.4, 0.9)] # Red, Blue
## Team number: 0 = Red, 1 = Blue; 100 and above = free-for-all (everyone on their own team).
@export var team := 0                 ## Set by the spawner before the player enters the tree.
var spawn_position := Vector3.ZERO    ## Where this player respawns. Set by the spawner.

# --- Movement settings ---------------------------------------------------------------------

## Radians turned per pixel of mouse movement (overwritten by the saved Options value).
@export var look_sensitivity : float = 0.005
## Upward speed given by a jump, in m/s.
@export var jump_velocity := 6.0
## Holding jump keeps jumping automatically the moment you land (makes bunny hopping easy).
@export var auto_bhop := false


## Head bob: how far (metres) and how fast the camera sways while walking.
const  HEADBOB_MOVE_AMOUNT = 0.06
const  HEADBOB_FREQUENCY = 2.4
## Grows with distance walked; fed into cos() to make the bob wave.
var headbob_time := 0.0

## Normal ground speed, m/s.
@export var walk_speed := 7.0
## Ground speed while holding sprint, m/s.
@export var sprint_speed := 8.5
## How quickly you reach your target speed on the ground (higher = snappier).
@export var ground_accel := 14.0
## Minimum speed (m/s) friction works with, so slow movement still stops quickly (Quake's "stopspeed").
@export var ground_decel := 10.0
## How strongly the ground slows you down (Quake's "friction").
@export var ground_friction := 6.0

## Air control: the most speed (m/s) you can ADD in the direction you press while in the air.
## Small on purpose - this low cap is what makes Source-style air strafing work (see _handle_air_physics).
@export var air_cap := 0.85
## Air acceleration (very high, so you reach the small air_cap almost instantly).
@export var air_accel := 800.0
## Wished air speed; multiplied with air_accel. In practice air_cap is the real limit.
@export var air_move_speed := 500.0
## How fast holding jump makes you swim upwards in water (m/s per second).
@export var swim_up_speed := 10.0

## Direction you want to move in, from WASD, turned to match where the body faces (flat, no up/down).
var wish_dir := Vector3.ZERO
## Same as wish_dir but follows the camera, including looking up/down. Used for swimming and noclip.
var cam_allign_wish_dir := Vector3.ZERO

## How much shorter (metres) the player gets when crouching, and how far the head drops.
const  CROUCH_TRANSLATE = 0.7
## Crouching in the air pulls your legs up by this much: the "crouch jump" that reaches higher ledges.
const CROUCH_JUMP_ADD = CROUCH_TRANSLATE * 0.9
var is_crouched := false

## Noclip (debug fly mode) speed multiplier; the mouse wheel changes it.
var no_clip_speed_multi := 3.0
var no_clip := false

## Tallest step (metres) the player walks up/down automatically without jumping.
const MAX_STEP_HEIGHT = 0.5
## True if we stepped on stairs last physics frame (keeps stair stepping going on a staircase).
var _snapped_to_stairs_last_frame := false
## Physics frame number when we last stood on the floor.
var _last_frame_was_on_floor := -INF

# --- Bots ------------------------------------------------------------------------------------

## True for AI players. Bots run on the server and get their controls from a bot brain
## (Scripts/AI/bot_brain.gd) through bot_move / bot_jump / bot_sprint instead of the keyboard.
var is_bot := false
var bot_move := Vector2.ZERO     ## Like Input.get_vector("left","right","up","down"): x = right, y = back.
var bot_jump := false            ## The bot is "holding" jump.
var bot_sprint := false          ## The bot is "holding" sprint.
## Who this player is in scores and kill credit: the peer id for people, a bot id for bots.
## Real players use their network peer id (1 for the host, otherwise a big random positive number).
## Bots use negative ids (-1, -2, ...) so they can never clash with a real player.
## The id is stored in the node's name, so this getter just turns the name back into a number.
var combat_id: int:
	get: return str(name).to_int()

## Godot calls this when the node is added to the scene tree, BEFORE _ready().
## We set the multiplayer authority here so it is already correct when _ready() and the
## MultiplayerSynchronizer start (set_multiplayer_authority also applies to all child nodes).
func _enter_tree():
	# Players are named after their id. Bots (negative ids) belong to the server (peer 1).
	var id := str(name).to_int()
	set_multiplayer_authority(1 if id < 0 else id)

## Runs once on EVERY peer when the player appears. Shared setup first; then, only for the
## player you control yourself, grab the mouse and switch to this player's camera.
func _ready() -> void:
	health = max_health
	_apply_team_color()
	# Create the visible status effects node (flames when boosted, sparkles when healing).
	_status_fx = StatusEffects.new()
	_status_fx.name = "StatusEffects"
	add_child(_status_fx)
	_status_fx.set_status(status_flags)
	if start_dead_for > 0.0:
		is_dead = true
		_respawn_left = start_dead_for
	if weapon_manager:
		# This class has its own weapons, so hide the base class's built-in shotgun.
		$"HeadOriginalPosition/Head/CameraSmooth/Camera3D/Pump-Shotgun-Long".visible = false
	# Everything below is only for "my own" player on this computer: not other people's
	# copies, and not bots (which belong to the server but have no person looking through them).
	if !is_multiplayer_authority() or is_bot: return
	_hide_own_body_from_own_camera()
	_status_fx.hide_from_layer(OWN_BODY_RENDER_LAYER)

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)   # hide the cursor and lock it to the window
	%Camera3D.current = true   # look through this player's camera
	GameSettings.apply_to_player(self)   # mouse sensitivity, field of view

## Colours the body capsule by team so you can tell friend from foe.
func _apply_team_color() -> void:
	var mat := StandardMaterial3D.new()
	if team >= 100:
		# Free-for-all (each player has their own team id): give everyone their own colour.
		# Multiplying by 0.618 (the golden ratio) and keeping the fraction spreads the hues
		# evenly around the colour wheel, so neighbouring ids get clearly different colours.
		mat.albedo_color = Color.from_hsv(fmod((team - 100) * 0.618, 1.0), 0.65, 0.9)
	else:
		mat.albedo_color = TEAM_COLORS[team % TEAM_COLORS.size()]
	# material_override replaces the mesh's material just for this player instance.
	$WorldModel/MeshInstance3D.material_override = mat

## Your own capsule (and its outline) would otherwise block your view from the inside.
## Other players still see your body, and it still casts a shadow.
## How: move every visible part of the body onto a render layer of its own, then tell our
## camera's cull_mask to skip that layer. Other players' cameras don't skip it.
func _hide_own_body_from_own_camera() -> void:
	for g in $WorldModel.find_children("*", "GeometryInstance3D", true, false):
		g.layers = OWN_BODY_RENDER_LAYER
	camera.cull_mask &= ~OWN_BODY_RENDER_LAYER   # clear that bit = "don't draw this layer"

## True if `other` is on our team (weapons use this to avoid friendly fire).
## get("team") returns null for nodes without a team, so walls etc. are never teammates.
func is_teammate(other: Node) -> bool:
	return other != null and other.get("team") == team

## Noclip: a debug fly mode that ignores walls (toggle with the _noclip key, debug builds only).
## Returns true while noclip is on, which tells _physics_process to skip normal movement.
func _handle_no_clip(delta: float) -> bool:
	# OS.has_feature("debug") is false in exported release builds, so players can't cheat with it.
	if !is_bot and Input.is_action_just_pressed("_noclip") and OS.has_feature("debug"):
		no_clip = !no_clip
		no_clip_speed_multi = 3.0

	# No collision while flying (or while dead) so you can pass through walls.
	$CollisionShape3D.disabled = no_clip or is_dead

	if !no_clip:
		return false

	var speed = get_move_speed() * no_clip_speed_multi
	if _wants("sprint"):
		speed *= 3

	# Fly where the camera looks, and move the position directly (no move_and_slide, so no collisions).
	self.velocity = cam_allign_wish_dir * speed
	global_position += self.velocity * delta

	return true

## The speed (m/s) you are trying to reach right now: walking, sprinting or crouching, times buffs.
func get_move_speed() -> float:
	if is_crouched:
		return walk_speed * 0.8 * speed_multiplier

	return (sprint_speed if _wants("sprint") else walk_speed) * speed_multiplier

## Godot calls this for input events that no UI element used up (so clicks on menus don't
## reach the game). Handles mouse look, the noclip speed wheel and the fire button.
## Only the player's owner reacts to input; everyone else gets the result through the synchronizer.
func _unhandled_input(event: InputEvent) -> void:
	if !is_multiplayer_authority() or is_bot: return   # bots on the server must never follow the host's mouse
	if !input_enabled or frozen or is_dead: return   # a menu is open (Esc is handled by the pause menu)

	# Clicking into the window grabs the mouse again - but that click shouldn't also fire.
	var was_captured := Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			# Mouse left/right turns the whole body (yaw); up/down only tilts the camera (pitch).
			# Turning the body means "forward" for movement always matches where you look.
			rotate_y(-event.relative.x * look_sensitivity)
			%Camera3D.rotate_x(-event.relative.y * look_sensitivity)
			# Stop at straight up / straight down so you can't flip upside down.
			%Camera3D.rotation.x = clamp(%Camera3D.rotation.x, deg_to_rad(-90), deg_to_rad(90))

	# Mouse wheel changes the noclip flying speed (10% per notch, between 0.1x and 100x).
	if event is InputEventMouseButton and event.is_pressed():
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			no_clip_speed_multi = min(100.0, no_clip_speed_multi * 1.1)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			no_clip_speed_multi = max(0.1, no_clip_speed_multi * 0.9)

	if Input.is_action_just_pressed("shoot") and was_captured:
		_primary_fire()

## Fires the current weapon. Called on the owner's peer when "shoot" is pressed.
## Override in class scripts (e.g. Medic) to change what the primary fire does.
func _primary_fire() -> void:
	# Classes with a WeaponManager let it handle the weapon they are holding.
	if weapon_manager:
		weapon_manager.try_primary_fire()
		return
	# Otherwise use the base class's simple built-in shotgun.
	# The "shoot" animation acts as the fire-rate limit: no new shot until it has finished.
	if animator.current_animation == "shoot": return
	play_shoot_effects.rpc()   # show the shot on every peer
	if raycast.is_colliding():
		var hit_player = raycast.get_collider()
		if hit_player.has_method("receive_damage") and !is_teammate(hit_player):
			var dmg := roundi(shot_damage * damage_multiplier)
			# Send the damage to the peer that OWNS the victim, because that peer controls its health.
			hit_player.receive_damage.rpc_id(hit_player.get_multiplayer_authority(), dmg, combat_id, "Shotgun")
			report_damage_dealt(dmg, raycast.get_collision_point())




## Camera sway while walking. headbob_time grows with distance travelled (speed * time), so
## the bob is faster when you run and stops when you stand still. The camera moves sideways
## at half the up/down rate, which traces a figure-8 like real footsteps.
func _headbob_effect(delta):
	headbob_time += delta * self.velocity.length()
	%Camera3D.transform.origin = Vector3(
		cos(headbob_time * HEADBOB_FREQUENCY * 0.5) * HEADBOB_MOVE_AMOUNT,
		cos(headbob_time * HEADBOB_FREQUENCY) * HEADBOB_MOVE_AMOUNT,
		0,
	)

# --- Camera smoothing for stairs ---------------------------------------------------------
# Stepping up/down stairs teleports the body up to MAX_STEP_HEIGHT in one frame, which would
# make the view jerk. Instead the CameraSmooth node is held at its old world height and then
# slides back to its normal place over a few frames.

## World position of CameraSmooth from before the stair step (null = not smoothing right now).
var _saved_camera_global_pos = null
## Remember where the camera was BEFORE a stair teleport (only the first time, if several steps follow).
func _save_camera_pos_for_smoothing():
	if _saved_camera_global_pos == null:
		_saved_camera_global_pos = %CameraSmooth.global_position

## Each frame: put the camera back at the remembered height, then move it a bit toward its
## normal local position (y = 0). It moves at least as fast as the player, so it never lags far.
func _slide_camera_smooth_back_to_origin(delta):
	if _saved_camera_global_pos == null: return
	%CameraSmooth.global_position.y = _saved_camera_global_pos.y
	%CameraSmooth.position.y = clampf(%CameraSmooth.position.y, -0.7, 0.7)   # never more than 0.7 m off
	var move_amount = max(self.velocity.length() * delta, walk_speed/2 * delta)
	%CameraSmooth.position.y = move_toward(%CameraSmooth.position.y, 0.0, move_amount)
	_saved_camera_global_pos = %CameraSmooth.global_position
	if %CameraSmooth.position.y == 0:
		_saved_camera_global_pos = null   # back in place: smoothing finished

# --- Stairs --------------------------------------------------------------------------------

## Walking DOWN stairs: without this, walking off a step would make you fly off and fall a
## little ("bounce" down the stairs). If we were on the floor last frame, are not moving up,
## and there is walkable ground at most MAX_STEP_HEIGHT below us, snap straight down onto it.
func _snap_down_to_stairs_check() -> void:
	var did_snap := false
	# StairsBelowRayCast3D points down from the feet: is there ground close below?
	var floor_below : bool = %StairsBelowRayCast3D.is_colliding() and not is_surface_too_steep(%StairsBelowRayCast3D.get_collision_normal())
	# Engine.get_physics_frames() counts physics frames; a difference of 1 means "last frame".
	var was_on_floor_last_frame = Engine.get_physics_frames() - _last_frame_was_on_floor == 1
	if not is_on_floor() and velocity.y <= 0 and (was_on_floor_last_frame or _snapped_to_stairs_last_frame) and floor_below:
		# "Pretend" to move the body down MAX_STEP_HEIGHT and see where it would hit.
		var body_test_result = PhysicsTestMotionResult3D.new()
		if _run_body_test_motion(self.global_transform, Vector3(0, -MAX_STEP_HEIGHT, 0), body_test_result):
			_save_camera_pos_for_smoothing()
			# get_travel() = how far the body could move before touching the ground.
			var translate_y = body_test_result.get_travel().y
			self.position.y += translate_y
			apply_floor_snap()   # tell the CharacterBody3D it is standing on the floor now
			did_snap = true
		# Note: this flag is only updated when the check above ran.
		_snapped_to_stairs_last_frame = did_snap


## Walking UP stairs: test whether the body would fit if it were lifted onto the step ahead.
## Returns true if we stepped up (then _physics_process skips move_and_slide for this frame).
## How it works:
##  1. Take where we'd be after this frame's horizontal move, lifted 2 * MAX_STEP_HEIGHT up.
##  2. From there, sweep the body down to find the top of the step.
##  3. If the step is between 0.01 m and MAX_STEP_HEIGHT high and its top isn't too steep
##     (checked with StairsAheadRayCast3D), teleport onto it.
func _snap_up_stairs_check(delta) -> bool:
	# Only when standing on something (floor or a stair we just stepped on).
	if !is_on_floor() and not _snapped_to_stairs_last_frame: return false

	# Not when jumping, and not when standing still horizontally.
	# velocity * Vector3(1,0,1) removes the up/down part, leaving only the horizontal movement.
	if self.velocity.y > 0 or (self.velocity * Vector3(1,0,1)).length() == 0: return false
	var expected_move_motion = self.velocity * Vector3(1,0,1) * delta
	var step_pos_with_clearance = self.global_transform.translated(expected_move_motion + Vector3(0, MAX_STEP_HEIGHT * 2, 0))

	# Sweep down from the raised spot. Only real level geometry (StaticBody3D / CSG) counts as
	# stairs, so we don't "step up" onto other players or moving objects.
	var down_check_result = PhysicsTestMotionResult3D.new()
	if(_run_body_test_motion(step_pos_with_clearance, Vector3(0, -MAX_STEP_HEIGHT*2, 0), down_check_result)
	and (down_check_result.get_collider().is_class("StaticBody3D") or down_check_result.get_collider().is_class("CSGShape3D"))):
		# How much higher the landing spot is than where we stand now.
		var step_height = ((step_pos_with_clearance.origin + down_check_result.get_travel()) - self.global_position).y

		# Too tall (that's a wall), basically flat (normal walking handles it), or the hit point is too high.
		if step_height > MAX_STEP_HEIGHT or step_height <= 0.01 or (down_check_result.get_collision_point() - self.global_position).y > MAX_STEP_HEIGHT: return false
		# Put the "ahead" ray just above the step's top, slightly forward, and check the surface is walkable.
		%StairsAheadRayCast3D.global_position = down_check_result.get_collision_point() + Vector3(0,MAX_STEP_HEIGHT,0) + expected_move_motion.normalized() * 0.1
		%StairsAheadRayCast3D.force_raycast_update()   # update the ray now instead of next physics frame
		if %StairsAheadRayCast3D.is_colliding() and !is_surface_too_steep(%StairsAheadRayCast3D.get_collision_normal()):
			_save_camera_pos_for_smoothing()
			self.global_position = step_pos_with_clearance.origin + down_check_result.get_travel()
			apply_floor_snap()
			_snapped_to_stairs_last_frame = true
			return true
	return false

## Swimming. Returns true while inside any water area (node in the "water_area" group, e.g.
## from WaterMaker3D), which tells _physics_process to skip normal ground/air movement.
func _handle_water_physics(delta) -> bool:
	# .all(...) is true if NO water area overlaps us -> not in water.
	if get_tree().get_nodes_in_group("water_area").all(func(area): return !area.overlaps_body(self)):
		return false

	# Sink slowly: only 10% of normal gravity.
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * 0.1 * delta

	# Swim where the camera looks (look up + W = swim up).
	self.velocity += cam_allign_wish_dir * get_move_speed() * delta

	if _wants("jump"):
		self.velocity.y += swim_up_speed * delta

	# Dampen velocity when in water
	# (lerp toward zero = water drag: you lose about 2x your speed per second, so you slow down smoothly).
	self.velocity = self.velocity.lerp(Vector3.ZERO, 2 * delta)

	return true

## Standing height of the collision capsule, remembered so crouching can shrink and restore it.
@onready var _original_capsule_height = $CollisionShape3D.shape.height
## Crouching: shrinks the collision capsule by CROUCH_TRANSLATE and lowers the camera.
func _handle_crouch(delta) -> void:
	var was_crouched_last_frame = is_crouched
	if _wants("crouch"):
		is_crouched = true
	# Released crouch: only stand up if there is room above the head.
	# test_move returns true if moving up CROUCH_TRANSLATE would hit something (e.g. a low ceiling).
	elif is_crouched and !self.test_move(self.transform, Vector3(0, CROUCH_TRANSLATE, 0)):
		is_crouched = false

	# Crouch jump: crouching in mid-air pulls your feet UP instead of your head down (and
	# standing up in the air pushes the feet back down). That lets you reach higher ledges.
	var translate_y_if_possible := 0.0
	if was_crouched_last_frame != is_crouched and !is_on_floor():
		translate_y_if_possible = CROUCH_JUMP_ADD if is_crouched else -CROUCH_JUMP_ADD

	if translate_y_if_possible != 0.0:
		# Move the body as far as it fits (result.get_travel() stops at any collision)...
		var result = KinematicCollision3D.new()
		self.test_move(self.transform, Vector3(0, translate_y_if_possible, 0), result)
		self.position.y += result.get_travel().y
		# ...and move the head the opposite way so the camera stays where it was (no jolt).
		%Head.position.y -= result.get_travel().y
		%Head.position.y = clampf(%Head.position.y, -CROUCH_TRANSLATE, 0)

	# Smoothly move the head to crouched / standing height (7 m/s).
	%Head.position.y = move_toward(%Head.position.y, -CROUCH_TRANSLATE if is_crouched else 0.0, 7.0 * delta)
	$CollisionShape3D.shape.height = _original_capsule_height - CROUCH_TRANSLATE if is_crouched else _original_capsule_height
	# Keep the bottom of the capsule at the player's feet (the node's origin) whatever its height.
	$CollisionShape3D.position.y = $CollisionShape3D.shape.height / 2

## Removes the part of our velocity that goes INTO a surface, so we slide along it instead
## (the Quake/Source "ClipVelocity"). `normal` points out of the surface.
## velocity.dot(normal) is how fast we move into (negative) or away from (positive) the surface.
## overbounce = 1 removes exactly that part; above 1 would bounce slightly off. `delta` is unused.
func clip_velocity(normal: Vector3, overbounce: float, delta: float) -> void:
	var backoff := self.velocity.dot(normal) * overbounce

	if backoff >= 0: return   # already moving away from the surface: nothing to do
	var change := normal * backoff
	self.velocity -= change

	# Floating point safety: if we are still moving into the surface a tiny bit, remove that too.
	var adjust := self.velocity.dot(normal)
	if adjust < 0.0:
		self.velocity -= normal * adjust

## True if a surface with this normal is steeper than the body's floor_max_angle (can't stand on it).
func is_surface_too_steep(normal: Vector3) -> bool:
	# Old version of the same check, kept for reference:
	#var max_slope_ang_dot = Vector3(0,1,0).rotated(Vector3(1.0,0,0), self.floor_max_angle).dot(Vector3(0,1,0))
	#if normal.dot(Vector3(0,1,0)) < max_slope_ang_dot:
		#return true
	#return false
	return normal.angle_to(Vector3.UP) > self.floor_max_angle

## Asks the physics engine "if this body started at `from` and moved by `motion`, would it hit
## something?" without actually moving it. Returns true on a hit; details go into `result`
## (a PhysicsTestMotionResult3D). Used by the stair checks.
## Note: the fallback on the first line creates the wrong type (Parameters instead of Result),
## but every caller passes its own result, so it never runs.
func _run_body_test_motion(from: Transform3D, motion: Vector3, result = null) -> bool:
	if !result: result = PhysicsTestMotionParameters3D.new()
	var params = PhysicsTestMotionParameters3D.new()
	params.from = from
	params.motion = motion
	return PhysicsServer3D.body_test_motion(self.get_rid(), params, result)

## Movement while in the air: gravity + Source-style air acceleration.
## The trick behind air strafing / bunny hopping: we only limit the speed IN THE DIRECTION YOU
## PRESS (cur_speed_in_wish_dir), never your total speed. Pressing A/D while turning the mouse
## the same way keeps pointing wish_dir slightly sideways to your velocity, where that
## component is small, so speed keeps being added and your total speed grows.
func _handle_air_physics(delta) -> void:
	self.velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity") * delta
	# dot() = how much of our velocity already points along wish_dir (projection).
	var cur_speed_in_wish_dir = self.velocity.dot(wish_dir)
	# The most speed allowed along wish_dir: air_cap (0 if no key is pressed, since wish_dir is zero).
	var capped_speed = min((air_move_speed * wish_dir).length(), air_cap)
	var add_speed_till_cap = capped_speed - cur_speed_in_wish_dir
	if add_speed_till_cap > 0:
		var accel_speed = air_accel * air_move_speed * delta
		accel_speed = min(accel_speed, add_speed_till_cap)   # never push past the cap
		self.velocity += accel_speed * wish_dir

	if is_on_wall():
		# Steep walls: FLOATING mode so move_and_slide doesn't treat the slope as floor and
		# we slide along it (this is how "surfing" on steep ramps works). Walkable slopes: normal mode.
		if is_surface_too_steep(get_wall_normal()):
			self.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		else:
			self.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
		clip_velocity(get_wall_normal(), 1, delta)

## Movement on the ground: accelerate toward the wished direction, then apply friction.
func _handle_ground_physics(delta) -> void:

	#Accelaration and friction on ground
	# Same idea as in the air, but the cap is the full move speed and acceleration is gentler.
	var curr_speed_in_wish_dir = self.velocity.dot(wish_dir)
	var add_speed_till_cap = get_move_speed() - curr_speed_in_wish_dir
	if add_speed_till_cap > 0:
		var accel_speed = ground_accel * delta * get_move_speed()
		accel_speed = min(accel_speed, add_speed_till_cap)
		self.velocity += accel_speed * wish_dir

	#Apply friction
	# Quake-style friction: lose `drop` m/s this frame. When slow, pretend we go at least
	# ground_decel m/s ("control"), so we come to a full stop quickly instead of creeping.
	var control = max(self.velocity.length(), ground_decel)
	var drop = control * ground_friction * delta
	var new_speed = max(self.velocity.length() - drop, 0.0)
	# Turn new_speed into a scale factor (new speed / old speed) and shrink the velocity by it.
	if self.velocity.length() > 0:
		new_speed /= self.velocity.length()
	self.velocity *= new_speed

	_headbob_effect(delta)


## Main movement loop, called by Godot at a fixed rate (60 times per second by default).
## Only the owner of this player runs it; the synchronizer sends the result to everyone else.
## Order each frame: timers -> death checks -> read input -> crouch -> noclip / water /
## ground / air movement -> stairs + move_and_slide -> camera smoothing.
func _physics_process(delta: float) -> void:
	if !is_multiplayer_authority(): return
	_tick_timers(delta)
	if is_dead:
		velocity = Vector3.ZERO
		return
	if global_position.y < kill_height:
		fall_kill()
		return

	if is_on_floor(): _last_frame_was_on_floor = Engine.get_physics_frames()

	# WASD (or the bot brain) as a 2D vector; nothing while a menu is open or frozen.
	var input_dir = _move_input() if input_enabled and !frozen else Vector2.ZERO
	# Turn the 2D input into a 3D direction relative to where the body / camera faces.
	# (Godot's forward is -Z, and "up" on the input vector is negative y, so they line up.)
	wish_dir = self.global_transform.basis * Vector3(input_dir.x,0.0,input_dir.y)
	cam_allign_wish_dir = %Camera3D.global_transform.basis * Vector3(input_dir.x,0.0,input_dir.y)

	# Pick the weapon animation (don't interrupt a shot that is still playing).
	if animator.current_animation == "shoot":
		pass
	elif input_dir != Vector2.ZERO and is_on_floor():
		animator.play("move")
	else:
		animator.play("idle")

	_handle_crouch(delta)

	# Each handler returns true if it "took over" movement this frame.
	if !_handle_no_clip(delta):
		if !_handle_water_physics(delta):
			if is_on_floor():
				# Jump on press (or keep jumping while held if auto bunny hop is on).
				if input_enabled and !frozen and (_wants_just("jump") or (auto_bhop and _wants("jump"))):
					self.velocity.y = jump_velocity
				_handle_ground_physics(delta)
			else:
				_handle_air_physics(delta)

		# Step up a stair if there is one; otherwise move normally and maybe snap down a step.
		# move_and_slide() moves the body by `velocity`, sliding along walls and floors.
		if not _snap_up_stairs_check(delta):
			move_and_slide()
			_snap_down_to_stairs_check()

	_slide_camera_smooth_back_to_origin(delta)

## Connected to the AnimationPlayer's animation_finished signal (in the scene): back to idle after a shot.
func _on_animation_player_animation_finished(anim_name: StringName) -> void:
	if anim_name == "shoot":
		animator.play("idle")

## Shows the built-in shotgun's shot (animation + muzzle flash).
## @rpc("call_local"): the mode defaults to "authority", so only the player's owner may call it;
## "call_local" means calling .rpc() runs it on the owner's own computer too, not just the others.
@rpc("call_local")
func play_shoot_effects():
	animator.stop()
	animator.play("shoot")
	shootParticle.restart()
	shootParticle.emitting = true
## Takes damage. Runs on the damaged player's own peer. Call with
##   receive_damage.rpc_id(target.get_multiplayer_authority(), amount, attacker.combat_id, weapon_name)
## attacker_id says who gets the kill (bots all send from the server, so the sender alone isn't enough).
## @rpc("any_peer", "call_local"): ANY peer may call it (the attacker can be anyone), and it
## also works when the attacker is on the same peer as the victim (e.g. the host shooting a bot).
@rpc("any_peer", "call_local")
func receive_damage(amount: int = 1, attacker_id: int = 0, weapon := ""):
	if is_dead: return
	health = maxi(health - amount, 0)   # never below 0
	died_from_fall = false
	death_weapon = weapon
	# Who hurt us: the id they sent, or else the peer that sent the RPC.
	var killer := attacker_id if attacker_id != 0 else multiplayer.get_remote_sender_id()
	if killer == combat_id: killer = 0   # hurting yourself (own dynamite) gives no kill credit
	if killer != 0:
		# Remember them, in case we fall to our death soon (see fall_kill).
		_last_attacker = killer
		_last_attacked_at = Time.get_ticks_msec() / 1000.0
	# Find the attacker's player node (named after its id) so the HUD can point toward them.
	var attacker_position = null
	if killer != 0:
		var attacker = get_parent().get_node_or_null(str(killer))
		if attacker is Node3D: attacker_position = attacker.global_position
	damage_taken.emit(amount, attacker_position)
	health_changed.emit(health)
	if health <= 0:
		_die(killer)


# --- Death, respawn, buffs (run on the owner's peer) ---------------------------------------

## Fell off the map / touched a death zone (runs on your own peer).
## If someone hurt you in the last FALL_CREDIT_SECONDS (e.g. knocked you off with dynamite),
## they get the kill.
func fall_kill() -> void:
	# Ignore it right after respawning (see _fall_safe_until).
	if is_dead or Time.get_ticks_msec() / 1000.0 < _fall_safe_until: return
	var recent := Time.get_ticks_msec() / 1000.0 - _last_attacked_at <= FALL_CREDIT_SECONDS
	var killer := _last_attacker if recent else 0
	health = 0
	health_changed.emit(health)
	died_from_fall = true
	death_weapon = ""
	_die(killer)


## Shared death logic (damage or falling): mark dead, drop ammo, start the respawn countdown,
## clear buffs and tell listeners (HUD, game mode) through the `died` signal.
func _die(killer_id: int) -> void:
	is_dead = true   # the setter hides the body; the synchronizer tells everyone else
	var level = get_parent()
	if level.has_method("request_ammo_drop"):
		level.request_ammo_drop(global_position)   # leaves an ammo box behind for whoever's left
	_respawn_left = respawn_delay
	_end_boost()
	_end_heal_over_time()
	died.emit(killer_id)


## Bring the player back: full health, full ammo, primary weapon, new spawn point.
## Called by _tick_timers when the respawn countdown ends (on the owner's peer).
func respawn() -> void:
	# Move first, then become solid again, so nothing at the old spot (e.g. a death zone) catches us.
	var level = get_parent()
	position = level.get_respawn_position(self) if level.has_method("get_respawn_position") else spawn_position
	force_update_transform()   # apply the new position to physics right away
	_fall_safe_until = Time.get_ticks_msec() / 1000.0 + 0.5   # half a second of fall-kill immunity
	is_dead = false
	_end_heal_over_time()
	_last_attacker = 0
	health = max_health
	velocity = Vector3.ZERO
	if weapon_manager:
		weapon_manager.reset_all()
	respawned.emit()
	health_changed.emit(health)


## Counts down the respawn timer, the buff timer and the heal over time. Called every physics frame.
func _tick_timers(delta: float) -> void:
	if is_dead and _respawn_left > 0.0:
		_respawn_left -= delta
		if _respawn_left <= 0.0:
			respawn()
	if _boost_left > 0.0:
		_boost_left -= delta
		if _boost_left <= 0.0:
			_end_boost()
	_tick_heal_over_time(delta)


# --- Controls: keyboard for people, bot brain for bots -----------------------------------------
# The movement code never reads Input directly; it asks these helpers instead. That way the same
# movement code works for people (keyboard) and bots (values set by bot_brain.gd).

## Movement input as a 2D vector (x = right, y = back), length at most 1.
func _move_input() -> Vector2:
	if is_bot: return bot_move.limit_length(1.0)
	# normalized() so pressing W+D together isn't faster than W alone.
	return Input.get_vector("left", "right", "up", "down").normalized()


## Is this action ("jump", "sprint", "crouch"...) held down? Bots only know jump and sprint.
func _wants(action: String) -> bool:
	if is_bot:
		match action:
			"sprint": return bot_sprint
			"jump": return bot_jump
		return false
	return Input.is_action_pressed(action)


## Was this action pressed THIS frame? (Bots: jump counts as pressed every frame they hold it.)
func _wants_just(action: String) -> bool:
	if is_bot: return action == "jump" and bot_jump
	return Input.is_action_just_pressed(action)


## Seconds of buff left (for the HUD).
func get_boost_time_left() -> float:
	return maxf(_boost_left, 0.0)


## Seconds until respawn (for the death screen).
func get_respawn_time_left() -> float:
	return maxf(_respawn_left, 0.0)


## Setter for is_dead (see "set = _set_dead" above).
func _set_dead(value: bool) -> void:
	is_dead = value
	# Runs on every peer (the synchronizer sets it remotely): hide the body and weapons, no hits.
	# The value can be set before the node is in the scene tree (e.g. while spawning), when the
	# child nodes aren't reachable yet, so skip the visuals then.
	if !is_inside_tree(): return
	$WorldModel.visible = !value
	$HeadOriginalPosition.visible = !value
	$CollisionShape3D.disabled = value or no_clip


## Server -> owner: temporary buff (double damage + faster).
## Sent by the game mode (deathmatch.gd gives it to the player who is furthest behind).
## "reliable" = guaranteed to arrive, and in order (important for one-off events like this).
@rpc("any_peer", "call_local", "reliable")
func receive_boost(seconds: float, damage_mult := 2.0, speed_mult := 1.3) -> void:
	# "any_peer" lets anyone call it, so check by hand that it came from the server (peer 1).
	# 0 means it was called directly as a normal function, not through the network.
	if multiplayer.get_remote_sender_id() != 1 and multiplayer.get_remote_sender_id() != 0: return   # only the server
	damage_multiplier = damage_mult
	speed_multiplier = speed_mult
	_boost_left = seconds
	status_flags |= STATUS_FIRE   # show the flames effect to everyone
	boost_started.emit(seconds)


## Removes the buff (timer ran out, or we died).
func _end_boost() -> void:
	_boost_left = 0.0
	damage_multiplier = 1.0
	speed_multiplier = 1.0
	status_flags &= ~STATUS_FIRE


## Explosions push you (runs on your own peer). Added to your current velocity, so a blast
## under your feet launches you into the air.
## Sent by explosion.gd to the owner of each player caught in the blast; `impulse` is in m/s.
@rpc("any_peer", "call_local", "reliable")
func receive_knockback(impulse: Vector3) -> void:
	if is_dead: return
	velocity += impulse


## Ammo pickup: refill this fraction of every gun's spare ammo (0.5 = half of the maximum).
## Sent by pickup.gd on the server to the player's owner.
@rpc("any_peer", "call_local", "reliable")
func receive_ammo(fraction: float) -> void:
	if weapon_manager:
		weapon_manager.add_ammo_fraction(fraction)

## Runs on the healed player's own peer. Call with receive_heal.rpc_id(target.get_multiplayer_authority(), amount).
## Used by health pickups and healing weapons. Can't go above max_health.
@rpc("any_peer", "call_local")
func receive_heal(amount: int) -> void:
	heal(amount)

## Weapons call this after a hit so the HUD can show hitmarkers / damage numbers.
func report_damage_dealt(amount: int, world_position: Vector3, is_heal := false, is_headshot := false) -> void:
	damage_dealt.emit(amount, world_position, is_heal, is_headshot)


# --- View punch: small upward camera kick when you fire (your own view only) ---

## The tween currently running the kick (kept so a new shot can cancel it).
var _punch_tween: Tween
## Small upward camera kick when you fire (your own view only). Called by weapons when they fire. `degrees` = how far the view tips up (max 6 degrees total).
## Uses a Tween: an object that animates a property over time. Two steps run one after the other:
## kick up in 0.03 s, then ease back to level in 0.2 s.
func add_view_punch(degrees: float) -> void:
	if degrees <= 0.0 or is_bot: return
	var cs: Node3D = %CameraSmooth
	if _punch_tween: _punch_tween.kill()   # stop the previous kick so they don't fight
	_punch_tween = create_tween()
	_punch_tween.tween_property(cs, "rotation:x", clampf(cs.rotation.x + deg_to_rad(degrees), 0.0, deg_to_rad(6.0)), 0.03).set_ease(Tween.EASE_OUT)
	_punch_tween.tween_property(cs, "rotation:x", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

## Heals up to max_health, or up to `cap` for overheal.
## Runs locally (call it on the owner's peer, or use receive_heal to reach another peer).
func heal(amount: int, cap := -1) -> void:
	if cap < 0: cap = max_health   # -1 means "no overheal"
	if is_dead or health >= cap: return
	health = mini(health + amount, cap)
	health_changed.emit(health)


## Start healing `total` HP spread over `seconds`, allowed to go up to `cap` (overheal).
## Stacks: a new dose adds its healing to whatever is left of the last one.
## Runs on the player's own peer.
func add_heal_over_time(total: float, seconds: float, cap: int) -> void:
	if is_dead: return
	# HP the old dose still had to give (rate * time left) plus the new dose...
	var remaining := _hot_rate * _hot_left + total
	# ...spread over the longer of the two durations.
	_hot_left = maxf(_hot_left, seconds)
	_hot_rate = remaining / _hot_left
	_hot_cap = maxi(_hot_cap, cap)
	status_flags |= STATUS_HEALING   # show the healing effect to everyone


## Seconds of heal over time left (for the HUD).
func get_heal_time_left() -> float:
	return maxf(_hot_left, 0.0)


## Every physics frame: give out the heal over time, or (once it ended) drain overheal.
func _tick_heal_over_time(delta: float) -> void:
	if is_dead: return
	if _hot_left > 0.0:
		_hot_left -= delta
		# Collect fractional HP and add only whole points to health (health is an int).
		_hot_accum += _hot_rate * delta
		var whole := floori(_hot_accum)
		if whole > 0:
			_hot_accum -= whole
			heal(whole, _hot_cap)
		if _hot_left <= 0.0: _end_heal_over_time()
	elif health > max_health:
		# Overheal drains back down to normal.
		_decay_accum += overheal_decay_per_second * delta
		var drop := floori(_decay_accum)
		if drop > 0:
			_decay_accum -= drop
			health = maxi(health - drop, max_health)   # stop exactly at max_health
			health_changed.emit(health)


## Stops the heal over time (finished, died or respawned).
func _end_heal_over_time() -> void:
	_hot_left = 0.0
	_hot_rate = 0.0
	_hot_accum = 0.0
	_hot_cap = 0
	status_flags &= ~STATUS_HEALING


## Setter for status_flags: runs on every peer whenever the flags change (locally, or when the
## synchronizer receives new flags), and shows/hides the matching effects.
func _set_status_flags(value: int) -> void:
	status_flags = value
	if _status_fx: _status_fx.set_status(value)   # null before _ready() has created it
