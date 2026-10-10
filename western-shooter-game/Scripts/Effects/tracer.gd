extends Node3D
## Bullet tracer: a bright streak from the muzzle to where the bullet stopped, plus a small
## dust puff where it hit the world. Purely cosmetic, frees itself.
##   Tracer.spawn(parent, from, to, hit_world)
##
## Used by Scripts/Weapons/hitscan_weapon.gd: hitscan guns hit instantly (a raycast), so there is
## no real bullet to see - this streak shows where the shot went. The shooter sends the pellet end
## points to the other peers, and each peer spawns its own tracers, so this runs on every peer
## that draws graphics. It never affects gameplay (damage is decided by the weapon code, not here).

## Colour of the streak (warm yellow-white, like a muzzle flash).
const COLOR := Color(1.0, 0.86, 0.5)

var from := Vector3.ZERO   ## Start of the streak (the muzzle), in world space.
var to := Vector3.ZERO     ## End of the streak (where the bullet stopped), in world space.
var hit_world := false     ## True if the bullet hit a wall/floor (then a dust puff is shown).


## Creates a tracer under `parent`. Static, so callers don't need an instance:
## Tracer.spawn(self, muzzle_pos, hit_pos, true).
static func spawn(parent: Node, p_from: Vector3, p_to: Vector3, p_hit_world: bool) -> void:
	# The script loads itself by path and creates a new node from it. The values are set
	# BEFORE add_child, so they are ready when _ready runs.
	var t: Node3D = load("res://Scripts/Effects/tracer.gd").new()
	t.from = p_from
	t.to = p_to
	t.hit_world = p_hit_world
	parent.add_child(t)


## Builds the streak and the dust puff, then schedules its own removal after 0.5 s.
func _ready() -> void:
	# top_level = ignore the parent's transform, so the tracer stays put in world space even if
	# the gun that fired it moves on the next frame.
	top_level = true
	var dir := to - from
	var length := dir.length()
	# Very short shots (point blank) don't get a streak - it would just be a dot in your face.
	if length > 0.3:
		# A thin unshaded box stretched between the two points.
		# The box is 2.5 cm thick and 1 m long along Z; we scale Z to the shot length below.
		var streak := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.025, 0.025, 1.0)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = COLOR
		box.material = mat
		streak.mesh = box
		streak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(streak)
		# Basis.looking_at needs an "up" direction that isn't parallel to the look direction,
		# otherwise the maths breaks; for (almost) vertical shots use RIGHT as "up" instead.
		var up := Vector3.UP if absf(dir.normalized().dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		# Rotation whose Z axis lies along the shot...
		var b := Basis.looking_at(dir, up)
		# ...then stretch the Z axis to the shot length (scaling a basis axis scales the mesh along it).
		b.z *= length
		# Place the box's centre halfway between muzzle and hit point, so it covers the whole line.
		streak.global_transform = Transform3D(b, from + dir * 0.5)
		# Fade the streak out over 0.09 s (a few frames - just a quick flash).
		var tw := create_tween()
		tw.tween_property(mat, "albedo_color:a", 0.0, 0.09)

	if hit_world:
		# Dust puff: 6 tiny spheres burst out at once (explosiveness 1 = all at the same moment),
		# only once (one_shot), flying back toward the shooter and falling with light gravity.
		var puff := CPUParticles3D.new()
		puff.amount = 6
		puff.lifetime = 0.35
		puff.one_shot = true
		puff.explosiveness = 1.0
		puff.direction = -dir.normalized() if length > 0.01 else Vector3.UP
		puff.spread = 50.0
		puff.initial_velocity_min = 1.0
		puff.initial_velocity_max = 2.5
		puff.gravity = Vector3(0, -4, 0)
		var m := SphereMesh.new()
		m.radius = 0.035
		m.height = 0.07
		m.radial_segments = 4
		m.rings = 2
		var pm := StandardMaterial3D.new()
		pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# Sandy dust colour to match the western desert ground.
		pm.albedo_color = Color(0.75, 0.68, 0.55)
		m.material = pm
		puff.mesh = m
		# Off until it's in place (a new emitter starts on its own, and the tracer node sits at the
		# world origin, so it would first puff there). This node is top_level at the origin, so a
		# local position is the same as a world position.
		puff.emitting = false
		puff.position = to
		add_child(puff)
		puff.emitting = true

	# Delete the whole tracer (streak + puff) after 0.5 s - long enough for both to finish.
	get_tree().create_timer(0.5).timeout.connect(queue_free)
