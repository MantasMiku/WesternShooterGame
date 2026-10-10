extends "res://Scenes/Player/player_controller.gd"
class_name Gunslinger

## Gunslinger class (Offense) - an outcast who's spent years running from trouble.
## - 125 HP, fast (from the design doc).
## - Weapons (see the WeaponManager node in gunslinger.tscn):
##     1: Dual revolvers - one in each hand, firing in turn. 12 shots, fast, mid range.
##     2: Coach gun      - sawed-off double barrel. 2 shells, brutal up close.
##     3: Bowie knife    - quick stab.
## - Passive: double jump. Jump again in the air to get a second jump, and steer toward
##   where you're pressing (WASD) - for dodging and reaching high spots.
##
## Used on the root node of Scenes/Gunslinger/gunslinger.tscn. Inherits all movement from
## player_controller.gd and only adds the air jump. Like all movement, the air jump runs on
## the owner's peer only (for bots: the server); the synchronizer shows the result to everyone.

@export_group("Double Jump")   # foldable "Double Jump" header in the Inspector
@export var air_jumps := 1                ## Extra jumps in the air (0 = no double jump).
@export var air_jump_velocity := 6.5      ## Upward speed of an air jump, in m/s.

## Air jumps still available before landing again.
var _air_jumps_left := 0


## Checks for an air jump BEFORE the normal movement (super) runs, so the new velocity is
## used by this same frame's air physics and move_and_slide().
func _physics_process(delta: float) -> void:
	if is_multiplayer_authority() and !is_dead:
		_handle_air_jump()
	super(delta)


## Refills air jumps on the ground; in the air, a fresh jump press uses one up.
func _handle_air_jump() -> void:
	if is_on_floor() or no_clip:
		_air_jumps_left = air_jumps
		return
	# _wants_just("jump") = jump pressed this frame (works for bots too). Holding jump won't repeat it.
	if !input_enabled or frozen or _air_jumps_left <= 0 or !_wants_just("jump"):
		return
	_air_jumps_left -= 1
	velocity.y = air_jump_velocity   # set, not add: a double jump always gives the same height, even while falling
	# Steer: the second jump goes where you're pressing, keeping your speed.
	var input := _move_input()
	if input.length() > 0.1:
		# Turn the 2D input into a world direction relative to where the body faces.
		var dir := (global_basis * Vector3(input.x, 0, input.y)).normalized()
		# Keep the current horizontal speed (but at least walking speed), just change its direction.
		var speed := maxf(Vector2(velocity.x, velocity.z).length(), walk_speed)
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
