shader_type canvas_item;
#include "res://src/world/liquid_common.gdshaderinc"
// Water: translucent, lit by the lamps like everything else, a pale line on the surface.

void fragment() {
	float w = liquid_here(UV, 0, TIME);
	if (w == 0.0) discard;
	COLOR = w > 1.5 ? vec4(0.62, 0.8, 0.95, 0.85) : vec4(0.1, 0.28, 0.45, 0.58);
}
