extends CharacterBody2D
class_name Player
## The little digger: tight platformer controls, the grapple and tools, health, animation, helmet lamp.
## Digging lives in the Pickaxe child (pickaxe.gd). Group "player".
## Online, the host simulates every miner; on clients they're puppets showing the host's state
## (net_state / net_apply, see src/net/net_entities.gd).

signal health_changed(health: int, max_health: int)
signal bag_changed
signal went_down                       # health ran out: down, bleeding out, a crewmate can help
signal bled_out                        # nobody helped in time (main respawns them in the drill)
signal revived
signal kicked_dust(at: Vector2, strength: float)   # steps, jumps, landings
signal breath_changed(left: float)                 # 0..1 while underwater, 1 = full
signal pinged(at: Vector2)                         # marked a spot for the crew
signal message(text: String)                       # something for this player's screen only

const SPEED := 150.0
const ACCEL := 1300.0
const FRICTION := 1800.0
const GRAVITY := 1100.0
const JUMP_V := -390.0
const MAX_FALL := 560.0
const COYOTE := 0.1
const JUMP_BUFFER := 0.12
const INVULNERABLE := 1.0      # seconds after a hit
const HALF_HEIGHT := 18.0
const SWIM_UP := -120.0         # holding jump in water
const WATER_DRAG := 0.55        # how much slower you move in water
const BREATH := 8.0             # seconds of air underwater
const LAVA_HURT_EVERY := 0.45
const ROLL_SPEED := 270.0
const ROLL_TIME := 0.32        # untouchable for the whole roll
const ROLL_COOLDOWN := 0.55
const BLEED_OUT := 30.0         # seconds down before it's too late to help them up
const CARRY_SPEED := 0.65       # how fast you go with a crewmate on your shoulders
const BAG := 15                 # ore + coal you can carry (more with the sled, as a miner)

# each miner's work clothes and name tag: blue, red, green, violet (by player number)
const CREW_COLORS := [Color("3f8fd8"), Color("d84a3f"), Color("4fb84a"), Color("9a5ad8")]
const CREW_SHADER := preload("res://src/player/crew_color.gdshader")
const SHEET := "res://assets/sprites/miner.png"
const SHEET_INFO := "res://assets/sprites/miner.json"
# fps and whether the animation loops; rows/frame counts come from miner.json
const ANIM_SPEED := {
	"idle": [4.0, true], "run": [13.0, true], "jump": [10.0, false], "fall": [6.0, true],
	"land": [14.0, false], "climb": [9.0, true], "hurt": [10.0, false], "roll": [18.0, false],
	"swim": [8.0, true], "down": [3.0, true], "carried": [4.0, true], "carry": [13.0, true],
	"throw": [20.0, false],
}
# used while the sheet doesn't have an animation yet
const ANIM_FALLBACK := {"land": "idle", "climb": "fall", "hurt": "fall", "roll": "land", "swim": "fall",
	"down": "hurt", "carried": "hurt", "carry": "run", "throw": "dig_side"}

var world: World
var pick := Pickaxe.new()
var interactor := Interactor.new()
var tools := PlayerTools.new()
var role := "miner"              # Roles: miner / engineer / gunner / medic
var carrying: Player = null      # a downed crewmate on your shoulders
var carried_by: Player = null    # (downed) who's carrying you
var sled: OreSled = null         # follows you once the ore sled is bought
var input := PlayerInput.new()   # whose controls drive this player (set before adding)
var number := 1                  # player 1, 2 ... (sets their colour)
var display_name := ""           # shown on their name tag ("" = "P<number>")
var peer := 1                    # online: the machine whose controls drive this miner (1 = host)
var puppet := false              # online client: shows the host's miner, doesn't simulate it
# what you carry (each player has their own bag)
var ore_count := 0
var ore_value := 0
var coal := 0
var sold_value := 0            # this run: ore sold at the workbench
var health := 3
var max_health := 3
var frozen := false            # e.g. while the shop is open
var light_mul := 1.0           # set by main for flicker
var lamp_on := false
var facing := 1
var sprite := Sprite2D.new()
var anim := "idle"

