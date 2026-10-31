extends CharacterBody2D
class_name Player
## The little digger. Tight platformer controls + directional digging.

signal digging(cell: Vector2i)   # every frame while chipping at a tile

const SPEED := 110.0
const ACCEL := 1000.0
const FRICTION := 1400.0
const GRAVITY := 900.0
const JUMP_V := -270.0
const MAX_FALL := 420.0
const COYOTE := 0.1
const JUMP_BUFFER := 0.12

var world: World
var dig_power := 4.0   # damage per second (dirt has 1 HP, hard rock 5.5)
var coyote_t := 0.0
var buffer_t := 0.0
var facing := 1
var squash := Vector2.ONE
var dig_anim := 0.0


func _ready() -> void:
	var col := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(10, 14)
	col.shape = shape
	add_child(col)


func _physics_process(dt: float) -> void:
	var dir := Input.get_axis("left", "right")
	if dir != 0:
		facing = int(sign(dir))

	var was_on_floor := is_on_floor()
	velocity.y = minf(velocity.y + GRAVITY * dt, MAX_FALL)
	coyote_t = COYOTE if is_on_floor() else coyote_t - dt
	buffer_t = JUMP_BUFFER if Input.is_action_just_pressed("jump") else buffer_t - dt
	if buffer_t > 0 and coyote_t > 0:
		velocity.y = JUMP_V
		buffer_t = 0
		coyote_t = 0
		squash = Vector2(0.7, 1.3)
	if Input.is_action_just_released("jump") and velocity.y < 0:
		velocity.y *= 0.5

	if dir != 0:
		velocity.x = move_toward(velocity.x, dir * SPEED, ACCEL * dt)
	else:
		velocity.x = move_toward(velocity.x, 0, FRICTION * dt)

	var fall_speed := velocity.y
	move_and_slide()
	if is_on_floor() and not was_on_floor and fall_speed > 150:
		squash = Vector2(1.3, 0.7)

	_handle_dig(dt, dir)
	squash = squash.lerp(Vector2.ONE, 12 * dt)
	queue_redraw()


func _handle_dig(dt: float, dir: float) -> void:
	var target := Vector2i(-99999, 0)
	if Input.is_action_pressed("down") and is_on_floor():
		target = world.local_to_map(world.to_local(global_position + Vector2(0, 10)))
		# slide to the middle of the tile so you fall cleanly into the hole
		var cx := world.to_global(world.map_to_local(target)).x
		velocity.x = (cx - global_position.x) * 12.0
	elif Input.is_action_pressed("up"):
		target = world.local_to_map(world.to_local(global_position + Vector2(0, -10)))
	elif dir != 0 and is_on_wall():
		target = world.local_to_map(world.to_local(global_position + Vector2(facing * 9, 0)))

	if target.x == -99999 or world.get_type(target) == -1:
		dig_anim = 0
		return
	dig_anim += dt
	digging.emit(target)
	world.dig(target, dig_power * dt)


func _draw() -> void:
	# placeholder art: body, helmet, lamp, eye, swinging pick
	draw_set_transform(Vector2(0, 7), 0, squash)
	draw_rect(Rect2(-5, -14, 10, 14), Color("e07a3a"))          # body
	draw_rect(Rect2(-5, -14, 10, 4), Color("f2c14e"))           # helmet
	draw_rect(Rect2(facing * 3 - 1, -13, 2, 2), Color("fff6c8"))  # lamp
	draw_rect(Rect2(facing * 2 - 1, -9, 2, 2), Color("1c1a22"))   # eye
	var swing := sin(dig_anim * 30.0) * 0.8 if dig_anim > 0 else 0.0
	draw_set_transform(Vector2(facing * 4, 0), (-0.6 + swing) * facing, squash)
	draw_rect(Rect2(0 if facing > 0 else -2, -2, 2, 9), Color("8a6a4a"))  # handle
	draw_rect(Rect2(-3, 6, 8, 2), Color("b8bcc8"))              # pick head
