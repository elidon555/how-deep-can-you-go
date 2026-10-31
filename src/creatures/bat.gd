extends Node2D
class_name Bat
## A cave bat. Hangs from a ceiling until someone comes close, then drops and flits at them in
## an erratic swoop, nipping (1 damage) and peeling away. It looks ahead and steers around rock
## and the drill's hull (it only gets into the cabin through an open hatch). One hit kills it.
## Drawn from its rendered sheet (assets/sprites/bat.png): fly / dive / hang / die frames.

signal killed(pos: Vector2)

const WAKE_DIST := 120.0
const SPEED := 95.0
const BITE_DIST := 12.0
const SHEET := "res://assets/sprites/bat.png"
const SHEET_GLOW := "res://assets/sprites/bat_glow.png"
const SHEET_INFO := "res://assets/sprites/bat.json"

enum State { HANG, FLY, PEEL, DEAD }

var world: World
var glow_parent: Node
var state := State.HANG
var velocity := Vector2.ZERO
var _t := 0.0
var _anim_t := 0.0
var _phase := randf() * TAU
var _sprite := Sprite2D.new()
var _eyes := Sprite2D.new()
var _anims := {}
var _target: Player


func _ready() -> void:
	add_to_group("hittable")
	add_to_group("creature")
	add_to_group("bat")
	var info = JSON.parse_string(FileAccess.get_file_as_string(SHEET_INFO))
	for name in info.anims:
		_anims[name] = [int(info.anims[name].row), int(info.anims[name].frames)]
	for s in [_sprite, _eyes]:
		s.hframes = int(info.columns)
		s.vframes = _anims.size()
	_sprite.texture = Art.lit(SHEET)
	add_child(_sprite)
	if glow_parent and ResourceLoader.exists(SHEET_GLOW):
		_eyes.texture = load(SHEET_GLOW)
		glow_parent.add_child(_eyes)
		tree_exiting.connect(_eyes.queue_free)
	_sprite.position = Vector2(0, 10)        # hanging: feet on the ceiling point we were placed at


func _physics_process(dt: float) -> void:
	_t -= dt
	match state:
		State.HANG:
			var p := _closest_player()
			if p and p.global_position.distance_to(global_position) < WAKE_DIST:
				_target = p
				state = State.FLY
				_sprite.position = Vector2.ZERO
				velocity = Vector2(randf_range(-40, 40), 60)
				Sfx.play("bat_screech", global_position, -4.0)
		State.FLY:
			if not is_instance_valid(_target):
				state = State.PEEL
			else:
				var to := _target.global_position + Vector2(0, -6) - global_position
				var wobble := Vector2(sin(Time.get_ticks_msec() * 0.009 + _phase), cos(Time.get_ticks_msec() * 0.013 + _phase)) * 70.0
				velocity = velocity.move_toward(to.normalized() * SPEED + wobble, 260.0 * dt)
				if to.length() < BITE_DIST:
					_target.hurt(1, global_position)
					state = State.PEEL
					_t = 0.9
					velocity = -to.normalized() * SPEED + Vector2(0, -60)
				elif to.length() > 400.0:
					queue_free()
		State.PEEL:
			velocity = velocity.move_toward(Vector2(velocity.x, -40), 200.0 * dt)
			if _t <= 0.0:
				state = State.FLY
		State.DEAD:
			velocity.y += 600.0 * dt
			modulate.a = clampf(_t / 0.8, 0.0, 1.0)
			if _t <= 0.0:
				queue_free()
	if state != State.HANG:
		if state != State.DEAD:
			_steer_around()
		var next := global_position + velocity * dt
		if state != State.DEAD and _solid(next):        # still about to hit: bounce off
			velocity = -velocity * 0.6
		else:
			global_position = next
	_animate(dt)


## Rock, or the drill's hull from whichever side we're on.
func _solid(p: Vector2) -> bool:
	if not world.is_air(p):
		return true
	var d := get_tree().get_first_node_in_group("drill") as Drill
	return d != null and d.blocks(p, d.contains(global_position))


## Something solid just ahead: turn toward whichever side is open (prefer toward the target).
func _steer_around() -> void:
	if velocity.length() < 1.0:
		return
	var dir := velocity.normalized()
	if not _solid(global_position + dir * 18.0):
		return
	var left := dir.rotated(-PI / 2.0)
	var right := dir.rotated(PI / 2.0)
	var prefer := right
	if is_instance_valid(_target):
		prefer = left if left.dot(_target.global_position - global_position) > 0.0 else right
	var other := right if prefer == left else left
	for side: Vector2 in [prefer, other, -dir]:
		if not _solid(global_position + side * 18.0):
			velocity = side * velocity.length()
			return


func _closest_player() -> Player:
	var best: Player = null
	for p: Player in get_tree().get_nodes_in_group("player"):
		if best == null or p.global_position.distance_to(global_position) < best.global_position.distance_to(global_position):
			best = p
	return best


func hit(_damage: int, _from: Vector2) -> void:
	if state == State.DEAD:
		return
	state = State.DEAD
	_t = 0.8
	_anim_t = 0.0
	velocity = Vector2(velocity.x * 0.3, -80)
	remove_from_group("hittable")
	Sfx.play("bat_screech", global_position, -2.0, 0.3)
	killed.emit(global_position)


func _animate(dt: float) -> void:
	var name := "fly"
	match state:
		State.HANG:
			name = "hang"
		State.DEAD:
			name = "die"
		State.PEEL, State.FLY:
			name = "dive" if velocity.y > 70.0 else "fly"
	var a: Array = _anims.get(name, _anims["fly"])
	_anim_t += dt * (14.0 if name == "fly" else 4.0)
	var f := int(_anim_t) % int(a[1]) if name != "die" else mini(int(_anim_t), int(a[1]) - 1)
	_sprite.frame = a[0] * _sprite.hframes + f
	_sprite.flip_h = velocity.x < 0.0
	if _eyes.texture:
		_eyes.frame = _sprite.frame
		_eyes.flip_h = _sprite.flip_h
		_eyes.global_position = _sprite.global_position
		_eyes.visible = state != State.DEAD