var _anims := {}               # name -> [row, frames]
var _anim_t := 0.0
var _coyote_t := 0.0
var _buffer_t := 0.0
var _land_t := 0.0
var _hurt_t := 0.0
var _invuln_t := 0.0
var _roll_t := 0.0
var _roll_cool := 0.0
var _roll_dir := 1
var in_water := false
var breath := BREATH
var _lava_t := 0.0
var _drown_t := 0.0
var _last_step_frame := -1
var _cone := PointLight2D.new()
var _glow := PointLight2D.new()
var _lamp_dir := 0               # where the helmet lamp points: 0 ahead, 1 down, -1 up
var _tag := Label.new()          # name over their head (shown when there's a crew)
var downed := false              # out of health, on the ground, waiting for help
var bleed := 0.0                 # seconds left to help them up
var _revive_spot: ReviveSpot = null
var _throw_t := 0.0


func _ready() -> void:
	add_to_group("player")
	add_to_group("net")
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
	tools.player = self
	add_child(tools)
	max_health = Progress.max_health()
	health = max_health


func _physics_process(dt: float) -> void:
	_update_sled()
	if puppet:
		_update_lamp(dt)
		pick.show_trail(dt)
		return
	input.update(self)
	_throw_t -= dt
	if downed:
		_lie_there(dt)
		return
	if tools.haul(dt):
		_animate(dt)
		return
	var dir := 0.0 if frozen else input.axis("left", "right")
	if dir != 0:
		facing = int(sign(dir))
	_roll_cool -= dt
	if not frozen and _roll_t <= 0.0 and _roll_cool <= 0.0 and carrying == null \
			and input.just_pressed("roll") and pick.kind == "":
		_start_roll(dir)
	_liquids(dt)
	if _roll_t > 0.0:
		_roll(dt)
	else:
		_move(dt, dir)
	if not frozen and _roll_t <= 0.0 and carrying == null:       # (hands full while carrying)
		pick.update(dt, dir)
		tools.update(dt)
	if not frozen and input.just_pressed("ping"):
		pinged.emit(aim_point())
	_update_lamp(dt)
	_invuln_t -= dt
	_hurt_t -= dt
	_land_t -= dt
	sprite.visible = _invuln_t <= 0.0 or fmod(_invuln_t, 0.12) > 0.05
	_animate(dt)


# ---------------------------------------------------------------- movement

func _move(dt: float, dir: float) -> void:
	var was_on_floor := is_on_floor()
	if in_water:          # floaty: slow sinking, hold jump to swim up
		velocity.y = minf(velocity.y + GRAVITY * 0.25 * dt, 70.0)
		if not frozen and input.pressed("jump"):
			velocity.y = move_toward(velocity.y, SWIM_UP, 900.0 * dt)
	else:
		velocity.y = minf(velocity.y + GRAVITY * dt, MAX_FALL)
	_coyote_t = COYOTE if is_on_floor() else _coyote_t - dt
	_buffer_t = JUMP_BUFFER if (not frozen and input.just_pressed("jump")) else _buffer_t - dt
	if _buffer_t > 0 and _coyote_t > 0:
		velocity.y = JUMP_V
		_buffer_t = 0
		_coyote_t = 0
		Sfx.play("jump", global_position, -8.0)
		kicked_dust.emit(global_position + Vector2(0, HALF_HEIGHT), 0.5)
	if input.just_released("jump") and velocity.y < 0:
		velocity.y *= 0.5
	if _hurt_t > 0.0:
		pass                       # knocked back: no control for a moment
	elif dir != 0:
		var top := SPEED * (WATER_DRAG if in_water else 1.0) * (CARRY_SPEED if carrying else 1.0)
		velocity.x = move_toward(velocity.x, dir * top, ACCEL * dt)
	else:
		velocity.x = move_toward(velocity.x, 0, FRICTION * dt)
	var fall_speed := velocity.y
	move_and_slide()
	if is_on_floor() and not was_on_floor and fall_speed > 150:
		_land_t = 0.16
		Sfx.play("land", global_position + Vector2(0, HALF_HEIGHT), -4.0 if fall_speed > 400 else -10.0)
		kicked_dust.emit(global_position + Vector2(0, HALF_HEIGHT), clampf(fall_speed / 350.0, 0.4, 1.5))


