extends "res://Scripts/Weapons/hitscan_weapon.gd"
## Thrown explosive (the Bomber's dynamite).
## Ammo works like a tube-fed gun: a few sticks ready in hand (`mag_size`) plus spares
## (`reserve_ammo`), and R / running dry reloads one stick at a time.
## Left click throws a stick in an arc. It explodes after `fuse_time`, or on touching an enemy:
## area damage that fades with distance, blocked by walls, and a knockback push.
## The thrower takes reduced damage but a big push - throw one at your feet and jump to fly.
##
## It extends hitscan_weapon.gd only to reuse the ammo/reload system; _fire() is replaced,
## so the hitscan "Damage" settings (pellets, spread...) are not used.
## (`reload_per_round` is switched on for it in Scenes/Bomber/bomber.tscn.)
##
## [b]Multiplayer - how a throw works:[/b]
## [br]1. The thrower's peer runs _fire() and sends [method _spawn_projectile] to everyone.
## [br]2. EVERY peer creates its own copy of the stick (dynamite_projectile.gd) with the same id,
##    start position and velocity, and simulates its physics locally (cheap, smooth).
## [br]3. Only the thrower's copy (`is_owner_copy`) decides when it explodes. It calls
##    detonate(), which deals the damage and sends [method _sync_explode] to everyone.
## [br]4. Every peer then removes its copy and shows the explosion effect at the same spot.
## Copies on other peers might bounce slightly differently, but the one that counts is the
## thrower's, so damage is decided in exactly one place.

## explosion.gd has the static damage and effect helpers used below.
const Explosion = preload("res://Scripts/Weapons/explosion.gd")

@export_group("Throw")
## The dynamite scene (a RigidBody3D with dynamite_projectile.gd) spawned for each throw.
@export var projectile_scene: PackedScene
@export var throw_speed := 18.0          ## m/s along the crosshair.
@export var throw_lift := 3.0            ## Extra upward m/s so it arcs.
@export var inherit_velocity := 0.5      ## How much of your own movement the stick keeps (0..1).
## Seconds from the throw until the stick explodes on its own.
@export var fuse_time := 1.6

@export_group("Explosion")
## Blast radius in metres. Players further away aren't touched.
@export var explosion_radius := 4.5
@export var max_damage := 90             ## At the centre...
@export var min_damage := 25             ## ...fading to this at the edge.
@export var self_damage_scale := 0.4     ## You take this fraction of your own blast.
@export var knockback := 7.0             ## Push on enemies (m/s).
@export var self_knockback := 20.0       ## Push on yourself (m/s) - blast jumping.

## Counter for giving each thrown stick a unique id (only the thrower's peer counts up;
## the id is sent with the spawn RPC so all peers agree).
var _next_id := 0
var _live := {}   # id -> projectile (on every peer): the sticks currently flying


## A throw (thrower's peer only): use a stick, work out where it starts and how fast it
## goes, and tell every peer to spawn it.
func _fire() -> void:
	_since_shot = 0.0
	ammo -= 1
	status_changed.emit()
	manager.broadcast_attack_visual(self)

	var cam := _camera()
	var b := cam.global_basis
	var dir := -b.z
	var eye := cam.global_position
	# Start 0.5 m in front of the eyes, a bit to the right and down (where the hand is).
	var start := eye + dir * 0.5 + b.x * 0.15 - b.y * 0.1
	# Make sure that start point isn't inside a wall (or the stick would fly out the other side).
	var wall := _trace(eye, start, 0b01)
	if !wall.is_empty():   # up against a wall: let go of it right in front of the face
		start = eye.lerp(wall.position, 0.5)
	# Velocity = forward speed + a little upward lift (for the arc) + part of our own movement
	# (so throwing while running forward throws further, like real life).
	var vel := dir * throw_speed + Vector3.UP * throw_lift + player.velocity * inherit_velocity
	_next_id += 1
	_spawn_projectile.rpc(_next_id, start, vel)

	if ammo <= 0 and _auto_reload_on():
		try_reload()


