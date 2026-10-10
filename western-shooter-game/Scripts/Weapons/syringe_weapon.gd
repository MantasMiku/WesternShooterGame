extends "res://Scripts/Weapons/melee_weapon.gd"
## Medic's syringe.
##  - Death Match (no teammates): a self-injection with limited doses (ammo). Each dose heals
##    you over a few seconds and can push you past max health ("overheal", up to
##    max health x overheal_fraction). Overheal slowly drains away after the effect ends.
##    Doses come back over time and from ammo pickups.
##  - Team modes (Team vs Team, Wave Survival): left click fires a syringe dart (heal_dart.gd).
##    A teammate it hits is healed gradually and can be overhealed, the same heal-over-time as
##    the Death Match dose. An enemy it hits is POISONED instead: the reverse effect, damage
##    spread over a few seconds. Darts work like a gun's ammo: a few loaded (`dart_mag`) plus
##    spares (`dart_reserve`). R reloads (and auto reload / holster reload work like on guns),
##    and ammo pickups / dropped ammo boxes refill the spares.
## These are just defaults; everything can still be changed in the Inspector.
##
## Which mode is active is decided live by is_self_use() (it checks the player's team), so the
## same weapon node works in every game mode. Like every weapon, the logic runs on the
## Medic's own peer; the heal itself is done by the healed player (add_heal_over_time).
##
## [b]Multiplayer - how a dart works[/b] (same idea as the Bomber's dynamite):
## [br]1. The Medic's peer runs _fire() and sends [method _spawn_dart] to everyone.
## [br]2. Every peer creates its own copy of the dart and flies it locally.
## [br]3. Only the Medic's copy reports what it hit ([method dart_hit]); a teammate then gets
##    receive_heal_over_time by RPC on their own peer.

## The flying dart's script (a Node3D built in code, no scene needed).
const HealDart = preload("res://Scripts/Weapons/heal_dart.gd")

@export_group("Death Match self-heal")
@export var doses := 3                 ## Doses you can carry.
@export var dose_heal := 60.0          ## HP each dose heals...
@export var dose_seconds := 4.0        ## ...spread over this many seconds.
@export var overheal_fraction := 1.5   ## Can heal up to max health x this (150 -> 225 for the Medic).
@export var dose_recharge := 12.0      ## Seconds to get one dose back.

@export_group("Team heal darts")
@export var dart_mag := 4             ## Darts loaded at once (the "magazine").
@export var dart_reserve := 20         ## Spare darts (also the most spares you can carry).
@export var dart_reload_time := 1.4    ## Seconds to reload the whole magazine.
## Auto reload (if on in the options) starts after this many seconds without firing, or when empty.
@export var dart_idle_reload_delay := 0.8
## Put away for this long, the syringe reloads itself in the background (like the guns).
@export var dart_holster_reload_seconds := 1.0
@export var dart_heal := 45.0          ## HP each dart heals a teammate...
@export var dart_heal_seconds := 3.0   ## ...spread over this many seconds.
## A dart can heal a teammate up to their max health x this (overheal). 1.5 = +50%.
@export var dart_overheal_fraction := 1.5
## Poison: an enemy hit by a dart takes this much damage...
@export var dart_poison := 30.0
## ...spread over this many seconds (several darts stack, like the healing).
@export var dart_poison_seconds := 3.0
@export var dart_speed := 38.0         ## m/s when it leaves the hand.
@export var dart_gravity := 6.0        ## How fast it drops (m/s per second). Real gravity is 9.8.
@export var dart_radius := 0.3         ## Size of the hit ball (bigger = easier to hit teammates).
@export var dart_lifetime := 2.0       ## Seconds before a dart that hit nothing disappears.

var ammo := 0                          ## Doses (Death Match) or loaded darts (team modes).
# reserve, mag_size and reserve_ammo are read-only properties (a "get:" with no variable behind
# it). They make the syringe look like a gun to the HUD and the bots, which read these names.
## HUD shows "ammo / reserve": doses "2 / 3" in Death Match, darts "3 / 20" in team modes.
var reserve: int:
	get: return doses if is_self_use() else _spare_darts
## Death Match: all doses. Team modes: darts per reload.
var mag_size: int:
	get: return doses if is_self_use() else dart_mag
## Most spares you can carry (same name as on guns).
var reserve_ammo: int:
	get: return doses if is_self_use() else dart_reserve
## Seconds counted towards the next recharged dose (Death Match only).
var _recharge := 0.0
## Spare darts (team modes).
var _spare_darts := 0
## True while a dart reload is running.
var _reloading := false
## Seconds until the reload finishes.
var _reload_timer := 0.0
## Seconds since the last dart (for the idle auto reload).
var _since_shot := 0.0
## Seconds the syringe has been put away (for the holster reload).
var _holstered_for := 0.0
## Counter giving each dart a unique id (sent with the spawn RPC so every peer agrees).
var _next_dart_id := 0


