shader_type sky;

uniform vec3  space_tint        = vec3(0.90, 0.96, 1.00);
uniform float star_density      : hint_range(0.0,1.0) = 0.15;   // 0 = none
uniform float star_cutoff       : hint_range(0.95,0.9999,0.0001) = 0.995; // baseline threshold
uniform float star_brightness   = 1.25;
uniform float twinkle_speed     = 0.35;
uniform float twinkle_amount    = 0.20;
uniform vec3  band_dir          = vec3(0.2, 0.4, 0.9);
uniform float band_strength     = 0.22;
uniform float horizon_fade      = 0.0;

float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

void sky() {
    // SKY_COORDS is vec2 → convert to 3D direction
    vec2 uv   = SKY_COORDS;
    float phi = uv.x * TAU;
    float th  = uv.y * PI;
    vec3 d = vec3(
        sin(th) * cos(phi),
        cos(th),
        sin(th) * sin(phi)
    );

    // Hash per coarse direction cell
    vec3 cell = floor(d * 1024.0);
    float h = hash13(cell);

    // ---- STAR DENSITY (binary gate; truly zero when star_density=0) ----
    // Interpolate a threshold between "almost 1" and star_cutoff.
    float thresh = mix(0.9999, star_cutoff, clamp(star_density, 0.0, 1.0));
    float star   = step(thresh, h);                 // 0 or 1
    float tw     = 1.0 + twinkle_amount * sin(h * 123.0 + TIME * TAU * twinkle_speed);
    vec3  col    = star * tw * star_brightness * space_tint;

    // Soft galactic band
    vec3 nband = normalize(band_dir);
    float band = pow(max(0.0, dot(nband, d)), 16.0) * band_strength;
    col += band * vec3(0.35, 0.55, 0.9);

    // Optional horizon fade
    if (horizon_fade > 0.0) {
        float hf = clamp((d.y + 0.05) * 8.0, 0.0, 1.0);
        col = mix(col, col * 0.3, vec3(hf * horizon_fade));
    }

    COLOR = col;   // sky shaders use vec3 COLOR
}
