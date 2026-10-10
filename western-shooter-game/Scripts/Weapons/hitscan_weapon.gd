extends "res://Scripts/Weapons/weapon.gd"
## Instant-hit gun (shotguns, rifles, revolvers...).
##
## "Hitscan" means there is no flying bullet: when you fire, rays are traced instantly from
## the camera and whatever they touch first is hit. Fires `pellet_count` traces in a cone
## around the crosshair (8 for a shotgun, 1 for a rifle). Walls block shots.
##
## [b]Ammo:[/b] a magazine (`ammo`, up to `mag_size`) plus spare ammo (`reserve`). Reloading either
## refills the whole magazine at once (break-action style) or, with `reload_per_round`, loads
## one round at a time (lever rifles, pump shotguns). It can also reload by itself: after a
## short pause in shooting, when empty, or while the gun is put away (see the Ammo group).
##
## [b]Damage:[/b] each pellet does `damage_per_pellet`, less at long range (falloff) and more
## through the head hitbox (headshots). All pellets that hit the same player are added up and
## sent as ONE damage RPC to that player's owner.
##
## [b]Multiplayer:[/b] firing, ammo and reloading run on the shooter's own peer (see weapon.gd).
## Recoil, muzzle flash and tracers are shown on every peer.
##
## Used directly by most guns (Sheriff, Bomber...) and extended by thrown_weapon.gd and
## dual_pistol_weapon.gd.

@export_group("Damage")
## Damage of one pellet/bullet at close range, before falloff and headshot.
@export var damage_per_pellet := 9
@export var pellet_count := 8            ## Rays per shot. 1 for rifles/pistols.
@export var spread_degrees := 4.5        ## Cone half-angle in degrees. 0 = perfectly accurate.
## How far (metres) a shot can reach. Beyond this it hits nothing.
@export var max_range := 60.0
@export var falloff_start := 8.0         ## Full damage up to this distance (metres)...
@export var falloff_end := 30.0          ## ...then fades down to min_damage_multiplier here.
## Damage multiplier at falloff_end and beyond (0.3 = 30 % damage).
@export var min_damage_multiplier := 0.3
## Damage multiplier for bullets that pass through someone's head hitbox. 1 = no headshots
## (shotguns are set to 1 so a point-blank face shot isn't an instant kill).
@export var headshot_multiplier := 2.0

@export_group("Ammo")
## Rounds the gun holds before it must reload.
@export var mag_size := 2
@export var reserve_ammo := 24           ## Starting spare ammo (also the most spare ammo you can carry).
@export var reload_time := 2.2           ## Seconds to reload the whole magazine (or ONE round, see below).
## Tube-fed guns (lever rifles, pump shotguns): load one round at a time, every `reload_time`
## seconds. Firing interrupts the reload if at least one round is loaded.
@export var reload_per_round := false
@export var auto_reload := true          ## This gun may auto reload (the player's "Auto reload" option must be on too).
## Auto reload: tops the magazine up after this many seconds without shooting (and right away when empty).
@export var idle_reload_delay := 0.8
## Put away for this long, the gun reloads itself in the background - switch back and it's full.
## (Switching away and straight back doesn't count, so it isn't a free instant reload.)
@export var holster_reload_seconds := 1.0

@export_group("Feel")
## Particle effect at the barrel, restarted on every shot. Also where tracers start.
@export var muzzle_flash: GPUParticles3D
@export var recoil_kick := 0.12          ## Viewmodel moves back this far (metres).
@export var recoil_pitch_degrees := 14.0 ## Viewmodel tips up this much.
@export var view_punch_degrees := 1.5    ## Your camera kicks up this much per shot (your view only).
@export var tracers := true              ## Bullet streaks + dust puffs (everyone sees them).

## Script with a static spawn() that draws one bullet streak (Scripts/Effects/tracer.gd).
const Tracer = preload("res://Scripts/Effects/tracer.gd")
const HITBOX_LAYER := 0b100   # head hitboxes (see player_controller.gd)

## Rounds in the magazine right now.
var ammo := 0
## Spare rounds (not in the gun).
var reserve := 0
## True while a reload is running (the gun can't fire unless the reload is interrupted).
var _reloading := false
## Seconds until the current reload (or the current round, for per-round guns) finishes.
var _reload_timer := 0.0
## Seconds since the last shot (for the idle auto reload).
var _since_shot := 0.0
## Seconds this gun has been put away (for the holster reload).
var _holstered_for := 0.0


