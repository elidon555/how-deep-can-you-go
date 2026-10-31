extends Node2D
class_name Watcher
## A pair of glowing eyes in a dark cave. Blinks, stares, and vanishes if you get close.

var player: Node2D
var life := randf_range(6.0, 14.0)
var fade := 0.0
var blink := randf_range(1.0, 3.0)
var gone := false
var tint := Color(2.2, 0.25, 0.15) if randf() < 0.7 else Color(1.8, 1.6, 0.4)
var wide := randi() % 2 + 3


func _process(dt: float) -> void:
	life -= dt
	if not gone and (life <= 0.0 or global_position.distance_to(player.global_position) < 130.0):
		gone = true
	fade = move_toward(fade, 0.0 if gone else 1.0, dt * (4.0 if gone else 0.6))
	if gone and fade <= 0.0:
		queue_free()
	blink -= dt
	if blink < -0.12:
		blink = randf_range(1.5, 4.5)
	queue_redraw()


func _draw() -> void:
	if blink < 0.0:
		return
	var c := Color(tint.r, tint.g, tint.b, fade)
	draw_rect(Rect2(-wide * 2, 0, 3, 2), c)
	draw_rect(Rect2(wide * 2 - 2, 0, 3, 2), c)
