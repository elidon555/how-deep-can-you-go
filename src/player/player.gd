extends CharacterBody2D
class_name Player
## The little digger: tight platformer controls, rope climbing, health, animation, helmet lamp.
## Digging lives in the Pickaxe child (pickaxe.gd). Group "player".

signal health_changed(health: int, max_health: int)
signal bag_changed
signal died
signal rope_requested(feet: Vector2)   # main decides if there's a rope left to hang
signal kicked_dust(at: Vector2, strength: float)   # steps, jumps, landings

const SPEED := 150.0
const ACCEL := 1300.0
const FRICTION := 1800.0
const GRAVITY := 1100.0
const JUMP_V := -390.0
const MAX_FALL := 560.0
const COYOTE := 0.1
const JUMP_BUFFER := 0.12
const CLIMB_SPEED := 110.0
const INVULNERABLE := 1.0      # seconds after a hit
const HALF_HEIGHT := 18.0

const SHEET := "res://assets/sprites/miner.png"
const SHEET_INFO := "res://assets/sprites/miner.json"
# fps and whether the animation loops; rows/frame counts come from miner.json
const ANIM_SPEED := {
	"idle": [4.0, true], "run": [13.0, true], "jump": [10.0, false], "fall": [6.0, true],
	"land": [14.0, false], "climb": [9.0, true], "hurt": [10.0, false],
}
# used while the sheet doesn't have an animation yet
const ANIM_FALLBACK := {"land": "idle", "climb": "fall", "hurt": "fall"}

var world: World
var pick := Pickaxe.new()
var interactor := Interactor.new()
# what you carry (each player has their own bag)
var ore_count := 0
var ore_value := 0
var coal := 0
var ropes := 0
var health := 3
var max_health := 3
var frozen := false            # e.g. while the shop is open
var light_mul := 1.0           # set by main for flicker
var lamp_on := false
var facing := 1
var rope: Rope = null          # the rope being climbed
var sprite := Sprite2D.new()
var anim := "idle"

var _anims := {}               # name -> [row, frames]
var _rope_x := 0.0             # where the hands hold the rope, px right of the sprite centre
var _rope_last_y := 0.0
var _anim_t := 0.0
var _coyote_t := 0.0
var _buffer_t := 0.0
var _squash := Vector2.ONE
var _land_t := 0.0
var _hurt_t := 0.0
var _invuln_t := 0.0
var _last_step_frame := -1
var _cone := PointLight2D.new()
var _glow := PointLight2D.new()


func _ready() -> void:
	add_to_group("player")
	collision_layer = 2            # creatures and boulders check us themselves
	collision_mask = 1
	floor_max_angle = deg_to_rad(50)
	floor_snap_length = 6.0
	var col := CollisionShape2D.new()
	var shape := CapsuleShape2D.new()
	shape.radius = 7.0
	shape.height = HALF_HEIGHT * 2.0
	col.shape = shape
	add_child(col)
	_setup_sprite()
	_setup_lamp()
	pick.player = self
	pick.world = world
	add_child(pick)
	interactor.player = self
	add_child(interactor)
	ropes = Progress.rope_capacity()
	max_health = Progress.max_health()
	health = max_health


func _physics_process(dt: float) -> void:
	var dir := 0.0 if frozen else Input.get_axis("left", "right")
	if dir != 0:
		facing = int(sign(dir))
	if rope == null and not frozen:
		_try_grab_rope()
	if rope:
		_climb(dt, dir)
	else:
		_move(dt, dir)
	if not frozen:
		pick.update(dt, dir)
		if Input.is_action_just_pressed("rope"):
			rope_requested.emit(global_position + Vector2(0, HALF_HEIGHT))
	_update_lamp(dt)
	_invuln_t -= dt
	_hurt_t -= dt
	_land_t -= dt
	sprite.visible = _invuln_t <= 0.0 or fmod(_invuln_t, 0.12) > 0.05
	_squash = _squash.lerp(Vector2.ONE, 12 * dt)
	_animate(dt)


# ---------------------------------------------------------------- movement

