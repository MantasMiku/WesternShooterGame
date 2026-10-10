extends "res://Scripts/Weapons/weapon.gd"
## Close-range weapon. Hits the nearest valid player in a short cone in front of the camera
## (more forgiving than a single thin ray). Walls block hits.
## Can damage enemies, heal teammates, or both - set in the Inspector.
##
## Used for the characters' knives/hatchets, and extended by syringe_weapon.gd (Medic).
## Like every weapon, _fire() runs only on the attacker's peer: it picks the target and
## sends receive_damage / receive_heal by RPC to the target's owner. The swing animation
## is broadcast to everyone.

## Animation style of the swing: STAB pokes forward, CHOP winds up and slashes down.
enum Swing { STAB, CHOP }

@export_group("Effect")
@export var damage := 45                 ## Damage to enemies (if damages_enemies).
## Can this weapon hurt enemies?
@export var damages_enemies := true
@export var heal_amount := 0             ## Healing for teammates (if heals_teammates).
## Can this weapon heal teammates?
@export var heals_teammates := false

@export_group("Reach")
@export var melee_range := 2.2           ## Metres from the camera.
@export var aim_cone_degrees := 35.0     ## How far off-crosshair (degrees) a target can be and still get hit.

@export_group("Feel")
## Which swing animation to play (purely visual).
@export var swing_style := Swing.CHOP
## Seconds the swing animation takes (visual only - fire_cooldown sets the attack rate).
@export var swing_time := 0.3


## One swing (owner's peer only): play the animation everywhere, find a target, and
## heal it (teammate) or damage it (enemy). Missing is fine - the swing still plays.
func _fire() -> void:
	manager.broadcast_attack_visual(self)

	var target = _find_target()
	if target == null: return

	# Roughly chest height, used for where the damage/heal number pops up.
	var hit_point: Vector3 = target.global_position + Vector3.UP * 1.2
	if player.is_teammate(target):
		target.receive_heal.rpc_id(target.get_multiplayer_authority(), heal_amount)
		player.report_damage_dealt(heal_amount, hit_point, true)
	else:
		var dmg := roundi(damage * player.damage_multiplier)
		target.receive_damage.rpc_id(target.get_multiplayer_authority(), dmg, player.combat_id, weapon_name)
		player.report_damage_dealt(dmg, hit_point)


## Can this weapon do anything to `body`? Never yourself; teammates only if it heals,
## enemies only if it damages.
func _can_affect(body: Node) -> bool:
	if body == player: return false
	if player.is_teammate(body):
		return heals_teammates and heal_amount > 0 and body.has_method("receive_heal")
	return damages_enemies and body.has_method("receive_damage")


## Finds the best player to hit: the closest valid one that is within reach, roughly in
## front of the crosshair and not behind a wall. Returns null if there is none.
func _find_target() -> Node:
	var cam := _camera()
	var origin := cam.global_position
	var forward := -cam.global_basis.z

	# 1) Grab every player body in a sphere covering the reach in front of us.
	# The sphere's diameter is melee_range and its centre is half that far ahead, so it
	# covers the space from the camera out to melee_range.
	var sphere := SphereShape3D.new()
	sphere.radius = melee_range * 0.5
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), origin + forward * melee_range * 0.5)
	q.collision_mask = 0b10   # players only
	q.exclude = [player.get_rid()]
	var results := _space().intersect_shape(q, 16)

	# 2) Keep those in front of us, in reach, and not behind a wall; pick the closest.
	var best: Node = null
	var best_dist := INF
	# Dot product trick: for two unit vectors, dot = cos(angle between them). A target is
	# inside the cone if dot >= cos(aim_cone_degrees).
	var min_dot := cos(deg_to_rad(aim_cone_degrees))
	for r in results:
		var body = r.collider
		if !_can_affect(body): continue
		# Aim at the middle of the body (1 m above the feet), not at the feet.
		var aim_point: Vector3 = body.global_position + Vector3.UP * 1.0
		var to_target := aim_point - origin
		var dist := to_target.length()
		# +0.5 m of slack because we measure to the body's centre, not its surface.
		if dist > melee_range + 0.5: continue
		# Outside the cone? Skip - unless they are really close (< 0.8 m), where the angle
		# changes wildly and you should hit anyway.
		if forward.dot(to_target / maxf(dist, 0.001)) < min_dot and dist > 0.8: continue
		var wall := _trace(origin, aim_point, 0b01)   # world only
		if !wall.is_empty(): continue
		if dist < best_dist:
			best_dist = dist
			best = body
	return best


## Swing animation (every peer). The pieces of the Tween play one after another and
## add up to swing_time.
func play_attack_visual() -> void:
	if !viewmodel: return
	var tw := _new_tween()
	if swing_style == Swing.STAB:
		# Thrust 0.35 m forward (-z is forward), then pull back.
		var out := _rest_transform.translated(Vector3(0, 0.03, -0.35))
		tw.tween_property(viewmodel, "transform", out, swing_time * 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(viewmodel, "transform", _rest_transform, swing_time * 0.65).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	else:
		# Wind up (raise and pull back), then chop down and across, then return.
		var wind := _rest_transform.translated(Vector3(0.05, 0.12, 0.08)).rotated_local(Vector3.RIGHT, deg_to_rad(35))
		var hit := _rest_transform.translated(Vector3(-0.2, -0.15, -0.2)).rotated_local(Vector3.RIGHT, deg_to_rad(-80)) \
			.rotated_local(Vector3.BACK, deg_to_rad(25))
		# EASE_IN on the chop = starts slow and speeds up, so the blow feels heavy.
		tw.tween_property(viewmodel, "transform", wind, swing_time * 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(viewmodel, "transform", hit, swing_time * 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(viewmodel, "transform", _rest_transform, swing_time * 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