## _init runs when the node is created, BEFORE the scene's Inspector values are applied.
## So these only change the defaults inherited from melee_weapon.gd - the scene can
## still override any of them.
func _init() -> void:
	damages_enemies = false
	heals_teammates = true
	heal_amount = 25
	swing_style = Swing.STAB
	swing_time = 0.25


## Start full. The WeaponManager calls setup() once it knows the player, so the team (and with
## it doses vs darts) is known here.
func setup(p_player: CharacterBody3D, p_manager: Node) -> void:
	super(p_player, p_manager)
	ammo = mag_size
	_spare_darts = dart_reserve


## True in Death Match / free-for-all, where there's nobody to heal but yourself.
## (In free-for-all every player gets their own team number of 100 or more.)
func is_self_use() -> bool:
	return player != null and player.team >= 100


## Both modes have ammo now: doses in Death Match, darts in team modes.
func uses_ammo() -> bool:
	return true


## The highest health a dose can heal you to (max health x overheal_fraction).
func _overheal_cap() -> int:
	return roundi(player.max_health * overheal_fraction)


## Every physics frame on the owner's peer.
## Death Match: slowly recharge used doses. Team modes: reload darts (same rules as the guns).
func tick(delta: float) -> void:
	super(delta)
	if is_self_use():
		if ammo < doses:
			_recharge += delta
			if _recharge >= dose_recharge:
				_recharge = 0.0
				ammo += 1
				status_changed.emit()
		return
	_since_shot += delta
	if manager.get_current_weapon() != self:
		# Put away: reload in the background once it has been away long enough.
		_holstered_for += delta
		if _holstered_for >= dart_holster_reload_seconds and ammo < dart_mag and _spare_darts > 0:
			_load_from_spares()
		return
	_holstered_for = 0.0
	if _reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_reloading = false
			_load_from_spares()
	elif _auto_reload_on() and ammo < dart_mag and _spare_darts > 0 and _cooldown <= 0.0 \
			and (ammo == 0 or _since_shot >= dart_idle_reload_delay):
		try_reload()


## Moves darts from the spares into the magazine (as many as fit and as many as are left).
func _load_from_spares() -> void:
	var take := mini(dart_mag - ammo, _spare_darts)
	ammo += take
	_spare_darts -= take
	status_changed.emit()


## Auto reload is on in the player's options (bots always have it).
func _auto_reload_on() -> bool:
	return player != null and player.get("auto_reload_enabled") != false


## Death Match: needs a dose AND you must be below the overheal cap (no wasting doses).
## Team modes: needs a loaded dart and no reload running (plus the normal cooldown).
func can_fire() -> bool:
	if is_self_use():
		return super() and ammo > 0 and player.health < _overheal_cap()
	return super() and ammo > 0 and !_reloading


## Team modes behave like a gun when you click: empty -> start reloading; reloading with darts
## still loaded -> stop the reload and fire.
func try_fire() -> void:
	if !is_self_use():
		if ammo <= 0 and !_reloading:
			try_reload()
			return
		if _reloading and ammo > 0 and _cooldown <= 0.0:
			_reloading = false
			_reset_viewmodel()
			status_changed.emit()
	super()


## R key, empty syringe or auto reload (team modes only; Death Match doses recharge by themselves).
func try_reload() -> void:
	if is_self_use() or _reloading or ammo >= dart_mag or _spare_darts <= 0: return
	_reloading = true
	_reload_timer = dart_reload_time
	status_changed.emit()
	manager.broadcast_reload_visual(self)


## Switching away cancels a reload in progress (the holster reload takes over).
func unequip() -> void:
	if _reloading:
		_reloading = false
		status_changed.emit()
	super()


## Death Match: use a dose and start healing yourself over time.
## Team modes: fire a healing dart along the crosshair.
func _fire() -> void:
	ammo -= 1
	status_changed.emit()
	manager.broadcast_attack_visual(self)
	if is_self_use():
		# We are on our own peer here, so we can heal ourselves directly (no RPC needed).
		player.add_heal_over_time(dose_heal, dose_seconds, _overheal_cap())
		return
	var cam := _camera()
	var b := cam.global_basis
	var dir := -b.z
	var eye := cam.global_position
	# Leave from the hand: a bit in front of the eyes, right and down.
	var start := eye + dir * 0.4 + b.x * 0.15 - b.y * 0.12
	# Up against a wall: let go right in front of the face so it can't come out the other side.
	var wall := _trace(eye, start, 0b01)
	if !wall.is_empty(): start = eye.lerp(wall.position, 0.5)
	# Aim correction: the dart starts beside the eyes, so point it at whatever the crosshair
	# is on (up to 60 m away) instead of straight ahead - otherwise close shots would miss to the right.
	var aim_hit := _trace(eye, eye + dir * 60.0)
	var aim_point: Vector3 = aim_hit.position if !aim_hit.is_empty() else eye + dir * 60.0
	var vel := (aim_point - start).normalized() * dart_speed
	_next_dart_id += 1
	_spawn_dart.rpc(_next_dart_id, start, vel)
	_since_shot = 0.0
	# Just fired the last loaded dart: start reloading right away.
	if ammo <= 0 and _auto_reload_on():
		try_reload()


