extends Control
## Main menu: PLAY on a game mode (Quick Play finds a server and drops you in), browse all
## running servers, or create a local game / direct connect for testing.
## Mode cards and class buttons are generated from the MODES / CLASSES lists below,
## so adding a mode or class is just adding an entry.
##
## Where it lives: Scenes/UI/main_menu.tscn (the first scene the game opens).
## The server browser panel (server_browser.gd) and the Quick Play overlay are nodes inside it.
## It owns a ServerBrowserService node (created in _ready) which does the networking for
## both Quick Play and the browser.
##
## How a game starts: every path (Quick Play, browser, Create, Connect) ends in _start_level(),
## which builds a `start_config` Dictionary (host or join, mode, class, team, address...),
## hands it to the level scene and swaps to it. The level then hosts or connects.
## Menu UI only runs on this machine.

## The level scene that runs every game mode.
const LEVEL_SCENE := "res://Levels/multiplayer_test_scene.tscn"
## Network settings (default port, master server URL...).
const NetConfig = preload("res://Scripts/Network/net_config.gd")
## Script of the node that finds servers (we create it with .new()).
const BrowserService = preload("res://Scripts/Network/server_browser_service.gd")
## When Quick Play finds nothing, wait this many seconds before asking again.
const QUICK_PLAY_RETRY_SECONDS := 3.0

## Message to show when we come back here (e.g. "the host left"). Set by the level.
## It's `static` so it belongs to the script, not to one menu instance: the level can set
## it before the menu even exists, and the next menu reads it in _ready().
static var notice := ""

# From the design notes (Obsidian: GameModes/*.md).
# One entry per mode card. `id` is what the level and the network code use; the rest is display text.
# sub_modes (if any) become a drop-down on the card.
const MODES := [
	{
		id = "team_vs_team",
		name = "Team vs Team",
		stats = "6 v 6   |   up to 30 min",
		desc = "Survivor gangs fight over what's left of the town. Hold the point for 2.5 minutes, or bring three flags home.",
		sub_modes = ["Capture the Point", "Capture the Flag"],
	},
	{
		id = "deathmatch",
		name = "Death Match",
		stats = "Up to 8   |   5 min   |   Free-for-all",
		desc = "Madness takes over. Kill streaks make you worth more points, and every 90 seconds an event shakes things up.",
		sub_modes = [],
	},
	{
		id = "wave_survival",
		name = "Wave Survival",
		stats = "Co-op   |   up to 4   |   Roguelike",
		desc = "The infected rise. Survive wave after wave, earn money and buy upgrades between rounds.",
		sub_modes = [],
	},
]

# `index` = position in the level's CLASS_SCENES list (-1 = not made yet).
# The other fields are only shown in the class info text.
const CLASSES := [
	{name = "Medic", index = 1, role = "Support", hp = 150, speed = "Medium", kit = "Remington 1889  /  Syringe  /  Bone saw"},
	{name = "Sheriff", index = 2, role = "Defense / Offense", hp = 200, speed = "Slow", kit = "Winchester 1873  /  Winchester 1897  /  Bat"},
	{name = "Gunslinger", index = 4, role = "Offense", hp = 125, speed = "Fast", kit = "Dual revolvers  /  Coach gun  /  Bowie knife"},
	{name = "Bomber", index = 3, role = "Defense", hp = 125, speed = "Medium", kit = "Dynamite  /  Revolver rifle  /  Pickaxe"},
]

## Row that the mode cards are added to (filled by _build_mode_cards).
@onready var mode_cards: HBoxContainer = %ModeCards
## Row for the class buttons.
@onready var class_buttons: HBoxContainer = %ClassButtons
## Text under the class buttons (role, HP, speed, weapons).
@onready var class_info: Label = %ClassInfo
## Row for the Auto / Red / Blue team buttons.
@onready var team_buttons: HBoxContainer = %TeamButtons
## Hint under the team buttons (changes with the selected mode).
@onready var team_note: Label = %TeamNote
## Text box for "Direct connect" (address or address:port).
@onready var address_edit: LineEdit = %AddressEdit
## Toggle: try to open the router port with UPnP when hosting.
@onready var upnp_toggle: Button = %UpnpToggle
## Status / error line at the bottom.
@onready var status_label: Label = %StatusLabel
## The server browser panel (server_browser.gd).
@onready var browser = %ServerBrowser
## Full-screen "Looking for a server..." overlay shown during Quick Play.
@onready var quick_overlay: Control = %QuickPlay
## Mode name on the overlay.
@onready var qp_mode: Label = %QPMode
## Status text + elapsed timer on the overlay.
@onready var qp_status: Label = %QPStatus
## "Create a game instead" button on the overlay (shown when nothing is found).
@onready var qp_create: Button = %QPCreate

