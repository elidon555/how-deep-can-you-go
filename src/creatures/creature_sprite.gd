extends RefCounted
class_name CreatureSprite
## A creature's rendered sheet (assets/sprites/<name>.png, _glow.png, .json from the tools/
## sheet scripts): the lit sprite on the creature and its glowing parts on the bloom layer, kept
## in step. Frames come from the sheet's rows; nothing is scaled or rotated to animate.

var sprite := Sprite2D.new()
var glow := Sprite2D.new()
var anims := {}                  # name -> [row, frames]
var ok := false                  # the sheet exists (otherwise the creature draws itself)


## feet: where the creature's feet are, relative to its origin (the sheet's feet line goes there).
func _init(owner: Node2D, name: String, glow_parent: Node, feet := Vector2.ZERO) -> void:
	var dir := "res://assets/sprites/"
	if not ResourceLoader.exists(dir + name + ".json"):
		return
	ok = true
	var info = JSON.parse_string(FileAccess.get_file_as_string(dir + name + ".json"))
	var rows := 0
	for a in info.anims:
		anims[a] = [int(info.anims[a].row), int(info.anims[a].frames)]
		rows = maxi(rows, int(info.anims[a].row) + 1)
	for s in [sprite, glow]:
		s.hframes = int(info.columns)
		s.vframes = rows
		s.offset = Vector2(0, -float(info.get("feet_below_center", 0.0)))
		s.position = feet
	sprite.texture = Art.lit(dir + name + ".png")
	owner.add_child(sprite)
	if glow_parent and ResourceLoader.exists(dir + name + "_glow.png"):
		glow.texture = load(dir + name + "_glow.png")
		glow_parent.add_child(glow)
		owner.tree_exiting.connect(glow.queue_free)


func frames(anim: String) -> int:
	return anims[anim][1] if anims.has(anim) else 1


## Shows frame `t` (counted in frames) of `anim`: looping, or held on its last frame.
func show(anim: String, t: float, flip: bool, loop := true) -> void:
	if not ok or not anims.has(anim):
		return
	var a: Array = anims[anim]
	var f := int(t) % int(a[1]) if loop else mini(int(t), int(a[1]) - 1)
	sprite.frame = a[0] * sprite.hframes + f
	sprite.flip_h = flip
	if glow.texture:
		glow.frame = sprite.frame
		glow.flip_h = flip
		glow.global_position = sprite.global_position
		glow.modulate.a = sprite.get_parent().modulate.a
