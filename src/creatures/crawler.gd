extends CharacterBody2D
class_name Crawler
## A pale six-legged cave crawler. Patrols cave floors; when it sees you it chases (hopping
## up small ledges, never into lava), winds up and lunges to bite. If you're shut inside the
## drill it chews at the hull / hatch. Takes pickaxe hits (group "hittable"), flinches, dies.

signal killed(pos: Vector2)

const GRAVITY := 1000.0
const PATROL_SPEED := 30.0
const CHASE_SPEED := 75.0
const SIGHT := 160.0
const GIVE_UP := 280.0
const LUNGE_RANGE := 40.0
const WINDUP := 0.4
const LUNGE_TIME := 0.3
const RECOVER := 0.6
const HP := 3
const SHEET := "res://assets/sprites/crawler.png"
const SHEET_GLOW := "res://assets/sprites/crawler_glow.png"
const SHEET_INFO := "res://assets/sprites/crawler.json"
const ANIM_FPS := {"walk": 10.0, "lunge": 12.0, "hurt": 10.0, "die": 8.0}

enum State { PATROL, CHASE, WINDUP, LUNGE, RECOVER, HURT, DEAD }

var world: World
var player: Player
var glow_parent: Node          # where the glowing eyes go (bloom layer)
var state := State.PATROL
var hp := HP
var dir := 1
var _t := 0.0
var _anim_t := 0.0
var _bit := false
var _growl_t := 0.0
var _gnaw_t := 1.0
var _hop_t := 0.0
var _sprite := Sprite2D.new()
var _eyes := Sprite2D.new()
var _anims := {}               # name -> [row, frames]


func _ready() -> void:
	add_to_group("hittable")
	add_to_group("creature")
	collision_layer = 4
	collision_mask = 1
	floor_snap_length = 6.0
	var cs := CollisionShape2D.new()
	var shape := CapsuleShape2D.new()
	shape.radius = 8.0
	shape.height = 30.0
	cs.shape = shape
	cs.rotation = PI / 2           # lying down: long and low
	add_child(cs)
	_setup_sprite()
	dir = 1 if randf() < 0.5 else -1


func _physics_process(dt: float) -> void:
	_t -= dt
	_growl_t -= dt
	if state != State.DEAD and world.liquid_at(global_position).y == Liquids.LAVA:
		hit(HP, global_position + Vector2(0, 10))          # lava kills it
		Sfx.play("sizzle", global_position)
	velocity.y = minf(velocity.y + GRAVITY * dt, 600.0)
	var to_player := player.global_position - global_position
	match state:
		State.PATROL:
			velocity.x = dir * PATROL_SPEED
			if is_on_wall() or (is_on_floor() and _ledge_ahead()) or _lava_ahead():
				dir = -dir
			if _sees_player(to_player):
				state = State.CHASE
				if _growl_t <= 0.0:
					_growl_t = 4.0
					Sfx.play("creature_growl", global_position, -2.0)
		State.CHASE:
			dir = 1 if to_player.x > 0 else -1
			velocity.x = dir * CHASE_SPEED
			_hop_t -= dt
			if is_on_floor() and _ledge_ahead() and to_player.y < 10.0:
				velocity.x = 0.0           # don't run off a cliff unless the target is below
			elif is_on_floor() and is_on_wall() and _hop_t <= 0.0 and _can_hop():
				velocity.y = -300.0        # hop up a small ledge toward them
				_hop_t = 0.8
			if _lava_ahead():
				velocity.x = 0.0           # never walk into lava
			_gnaw(dt)
			if absf(to_player.x) < LUNGE_RANGE and absf(to_player.y) < 24.0:
				state = State.WINDUP
				_t = WINDUP
			elif to_player.length() > GIVE_UP:
				state = State.PATROL
		State.WINDUP:
			velocity.x = move_toward(velocity.x, 0.0, 600.0 * dt)
			if _t <= 0.0:
				state = State.LUNGE
				_t = LUNGE_TIME
				_bit = false
				velocity = Vector2(dir * 230.0, -140.0)
		State.LUNGE:
			if not _bit and _touches_player():
				_bit = true
				player.hurt(1, global_position)
			if _t <= 0.0 and is_on_floor():
				state = State.RECOVER
				_t = RECOVER
		State.RECOVER, State.HURT:
			velocity.x = move_toward(velocity.x, 0.0, 500.0 * dt)
			if _t <= 0.0:
				state = State.CHASE
		State.DEAD:
			velocity.x = move_toward(velocity.x, 0.0, 400.0 * dt)
			modulate.a = clampf(_t / 0.8, 0.0, 1.0)
			if _t <= 0.0:
				queue_free()
	move_and_slide()
	_animate(dt)


