extends Control
## Death Match HUD (built in code, added by Scripts/GameModes/deathmatch.gd on players' screens):
##  - top: match timer, your points / rank / how much you're worth
##  - top right: kill feed
##  - banners for events, "+150" popup when you score, death screen with respawn countdown
##  - big 3-2-1 countdown at the end of the warm-up, and an "ON FIRE" boost timer
##  - Tab: scoreboard (also shown automatically on the results screen)
##
## Who creates it: deathmatch.gd does HUD_SCRIPT.new(), sets `game_mode`, and adds it to the
## level's CanvasLayer just below the pause menu. A dedicated server (no window) never makes one.
## There is no .tscn - the whole layout is made from code in _build().
##
## Data it reads:
##  - game_mode.phase / time_left / stats / winner / min_players, read every frame in _process().
##    These are synced from the server to every client by deathmatch.gd's RPCs, so this HUD
##    only DISPLAYS them and never changes the score itself.
##  - local_player (set by deathmatch.gd) for death state, respawn timer and boost time.
##  - deathmatch.gd also calls the "push" functions: show_banner(), add_kill(), show_death(),
##    show_boost() and refresh() when something happens.
## Like all UI, it only runs on the local machine; every player has their own copy.

## The project's menu theme (fonts, HeadingLabel/TitleLabel styles), so the HUD matches the menus.
const THEME := preload("res://Scenes/UI/menu_theme.tres")
## Gold for important text (timer, your kills, your row on the scoreboard).
const GOLD := Color(0.98, 0.84, 0.55)
## Normal text colour.
const TEXT := Color(0.96, 0.92, 0.84)
## Red for deaths and the last 30 seconds.
const RED := Color(1, 0.4, 0.32)
## Dark brown outline drawn around all text so it reads on any background.
const OUTLINE := Color(0.08, 0.04, 0.02)
## How long a kill feed line stays before fading out.
const FEED_SECONDS := 6.0

## The deathmatch.gd node (set by it when it creates this HUD).
var game_mode: Node
## The local player's node (set by deathmatch.gd when our player spawns).
var local_player: Node

# --- Widgets (all created in _build) ---
## Big match timer at the top.
var _timer: Label
## Text under the timer: WAITING / WARM-UP / DEATH MATCH / MATCH OVER.
var _phase: Label
## Your standing: "350 pts | 2nd of 5 | you're worth 150".
var _me: Label
## "ON FIRE 2x DAMAGE 4.2s" text under the crosshair.
var _boost: Label
## Holds the boost label + bar so both can be hidden together.
var _boost_box: VBoxContainer
## Bar that drains while the boost lasts.
var _boost_bar: ProgressBar
## Running time used for the boost flicker animation.
var _boost_t := 0.0
## Orange "fire" colour for the boost.
const FIRE := Color(1, 0.55, 0.15)
## Kill feed list (top right); each line is a Label child.
var _feed: VBoxContainer
## Event banner (title + text) in the upper middle.
var _banner: VBoxContainer
var _banner_title: Label
var _banner_text: Label
## "+150" points popup under the crosshair.
var _popup: Label
var _count: Label        # big 3-2-1 in the middle before a match
## Last number shown by the countdown, so its pop animation plays only once per second.
var _last_count := -1
## Death screen layer (red tint + text).
var _death: Control
var _death_title: Label
var _death_timer: Label
## Scoreboard panel and its parts.
var _board: PanelContainer
var _board_title: Label
var _board_sub: Label
## Table of players: 7 columns (#, Player, Class, K, D, Streak, Points).
var _board_grid: GridContainer
# Kept so a new banner/popup can cancel the old animation instead of overlapping it.
var _banner_tween: Tween
var _popup_tween: Tween


## Sets up the theme, full-screen layout and the Tab key, then builds all widgets.
func _ready() -> void:
	# Setting a theme on this Control makes every child we add use it too.
	theme = THEME
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)   # fill the screen (offsets too, or size stays 0)
	# The HUD covers the screen but must not block mouse clicks (e.g. on the pause menu).
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Add a "scoreboard" input action (Tab) from code if the project doesn't define one,
	# so Input.is_action_pressed("scoreboard") works without editing Project Settings.
	if !InputMap.has_action("scoreboard"):
		InputMap.add_action("scoreboard")
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_TAB
		InputMap.action_add_event("scoreboard", ev)
	_build()
	refresh()


