extends Node2D
class_name OreSled
## The ore sled upgrade: a little sled trailing behind its miner on the ground, piled with what
## they carry (Progress.bag_bonus gives the room). Just for show, so every machine moves its own.

const TEX := "res://assets/props/sled.png"
const BEHIND := 22.0

var player: Player
var _tex: Texture2D = Art.lit(TEX) if ResourceLoader.exists(TEX) else null


func _ready() -> void:
	z_index = -1
	if player:
		global_position = player.global_position


func _process(dt: float) -> void:
	if player == null or not is_instance_valid(player):
		queue_free()
		return
	visible = player.visible
	var want := player.global_position + Vector2(-player.facing * BEHIND, Player.HALF_HEIGHT)
	# rest on the ground under that spot
	var y := want.y - 6.0
	while player.world.is_air(Vector2(want.x, y + 1.0)) and y < want.y + 24.0:
		y += 2.0
	want.y = y
	if global_position.distance_to(want) > 120.0:
		global_position = want
	global_position = global_position.lerp(want, 1.0 - exp(-6.0 * dt))
	queue_redraw()


func _draw() -> void:
	if _tex:
		draw_texture(_tex, Vector2(-_tex.get_width() / 2.0, -_tex.get_height()))
	else:
		draw_rect(Rect2(-12, -6, 24, 4), Color("5a3c27"))
		draw_line(Vector2(-13, 0), Vector2(13, 0), Color("2a1c12"), 2.0)
	var load := mini(player.ore_count + player.coal, 12)
	for i in load:                                # the haul piled on top
		var x := -9.0 + (i % 6) * 3.5
		var yy := -8.0 - (i / 6) * 3.0
		draw_rect(Rect2(x, yy, 3, 3), Color("d9824a") if i < player.ore_count else Color("26252b"))
	if player.global_position.distance_to(global_position) < 60.0:     # the tow rope
		draw_line(Vector2(0, -5), to_local(player.global_position + Vector2(0, 4)), Color("6b5236"), 1.0)
