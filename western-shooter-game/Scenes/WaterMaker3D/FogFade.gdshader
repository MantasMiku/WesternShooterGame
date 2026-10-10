// Fog shader for the underwater FogVolume of a WaterMaker3D water body.
// A "fog" shader runs inside a FogVolume for each point (froxel) of Godot's volumetric fog and
// says how thick (DENSITY) and what colour (ALBEDO / EMISSION) the fog is there. Volumetric fog
// must be enabled in the WorldEnvironment for it to show. Purely visual, rendered on each peer.
//
// The first part copies what Godot's built-in FogMaterial does (density, height falloff, 3D
// texture, soft edges). The extra part is the "fade plane": FogVolumeFadeScript.gd puts a plane a
// few metres in front of the camera and all fog between the camera and that plane is removed.
shader_type fog;

// Overall fog thickness.
uniform float density : hint_range(0, 1, 0.0001) = 1.0;
// Fog colour (how it scatters light). Its alpha is also used as an extra density multiplier.
uniform vec4 albedo : source_color = vec4(1.0);
// Light the fog gives off by itself (WaterMaker3D sets it to the fog colour so it's visible in the dark).
uniform vec4 emission : source_color = vec4(0, 0, 0, 1);
// > 0 makes the fog thinner higher up in the volume (0 = same everywhere).
uniform float height_falloff = 0.0;
// Softness of the volume's edges: higher = fades out more toward the edges. WaterMaker3D switches
// it between 0.1 (camera underwater: thick everywhere) and 1.1 (camera outside: soft edges).
uniform float edge_fade = 0.1;
// Optional 3D noise texture to make the fog patchy (white = no change).
uniform sampler3D density_texture: hint_default_white;
// The fade plane as (normal.xyz, distance from world origin). The default (normal up, at
// y = -999) is far below everything, so nothing is faded until the script sets a real value.
uniform vec4 fade_plane = vec4(0., 1., 0., -999.);

void fog() {
	// Height falloff: exp2(-k * height above the volume's centre) halves the density for every
	// 1/k metres you go up (clamped so it never gets thicker than `density`).
	DENSITY = density * clamp(exp2(-height_falloff * (WORLD_POSITION.y - OBJECT_POSITION.y)), 0.0, 1.0);
	// Patchiness from the 3D texture (UVW = position inside the volume, 0..1 on each axis).
	DENSITY *= texture(density_texture, UVW).r;
	// Soft edges. SDF is the signed distance to the volume's surface (negative inside). Dividing by
	// half the smallest side gives 0 at the edge -> 1 at the middle; pow(.., edge_fade) shapes the curve.
	DENSITY *= pow(clamp(-2.0 * SDF / min(min(SIZE.x, SIZE.y), SIZE.z), 0.0, 1.0), edge_fade);
	ALBEDO = albedo.rgb;
	EMISSION = emission.rgb;

	// Anything above the fade plane will be drawn. Anything below has its density set to 0.
	// ("Above" = on the side the normal points to, i.e. further from the camera than the plane.)
	float fade_sharpness = 0.35; // Higher is faster fade
	// normal * d is the point on the plane closest to the world origin - any point on it works.
	vec3 fade_plane_origin = fade_plane.xyz * fade_plane.w;
	vec3 pos_rel_to_plane = WORLD_POSITION - fade_plane_origin;
	// dot(..., normal) = signed distance from the plane. Negative (camera side) -> 0, then it
	// ramps up to 1 over 1 / 0.35 = about 2.9 m beyond the plane, so the fog fades in smoothly.
	float fade_mult = max(0., min(1., dot(pos_rel_to_plane, fade_plane.xyz) * fade_sharpness));
	DENSITY *= fade_mult * albedo.a;
}
