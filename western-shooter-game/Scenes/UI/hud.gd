extends Control
## In-game HUD (heads-up display) for the LOCAL player.
##
## Where it lives: Scenes/UI/hud.tscn, placed under the level's CanvasLayer
## (multiplayer_test_scene.gd grabs it as $CanvasLayer/HUD). A CanvasLayer draws on top of the
## 3D world, so everything here is plain 2D Control nodes.
##
## How it gets data: the level calls bind_player(player) once the local player exists.
## From then on the HUD just listens to the player's signals (health_changed, damage_taken,
## damage_dealt, respawned) and the WeaponManager's weapon_status_changed signal.
## The HUD never changes game state itself - it only shows things.
##
## UI only runs on this machine: each player has their own HUD showing their own player.
## The dedicated server has no local player, so its HUD is simply hidden.
##
## What you see:
## - Bottom-left: health number + bar. A pale "chip" bar shows how much you just lost.
## - Bottom-right: ammo (magazine / reserve). Hidden for melee weapons.
## - Getting hit: red screen-edge flash, camera shake, arc pointing at the attacker.
##   Low health keeps a slow red pulse.
## - Hitting someone: crosshair hitmarker + floating damage numbers (green "+X" for heals).
## - Overheal (health above max): the health number turns light blue.
## - It also creates the kill cam (kill_cam.gd) from code as a child.

# --- Colours -------------------------------------------------------------------
# Kept as constants in one place so the whole HUD uses a consistent palette.

## Normal text colour (warm off-white, fits the western look).
const COLOR_TEXT := Color(0.96, 0.92, 0.84)
## Floating number colour for a normal hit.
const COLOR_DAMAGE := Color(1.0, 0.95, 0.85)
## Floating number colour for a big hit (see big_hit_threshold).
const COLOR_BIG_DAMAGE := Color(1.0, 0.72, 0.15)
## Green used for healing numbers and the heal flash.
const COLOR_HEAL := Color(0.35, 1.0, 0.45)
## Red used when you lose health or run out of ammo.
const COLOR_DANGER := Color(1.0, 0.25, 0.2)
## Colour for headshot hitmarkers and numbers.
const COLOR_HEADSHOT := Color(1.0, 0.32, 0.22)
## Light blue tint for the health number while overhealed.
const COLOR_OVERHEAL := Color(0.55, 0.85, 1.0)

## Below this fraction of max health (0.3 = 30%) the screen pulses red and the bar blinks.
@export var low_health_fraction := 0.3
@export var big_hit_threshold := 50        ## Hits this big get the extra-flashy treatment.
@export var shake_strength := 1.0          ## Multiplier for camera shake when hit (0 = off).

# --- Nodes from hud.tscn ----------------------------------------------------------
# "%Name" means a node marked "Access as Unique Name" in the scene, so the path
# still works even if the node gets moved around inside the scene tree.

## Big number showing current health.
@onready var health_number: Label = %HealthNumber
## Small "/ 200" label next to it.
@onready var health_max: Label = %HealthMax
## The real health bar (jumps straight to the new value).
@onready var health_bar: ProgressBar = %HealthBar
## Pale bar behind the health bar that drains slowly, showing the chunk you just lost.
@onready var chip_bar: ProgressBar = %ChipBar
## Container of the health widgets (shaken when you get hurt).
@onready var health_panel: Control = %HealthPanel
## Container of the ammo widgets (hidden for melee weapons).
@onready var ammo_panel: Control = %AmmoPanel
## Bullets left in the magazine.
@onready var ammo_count: Label = %AmmoCount
## Spare bullets ("/ 24").
@onready var ammo_reserve: Label = %AmmoReserve
## Small text with mode / class / team, set by set_class_text().
@onready var class_label: Label = %ClassLabel
## Crosshair hitmarker (hit_marker.gd).
@onready var hit_marker = %HitMarker
## Red arcs showing where damage came from (damage_direction.gd).
@onready var damage_direction = %DamageDirection
## Empty full-screen Control that the floating damage-number Labels are added to.
@onready var damage_numbers: Control = %DamageNumbers
## Full-screen rect with a vignette shader; its "intensity" uniform makes the red edges.
@onready var hurt_vignette: ColorRect = %HurtVignette
## Same idea, green, for healing.
@onready var heal_vignette: ColorRect = %HealVignette

