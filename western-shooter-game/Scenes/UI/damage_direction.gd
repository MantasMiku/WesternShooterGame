extends Control
## Red arcs around the crosshair pointing toward whoever just hit you.
## Arcs keep pointing at the attacker's position while you turn, then fade out.
##
## Lives in hud.tscn (node %DamageDirection), covering the screen. hud.gd sets `camera`
## in bind_player() and calls add_hit() from the player's damage_taken signal.
## Local-only UI; everything is drawn in code in _draw().
##
## The trick: we store the attacker's 3D WORLD position (not a fixed screen angle).
## Each frame we work out where that point is relative to the camera, so if you turn
## around, the arc slides around the circle to keep pointing at the attacker.

## Distance of the arcs from the screen centre, in pixels.
@export var radius := 150.0
## How wide each arc is: it spans this many degrees to each side of its direction.
@export var arc_half_angle_degrees := 22.0
## Arc line width in pixels.
@export var thickness := 10.0
## Seconds an arc stays on screen.
@export var lifetime := 1.6
## Arc colour.
@export var color := Color(0.9, 0.08, 0.05)

## The local player's camera (set by hud.gd). Needed to know which way we are facing.
var camera: Camera3D
var _hits: Array = []   # [{pos: Vector3, age: float}]


## Adds an arc pointing at a world position (where the attacker was).
func add_hit(from_position: Vector3) -> void:
	# Merge with a recent arc from (almost) the same place instead of stacking.
	# (Within 1.5 m counts as the same attacker; we just refresh that arc.)
	for h in _hits:
		if h.pos.distance_to(from_position) < 1.5:
			h.pos = from_position
			h.age = 0.0
			return
	_hits.append({pos = from_position, age = 0.0})


## Ages the arcs, drops expired ones, and redraws (the camera may have turned).
func _process(delta: float) -> void:
	if _hits.is_empty(): return
	for h in _hits: h.age += delta
	_hits = _hits.filter(func(h): return h.age < lifetime)
	queue_redraw()


## Draws every active arc plus a small arrow tip.
func _draw() -> void:
	if camera == null or !is_instance_valid(camera) or !camera.is_inside_tree(): return
	var center := size * 0.5
	var half := deg_to_rad(arc_half_angle_degrees)
	for h in _hits:
		# Convert the world position into the camera's own local space.
		# affine_inverse() undoes the camera's position+rotation. In camera space,
		# -Z is straight ahead and +X is to the right.
		var local: Vector3 = camera.global_transform.affine_inverse() * h.pos
		# 0 = straight ahead, + = to the right. Screen "up" is ahead.
		# atan2 gives the angle seen from above (height is ignored). In Godot 2D, angle 0 points
		# right and angles grow clockwise (because screen Y goes down), so subtracting 90 degrees
		# turns "ahead" into "up on the screen".
		var angle := atan2(local.x, -local.z) - PI * 0.5
		# Fade: t goes 0 -> 1 over the lifetime; 1 - t*t stays bright for a while, then drops fast.
		var t: float = h.age / lifetime
		var a := 1.0 - t * t
		var pop: float = 1.0 + 0.25 * maxf(0.0, 1.0 - h.age * 6.0)   # small pop when it appears
		# Dark, thicker arc first (outline), then the coloured arc on top. 24 = segments (smoothness).
		draw_arc(center, radius * pop, angle - half, angle + half, 24, Color(0, 0, 0, 0.45 * a), thickness + 4.0, true)
		draw_arc(center, radius * pop, angle - half, angle + half, 24, Color(color, a), thickness, true)
		# Little arrow tip on the outside of the arc.
		# dir points outward toward the attacker, side is perpendicular to it;
		# the triangle is: tip 16 px out, two corners 11 px to each side.
		var dir := Vector2(cos(angle), sin(angle))
		var side := Vector2(-dir.y, dir.x)
		var base := center + dir * (radius * pop + thickness * 0.5)
		draw_colored_polygon(PackedVector2Array([base + dir * 16.0, base + side * 11.0, base - side * 11.0]), Color(color, a))
