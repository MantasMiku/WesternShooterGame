extends Area3D
## Death zone: anyone who touches it dies (falling off the map, pits, lava...).
## Drop one into any level and size its CollisionShape3D to cover the area.
## If someone hurt the victim in the last few seconds (shot them, blasted them off with
## dynamite...), that player gets the kill - otherwise it counts as falling to your death.
## Runs on every peer, but only the victim's own peer (its multiplayer authority) acts on it.
##
## Used by the DeathZone node in Levels/multiplayer_test_scene.tscn. The actual death and
## kill-credit logic lives in PlayerController.fall_kill() (player_controller.gd).
## Why only the victim's peer: that peer owns the player's health and position, so it is the
## one that decides the player died; the other peers learn about it through the player's
## MultiplayerSynchronizer (is_dead) and the game mode.


## Set up the physics and connect the "something entered" signal.
func _ready() -> void:
	collision_layer = 0      # nothing needs to detect the zone itself
	collision_mask = 0b10    # players
	monitorable = false      # other areas can't see this one (saves work)
	# body_entered is a built-in Area3D signal: it fires when a physics body starts touching us.
	body_entered.connect(_on_body_entered)


## Kill a living player that entered the zone, if this peer controls that player.
func _on_body_entered(body: Node) -> void:
	if body.has_method("fall_kill") and body.is_multiplayer_authority() and !body.is_dead:
		body.fall_kill()