func _move(dt: float, dir: float) -> void:
	var was_on_floor := is_on_floor()
	velocity.y = minf(velocity.y + GRAVITY * dt, MAX_FALL)
	_coyote_t = COYOTE if is_on_floor() else _coyote_t - dt
	_buffer_t = JUMP_BUFFER if (not frozen and Input.is_action_just_pressed("jump")) else _buffer_t - dt
	if _buffer_t > 0 and _coyote_t > 0:
		velocity.y = JUMP_V
		_buffer_t = 0
		_coyote_t = 0
		_squash = Vector2(0.75, 1.25)
		Sfx.play("jump", global_position, -8.0)
		kicked_dust.emit(global_position + Vector2(0, HALF_HEIGHT), 0.5)
	if Input.is_action_just_released("jump") and velocity.y < 0:
		velocity.y *= 0.5
	if _hurt_t > 0.0:
		pass                       # knocked back: no control for a moment
	elif dir != 0:
		velocity.x = move_toward(velocity.x, dir * SPEED, ACCEL * dt)
	else:
		velocity.x = move_toward(velocity.x, 0, FRICTION * dt)
	var fall_speed := velocity.y
	move_and_slide()
	if is_on_floor() and not was_on_floor and fall_speed > 150:
		_squash = Vector2(1.25, 0.75)
		_land_t = 0.16
		Sfx.play("land", global_position + Vector2(0, HALF_HEIGHT), -4.0 if fall_speed > 400 else -10.0)
		kicked_dust.emit(global_position + Vector2(0, HALF_HEIGHT), clampf(fall_speed / 350.0, 0.4, 1.5))


## W / Up next to a rope grabs it (instead of jumping); so does Down while falling past one.
func _try_grab_rope() -> void:
	var up := Input.is_action_pressed("up")
	var down := Input.is_action_pressed("down") and not is_on_floor()
	if not (up or down):
		return
	for r: Rope in get_tree().get_nodes_in_group("rope"):
		if r.covers(global_position):
			rope = r
			_rope_last_y = r.global_position.y
			velocity = Vector2.ZERO
			_buffer_t = 0.0
			return


func _climb(dt: float, dir: float) -> void:
	var v := 0.0 if frozen else Input.get_axis("up", "down")
	velocity = Vector2(0, v * CLIMB_SPEED)
	var hold_x := rope.global_position.x - _rope_x * facing     # rope in the hands, not through the body
	global_position.x = move_toward(global_position.x, hold_x, 200.0 * dt)
	global_position.y += rope.global_position.y - _rope_last_y   # ride along if it moves (drill ladders)
	_rope_last_y = rope.global_position.y
	move_and_slide()
	# you can climb until your feet are level with the anchor, so you can step off at the top
	if global_position.y < rope.top_y() - HALF_HEIGHT - 6.0:
		global_position.y = rope.top_y() - HALF_HEIGHT - 6.0
	var jump_off := Input.is_action_just_pressed("jump") and not Input.is_action_pressed("up")
	var off_bottom := global_position.y > rope.bottom_y() and v > 0
	var step_off := dir != 0 and v == 0
	var at_top := global_position.y < rope.top_y() - HALF_HEIGHT + 4.0
	if jump_off or off_bottom or step_off or not is_instance_valid(rope):
		rope = null
		if jump_off:
			velocity = Vector2(facing * 120.0, JUMP_V * 0.6)
		elif step_off and at_top:
			velocity = Vector2(dir * SPEED, JUMP_V * 0.55)   # little hop onto the ledge


# ---------------------------------------------------------------- bag

func add_ore(kind: int) -> void:
	if kind == World.COAL:
		coal += 1
	else:
		ore_count += 1
		ore_value += World.ORES[kind][1]
	bag_changed.emit()


func add_value(value: int) -> void:
	ore_count += 1
	ore_value += value
	bag_changed.emit()


## Hands over the metal ore's value and empties that part of the bag.
func take_ore_value() -> int:
	var v := ore_value
	ore_count = 0
	ore_value = 0
	bag_changed.emit()
	return v


func take_coal() -> int:
	var c := coal
	coal = 0
	bag_changed.emit()
	return c


func refill_ropes() -> void:
	ropes = maxi(ropes, Progress.rope_capacity())
	bag_changed.emit()


func lose_bag() -> void:
	ore_count = 0
	ore_value = 0
	coal = 0
	bag_changed.emit()


# ---------------------------------------------------------------- health