## Start with a full magazine and full spare ammo.
func _ready() -> void:
	ammo = mag_size
	reserve = reserve_ammo


## Every physics frame on the owner's peer (called by the WeaponManager for every weapon).
## Runs the reload timer and decides when to reload by itself.
func tick(delta: float) -> void:
	super(delta)
	_since_shot += delta
	if manager.get_current_weapon() != self:
		# Holstered: reload in the background.
		# Once it has been away for holster_reload_seconds, move rounds from the reserve into
		# the magazine in one go (no animation - nobody can see a holstered gun).
		_holstered_for += delta
		if _holstered_for >= holster_reload_seconds and ammo < mag_size and reserve > 0:
			var take := mini(mag_size - ammo, reserve)
			ammo += take
			reserve -= take
			status_changed.emit()
		return
	# In hand: restart the holster timer so a quick swap-and-back gives nothing.
	_holstered_for = 0.0
	# The reload "state machine" has just two states: reloading (count down the timer, then
	# finish) or not reloading (maybe start an automatic reload).
	if _reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_finish_reload()
	elif _auto_reload_on() and ammo < mag_size and reserve > 0 and _cooldown <= 0.0 \
			and manager.get_current_weapon() == self and (ammo == 0 or _since_shot >= idle_reload_delay):
		# Auto reload: allowed, not full, has spares, not mid-cooldown, and either empty or
		# we haven't fired for idle_reload_delay seconds.
		try_reload()


## Auto reload is on for this gun AND in the player's options (bots always have it).
## player.get() returns null if the player script has no such option, which also counts as on.
func _auto_reload_on() -> bool:
	return auto_reload and player != null and player.get("auto_reload_enabled") != false


## A gun can fire when the cooldown is over, it isn't reloading and it has a round loaded.
func can_fire() -> bool:
	return super() and !_reloading and ammo > 0


## Called by the WeaponManager when you attack. Handles the special ammo cases before
## the normal cooldown check in weapon.gd.
func try_fire() -> void:
	# Clicking with an empty gun starts a reload instead of shooting.
	if ammo <= 0 and !_reloading:
		try_reload()
		return
	if _reloading and ammo > 0 and _cooldown <= 0.0:
		# Shooting interrupts a reload if there's anything loaded (shell-by-shell guns keep
		# what they've loaded so far; others just stop reloading).
		_reloading = false
		_reset_viewmodel()
		status_changed.emit()
	super()