## Water: you float and swim (slower, hold jump to rise), and run out of breath with your head
## under. Lava: it burns, and throws you up out of it.
func _liquids(dt: float) -> void:
	var body := world.liquid_at(global_position)
	var head := world.liquid_at(global_position + Vector2(0, -14))
	var feet := world.liquid_at(global_position + Vector2(0, HALF_HEIGHT - 2))
	var was := in_water
	var drill := get_tree().get_first_node_in_group("drill") as Drill
	var cabin_body := drill != null and drill.flooding.flooded_at(global_position)
	var cabin_head := drill != null and drill.flooding.flooded_at(global_position + Vector2(0, -14))
	in_water = (body.y == Liquids.WATER and body.x > 0.4) or cabin_body
	if in_water and not was and velocity.y > 120.0:
		Sfx.play("splash", global_position, -6.0)
		kicked_dust.emit(global_position, 0.8)
	var under := (head.y == Liquids.WATER and head.x > 0.5) or cabin_head
	if under:
		breath = maxf(breath - dt, 0.0)
		if breath == 0.0:
			_drown_t -= dt
			if _drown_t <= 0.0:
				_drown_t = 1.0
				_invuln_t = 0.0
				hurt(1, global_position + Vector2(0, 10))
	else:
		breath = minf(breath + dt * 3.0, BREATH)
		_drown_t = 0.0
	breath_changed.emit(breath / BREATH)
	_lava_t -= dt
	if (feet.y == Liquids.LAVA and feet.x > 0.2) or (body.y == Liquids.LAVA and body.x > 0.2):
		if _lava_t <= 0.0:
			_lava_t = LAVA_HURT_EVERY
			_invuln_t = 0.0
			hurt(1, global_position + Vector2(0, 20))
			velocity.y = JUMP_V * 0.9
			Sfx.play("sizzle", global_position)


## A quick dodge roll the way you're moving (or facing): fast, low, and nothing can hurt you.
func _start_roll(dir: float) -> void:
	_roll_dir = int(sign(dir)) if dir != 0 else facing
	facing = _roll_dir
	_roll_t = ROLL_TIME
	_roll_cool = ROLL_TIME + ROLL_COOLDOWN
	_anim_t = 0.0
	Sfx.play("roll", global_position, -6.0)
	kicked_dust.emit(global_position + Vector2(0, HALF_HEIGHT), 0.6)


func _roll(dt: float) -> void:
	_roll_t -= dt
	var k := _roll_t / ROLL_TIME             # fast at first, easing out
	velocity.x = _roll_dir * ROLL_SPEED * (0.4 + 0.6 * k)
	velocity.y = minf(velocity.y + GRAVITY * dt, MAX_FALL)
	move_and_slide()


func is_rolling() -> bool:
	return _roll_t > 0.0


# ---------------------------------------------------------------- controls for stations
# (what this player is pointing at / pressing; per player so co-op can feed them from the network)

var aim_override := Vector2.INF   # tests / remote players aim without the local mouse


func aim_point() -> Vector2:
	if aim_override != Vector2.INF:
		return aim_override
	if input.uses_mouse:
		return get_global_mouse_position()
	var d := Vector2(input.axis("left", "right"), input.axis("up", "down"))   # stick aims
	return global_position + (d.normalized() if d.length() > 0.2 else Vector2(facing, 0)) * 300.0


func wants_fire() -> bool:
	return input.pressed("dig")


func wants_leave() -> bool:
	return input.just_pressed("interact") or input.just_pressed("ui_cancel")


# ---------------------------------------------------------------- bag

## Room left in the bag (ore and coal count alike).
func bag_space() -> int:
	return BAG + Progress.bag_bonus() + Roles.bag_bonus(role) - ore_count - coal


## Puts ore in the bag; false (and a word to the player) when it's full.
func add_ore(kind: int) -> bool:
	if bag_space() <= 0:
		tell("Bag full! Sell your ore at the drill's workbench.")
		return false
	if kind == World.COAL:
		coal += 1
	else:
		ore_count += 1
		ore_value += World.ORES[kind][1]
	bag_changed.emit()
	return true


func add_value(value: int) -> void:
	ore_count += 1
	ore_value += value
	bag_changed.emit()


## Hands over the metal ore's value and empties that part of the bag.
func take_ore_value() -> int:
	var v := ore_value
	sold_value += v
	ore_count = 0
	ore_value = 0
	bag_changed.emit()
	return v


