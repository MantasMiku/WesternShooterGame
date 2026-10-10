@tool
extends CSGBox3D
## Water body helper (an older add-on-style script that came with the project's water scenes).
## Attach it to a CSGBox3D: the box IS the water. Resize the box and everything else follows.
##
## It expects these child nodes, marked "Access as Unique Name" (that's what the % in %Name means):
##  - %CollisionShape3D      box shape (inside %SwimmableArea3D) - resized to match the water box.
##  - %SwimmableArea3D       an Area3D covering the water (used to tell if the camera is underwater).
##  - %CameraPosShapeCast3D  a ShapeCast3D that is moved to the camera to test for that area.
##  - %FogVolume             a FogVolume with FogVolumeFadeScript.gd + FogFade.gdshader:
##                           the murky fog you see inside the water.
##  - %WaterRippleOverlay    a full-screen overlay using CameraWaterOverlay.gdshader
##                           (wobbly, blurry view), shown only while the camera is underwater.
##
## What it does every frame:
##  1. keeps the collision shape and the fog volume the same size as the box,
##  2. scrolls the water surface texture (only in the running game, not in the editor),
##  3. pushes the colour settings into the materials,
##  4. checks if the active camera is underwater and switches the underwater look on/off.
##
## @tool means this script also runs inside the Godot editor, so colour/size changes are
## visible immediately while building the level. It is purely visual and local: each peer
## checks its own camera.

## How fast the surface texture slides (UV units per second) - makes the water look like it flows.
@export var water_texture_move_speed := Vector3(0.0025, 0.0025, 0.0025)
## Texture tiling: smaller numbers = bigger texture pattern on the water.
@export var water_texture_uv_scale := 0.04
## Surface colour; the alpha (0.39) makes the water see-through.
@export var water_color := Color(0.3098039329052, 0.54117649793625, 0.86666667461395, 0.38823530077934)
## Colour of the underwater fog (dark blue). Used for both fog albedo and emission.
@export var fog_color := Color(0, 0.04313725605607, 0.15686275064945)
## Distance in front of the camera (metres) that stays clear of fog - see FogVolumeFadeScript.gd.
@export_range(0.0, 250.0) var fog_fade_dist := 5.0

## Frame number when some water body last showed the underwater overlay. "static" = shared by
## ALL water bodies, so if two overlap only the first one that notices the camera draws the effect.
static var last_frame_drew_underwater_effect : int = -999

## Sets a very high process priority so this water's _process runs after other nodes.
func _ready():
	self.process_priority = 999 # Call _process last to update move after any camera movement

# Checks the current camera against the water's area to see if it is inside the water.
# Returns true if the active camera is inside this water body (and no other water body already
# drew the underwater effect this frame). Two steps: a cheap box (AABB) test first, then an exact
# test with the shape cast against the SwimmableArea3D.
func should_draw_camera_underwater_effect():
	var camera := get_viewport().get_camera_3d() if get_viewport() else null
	if not camera: return false
	# Quick reject: is the camera inside the box's bounds (grown by 2.5 cm), in world space?
	var aabb = self.global_transform * self.get_aabb().grow(0.025)
	if not aabb.has_point(camera.global_position): return false
	# Don't draw multiple overlays at once, incase 2 water bodies overlap
	if last_frame_drew_underwater_effect == Engine.get_process_frames(): return false

	# Exact test: move the shape cast to the camera and ask what it overlaps right now
	# (force_shapecast_update runs the query immediately instead of waiting for the physics step).
	%CameraPosShapeCast3D.global_position = camera.global_position
	%CameraPosShapeCast3D.force_shapecast_update()
	# (This variable is never used - left over from an earlier version.)
	var camera_is_in_water_area3d := false
	for i in %CameraPosShapeCast3D.get_collision_count():
		if %CameraPosShapeCast3D.get_collider(i) == %SwimmableArea3D:
			return true
	return false

## Keeps the collision box the same size as the water box. (Despite the name, it doesn't touch the mesh.)
func _update_mesh():
	if get_node_or_null("%CollisionShape3D"):
		%CollisionShape3D.shape.size = self.size

## Runs every frame, in the editor too (because of @tool).
func _process(delta):
	_update_mesh()
	# Only if the box uses a StandardMaterial3D (the water surface material).
	if self.material is StandardMaterial3D:
		# Scroll the texture over time - only in game, so the editor view stays still.
		if not Engine.is_editor_hint():
			self.material.uv1_offset += water_texture_move_speed * delta
		self.material.uv1_scale = Vector3(water_texture_uv_scale,water_texture_uv_scale,water_texture_uv_scale)
		self.material.albedo_color = water_color
	# Keep the fog's colour and size in sync with this water body.
	%FogVolume.material.set_shader_parameter("albedo", fog_color)
	%FogVolume.material.set_shader_parameter("emission", fog_color)
	%FogVolume.size = self.size
	%FogVolume.fade_distance = self.fog_fade_dist
	if not Engine.is_editor_hint():
		if should_draw_camera_underwater_effect():
			# Underwater: show the wobbly overlay. edge_fade 0.1 makes the fog almost fully
			# dense right up to the box edges (pow(x, 0.1) is close to 1), so you're surrounded by it.
			%WaterRippleOverlay.visible = true
			%FogVolume.material.set_shader_parameter("edge_fade", 0.1)
			last_frame_drew_underwater_effect = Engine.get_process_frames()
		else:
			# Above water: no overlay, and edge_fade 1.1 fades the fog out softly toward the
			# box edges, so the water doesn't look like a solid blue block from outside.
			%WaterRippleOverlay.visible = false
			%FogVolume.material.set_shader_parameter("edge_fade", 1.1)