## Called by the owner's copy of a dart when it touches something.
## A living teammate gets healed over time, a living enemy gets poisoned (both happen on the
## target's own peer, by RPC). Walls are ignored.
func dart_hit(collider: Object, pos: Vector3) -> void:
	if collider == null or !collider.has_method("receive_heal_over_time"): return
	if collider.is_dead: return
	if !player.is_teammate(collider):
		if dart_poison <= 0.0: return
		collider.receive_poison.rpc_id(collider.get_multiplayer_authority(), dart_poison, dart_poison_seconds, player.combat_id, weapon_name)
		# Hitmarker + the total poison damage as a number for the Medic.
		player.report_damage_dealt(roundi(dart_poison), pos)
		return
	var cap := roundi(collider.max_health * dart_overheal_fraction)
	collider.receive_heal_over_time.rpc_id(collider.get_multiplayer_authority(), dart_heal, dart_heal_seconds, cap)
	# Green "+45" number and hitmarker for the Medic.
	player.report_damage_dealt(roundi(dart_heal), pos, true)


## Network message from the Medic: create a flying dart on this peer.
@rpc("authority", "call_local", "reliable")
func _spawn_dart(id: int, start: Vector3, vel: Vector3) -> void:
	var d := HealDart.new()
	d.weapon = self
	d.id = id
	d.velocity = vel
	d.life = dart_lifetime
	d.is_owner_copy = is_multiplayer_authority()
	# Position it before add_child: its trail starts emitting in _ready, and at the world origin
	# that would leave a puff of sparkles in the middle of the map.
	d.top_level = true
	d.position = start
	add_child(d)   # this weapon is a plain Node, so the dart flies freely in world space


## Bots: how much higher than a teammate to aim so the dart's drop lands on them.
## Drop over the flight = 1/2 * gravity * t^2, with t = distance / speed.
func bot_dart_lift(dist: float) -> float:
	var t := dist / dart_speed
	return 0.5 * dart_gravity * t * t


## Ammo pickup / dropped ammo box.
## Death Match: one dose back. Team modes: refills that fraction of your spare darts (at least 1),
## the same as a gun's reserve.
func add_ammo_fraction(fraction: float) -> void:
	if fraction <= 0.0: return
	if is_self_use():
		if ammo < doses:
			ammo += 1
			status_changed.emit()
		return
	_spare_darts = mini(_spare_darts + maxi(1, ceili(dart_reserve * fraction)), dart_reserve)
	status_changed.emit()


## Respawn: everything refilled, timers and reload reset.
func reset() -> void:
	super()
	_reloading = false
	_recharge = 0.0
	ammo = mag_size
	_spare_darts = dart_reserve
	status_changed.emit()


## HUD text: "doses / max doses" in Death Match, "loaded / spare darts" in team modes.
func get_hud_text() -> String:
	return "%d / %d" % [ammo, reserve]


## Death Match: injecting yourself. Team modes: a quick overarm flick.
func play_attack_visual() -> void:
	if !viewmodel:
		return
	var tw := _new_tween()
	if is_self_use():
		# Jab it into your own arm: swing the needle back toward you, hold, pull it out.
		# (Turning 110 degrees around the up axis points the needle back at the player.)
		var jab := _rest_transform.translated(Vector3(-0.18, -0.08, 0.12)).rotated_local(Vector3.UP, deg_to_rad(110))
		tw.tween_property(viewmodel, "transform", jab, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_interval(0.15)
		tw.tween_property(viewmodel, "transform", _rest_transform, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
		return
	# Flick: pull back, snap forward, then a fresh syringe comes up from below.
	var back := _rest_transform.translated(Vector3(0.02, 0.05, 0.1)).rotated_local(Vector3.RIGHT, deg_to_rad(25))
	var flung := _rest_transform.translated(Vector3(-0.05, 0.06, -0.25)).rotated_local(Vector3.RIGHT, deg_to_rad(-20))
	var low := _rest_transform.translated(Vector3(0, -0.35, 0.05))
	tw.tween_property(viewmodel, "transform", back, 0.05).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(viewmodel, "transform", flung, 0.06).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(viewmodel, "transform", low, 0.0)
	tw.tween_interval(0.08)
	tw.tween_property(viewmodel, "transform", _rest_transform, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Reload: dip down out of view to grab a fresh syringe, then bring it back up.
func play_reload_visual() -> void:
	if !viewmodel: return
	var low := _rest_transform.translated(Vector3(-0.04, -0.32, 0.06)).rotated_local(Vector3.FORWARD, deg_to_rad(-25))
	var tw := _new_tween()
	tw.tween_property(viewmodel, "transform", low, dart_reload_time * 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(dart_reload_time * 0.2)
	tw.tween_property(viewmodel, "transform", _rest_transform, dart_reload_time * 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
