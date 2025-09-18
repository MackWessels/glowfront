shader_type spatial;
render_mode unshaded, cull_front; // draw backfaces only → silhouette hull

uniform vec3  outline_color : source_color = vec3(0.10, 0.90, 1.00);
uniform float outline_width                 = 0.02;   // world-ish units (scales with node)
uniform float outline_glow                  = 2.2;    // >1 so Glow blooms

void vertex() {
    // Expand mesh slightly along normals to form the outline hull
    VERTEX += NORMAL * outline_width;
}

void fragment() {
    // Tiny albedo so MSAA edges aren’t 100% black
    ALBEDO   = outline_color * 0.05;
    EMISSION = outline_color * outline_glow;
}
