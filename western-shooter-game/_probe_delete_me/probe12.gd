extends Node
# Temporary test: explosion smoke must appear at the blast, not at the map centre. Delete this folder.
func _ready() -> void:
	await get_tree().process_frame
	var level = load("res://Levels/team_vs_team.tscn").instantiate()
	level.start_config = {"host": true, "mode": "team_vs_team", "sub_mode": "", "class": 3, "team": 0, "address": "", "port": 9999, "upnp": false, "name": "Probe", "bots": 0, "bot_difficulty": 1}
	get_tree().root.add_child(level)
	await get_tree().create_timer(1.0).timeout
	var me = level.get_node("1")
	# Look at the map centre.
	var to_center: Vector3 = Vector3.ZERO - me.global_position
	me.rotation.y = atan2(-to_center.x, -to_center.z)
	me.camera.rotation.x = deg_to_rad(-8)
	await get_tree().create_timer(0.3).timeout
	var side: Vector3 = me.global_basis.x
	var blast: Vector3 = me.global_position.lerp(Vector3.ZERO, 0.5) + side * 8.0 + Vector3.UP
	preload("res://Scripts/Weapons/explosion.gd").spawn_effect(level, blast, 4.5)
	await get_tree().create_timer(0.45).timeout
	get_viewport().get_texture().get_image().save_png("res://_probe_delete_me/explosion.png")
	get_tree().quit()
