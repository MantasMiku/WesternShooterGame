extends Node3D
## An explosion: the fireball/smoke/light effect (on every peer) plus a damage helper
## (run once, on the peer that owns whatever exploded).
##
##   Explosion.spawn_effect(parent, position, radius)            # cosmetic, call on every peer
##   Explosion.apply_damage(source_player, position, settings)   # damage + knockback, owner only,
##                                                                # call from _physics_process
## Used by the Bomber's dynamite (thrown_weapon.gd) and his death blast (Scenes/Bomber/bomber.gd).
##
## Both helpers are [code]static[/code]: you call them on the script itself
## (Explosion.apply_damage(...)) without having an explosion node first.
## apply_damage must run on exactly ONE peer (the owner of the thing that exploded),
## otherwise everyone would deal the damage again. It sends receive_damage and
## receive_knockback RPCs to each victim's owner. spawn_effect is only looks, so every peer
## runs it for itself.
##
## The visual is built entirely in code (no .tscn): a light, a growing fireball sphere and
## three particle bursts, all made in _ready(). It deletes itself after about 2 seconds.

## Orange colour of the flash light.
const FIRE_COLOR := Color(1.0, 0.55, 0.15)
## Physics layer 2: player bodies (what the blast can hurt).
const PLAYER_LAYER := 0b10
## Physics layer 1: the world (what blocks the blast).
const WORLD_LAYER := 0b01

## Blast radius in metres; sizes the light, fireball and camera shake. Set by spawn_effect().
var radius := 5.0


## Deals the explosion's damage and knockback to every player in range.
## `source` = the player who caused it (gets the kill credit, and is the "self" for
## self-damage), `pos` = centre of the blast.
## Damage settings (all optional): radius, max_damage, min_damage, self_damage_scale,
## knockback, self_knockback, hurt_self, weapon (name for the kill feed).
static func apply_damage(source: Node3D, pos: Vector3, s: Dictionary) -> void:
	var r: float = s.get("radius", 5.0)
	var space := source.get_world_3d().direct_space_state
	# Find every player body overlapping a sphere of the blast radius.
	var sphere := SphereShape3D.new()
	sphere.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), pos)
	q.collision_mask = PLAYER_LAYER
	# A body can be reported more than once (one result per collision shape), so remember
	# who we already handled.
	var done := {}
	for hit in space.intersect_shape(q, 32):
		var body = hit.collider
		if done.has(body) or !body.has_method("receive_damage") or body.is_dead: continue
		done[body] = true
		var is_self: bool = body == source
		if is_self and !s.get("hurt_self", true): continue
		if !is_self and source.is_teammate(body): continue   # no friendly fire

		# Walls protect you: the blast needs a clear line to your chest or your feet.
		# (Checking two points means hiding only your head behind a low wall doesn't save you.)
		# `from` is lifted 15 cm so a stick lying on the floor isn't "blocked" by the floor itself.
		var chest: Vector3 = body.global_position + Vector3.UP * 1.0
		var feet: Vector3 = body.global_position + Vector3.UP * 0.2
		var from := pos + Vector3.UP * 0.15
		if !_clear(space, from, chest) and !_clear(space, from, feet): continue

		# Full damage near the centre, fading out to min_damage at the edge.
		# t = how far out you are as a fraction of the radius: 0 = centre, 1 = edge.
		# lerpf(max, min, t) slides the damage linearly from max_damage down to min_damage.
		var dist := maxf(from.distance_to(chest), 0.0) - 0.5   # roughly the capsule's surface
		var t := clampf(dist / r, 0.0, 1.0)
		var dmg: float = lerpf(s.get("max_damage", 90), s.get("min_damage", 25), t)
		# Your own blast hurts you less; enemies get the thrower's damage buffs.
		if is_self: dmg *= s.get("self_damage_scale", 0.4)
		else: dmg *= source.damage_multiplier
		var amount := roundi(dmg)

		# Knockback, mostly upward so a blast under your feet throws you into the air.
		# Direction: away from the blast (never pointing down), with 0.7 of "up" mixed in,
		# then normalized to length 1. Strength: knockback (m/s) at the centre, 35 % of it
		# at the edge.
		var dir := (chest - pos)
		dir.y = maxf(dir.y, 0.0)
		dir = (dir.normalized() + Vector3.UP * 0.7).normalized()
		var push: float = s.get("self_knockback", 14.0) if is_self else s.get("knockback", 8.0)
		push *= lerpf(1.0, 0.35, t)
		# Movement and health are owned by each player's own peer, so send both there.
		var auth: int = body.get_multiplayer_authority()
		body.receive_knockback.rpc_id(auth, dir * push)
		if amount > 0:
			body.receive_damage.rpc_id(auth, amount, source.combat_id, str(s.get("weapon", "Explosion")))
			# Hitmarker / damage number for the attacker (not for hurting yourself).
			if !is_self: source.report_damage_dealt(amount, chest)


## True if nothing in the world (walls, floor) is between points a and b.
static func _clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(a, b, WORLD_LAYER)
	return space.intersect_ray(q).is_empty()


