extends Node
## Holds a player's weapons and handles switching, firing and reloading.
##
## Add weapons as child nodes (scripts that extend weapon.gd). Child order = slot order:
## first child is slot 1, second is slot 2, ...
## Controls: 1/2/3... or mouse wheel to switch, left click to attack, R to reload.
##
## This node must be a direct child of the player (player_controller.gd or a class script
## like the Sheriff's). The player calls try_primary_fire() when you click; the HUD listens
## to weapon_changed / weapon_status_changed.
##
## [b]Multiplayer:[/b] this node has the same multiplayer authority as its player. Input,
## firing and reloading only run on that peer. Weapon switches and attack/reload visuals
## are sent to every peer with RPCs ([method _sync_equip], [method _sync_visual]) so other
## players see which weapon you hold and see it fire.

## Emitted (on every peer) after switching weapons. The HUD uses it to show the new weapon.
signal weapon_changed(weapon: Node)
signal weapon_status_changed(weapon: Node)   ## Current weapon's HUD info changed (ammo etc).

## Number keys 1-9, so at most 9 weapons get a key.
const MAX_SLOTS := 9

## The player that owns these weapons (our parent node).
var player: CharacterBody3D
## The weapon nodes, in slot order (filled in _ready()).
var weapons: Array[Node] = []
## Index into `weapons` of the weapon in your hands (-1 = none yet).
var current_index := -1
## Set when the player asked to attack; the actual attack happens in the next _physics_process.
var _fire_requested := false


## Finds the weapon children, hooks them up and makes sure the keys 1..9 and R exist.
## Runs on every peer (every peer needs the weapon nodes for the visuals).
func _ready() -> void:
	player = get_parent()
	for child in get_children():
		# Anything with try_fire() counts as a weapon (other child nodes are ignored).
		if child.has_method("try_fire"):
			weapons.append(child)
			child.setup(player, self)
			child.unequip()
			# .bind(child) adds the weapon as an extra argument, so one handler can tell
			# which weapon's ammo changed.
			child.status_changed.connect(_on_weapon_status_changed.bind(child))

	# Create input actions "weapon_1", "weapon_2"... mapped to the number keys.
	for i in mini(weapons.size(), MAX_SLOTS):
		_ensure_key_action("weapon_%d" % (i + 1), KEY_1 + i)
	_ensure_key_action("reload", KEY_R)

	# Start holding the first weapon.
	if !weapons.is_empty():
		_equip(0)


## Every physics frame on the owner's peer: tick all weapons (cooldowns, reload timers),
## handle holding the button for automatic fire, and attack if requested.
func _physics_process(delta: float) -> void:
	# Only the peer that controls this player runs weapon logic. Other peers just show visuals.
	if !is_multiplayer_authority(): return
	for w in weapons:
		w.tick(delta)
	# Automatic weapons keep firing while the button is held.
	# Not for bots (they request attacks themselves), not while a menu is open (mouse not
	# captured), and not while input is disabled, frozen or dead.
	var held := get_current_weapon()
	if held and held.automatic and !player.is_bot and player.input_enabled and !player.frozen and !player.is_dead \
			and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED and Input.is_action_pressed("shoot"):
		_fire_requested = true
	# Attacks are processed here (not in input callbacks) so physics queries are safe.
	# Godot only allows ray casts / shape queries on the physics space during the physics
	# step; doing them from _input could read out-of-date physics data or error out.
	# Holding the button just keeps requesting - the weapon's cooldown limits the fire rate.
	if _fire_requested:
		_fire_requested = false
		var w := get_current_weapon()
		if w: w.try_fire()


## Keyboard/mouse input for switching and reloading (owner's peer only, humans only).
## _unhandled_input means UI elements (menus, chat) get the event first.
func _unhandled_input(event: InputEvent) -> void:
	if !is_multiplayer_authority() or player.is_bot or !player.input_enabled: return

	# Number keys pick a slot directly.
	for i in mini(weapons.size(), MAX_SLOTS):
		if event.is_action_pressed("weapon_%d" % (i + 1)):
			select_weapon(i)
			return

	if event.is_action_pressed("reload"):
		var w := get_current_weapon()
		if w: w.try_reload()
		return

	# Mouse wheel cycles weapons (but not while noclipping, where the wheel sets fly speed).
	# wrapi() wraps around: scrolling past the last slot goes back to the first one.
	if event is InputEventMouseButton and event.pressed and !player.no_clip and weapons.size() > 1:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			select_weapon(wrapi(current_index - 1, 0, weapons.size()))
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			select_weapon(wrapi(current_index + 1, 0, weapons.size()))