## One shot: use a round, trace every pellet, add up the damage per player and send it.
## Runs only on the shooter's peer, inside _physics_process.
func _fire() -> void:
	_since_shot = 0.0
	ammo -= 1
	status_changed.emit()
	# Recoil and muzzle flash on every peer.
	manager.broadcast_attack_visual(self)

	var cam := _camera()
	var origin := cam.global_position
	# The camera's basis holds its three direction vectors: -z = forward (where the
	# crosshair points), x = right, y = up.
	var basis := cam.global_basis
	var spread := deg_to_rad(spread_degrees)
	var damage_by_target := {}
	var hit_points := {}   # target -> list of hit positions (averaged for the damage number position)
	var headshot_targets := {}
	var tracer_ends := []   # [end point, hit world?] per pellet

	for i in pellet_count:
		# Random direction inside the spread cone (sqrt gives an even spread across the cone).
		# How it works: pick a random angle away from the centre (0..spread) and a random
		# direction around the centre (a, 0..360 degrees). tan(angle) is how far sideways
		# that is at 1 metre forward. Without the sqrt, more pellets would bunch up near the
		# middle; sqrt spreads them evenly over the circle's area.
		var r := tan(spread * sqrt(randf()))
		var a := randf() * TAU
		# forward + a sideways offset of length r (cos/sin turn angle `a` into a right/up mix).
		var dir := (-basis.z + basis.x * r * cos(a) + basis.y * r * sin(a)).normalized()

		var hit := _trace(origin, origin + dir * max_range)
		if hit.is_empty():
			# Missed everything: the tracer just flies to max range.
			tracer_ends.append([origin + dir * max_range, false])
			continue
		var target = hit.collider
		# Players have receive_damage(); anything else is the world (walls, floor, props).
		var is_player: bool = target.has_method("receive_damage")
		tracer_ends.append([hit.position, !is_player])
		if !is_player or player.is_teammate(target): continue

		# Damage falloff: inverse_lerp gives 0 at falloff_start and 1 at falloff_end
		# (clamped to 0..1 outside that range); lerpf then turns that into a multiplier
		# going from 1.0 (full damage) down to min_damage_multiplier.
		var dist := origin.distance_to(hit.position)
		var t := clampf(inverse_lerp(falloff_start, falloff_end, dist), 0.0, 1.0)
		var dmg := damage_per_pellet * lerpf(1.0, min_damage_multiplier, t)
		if _passes_through_head(target, origin, dir, hit.position):
			dmg *= headshot_multiplier
			headshot_targets[target] = true
		# Add this pellet's damage to the running total for that player.
		damage_by_target[target] = damage_by_target.get(target, 0.0) + dmg
		hit_points[target] = hit_points.get(target, []) + [hit.position]

	# One damage message per player hit (not one per pellet).
	for target in damage_by_target:
		# damage_multiplier = buffs on the shooter (1.0 normally).
		var total := roundi(damage_by_target[target] * player.damage_multiplier)
		if total > 0:
			# rpc_id sends the RPC only to the peer that owns the victim; that peer lowers
			# its own health. combat_id says who gets credit for the kill.
			target.receive_damage.rpc_id(target.get_multiplayer_authority(), total, player.combat_id, weapon_name)
			# Show the damage number at the average of where the pellets hit (local HUD only).
			var pts: Array = hit_points[target]
			var avg := Vector3.ZERO
			for pt in pts: avg += pt
			player.report_damage_dealt(total, avg / pts.size(), false, headshot_targets.has(target))

	if tracers and !tracer_ends.is_empty():
		# Packed arrays are compact and cheap to send over the network. Parallel arrays:
		# ends[i] is where pellet i stopped, world_hits[i] is 1 if it hit a wall (dust puff).
		var ends := PackedVector3Array()
		var world_hits := PackedByteArray()
		for e in tracer_ends:
			ends.append(e[0])
			world_hits.append(1 if e[1] else 0)
		_show_tracers.rpc(ends, world_hits)
	player.add_view_punch(view_punch_degrees)

	# Just fired the last round: start reloading right away.
	if ammo <= 0 and _auto_reload_on():
		try_reload()


## True if the bullet (from origin along dir, which hit `target`'s body at body_hit) also
## goes through the target's head hitbox.
##
## The normal trace only hits player BODIES (capsules on layer 2). The head is a separate
## Area3D (`head_hitbox`, layer 3) placed around the head, so a second ray that only looks
## at areas on that layer checks whether the same bullet line also crosses the head.
func _passes_through_head(target: Node, origin: Vector3, dir: Vector3, body_hit: Vector3) -> bool:
	if headshot_multiplier <= 1.0: return false
	var head: Area3D = target.get("head_hitbox")
	if head == null: return false
	# Ray from the camera to 0.9 m past the body hit, so it can pass all the way through the head.
	var q := PhysicsRayQueryParameters3D.create(origin, body_hit + dir * 0.9, HITBOX_LAYER)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	# Ignore our own head hitbox (the ray starts inside it).
	if player.head_hitbox: q.exclude = [player.head_hitbox.get_rid()]
	var r := _space().intersect_ray(q)
	# Must be THIS target's head, not someone else's standing behind.
	return !r.is_empty() and r.collider == head


## Where tracers start: the muzzle of the gun that just fired.
## (Falls back to just below the camera if there's no muzzle flash node.)
func _tracer_origin() -> Vector3:
	if muzzle_flash and muzzle_flash.is_inside_tree(): return muzzle_flash.global_position
	return player.camera.global_position + Vector3.DOWN * 0.15


## Network message from the shooter: draw a bullet streak to each end point on every peer.
## Unreliable is fine - a missing tracer is only a missing effect.
@rpc("authority", "call_local", "unreliable_ordered")
func _show_tracers(ends: PackedVector3Array, world_hits: PackedByteArray) -> void:
	var from := _tracer_origin()
	for i in ends.size():
		Tracer.spawn(self, from, ends[i], world_hits[i] == 1)


