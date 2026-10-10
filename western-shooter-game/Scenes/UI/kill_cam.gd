extends Control
## Kill cam (every game mode). When your player dies:
##  - your view stays where you died, then turns and zooms in on whoever killed you,
##  - a card shows who it was, their class, the weapon, and how much health they had left.
## Back to normal when you respawn. Created by the HUD; call bind_player() with your player.
##
## Who creates it: hud.gd makes it with kill_cam.gd.new() in its _ready() (there is no .tscn),
## so ALL of its UI (the card, labels, health bar) is built from code in _build_card().
## Data it reads: the local player's died/respawned signals, plus the killer's player node
## (name, class, health) which is already synced to every client by the multiplayer code.
## Local-only: it adds a temporary camera to the level on THIS machine only; other players
## are not affected at all.

const CLASS_NAMES := ["Player", "Medic", "Sheriff", "Bomber", "Gunslinger"]   # level's class order
## Gold colour for the killer's name.
const GOLD := Color(0.98, 0.84, 0.55)
## Normal text colour.
const TEXT := Color(0.96, 0.92, 0.84)
## Red for the "KILLED BY" heading and low-health bar.
const RED := Color(1, 0.4, 0.32)
const TURN_DELAY := 0.35        # beat before the camera swings round

## The local player (set in bind_player).
var player: Node3D
## Our own extra Camera3D used while dead (created on first death, reused afterwards).
var _cam: Camera3D
## The player node that killed us, or null (fell, self-kill, unknown).
var _killer: Node3D
## True while the kill cam is running.
var _active := false
## Seconds since death (used for TURN_DELAY).
var _t := 0.0
## The player's normal field of view, so we never zoom OUT past it.
var _base_fov := 75.0

# Card widgets, created in _build_card() and filled in _fill_card().
var _card: PanelContainer
var _heading: Label
var _name: Label
var _detail: Label
var _hp_bar: ProgressBar
var _hp_label: Label


## Makes this Control cover the whole screen, builds the card and starts hidden.
func _ready() -> void:
	# Since we were made in code (not in the editor), set the layout here:
	# PRESET_FULL_RECT = anchors at all four screen edges, offsets 0 -> fills the parent.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_card()
	hide()


## Hooks up to a (new) local player. Called by hud.gd's bind_player().
func bind_player(p: Node3D) -> void:
	# If we were showing a kill cam for an old player node, turn it off first.
	_stop()
	player = p
	p.died.connect(_on_died)
	# respawned connects straight to _stop: coming back to life ends the kill cam.
	p.respawned.connect(_stop)