## Respawn: full ammo on every weapon and back to slot 1.
## Called on the player's own peer; the switch back to slot 1 is sent to everyone.
func reset_all() -> void:
	_fire_requested = false
	for w in weapons: w.reset()
	if current_index != 0 and !weapons.is_empty():
		_sync_equip.rpc(0)
	elif !weapons.is_empty():
		# Already on slot 1: just refresh the HUD (the ammo was refilled).
		weapon_status_changed.emit(weapons[0])


## Ammo pickup: gives every weapon `fraction` (0..1) of its starting spare ammo.
func add_ammo_fraction(fraction: float) -> void:
	for w in weapons: w.add_ammo_fraction(fraction)


## Called by the player's _primary_fire(). The attack happens on the next physics frame.
## (Bots go through the same path, so they obey the same cooldowns and ammo.)
func try_primary_fire() -> void:
	_fire_requested = true


## The weapon in your hands, or null if there are no weapons.
func get_current_weapon() -> Node:
	return weapons[current_index] if current_index >= 0 and current_index < weapons.size() else null


## Switch to slot `index` (0-based). Ignores invalid slots and the slot you already hold.
## Sends the switch to every peer so everyone sees the new weapon.
func select_weapon(index: int) -> void:
	if index == current_index or index < 0 or index >= weapons.size(): return
	_sync_equip.rpc(index)


## Weapons call these to play their effects on every peer.
## We send the weapon's slot number (a node can't be sent over the network) plus a
## "kind": 0 = attack, 1 = reload.
func broadcast_attack_visual(weapon: Node) -> void:
	_sync_visual.rpc(weapons.find(weapon), 0)

## Like broadcast_attack_visual(), but plays the reload animation everywhere.
func broadcast_reload_visual(weapon: Node) -> void:
	_sync_visual.rpc(weapons.find(weapon), 1)


## Network message: "this player now holds weapon `index`".
## "authority" = only the owner of this player may send it (nobody can switch someone
## else's weapon). "call_local" = it also runs on the sender's own machine.
## "reliable" = guaranteed to arrive, in order (a lost switch would leave the wrong weapon
## showing forever).
@rpc("authority", "call_local", "reliable")
func _sync_equip(index: int) -> void:
	_equip(index)


## Network message: play weapon `index`'s attack (kind 0) or reload (kind 1) animation.
## "unreliable_ordered" = fast, may be dropped, late packets are thrown away. Fine for
## cosmetics - if one recoil animation gets lost, nobody notices.
@rpc("authority", "call_local", "unreliable_ordered")
func _sync_visual(index: int, kind: int) -> void:
	if index < 0 or index >= weapons.size(): return
	if kind == 0: weapons[index].play_attack_visual()
	else: weapons[index].play_reload_visual()


## Does the actual switch on this peer: put the old weapon away, take the new one out,
## and tell the HUD.
func _equip(index: int) -> void:
	var old := get_current_weapon()
	if old: old.unequip()
	current_index = index
	weapons[index].equip()
	weapon_changed.emit(weapons[index])
	weapon_status_changed.emit(weapons[index])


## A weapon's HUD info changed. Only pass it on if it's the weapon in your hands
## (a holstered gun refilling in the background shouldn't overwrite the ammo display).
func _on_weapon_status_changed(weapon: Node) -> void:
	if weapon == get_current_weapon():
		weapon_status_changed.emit(weapon)


# Registers a default key for an input action if the project doesn't define it yet.
# You can override these in Project Settings > Input Map by adding actions with the same name.
# physical_keycode = the key's position on the keyboard, so it works on any keyboard layout.
func _ensure_key_action(action: StringName, keycode: Key) -> void:
	if InputMap.has_action(action): return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)
