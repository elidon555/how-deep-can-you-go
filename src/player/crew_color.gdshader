shader_type canvas_item;
// Crew colours: the miner's blue work clothes take this player's colour (a hue swap), and the
// brass-yellow helmet the helmet colour they've unlocked (helmet_hue < 0 keeps it); skin, leather
// and the outline keep theirs. Lit by the lamps and the normal map as usual.

uniform float hue = 0.56;          // 0..1; the sheet's own blue is ~0.56
uniform float saturation = 1.0;    // multiplier for the clothes' saturation
uniform float helmet_hue = -1.0;

vec3 rgb2hsv(vec3 c) {
	vec4 k = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, k.wz), vec4(c.gb, k.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

void fragment() {
	vec3 hsv = rgb2hsv(COLOR.rgb);
	if (hsv.x > 0.44 && hsv.x < 0.68 && hsv.y > 0.18) {     // the blue cloth
		hsv.x = hue;
		hsv.y = min(hsv.y * saturation, 1.0);
		COLOR.rgb = hsv2rgb(hsv);
	} else if (helmet_hue >= 0.0 && hsv.x > 0.088 && hsv.x < 0.16 && hsv.y > 0.62 && hsv.z > 0.45) {   // the helmet
		hsv.x = helmet_hue;
		COLOR.rgb = hsv2rgb(hsv);
	}
}
