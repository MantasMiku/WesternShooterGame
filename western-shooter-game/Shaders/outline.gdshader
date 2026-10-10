// Inverted-hull outline.
// Draws the back faces of a mesh pushed outward along its normals, in a solid colour.
// Width is in screen pixels, so outlines stay the same thickness at any distance.
// Use it through Scripts/Effects/outline.gd, which also smooths the normals so
// flat-shaded (low-poly) models don't get gaps at their corners.
//
// Why this gives an outline: the hull is a slightly "inflated" copy of the model. Because only
// its BACK faces are drawn (cull_front), the inflated shell never covers the model's front -
// the real model is in front of it and wins the depth test. The only part of the shell left
// visible is the thin rim that sticks out past the model's silhouette: that rim is the outline.
// Runs on the GPU of every peer that renders (purely visual).
shader_type spatial;
// unshaded          - no lighting, the outline is one flat colour.
// cull_front        - skip front-facing triangles, draw only the back faces (the "inverted" hull).
// depth_draw_opaque - write depth like a normal solid object.
// shadows_disabled / fog_disabled - outlines don't receive shadows and aren't tinted by fog.
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled, fog_disabled;

// Colour of the outline (set from outline.gd). source_color = treated as an sRGB colour in the editor.
uniform vec4 outline_color : source_color = vec4(0.06, 0.04, 0.03, 1.0);
uniform float outline_width : hint_range(0.0, 10.0) = 2.0; // pixels

// Vertex stage: runs once per vertex. Instead of pushing the vertex out in 3D (which would make
// far-away outlines thin and close ones thick), we push it out on the SCREEN by a fixed number of pixels.
void vertex() {
	// The vertex's normal position on screen, in clip space (before the perspective divide).
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	// The (smoothed) normal turned into view space (relative to the camera).
	vec3 view_normal = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	// Project the normal as a direction (w = 0, so it isn't moved, only turned) to find which way
	// "outward" points on the screen. Only x/y matter: that's the 2D screen direction.
	vec2 screen_dir = (PROJECTION_MATRIX * vec4(view_normal, 0.0)).xy;
	float len = length(screen_dir);
	// If the normal points straight at/away from the camera there's no sideways direction to push in.
	if (len > 0.0001) {
		screen_dir /= len;
		// Pixels -> normalized device coords (x2 because NDC spans -1..1), then undo the perspective divide.
		// The GPU later divides clip.xy by clip.w; multiplying by clip.w here cancels that,
		// so the push is exactly outline_width pixels no matter how far away the vertex is.
		clip.xy += screen_dir * outline_width * 2.0 / VIEWPORT_SIZE * clip.w;
	}
	// Writing POSITION directly tells Godot we've already done the full projection ourselves.
	POSITION = clip;
}

// Fragment stage: runs once per pixel of the hull. Just paint the flat outline colour.
void fragment() {
	ALBEDO = outline_color.rgb;
}
