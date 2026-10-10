extends Node
# Temporary test: mashing fire on the Sheriff guns. Delete the _probe_delete_me folder.
var _log := ""
func _p(line: String) -> void:
	print(line)
	_log += line + "\n"
	var f := FileAccess.open("res://_probe_delete_me/log11.txt", FileAccess.WRITE)
	f.store_string(_log)

func _ready() -> void:
	await get_tree().process_frame
	var level = load("res://Levels/team_vs_team.tscn").instantiate()
	level.start_config = {"host": true, "mode": "team_vs_team", "sub_mode": "", "class": 2, "team": 0, "address": "", "port": 9999, "upnp": false, "name": "Probe", "bots": 0, "bot_difficulty": 1}
	get_tree().root.add_child(level)
	await get_tree().create_timer(1.0).timeout
	var me = level.get_node("1")
	me.camera.rotation.x = deg_to_rad(30)
	var wm = me.weapon_manager
	for slot in [0, 1]:
		wm.select_weapon(slot)
		await get_tree().create_timer(0.6).timeout
		var g = wm.get_current_weapon()
		var shots := 0
		var last: int = g.ammo
		var timeline := ""
		# Mash fire every 0.1 s for 6 seconds.
		for i in 60:
			wm.try_primary_fire()
			await get_tree().create_timer(0.1).timeout
			if g.ammo < last: shots += 1
			last = g.ammo
			if i % 5 == 4: timeline += "%d%s " % [g.ammo, "R" if g._reloading else ""]
		_p("[probe] %s: %d shots in 6 s, ammo every 0.5 s: %s" % [g.weapon_name, shots, timeline])
	_p("[probe] DONE")
	get_tree().quit()
