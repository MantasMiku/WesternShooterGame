extends "res://Scenes/Player/player_controller.gd"
class_name Bomber

## Bomber class (Defense) - a miner from the 1890s with a belt full of dynamite.
## - 125 HP, medium speed (from the design doc).
## - Weapons (see the WeaponManager node in bomber.tscn):
##     1: Dynamite       - thrown in an arc, explodes after a short fuse or on touching an enemy.
##                         Area damage, blocked by walls. 4 sticks ready + 16 spare (20 total).
##                         Your own blast hurts you a little but throws you far: throw one at your
##                         feet and jump to launch yourself into the air.
##     2: Revolver rifle - 6-shot revolving rifle, good at mid range.
##     3: Pickaxe        - slow but hits hard.
## - Passive: blows up when he dies, damaging enemies around him.
##
## Used on the root node of Scenes/Bomber/bomber.tscn. Inherits all movement and health from
## player_controller.gd and adds the death blast.
## Multiplayer: the blast's damage is worked out on the Bomber's owner peer (where `died` fires);
## the damage itself is sent to each victim's owner by Explosion.apply_damage, and the
## explosion visual is shown on every peer through the _death_blast_visual RPC.

## Shared explosion code (damage falloff, wall checks, knockback and the visual effect).
const Explosion = preload("res://Scripts/Weapons/explosion.gd")

@export_group("Death Blast")   # foldable "Death Blast" header in the Inspector
@export var death_blast_radius := 4.0       ## Metres.
@export var death_blast_damage := 70        ## At the centre...
@export var death_blast_min_damage := 20    ## ...fading to this at the edge.

var _blast_at = null   # position of a death blast waiting for the next physics frame


## Runs PlayerController's _ready() (super), then listens to our own `died` signal.
func _ready() -> void:
	super()
	died.connect(_on_died)


## Called when this Bomber dies (through the `died` signal).
func _on_died(_killer_id: int) -> void:
	# died fires on this player's own peer. Physics queries are only safe in _physics_process,
	# so remember where we died and blow up on the next physics frame.
	# (+0.6 m up = roughly the middle of the body, so the floor doesn't block the blast.)
	if is_multiplayer_authority():
		_blast_at = global_position + Vector3.UP * 0.6


## Normal player physics (super), then set off a death blast if one is waiting.
func _physics_process(delta: float) -> void:
	super(delta)
	if _blast_at != null and is_multiplayer_authority():
		var pos: Vector3 = _blast_at
		_blast_at = null   # clear first so it only explodes once
		# Damage everyone in range (with falloff and knockback), but not the dead Bomber himself.
		Explosion.apply_damage(self, pos, {
			"radius": death_blast_radius, "max_damage": death_blast_damage,
			"min_damage": death_blast_min_damage, "knockback": 7.0, "hurt_self": false, "weapon": "Death blast",
		})
		_death_blast_visual.rpc(pos)


## Shows the explosion effect on every peer.
## @rpc("authority", "call_local", "reliable"): only the owner may send it, it also runs on the
## owner's own computer, and it is guaranteed to arrive.
@rpc("authority", "call_local", "reliable")
func _death_blast_visual(pos: Vector3) -> void:
	Explosion.spawn_effect(get_parent(), pos, death_blast_radius)