# --- Building the layout -------------------------------------------------------------------
# How positioning from code works: set_anchors_and_offsets_preset() pins a Control to a spot on
# the screen (top-centre, centre, top-right...). The offsets then say how far each edge is
# from that anchor in pixels, and grow_* says which way the Control grows if its content is bigger.

## Makes a centred, outlined Label. `variation` picks a theme style (e.g. &"HeadingLabel").
func _label(font_size: int, color := TEXT, outline := 8, variation := &"") -> Label:
	var l := Label.new()
	if variation != &"": l.theme_type_variation = variation
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", OUTLINE)
	l.add_theme_constant_override("outline_size", outline)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Creates every widget of the HUD and places it on screen. Called once from _ready().
func _build() -> void:
	# Top centre: timer + phase + your standing
	# A 600 px wide column anchored to the top-centre, 8 px down from the top edge.
	var top := VBoxContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top.offset_left = -300
	top.offset_right = 300
	top.offset_top = 8
	top.grow_horizontal = Control.GROW_DIRECTION_BOTH
	top.add_theme_constant_override("separation", 0)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	_timer = _label(40, GOLD, 10, &"HeadingLabel")
	_phase = _label(15, TEXT, 6)
	_me = _label(17, TEXT, 7)
	for l in [_timer, _phase, _me]: top.add_child(l)

	# Under the crosshair: power-up timer (label + draining bar) while you're boosted.
	# Anchored to the screen centre, then pushed 70-120 px below it.
	_boost_box = VBoxContainer.new()
	_boost_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_boost_box.offset_left = -170
	_boost_box.offset_right = 170
	_boost_box.offset_top = 70
	_boost_box.offset_bottom = 120
	_boost_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_boost_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_boost_box.add_theme_constant_override("separation", 4)
	add_child(_boost_box)
	_boost = _label(20, FIRE, 8, &"HeadingLabel")
	_boost_box.add_child(_boost)
	_boost_bar = ProgressBar.new()
	_boost_bar.show_percentage = false
	_boost_bar.custom_minimum_size = Vector2(300, 12)
	_boost_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_boost_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The bar's look comes from two StyleBoxFlats: "background" (dark, thin border) and "fill" (orange).
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.04, 0.02, 0.75)
	bg.set_corner_radius_all(3)
	bg.set_border_width_all(1)
	bg.border_color = Color(0, 0, 0, 0.6)
	var fill := StyleBoxFlat.new()
	fill.bg_color = FIRE
	fill.set_corner_radius_all(3)
	_boost_bar.add_theme_stylebox_override("background", bg)
	_boost_bar.add_theme_stylebox_override("fill", fill)
	_boost_box.add_child(_boost_bar)
	_boost_box.hide()

	# Top right: kill feed
	# 420 px wide column 20 px from the right edge; new lines are added at the bottom.
	_feed = VBoxContainer.new()
	_feed.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_feed.offset_left = -440
	_feed.offset_right = -20
	_feed.offset_top = 16
	_feed.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_feed.alignment = BoxContainer.ALIGNMENT_BEGIN
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_feed)

	# Event banner (upper middle)
	# Starts fully transparent (alpha 0); show_banner() fades it in and out.
	_banner = VBoxContainer.new()
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_banner.offset_left = -500
	_banner.offset_right = 500
	_banner.offset_top = 150
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.modulate.a = 0.0
	add_child(_banner)
	_banner_title = _label(52, GOLD, 12, &"TitleLabel")
	_banner_text = _label(20, TEXT, 8)
	_banner.add_child(_banner_title)
	_banner.add_child(_banner_text)

	# "+150" under the crosshair
	_popup = _label(34, GOLD, 10, &"HeadingLabel")
	_popup.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_popup.offset_left = -150
	_popup.offset_right = 150
	_popup.offset_top = 40
	_popup.offset_bottom = 90
	_popup.modulate.a = 0.0
	add_child(_popup)

	# Countdown numbers (last 5 seconds before a match)
	# 400 x 150 box above the centre; pivot at its middle so the pop animation scales from the centre.
	_count = _label(130, GOLD, 18, &"TitleLabel")
	_count.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_count.offset_left = -200
	_count.offset_right = 200
	_count.offset_top = -170
	_count.offset_bottom = -20
	_count.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_count.pivot_offset = Vector2(200, 75)
	_count.hide()
	add_child(_count)

	# Death screen
	# A full-screen Control holding a see-through dark red ColorRect and the death text.
	_death = Control.new()
	_death.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death.hide()
	add_child(_death)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.15, 0.0, 0.0, 0.35)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death.add_child(shade)
	var dbox := VBoxContainer.new()
	dbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dbox.offset_left = -400
	dbox.offset_right = 400
	dbox.offset_top = -230   # upper part of the screen: the kill cam shows your killer in the middle
	dbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
	dbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death.add_child(dbox)
	_death_title = _label(48, RED, 12, &"TitleLabel")
	_death_timer = _label(20, TEXT, 8)
	dbox.add_child(_death_title)
	dbox.add_child(_death_timer)

	# Scoreboard
	# Centred panel (its background comes from the theme's PanelContainer style).
	# grow BOTH ways keeps it centred as rows are added.
	_board = PanelContainer.new()
	_board.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_board.custom_minimum_size = Vector2(620, 0)   # height follows the number of players
	_board.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_board.grow_vertical = Control.GROW_DIRECTION_BOTH
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board.hide()
	add_child(_board)
	var bbox := VBoxContainer.new()
	bbox.add_theme_constant_override("separation", 10)
	_board.add_child(bbox)
	_board_title = _label(34, GOLD, 10, &"TitleLabel")
	_board_sub = _label(16, Color(0.85, 0.68, 0.42), 0)
	bbox.add_child(_board_title)
	bbox.add_child(_board_sub)
	# A GridContainer places children left-to-right and wraps every 7, which makes a table.
	_board_grid = GridContainer.new()
	_board_grid.columns = 7
	_board_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_board_grid.add_theme_constant_override("h_separation", 22)
	_board_grid.add_theme_constant_override("v_separation", 6)
	bbox.add_child(_board_grid)


