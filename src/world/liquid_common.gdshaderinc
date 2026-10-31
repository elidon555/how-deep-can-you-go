// Shared by liquid_water.gdshader and liquid_lava.gdshader. Liquid sits in the dig grid's
// cells (liquid_map: R = water, G = lava, 0..1, one-cell margin like fill_map). A part-full
// cell is filled from the bottom; a cell with liquid above it is full. The free surface is
// interpolated between neighbouring cells (so levels slope smoothly instead of stepping in
// squares) and ripples. Rock (from fill_map, same contour as the terrain) hides it.

uniform sampler2D liquid_map : filter_nearest, repeat_disable;
uniform sampler2D fill_map : filter_linear, repeat_disable;
uniform vec2 origin;
uniform float cells = 32.0;
uniform float cell_px = 8.0;

vec2 cell_uv(vec2 cell) { return (cell + 1.5) / (cells + 2.0); }

float amount(vec2 cell, int ch) { return texture(liquid_map, cell_uv(cell))[ch]; }

// Surface height of a cell (0 = empty, 1 = full): full if there's liquid above it.
float level(vec2 cell, int ch) {
	if (amount(cell - vec2(0.0, 1.0), ch) > 0.05) return 1.0;
	return amount(cell, ch);
}

// > 0 where this pixel is liquid of the given channel (0 water, 1 lava); 2 = surface pixel.
float liquid_here(vec2 uv, int ch, float time) {
	vec2 local = floor(uv * cells * cell_px) + 0.5;
	vec2 cellf = local / cell_px;
	vec2 cell = floor(cellf);
	vec2 f = fract(cellf);
	float here = level(cell, ch);
	if (here < 0.02) return 0.0;
	// the neighbour on the side this pixel leans toward; its level blends in toward the shared
	// edge (a neighbour with no liquid of this kind counts as level with us: rock walls, air
	// next to a pool's edge -> the pool stays flat there)
	vec2 side = cell + vec2(f.x < 0.5 ? -1.0 : 1.0, 0.0);
	float there = level(side, ch);
	if (there < 0.02) there = here;
	float t = abs(f.x - 0.5);                         // 0 at the cell centre .. 0.5 at its edge
	float lv = mix(here, (here + there) * 0.5, t * 2.0);
	bool free_surface = lv < 0.999;
	float top = 1.0 - lv;
	if (free_surface) {
		top += sin(time * 3.0 + (origin.x + local.x) * 0.45) * 0.04;
	}
	if (f.y < top) return 0.0;
	if (texture(fill_map, (local / cell_px + 1.0) / (cells + 2.0)).r >= 0.5) return 0.0;
	return (free_surface && f.y < top + 1.5 / cell_px) ? 2.0 : 1.0;
}