## The visual: flash of light, fireball, sparks and a puff of smoke. Frees itself.
## Call on every peer. `parent` is any node in the world to attach it to.
static func spawn_effect(parent: Node, pos: Vector3, p_radius := 5.0) -> void:
	# A static function can't use "self", so load this same script and make a new node from it.
	var e: Node3D = load("res://Scripts/Weapons/explosion.gd").new()
	e.radius = p_radius
	parent.add_child(e)
	e.global_position = pos
	# Shake the local player's camera if they're close.
	# Within 3 x radius: the closer you are, the stronger the shake (0.9 right next to it,
	# 0.15 at the far edge). Only works if the current scene has a HUD with add_shake().
	var cam := e.get_viewport().get_camera_3d()
	var hud = parent.get_tree().current_scene.get("hud") if parent.get_tree().current_scene else null
	if cam and hud and hud.has_method("add_shake"):
		var d := cam.global_position.distance_to(pos)
		if d < p_radius * 3.0:
			hud.add_shake(lerpf(0.9, 0.15, d / (p_radius * 3.0)))


## Builds the effect out of code-made nodes and animates it with one Tween.
func _ready() -> void:
	# Bright orange flash that lights up the surroundings.
	var light := OmniLight3D.new()
	light.light_color = FIRE_COLOR
	light.light_energy = 9.0
	light.omni_range = radius * 2.5
	light.position = Vector3.UP * 0.5
	add_child(light)

	# Fireball: an unshaded sphere that swells and fades.
	# Unshaded = ignores lighting, so it looks like it glows. Low polygon count is fine,
	# it's only on screen for a moment.
	var ball := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.45, 0.95)
	mesh.material = mat
	ball.mesh = mesh
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ball.scale = Vector3.ONE * radius * 0.15
	add_child(ball)

	# Arguments: count, lifetime (s), colour, size (m), min/max speed (m/s), gravity, growth.
	add_child(_particles(28, 0.55, Color(1.0, 0.6, 0.15), 0.18, 9.0, 16.0, -4.0, 0.0))    # sparks / fire
	add_child(_particles(18, 1.6, Color(0.3, 0.27, 0.24, 0.8), 0.7, 1.5, 4.0, 1.2, 0.35))  # smoke
	add_child(_particles(14, 1.2, Color(0.35, 0.25, 0.15), 0.08, 5.0, 11.0, -14.0, 0.0))   # dirt chunks

	# set_parallel(): the first three animations play at the same time (not one after another).
	# The fireball grows fast (EXPO), turns red and transparent, and the light fades out.
	var tw := create_tween().set_parallel()
	tw.tween_property(ball, "scale", Vector3.ONE * radius * 0.65, 0.22).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color", Color(1.0, 0.35, 0.05, 0.0), 0.35).set_ease(Tween.EASE_IN)
	tw.tween_property(light, "light_energy", 0.0, 0.45).set_ease(Tween.EASE_OUT)
	# chain() = "after everything above has finished": wait for the smoke to clear, then delete.
	tw.chain().tween_interval(1.6)
	tw.chain().tween_callback(queue_free)


# One-shot burst of little spheres flying outward.
# count = how many, life = seconds each lives, size = sphere radius (m),
# speed_min/max = launch speed (m/s), gravity_y = negative falls, positive rises (smoke),
# grow = how much each particle swells over its life (0 = shrink away instead).
func _particles(count: int, life: float, color: Color, size: float, speed_min: float, speed_max: float,
		gravity_y: float, grow: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = count
	p.lifetime = life
	p.one_shot = true
	# explosiveness 1 = all particles are emitted at the same instant (a burst).
	p.explosiveness = 1.0
	p.randomness = 0.5
	# Shoot upward, spread over an 80-degree half-angle (a wide dome).
	p.direction = Vector3.UP
	p.spread = 80.0
	p.initial_velocity_min = speed_min
	p.initial_velocity_max = speed_max
	p.gravity = Vector3(0, gravity_y, 0)
	# Damping slows the particles down over time (like air resistance).
	p.damping_min = 2.0
	p.damping_max = 4.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	# Size over lifetime: starts at 1, ends at 1 + grow * 6 (grows) or 0 (shrinks to nothing).
	var curve := Curve.new()
	curve.max_value = 10.0
	curve.add_point(Vector2(0, 1.0))
	curve.add_point(Vector2(1, 1.0 + grow * 6.0 if grow > 0.0 else 0.0))
	p.scale_amount_curve = curve
	# Colour over lifetime: from `color` to a darker, fully transparent version (fades out).
	var grad := Gradient.new()
	grad.set_color(0, color)
	grad.set_color(1, Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, 0.0))
	p.color_ramp = grad
	# Each particle is a tiny low-poly sphere.
	var m := SphereMesh.new()
	m.radius = size
	m.height = size * 2.0
	m.radial_segments = 6
	m.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Needed so the color_ramp above actually colours the mesh.
	mat.vertex_color_use_as_albedo = true
	m.material = mat
	p.mesh = m
	p.emitting = true
	return p
