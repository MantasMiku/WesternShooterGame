extends Node3D
## Effects on a player's body that everyone can see, driven by the player's synced status_flags:
##  - ON FIRE: flames + flickering orange light (Death Match underdog boost: double damage).
##  - HEALING: green sparkles rising (the Medic's heal-over-time / overheal).
##  - POISONED: sickly purple bubbles drifting up and dripping off the body (Medic's dart on an enemy).
## Hidden from the player's own camera (like the body), so it never blocks your view.
##
## Created by player_controller.gd as a child of the player. The player's `status_flags` integer
## is synced over the network to every peer; whenever it changes, the player calls set_status()
## here. So this script runs on EVERY peer (it's only visuals) and never decides anything itself -
## it just shows what the flags say. All particles and the light are built in code (no scene file).

## Colour of the flickering light while burning (warm orange).
const FIRE_LIGHT := Color(1.0, 0.5, 0.15)

var fire: CPUParticles3D     ## Big flame blobs around the body.
var embers: CPUParticles3D   ## A few small, fast sparks flying higher than the flames.
var light: OmniLight3D       ## Orange point light that lights up the surroundings while burning.
var heal: CPUParticles3D     ## Green sparkles rising from the feet while healing.
var poison: CPUParticles3D   ## Purple bubbles around the body while poisoned.
var _t := 0.0                # time counter for the light flicker


## Builds the particle emitters and the light, then starts with everything switched off.
func _ready() -> void:
	# Arguments of _make_particles: amount, lifetime, colour ramp, blob size, gravity, min/max speed.
	# Positive gravity (0, 3.2, 0) makes particles accelerate UPWARDS, like hot flames rising.
	# Flames lick up the outside of the body (the capsule is 0.5 m wide, so emit just outside it).
	fire = _make_particles(90, 0.65, [Color(1, 0.8, 0.3, 0.95), Color(1, 0.4, 0.05, 0.85), Color(0.3, 0.08, 0.03, 0.0)], 0.24, Vector3(0, 3.2, 0), 0.3, 0.8)
	_ring(fire, 0.58, 1.7)
	fire.position = Vector3(0, 0.9, 0)
	# Embers: few, tiny, longer-lived and faster, so they fly above the flames.
	embers = _make_particles(16, 1.1, [Color(1, 0.8, 0.3, 1), Color(1, 0.3, 0.05, 0)], 0.04, Vector3(0, 1.5, 0), 0.8, 2.2)
	_ring(embers, 0.65, 1.8)
	embers.position = Vector3(0, 1.0, 0)
	# Heal: a flat ring at the feet (height 0.1) whose sparkles float up the body.
	heal = _make_particles(28, 1.2, [Color(0.55, 1, 0.6, 0.95), Color(0.3, 1, 0.5, 0)], 0.07, Vector3(0, 1.4, 0), 0.3, 0.8)
	_ring(heal, 0.62, 0.1)
	heal.position = Vector3(0, 0.15, 0)
	# Poison: slow purple bubbles all over the body that bob up a little and then drip down.
	poison = _make_particles(36, 1.0, [Color(0.75, 0.35, 1.0, 0.95), Color(0.45, 0.85, 0.2, 0.8), Color(0.3, 0.1, 0.4, 0.0)], 0.06, Vector3(0, -1.2, 0), 0.4, 0.9)
	_ring(poison, 0.6, 1.6)
	poison.position = Vector3(0, 1.0, 0)
	light = OmniLight3D.new()
	light.light_color = FIRE_LIGHT
	light.omni_range = 4.0
	light.position = Vector3(0, 1.2, 0)
	light.visible = false
	for n in [fire, embers, heal, poison, light]: add_child(n)
	set_status(0)


