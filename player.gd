extends CharacterBody2D
class_name Player
## The little digger. Tight platformer controls + directional digging + helmet lamp.

signal digging(cell: Vector2i)   # every frame while chipping at a tile

const SPEED := 110.0
const ACCEL := 1000.0
const FRICTION := 1400.0
const GRAVITY := 900.0
const JUMP_V := -270.0
const MAX_FALL := 420.0
const COYOTE := 0.1
const JUMP_BUFFER := 0.12

# pixel-art frames, facing right. 12 wide x 14 tall, feet on the last row.
const PAL := {
	"o": Color("0c090e"), "h": Color("e8b13a"), "H": Color("9c6a1c"), "L": Color("fff6d0"),
	"s": Color("d99a74"), "e": Color("140c10"), "c": Color("35536a"), "d": Color("223646"),
	"b": Color("3a2a20"), "B": Color("5a4130"),
}
const BODY := [
	"...oooooo...",
	"..ohhhhhhoo.",
	"..ohhhhhhLLo",
	".oHHHHHHHHo.",
	"..ossssseo..",
	"..osssssso..",
	"..ocdcccco..",
	".occdcccccoo",
	".occdccccsso",
	".occdcccco..",
	"..oddBdddo..",
]
const LEGS := {
	"idle": ["..occo.oco..", "..obbo.obbo.", "..ooo...ooo."],
	"run1": [".occo...occo", ".obbo...obo.", ".ooo....ooo."],
	"run2": ["...occooco..", "...obbobbo..", "...oooooo..."],
	"jump": ["..occoocco..", ".obbo..obbo.", ".ooo....ooo."],
}

var world: World
var dig_power := 4.0   # damage per second (dirt has 1 HP, hard rock 5.5)
var light_mul := 1.0   # set by main for flicker
var lamp_on := false
var coyote_t := 0.0
var buffer_t := 0.0
var facing := 1
var squash := Vector2.ONE
var dig_anim := 0.0
var run_t := 0.0
var cone := PointLight2D.new()
var glow := PointLight2D.new()


func _ready() -> void:
	var col := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(10, 14)
	col.shape = shape
	add_child(col)

	# helmet flashlight cone + small glow around the miner
	cone.texture = _cone_texture()
	cone.texture_scale = 1.35
	cone.color = Color("ffd9a0")
	cone.energy = 1.5
	cone.height = 90.0
	cone.position = Vector2(0, -3)
	add_child(cone)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	glow.texture = gt
	glow.texture_scale = 0.55
	glow.color = Color("ffcf99")
	glow.energy = 0.8
	glow.height = 60.0
	add_child(glow)


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
		squash = Vector2(0.75, 1.25)
	if Input.is_action_just_released("jump") and velocity.y < 0:
		velocity.y *= 0.5

	if dir != 0:
		velocity.x = move_toward(velocity.x, dir * SPEED, ACCEL * dt)
	else:
		velocity.x = move_toward(velocity.x, 0, FRICTION * dt)

	var fall_speed := velocity.y
	move_and_slide()
	if is_on_floor() and not was_on_floor and fall_speed > 150:
		squash = Vector2(1.25, 0.75)

	_handle_dig(dt, dir)
	_update_lamp(dt)
	squash = squash.lerp(Vector2.ONE, 12 * dt)
	run_t += dt * absf(velocity.x) / SPEED
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


func _update_lamp(dt: float) -> void:
	var aim := 0.0 if facing > 0 else PI
	if Input.is_action_pressed("down"):
		aim = PI / 2
	elif Input.is_action_pressed("up"):
		aim = -PI / 2
	cone.rotation = lerp_angle(cone.rotation, aim, 10.0 * dt)
	cone.enabled = lamp_on
	glow.enabled = lamp_on
	cone.energy = 2.4 * light_mul
	glow.energy = 1.1 * light_mul


func _draw() -> void:
	draw_set_transform(Vector2(0, 7), 0, squash)   # anchor at the feet
	var legs: Array = LEGS.idle
	if not is_on_floor():
		legs = LEGS.jump
	elif absf(velocity.x) > 10:
		legs = LEGS.run1 if int(run_t * 8.0) % 2 == 0 else LEGS.run2
	var rows: Array = BODY + legs
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var ch := row[x]
			if ch == ".":
				continue
			var px := x - 6 if facing > 0 else 5 - x
			draw_rect(Rect2(px, y - rows.size(), 1, 1), PAL[ch])
	# pickaxe (outline first, then wood + iron)
	var swing := sin(dig_anim * 30.0) * 0.9 if dig_anim > 0 else 0.0
	draw_set_transform(Vector2(facing * 4, 1), (0.5 + swing) * facing, squash)
	draw_rect(Rect2(-1, -9, 3, 11), PAL.o)
	draw_rect(Rect2(-4, -10, 9, 4), PAL.o)
	draw_rect(Rect2(0, -8, 1, 9), Color("7a5636"))
	draw_rect(Rect2(-3, -9, 7, 2), Color("aab2c0"))
	draw_rect(Rect2(-3, -9, 7, 1), Color("d8dee8"))


static func _cone_texture() -> ImageTexture:
	var s := 256
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := Vector2(s / 2.0, s / 2.0)
	for y in s:
		for x in s:
			var d := Vector2(x, y) - c
			var dist := d.length() / (s / 2.0)
			if dist >= 1.0:
				continue
			var ang := absf(d.angle())
			var a := (1.0 - smoothstep(0.32, 0.56, ang)) * pow(1.0 - dist, 0.9)
			img.set_pixel(x, y, Color(a, a, a, a))
	return ImageTexture.create_from_image(img)