var service: Node              ## Finds servers (master + LAN) - shared by Quick Play and the browser.
## Index into MODES of the selected mode card.
var selected_mode := 0
## Index into CLASSES of the selected class (NOT the level's class index).
var selected_class := 0
var selected_team := -1        ## -1 = Auto (fewer players), 0 = Red, 1 = Blue
var _sub_mode_pickers := {}    # mode index -> OptionButton
var _quick_mode := -1          # mode index being searched, -1 = not searching
var _quick_elapsed := 0.0      # seconds spent searching (shown as m:ss)
var _quick_retry_in := 0.0     # countdown until we ask the service again (0 = not waiting)
var _quick_message := ""       # current Quick Play status text


## Handles command-line launches, loads settings, creates the server service and builds the UI.
func _ready() -> void:
	# Launched as a dedicated server (e.g. Game.exe --headless -- --server --mode=deathmatch):
	# skip the menu, the level reads the same arguments and starts the server.
	# call_deferred: changing scene in the middle of _ready is not allowed, so do it at the end of the frame.
	if "--server" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred(LEVEL_SCENE)
		return
	# --master runs the master server (the list of online servers) instead of the game.
	if "--master" in OS.get_cmdline_user_args():
		get_tree().change_scene_to_file.call_deferred("res://Scenes/Network/master_server.tscn")
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	var settings = preload("res://Scripts/Global/game_settings.gd")
	settings.reload()         # fresh from disk, in case another copy of the game changed it
	settings.apply_global()   # volume, fullscreen
	# Player name and bot count are saved as soon as they change.
	%NameEdit.text = settings.get_value("player_name")
	%NameEdit.text_changed.connect(func(t): settings.set_value("player_name", t.strip_edges()))
	# clampi keeps a weird saved value inside the drop-down's range.
	%BotsSelect.select(clampi(int(settings.get_value("bots")), 0, %BotsSelect.item_count - 1))
	%BotsSelect.item_selected.connect(func(i): settings.set_value("bots", i))

	# The service is a plain Node made from a script, added as our child so it runs
	# (_process, HTTP requests) and is freed together with the menu.
	service = BrowserService.new()
	service.name = "ServerBrowserService"
	add_child(service)
	service.quick_play_result.connect(_on_quick_play_result)
	browser.service = service
	browser.join_requested.connect(func(address, port): _start_level(false, address, port))

	_build_mode_cards()
	_build_class_buttons()
	_build_team_buttons()

	%BrowseButton.pressed.connect(func(): browser.open())
	%CreateButton.pressed.connect(func(): _start_level(true))
	%ConnectButton.pressed.connect(_direct_connect)
	address_edit.text_submitted.connect(func(_t): _direct_connect())
	upnp_toggle.toggled.connect(func(on): upnp_toggle.text = "UPnP: %s" % ("on" if on else "off"))
	%QPCancel.pressed.connect(_cancel_quick_play)
	qp_create.pressed.connect(func(): _cancel_quick_play(); _start_level(true))

	_select_mode(0)
	_select_class(0)

	# Show (once) any message the level left for us, like "Disconnected from server".
	if notice != "":
		_show_status(notice, true)
		notice = ""


# --- Mode cards --------------------------------------------------------------------

## Builds one big clickable card per entry in MODES, entirely from code:
## Button (the card) > MarginContainer > VBoxContainer > title, stats, description, row [sub-mode picker, PLAY].
func _build_mode_cards() -> void:
	# A ButtonGroup makes toggle buttons act like radio buttons: pressing one un-presses the others.
	var group := ButtonGroup.new()
	for i in MODES.size():
		var m: Dictionary = MODES[i]
		var card := Button.new()
		card.toggle_mode = true
		card.button_group = group
		card.custom_minimum_size = Vector2(0, 262)
		# EXPAND_FILL: the cards share the row's width equally.
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.pressed.connect(_select_mode.bind(i))

		# A Button is not a container, so it won't lay out children by itself. We put a
		# MarginContainer inside it, stretched over the whole card (PRESET_FULL_RECT), for padding.
		var margin := MarginContainer.new()
		margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# IGNORE so clicks on the card's content still reach the card button underneath.
		margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for side in ["left", "right"]: margin.add_theme_constant_override("margin_" + side, 18)
		for side in ["top", "bottom"]: margin.add_theme_constant_override("margin_" + side, 14)
		card.add_child(margin)

		var box := VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_theme_constant_override("separation", 6)
		margin.add_child(box)

		# theme_type_variation uses the "HeadingLabel" style defined in the menu theme (menu_theme.tres).
		var title := Label.new()
		title.theme_type_variation = &"HeadingLabel"
		title.add_theme_font_size_override("font_size", 26)
		title.text = m.name.to_upper()
		box.add_child(title)

		var stats := Label.new()
		stats.text = m.stats
		stats.add_theme_font_size_override("font_size", 14)
		stats.add_theme_color_override("font_color", Color(0.85, 0.68, 0.42))
		box.add_child(stats)

		# Description wraps at word boundaries and takes all spare height,
		# which pushes the PLAY row down to the bottom of the card.
		var desc := Label.new()
		desc.text = m.desc
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.add_theme_font_size_override("font_size", 15)
		desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(desc)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)
		# Modes with sub-modes (Team vs Team) get a drop-down; picking from it also selects the card.
		if !m.sub_modes.is_empty():
			var picker := OptionButton.new()
			for s in m.sub_modes: picker.add_item(s)
			picker.add_theme_font_size_override("font_size", 14)
			picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			picker.item_selected.connect(func(_idx): _select_mode(i))
			row.add_child(picker)
			_sub_mode_pickers[i] = picker
		# PLAY = Quick Play for this mode. It fills the row unless a drop-down shares it.
		var play := Button.new()
		play.text = "PLAY"
		play.add_theme_font_size_override("font_size", 20)
		play.custom_minimum_size = Vector2(110, 0)
		play.size_flags_horizontal = Control.SIZE_SHRINK_END if !m.sub_modes.is_empty() else Control.SIZE_EXPAND_FILL
		play.pressed.connect(_start_quick_play.bind(i))
		row.add_child(play)

		mode_cards.add_child(card)


