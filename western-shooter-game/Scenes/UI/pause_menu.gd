extends Control
## Esc menu during a match: Resume, Options, Disconnect / End game, Quit.
## The match keeps running underneath (it's online) - your player just stops taking input.
##
## Where it lives: Scenes/UI/pause_menu.tscn, under the level's CanvasLayer
## (multiplayer_test_scene.gd has it as $CanvasLayer/PauseMenu).
## How it talks to the game: the level calls bind() once your player exists, and
## set_current_class() / set_bot_info() to keep it up to date. The menu never does
## network stuff itself - it emits signals (leave_requested, add_bot_requested...) and
## the level does the real work. Settings are saved through GameSettings.
##
## Why no get_tree().paused? In an online game you can't freeze the world for everyone,
## so "pausing" only means: show the menu, free the mouse, and stop your player's input.
## Local-only UI: each player has their own pause menu.
##
## Pages (only one is visible at a time): main buttons, options, and the class picker
## (the class picker and the auto reload option are built from code, not in the .tscn).

signal leave_requested   ## The level handles disconnecting and going back to the main menu.
## Host pressed "+" in the bots row.
signal add_bot_requested
## Host pressed "-" in the bots row.
signal remove_bot_requested
## Host cycled the bot difficulty (0 = Easy, 1 = Normal, 2 = Hard).
signal bot_difficulty_changed(difficulty: int)
signal class_change_requested(class_index: int)   ## Index into the level's CLASS_SCENES.

## Classes you can switch to: [level class index, name, short description].
## (The order here is the order of the buttons; the first number must match the level.)
const CLASSES := [
	[1, "Medic", "150 HP  |  shotgun, syringe, bone saw"],
	[2, "Sheriff", "200 HP  |  lever rifle, pump shotgun, bat"],
	[4, "Gunslinger", "125 HP, fast  |  dual revolvers, coach gun, knife"],
	[3, "Bomber", "125 HP  |  dynamite, revolver rifle, pickaxe"],
]

## Text for the bot difficulty button, indexed by difficulty number.
const DIFFICULTY_NAMES := ["Easy", "Normal", "Hard"]

## Script with static helpers that load/save player settings and apply them.
const GameSettings = preload("res://Scripts/Global/game_settings.gd")

## Shows the mode and where you are playing (e.g. "Death Match  |  Hosting").
@onready var info_label: Label = %InfoLabel
## The main page (Resume / Options / Change class / Leave / Quit).
@onready var main_buttons: Control = %MainButtons
## The options page.
@onready var options_box: Control = %OptionsBox
## "Disconnect" for clients, "End game" for the host.
@onready var leave_button: Button = %LeaveButton
@onready var sensitivity: HSlider = %Sensitivity
@onready var fov: HSlider = %Fov
@onready var volume: HSlider = %Volume
## Toggle button for fullscreen (shows "On"/"Off").
@onready var fullscreen: Button = %Fullscreen
## Toggle button for auto reload. Not in the .tscn - created in _add_auto_reload_row().
var auto_reload: Button

## The local player (we switch its input off while the menu is open).
var player: Node
## True if this machine is the server/host (shows the bots row, "End game" text).
var is_host := false
## Seconds left to click "End game" a second time to confirm (0 = not waiting).
var _confirm_left := 0.0
## Current bot difficulty as told by the level (used to work out the next one).
var _bot_difficulty := 1
## Class the player is currently playing (-1 = unknown yet).
var _current_class := -1
## The class picker page, built in code.
var _class_box: VBoxContainer
var _class_buttons := {}   # class index -> Button


## Connects buttons, builds the code-made parts and loads saved settings into the controls.
func _ready() -> void:
	hide()
	%ResumeButton.pressed.connect(resume)
	%OptionsButton.pressed.connect(_show_options)
	%BackButton.pressed.connect(_show_main)
	%QuitButton.pressed.connect(func(): get_tree().quit())
	leave_button.pressed.connect(_on_leave_pressed)
	# Bot buttons only send requests; the level adds/removes bots and then calls set_bot_info().
	%AddBot.pressed.connect(func(): add_bot_requested.emit())
	%RemoveBot.pressed.connect(func(): remove_bot_requested.emit())
	# Cycles 0 -> 1 -> 2 -> 0 (% 3 wraps around).
	%BotDifficulty.pressed.connect(func(): bot_difficulty_changed.emit((_bot_difficulty + 1) % 3))
	_build_class_box()

	# Put the saved settings into the controls BEFORE connecting their signals,
	# so setting these values doesn't trigger a save/apply for nothing.
	sensitivity.value = GameSettings.get_value("mouse_sensitivity")
	fov.value = GameSettings.get_value("fov")
	volume.value = GameSettings.get_value("master_volume")
	fullscreen.button_pressed = GameSettings.get_value("fullscreen")
	_add_auto_reload_row()
	_update_value_labels()
	# bind("key") adds an extra argument to the signal call, so one function
	# (_on_setting_changed(value, key)) can handle every setting.
	sensitivity.value_changed.connect(_on_setting_changed.bind("mouse_sensitivity"))
	fov.value_changed.connect(_on_setting_changed.bind("fov"))
	volume.value_changed.connect(_on_setting_changed.bind("master_volume"))
	fullscreen.toggled.connect(_on_setting_changed.bind("fullscreen"))
	auto_reload.toggled.connect(_on_setting_changed.bind("auto_reload"))


