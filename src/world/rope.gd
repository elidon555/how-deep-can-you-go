extends Node2D
class_name Rope
## Something you can climb with W / S: a rope hammered into the rock, or a ladder fixed to
## the drill's hull (as a child of it, so it moves along). Group "rope".
## top / bottom are local y, so a rope keeps working when its parent moves.

const MAX_LEN := 15.0 * World.METER
const TEX := "res://assets/props/rope.png"
const ANCHOR_TEX := "res://assets/props/rope_anchor.png"

var top := 0.0       # local y of the anchor
var bottom := 0.0    # local y of the end
var ladder := false  # drawn as a ladder instead of a rope
var _tex: Texture2D
var _anchor: Texture2D


## Hangs a rope above `feet` (the thrower's feet): up to the first rock overhead, or as far as
## a throw reaches (hammered into the shaft wall), but never above the surface.
static func hang(world: World, feet: Vector2) -> Rope:
	var y := feet.y - 40.0
	while y > feet.y - MAX_LEN and y > -4.0 and world.is_air(Vector2(feet.x, y - 4.0)):
		y -= 4.0
	var r := Rope.new()
	r.position = Vector2(feet.x, 0)
	r.top = maxf(y, -4.0)
	r.bottom = feet.y + 4.0
	r.add_to_group("net")          # the crew's ropes are shared online (not the drill's ladders)
	return r


func _ready() -> void:
	add_to_group("rope")
	z_index = -1
	_tex = Art.lit(TEX) if ResourceLoader.exists(TEX) else null
	_anchor = load(ANCHOR_TEX) if ResourceLoader.exists(ANCHOR_TEX) else null
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


var puppet := false   # online client: a rope the host's crew hung


func net_state() -> Array:
	return [top, bottom]


func net_apply(s: Array) -> void:
	if top != s[0] or bottom != s[1]:
		top = s[0]
		bottom = s[1]
		queue_redraw()


func top_y() -> float:
	return global_position.y + top


func bottom_y() -> float:
	return global_position.y + bottom


## Can someone centred at p (global) grab it?
func covers(p: Vector2) -> bool:
	return absf(p.x - global_position.x) < 10.0 and p.y > top_y() - 26.0 and p.y < bottom_y() + 10.0


func _draw() -> void:
	if ladder:
		for x in [-5.0, 5.0]:
			draw_line(Vector2(x, top), Vector2(x, bottom), Color("2a2d33"), 2.0)
		var y := top + 3.0
		while y < bottom:
			draw_line(Vector2(-5, y), Vector2(5, y), Color("6d7480"), 2.0)
			y += 7.0
		return
	# the anchor's top edge sits on the rock; the rope starts at its bottom edge
	var start: float = top + (_anchor.get_height() if _anchor else 2.0)
	if _tex:
		var w := float(_tex.get_width())
		draw_texture_rect(_tex, Rect2(-w / 2.0, start, w, bottom - start), true)
	else:
		draw_line(Vector2(0, start), Vector2(0, bottom), Color("8a6a42"), 3.0)
	if _anchor:
		draw_texture(_anchor, Vector2(-_anchor.get_width() / 2.0, top))
	else:
		draw_rect(Rect2(-3, top - 3, 6, 5), Color("3a3a40"))
