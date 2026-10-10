// Full-screen edge glow used by the HUD for "you got hit" (red) and "you got healed" (green).
// Applied to full-screen ColorRects (HurtVignette / HealVignette in the HUD, and a Vignette in the
// main menu). Scenes/UI/hud.gd gives each rect its own copy of the material and animates
// `intensity` every frame (a quick flash when hit or healed, a pulse at low health).
// Purely local UI - each player only sees their own.
shader_type canvas_item;

// Colour of the glow (red by default; the heal rect sets green).
uniform vec4 tint : source_color = vec4(0.75, 0.02, 0.0, 1.0);
// 0 = invisible, 1 = full strength. Driven by hud.gd.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float inner_radius = 0.28;   // clear area in the middle of the screen
uniform float outer_radius = 0.78;   // fully tinted at the corners

// Fragment stage: runs once per pixel of the ColorRect.
void fragment() {
	// UV goes 0..1 across the rect; subtracting 0.5 puts (0,0) at the screen centre.
	vec2 uv = UV - 0.5;
	// Distance from the centre: 0 in the middle, ~0.71 in the corners (sqrt(0.5^2 + 0.5^2)).
	float d = length(uv);
	// smoothstep: 0 inside inner_radius, 1 beyond outer_radius, a smooth S-curve in between.
	float edge = smoothstep(inner_radius, outer_radius, d);
	// Colour stays the tint everywhere; only the transparency changes, so the middle stays clear.
	COLOR = vec4(tint.rgb, tint.a * edge * intensity);
}