## Called by the level once your player exists.
## info is the small text at the top (mode and where you're playing).
func bind(p_player: Node, p_is_host: bool, info: String) -> void:
	player = p_player
	is_host = p_is_host
	info_label.text = info
	leave_button.text = "End game" if is_host else "Disconnect"
	%BotRow.visible = is_host   # only the host can add/remove bots


## Host only: shows how many bots there are and how good they are.
func set_bot_info(count: int, difficulty: int) -> void:
	_bot_difficulty = difficulty
	%BotCount.text = str(count)
	%BotDifficulty.text = DIFFICULTY_NAMES[difficulty]


## Keyboard shortcuts. _unhandled_input only gets events that no other UI used first.
func _unhandled_input(event: InputEvent) -> void:
	if player == null or !is_instance_valid(player): return
	# Esc ("ui_cancel"): open the menu, or go back one page, or close it.
	if event.is_action_pressed("ui_cancel"):
		if !visible: open()
		elif options_box.visible or _class_box.visible: _show_main()
		else: resume()
		# Mark the event as used so nothing else reacts to the same key press.
		get_viewport().set_input_as_handled()
	# physical_keycode = the key's position on the keyboard, so it works on any layout.
	# !event.echo ignores the auto-repeat events from holding the key down.
	elif event is InputEventKey and event.pressed and !event.echo and event.physical_keycode == KEY_COMMA:
		# , opens the class picker straight away (like TF2).
		if !visible: open()
		_show_classes()
		get_viewport().set_input_as_handled()


## Shows the menu: stops player input and frees the mouse cursor so you can click buttons.
func open() -> void:
	show()
	_show_main()
	player.input_enabled = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Give keyboard/controller focus to Resume so the menu works without a mouse too.
	%ResumeButton.grab_focus()


## Closes the menu and gives control back to the player (mouse locked to the game again).
func resume() -> void:
	hide()
	if player and is_instance_valid(player):
		player.input_enabled = true
	# CAPTURED hides the cursor and keeps it in the window, for mouse-look.
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


## Shows the main page (and cancels a pending "click again to end game").
func _show_main() -> void:
	main_buttons.show()
	options_box.hide()
	_class_box.hide()
	_reset_leave_button()


## Shows the options page.
func _show_options() -> void:
	main_buttons.hide()
	options_box.show()


## Shows the class picker and focuses the current class button (or the first one).
func _show_classes() -> void:
	main_buttons.hide()
	options_box.hide()
	_class_box.show()
	var b: Button = _class_buttons.get(_current_class)
	if b == null and !_class_buttons.is_empty(): b = _class_buttons.values()[0]
	if b: b.grab_focus()


# --- Change class ----------------------------------------------------------------------------

## Called by the level with your current class (its index in the level's CLASS_SCENES).
## Disables that class's button and adds "(current)" to its text.
func set_current_class(class_index: int) -> void:
	_current_class = class_index
	for i in _class_buttons:
		var b: Button = _class_buttons[i]
		b.disabled = i == class_index
		b.text = _class_name(i) + ("  (current)" if i == class_index else "")


## Looks up a class name from its level index in CLASSES.
func _class_name(class_index: int) -> String:
	for c in CLASSES:
		if c[0] == class_index: return c[1]
	return "?"


