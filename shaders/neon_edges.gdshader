shader_type spatial;
render_mode unshaded, cull_back;

uniform vec3  color : source_color = vec3(0.10, 0.90, 1.00);
uniform float glow  = 2.2;   // >1 so Environment->Glow blooms

void fragment() {
    ALBEDO   = color * 0.05;   // faint base so MSAA edges aren't pure black
    EMISSION = color * glow;
}
