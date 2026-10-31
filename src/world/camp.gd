extends Node2D
class_name Camp
## The surface camp: a merchant stall next to where you start. Stand by it to open the shop;
## coming back to the surface sells your ore, heals you and refills your ropes (main does that).

const TEX := "res://assets/props/stall.png"
const GLOW_TEX := "res://assets/props/stall_glow.png"
const REACH := 70.0

var ground_y := 0.0


## Sits the camp on the ground at x (finds the surface there).
func place(world: World, x: float, glow_parent: Node) -> void:
	var y := -60.0
	while world.is_air(Vector2(x, y)) and y < 200.0:
		y += 2.0
	ground_y = y
	position = Vector2(x, y)
	var tex: Texture2D = load(TEX) if ResourceLoader.exists(TEX) else null
	if tex:
		var s := Sprite2D.new()
		s.texture = tex
		s.offset = Vector2(0, -tex.get_height() / 2.0)
		s.z_index = -1
		add_child(s)
		if ResourceLoader.exists(GLOW_TEX):
			var g := Sprite2D.new()
			g.texture = load(GLOW_TEX)
			g.offset = s.offset
			g.position = position
			glow_parent.add_child(g)
	else:
		queue_redraw()


func near(p: Vector2) -> bool:
	return absf(p.x - position.x) < REACH and p.y > ground_y - 70.0 and p.y < ground_y + 10.0


func _draw() -> void:
	if get_child_count() > 0:
		return
	# placeholder stall until the Blender one exists
	draw_rect(Rect2(-40, -50, 80, 50), Color("4a3726"))
	draw_rect(Rect2(-46, -60, 92, 14), Color("8c2f2a"))
