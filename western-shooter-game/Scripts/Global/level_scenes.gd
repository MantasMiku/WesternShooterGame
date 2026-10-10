extends RefCounted
## Which level scene each game mode loads.
##
## Used by the main menu (hosting, joining, dedicated servers) and by the level itself
## (a client that loaded the wrong level for the server's mode swaps to the right one).
## To give a mode its own map: make the scene in Levels/ and put its path here.
## If a scene file is missing, the mode falls back to FALLBACK_LEVEL so the game still runs.

## The level used when a mode has no scene of its own (or its file was deleted).
const FALLBACK_LEVEL := "res://Levels/multiplayer_test_scene.tscn"

## mode id (same ids as the MODES lists in main_menu.gd / the level script) -> level scene path.
const LEVELS := {
	"team_vs_team": "res://Levels/team_vs_team.tscn",
	"deathmatch": "res://Levels/multiplayer_test_scene.tscn",
	"wave_survival": "res://Levels/wave_survival.tscn",
}


## The level scene path for this mode (FALLBACK_LEVEL if unknown or the file doesn't exist).
static func for_mode(mode: String) -> String:
	var path: String = LEVELS.get(mode, FALLBACK_LEVEL)
	return path if ResourceLoader.exists(path) else FALLBACK_LEVEL
