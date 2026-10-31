extends Node2D
class_name Ping
## A crew marker (middle click / F / LB): "here!" at a spot, in the colour of who placed it, on
## the bloom layer. Rings out, then fades after LIFE seconds. While it's off screen, an arrow at
## the screen's edge points the way.

const LIFE := 5.0
const EDGE := 26.0               # px in from the screen edge for the arrow

var color := Color.WHITE
var who := ""
var _t := 0.0


func _process(dt: float) -> void:
	_t += dt
	if _t >= LIFE:
		queue_free()
	queue_redraw()


func _draw() -> void:
	var a := clampf((LIFE - _t) / 1.0, 0.0, 1.0)            # fades over the last second
	var c := Color(color.r * 1.6, color.g * 1.6, color.b * 1.6, a)
	var ring := fmod(_t, 1.2) / 1.2                          # a ring every 1.2 s
	draw_arc(Vector2.ZERO, 4.0 + ring * 18.0, 0.0, TAU, 24, Color(c, a * (1.0 - ring)), 1.5)
	var d := PackedVector2Array([Vector2(0, -7), Vector2(5, 0), Vector2(0, 7), Vector2(-5, 0)])
	draw_colored_polygon(d, c)
	draw_string(ThemeDB.fallback_font, Vector2(-30, -11), who, HORIZONTAL_ALIGNMENT_CENTER, 60, 8, c)
	# off screen: an arrow at the edge, pointing at it
	var xf := get_global_transform_with_canvas()
	var screen := get_viewport_rect().size
	var at := xf.origin
	var inner := Rect2(Vector2(EDGE, EDGE), screen - Vector2(EDGE, EDGE) * 2.0)
	if inner.has_point(at):
		return
	var centre := screen / 2.0
	var dir := (at - centre).normalized()
	var edge := Vector2(clampf(at.x, inner.position.x, inner.end.x), clampf(at.y, inner.position.y, inner.end.y))
	var back := xf.affine_inverse()
	var tip := back * edge
	var side := dir.orthogonal()
	var scale := back.get_scale().x
	draw_colored_polygon(PackedVector2Array([tip, back * (edge - dir * 14.0 + side * 8.0),
		back * (edge - dir * 14.0 - side * 8.0)]), c)
	draw_string(ThemeDB.fallback_font, back * (edge - dir * 22.0) - Vector2(30, -4) * scale, who,
		HORIZONTAL_ALIGNMENT_CENTER, 60 * scale, int(14 * scale), c)