## Bits: 1 = on fire, 2 = healing, 4 = poisoned.
## The flags are a bit field: several statuses fit in one int, and `flags & 1` checks just bit 1.
## (In GDScript `&` binds tighter than `!=`, so `flags & 1 != 0` means `(flags & 1) != 0`.)
func set_status(flags: int) -> void:
	var burning := flags & 1 != 0
	# Setting emitting = false lets the particles already in the air finish instead of vanishing.
	fire.emitting = burning
	embers.emitting = burning
	light.visible = burning
	heal.emitting = flags & 2 != 0
	poison.emitting = flags & 4 != 0


## Hide everything from one camera by moving it to a render layer that camera doesn't draw.
## The player calls this on its own (local) copy with the "own body" layer that the first-person
## camera excludes - other players' cameras still see the effects.
func hide_from_layer(layer_bit: int) -> void:
	for n in [fire, embers, heal, poison]: n.layers = layer_bit
	# Lights use a cull mask instead of layers: remove that bit so the light doesn't affect
	# objects on that layer (e.g. your own body glowing orange right in front of the camera).
	light.light_cull_mask &= ~layer_bit


## Makes the fire light flicker while it's on.
func _process(delta: float) -> void:
	if light.visible:
		_t += delta
		# Two sine waves at different speeds added together don't line up into a simple repeating
		# pattern, so the brightness wobbles irregularly (2.2 +/- 0.9) like real fire.
		light.light_energy = 2.2 + sin(_t * 23.0) * 0.5 + sin(_t * 9.0) * 0.4


# Emit from a ring (tube) around the body, `height` tall.
# The ring is 8 cm thick (inner radius = radius - 0.08), so particles start on the surface of a
# hollow cylinder around the player instead of inside the body.
func _ring(p: CPUParticles3D, radius: float, height: float) -> void:
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	p.emission_ring_axis = Vector3.UP
	p.emission_ring_radius = radius
	p.emission_ring_inner_radius = radius - 0.08
	p.emission_ring_height = height


# Builds one CPUParticles3D emitter. CPU particles (not GPU) are used because they are simple
# to set up in code and work on every renderer.
#  count / life      - how many particles exist at once and how long each lives (seconds)
#  colors            - colour over the particle's life, spread evenly (last one usually alpha 0 = fade out)
#  size              - radius of each little sphere
#  gravity           - constant acceleration (pointing up here, so particles rise)
#  vel_min / vel_max - random starting speed range
func _make_particles(count: int, life: float, colors: Array, size: float, gravity: Vector3,
		vel_min: float, vel_max: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = count
	p.lifetime = life
	p.emitting = false
	# World-space particles: once emitted they stay where they are in the world, so a running
	# player leaves a short trail of flames behind instead of dragging them along.
	p.local_coords = false
	# Shoot upward with up to 20 degrees of random spread.
	p.direction = Vector3.UP
	p.spread = 20.0
	p.initial_velocity_min = vel_min
	p.initial_velocity_max = vel_max
	p.gravity = gravity
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.3
	# Size over lifetime: starts at full size (1) and shrinks to 20% by the end.
	var curve := Curve.new()
	curve.add_point(Vector2(0, 1))
	curve.add_point(Vector2(1, 0.2))
	p.scale_amount_curve = curve
	# Colour over lifetime: place the given colours at evenly spaced points from 0 to 1
	# (e.g. 3 colours -> offsets 0, 0.5, 1).
	var grad := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for i in colors.size():
		offs.append(float(i) / (colors.size() - 1))
		cols.append(colors[i])
	grad.offsets = offs
	grad.colors = cols
	p.color_ramp = grad
	# Each particle is a very low-poly sphere (6 x 3 segments): cheap, and fits the low-poly style.
	var m := SphereMesh.new()
	m.radius = size
	m.height = size * 2.0
	m.radial_segments = 6
	m.rings = 3
	# Unshaded = the colour is shown as-is (glowing, not darkened by lighting). Alpha transparency
	# lets the fade-out work. vertex_color_use_as_albedo is REQUIRED for the color_ramp to show:
	# the particle system passes each particle's colour to the mesh as a vertex colour.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	m.material = mat
	p.mesh = m
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p
