shader_type canvas_item;
render_mode unshaded, blend_add;
#include "res://src/world/terrain_common.gdshaderinc"
// The glowing bits of crystal and magma rock (crystal facets, hot cracks), drawn on the bloom
// layer over the same chunk as terrain.gdshader, using the same shape and material picking.

uniform sampler2D g_crystal : filter_nearest, repeat_enable;
uniform sampler2D g_magma : filter_nearest, repeat_enable;
uniform sampler2D g_floor : filter_nearest, repeat_enable;
uniform sampler2D g_ice : filter_nearest, repeat_enable;

void fragment() {
	vec2 local = floor(UV * cells * cell_px) + 0.5;
	vec2 wp = origin + local;
	vec4 s = texture(fill_map, fuv(local));
	COLOR = vec4(0.0);
	if (s.r >= 0.5) {
		int mat = pick_mat(local, wp);
		vec2 tuv = wp / 128.0;
		vec4 g = vec4(0.0);
		if (mat == 4) { g = texture(g_crystal, tuv) * vec4(1.4, 1.2, 2.0, 1.0); }
		else if (mat == 5) {
			float pulse = 0.75 + 0.25 * sin(TIME * 1.7 + wp.x * 0.05 + wp.y * 0.03);
			g = texture(g_magma, tuv) * vec4(2.2, 1.2, 0.5, 1.0) * pulse;
		} else if (mat == 6) {          // the Floor's glyphs breathe slowly
			g = texture(g_floor, tuv) * vec4(1.3, 1.2, 2.0, 1.0) * (0.6 + 0.4 * sin(TIME * 0.8 + wp.x * 0.01));
		} else if (mat == 7) {          // a faint cold light inside the ice
			g = texture(g_ice, tuv) * vec4(0.6, 1.0, 1.4, 1.0) * 0.7;
		}
		COLOR = vec4(g.rgb * g.a * (1.0 - s.g * 0.6), 1.0);   // dimmer deep inside the rock
	}
}
