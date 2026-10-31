shader_type canvas_item;
// Smooth terrain: the dig grid (fill_map, bilinear) becomes an organic contour.
// Distance to the edge drives outline, mossy/lit top lips, dark undersides, bevels.

uniform sampler2D fill_map : filter_linear, repeat_disable;  // R = fill, G = depth inside rock
uniform sampler2D mat_map : filter_linear, repeat_disable;   // one-hot: dirt, stone, hard, bedrock
uniform sampler2D t_dirt : filter_nearest, repeat_enable;
uniform sampler2D t_stone : filter_nearest, repeat_enable;
uniform sampler2D t_hard : filter_nearest, repeat_enable;
uniform sampler2D t_bed : filter_nearest, repeat_enable;
uniform sampler2D n_dirt : filter_nearest, repeat_enable;
uniform sampler2D n_stone : filter_nearest, repeat_enable;
uniform sampler2D n_hard : filter_nearest, repeat_enable;
uniform sampler2D n_bed : filter_nearest, repeat_enable;
uniform float cells = 32.0;
uniform float cell_px = 8.0;
uniform vec2 origin;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 fuv(vec2 local) { return (local / cell_px + 1.0) / (cells + 2.0); }
float F(vec2 local) { return texture(fill_map, fuv(local)).r; }

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
	vec4 w = texture(mat_map, fuv(local));
	float h = hash(floor(wp));
	w += vec4(h, fract(h * 13.7), fract(h * 71.3), fract(h * 37.9)) * 0.3;
	vec2 tuv = wp / 128.0;
	vec3 col; vec3 nm; vec3 rim;
	if (w.r >= w.g && w.r >= w.b && w.r >= w.a) {
		col = texture(t_dirt, tuv).rgb; nm = texture(n_dirt, tuv).rgb; rim = vec3(0.25, 0.38, 0.16);
	} else if (w.g >= w.b && w.g >= w.a) {
		col = texture(t_stone, tuv).rgb; nm = texture(n_stone, tuv).rgb; rim = vec3(0.52, 0.58, 0.66);
	} else if (w.b >= w.a) {
		col = texture(t_hard, tuv).rgb; nm = texture(n_hard, tuv).rgb; rim = vec3(0.4, 0.3, 0.5);
	} else {
		col = texture(t_bed, tuv).rgb; nm = texture(n_bed, tuv).rgb; rim = vec3(0.16, 0.14, 0.2);
	}

	col *= mix(1.0, 0.38, s.g);   // rock gets darker deep inside
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
