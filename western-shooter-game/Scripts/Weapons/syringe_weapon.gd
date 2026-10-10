extends "res://Scripts/Weapons/melee_weapon.gd"
## Medic's syringe.
##  - Team modes: a melee weapon that heals teammates instead of hurting enemies.
##  - Death Match (no teammates): a self-injection with limited doses (ammo). Each dose heals
##    you over a few seconds and can push you past max health ("overheal", up to
##    max health x overheal_fraction). Overheal slowly drains away after the effect ends.
##    Doses come back over time and from ammo pickups.
## These are just defaults; everything can still be changed in the Inspector.
##
## Which mode is active is decided live by is_self_use() (it checks the player's team), so the
## same weapon node works in every game mode. Like every weapon, the logic runs on the
## Medic's own peer; the heal itself is done by the player (add_heal_over_time / receive_heal).

@export_group("Death Match self-heal")
@export var doses := 3                 ## Doses you can carry.
@export var dose_heal := 60.0          ## HP each dose heals...
@export var dose_seconds := 4.0        ## ...spread over this many seconds.
@export var overheal_fraction := 1.5   ## Can heal up to max health x this (150 -> 225 for the Medic).
@export var dose_recharge := 12.0      ## Seconds to get one dose back.

var ammo := 0                          ## Doses left (shown on the HUD like ammo).
# reserve and mag_size are read-only properties (a "get:" with no variable behind it). They
# exist so code that expects a gun (e.g. a HUD reading .reserve / .mag_size) also works here.
var reserve: int:                      ## HUD shows "ammo / reserve" -> "2 / 3".
	get: return doses
## Same as doses (the "magazine" is full when you hold all your doses).
var mag_size: int:
	get: return doses
## Seconds counted towards the next recharged dose.
var _recharge := 0.0


## _init runs when the node is created, BEFORE the scene's Inspector values are applied.
## So these only change the defaults inherited from melee_weapon.gd - the scene can
## still override any of them.
func _init() -> void:
	damages_enemies = false
	heals_teammates = true
	heal_amount = 25
	swing_style = Swing.STAB
	swing_time = 0.25


## Start with all doses.
func _ready() -> void:
	ammo = doses


## True in Death Match / free-for-all, where there's nobody to heal but yourself.
## (In free-for-all every player gets their own team number of 100 or more.)
func is_self_use() -> bool:
	return player != null and player.team >= 100


## Only show an ammo counter in Death Match (in team modes the syringe never runs out).
func uses_ammo() -> bool:
	return is_self_use()


## The highest health a dose can heal you to (max health x overheal_fraction).
func _overheal_cap() -> int:
	return roundi(player.max_health * overheal_fraction)


## Every physics frame on the owner's peer: in Death Match, slowly recharge used doses
## (one every dose_recharge seconds).
func tick(delta: float) -> void:
	super(delta)
	if is_self_use() and ammo < doses:
		_recharge += delta
		if _recharge >= dose_recharge:
			_recharge = 0.0
			ammo += 1
			status_changed.emit()


## Death Match: needs a dose AND you must be below the overheal cap (no wasting doses).
## Team modes: the normal melee rule (just the cooldown).
func can_fire() -> bool:
	if is_self_use():
		return super() and ammo > 0 and player.health < _overheal_cap()
	return super()


## Team modes: a normal melee jab that heals the teammate in front of you (melee_weapon.gd).
## Death Match: use a dose and start healing yourself over time.
func _fire() -> void:
	if !is_self_use():
		super()
		return
	ammo -= 1
	status_changed.emit()
	manager.broadcast_attack_visual(self)
	# We are on our own peer here, so we can heal ourselves directly (no RPC needed).
	player.add_heal_over_time(dose_heal, dose_seconds, _overheal_cap())


## Ammo pickup in Death Match: gives back one dose (however big the pickup is).
func add_ammo_fraction(fraction: float) -> void:
	if is_self_use() and fraction > 0.0 and ammo < doses:
		ammo += 1
		status_changed.emit()


## Respawn: all doses back, recharge timer restarted.
func reset() -> void:
	super()
	ammo = doses
	_recharge = 0.0
	status_changed.emit()


## HUD: "doses left / max doses" in Death Match, otherwise just the weapon's name.
func get_hud_text() -> String:
	return "%d / %d" % [ammo, doses] if is_self_use() else weapon_name


## Team modes: the normal stab animation. Death Match: injecting yourself.
func play_attack_visual() -> void:
	if !is_self_use() or !viewmodel:
		super()
		return
	# Jab it into your own arm: swing the needle back toward you, hold, pull it out.
	# (Turning 110 degrees around the up axis points the needle back at the player.)
	var tw := _new_tween()
	var jab := _rest_transform.translated(Vector3(-0.18, -0.08, 0.12)).rotated_local(Vector3.UP, deg_to_rad(110))
	tw.tween_property(viewmodel, "transform", jab, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.15)
	tw.tween_property(viewmodel, "transform", _rest_transform, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