func take_coal() -> int:
	var c := coal
	coal = 0
	bag_changed.emit()
	return c


## Restocked at the workbench (flares, dynamite).
func restock() -> void:
	tools.restock()
	bag_changed.emit()


func tell(text: String) -> void:
	message.emit(text)


func start_throw() -> void:
	_throw_t = 0.3
	_anim_t = 0.0


# ---------------------------------------------------------------- carrying the downed

## Hoists a downed crewmate onto your shoulders (they bleed slower while carried).
func carry(other: Player) -> void:
	if carrying or not other.downed or other.carried_by:
		return
	carrying = other
	other.carried_by = self
	Sfx.play("land", global_position, -6.0)


func drop_carried() -> void:
	if carrying == null:
		return
	var other := carrying
	carrying = null
	other.carried_by = null
	other.global_position = global_position + Vector2(facing * 14.0, 0)
	other.velocity = Vector2.ZERO


## The ore sled (an upgrade) trails behind you; on every machine, it's only for show.
func _update_sled() -> void:
	if sled == null and Progress.level("sled") > 0 and is_inside_tree():
		sled = OreSled.new()
		sled.player = self
		get_parent().add_child.call_deferred(sled)
		tree_exiting.connect(sled.queue_free)


func lose_bag() -> void:
	ore_count = 0
	ore_value = 0
	coal = 0
	bag_changed.emit()


# ---------------------------------------------------------------- health

func hurt(damage: int, from: Vector2) -> void:
	if _invuln_t > 0.0 or _roll_t > 0.0 or health <= 0:
		return
	health = maxi(health - damage, 0)
	_invuln_t = INVULNERABLE
	drop_carried()                      # (a hit makes you drop whoever you carry)
	_hurt_t = 0.3
	var away := signf(global_position.x - from.x)
	velocity = Vector2((away if away != 0 else -facing) * 180.0, -220.0)
	Sfx.play("player_hurt", global_position)
	health_changed.emit(health, max_health)
	if health == 0:
		_go_down()


## Out of health: down on the ground. A crewmate can help them up (ReviveSpot) until they
## bleed out.
func _go_down() -> void:
	downed = true
	bleed = BLEED_OUT
	_revive_spot = ReviveSpot.new()
	_revive_spot.downed = self
	add_child(_revive_spot)
	went_down.emit()


func _lie_there(dt: float) -> void:
	bleed -= dt * (0.5 if carried_by else 1.0)       # carried, you bleed slower
	if carried_by:
		global_position = carried_by.global_position + Vector2(0, -26)
		facing = carried_by.facing
		velocity = Vector2.ZERO
	else:
		velocity.x = move_toward(velocity.x, 0.0, FRICTION * dt)
		velocity.y = minf(velocity.y + GRAVITY * dt, MAX_FALL)
		move_and_slide()
	sprite.visible = true
	_animate(dt)
	if bleed <= 0.0:
		_get_up()
		bled_out.emit()


## A crewmate helped them up: back on their feet with a sliver of health (more from a medic).
func revive(by: Player = null) -> void:
	if not downed:
		return
	_get_up()
	health = Roles.revive_health(by.role) if by else 1
	_invuln_t = 2.0
	Sfx.play("repair", global_position, -4.0)
	health_changed.emit(health, max_health)
	revived.emit()


func _get_up() -> void:
	downed = false
	if carried_by:
		carried_by.carrying = null
		carried_by = null
	if _revive_spot:
		_revive_spot.queue_free()
		_revive_spot = null


func is_hurt() -> bool:
	return health < Progress.max_health()


func heal_full() -> void:
	_get_up()
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
	sprite.texture = Art.lit(SHEET)
	sprite.hframes = int(info.columns)
	sprite.vframes = rows
	sprite.position = Vector2(0, HALF_HEIGHT)                  # feet
	sprite.offset = Vector2(0, -float(info.feet_below_center))
	if not Art.has_normals(SHEET):      # no normal map yet: keep it flat and always readable
		var unlit := CanvasItemMaterial.new()
		unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		sprite.material = unlit
	else:
		var m := ShaderMaterial.new()
		m.shader = CREW_SHADER
		sprite.material = m
	add_child(sprite)
	_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tag.size = Vector2(80, 10)
	_tag.position = Vector2(-40, -HALF_HEIGHT - 16)
	_tag.add_theme_font_size_override("font_size", 8)
	_tag.add_theme_color_override("font_outline_color", Color.BLACK)
	_tag.add_theme_constant_override("outline_size", 3)
	_tag.visible = false
	_tag.z_index = 4
	var unshaded := CanvasItemMaterial.new()
	unshaded.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED   # readable in the dark
	_tag.material = unshaded
	add_child(_tag)
	update_crew_look()


