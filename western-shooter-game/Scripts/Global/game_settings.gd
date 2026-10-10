extends RefCounted
## Player settings (saved per PC in user://settings.cfg) and helpers to apply them.
## Use with:  const GameSettings = preload("res://Scripts/Global/game_settings.gd")
##
## This is not an autoload and is never added to a scene: everything here is `static`, so other
## scripts just preload the file and call GameSettings.get_value(...) etc. directly.
## Used by the main menu / settings screen (to show and change values), the level
## (player name, bot difficulty) and the local player (mouse sensitivity, FOV, auto reload).
## It runs on whichever computer calls it - settings are personal and are never sent over the network.
##
## "user://" is a per-user folder Godot picks for the game (on Windows something like
## %APPDATA%/Godot/app_userdata/<project name>/), so settings survive between runs.

## File the settings are saved in.
const PATH := "user://settings.cfg"
## Every setting and its value when the player hasn't changed it yet.
## Only keys listed here can be read with get_value().
const DEFAULTS := {
	"mouse_sensitivity": 5.0,   # shown as 1-15; the player uses this / 1000
	"fov": 75.0,                # degrees
	"master_volume": 80.0,      # percent
	"fullscreen": false,
	"player_name": "",          # empty = use the computer's user name
	"bots": 0,                  # bots in a local game (add more from the menu or the Esc menu)
	"bot_difficulty": 1,        # 0 easy, 1 normal, 2 hard
	"auto_reload": true,        # reload by itself when empty or after you stop shooting
}

# The loaded settings file, kept in memory so we don't read the disk every time.
# A static var is shared by every script that preloads this file.
static var _cfg: ConfigFile


## Returns the saved value of a setting, or its default from DEFAULTS.
## An empty player name is replaced by the computer's login name (or "Player").
static func get_value(key: String):
	_load()
	# ConfigFile stores values under "sections"; we keep everything in one called "settings".
	var value = _cfg.get_value("settings", key, DEFAULTS[key])
	if key == "player_name" and str(value).strip_edges() == "":
		# USERNAME exists on Windows, USER on Linux/macOS.
		var n := OS.get_environment("USERNAME")
		if n == "": n = OS.get_environment("USER")
		return n if n != "" else "Player"
	return value


## Changes one setting and saves the file straight away.
static func set_value(key: String, value) -> void:
	reload()   # pick up changes another open copy of the game saved, so we don't overwrite them
	_cfg.set_value("settings", key, value)
	_cfg.save(PATH)


## Settings that belong to your own player (call on the local player only).
## Sensitivity is stored as a friendly 1-15 number; the player script wants a small radians-per-pixel value.
static func apply_to_player(player: Node) -> void:
	player.look_sensitivity = float(get_value("mouse_sensitivity")) / 1000.0
	player.camera.fov = float(get_value("fov"))
	player.auto_reload_enabled = bool(get_value("auto_reload"))


## Settings for the whole game window.
static func apply_global() -> void:
	# Volume: percent -> 0..1 -> decibels on bus 0 (the "Master" audio bus).
	# linear_to_db(0) would be minus infinity, so use a tiny number instead and mute at 0 %.
	var vol := float(get_value("master_volume")) / 100.0
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(vol, 0.0001)))
	AudioServer.set_bus_mute(0, vol <= 0.0)
	# A dedicated server started with --headless has no window, so stop here.
	if DisplayServer.get_name() == "headless": return
	var full: bool = get_value("fullscreen")
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if full else DisplayServer.WINDOW_MODE_WINDOWED
	# Only change the window when needed (changing it makes the screen flicker). If it's already
	# in *exclusive* fullscreen, that counts as fullscreen too, so leave it alone.
	if DisplayServer.window_get_mode() != want and !(full and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN):
		DisplayServer.window_set_mode(want)


## Re-reads the file from disk (e.g. when the main menu opens).
static func reload() -> void:
	_cfg = null
	_load()


# Loads the file the first time it's needed. If it doesn't exist yet (first run), load() just
# fails quietly and we start with an empty ConfigFile, so every value falls back to DEFAULTS.
static func _load() -> void:
	if _cfg: return
	_cfg = ConfigFile.new()
	_cfg.load(PATH)
