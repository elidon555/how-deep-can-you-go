// Shared by terrain.gdshader and terrain_glow.gdshader: the chunk's fill / material maps and
// how a pixel turns into "rock or not" and "which material".
uniform sampler2D fill_map : filter_linear, repeat_disable;  // R = fill, G = depth inside rock, B = cracks
uniform sampler2D mat_map : filter_linear, repeat_disable;   // one-hot: dirt, stone, hard, bedrock
uniform sampler2D mat_map2 : filter_linear, repeat_disable;  // one-hot: crystal, magma, the Floor
uniform float cells = 32.0;
uniform float cell_px = 8.0;
uniform vec2 origin;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
vec2 fuv(vec2 local) { return (local / cell_px + 1.0) / (cells + 2.0); }
float F(vec2 local) { return texture(fill_map, fuv(local)).r; }

// The material at a pixel: the strongest of the six one-hot weights, dithered at borders.
// (0 dirt, 1 stone, 2 hard, 3 bedrock, 4 crystal, 5 magma, 6 the Floor)
int pick_mat(vec2 local, vec2 wp) {
	vec4 w = texture(mat_map, fuv(local));
	vec4 w2 = texture(mat_map2, fuv(local));
	float h = hash(floor(wp));
	w += vec4(h, fract(h * 13.7), fract(h * 71.3), fract(h * 37.9)) * 0.3;
	w2 += vec4(fract(h * 5.3), fract(h * 29.1), fract(h * 17.7), 0.0) * 0.3;
	float ws[7] = float[7](w.r, w.g, w.b, w.a, w2.r, w2.g, w2.b);
	int best = 0;
	for (int i = 1; i < 7; i++) {
		if (ws[i] > ws[best]) { best = i; }
	}
	return best;
}

