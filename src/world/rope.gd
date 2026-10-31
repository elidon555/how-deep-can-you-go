extends Node2D
class_name Rope
## A rope hammered into the rock above where it was thrown; climb it with W / S.
## Group "rope" so the player can find one to grab.

const MAX_LEN := 15.0 * World.METER
const TEX := "res://assets/props/rope.png"
const ANCHOR_TEX := "res://assets/props/rope_anchor.png"

var top := 0.0       # global y of the anchor
var bottom := 0.0    # global y of the rope's end
var _tex: Texture2D
var _anchor: Texture2D


## Hangs a rope above `feet` (the thrower's feet): up to the first rock overhead, or as far as
## a throw reaches (hammered into the shaft wall), but never above the surface.
static func hang(world: World, feet: Vector2) -> Rope:
	var r := Rope.new()
	r.position = Vector2(feet.x, 0)
	r.bottom = feet.y + 4.0
	var y := feet.y - 40.0
	while y > feet.y - MAX_LEN and y > -4.0 and world.is_air(Vector2(feet.x, y - 4.0)):
		y -= 4.0
	r.top = maxf(y, -4.0)
	return r


func _ready() -> void:
	add_to_group("rope")
	z_index = -1
	_tex = load(TEX) if ResourceLoader.exists(TEX) else null
	_anchor = load(ANCHOR_TEX) if ResourceLoader.exists(ANCHOR_TEX) else null
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


## Can someone centred at p grab this rope?
func covers(p: Vector2) -> bool:
	return absf(p.x - position.x) < 10.0 and p.y > top - 26.0 and p.y < bottom + 10.0


func _draw() -> void:
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
