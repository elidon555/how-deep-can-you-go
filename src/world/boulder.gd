extends CharacterBody2D
class_name Boulder
## A loose rock sitting in a little pocket of the ground. Dig out what holds it up and it
## wobbles, then drops: it hurts whoever it lands on and shatters when it hits the ground.
## A pickaxe hit smashes it too. Group "hittable".

signal shattered(pos: Vector2)

const RADIUS := 10.0
const WOBBLE_TIME := 0.5
const GRAVITY := 900.0
const MAX_FALL := 600.0
const AWAKE_DIST := 700.0     # only boulders near the player think
const TEX := "res://assets/props/boulder.png"

enum State { REST, WOBBLE, FALL }

var state := State.REST
var _t := 0.0
var _fall_from := 0.0
var _sprite := Sprite2D.new()
var world: World


func _ready() -> void:
	add_to_group("hittable")
	collision_layer = 1
	collision_mask = 1
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = RADIUS
	cs.shape = shape
	add_child(cs)
	_sprite.texture = Art.lit(TEX) if ResourceLoader.exists(TEX) else _placeholder()
	_sprite.flip_h = randf() < 0.5
	add_child(_sprite)


func _physics_process(dt: float) -> void:
	var player := get_tree().get_first_node_in_group("player") as Player
	if player == null or global_position.distance_to(player.global_position) > AWAKE_DIST:
		return
	_t -= dt
	match state:
		State.REST:
			if _t <= 0.0:
				_t = 0.15
				if _unsupported():
					state = State.WOBBLE
					_t = WOBBLE_TIME
					Sfx.play("break", global_position, -10.0)
		State.WOBBLE:
			_sprite.position.x = sin(_t * 70.0) * 1.2
			if _t <= 0.0:
				_sprite.position.x = 0.0
				state = State.FALL
				_fall_from = global_position.y
		State.FALL:
			velocity.y = minf(velocity.y + GRAVITY * dt, MAX_FALL)
			if _lands_on(player):
				player.hurt(2, global_position)
				shatter()
				return
			var col := move_and_collide(velocity * dt)
			if col:
				if col.get_collider() is Drill:
					col.get_collider().damage(12.0 + velocity.y * 0.02, global_position)
					shatter()
				elif global_position.y - _fall_from > 12.0:
					shatter()
				else:
					state = State.REST
					velocity = Vector2.ZERO


func hit(_damage: int, _from: Vector2) -> void:
	shatter()


func shatter() -> void:
	shattered.emit(global_position)
	Sfx.play("rockfall", global_position)
	queue_free()


## Nothing but air right under the boulder.
func _unsupported() -> bool:
	for x in [-5.0, 0.0, 5.0]:
		if not world.is_air(global_position + Vector2(x, RADIUS + 6.0)):
			return false
	return true


func _lands_on(p: Player) -> bool:
	var top := p.global_position + Vector2(0, -12)
	var foot := p.global_position + Vector2(0, 12)
	var closest := Geometry2D.get_closest_point_to_segment(global_position, top, foot)
	return velocity.y > 60.0 and global_position.distance_to(closest) < RADIUS + 7.0


static func _placeholder() -> Texture2D:
	var img := Image.create(22, 20, false, Image.FORMAT_RGBA8)
	for y in 20:
		for x in 22:
			var d := Vector2(x - 11, (y - 10) * 1.1).length()
			if d < 10.0:
				img.set_pixel(x, y, Color("6b6058").darkened(0.35 * float(y) / 20.0))
			elif d < 11.0:
				img.set_pixel(x, y, Color("0c090e"))
	return ImageTexture.create_from_image(img)
