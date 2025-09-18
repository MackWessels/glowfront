shader_type spatial;
render_mode cull_back, specular_disabled;

uniform vec3  base_color       : source_color = vec3(0.08, 0.10, 0.16); // dark body
uniform float mid_boost                          = 0.35;   // mid band lift
uniform float highlight_boost                    = 0.65;   // bright band lift

uniform vec3  rim_color        : source_color = vec3(0.70, 0.20, 1.00); // neon rim
uniform float rim_intensity                       = 2.5;    // >1 to bloom (enable Glow)
uniform float rim_width                           = 0.35;   // 0..1
uniform float rim_power                           = 2.0;    // higher = thinner rim

// Optional “panel” banding to break up big faces (no textures)
uniform float band_strength                        = 0.0;    // 0 disables
uniform float band_scale                           = 1.0;    // local-space frequency

// Pass LOCAL vertex position to fragment (simple & robust)
varying vec3 v_local_pos;

void vertex() {
    v_local_pos = VERTEX;
}

void fragment() {
    // Base body color (keep faces dark to hide lack of textures)
    ALBEDO = base_color;

    // Optional local-space banding
    if (band_strength > 0.0) {
        float bands = sin(v_local_pos.x * 3.14159 * band_scale) *
                      sin(v_local_pos.z * 3.14159 * band_scale);
        float mask = smoothstep(0.6, 1.0, abs(bands));
        ALBEDO = mix(ALBEDO, ALBEDO * 0.8, mask * band_strength);
    }

    // View-dependent rim as emission (for glow)
    vec3 N = normalize(NORMAL);
    vec3 V = normalize(-VIEW);
    float fres = pow(1.0 - max(dot(N, V), 0.0), rim_power);
    float rim  = smoothstep(1.0 - rim_width, 1.0, fres);
    EMISSION = rim_color * rim * rim_intensity;
}

// Per-light toon bands (works with Directional/Omni/Spot)
void light() {
    vec3 N = normalize(NORMAL);
    vec3 L = normalize(LIGHT);      // per-light direction or vector
    float ndl = max(dot(N, L), 0.0);

    // Three hard bands
    float dark_band  = step(ndl, 0.30);
    float mid_band   = step(0.30, ndl) * step(ndl, 0.70);
    float light_band = step(0.70, ndl);

    // Compose band color (kept dark overall)
    vec3 band_col = base_color * (0.20 * dark_band);
    band_col += base_color * (0.20 + mid_boost)      * mid_band;
    band_col += base_color * (0.20 + highlight_boost)* light_band;

    // Respect light color & engine attenuation (includes shadowing in 4.x)
    DIFFUSE_LIGHT += band_col * LIGHT_COLOR.rgb * ATTENUATION;

    // No specular for a flat comic look
}