## Selects mode card i: presses it, dims the other cards, and updates the team options.
func _select_mode(i: int) -> void:
	selected_mode = i
	var card: Button = mode_cards.get_child(i)
	card.button_pressed = true
	# Fade every card's colour: the selected one to full white, the others slightly darker.
	for c in mode_cards.get_child_count():
		var other: Control = mode_cards.get_child(c)
		var t := create_tween()
		t.tween_property(other, "modulate", Color.WHITE if c == i else Color(0.78, 0.74, 0.7), 0.12)

	# Teams only matter in Team vs Team.
	var id: String = MODES[i].id
	for b in team_buttons.get_children(): b.disabled = id != "team_vs_team"
	match id:
		"deathmatch": team_note.text = "Every survivor for themselves."
		"wave_survival": team_note.text = "Everyone fights on one team."
		_: team_note.text = "Auto puts you on the smaller team."


## The chosen sub-mode name for mode i (e.g. "Capture the Flag"), or "" if it has none.
func _sub_mode_text(i: int) -> String:
	if !_sub_mode_pickers.has(i): return ""
	var p: OptionButton = _sub_mode_pickers[i]
	return p.get_item_text(p.selected)


# --- Classes & teams ----------------------------------------------------------------------

## One toggle button per class (radio-style through a ButtonGroup).
func _build_class_buttons() -> void:
	var group := ButtonGroup.new()
	for i in CLASSES.size():
		var c: Dictionary = CLASSES[i]
		var b := Button.new()
		b.text = c.name
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Classes that don't exist in the level yet are greyed out.
		if c.index < 0:
			b.disabled = true
			b.tooltip_text = "Coming soon"
		b.pressed.connect(_select_class.bind(i))
		class_buttons.add_child(b)


## Selects class i and shows its info text.
func _select_class(i: int) -> void:
	selected_class = i
	(class_buttons.get_child(i) as Button).button_pressed = true
	var c: Dictionary = CLASSES[i]
	class_info.text = "%s   |   %d HP   |   %s speed\n%s" % [c.role, c.hp, c.speed, c.kit]


## Auto / Red / Blue buttons, each with its own text colour. Auto is selected by default.
func _build_team_buttons() -> void:
	var group := ButtonGroup.new()
	# [label, team value, text colour]
	var options := [["Auto", -1, Color(0.95, 0.89, 0.76)], ["Red", 0, Color(1, 0.55, 0.45)], ["Blue", 1, Color(0.55, 0.7, 1)]]
	for o in options:
		var b := Button.new()
		b.text = o[0]
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# A Button has a separate font colour for each state; override all of them so the
		# team colour stays the same when hovered or pressed.
		for k in ["font_color", "font_pressed_color", "font_hover_color", "font_hover_pressed_color"]:
			b.add_theme_color_override(k, o[2])
		b.pressed.connect(func(): selected_team = o[1])
		team_buttons.add_child(b)
	(team_buttons.get_child(0) as Button).button_pressed = true


# --- Quick Play ------------------------------------------------------------------------------
# Quick Play asks the service for a server for the chosen mode. The answer comes back
# later through the quick_play_result signal. If nothing is found yet we keep retrying
# (timer in _process) until the player cancels or creates their own game.

