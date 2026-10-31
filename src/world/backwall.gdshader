shader_type canvas_item;
// Cave back wall: big rock slabs with holes that show the far background.

uniform sampler2D wall_tex : filter_nearest, repeat_enable;
uniform sampler2D wall_n : filter_nearest, repeat_enable;
uniform sampler2D mask_tex : filter_linear, repeat_enable;
uniform float thresh = 0.56;
varying vec2 world;

void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy; }
float M(vec2 p) { vec2 t = texture(mask_tex, p / 1024.0).rg; return t.r + t.g / 255.0; }

void fragment() {
	vec2 wp = floor(world) + 0.5;
	if (wp.y < 4.0) discard;
	float m = M(wp);
	vec2 g = vec2(M(wp + vec2(4.0, 0.0)) - M(wp - vec2(4.0, 0.0)),
	              M(wp + vec2(0.0, 4.0)) - M(wp - vec2(0.0, 4.0))) * 0.125;
	float gl = length(g);
	float d = gl > 1e-5 ? (m - thresh) / gl : 99.0;
	if (d < 0.0) discard;
	vec2 n = gl > 1e-5 ? -g / gl : vec2(0.0, -1.0);
	vec3 col = texture(wall_tex, wp / 256.0).rgb * 2.4;
	vec3 nrm = texture(wall_n, wp / 256.0).rgb * 2.0 - 1.0;
	col *= mix(1.0, 0.6, clamp(d / 40.0, 0.0, 1.0));
	if (d < 1.5) col = vec3(0.015, 0.013, 0.02);
	else if (d < 4.0 && n.y < -0.3) col *= 1.6;
	if (d < 6.0) nrm.xy += vec2(n.x, -n.y) * (1.0 - d / 6.0);
	COLOR = vec4(col, 1.0);
	NORMAL_MAP = normalize(nrm) * 0.5 + 0.5;
}
