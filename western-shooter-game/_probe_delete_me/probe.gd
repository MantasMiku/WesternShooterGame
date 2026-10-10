extends Node3D
# Throwaway smoke test after adding comments. Safe to delete.
const FILES := [
	"res://Scenes/Bomber/bomber.gd",
	"res://Scenes/Gunslinger/gunslinger.gd",
	"res://Scenes/Medic/medic.gd",
	"res://Scenes/Pickups/pickup.gd",
	"res://Scenes/Player/player_controller.gd",
	"res://Scenes/Sheriff/sheriff.gd",
	"res://Scenes/UI/damage_direction.gd",
	"res://Scenes/UI/deathmatch_hud.gd",
	"res://Scenes/UI/hit_marker.gd",
	"res://Scenes/UI/hud.gd",
	"res://Scenes/UI/kill_cam.gd",
	"res://Scenes/UI/main_menu.gd",
	"res://Scenes/UI/pause_menu.gd",
	"res://Scenes/UI/server_browser.gd",
	"res://Scenes/WaterMaker3D/CameraWaterOverlay.gdshader",
	"res://Scenes/WaterMaker3D/FogFade.gdshader",
	"res://Scenes/WaterMaker3D/FogVolumeFadeScript.gd",
	"res://Scenes/WaterMaker3D/WaterMaker3D.gd",
	"res://Scripts/AI/bot_brain.gd",
	"res://Scripts/Effects/outline.gd",
	"res://Scripts/Effects/status_effects.gd",
	"res://Scripts/Effects/tracer.gd",
	"res://Scripts/GameModes/death_zone.gd",
	"res://Scripts/GameModes/deathmatch.gd",
	"res://Scripts/Global/game_settings.gd",
	"res://Scripts/Multiplayer/multiplayer_test_scene.gd",
	"res://Scripts/Network/master_server.gd",
	"res://Scripts/Network/net_config.gd",
	"res://Scripts/Network/server_browser_service.gd",
	"res://Scripts/Network/server_query.gd",
	"res://Scripts/Weapons/dual_pistol_weapon.gd",
	"res://Scripts/Weapons/dynamite_projectile.gd",
	"res://Scripts/Weapons/explosion.gd",
	"res://Scripts/Weapons/hitscan_weapon.gd",
	"res://Scripts/Weapons/melee_weapon.gd",
	"res://Scripts/Weapons/syringe_weapon.gd",
	"res://Scripts/Weapons/thrown_weapon.gd",
	"res://Scripts/Weapons/weapon.gd",
	"res://Scripts/Weapons/weapon_manager.gd",
	"res://Shaders/outline.gdshader",
	"res://Shaders/screen_vignette.gdshader"
]

func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout

func _ready():
	var bad := 0
	for f in FILES:
		var r = load(f)
		if r == null:
			bad += 1
			print("PROBE LOAD FAILED ", f)
		elif r is GDScript and !r.can_instantiate():
			bad += 1
			print("PROBE SCRIPT ERROR ", f)
	print("PROBE loaded %d files, %d problems" % [FILES.size(), bad])
	get_window().size = Vector2i(1280, 720)
	var menu = load("res://Scenes/UI/main_menu.tscn").instantiate()
	get_tree().root.add_child.call_deferred(menu)
	await _wait(0.5)
	menu.get_node("%BotsSelect").select(0)
	menu._select_mode(1)
	menu._select_class(3)   # Bomber
	menu._start_level(true)
	await _wait(1.0)
	var level = get_tree().current_scene
	for cls in [1, 2, 3, 4, 1, 4]: level.add_player(-200 - level.get_bots().size(), cls, -1, "B%d [BOT]" % level.get_bots().size(), true)
	await _wait(14.0)
	var me = level.get_node("1")
	level.pause_menu.open()
	level.pause_menu._show_options()
	await _wait(0.3)
	level.pause_menu._show_classes()
	await _wait(0.3)
	level.pause_menu._pick_class(4)
	await _wait(4.0)
	me = level.get_node("1")
	me.receive_damage(999, -200, "Remington 1889")
	await _wait(1.0)
	print("PROBE kill cam visible=%s card='%s'" % [level.hud.kill_cam.visible, level.hud.kill_cam._detail.text])
	await _wait(8.0)
	var out := []
	for id in level.game_mode.stats:
		var s = level.game_mode.stats[id]
		out.append("%s(%s) K%d D%d" % [s.name, s["class"], s.kills, s.deaths])
	print("PROBE phase=%s  %s" % [level.game_mode.phase, " | ".join(out)])
	print("PROBE_DONE")
