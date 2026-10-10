extends "res://Scripts/Weapons/hitscan_weapon.gd"
## Two pistols, one in each hand, firing in turn (the Gunslinger's revolvers).
## Shooting, ammo and reloading are the normal hitscan gun (one shared magazine: 6 + 6).
## Only the looks differ: each shot kicks the next gun in turn and flashes its muzzle.
## `viewmodel` is the node holding both guns (shown/hidden and dipped on reload as one).
##
## Set up in Scenes/Gunslinger/gunslinger.tscn. Everything here is visual, so it runs on
## every peer; the damage logic is inherited unchanged from hitscan_weapon.gd.
## Each gun has its own Tween (in `_gun_tweens`) so the two can animate independently while
## the parent `viewmodel` uses the normal tween from weapon.gd.

@export_group("Dual")
## The right-hand gun model (a child of `viewmodel`).
@export var right_gun: Node3D
## The left-hand gun model (a child of `viewmodel`).
@export var left_gun: Node3D
## Muzzle flash particles at the right gun's barrel.
@export var right_flash: GPUParticles3D
## Muzzle flash particles at the left gun's barrel.
@export var left_flash: GPUParticles3D

var _rest := {}       # gun -> resting transform
var _gun_tweens := {} # gun -> tween
## Which gun fires next (flips after every shot).
var _next_right := true


## Like weapon.gd's setup(), but also remembers each gun's own resting pose.
func setup(p_player: CharacterBody3D, p_manager: Node) -> void:
	super(p_player, p_manager)
	for gun in [right_gun, left_gun]:
		if gun: _rest[gun] = gun.transform


## Recoil on ONE gun (every peer): pick the gun whose turn it is, flip the turn, flash its
## muzzle and kick it back and up. Doesn't call super(), so the pair as a whole stays still.
func play_attack_visual() -> void:
	var gun := right_gun if _next_right else left_gun
	var flash := right_flash if _next_right else left_flash
	_next_right = !_next_right
	if flash:
		flash.restart()
		flash.emitting = true
	if gun == null or !_rest.has(gun): return
	var rest: Transform3D = _rest[gun]
	# Stop this gun's previous animation and start from rest, so fast shots don't drift.
	if _gun_tweens.has(gun): _gun_tweens[gun].kill()
	gun.transform = rest
	var kicked := rest.translated_local(Vector3(0, 0, recoil_kick)).rotated_local(Vector3.RIGHT, deg_to_rad(recoil_pitch_degrees))
	var tw := create_tween()
	_gun_tweens[gun] = tw
	tw.tween_property(gun, "transform", kicked, 0.04).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(gun, "transform", rest, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


# Reload spins both guns' barrels down a little while the whole pair dips (see hitscan_weapon).
# super() dips the whole `viewmodel`; on top of that each gun tips 55 degrees nose-down
# (like flipping open a revolver), using the same 25 % / 45 % / 30 % timing as the dip.
func play_reload_visual() -> void:
	super()
	for gun in _rest:
		if _gun_tweens.has(gun): _gun_tweens[gun].kill()
		var rest: Transform3D = _rest[gun]
		var tipped := rest.rotated_local(Vector3.RIGHT, deg_to_rad(-55))
		var tw := create_tween()
		_gun_tweens[gun] = tw
		tw.tween_property(gun, "transform", tipped, reload_time * 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_interval(reload_time * 0.45)
		tw.tween_property(gun, "transform", rest, reload_time * 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


# Tracers come out of whichever gun just fired (play_attack_visual already flipped the side).
# So if the RIGHT gun is next, the LEFT one just fired, and the other way round.
func _tracer_origin() -> Vector3:
	var flash := left_flash if _next_right else right_flash
	if flash and flash.is_inside_tree(): return flash.global_position
	return super()


## Respawn: also start again with the right gun.
func reset() -> void:
	super()
	_next_right = true


## Also stop both guns' own animations and snap them back to rest.
func _reset_viewmodel() -> void:
	super()
	for gun in _rest:
		if _gun_tweens.has(gun): _gun_tweens[gun].kill()
		gun.transform = _rest[gun]
