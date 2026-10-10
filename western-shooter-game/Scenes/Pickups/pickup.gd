extends Area3D
## Health or ammo pickup. The server decides who gets it; everyone sees it vanish and come back.
##
## Used on the root (an Area3D) of the health_pickup.tscn / ammo_pickup.tscn scenes. They are
## placed by the Death Match game mode (deathmatch.gd, at the level's PickupSpots markers) and
## the "ammo box" a dead player leaves behind is spawned by multiplayer_test_scene.gd
## (_spawn_drop, with single_use = true).
##
## Multiplayer:
##  - Every peer spins and bobs the model (_process) - that's just looks.
##  - Only the SERVER checks who is touching it, gives the item and runs the respawn timer.
##    Letting one peer decide avoids two players both grabbing the same pickup.
##  - The server sends the health/ammo to the lucky player's owner with an RPC, and tells
##    every peer to hide/show the pickup with the _set_available RPC.

## What this pickup gives.
enum Kind { HEALTH, AMMO }

@export var kind := Kind.HEALTH
## Health: fraction of the player's max health. Ammo: fraction of each gun's spare ammo.
## (@export_range limits the Inspector slider to 0.05 - 1.0.)
@export_range(0.05, 1.0) var amount := 0.5
## Seconds after being taken before it comes back.
@export var respawn_seconds := 20.0
## Dropped by a dead player: can be taken once (no respawn) and vanishes after `lifetime` seconds.
@export var single_use := false
@export var lifetime := 0.0

## Can it be picked up right now? (False while waiting to respawn.)
var available := true
## Seconds until it comes back (server only).
var _respawn_left := 0.0
## Animation clock for the spin and bob.
var _t := 0.0

## The model that spins; hidden while the pickup is taken.
@onready var visual: Node3D = $Visual


## Set up the physics: this Area3D doesn't need to be detected by anything (layer 0), but it
## detects bodies on layer 2, which is where the players are.
func _ready() -> void:
	collision_layer = 0
	collision_mask = 0b10   # players
	# Random start so pickups placed next to each other don't spin in perfect sync. TAU = 2*PI.
	_t = randf() * TAU


## Every frame: animate on all peers; on the server also run the lifetime and respawn timers.
func _process(delta: float) -> void:
	# Spin and bob.
	_t += delta
	visual.rotation.y = _t * 1.2                       # 1.2 radians per second
	visual.position.y = 0.35 + sin(_t * 2.0) * 0.08    # float 0.08 m up and down around 0.35 m
	# Below here: server only (multiplayer_peer is null when no game is running).
	if multiplayer.multiplayer_peer == null or !multiplayer.is_server(): return
	if single_use and lifetime > 0.0 and available:
		lifetime -= delta
		if lifetime <= 0.0:
			_set_available.rpc(false)   # nobody took it in time
			return
	if !available:
		_respawn_left -= delta
		if _respawn_left <= 0.0:
			_set_available.rpc(true)


## Every physics frame on the server: check the players standing in the pickup.
func _physics_process(_delta: float) -> void:
	# Server only: hand it to the first player standing in it who can use it.
	if !available or multiplayer.multiplayer_peer == null or !multiplayer.is_server(): return
	for body in get_overlapping_bodies():
		if _try_give(body): return


## Try to give the pickup to `body`. Returns true if it was taken. (Server only.)
func _try_give(body: Node) -> bool:
	# Only living players (anything with receive_ammo is a PlayerController).
	if !body.has_method("receive_ammo") or body.is_dead: return false
	# The peer that controls this player - its health and ammo live there.
	var owner_id := body.get_multiplayer_authority()
	match kind:
		Kind.HEALTH:
			if body.health >= body.max_health: return false   # full health: leave it for someone else
			body.receive_heal.rpc_id(owner_id, ceili(body.max_health * amount))
		Kind.AMMO:
			body.receive_ammo.rpc_id(owner_id, amount)
	_respawn_left = respawn_seconds
	_set_available.rpc(false)   # hide it for everyone
	return true


## Server -> everyone: show or hide the pickup.
## @rpc("authority", "call_local", "reliable"): only the server (the authority of this node)
## may send it, it runs on the server too, and it is guaranteed to arrive.
@rpc("authority", "call_local", "reliable")
func _set_available(value: bool) -> void:
	set_available_local(value)


## Show/hide the pickup on this peer only. Also called directly by deathmatch.gd to tell a
## player who just joined which pickups are currently taken.
func set_available_local(value: bool) -> void:
	available = value
	visual.visible = value
	# A dropped ammo box is gone for good once taken or expired.
	if single_use and !value:
		queue_free()