func hurt(damage: int, from: Vector2) -> void:
	if _invuln_t > 0.0 or health <= 0:
		return
	health = maxi(health - damage, 0)
	_invuln_t = INVULNERABLE
	_hurt_t = 0.3
	rope = null
	var away := signf(global_position.x - from.x)
	velocity = Vector2((away if away != 0 else -facing) * 180.0, -220.0)
	Sfx.play("player_hurt", global_position)
	health_changed.emit(health, max_health)
	if health == 0:
		died.emit()


func is_hurt() -> bool:
	return health < Progress.max_health()


func heal_full() -> void:
	max_health = Progress.max_health()
	if health != max_health:
		health = max_health
		health_changed.emit(health, max_health)


# ---------------------------------------------------------------- looks

func _setup_sprite() -> void:
	var info = JSON.parse_string(FileAccess.get_file_as_string(SHEET_INFO))
	var rows := 0
	for name in info.anims:
		_anims[name] = [int(info.anims[name].row), int(info.anims[name].frames)]
		rows = maxi(rows, int(info.anims[name].row) + 1)
	_rope_x = float(info.get("climb_rope_x", 0.0))
	sprite.texture = Art.lit(SHEET)
	sprite.hframes = int(info.columns)
	sprite.vframes = rows
	sprite.position = Vector2(0, HALF_HEIGHT)                  # feet
	sprite.offset = Vector2(0, -float(info.feet_below_center))  # so squashing keeps the feet put
	if not Art.has_normals(SHEET):      # no normal map yet: keep it flat and always readable
		var unlit := CanvasItemMaterial.new()
		unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		sprite.material = unlit
	add_child(sprite)


func _setup_lamp() -> void:
	# helmet flashlight cone + small glow around the miner
	_cone.texture = _cone_texture()
	_cone.color = Color("ffd9a0")
	_cone.height = 140.0
	add_child(_cone)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	_glow.texture = gt
	_glow.color = Color("ffcf99")
	_glow.height = 90.0
	add_child(_glow)


func _update_lamp(dt: float) -> void:
	var aim := 0.0 if facing > 0 else PI
	if Input.is_action_pressed("down"):
		aim = PI / 2
	elif Input.is_action_pressed("up"):
		aim = -PI / 2
	var reach := Progress.lamp_scale()
	_cone.rotation = lerp_angle(_cone.rotation, aim, 10.0 * dt)
	_cone.position = Vector2(4 * facing, -20)
	_cone.texture_scale = 2.3 * reach
	_glow.texture_scale = reach
	_cone.enabled = lamp_on
	_glow.enabled = lamp_on
	_cone.energy = 2.4 * light_mul
	_glow.energy = 1.1 * light_mul


func _animate(dt: float) -> void:
	var dig := pick.anim()
	var want := "idle"
	if dig != "":
		want = dig
	elif _hurt_t > 0.0:
		want = "hurt"
	elif rope:
		want = "climb"
	elif not is_on_floor():
		want = "jump" if velocity.y < 0 else "fall"
	elif _land_t > 0.0 and absf(velocity.x) < 60.0:
		want = "land"
	elif absf(velocity.x) > 15:
		want = "run"
	if not _anims.has(want):
		want = ANIM_FALLBACK.get(want, "idle")
	if want != anim:
		anim = want
		_anim_t = 0.0
	var a: Array = _anims[anim]
	var frame := 0
	if dig != "":
		frame = pick.frame
	else:
		var spd: Array = ANIM_SPEED.get(anim, [8.0, true])
		var rate: float = spd[0]
		if anim == "run":
			rate *= clampf(absf(velocity.x) / SPEED, 0.4, 1.2)
		elif anim == "climb":
			rate *= absf(velocity.y) / CLIMB_SPEED
		_anim_t += dt * rate
		frame = int(_anim_t) % int(a[1]) if spd[1] else mini(int(_anim_t), int(a[1]) - 1)
	sprite.frame = a[0] * sprite.hframes + frame
	sprite.flip_h = facing < 0
	sprite.scale = _squash
	# footsteps on the frames where a boot hits the ground (start and middle of the cycle)
	var half := int(a[1]) / 2
	if anim == "run" and frame != _last_step_frame and (frame == 1 or frame == half + 1):
		Sfx.play("step", global_position + Vector2(0, HALF_HEIGHT), -12.0, 0.12)
		kicked_dust.emit(global_position + Vector2(-facing * 4, HALF_HEIGHT), 0.25)
	_last_step_frame = frame if anim == "run" else -1


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