## The local player this HUD is showing (set in bind_player).
var player: Node3D
var kill_cam: Control   ## Scenes/UI/kill_cam.gd - shows who killed you.
## Health we are currently displaying (used to tell hits from heals).
var _health := 0
## The player's max health (for bar range, overheal and low-health checks).
var _max_health := 1
## Strength (0..1) of the red edge flash. Jumps up on a hit and fades in _process.
var _hurt_flash := 0.0
## Strength (0..1) of the green edge flash.
var _heal_flash := 0.0
## Current camera shake strength (0..1), fades out over time.
var _shake := 0.0
## Running clock, used for sine-wave pulses.
var _time := 0.0
# Tweens are stored so a new animation can kill the old one instead of fighting it.
var _chip_tween: Tween
var _number_tween: Tween
var _ammo_tween: Tween
## Ammo on the last update (-1 = unknown). If it went down, a shot was fired.
var _last_ammo := -1
var _floating: Array = []   # [{label, pos, age, drift}]
var _shake_tweens := {}     # control -> [tween, home position]


## Runs once when the HUD enters the scene tree.
func _ready() -> void:
	# The HUD covers the whole screen; IGNORE lets mouse clicks pass through it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Materials are shared resources by default. Duplicating gives this HUD its own copy,
	# so changing "intensity" here can't affect any other node using the same material.
	hurt_vignette.material = hurt_vignette.material.duplicate()
	heal_vignette.material = heal_vignette.material.duplicate()
	ammo_panel.hide()
	# The kill cam is pure code (no .tscn), so we create it with .new() and add it as a child.
	kill_cam = preload("res://Scenes/UI/kill_cam.gd").new()
	kill_cam.name = "KillCam"
	add_child(kill_cam)


## Connects the HUD to the local player. Called by the level (multiplayer_test_scene.gd)
## every time the local player node is created (join, respawn as new class...).
func bind_player(p: Node3D) -> void:
	player = p
	kill_cam.bind_player(p)
	# Signal-driven UI: instead of checking the player every frame, we get told when things change.
	p.health_changed.connect(_on_health_changed)
	p.damage_taken.connect(_on_damage_taken)
	p.damage_dealt.connect(_on_damage_dealt)
	p.respawned.connect(_on_respawned)
	# The damage arcs need the camera to know which way we are looking.
	damage_direction.camera = p.camera

	_max_health = p.max_health
	health_bar.max_value = _max_health
	chip_bar.max_value = _max_health
	health_max.text = "/ %d" % _max_health
	_set_health_instant(p.health)

	# Only some classes have a WeaponManager (melee/ammo weapons). If there is one,
	# listen for ammo changes and show the current weapon right away.
	var wm = p.get_node_or_null("WeaponManager")
	if wm:
		wm.weapon_status_changed.connect(_on_weapon_status_changed)
		var w = wm.get_current_weapon()
		if w: _on_weapon_status_changed(w)


## Sets the small info text (e.g. "Death Match  |  Sheriff  |  Red").
func set_class_text(text: String) -> void:
	class_label.text = text


# --- Health -------------------------------------------------------------------

## Shows a health value with no animation (used when binding and on respawn).
func _set_health_instant(value: int) -> void:
	_health = value
	health_bar.value = value
	chip_bar.value = value
	health_number.text = str(value)
	_apply_overheal_tint(value)