## Start a reload (R key, empty gun, or auto reload). Does nothing if already reloading,
## already full, or out of spare ammo. tick() finishes it after reload_time seconds.
func try_reload() -> void:
	if _reloading or ammo >= mag_size or reserve <= 0: return
	_reloading = true
	_reload_timer = reload_time
	status_changed.emit()
	manager.broadcast_reload_visual(self)


## The reload timer ran out.
## Per-round guns: load ONE round, then start the timer again for the next one (and play the
## animation again) until full or out of spares. Other guns: fill the magazine at once.
func _finish_reload() -> void:
	if reload_per_round:
		ammo += 1
		reserve -= 1
		if ammo < mag_size and reserve > 0:
			_reload_timer = reload_time   # keep going, next round
			manager.broadcast_reload_visual(self)
		else:
			_reloading = false
		status_changed.emit()
		return
	_reloading = false
	# Take only what fits in the magazine, and only what's left in the reserve.
	var take := mini(mag_size - ammo, reserve)
	ammo += take
	reserve -= take
	status_changed.emit()


## Adds spare ammo. Spare ammo is capped at the starting amount.
## Returns how much was really added (0 if already full).
func add_reserve_ammo(amount: int) -> int:
	var before := reserve
	reserve = mini(reserve + amount, reserve_ammo)
	status_changed.emit()
	return reserve - before


## Ammo pickup: `fraction` of the starting spare ammo, rounded up (so you always get at least 1).
func add_ammo_fraction(fraction: float) -> void:
	add_reserve_ammo(ceili(reserve_ammo * fraction))


## Respawn: stop reloading and refill everything.
func reset() -> void:
	super()
	_reloading = false
	ammo = mag_size
	reserve = reserve_ammo
	status_changed.emit()


## Guns use ammo, so the HUD shows "ammo / reserve".
func uses_ammo() -> bool:
	return true


## HUD text, e.g. "2 / 24".
func get_hud_text() -> String:
	return "%d / %d" % [ammo, reserve]


## Putting the gun away. Any rounds already loaded by a per-round reload are kept.
func unequip() -> void:
	# Switching weapons cancels a reload in progress.
	if _reloading:
		_reloading = false
		status_changed.emit()
	super()


## Recoil (every peer): flash the muzzle, then jerk the viewmodel back and up very fast
## (0.05 s) and ease it back to rest (0.3 s).
func play_attack_visual() -> void:
	if muzzle_flash:
		muzzle_flash.restart()
		muzzle_flash.emitting = true
	if !viewmodel: return
	var kicked := _rest_transform.translated_local(Vector3(0, 0, recoil_kick)) \
		.rotated_local(Vector3.RIGHT, deg_to_rad(recoil_pitch_degrees))
	var tw := _new_tween()
	tw.tween_property(viewmodel, "transform", kicked, 0.05).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(viewmodel, "transform", _rest_transform, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


## Reload animation (every peer). Timed from reload_time so it always matches the real reload.
func play_reload_visual() -> void:
	if !viewmodel: return
	if reload_per_round:
		# Quick tilt per round loaded.
		# (This is played again for every round, see _finish_reload().)
		var tilted := _rest_transform.translated(Vector3(-0.05, -0.08, 0.05)) \
			.rotated_local(Vector3.FORWARD, deg_to_rad(-25.0)).rotated_local(Vector3.RIGHT, deg_to_rad(10.0))
		var t := _new_tween()
		t.tween_property(viewmodel, "transform", tilted, reload_time * 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		t.tween_property(viewmodel, "transform", _rest_transform, reload_time * 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
		return
	# Dip the gun down and tilt it, hold, then bring it back up over reload_time.
	# 25 % going down + 45 % holding + 30 % coming back = 100 % of reload_time.
	var lowered := _rest_transform.translated(Vector3(0, -0.25, 0.1)) \
		.rotated_local(Vector3.RIGHT, deg_to_rad(30.0))
	var tw := _new_tween()
	tw.tween_property(viewmodel, "transform", lowered, reload_time * 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(reload_time * 0.45)
	tw.tween_property(viewmodel, "transform", _rest_transform, reload_time * 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