# --- Updates from the game mode ------------------------------------------------------------

## Called by deathmatch.gd whenever new stats arrive from the server: redraws the scoreboard.
func refresh() -> void:
	if game_mode == null: return
	_rebuild_scoreboard()


## Shows a big announcement (e.g. "GET READY", "MATCH OVER", random events) for about 3.5 s.
func show_banner(title: String, text: String) -> void:
	_banner_title.text = title
	_banner_text.text = text
	if _banner_tween: _banner_tween.kill()
	# Start 30% bigger and shrink into place while fading in ("slam" effect).
	_banner.scale = Vector2.ONE * 1.3
	_banner.pivot_offset = _banner.size * 0.5
	_banner_tween = create_tween()
	# set_parallel(): the fade-in and the scale run together...
	_banner_tween.set_parallel()
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.2)
	_banner_tween.tween_property(_banner, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# ...chain() then waits for them to finish before the next step: stay 3.2 s, then fade out.
	_banner_tween.chain().tween_property(_banner, "modulate:a", 0.0, 0.6).set_delay(3.2)


## Adds a line to the kill feed. Called (through an RPC in deathmatch.gd) on every player.
## Your own kills are gold (and show the points popup); your deaths are red.
func add_kill(killer_name: String, victim_name: String, points: int, killer_id: int, victim_id: int) -> void:
	# Our own peer id, to know if we were the killer or the victim.
	var my_id := multiplayer.get_unique_id()
	var line := _label(17, TEXT, 7)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if killer_name == "":
		line.text = "%s died" % victim_name
	else:
		line.text = "%s  shot  %s   +%d" % [killer_name, victim_name, points]
	if killer_id == my_id:
		line.add_theme_color_override("font_color", GOLD)
		_show_points(points, victim_name)
	elif victim_id == my_id:
		line.add_theme_color_override("font_color", RED)
	_feed.add_child(line)
	# Keep at most 6 lines: remove the oldest (the first child).
	if _feed.get_child_count() > 6: _feed.get_child(0).queue_free()
	# The tween is created ON the line (line.create_tween), so if the line is freed early
	# the tween dies with it. Steps: wait, fade out, then delete the line.
	var t := line.create_tween()
	t.tween_interval(FEED_SECONDS)
	t.tween_property(line, "modulate:a", 0.0, 0.6)
	t.tween_callback(line.queue_free)


## Sets the death screen title. fell = you were knocked off / fell instead of being shot.
## (The death screen itself is shown/hidden in _process based on local_player.is_dead.)
func show_death(killer_name: String, fell := false) -> void:
	if fell:
		_death_title.text = "KNOCKED OFF BY %s" % killer_name.to_upper() if killer_name != "" else "YOU FELL TO YOUR DEATH"
	else:
		_death_title.text = "SHOT BY %s" % killer_name.to_upper() if killer_name != "" else "YOU DIED"


## Connected to the local player's boost_started signal. Only shows a banner; the timer
## under the crosshair is driven by local_player.get_boost_time_left() in _process.
func show_boost(_seconds: float) -> void:
	show_banner("UNDERDOG BOOST", "Double damage and +30% speed!")


## The "+150" popup when you get a kill. Normal kills are worth 100, so more means you ended a
## streak and less means the victim was on a losing streak.
func _show_points(points: int, victim_name: String) -> void:
	_popup.text = "+%d" % points
	if points > 100: _popup.text += "   streak ended!"
	elif points < 100: _popup.text += "   (%s was on a losing streak)" % victim_name
	_popup.pivot_offset = _popup.size * 0.5
	_popup.scale = Vector2.ONE * 1.6
	if _popup_tween: _popup_tween.kill()
	# Same pattern as the banner: quick fade-in + springy shrink together, then fade out after 1.2 s.
	_popup_tween = create_tween()
	_popup_tween.set_parallel()
	_popup_tween.tween_property(_popup, "modulate:a", 1.0, 0.08)
	_popup_tween.tween_property(_popup, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_popup_tween.chain().tween_property(_popup, "modulate:a", 0.0, 0.5).set_delay(1.2)


# --- Every frame ---------------------------------------------------------------------------------

## Reads the game mode's state every frame and updates the timer, phase text, your standing,
## boost timer, countdown, death screen and scoreboard.
func _process(_delta: float) -> void:
	if game_mode == null: return
	var phase: String = game_mode.phase
	# Round UP so the timer shows "0:01" until the very end (not "0:00" one second early).
	var t := int(ceil(game_mode.time_left))
	# The match phases (decided by the server in deathmatch.gd):
	#   waiting   -> not enough players yet
	#   countdown -> warm-up before the match (kills don't count)
	#   playing   -> the real match
	#   results   -> winner + scoreboard until the next match
	match phase:
		"waiting":
			_timer.text = "--:--"
			_phase.text = "WAITING FOR PLAYERS   %d / %d" % [game_mode.stats.size(), game_mode.min_players]
		"countdown":
			_timer.text = "0:%02d" % t
			_timer.add_theme_color_override("font_color", GOLD)
			_phase.text = "WARM-UP   |   MATCH STARTS IN %d" % t
		"playing":
			# m:ss, timer turns red in the last 30 seconds.
			_timer.text = "%d:%02d" % [floori(t / 60.0), t % 60]
			_timer.add_theme_color_override("font_color", RED if t <= 30 else GOLD)
			_phase.text = "DEATH MATCH"
		"results":
			_timer.text = "%d:%02d" % [0, 0]
			_phase.text = "MATCH OVER"

	# Your line under the timer. stats is keyed by peer id; worth() is deathmatch.gd's points formula.
	var me_id := multiplayer.get_unique_id()
	if game_mode.stats.has(me_id):
		var s: Dictionary = game_mode.stats[me_id]
		_me.text = "%d pts   |   %s of %d   |   you're worth %d" % [s.points, _ordinal(_rank_of(me_id)), game_mode.stats.size(), game_mode.worth(s)]

	# Boost (underdog power-up) timer: visible only while time is left.
	var boost_left: float = local_player.get_boost_time_left() if local_player and is_instance_valid(local_player) else 0.0
	var was_visible := _boost_box.visible
	_boost_box.visible = boost_left > 0.0
	if _boost_box.visible:
		_boost_t += _delta
		_boost.text = "ON FIRE   2x DAMAGE   %.1fs" % boost_left
		# When the boost starts (or gets extended) the bar's max becomes the time left,
		# so the bar starts full and drains to empty.
		if !was_visible or boost_left > _boost_bar.max_value:
			_boost_bar.max_value = boost_left   # full bar at the start of the boost
		_boost_bar.value = boost_left
		# Flicker like a flame; blink faster in the last 3 seconds.
		# k swings 0..1 with a sine wave; it blends the colour orange <-> yellow, and in the
		# last 3 seconds also blinks the opacity as a "running out" warning.
		var speed := 14.0 if boost_left < 3.0 else 6.0
		var k := 0.5 + 0.5 * sin(_boost_t * speed)
		_boost.add_theme_color_override("font_color", FIRE.lerp(Color(1, 0.9, 0.5), k))
		_boost_box.modulate.a = 1.0 if boost_left >= 3.0 else 0.55 + 0.45 * k

	_update_countdown(phase, t)

	# Death screen while our player is dead (not on the results screen, the scoreboard is there).
	var dead: bool = local_player != null and is_instance_valid(local_player) and local_player.is_dead
	_death.visible = dead and phase != "results"
	if dead:
		_death_timer.text = "Respawning in %.1f" % local_player.get_respawn_time_left()

	# Scoreboard: always on the results screen, otherwise while Tab is held.
	# Rebuilt when it opens so it's up to date (refresh() also rebuilds it when stats change).
	var show_board := phase == "results" or Input.is_action_pressed("scoreboard")
	if show_board and !_board.visible: _rebuild_scoreboard()
	_board.visible = show_board
	if phase == "results":
		_board_title.text = "%s WINS!" % game_mode.winner.to_upper() if game_mode.winner != "" else "MATCH OVER"
		_board_sub.text = "Next match in %d" % t
	elif _board.visible:
		_board_title.text = "SCOREBOARD"
		_board_sub.text = "Death Match   |   %s left" % _timer.text


## Big pulsing number for the last 5 seconds of the warm-up.
## The pop animation starts only when the number changes, not every frame.
func _update_countdown(phase: String, t: int) -> void:
	var show_it := phase == "countdown" and t <= 5 and t > 0
	_count.visible = show_it
	if !show_it:
		_last_count = -1
		return
	if t != _last_count:
		_last_count = t
		_count.text = str(t)
		# Appear big and solid, shrink into place, and fade to 25% before the next number.
		_count.scale = Vector2.ONE * 1.6
		_count.modulate.a = 1.0
		var tw := create_tween().set_parallel()
		tw.tween_property(_count, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(_count, "modulate:a", 0.25, 0.9).set_delay(0.1)


## Clears and refills the scoreboard table: a header row, then one row per player sorted by points.
func _rebuild_scoreboard() -> void:
	for c in _board_grid.get_children(): c.queue_free()
	# Header row (7 labels = one row, because the grid has 7 columns).
	for h in ["#", "Player", "Class", "K", "D", "Streak", "Points"]:
		var l := _label(15, GOLD, 0)
		l.text = h
		_board_grid.add_child(l)
	# Sort peer ids by points, highest first.
	var ids: Array = game_mode.stats.keys()
	ids.sort_custom(func(a, b): return game_mode.stats[a].points > game_mode.stats[b].points)
	var me_id := multiplayer.get_unique_id()
	for i in ids.size():
		var s: Dictionary = game_mode.stats[ids[i]]
		# Your own row is gold.
		var color := GOLD if ids[i] == me_id else TEXT
		# Streak column: kill streak normally, or "-3" style when on a losing streak (3+ deaths in a row).
		var streak_text := str(s.streak) if s.death_streak < 3 else "-%d" % s.death_streak
		# s["class"] uses brackets because `class` is a GDScript keyword, so s.class wouldn't work.
		for v in [str(i + 1), s.name, s["class"], str(s.kills), str(s.deaths), streak_text, str(s.points)]:
			var l := _label(18, color, 0)
			l.text = v
			_board_grid.add_child(l)


## Your place in the match: 1 + the number of players with more points (ties share a place).
func _rank_of(id: int) -> int:
	var mine: int = game_mode.stats[id].points
	var rank := 1
	for s in game_mode.stats.values():
		if s.points > mine: rank += 1
	return rank


## 1 -> "1st", 2 -> "2nd", 3 -> "3rd", 11/12/13 -> "11th"/"12th"/"13th", others -> "th".
func _ordinal(n: int) -> String:
	if n % 100 in [11, 12, 13]: return "%dth" % n
	match n % 10:
		1: return "%dst" % n
		2: return "%dnd" % n
		3: return "%drd" % n
	return "%dth" % n
