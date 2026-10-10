extends "res://Scenes/Player/player_controller.gd"
class_name Sheriff

## Sheriff class (Defense / Offense).
## - 200 HP, slow (from the design doc).
## - Weapons (see the WeaponManager node in sheriff.tscn):
##     1: Winchester 1873 - lever-action rifle, 14 rounds, accurate at mid/long range.
##     2: Winchester 1897 - pump shotgun, 5 shells, close to mid range.
##     3: Bat            - melee (stand-in for brass knuckles until a model exists).
##   Both guns reload one round at a time (R), and you can fire mid-reload.
## Movement and weapon handling come from PlayerController + WeaponManager.
## Add Sheriff-only abilities here later.
##
## Used on the root node of Scenes/Sheriff/sheriff.tscn. This script has no code of its own yet:
## everything is inherited from player_controller.gd ("extends"). The class's differences
## (200 HP, slower speed, its weapons) are just values and nodes set in sheriff.tscn.
## Having its own script and class_name still lets other code check "if player is Sheriff".
