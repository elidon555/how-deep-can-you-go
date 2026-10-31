extends CharacterBody2D
class_name Player
## The little digger. Tight platformer controls + directional digging + helmet lamp.

signal digging(pos: Vector2, mat: int)   # every frame while digging

const SPEED := 150.0
const ACCEL := 1300.0
const FRICTION := 1800.0
const GRAVITY := 1100.0
const JUMP_V := -390.0
const MAX_FALL := 560.0
const COYOTE := 0.1
const JUMP_BUFFER := 0.12

const SHEET := preload("res://assets/sprites/miner.png")
const ANIMS := {   # row, frames, fps (from assets/sprites/miner.json)
	"idle": [0, 4, 4.0], "run": [1, 8, 13.0], "jump": [2, 1, 1.0], "fall": [3, 1, 1.0],
	"dig_side": [4, 6, 14.0], "dig_down": [5, 6, 14.0], "dig_up": [6, 6, 14.0],
}
const FEET_BELOW_CENTER := 26.5

var world: World
var dig_power := 3.0   # fill removed per second at the centre of the dig (dirt)
var light_mul := 1.0   # set by main for flicker
var lamp_on := false
var coyote_t := 0.0
var buffer_t := 0.0
var facing := 1
var squash := Vector2.ONE
var dig_anim := 0.0
var sprite := Sprite2D.new()
var anim := "idle"
var anim_t := 0.0
var dig_kind := ""
var last_dig_kind := ""
var dig_hold := 0.0
var cone := PointLight2D.new()
var glow := PointLight2D.new()


func _ready() -> void:
	floor_max_angle = deg_to_rad(50)
	floor_snap_length = 6.0
	var col := CollisionShape2D.new()
	var shape := CapsuleShape2D.new()
	shape.radius = 7.0
	shape.height = 36.0
	col.shape = shape
	add_child(col)
	sprite.texture = SHEET
	sprite.hframes = 8
	sprite.vframes = 7
	sprite.position = Vector2(0, 18)                 # feet
	sprite.offset = Vector2(0, -FEET_BELOW_CENTER)    # so scaling squashes from the feet
	var unlit := CanvasItemMaterial.new()
	unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED   # always readable, like Dead Cells
	sprite.material = unlit
	add_child(sprite)

	# helmet flashlight cone + small glow around the miner
	cone.texture = _cone_texture()
	cone.texture_scale = 2.3
	cone.color = Color("ffd9a0")
	cone.energy = 1.5
	cone.height = 140.0
	cone.position = Vector2(0, -12)
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
	glow.texture_scale = 1.0
	glow.color = Color("ffcf99")
	glow.energy = 0.8
	glow.height = 90.0
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
	_animate(dt)


func _handle_dig(dt: float, dir: float) -> void:
	var down := Input.is_action_pressed("down")
	var up := Input.is_action_pressed("up")
	var c := global_position
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	var r := 0.0
	dig_kind = ""
	# rock in front of the head/chest: tunnel even when the wall's lip reads as "floor"
	# (or holding a direction without getting anywhere, e.g. pinched by a tunnel's rounded end)
	var blocked := dir != 0 and (is_on_wall() or absf(get_real_velocity().x) < 20.0 \
		or not world.is_air(c + Vector2(dir * 10, -14)) or not world.is_air(c + Vector2(dir * 10, 2)))
	if down and dir != 0:                       # diagonal: body-sized hole ahead + floor ahead
		var res := _dig_side(c, dir, dt)
		var res2 := world.dig(c + Vector2(dir * 10, 20), c + Vector2(dir * 10, 20), 12.0, dig_power * dt)
		_dig_result(res if res.hit else res2, "dig_down", c + Vector2(dir * 10, 10), dt)
		return
	elif blocked and not up:
		_dig_result(_dig_side(c, dir, dt), "dig_side", c + Vector2(dir * 13, 0), dt)
		return
	elif down:
		a = c + Vector2(0, 21)
		b = a
		r = 13.0
	elif up:
		a = c + Vector2(0, -21)
		b = a
		r = 13.0
	else:
		_dig_result({"hit": false}, "dig_side" if dir != 0 else "", c, dt)
		return
	# straight down gets a bonus so it stays the fastest way deeper (diagonal digs two holes)
	var res := world.dig(a, b, r, dig_power * dt * (1.0 if up else 1.4))
	_dig_result(res, "dig_up" if up else "dig_down", a.lerp(b, 0.5), dt)


## Tunnel sideways, a bit taller than you: a hole ahead that reaches head and feet height at
## your front edge, plus a clearance pass around your body so half-dug cells can't pinch you.
func _dig_side(c: Vector2, dir: float, dt: float) -> Dictionary:
	var res := world.dig(c + Vector2(dir * 13, -16), c + Vector2(dir * 13, 12), 11.0, dig_power * dt)
	var body := world.dig(c + Vector2(0, -15), c + Vector2(0, 10), 10.0, dig_power * dt)
	return res if res.hit else body


func _dig_result(res: Dictionary, kind: String, at: Vector2, dt: float) -> void:
	if res.hit:
		dig_anim += dt
		dig_hold = 0.15
		dig_kind = kind
		digging.emit(at, res.mat)
	else:
		dig_anim = 0
		# keep the swing going briefly between hits so the animation doesn't flicker
		dig_hold -= dt
		dig_kind = last_dig_kind if dig_hold > 0.0 and kind != "" else ""
	if dig_kind != "":
		last_dig_kind = dig_kind


func _update_lamp(dt: float) -> void:
	var aim := 0.0 if facing > 0 else PI
	if Input.is_action_pressed("down"):
		aim = PI / 2
	elif Input.is_action_pressed("up"):
		aim = -PI / 2
	cone.rotation = lerp_angle(cone.rotation, aim, 10.0 * dt)
	cone.position = Vector2(4 * facing, -20)
	cone.enabled = lamp_on
	glow.enabled = lamp_on
	cone.energy = 2.4 * light_mul
	glow.energy = 1.1 * light_mul


func _animate(dt: float) -> void:
	var want := "idle"
	if dig_kind != "":
		want = dig_kind
	elif not is_on_floor():
		want = "jump" if velocity.y < 0 else "fall"
	elif absf(velocity.x) > 15:
		want = "run"
	if want != anim:
		anim = want
		anim_t = 0.0
	var a: Array = ANIMS[anim]
	var speed := 1.0
	if anim == "run":
		speed = clampf(absf(velocity.x) / SPEED, 0.4, 1.2)
	anim_t += dt * a[2] * speed
	sprite.frame = a[0] * 8 + int(anim_t) % int(a[1])
	sprite.flip_h = facing < 0
	sprite.scale = squash


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