func crew_color() -> Color:
	return CREW_COLORS[(number - 1) % CREW_COLORS.size()]


func tag_name() -> String:
	return display_name if display_name != "" else "P%d" % number


## Clothes and name tag in this player's colour (after their number or name changes).
func update_crew_look() -> void:
	if sprite.material is ShaderMaterial:
		var c := crew_color()
		(sprite.material as ShaderMaterial).set_shader_parameter("hue", c.h)
		(sprite.material as ShaderMaterial).set_shader_parameter("saturation", 1.0 if number == 1 else 1.25)
	_tag.text = tag_name()
	_tag.add_theme_color_override("font_color", crew_color().lightened(0.35))


func show_tag(on: bool) -> void:
	_tag.visible = on and visible


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
	if not puppet:
		_lamp_dir = 1 if input.pressed("down") else (-1 if input.pressed("up") else 0)
	var aim := 0.0 if facing > 0 else PI
	if _lamp_dir != 0:
		aim = PI / 2 * _lamp_dir
	var reach := Progress.lamp_scale()
	_cone.rotation = lerp_angle(_cone.rotation, aim, 10.0 * dt)
	_cone.position = Vector2(4 * facing, -20)
	_cone.texture_scale = 2.3 * reach
	_glow.texture_scale = reach * 1.15
	_cone.enabled = lamp_on
	_glow.enabled = lamp_on
	_cone.energy = 2.4 * light_mul
	_glow.energy = 1.35 * light_mul     # enough to always read the miner, like Dead Cells' hero


func _animate(dt: float) -> void:
	var dig := pick.anim()
	var want := "idle"
	if downed:
		want = "carried" if carried_by else "down"
	elif carrying:
		want = "carry" if absf(velocity.x) > 15.0 or not is_on_floor() else "idle"
	elif _throw_t > 0.0:
		want = "throw"
	elif dig != "":
		want = dig
	elif _hurt_t > 0.0:
		want = "hurt"
	elif _roll_t > 0.0:
		want = "roll"
	elif in_water and not is_on_floor():
		want = "swim"
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
		_anim_t += dt * rate
		frame = int(_anim_t) % int(a[1]) if spd[1] else mini(int(_anim_t), int(a[1]) - 1)
	sprite.frame = a[0] * sprite.hframes + frame
	sprite.flip_h = facing < 0
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


# ---------------------------------------------------------------- online co-op

func net_state() -> Array:
	return [peer, number, display_name, sprite.frame, facing, sprite.visible, visible, health, max_health, breath,
		ore_count, ore_value, coal, 0, sold_value, _lamp_dir, pick.kind, pick.trail_age(),
		interactor.prompt_text(), frozen, downed, bleed, tools.net_state(), role, carrying != null]


func net_apply(s: Array) -> void:
	peer = s[0]
	if number != s[1] or display_name != s[2]:
		number = s[1]
		display_name = s[2]
		update_crew_look()
	sprite.frame = s[3]
	facing = s[4]
	sprite.flip_h = facing < 0
	sprite.visible = s[5]
	visible = s[6]
	if health != s[7] or max_health != s[8]:
		health = s[7]
		max_health = s[8]
		health_changed.emit(health, max_health)
	if breath != s[9]:
		breath = s[9]
		breath_changed.emit(breath / BREATH)
	var bag := [ore_count, ore_value, coal, 0, sold_value]
	if bag != s.slice(10, 15):
		ore_count = s[10]
		ore_value = s[11]
		coal = s[12]
		sold_value = s[14]
		bag_changed.emit()
	_lamp_dir = s[15]
	pick.show_swing(s[16], s[17])
	interactor.show_prompt(s[18])
	frozen = s[19]
	downed = s[20]
	bleed = s[21]
	tools.net_apply(s[22])
	role = s[23]
