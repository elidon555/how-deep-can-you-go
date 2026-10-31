shader_type canvas_item;
render_mode unshaded;
#include "res://src/world/liquid_common.gdshaderinc"
// Lava: glowing (unshaded, bright enough to bloom), slowly churning, a hot crust on top.

void fragment() {
	float l = liquid_here(UV, 1, TIME);
	if (l == 0.0) discard;
	vec2 p = floor(UV * cells * cell_px) + origin;
	float churn = 0.75 + 0.25 * sin(TIME * 1.3 + p.x * 0.11 + sin(p.y * 0.17 + TIME));
	COLOR = l > 1.5 ? vec4(3.0, 1.7, 0.5, 1.0) : vec4(2.1, 0.55, 0.12, 1.0) * churn;
	COLOR.a = 1.0;
}