## Pressed against the drill while hunting someone: chews on the hull.
func _gnaw(dt: float) -> void:
	for i in get_slide_collision_count():
		var d = get_slide_collision(i).get_collider()
		if d is Drill:
			_gnaw_t -= dt
			if _gnaw_t <= 0.0:
				_gnaw_t = 1.4
				d.damage(4.0, global_position)
			return


func hit(damage: int, from: Vector2) -> void:
	if state == State.DEAD:
		return
	hp -= damage
	var away := signf(global_position.x - from.x)
	velocity = Vector2(away * 160.0, -120.0)
	_sprite.modulate = Color(3, 3, 3)
	create_tween().tween_property(_sprite, "modulate", Color.WHITE, 0.15)
	if hp <= 0:
		state = State.DEAD
		_t = 1.2
		_anim_t = 0.0
		Sfx.play("creature_die", global_position)
		killed.emit(global_position)
		remove_from_group("hittable")
	else:
		state = State.HURT
		_t = 0.3
		Sfx.play("creature_hurt", global_position)


func _sees_player(to_player: Vector2) -> bool:
	if to_player.length() > SIGHT:
		return false
	for k in range(1, 8):            # nothing solid in between
		if not world.is_air(global_position + to_player * (k / 8.0)):
			return false
	return true


func _lava_ahead() -> bool:
	return world.liquid_at(global_position + Vector2(dir * 18.0, 6.0)).y == Liquids.LAVA


## A wall in front that's low enough to hop: open air a body-height up.
func _can_hop() -> bool:
	return world.is_air(global_position + Vector2(dir * 18.0, -30.0))


func _ledge_ahead() -> bool:
	return world.is_air(global_position + Vector2(dir * 16.0, 22.0))


func _touches_player() -> bool:
	return player.global_position.distance_to(global_position + Vector2(dir * 10.0, -4.0)) < 22.0


# ---------------------------------------------------------------- looks

func _setup_sprite() -> void:
	if not ResourceLoader.exists(SHEET_INFO):
		_sprite.texture = _placeholder()
		add_child(_sprite)
		return
	var info = JSON.parse_string(FileAccess.get_file_as_string(SHEET_INFO))
	var rows := 0
	for name in info.anims:
		_anims[name] = [int(info.anims[name].row), int(info.anims[name].frames)]
		rows = maxi(rows, int(info.anims[name].row) + 1)
	for s in [_sprite, _eyes]:
		s.hframes = int(info.columns)
		s.vframes = rows
		s.offset = Vector2(0, -float(info.get("feet_below_center", 0.0)))
		s.position = Vector2(0, 8)    # feet at the bottom of the capsule
	_sprite.texture = Art.lit(SHEET)
	add_child(_sprite)
	if ResourceLoader.exists(SHEET_GLOW) and glow_parent:
		_eyes.texture = load(SHEET_GLOW)
		glow_parent.add_child(_eyes)
		tree_exiting.connect(_eyes.queue_free)


func _animate(dt: float) -> void:
	_sprite.flip_h = dir < 0
	if _anims.is_empty():
		return
	var name := "walk"
	match state:
		State.WINDUP, State.LUNGE:
			name = "lunge"
		State.HURT:
			name = "hurt"
		State.DEAD:
			name = "die"
	if not _anims.has(name):
		name = "walk"
	var a: Array = _anims[name]
	var rate: float = ANIM_FPS.get(name, 10.0)
	if name == "walk":   # a cycle moves ~8 px over 6 frames; faster than that the feet slide a bit
		rate = clampf(absf(velocity.x) * 0.75, 0.0, 22.0)
	_anim_t += dt * rate
	var frame := int(_anim_t) % int(a[1]) if name == "walk" else mini(int(_anim_t), int(a[1]) - 1)
	if name == "lunge" and state == State.WINDUP:
		frame = 0
	_sprite.frame = a[0] * _sprite.hframes + frame
	if _eyes.texture:
		_eyes.frame = _sprite.frame
		_eyes.flip_h = _sprite.flip_h
		_eyes.global_position = _sprite.global_position
		_eyes.modulate.a = modulate.a


static func _placeholder() -> Texture2D:
	var img := Image.create(40, 20, false, Image.FORMAT_RGBA8)
	for y in 20:
		for x in 40:
			if Vector2((x - 20) / 18.0, (y - 12) / 8.0).length() < 1.0:
				img.set_pixel(x, y, Color("c9bfc8"))
	img.set_pixel(34, 9, Color(3, 0.4, 0.2))
	img.set_pixel(32, 9, Color(3, 0.4, 0.2))
	return ImageTexture.create_from_image(img)