## The local player died. killer_id is the killer's multiplayer peer id (0 = unknown).
func _on_died(killer_id: int) -> void:
	if player == null or !is_instance_valid(player): return
	# Player nodes are children of the level and named after their peer id,
	# so we can find the killer by name.
	var level := player.get_parent()
	_killer = level.get_node_or_null(str(killer_id)) if killer_id != 0 else null
	# Killed yourself (e.g. your own dynamite)? Treat it as "no killer".
	if _killer == player: _killer = null
	_fill_card()

	# A camera of our own at the spot where we died, looking where we were looking.
	# (Reuse the old one if it still exists in this same level.)
	if _cam == null or !is_instance_valid(_cam) or _cam.get_parent() != level:
		_cam = Camera3D.new()
		_cam.name = "KillCam"
		level.add_child(_cam)
	_base_fov = player.camera.fov
	_cam.fov = _base_fov
	# Copy the player's camera exactly, so the switch is invisible to the player.
	_cam.global_transform = player.camera.global_transform
	# Only one camera per viewport can be "current"; making ours current switches the view to it.
	_cam.current = true
	_t = 0.0
	_active = true
	show()
	# Card animation: start invisible and slightly small, then fade in and spring to full size.
	_card.modulate.a = 0.0
	_card.scale = Vector2.ONE * 0.9
	var tw := create_tween().set_parallel()
	tw.tween_property(_card, "modulate:a", 1.0, 0.25).set_delay(0.2)
	tw.tween_property(_card, "scale", Vector2.ONE, 0.35).set_delay(0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Ends the kill cam: hides the card and gives the view back to the player's own camera.
func _stop() -> void:
	_active = false
	hide()
	if player and is_instance_valid(player) and player.is_inside_tree():
		player.camera.current = true


## While active: after a short pause, smoothly turn the kill cam toward the killer and zoom in.
func _process(delta: float) -> void:
	if !_active or _cam == null or !is_instance_valid(_cam): return
	_t += delta
	if _t < TURN_DELAY: return
	# Aim at the killer's chest/head (1.3 m above their feet).
	var target: Vector3
	if _killer and is_instance_valid(_killer) and _killer.is_inside_tree():
		target = _killer.global_position + Vector3.UP * 1.3
	else:
		target = player.global_position + Vector3.UP * 0.5   # nobody to look at: look down at where we fell
	var from := _cam.global_position
	# Too close to aim sensibly (looking_at would be unstable), so just hold still.
	if from.distance_to(target) < 0.5: return
	# looking_at() needs an "up" direction that is not parallel to the look direction.
	# If we're looking almost straight up/down, use FORWARD as "up" instead to avoid a broken result.
	var up := Vector3.UP if absf((target - from).normalized().y) < 0.98 else Vector3.FORWARD
	# The rotation we WANT: same position, but facing the target.
	var want := _cam.global_transform.looking_at(target, up)
	# Exponential smoothing: each frame move a fraction k of the remaining way.
	# Using 1 - exp(-speed * delta) (instead of a fixed number like 0.1) makes the
	# turn feel the same at 30 fps and 144 fps. It starts fast and eases in at the end.
	var k := 1.0 - exp(-5.0 * delta)
	# interpolate_with blends between two transforms (rotation is blended smoothly too).
	_cam.global_transform = _cam.global_transform.interpolate_with(want, k)
	# Zoom so the killer fills a decent part of the screen (freeze-cam style).
	# FOV maths: to fit something of half-height h at distance d, the camera needs an
	# angle of 2 * atan(h / d). With h = 3 m about 6 m of height around the killer stays
	# in view, so far-away killers get zoomed in a lot and close ones barely at all.
	# Clamped between 18 degrees (max zoom) and the normal FOV (never zoom out).
	var dist := from.distance_to(target)
	var want_fov := clampf(rad_to_deg(2.0 * atan(3.0 / maxf(dist, 0.1))), 18.0, _base_fov)
	# Same frame-rate independent smoothing, a bit slower, so the zoom glides in.
	_cam.fov = lerpf(_cam.fov, want_fov, 1.0 - exp(-2.5 * delta))


# --- Card ---------------------------------------------------------------------------------

## Writes the killer info (or the cause of death) into the card's labels.
func _fill_card() -> void:
	# death_weapon is set on the player when the killing hit arrives (empty if unknown).
	var weapon: String = player.get("death_weapon") if player.get("death_weapon") != null else ""
	if _killer:
		_heading.text = "KILLED BY"
		_name.text = str(_killer.player_name)
		# The level stores each player's class number as node metadata ("class_index").
		var ci: int = _killer.get_meta("class_index", -1)
		var cls: String = CLASS_NAMES[ci] if ci >= 0 and ci < CLASS_NAMES.size() else "?"
		_detail.text = cls + ("   |   " + weapon if weapon != "" else "")
		# Show how much health the killer had left (nice for "they were almost dead!" moments).
		var hp: int = _killer.health
		var mx: int = _killer.max_health
		# If they are overhealed, stretch the bar so it doesn't overflow.
		_hp_bar.max_value = maxi(mx, hp)
		_hp_bar.value = hp
		_hp_label.text = "%d / %d HP left" % [hp, mx]
		var frac := float(hp) / mx
		# Recolour the bar's fill StyleBox: blue = overheal, green > 60%, orange > 30%, else red.
		# (We own this StyleBoxFlat - it was made in _build_card - so changing it directly is safe.)
		var fill: StyleBoxFlat = _hp_bar.get_theme_stylebox("fill")
		fill.bg_color = Color(0.4, 0.85, 1.0) if hp > mx else (Color(0.35, 0.85, 0.35) if frac > 0.6 else (Color(1, 0.75, 0.25) if frac > 0.3 else RED))
		_hp_bar.show()
		_hp_label.show()
	else:
		# No killer to show: explain how you died instead.
		_heading.text = "YOU DIED"
		if player.get("died_from_fall"):
			_name.text = "Fell to your death"
		elif weapon != "":
			_name.text = "Your own " + weapon.to_lower()
		else:
			_name.text = "Unlucky"
		_detail.text = ""
		_hp_bar.hide()
		_hp_label.hide()


## Builds the card UI entirely from code:
## PanelContainer (with a StyleBoxFlat background) > VBoxContainer > heading, name, detail, HP bar, HP text.
func _build_card() -> void:
	_card = PanelContainer.new()
	# Anchor to the bottom-centre of the screen. The offsets then place the 380 px wide card
	# from -190 to +190 around the centre, between 250 and 120 px above the bottom edge.
	_card.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_card.custom_minimum_size = Vector2(380, 0)
	_card.offset_left = -190
	_card.offset_right = 190
	_card.offset_top = -250
	_card.offset_bottom = -120
	# If the content makes the card bigger, grow to both sides and upward (away from the screen edge).
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Scale around roughly the card's middle for the pop-in animation.
	_card.pivot_offset = Vector2(190, 60)
	# StyleBoxFlat = a simple drawn box: background colour, border, rounded corners and
	# inner padding (content_margin). Used here instead of an image.
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.09, 0.05, 0.03, 0.85)
	bg.border_color = Color(0.75, 0.45, 0.2, 0.9)
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(6)
	bg.content_margin_left = 18
	bg.content_margin_right = 18
	bg.content_margin_top = 10
	bg.content_margin_bottom = 12
	# A PanelContainer draws its "panel" stylebox behind its child.
	_card.add_theme_stylebox_override("panel", bg)
	add_child(_card)
	# VBoxContainer stacks its children top to bottom automatically.
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(box)
	_heading = _label(14, RED)
	_name = _label(30, GOLD)
	_detail = _label(16, TEXT)
	for l in [_heading, _name, _detail]: box.add_child(l)
	# The killer's health bar, also styled with StyleBoxFlats (background + fill).
	_hp_bar = ProgressBar.new()
	_hp_bar.show_percentage = false
	# Width 0 = let the VBox stretch it; height 12 px.
	_hp_bar.custom_minimum_size = Vector2(0, 12)
	_hp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hbg := StyleBoxFlat.new()
	hbg.bg_color = Color(0, 0, 0, 0.6)
	hbg.set_corner_radius_all(3)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.85, 0.35)
	fill.set_corner_radius_all(3)
	_hp_bar.add_theme_stylebox_override("background", hbg)
	_hp_bar.add_theme_stylebox_override("fill", fill)
	box.add_child(_hp_bar)
	_hp_label = _label(14, TEXT)
	box.add_child(_hp_label)


## Small factory for centred, outlined Labels so all card text looks the same.
func _label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0.08, 0.04, 0.02))
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
