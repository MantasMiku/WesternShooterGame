extends Node
## Base script for every weapon.
##
## A weapon is a plain logic [Node] that lives as a child of a WeaponManager node
## (weapon_manager.gd), which itself is a child of the player. Its [member viewmodel] is the 3D model
## under the player's camera that is shown while the weapon is equipped.
##
## [b]Who extends this:[/b] hitscan_weapon.gd (guns), melee_weapon.gd (knives, hatchets),
## syringe_weapon.gd (Medic), thrown_weapon.gd (Bomber's dynamite) and dual_pistol_weapon.gd.
## Each character scene (e.g. Scenes/Sheriff/sheriff.tscn) puts a few of these under its
## WeaponManager and sets their exported values in the Inspector.
##
## [b]How an attack flows through the code:[/b]
## [codeblock]
## Player presses attack -> WeaponManager.try_primary_fire() sets a flag
## -> next WeaponManager._physics_process() -> weapon.try_fire()
## -> can_fire()? -> start cooldown -> _fire()   (the subclass does the real work)
## [/codeblock]
##
## [b]Which peer runs what (multiplayer):[/b]
## [br]- tick(), try_fire(), _fire(), try_reload() only run on the peer that OWNS the player
##   (its "multiplayer authority": the human's own computer, or the server for bots).
##   That peer decides what was hit and sends the damage by RPC to the victim's owner.
## [br]- play_attack_visual() / play_reload_visual() run on EVERY peer (the manager broadcasts
##   them with an RPC) so everybody sees the gun kick, the muzzle flash, etc.
##
## To make a new weapon: extend this script and override _fire() (and optionally the visuals).

# The WeaponManager listens to status_changed and forwards it to the HUD as
# weapon_status_changed. The warning_ignore line stops Godot complaining that this base
# script never emits the signal itself (the subclasses do).
@warning_ignore("unused_signal")
signal status_changed   ## Emitted when something shown on the HUD changes (ammo, reloading...).

## Name shown on the HUD and in the kill feed ("... killed by X with <weapon_name>").
@export var weapon_name := "Weapon"
@export var viewmodel: Node3D          ## First-person model shown while this weapon is equipped.
@export var fire_cooldown := 0.5       ## Seconds between attacks (lower = faster firing).
@export var automatic := true          ## Hold the attack button to keep firing (every weapon by default).
## Switching to this weapon: it comes up from below over this many seconds and can't attack
## until it's up (a small swap delay, so you can't swap-cancel cooldowns).
@export var draw_time := 0.28

## Physics layers hit by this weapon's traces: 1 = world, 2 = players. Walls block attacks.
## (Layer 3 holds head hitboxes; hitscan_weapon.gd checks those with a separate ray.)
@export_flags_3d_physics var hit_mask := 0b11

var player: CharacterBody3D            ## The player holding this weapon. Set by WeaponManager.
var manager: Node                      ## The WeaponManager this weapon belongs to.
## Seconds left until the weapon may attack again. Counts down in tick().
var _cooldown := 0.0
var _rest_transform := Transform3D()   ## Viewmodel's resting pose (visual tweens return here).
## The animation currently moving the viewmodel. Kept so a new animation can stop the old one.
var _tween: Tween


## Called once by the WeaponManager in its _ready(), on every peer.
## Remembers who holds the weapon and saves the viewmodel's starting pose (as placed in the
## scene) as the "rest" pose that all the little animations (recoil, reload, draw) go back to.
func setup(p_player: CharacterBody3D, p_manager: Node) -> void:
	player = p_player
	manager = p_manager
	if viewmodel: _rest_transform = viewmodel.transform


## Called by the WeaponManager every physics frame (authority only), for ALL weapons,
## even the ones that are put away. Subclasses add their own timers here (reloading...),
## always calling super(delta) first so the cooldown keeps counting down.
func tick(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)


## True when the weapon is allowed to attack right now. Subclasses add extra rules
## (guns: not reloading and has ammo).
func can_fire() -> bool:
	return _cooldown <= 0.0