## Player's health changed. Works out whether it was a hit or a heal and animates accordingly.
func _on_health_changed(value: int) -> void:
	var old := _health
	_health = value
	health_number.text = str(value)
	health_bar.value = value
	_apply_overheal_tint(value)

	if value < old and old > _max_health and value >= _max_health:
		chip_bar.value = value   # overheal draining away: quiet, not a hit
	elif value < old:
		# Took damage.
		# The chip bar waits a moment, then drains down to the new value.
		# This "delayed bar" trick (used in fighting games) lets you see how big the hit was.
		if _chip_tween: _chip_tween.kill()
		_chip_tween = create_tween()
		# Tween steps run one after another: first wait 0.35 s, then animate "value" over 0.45 s.
		_chip_tween.tween_interval(0.35)
		_chip_tween.tween_property(chip_bar, "value", float(value), 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_pop_label(health_number, COLOR_DANGER, 1.35)
		_shake_control(health_panel, 9.0)
	elif value > old:
		# Healed. The chip bar has nothing to show, so snap it.
		if _chip_tween: _chip_tween.kill()
		chip_bar.value = value
		if value - old >= 5:
			_heal_flash = maxf(_heal_flash, 0.55)
			_pop_label(health_number, COLOR_HEAL, 1.25)
		else:   # heal-over-time ticks: a gentle steady glow instead of a pop every point
			_heal_flash = maxf(_heal_flash, 0.3)


## Above max health (overheal): the number turns light blue.
## self_modulate tints only this node (not its children), and doesn't clash with
## the "modulate" flash that _pop_label animates.
func _apply_overheal_tint(value: int) -> void:
	health_number.self_modulate = COLOR_OVERHEAL if value > _max_health else Color.WHITE


## Player came back to life: clear effects and show full health without any heal animation.
func _on_respawned() -> void:
	# Reset straight to full - not a heal.
	if _chip_tween: _chip_tween.kill()
	_hurt_flash = 0.0
	_set_health_instant(player.health)


## Player got hit. Bigger hits (as a fraction of max health) give a stronger flash and shake.
## attacker_position is a Vector3, or null when the source is unknown (then no arc is drawn).
func _on_damage_taken(amount: int, attacker_position: Variant) -> void:
	var frac := clampf(float(amount) / _max_health, 0.0, 1.0)
	# Add to the current values (so rapid hits stack) but never go above 1.
	_hurt_flash = clampf(_hurt_flash + 0.45 + frac * 1.5, 0.0, 1.0)
	_shake = clampf(_shake + 0.35 + frac * 2.5, 0.0, 1.0) * shake_strength
	if attacker_position is Vector3:
		damage_direction.add_hit(attacker_position)


# --- Ammo ---------------------------------------------------------------------

## Called whenever the current weapon changes or fires/reloads. Updates the ammo text and colour.
func _on_weapon_status_changed(weapon) -> void:
	# Melee weapons have no ammo, so hide the panel completely.
	if !weapon.uses_ammo():
		ammo_panel.hide()
		_last_ammo = -1
		return
	ammo_panel.show()
	ammo_count.text = str(weapon.ammo)
	ammo_reserve.text = "/ %d" % weapon.reserve
	# "Low" = a quarter of the magazine or less (always at least 1 bullet).
	# Colour: red when empty, orange when low, normal otherwise.
	var low: bool = weapon.ammo <= maxi(1, int(weapon.mag_size * 0.25))
	ammo_count.modulate = COLOR_DANGER if weapon.ammo == 0 else (Color(1, 0.6, 0.4) if low else COLOR_TEXT)
	if _last_ammo >= 0 and weapon.ammo < _last_ammo:
		# Shot fired: little kick on the number.
		if _ammo_tween: _ammo_tween.kill()
		# pivot_offset is the point a Control scales/rotates around. Right-middle here, so the
		# number grows to the left (it is right-aligned on screen).
		ammo_count.pivot_offset = ammo_count.size * Vector2(1.0, 0.5)
		ammo_count.scale = Vector2.ONE * 1.25
		_ammo_tween = create_tween()
		# TRANS_BACK + EASE_OUT overshoots slightly before settling: a springy "kick".
		_ammo_tween.tween_property(ammo_count, "scale", Vector2.ONE, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_last_ammo = weapon.ammo


# --- Hits you deal --------------------------------------------------------------

## Your attack landed on someone (or healed a teammate). Flashes the hitmarker and
## spawns a floating number at the 3D point that was hit.
func _on_damage_dealt(amount: int, world_position: Vector3, is_heal: bool, is_headshot := false) -> void:
	if is_headshot:
		hit_marker.flash(COLOR_HEADSHOT, true)
		_spawn_number("%d" % amount, world_position, COLOR_HEADSHOT, true)
		# A second label a bit higher up (0.45 m) that says HEADSHOT.
		_spawn_number("HEADSHOT", world_position + Vector3.UP * 0.45, COLOR_HEADSHOT, false)
		return
	var big := !is_heal and amount >= big_hit_threshold
	var color := COLOR_HEAL if is_heal else (COLOR_BIG_DAMAGE if big else COLOR_DAMAGE)
	hit_marker.flash(color, big)
	_spawn_number(("+%d" if is_heal else "%d") % amount, world_position, color, big)


## Creates one floating damage-number Label from code. It remembers a 3D world position;
## _update_numbers() moves it on screen every frame so it stays "attached" to that point.
func _spawn_number(text: String, world_position: Vector3, color: Color, big: bool) -> void:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Theme overrides change the look of just this one Label (font size, colour, dark outline
	# so it's readable on any background) without editing the shared theme.
	l.add_theme_font_size_override("font_size", 46 if big else 34)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0.08, 0.04, 0.02))
	l.add_theme_constant_override("outline_size", 10 if big else 8)
	damage_numbers.add_child(l)
	# Shrink the Label to fit its text, then scale from its centre.
	l.reset_size()
	l.pivot_offset = l.size * 0.5
	# drift = a random sideways speed so several numbers don't sit on top of each other.
	_floating.append({
		label = l,
		pos = world_position,
		age = 0.0,
		drift = Vector2(randf_range(-40.0, 40.0), 0.0),
		big = big,
	})


# --- Per-frame effects ------------------------------------------------------------

## Every frame: fade the screen flashes, pulse at low health, update shake and damage numbers.
func _process(delta: float) -> void:
	_time += delta

	# Screen-edge flashes. Low health adds a slow pulse underneath.
	# move_toward fades the value to 0 at a fixed speed (per second, thanks to delta).
	_hurt_flash = move_toward(_hurt_flash, 0.0, delta * 1.6)
	_heal_flash = move_toward(_heal_flash, 0.0, delta * 1.4)
	var low_pulse := 0.0
	var is_low := player != null and _health <= _max_health * low_health_fraction
	if is_low:
		# sin() wobbles between -1 and 1, so this pulses between 0.16 and 0.40.
		low_pulse = 0.28 + 0.12 * sin(_time * 5.0)
	# Send the strength to the vignette shaders. The red one shows whichever is stronger:
	# a fresh hit flash or the low-health pulse.
	hurt_vignette.material.set_shader_parameter("intensity", maxf(_hurt_flash, low_pulse))
	heal_vignette.material.set_shader_parameter("intensity", _heal_flash)
	# At low health the bar blinks between pinkish and white.
	health_bar.modulate = Color(1, 0.75, 0.75).lerp(Color.WHITE, 0.5 + 0.5 * sin(_time * 8.0)) if is_low else Color.WHITE

	_update_shake(delta)
	_update_numbers(delta)


## Extra camera shake from something nearby (explosions). 0..1.
## Called by explosion.gd, stronger the closer you are.
func add_shake(amount: float) -> void:
	_shake = clampf(_shake + amount, 0.0, 1.0) * shake_strength


## Shakes the player's camera. Uses Camera3D h_offset/v_offset, which shift the picture
## without moving or rotating the camera node, so aiming and gameplay are not affected.
func _update_shake(delta: float) -> void:
	if player == null or !is_instance_valid(player) or !player.is_inside_tree(): return   # e.g. mid class switch
	var cam: Camera3D = player.camera
	if _shake > 0.0:
		_shake = move_toward(_shake, 0.0, delta * 3.0)
		# Squaring makes small shakes very subtle and big ones strong, and fades out smoothly.
		var s := _shake * _shake * 0.06
		cam.h_offset = randf_range(-s, s)
		cam.v_offset = randf_range(-s, s)
	elif cam.h_offset != 0.0 or cam.v_offset != 0.0:
		# Shake finished: put the camera back exactly centred.
		cam.h_offset = 0.0
		cam.v_offset = 0.0


## Moves, scales and fades all floating damage numbers, and removes old ones.
func _update_numbers(delta: float) -> void:
	if _floating.is_empty(): return
	var cam: Camera3D = player.camera if player else get_viewport().get_camera_3d()
	var lifetime := 0.9
	for f in _floating:
		f.age += delta
		var l: Label = f.label
		# The number rises in the 3D world (0.9 m per second) above where the hit landed.
		var world: Vector3 = f.pos + Vector3.UP * (0.35 + f.age * 0.9)
		# A point behind the camera would still "project" onto the screen (mirrored), so hide it.
		if cam == null or cam.is_position_behind(world):
			l.visible = false
			continue
		l.visible = true
		# unproject_position turns a 3D world point into 2D screen pixels. Then add the sideways drift.
		var screen: Vector2 = cam.unproject_position(world) + f.drift * f.age
		# Centre the Label on that pixel (position is the top-left corner).
		l.position = screen - l.size * 0.5
		# Pop in big, settle, then fade out.
		# Extra scale shrinks to 0 during the first 0.12 s; alpha fades during the last 0.35 s.
		var pop: float = 1.0 + (0.9 if f.big else 0.6) * maxf(0.0, 1.0 - f.age / 0.12)
		l.scale = Vector2.ONE * pop
		l.modulate.a = clampf((lifetime - f.age) / 0.35, 0.0, 1.0)
	# Free the expired Labels, then keep only the ones still alive.
	for f in _floating.filter(func(f): return f.age >= lifetime):
		f.label.queue_free()
	_floating = _floating.filter(func(f): return f.age < lifetime)


# --- Little animation helpers ---------------------------------------------------------

## Makes a Label briefly grow and flash a colour, then spring back to normal.
func _pop_label(l: Label, flash_color: Color, amount: float) -> void:
	if _number_tween: _number_tween.kill()
	# Scale from the left-middle so the number grows to the right.
	l.pivot_offset = l.size * Vector2(0.0, 0.5)
	l.scale = Vector2.ONE * amount
	l.modulate = flash_color
	# set_parallel(): both tweens below run at the same time instead of one after another.
	_number_tween = create_tween().set_parallel()
	_number_tween.tween_property(l, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_number_tween.tween_property(l, "modulate", Color.WHITE, 0.4)


## Jiggles a Control around its position a few times (used on the health panel when hit).
func _shake_control(c: Control, amount: float) -> void:
	# Always shake around the control's original spot, even if a shake is already running.
	# Otherwise a new shake could start from an offset position and the panel would drift away.
	var base: Vector2 = _shake_tweens[c][1] if _shake_tweens.has(c) else c.position
	if _shake_tweens.has(c): _shake_tweens[c][0].kill()
	var t := create_tween()
	_shake_tweens[c] = [t, base]
	# 4 quick random jumps, each a bit smaller (1.0, 0.78, 0.56, 0.34), then back home.
	for i in 4:
		t.tween_property(c, "position", base + Vector2(randf_range(-amount, amount), randf_range(-amount, amount)) * (1.0 - i * 0.22), 0.035)
	t.tween_property(c, "position", base, 0.05)
