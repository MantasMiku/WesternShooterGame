// Underwater screen effect (used by the %WaterRippleOverlay full-screen node of a WaterMaker3D
// water body; WaterMaker3D.gd shows it only while the camera is underwater).
// It takes the already-rendered picture of the screen, makes it swirl/wobble around the centre
// and blurs it slightly - like looking through moving water. Purely visual, local to each player.
shader_type canvas_item;

// A copy of everything drawn on screen so far (hint_screen_texture), so we can distort it.
uniform sampler2D screen_texture : hint_screen_texture;

// Fragment stage: runs once per screen pixel.
void fragment() {
    // Where this pixel is on the screen, 0..1 in x and y.
    vec2 uv = SCREEN_UV;

    // Ripple effect
    // rippleSpeed: how fast the pattern spins, rippleDensity: number of wobbles around the circle,
    // rippleStrength: how far pixels get pushed (in screen fractions, at full distance).
    float rippleSpeed = 1.5;
    float rippleDensity = 10.0;
    float rippleStrength = 0.02;

    // Calculate angle and distance from the center of the screen
    // (polar coordinates: atan gives the angle around the centre, length the distance from it).
    vec2 center = vec2(0.5, 0.5);
    vec2 delta = uv - center;
    float distance = length(delta);
    float angle = atan(delta.y, delta.x);

    // Apply the ripple effect
    // cos/sin of (angle * 10 + time) push each pixel a little in a direction that changes 10 times
    // around the circle and slowly rotates over time. Multiplying by `distance` keeps the middle
    // of the screen steady and makes the edges wobble most.
    uv.x += cos(angle * rippleDensity + TIME * rippleSpeed) * rippleStrength * distance;
    uv.y += sin(angle * rippleDensity + TIME * rippleSpeed) * rippleStrength * distance;

    // Simple blur effect
    // Box blur: average a 5 x 5 grid of samples (x and y from -2 to 2) around the rippled position.
    vec4 color = vec4(0.0);
    float total = 0.0;
    for (float x = -2.0; x <= 2.0; x++) {
        for (float y = -2.0; y <= 2.0; y++) {
            vec2 samplePos = uv + vec2(x, y) * 0.001; // Blur radius
            color += texture(screen_texture, samplePos);
            total += 1.0;
        }
    }
    // Sum of 25 samples / 25 = the average colour.
    color /= total;

    // Output the final color
    COLOR = color;
}
