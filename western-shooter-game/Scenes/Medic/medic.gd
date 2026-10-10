extends "res://Scenes/Player/player_controller.gd"
class_name Medic

## Medic class.
## - 150 HP, medium speed (from the design doc).
## - Weapons (see the WeaponManager node in medic.tscn):
##     1: Remington 1889 - 2-shell shotgun, damages enemies. R to reload.
##     2: Syringe        - melee, heals teammates.
##     3: Bone saw       - melee, damages enemies (Axe model as a placeholder).
##   Switch with 1 / 2 / 3 or the mouse wheel.
## - Passive: regenerates its own health after a few seconds without taking damage.
## Movement comes entirely from PlayerController.
##
## Used on the root node of Scenes/Medic/medic.tscn. Because it "extends" player_controller.gd,
## a Medic IS a PlayerController with everything it has, plus the self-regen below.
## The regen runs only on the Medic's owner peer (where health is changed); the new health then
## reaches everyone else through the MultiplayerSynchronizer.

@export_group("Self Regen")   # groups the next exports under a foldable "Self Regen" header in the Inspector
@export var regen_delay := 4.0        ## Seconds without taking damage before regen starts.
@export var regen_interval := 1.0     ## Seconds between each regen tick.
@export var regen_amount := 3         ## HP healed per tick (so 3 HP per second with the defaults).

## Counts down to the next regen tick (seconds).
var _regen_timer := 0.0
## Seconds since we last lost health.
var _time_since_damage := 0.0
## Health on the previous frame. If health is now lower, we just got hurt.
var _last_health := 0


## Runs once when the Medic appears. super() first runs PlayerController's _ready()
## (team colour, camera, etc.), then we remember the starting health.
func _ready() -> void:
	super()
	_last_health = health


## Every physics frame: do all the normal player movement (super), then the regen.
## Only on the owner's peer, and not while dead.
func _physics_process(delta: float) -> void:
	super(delta)
	if !is_multiplayer_authority() or is_dead: return
	_handle_self_regen(delta)


# --- Self regen ------------------------------------------------------------

## Heals regen_amount every regen_interval seconds, but only after regen_delay seconds
## without taking damage, and only up to max_health.
## Instead of listening for damage, it simply notices when health has gone down since last frame.
func _handle_self_regen(delta: float) -> void:
	if health < _last_health:
		# Just got hurt: restart the waiting time, and make the first tick a full interval later.
		_time_since_damage = 0.0
		_regen_timer = regen_interval
	_last_health = health

	_time_since_damage += delta
	if _time_since_damage < regen_delay or health >= max_health:
		return

	_regen_timer -= delta
	if _regen_timer <= 0.0:
		_regen_timer = regen_interval
		heal(regen_amount)
		# Update right away so our own healing isn't mistaken for a change next frame.
		_last_health = health
