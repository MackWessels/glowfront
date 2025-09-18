shader_type spatial;
render_mode unshaded, cull_back;

/* Brighter defaults */
uniform vec3  color : source_color = vec3(1.0, 1.0, 1.0);  // pure white
uniform float glow  = 4.0;   // strong emission (drives bloom)
uniform float albedo_boost = 1; // makes lines visible even without Glow

void fragment() {
    ALBEDO   = color * albedo_boost;
    EMISSION = color * glow;
}
