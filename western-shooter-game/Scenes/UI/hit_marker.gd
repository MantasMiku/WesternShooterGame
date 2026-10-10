extends Control
## Crosshair hitmarker: four short diagonal lines that pop out and fade when your attack lands.
##
## Lives in hud.tscn (node %HitMarker), centred on the crosshair. hud.gd calls flash()
## when the local player's damage_dealt signal fires. Local-only UI.
## Nothing is a texture: the lines are drawn in code in _draw() with draw_line().
## The node's position is the centre, so drawing around (0, 0) puts the lines around the crosshair.

## Distance (pixels) from the centre to where each line starts.
@export var gap := 7.0
## Length of each line in pixels.
@export var length := 11.0
## Line width in pixels.
@export var thickness := 3.0

## Colour of the current flash (white, orange, red for headshots, green for heals...).
var _color := Color.WHITE
## Current opacity (1 = fully visible, 0 = gone). Animated by a tween.
var _alpha := 0.0
## The running animation, so a new hit can cancel the previous one.
var _tween: Tween


## Shows the hitmarker. big = larger pop (big hits and headshots).
func flash(color: Color, big := false) -> void:
	_color = color
	_alpha = 1.0
	# Start a bit oversized and slightly tilted at random, then animate back to normal.
	# The random tilt makes rapid hits feel less repetitive.
	scale = Vector2.ONE * (1.7 if big else 1.35)
	rotation = deg_to_rad(randf_range(-6.0, 6.0))
	if _tween: _tween.kill()
	# Parallel tween: scale, rotation and fade all run at the same time.
	_tween = create_tween().set_parallel()
	_tween.tween_property(self, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "rotation", 0.0, 0.12)
	# tween_method calls _set_alpha with values going 1 -> 0. We need a method (not a property)
	# because the drawing must be redone (queue_redraw) whenever alpha changes.
	_tween.tween_method(_set_alpha, 1.0, 0.0, 0.35).set_delay(0.08)


## Tween callback: stores the new opacity and asks Godot to call _draw() again.
func _set_alpha(a: float) -> void:
	_alpha = a
	queue_redraw()


## Draws the four diagonal lines. Godot only calls this when queue_redraw() was requested.
func _draw() -> void:
	if _alpha <= 0.0: return
	var shadow := Color(0, 0, 0, 0.6 * _alpha)
	var c := Color(_color, _alpha)
	# First pass: slightly thicker dark lines as a shadow/outline so it's visible on bright backgrounds.
	for dir in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		# normalized() makes the diagonal length 1, so gap/length are in real pixels.
		var d: Vector2 = dir.normalized()
		draw_line(d * gap, d * (gap + length), shadow, thickness + 2.0, true)
	# Second pass: the coloured lines on top. The last "true" turns on anti-aliasing (smooth edges).
	for dir in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var d: Vector2 = dir.normalized()
		draw_line(d * gap, d * (gap + length), c, thickness, true)
