extends Control
## Teammate health on the HUD (team modes only - in Death Match nobody is your teammate).
##  1. Everyone: put your crosshair on a teammate and a small card floats above their head
##     with their name, a health bar and "HP / max" (blue while overhealed).
##  2. Medic only: every teammate below `critical_fraction` of their health gets a red cross
##     floating over their head, even through walls, so the Medic knows who needs healing.
##     It pulses faster and turns brighter red the lower they are.
##
## Created in code by hud.gd (no .tscn) and drawn with _draw() every frame. Purely visual and
## local: health is already synced to every peer by the MultiplayerSynchronizer, so we just read it.

## Below this fraction of max health a teammate counts as "critical" (Medic markers).
@export var critical_fraction := 0.5
## How far away (metres) the crosshair can pick up a teammate.
@export var hover_range := 60.0
## Medic markers are hidden for teammates further away than this (metres).
@export var marker_range := 80.0

const TEXT := Color(0.96, 0.92, 0.84)
const OUTLINE := Color(0.08, 0.04, 0.02)
const HP_GREEN := Color(0.4, 0.9, 0.45)
const HP_YELLOW := Color(1.0, 0.8, 0.3)
const HP_RED := Color(1.0, 0.3, 0.25)
const OVERHEAL := Color(0.55, 0.85, 1.0)

var player: Node3D      ## The local player (set by hud.gd's bind_player).
var _hovered: Node3D    # teammate under the crosshair (null = none)
var _hover_hold := 0.0  # keeps the card up briefly after the crosshair slips off (no flicker)
var _t := 0.0           # time, for the pulse


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func bind_player(p: Node3D) -> void:
	player = p
	_hovered = null


## Every frame: find the teammate under the crosshair, then redraw.
func _process(delta: float) -> void:
	_t += delta
	if !_valid():
		_hovered = null
		queue_redraw()
		return
	var hit := _teammate_under_crosshair()
	if hit:
		_hovered = hit
		_hover_hold = 0.25
	else:
		_hover_hold -= delta
		if _hover_hold <= 0.0: _hovered = null
	queue_redraw()


## True when there is a living local player with a camera to work with.
func _valid() -> bool:
	return player != null and is_instance_valid(player) and !player.is_dead and player.camera != null


## True if `other` is a living teammate (never yourself, never in free-for-all).
func _is_mate(other) -> bool:
	return other != null and is_instance_valid(other) and other != player and other.get("team") != null \
		and player.team < 100 and player.is_teammate(other) and !other.is_dead


## Casts a ray from the camera along the crosshair; returns the teammate it hits first, or null.
## Mask 0b11 = world + players, so a wall in front of a teammate blocks the hover.
func _teammate_under_crosshair() -> Node3D:
	var cam: Camera3D = player.camera
	var from := cam.global_position
	var to := from - cam.global_basis.z * hover_range
	var q := PhysicsRayQueryParameters3D.create(from, to, 0b11, [player.get_rid()])
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty(): return null
	return hit.collider if _is_mate(hit.collider) else null


func _draw() -> void:
	if !_valid(): return
	if player is Medic: _draw_critical_markers(_hovered)
	if _hovered and _is_mate(_hovered): _draw_hover_card(_hovered)


# --- Hover card ---------------------------------------------------------------------------

## Name, health bar and numbers floating above the teammate's head.
func _draw_hover_card(mate: Node3D) -> void:
	var cam: Camera3D = player.camera
	var head: Vector3 = mate.global_position + Vector3.UP * 2.35
	if cam.is_position_behind(head): return
	var anchor := cam.unproject_position(head)   # screen point above their head
	var font := get_theme_default_font()
	var w := 130.0
	# The card sits just above that point: name, bar, numbers (bottom edge at the anchor).
	var top := anchor.y - 40.0
	var center := Vector2(anchor.x, top)
	var hp: int = mate.health
	var max_hp: int = mate.max_health
	var frac := clampf(float(hp) / max_hp, 0.0, 1.0)
	# Name
	var name_text: String = str(mate.get("player_name"))
	_text(font, name_text, Vector2(center.x, top), 16, TEXT)
	# Bar: dark background, coloured fill, light-blue extra part for overheal.
	var bar := Rect2(center.x - w * 0.5, top + 7.0, w, 8.0)
	draw_rect(bar.grow(2.0), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bar.position, Vector2(w * frac, bar.size.y)), _hp_color(frac))
	if hp > max_hp:
		var over := clampf(float(hp - max_hp) / max_hp, 0.0, 1.0)
		draw_rect(Rect2(bar.position, Vector2(w * over, bar.size.y)), OVERHEAL)
	# "120 / 150"
	_text(font, "%d / %d" % [hp, max_hp], Vector2(center.x, bar.end.y + 17.0), 14, OVERHEAL if hp > max_hp else TEXT)


# --- Medic: critical teammates -------------------------------------------------------------

## A red cross with the health number above every hurt teammate (through walls).
## The teammate under the crosshair is skipped: their hover card already shows the same spot.
func _draw_critical_markers(skip: Node3D) -> void:
	var cam: Camera3D = player.camera
	var font := get_theme_default_font()
	var level := player.get_parent()
	if level == null or !level.has_method("_players"): return
	for mate in level._players():
		if !_is_mate(mate) or mate == skip: continue
		var frac: float = float(mate.health) / float(mate.max_health)
		if frac >= critical_fraction: continue
		var head: Vector3 = mate.global_position + Vector3.UP * 2.4
		if cam.global_position.distance_to(head) > marker_range: continue
		if cam.is_position_behind(head): continue   # only draw what's in front of us
		var p := cam.unproject_position(head)
		# Lower health = faster, stronger pulse.
		var urgency := 1.0 - frac / critical_fraction             # 0 at the threshold, 1 at 0 HP
		var pulse := 0.5 + 0.5 * sin(_t * lerpf(4.0, 10.0, urgency))
		var s := lerpf(9.0, 13.0, urgency) * (1.0 + 0.12 * pulse)  # half the cross arm length
		var col := HP_RED.lerp(Color(1, 0.1, 0.1), urgency)
		col.a = lerpf(0.75, 1.0, pulse)
		# Outline, then the cross (two bars).
		var t := s * 0.38   # half thickness of a bar
		draw_rect(Rect2(p.x - s - 2, p.y - t - 2, s * 2 + 4, t * 2 + 4), Color(OUTLINE, col.a))
		draw_rect(Rect2(p.x - t - 2, p.y - s - 2, t * 2 + 4, s * 2 + 4), Color(OUTLINE, col.a))
		draw_rect(Rect2(p.x - s, p.y - t, s * 2, t * 2), col)
		draw_rect(Rect2(p.x - t, p.y - s, t * 2, s * 2), col)
		# Health number just above the cross (below it would sit on the body).
		_text(font, str(mate.health), p + Vector2(0, -s - 7.0), 15, col)


# --- Helpers -------------------------------------------------------------------------------

## Green when healthy, yellow when hurt, red when low.
func _hp_color(frac: float) -> Color:
	if frac > 0.6: return HP_GREEN
	if frac > 0.3: return HP_YELLOW
	return HP_RED


## Draws text centred on `pos` (baseline) with a dark outline.
func _text(font: Font, s: String, pos: Vector2, font_size: int, color: Color) -> void:
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at := Vector2(pos.x - w * 0.5, pos.y)
	draw_string_outline(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 5, Color(OUTLINE, color.a))
	draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