## Builds the "Change class" button and the whole class picker page from code.
func _build_class_box() -> void:
	# "Change class" button in the main list, under Options.
	var open_btn := Button.new()
	open_btn.text = "Change class"
	# Same size as the other buttons so it fits in.
	open_btn.custom_minimum_size = %OptionsButton.custom_minimum_size
	open_btn.pressed.connect(_show_classes)
	main_buttons.add_child(open_btn)
	# add_child puts it at the end; move_child moves it to just after Options.
	main_buttons.move_child(open_btn, %OptionsButton.get_index() + 1)

	# The class picker page (same place as the options page).
	# Added to the same parent as options_box, so it appears in the same spot in the panel.
	_class_box = VBoxContainer.new()
	_class_box.add_theme_constant_override("separation", 8)
	options_box.get_parent().add_child(_class_box)
	var title := Label.new()
	title.text = "Choose a class"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_class_box.add_child(title)
	# One button + one small faded description label per class.
	for c in CLASSES:
		var b := Button.new()
		b.text = c[1]
		b.tooltip_text = c[2]
		b.custom_minimum_size = Vector2(0, 40)
		# bind(c[0]) makes the button call _pick_class with this class's index.
		b.pressed.connect(_pick_class.bind(c[0]))
		_class_box.add_child(b)
		var info := Label.new()
		info.text = c[2]
		info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		info.modulate = Color(1, 1, 1, 0.6)
		info.add_theme_font_size_override("font_size", 13)
		_class_box.add_child(info)
		_class_buttons[c[0]] = b
	var note := Label.new()
	note.text = "Switching while alive counts as a death.\nYou come back as the new class after the respawn wait."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.modulate = Color(1, 0.85, 0.6, 0.85)
	note.add_theme_font_size_override("font_size", 13)
	_class_box.add_child(note)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_show_main)
	_class_box.add_child(back)
	_class_box.hide()


## A class was chosen: close the menu and ask the level to switch (the level handles the network side).
func _pick_class(class_index: int) -> void:
	resume()
	class_change_requested.emit(class_index)


# --- Leaving --------------------------------------------------------------------------------

## Disconnect / End game. The host must click twice within 3 seconds.
func _on_leave_pressed() -> void:
	# The host is the server: leaving ends the match for everyone, so ask once more.
	if is_host and _confirm_left <= 0.0:
		_confirm_left = 3.0
		leave_button.text = "Ends it for everyone - click again"
		return
	leave_requested.emit()


## Counts down the "click again" confirmation window.
func _process(delta: float) -> void:
	if _confirm_left > 0.0:
		_confirm_left -= delta
		if _confirm_left <= 0.0: _reset_leave_button()


## Cancels the confirmation and puts the normal text back.
func _reset_leave_button() -> void:
	_confirm_left = 0.0
	leave_button.text = "End game" if is_host else "Disconnect"


# --- Options ---------------------------------------------------------------------------------

## Any option changed: save it, apply it to the player (sensitivity, FOV, auto reload)
## and to the whole game (volume, fullscreen), then refresh the value labels.
## `value` comes from the signal; `key` comes from the .bind() in _ready().
func _on_setting_changed(value, key: String) -> void:
	GameSettings.set_value(key, value)
	if player and is_instance_valid(player):
		GameSettings.apply_to_player(player)
	GameSettings.apply_global()
	_update_value_labels()


## Updates the small text next to each option (e.g. "1.5", "90", "80%", "On").
func _update_value_labels() -> void:
	%SensitivityValue.text = "%.1f" % sensitivity.value
	%FovValue.text = "%d" % fov.value
	# "%%" is how you write a literal % sign inside a format string.
	%VolumeValue.text = "%d%%" % volume.value
	fullscreen.text = "On" if fullscreen.button_pressed else "Off"
	auto_reload.text = "On" if auto_reload.button_pressed else "Off"


## Options row: Auto reload  [On/Off]
## Adds the row from code to the same GridContainer as Fullscreen.
func _add_auto_reload_row() -> void:
	var grid := fullscreen.get_parent()
	var label := Label.new()
	label.text = "Auto reload"
	label.tooltip_text = "Reload by yourself when the gun is empty or you stop shooting for a moment."
	# Labels ignore the mouse by default; PASS lets them receive hover so the tooltip shows.
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	auto_reload = Button.new()
	# toggle_mode makes the button stay pressed/unpressed like a checkbox.
	auto_reload.toggle_mode = true
	auto_reload.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	auto_reload.custom_minimum_size = fullscreen.custom_minimum_size
	auto_reload.button_pressed = GameSettings.get_value("auto_reload")
	# The grid has 3 columns (name, control, value text). A GridContainer fills cells in order,
	# so we add the label, the button, and an empty Control to fill the third cell.
	for n in [label, auto_reload, Control.new()]: grid.add_child(n)
