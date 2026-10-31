extends Node2D
class_name Turret
## A harpoon-bolt cannon on the drill's hull (one per side), aimed and fired by whoever sits
## in the gunner's seat. It swivels toward the aim at servo speed; bolts fly until they hit a
## creature (group "hittable") or rock. Aims through 16 rendered angle frames
## (assets/drill/turret_*.png) when they exist; until then the gun is drawn from shapes.

signal bolt_hit(pos: Vector2, on_rock: bool)

const DIR := "res://assets/drill/"
const TURN := 2.5              # radians per second
const COOLDOWN := 0.55
const BOLT_SPEED := 640.0
const BOLT_LIFE := 1.2
const DAMAGE := 3
const MUZZLE := 16.0

var side := 1                  # +1 right side of the hull, -1 left
var world: World
var aim := 0.0                 # radians from pointing straight out: -PI/2 up .. PI/2 down
var _want := 0.0
var _cool := 0.0
var _recoil := 0.0
var _sprite := Sprite2D.new()
var _frames := 0
var _step := deg_to_rad(12.0)
var _first := -PI / 2.0
var _muzzle := MUZZLE
var _servo := AudioStreamPlayer2D.new()


func _ready() -> void:
	var info_path := DIR + "turret.json"
	if ResourceLoader.exists(info_path):
		var info = JSON.parse_string(FileAccess.get_file_as_string(info_path))
		_frames = int(info.frames)
		_step = deg_to_rad(float(info.step_deg))
		_first = deg_to_rad(float(info.first_angle_deg))
		_muzzle = float(info.get("muzzle_len_px", MUZZLE))
		_sprite.texture = Art.lit(DIR + ("turret_r.png" if side > 0 else "turret_l.png"))
		_sprite.hframes = _frames
		_sprite.vframes = 2 if info.has("recoil_row") else 1
		add_child(_sprite)
	_servo.stream = Sfx.looping("turret_turn")
	add_child(_servo)


## Swing toward a world point (only within this side's half: straight up to straight down).
func aim_at(p: Vector2) -> void:
	var d := p - global_position
	_want = clampf(atan2(d.y, d.x * side), -PI / 2.0, PI / 2.0)


func fire() -> void:
	if _cool > 0.0:
		return
	_cool = COOLDOWN
	_recoil = 1.0
	var dir := _dir()
	var b := Bolt.new()
	b.turret = self
	b.world = world
	b.position = global_position + dir * _muzzle
	b.velocity = dir * BOLT_SPEED
	get_tree().current_scene.add_child(b)
	Sfx.play("turret_fire", global_position)


## Online: where it's turning to and its kick (host), shown on a client (which turns it itself).
func target_aim() -> float:
	return _want


func recoil() -> float:
	return _recoil


func show_aim(want: float, kick: float) -> void:
	_want = want
	if kick > _recoil:
		_recoil = kick


func _dir() -> Vector2:
	return Vector2(cos(aim) * side, sin(aim))


func _process(dt: float) -> void:
	_cool -= dt
	_recoil = maxf(_recoil - dt * 6.0, 0.0)
	var before := aim
	aim = move_toward(aim, _want, TURN * dt)
	var turning := absf(aim - before) > 0.0001
	if turning and not _servo.playing and _servo.stream:
		_servo.play()
	elif not turning and _servo.playing:
		_servo.stop()
	if _frames > 0:
		var f := clampi(int(round((aim - _first) / _step)), 0, _frames - 1)
		_sprite.frame = f + (_frames if _sprite.vframes > 1 and _recoil > 0.4 else 0)
	queue_redraw()


func _draw() -> void:
	if _frames > 0:
		return
	# placeholder until the rendered frames exist: a mount and a barrel drawn from shapes
	var d := _dir()
	var n := Vector2(-d.y, d.x)
	var back := -d * 3.0 * _recoil
	var tip := d * MUZZLE + back
	draw_colored_polygon(PackedVector2Array([back + n * 3.0, tip + n * 2.0, tip - n * 2.0, back - n * 3.0]), Color("3a3f47"))
	draw_line(back + n * 1.0, tip + n * 1.0, Color("7d8591"), 1.0)
	draw_circle(Vector2.ZERO, 6.0, Color("0c0a0e"))
	draw_circle(Vector2.ZERO, 5.0, Color("59606b"))
	draw_rect(Rect2(-side * 9.0 - 3.0, -6.0, 6.0, 12.0), Color("3a3f47"))


## A harpoon bolt in flight.
class Bolt extends Node2D:
	var turret: Turret
	var world: World
	var velocity := Vector2.ZERO
	var puppet := false        # online client: the host's bolt, just drawn
	var _life := BOLT_LIFE

	func _ready() -> void:
		add_to_group("net")

	func net_state() -> Array:
		return [velocity]

	func net_apply(s: Array) -> void:
		velocity = s[0]

	func _physics_process(dt: float) -> void:
		if puppet:
			queue_redraw()
			return
		_life -= dt
		if _life <= 0.0:
			queue_free()
			return
		var step := velocity * dt
		var n := int(ceil(step.length() / 4.0))       # check every 4 px so it can't skip through
		for i in n:
			position += step / n
			for h in get_tree().get_nodes_in_group("hittable"):
				var hit_me: bool = h.is_hit_by(position) if h.has_method("is_hit_by") \
					else (h as Node2D).global_position.distance_to(position) < 12.0
				if hit_me:
					h.hit(DAMAGE, position - velocity.normalized() * 20.0)
					turret.bolt_hit.emit(position, false)
					queue_free()
					return
			if world.is_diggable(position):
				world.dig(position, position, 8.0, 4.0, false)
				Sfx.play("bolt_hit", position)
				turret.bolt_hit.emit(position, true)
				queue_free()
				return
		queue_redraw()

	func _draw() -> void:
		var back := -velocity.normalized() * 7.0
		draw_line(back, Vector2.ZERO, Color("c9ccd1"), 2.0)
		draw_line(back * 0.3, Vector2.ZERO, Color(2.0, 1.6, 1.0), 1.0)
