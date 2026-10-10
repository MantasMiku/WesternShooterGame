extends Node
## Adds an outline to every MeshInstance3D under this node's parent.
## Usage: add a Node with this script as a child of anything (a player, a weapon, a prop,
## a whole level section) - on _ready it outlines all meshes below its parent.
## (For example Scenes/Player/player_controller.tscn has one, so every player is outlined.)
##
## How it works: for each mesh it builds a copy with smoothed normals (so flat-shaded
## low-poly models don't get gaps at corners) and draws it as a child "hull" with
## Shaders/outline.gdshader. The hull follows the original mesh's transform, visibility
## and render layers automatically.
##
## This is the "inverted hull" outline technique: draw a slightly fattened copy of the model
## in a solid dark colour, but only its BACK faces (front faces are culled). From the camera
## the fattened copy is hidden behind the real model everywhere except a thin rim around the
## silhouette - and that rim is the outline. The fattening (pushing vertices outward) happens
## in the shader; this script only prepares the mesh and the material.
##
## Runs on every peer that draws graphics (it's purely visual). Does nothing on a headless
## dedicated server.

## The shader that draws the hull (pushes vertices out and fills them with outline_color).
const OUTLINE_SHADER := preload("res://Shaders/outline.gdshader")
## Metadata tag put on hull nodes, so we can recognise them and never outline an outline.
const HULL_META := &"_outline_hull"

## Colour of the outline (a very dark brown by default, softer than pure black).
@export var outline_color := Color(0.06, 0.04, 0.03)
## Outline thickness in screen pixels (stays the same at any distance).
@export_range(0.0, 10.0, 0.1) var width_pixels := 2.0
## Skip meshes whose material is transparent (glass etc.) - outlines on them look odd.
@export var skip_transparent := false

# Smoothed copies are shared between all instances of the same mesh.
# Key: the original Mesh resource, value: its smoothed ArrayMesh. "static" means one dictionary
# for the whole game, so 8 players with the same model only build the hull mesh once.
static var _hull_cache := {}

# One material shared by every hull this node creates, so set_outline() updates them all at once.
var _material: ShaderMaterial


## Builds the outline material and adds a hull to every mesh found under the parent.
func _ready() -> void:
	# Dedicated servers run headless: nothing is drawn and mesh data isn't readable there.
	if DisplayServer.get_name() == "headless": return
	_material = ShaderMaterial.new()
	_material.shader = OUTLINE_SHADER
	_material.set_shader_parameter("outline_color", outline_color)
	_material.set_shader_parameter("outline_width", width_pixels)
	# find_children("*", type, recursive = true, owned = false): every MeshInstance3D below the
	# parent, including ones created by code (not saved in the scene), hence owned = false.
	for mi in get_parent().find_children("*", "MeshInstance3D", true, false):
		# Skip hulls themselves, empty mesh nodes, and meshes that already got a hull
		# (e.g. when two outline nodes cover the same meshes).
		if mi.has_meta(HULL_META) or mi.mesh == null: continue
		if _has_hull(mi): continue
		if skip_transparent and _is_transparent(mi): continue
		_add_hull(mi)


## Change colour/width at runtime (e.g. highlight a teammate).
func set_outline(color: Color, width: float) -> void:
	outline_color = color
	width_pixels = width
	# _material is null on a headless server, where there is nothing to update.
	if _material:
		_material.set_shader_parameter("outline_color", color)
		_material.set_shader_parameter("outline_width", width)


## Creates the hull MeshInstance3D for one mesh and adds it as that mesh's child.
func _add_hull(mi: MeshInstance3D) -> void:
	# Reuse the smoothed mesh if we already built one for this exact Mesh resource.
	var hull_mesh: ArrayMesh = _hull_cache.get(mi.mesh)
	if hull_mesh == null:
		hull_mesh = _build_smoothed_mesh(mi.mesh)
		_hull_cache[mi.mesh] = hull_mesh
	var hull := MeshInstance3D.new()
	hull.name = "OutlineHull"
	hull.mesh = hull_mesh
	hull.material_override = _material
	# Outlines should never cast shadows (they'd make every shadow fatter).
	hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Same render layers as the original: if a camera hides the mesh (e.g. your own body in
	# first person), it hides the outline too.
	hull.layers = mi.layers
	hull.set_meta(HULL_META, true)
	# As a CHILD of the mesh it automatically moves, rotates, scales and hides with it.
	mi.add_child(hull)


## True if this mesh node already has an outline hull child.
func _has_hull(mi: MeshInstance3D) -> bool:
	for c in mi.get_children():
		if c.has_meta(HULL_META): return true
	return false


## True if any surface of the mesh uses a transparent standard material.
func _is_transparent(mi: MeshInstance3D) -> bool:
	for i in mi.mesh.get_surface_count():
		# get_active_material gives the material actually used (override, surface override or mesh's own).
		var m = mi.get_active_material(i)
		if m is BaseMaterial3D and m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return true
	return false


# Copy of the mesh where every vertex's normal is the average of all normals at that
# position (across all surfaces). One surface per source surface, positions unchanged.
#
# Why: a flat-shaded (low-poly) cube really has 24 vertices - each corner exists 3 times, once
# per face, each with a different normal. Pushing those copies out along their own normals
# would tear the corner apart and leave gaps in the outline. Averaging the normals of all
# copies at the same position makes them all move the same way, so the hull stays closed.
static func _build_smoothed_mesh(mesh: Mesh) -> ArrayMesh:
	# Pass 1: add up the normals of all vertices that share a position.
	var sums := {}
	var surfaces := []
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		surfaces.append(arrays)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in verts.size():
			var k := _pos_key(verts[i])
			# Some meshes may have no normals at all; then this vertex adds nothing.
			sums[k] = sums.get(k, Vector3.ZERO) + (norms[i] if i < norms.size() else Vector3.ZERO)

	# Pass 2: build the new mesh using the averaged (normalized) normals. Only positions,
	# normals and indices are copied - the hull doesn't need UVs or colours (it's one solid colour).
	var out := ArrayMesh.new()
	for arrays in surfaces:
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var smooth := PackedVector3Array()
		smooth.resize(verts.size())
		for i in verts.size():
			var n: Vector3 = sums[_pos_key(verts[i])]
			# If the normals cancelled out (sum is ~zero, e.g. a paper-thin plane seen from both
			# sides) fall back to the original normal, or straight up if there is none.
			smooth[i] = n.normalized() if n.length_squared() > 0.000001 else (norms[i] if i < norms.size() else Vector3.UP)
		var hull_arrays := []
		hull_arrays.resize(Mesh.ARRAY_MAX)
		hull_arrays[Mesh.ARRAY_VERTEX] = verts
		hull_arrays[Mesh.ARRAY_NORMAL] = smooth
		hull_arrays[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, hull_arrays)
	return out


# Dictionary key for a vertex position. Rounding to 0.1 mm makes positions that are "the same"
# but differ by tiny floating-point errors land on the same key.
static func _pos_key(v: Vector3) -> Vector3:
	return v.snapped(Vector3.ONE * 0.0001)
