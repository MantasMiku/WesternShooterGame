extends Node3D
## A healing syringe fired by the Medic in team modes (Team vs Team, Wave Survival).
## It flies fast in a slight arc. When it touches a teammate it heals them gradually and can
## overheal them (the same heal-over-time as the Death Match self-dose). Walls and enemies just stop it.
##
## Created by syringe_weapon.gd's _spawn_dart() RPC on EVERY peer, so everyone sees it fly.
## Every copy moves itself and stops when it touches something, but only the thrower's copy
## (`is_owner_copy`) tells the weapon what it hit, so the heal is given exactly once.
##
## It isn't a physics body: each frame it sweeps a small sphere from where it was to where it
## will be (cast_motion), so a fast dart can't skip through a thin wall or a player between frames.

## First-person syringe model, reused as the flying dart.
const MODEL := preload("res://Scenes/Weapons/syringe_viewmodel.tscn")

var weapon: Node              ## The syringe_weapon.gd that fired it.
var id := 0                   ## Same number on every peer (matches the copies up).
var velocity := Vector3.ZERO  ## Metres per second; gravity is added every frame.
var is_owner_copy := false    ## True only on the thrower's peer: this copy reports hits.
var life := 2.0               ## Seconds until it disappears if it hits nothing.

## The sweep shape: a small ball around the dart (bigger = easier to hit teammates).
var _shape := SphereShape3D.new()


## Builds the look: the syringe model plus a short green trail.
func _ready() -> void:
	_shape.radius = weapon.dart_radius
	var model: Node3D = MODEL.instantiate()
	model.scale = Vector3.ONE * 1.6
	add_child(model)
	# Green sparkles left behind in the air (local_coords = false makes them stay where they
	# were emitted instead of following the dart, which draws a trail).
	var trail := CPUParticles3D.new()
	trail.local_coords = false
	trail.amount = 24
	trail.lifetime = 0.35
	trail.gravity = Vector3.ZERO
	trail.initial_velocity_min = 0.0
	trail.initial_velocity_max = 0.2
	var dot := SphereMesh.new()
	dot.radius = 0.035
	dot.height = 0.07
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.45, 1.0, 0.55)
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dot.material = mat
	trail.mesh = dot
	var fade := Gradient.new()
	fade.set_color(0, Color(0.55, 1, 0.6, 0.9))
	fade.set_color(1, Color(0.3, 1, 0.5, 0))
	trail.color_ramp = fade
	add_child(trail)
	_face_velocity()


## Every physics frame on every peer: fall a little, move, and stop on the first thing touched.
func _physics_process(delta: float) -> void:
	# The weapon (or its player) was removed - nothing left to report to.
	if !is_instance_valid(weapon) or !is_instance_valid(weapon.player):
		queue_free()
		return
	life -= delta
	if life <= 0.0:
		queue_free()
		return
	velocity.y -= weapon.dart_gravity * delta
	var from := global_position
	var motion := velocity * delta
	var hit := _sweep(from, motion)
	if hit.is_empty():
		global_position = from + motion
		_face_velocity()
		return
	# Touched something: only the owner's copy reports it (the heal happens once), then all copies vanish.
	global_position = hit.position
	if is_owner_copy:
		weapon.dart_hit(hit.collider, hit.position)
	queue_free()


## Moves a small ball from `from` along `motion` and returns the first thing it touches as
## {collider, position}, or {} if the path is clear. Ignores the thrower's own body.
func _sweep(from: Vector3, motion: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _shape
	q.transform = Transform3D(Basis(), from)
	q.motion = motion
	q.collision_mask = weapon.hit_mask           # world + players
	q.exclude = [weapon.player.get_rid()]
	# cast_motion returns [safe, unsafe] fractions of the motion; unsafe < 1 means we would touch something.
	var fractions := space.cast_motion(q)
	if fractions[1] >= 1.0: return {}
	var point := from + motion * fractions[1]
	# Ask what is touching the ball at that point.
	q.transform = Transform3D(Basis(), point)
	q.motion = Vector3.ZERO
	var info := space.get_rest_info(q)
	var collider: Object = instance_from_id(info.collider_id) if info.has("collider_id") else null
	return {"collider": collider, "position": point}


## Points the needle (the model's -Z) along the flight direction.
func _face_velocity() -> void:
	if velocity.length() > 0.1:
		global_basis = Basis.looking_at(velocity.normalized())
