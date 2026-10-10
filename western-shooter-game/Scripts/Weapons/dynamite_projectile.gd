extends RigidBody3D
## A thrown stick of dynamite. It bounces around and blows up when its fuse runs out,
## or straight away if it touches an enemy.
## Every peer simulates its own copy for looks. Only the thrower's peer (`is_owner_copy`)
## decides when it explodes and deals the damage; the others just wait to be told.
##
## Created by thrown_weapon.gd's _spawn_projectile() RPC on every peer, which also fills in
## the variables below. Being a RigidBody3D, Godot's physics engine moves it (gravity,
## bouncing, spinning) - this script only handles the fuse and the "touched an enemy" check.
## Needs a child Area3D called "HitArea" (slightly bigger than the stick) to detect players.

var weapon: Node            ## The thrown_weapon.gd that threw it.
## Unique number for this throw, the same on every peer (used to match up the copies).
var id := 0
## Seconds left before it explodes. Set from the weapon's fuse_time; counts down.
var fuse := 1.6
## True only on the thrower's peer. Only that copy may call weapon.detonate().
var is_owner_copy := false

const ARM_TIME := 0.06      # can't hit anyone for the first instant (no blowing up in your own hand)
## Seconds since it was thrown.
var _age := 0.0

## Area used to notice touching a player.
@onready var hit_area: Area3D = $HitArea


func _ready() -> void:
	# Sparks trail behind the flying stick (in the hand they stay stuck to the fuse).
	# local_coords = false: particles stay where they were emitted in the world instead of
	# moving with the stick, which makes a trail.
	var sparks = get_node_or_null("Model/FuseSparks")
	if sparks: sparks.local_coords = false


## Runs on every peer. Counts down the fuse; the owner's copy checks if it should explode.
## (Explosion damage uses physics queries, which is why this happens in _physics_process.)
func _physics_process(delta: float) -> void:
	_age += delta
	fuse -= delta
	if !is_owner_copy:
		# Other peers never decide anything; they wait for _sync_explode from the thrower.
		# Safety net: if that message never comes, remove the stick 1.5 s after the fuse ended.
		if fuse < -1.5: queue_free()   # never heard back from the thrower (lag/disconnect)
		return
	if fuse <= 0.0 or (_age >= ARM_TIME and _touching_enemy()):
		weapon.detonate(self)


## True if an alive enemy player is inside the HitArea (the thrower and teammates don't count).
func _touching_enemy() -> bool:
	for body in hit_area.get_overlapping_bodies():
		if body == weapon.player or !body.has_method("receive_damage") or body.is_dead: continue
		if !weapon.player.is_teammate(body): return true
	return false