## Called by the WeaponManager during _physics_process (so physics queries are safe).
## Checks the cooldown, restarts it, then lets the subclass do the actual attack.
func try_fire() -> void:
	if !can_fire(): return
	_cooldown = fire_cooldown
	_fire()


## Override: what happens when this weapon attacks. Runs only on the owning player's peer.
## This is where a weapon traces rays / finds targets and sends damage RPCs.
func _fire() -> void:
	pass


## Override for weapons that reload. Called when the player presses R (see WeaponManager).
func try_reload() -> void:
	pass


## Back to a fresh state (called when the player respawns). Override for ammo etc.
func reset() -> void:
	_cooldown = 0.0
	_reset_viewmodel()


## Ammo pickup: add this fraction (0..1) of the starting spare ammo. Override for guns.
func add_ammo_fraction(_fraction: float) -> void:
	pass


## True for weapons with ammo (the HUD shows `ammo` / `reserve` for these).
func uses_ammo() -> bool:
	return false


## Short text for the HUD (ammo guns return "ammo / reserve").
func get_hud_text() -> String:
	return weapon_name


## Override: cosmetic attack effect (recoil, muzzle flash, swing). Runs on every peer.
## Never put game logic (damage, ammo) in here - on other peers it is only for looks.
func play_attack_visual() -> void:
	pass


## Override: cosmetic reload effect. Runs on every peer.
func play_reload_visual() -> void:
	pass


## Called (on every peer) when the player switches TO this weapon.
## Adds the draw delay to the cooldown, shows the model and plays the "raise" animation.
func equip() -> void:
	# maxf: if a longer cooldown is still running (you just fired), keep it - switching
	# away and back must never let you attack sooner.
	_cooldown = maxf(_cooldown, draw_time)
	if !viewmodel: return
	viewmodel.visible = true
	# Draw animation: raise the weapon from below the screen, tipped back, into the resting pose.
	# First snap the model to a "lowered" pose (0.4 m down, a bit right and back, tipped back
	# 40 degrees and rolled 15 degrees)...
	if _tween: _tween.kill()
	viewmodel.transform = _rest_transform.translated(Vector3(0.05, -0.4, 0.1)).rotated_local(Vector3.RIGHT, deg_to_rad(-40)).rotated_local(Vector3.FORWARD, deg_to_rad(15))
	# ...then a Tween smoothly animates "transform" back to the rest pose over draw_time seconds.
	# TRANS_BACK + EASE_OUT overshoots a tiny bit at the end, which gives a nice "settle" feel.
	_tween = create_tween()
	_tween.tween_property(viewmodel, "transform", _rest_transform, draw_time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Called (on every peer) when the player switches AWAY from this weapon: hide the model.
func unequip() -> void:
	_reset_viewmodel()
	if viewmodel: viewmodel.visible = false


# --- helpers for subclasses ---------------------------------------------------

## The player's first-person camera. Attacks start from here so they go exactly where the
## crosshair points.
func _camera() -> Camera3D:
	return player.camera


## Godot's physics "space" for this world - the object you ask for ray casts and shape
## overlaps. Only safe to use during _physics_process.
func _space() -> PhysicsDirectSpaceState3D:
	return player.get_world_3d().direct_space_state


## Ray from `from` to `to` that ignores the shooter. Returns {} on miss.
## On a hit the Dictionary has "position", "normal", "collider" etc.
## `mask` picks which physics layers count (default: this weapon's hit_mask).
func _trace(from: Vector3, to: Vector3, mask: int = hit_mask) -> Dictionary:
	# The last argument is an "exclude" list: our own body, so we can't hit ourselves.
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, [player.get_rid()])
	return _space().intersect_ray(q)


## Starts a fresh viewmodel animation: stops the old one, snaps back to the rest pose,
## and returns a new Tween for the caller to fill. Steps added with tween_property() play
## one after another (a sequence), each over the given number of seconds.
func _new_tween() -> Tween:
	_reset_viewmodel()
	_tween = create_tween()
	return _tween


## Stops any running viewmodel animation and puts the model back in its rest pose.
func _reset_viewmodel() -> void:
	if _tween: _tween.kill()
	if viewmodel: viewmodel.transform = _rest_transform