## Called by the owner's copy of a projectile (during physics) when it should go off.
## Deals the damage (here, on the thrower's peer) and tells every peer to show the blast.
func detonate(p: Node3D) -> void:
	# Already exploded / removed? Then do nothing (stops a double explosion).
	if !_live.has(p.id): return
	var pos := p.global_position
	# Settings Dictionary for explosion.gd (see Explosion.apply_damage for what each does).
	Explosion.apply_damage(player, pos, {
		"radius": explosion_radius, "max_damage": max_damage, "min_damage": min_damage,
		"self_damage_scale": self_damage_scale, "knockback": knockback, "self_knockback": self_knockback,
		"weapon": weapon_name,
	})
	_sync_explode.rpc(p.id, pos)


## Network message from the thrower: create a flying stick on this peer.
## "reliable" because a lost spawn would mean an invisible stick for that player.
## The same id is used on every peer, so _sync_explode can find the matching copy later.
@rpc("authority", "call_local", "reliable")
func _spawn_projectile(id: int, start: Vector3, vel: Vector3) -> void:
	if projectile_scene == null: return
	var p: RigidBody3D = projectile_scene.instantiate()
	p.weapon = self
	p.id = id
	p.fuse = fuse_time
	# True only on the thrower's peer: that copy decides when to explode.
	p.is_owner_copy = is_multiplayer_authority()
	add_child(p)   # this weapon is a plain Node, so the stick flies freely in world space
	p.global_position = start
	# Point the stick along its flight direction (Basis.looking_at needs a non-zero direction).
	p.global_basis = Basis.looking_at(vel.normalized()) if vel.length() > 0.1 else Basis()
	p.linear_velocity = vel
	# Spin: tumble end over end around its own x axis, plus a little random wobble.
	p.angular_velocity = p.global_basis.x * -9.0 + Vector3(randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2))
	_live[id] = p
	# When the stick is removed for any reason, forget it.
	p.tree_exiting.connect(func(): _live.erase(id))


## Network message from the thrower: stick `id` exploded at `pos`.
## Every peer removes its copy and plays the explosion effect (damage was already done
## by the thrower in detonate()).
@rpc("authority", "call_local", "reliable")
func _sync_explode(id: int, pos: Vector3) -> void:
	var p = _live.get(id)
	_live.erase(id)
	if p and is_instance_valid(p): p.queue_free()
	Explosion.spawn_effect(self, pos, explosion_radius)


## Bots: how much higher than the target to aim so the arc lands on it.
## Physics: flight time t = distance / speed. In that time gravity pulls the stick down by
## 0.5 * g * t^2, while throw_lift pushes it up by throw_lift * t. Aim higher by the difference.
## (A rough estimate - it ignores that aiming up changes the forward speed a little.)
func bot_aim_lift(dist: float) -> float:
	var t := dist / throw_speed
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity"))
	return maxf(0.5 * g * t * t - throw_lift * t, 0.0)


# Throw animation: pull back, fling forward, a fresh stick comes up from below.
# (Runs on every peer. Total about 0.5 s.)
func play_attack_visual() -> void:
	if !viewmodel: return
	var back := _rest_transform.translated(Vector3(0.02, 0.06, 0.12)).rotated_local(Vector3.RIGHT, deg_to_rad(35))
	var flung := _rest_transform.translated(Vector3(-0.08, 0.12, -0.35)).rotated_local(Vector3.RIGHT, deg_to_rad(-50))
	var low := _rest_transform.translated(Vector3(0, -0.45, 0.05))
	var tw := _new_tween()
	tw.tween_property(viewmodel, "transform", back, 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(viewmodel, "transform", flung, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# Duration 0 = jump instantly below the screen (the "new" stick), wait, then rise up.
	tw.tween_property(viewmodel, "transform", low, 0.0)
	tw.tween_interval(0.12)
	tw.tween_property(viewmodel, "transform", _rest_transform, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Reload: dip down to grab another stick from the belt.
# (Played once per stick, since dynamite reloads one at a time.)
func play_reload_visual() -> void:
	if !viewmodel: return
	var low := _rest_transform.translated(Vector3(-0.05, -0.3, 0.05)).rotated_local(Vector3.FORWARD, deg_to_rad(-20))
	var tw := _new_tween()
	tw.tween_property(viewmodel, "transform", low, reload_time * 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(viewmodel, "transform", _rest_transform, reload_time * 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