## PLAY was pressed on mode card i: show the overlay and start searching.
func _start_quick_play(i: int) -> void:
	_select_mode(i)
	_quick_mode = i
	_quick_elapsed = 0.0
	_quick_retry_in = 0.0
	_quick_message = "Looking for a server..."
	var sub := _sub_mode_text(i)
	qp_mode.text = MODES[i].name + ("  -  " + sub if sub != "" else "")
	qp_create.hide()
	quick_overlay.show()
	service.quick_play(MODES[i].id)


## The service answered. r.status is "found", "waiting" or something else (nothing found).
func _on_quick_play_result(r: Dictionary) -> void:
	# Ignore late answers if the player already cancelled.
	if _quick_mode < 0: return
	match r.status:
		"found":
			_quick_message = "Found %s - joining..." % r.get("name", "a server")
			# Remember the mode and stop searching (so _process stops updating the text).
			var mode := _quick_mode
			_quick_mode = -1
			qp_status.text = _quick_message
			# await pauses this function for 0.5 s without freezing the game, then continues.
			await get_tree().create_timer(0.5).timeout   # a beat so you can read it
			# Only join if the player didn't switch to a different mode during the wait.
			if mode == selected_mode:
				_start_level(false, r.address, r.port)
		"waiting":
			# e.g. the master server is starting a server for us - ask again soon.
			_quick_message = r.get("message", "Waiting for a server...")
			_quick_retry_in = 2.0
		_:
			# Nothing yet: offer "create a game" and retry after a few seconds.
			_quick_message = "No open servers yet - still looking..."
			qp_create.show()
			_quick_retry_in = QUICK_PLAY_RETRY_SECONDS


## Stops searching and hides the overlay.
func _cancel_quick_play() -> void:
	_quick_mode = -1
	service.cancel_quick_play()
	quick_overlay.hide()


## While Quick Play is searching: update the m:ss timer and retry when the countdown ends.
func _process(delta: float) -> void:
	if _quick_mode < 0: return
	_quick_elapsed += delta
	var secs := int(_quick_elapsed)
	# %02d pads seconds with a zero (1:05, not 1:5).
	qp_status.text = "%s\n%d:%02d" % [_quick_message, floori(secs / 60.0), secs % 60]
	if _quick_retry_in > 0.0:
		_quick_retry_in -= delta
		if _quick_retry_in <= 0.0:
			service.quick_play(MODES[_quick_mode].id)


# --- Starting a game -----------------------------------------------------------------------

## Direct connect: reads "address" or "address:port" from the text box (empty = localhost).
func _direct_connect() -> void:
	var text := address_edit.text.strip_edges()
	var port := NetConfig.DEFAULT_GAME_PORT
	# rfind = search from the end, so we find the LAST ":" (the one before the port).
	var colon := text.rfind(":")
	if colon > 0 and text.substr(colon + 1).is_valid_int():   # "1.2.3.4:9998"
		port = int(text.substr(colon + 1))
		text = text.substr(0, colon)
	_start_level(false, text if text != "" else "localhost", port)


## as_host: create a local game with the selected mode. Otherwise join address:port.
## Every way of starting a game ends up here.
func _start_level(as_host: bool, address := "", port := NetConfig.DEFAULT_GAME_PORT) -> void:
	var m: Dictionary = MODES[selected_mode]
	_show_status("Creating %s..." % m.name if as_host else "Joining %s:%d..." % [address, port], false)
	# instantiate() creates the level's nodes but does NOT add them to the tree yet,
	# so its _ready() has not run. That gives us a chance to set start_config first.
	var level = load(LEVEL_SCENE).instantiate()
	# Everything the level needs to know to host or join. ("class" is the level's
	# CLASS_SCENES index, and bots only matter when hosting.)
	level.start_config = {
		"host": as_host,
		"mode": m.id,
		"sub_mode": _sub_mode_text(selected_mode),
		"class": CLASSES[selected_class].index,
		"team": selected_team,
		"address": address,
		"port": port,
		"upnp": upnp_toggle.button_pressed,
		"name": %NameEdit.text.strip_edges(),
		"bots": %BotsSelect.selected if as_host else 0,
		"bot_difficulty": int(preload("res://Scripts/Global/game_settings.gd").get_value("bot_difficulty")),
	}
	# Swap scenes by hand so start_config is set before the level's _ready runs.
	# (change_scene_to_file would create the level itself and we couldn't give it the config
	# in time.) Steps: add the level to the root -> its _ready runs with the config ->
	# mark it as the current scene -> delete this menu.
	var tree := get_tree()
	tree.root.add_child(level)
	tree.current_scene = level
	queue_free()


## Shows a message in the status line (red for errors, gold otherwise) with a quick fade-in.
func _show_status(text: String, is_error: bool) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", Color(1, 0.45, 0.35) if is_error else Color(0.85, 0.68, 0.42))
	status_label.modulate.a = 0.0
	create_tween().tween_property(status_label, "modulate:a", 1.0, 0.25)
