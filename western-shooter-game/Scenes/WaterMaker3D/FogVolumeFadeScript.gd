extends FogVolume
## Underwater fog volume (child of a WaterMaker3D water body, see WaterMaker3D.gd).
## Every frame it tells its FogFade.gdshader material where a "fade plane" is: an invisible wall
## facing the same way as the camera, `fade_distance` metres in front of it. The shader removes
## all fog between the camera and that plane, so the water right in front of you stays clear
## and the fog only builds up further away. Purely visual; runs on every peer for its own camera.

## How far in front of the camera (metres) the fog starts. WaterMaker3D.gd overwrites this
## every frame with its fog_fade_dist. (Declared as an int, so decimals get cut off.)
@export var fade_distance := 5

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	var cam = get_viewport().get_camera_3d() if get_viewport() else null
	if cam:
		# The camera looks along its -Z axis, so -basis.z is "forward" = the plane's normal.
		var fade_plane_normal = cam.global_transform.basis.z * -1
		# A point on the plane: start at the camera and go fade_distance metres forward.
		var fade_plane_pos = cam.global_transform.origin + cam.global_transform.basis.z * -fade_distance
		# A plane can be stored as (normal, d) where d = dot(any point on it, normal) is its
		# signed distance from the world origin. That fits in one Vector4: (nx, ny, nz, d).
		var fade_plane_distance = fade_plane_pos.dot(fade_plane_normal)
		var fade_plane = Vector4(fade_plane_normal.x, fade_plane_normal.y, fade_plane_normal.z, fade_plane_distance)
		self.material.set_shader_parameter("fade_plane", fade_plane)
