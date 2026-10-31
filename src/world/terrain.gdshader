shader_type canvas_item;
#include "res://src/world/terrain_common.gdshaderinc"
// Smooth terrain: the dig grid (fill_map, bilinear) becomes an organic contour.
// Distance to the edge drives outline, mossy/lit top lips, dark undersides, bevels.

uniform sampler2D t_dirt : filter_nearest, repeat_enable;
uniform sampler2D t_stone : filter_nearest, repeat_enable;
uniform sampler2D t_hard : filter_nearest, repeat_enable;
uniform sampler2D t_bed : filter_nearest, repeat_enable;
uniform sampler2D n_dirt : filter_nearest, repeat_enable;
uniform sampler2D n_stone : filter_nearest, repeat_enable;
uniform sampler2D n_hard : filter_nearest, repeat_enable;
uniform sampler2D n_bed : filter_nearest, repeat_enable;
uniform sampler2D t_crystal : filter_nearest, repeat_enable;
uniform sampler2D n_crystal : filter_nearest, repeat_enable;
uniform sampler2D t_magma : filter_nearest, repeat_enable;
uniform sampler2D n_magma : filter_nearest, repeat_enable;
uniform sampler2D t_floor : filter_nearest, repeat_enable;
uniform sampler2D n_floor : filter_nearest, repeat_enable;


// Crack network: edges of a small Voronoi pattern. More damage = wider and more of it.
float cracks(vec2 wp, float dmg) {
	vec2 q = wp / 7.0;
	vec2 iq = floor(q);
	vec2 fq = fract(q);
	float f1 = 9.0;
	float f2 = 9.0;
	vec2 cell = vec2(0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 o = vec2(float(i), float(j));
			vec2 r = o + vec2(hash(iq + o), hash(iq + o + 17.3)) - fq;
			float dd = dot(r, r);
			if (dd < f1) { f2 = f1; f1 = dd; cell = iq + o; }
			else if (dd < f2) { f2 = dd; }
		}
	}
	float edge = sqrt(f2) - sqrt(f1);
	float shown = step(hash(cell + 3.1), dmg * 1.4);   // cracks spread cell by cell
	return step(edge, 0.06 + 0.14 * dmg) * shown;
}

void fragment() {
	vec2 local = floor(UV * cells * cell_px) + 0.5;   // snap to whole pixels
	vec2 wp = origin + local;
	vec4 s = texture(fill_map, fuv(local));
	float f = s.r;
	if (f < 0.3) discard;
	vec2 g = vec2(F(local + vec2(1.0, 0.0)) - F(local - vec2(1.0, 0.0)),
	              F(local + vec2(0.0, 1.0)) - F(local - vec2(0.0, 1.0))) * 0.5;
	float gl = length(g);
	float d = gl > 0.0005 ? (f - 0.5) / gl : 99.0;   // signed distance to the edge in px
	if (d < 0.0) discard;
	vec2 n = gl > 0.0005 ? -g / gl : vec2(0.0, -1.0); // points toward open air (y down)

	// pick one material per pixel (dithered at borders, keeps it crisp)
	int mat = pick_mat(local, wp);
	vec2 tuv = wp / 128.0;
	vec3 col; vec3 nm; vec3 rim;
	if (mat == 0) {
		col = texture(t_dirt, tuv).rgb; nm = texture(n_dirt, tuv).rgb; rim = vec3(0.25, 0.38, 0.16);
	} else if (mat == 1) {
		col = texture(t_stone, tuv).rgb; nm = texture(n_stone, tuv).rgb; rim = vec3(0.52, 0.58, 0.66);
	} else if (mat == 2) {
		col = texture(t_hard, tuv).rgb; nm = texture(n_hard, tuv).rgb; rim = vec3(0.4, 0.3, 0.5);
	} else if (mat == 3) {
		col = texture(t_bed, tuv).rgb; nm = texture(n_bed, tuv).rgb; rim = vec3(0.16, 0.14, 0.2);
	} else if (mat == 4) {
		col = texture(t_crystal, tuv).rgb; nm = texture(n_crystal, tuv).rgb; rim = vec3(0.62, 0.46, 0.9);
	} else if (mat == 5) {
		col = texture(t_magma, tuv).rgb; nm = texture(n_magma, tuv).rgb; rim = vec3(0.5, 0.22, 0.12);
	} else {
		col = texture(t_floor, tuv).rgb; nm = texture(n_floor, tuv).rgb; rim = vec3(0.45, 0.42, 0.62);
	}

	col *= mix(1.0, 0.38, s.g);   // rock gets darker deep inside
	if (s.b > 0.02) {             // pickaxe damage: dusty and cracked
		col = mix(col, col * 1.3 + 0.03, s.b * 0.35);
		col *= 1.0 - 0.75 * cracks(wp, s.b);
	}
	vec3 nrm = nm * 2.0 - 1.0;
	if (d < 6.0) {
		float drip = floor(hash(vec2(floor(wp.x), 7.0)) * 4.0);
		if (d < 1.5) {
			col = vec3(0.027, 0.022, 0.035);                     // outline
		} else if (n.y < -0.35 && d < 4.5) {
			col = mix(col, rim, 0.55) * 1.2;                     // lit / mossy top lip
		} else if (n.y > 0.4 && d < 2.5 + drip) {
			col *= 0.4;                                          // dark underside with drips
		} else if (d < 3.0) {
			col *= 1.12;                                         // thin side highlight
		}
		nrm.xy += vec2(n.x, -n.y) * (1.0 - d / 6.0) * 1.4;     // bevel faces the open air
	}
	COLOR = vec4(col, 1.0);
	NORMAL_MAP = normalize(nrm) * 0.5 + 0.5;
}
