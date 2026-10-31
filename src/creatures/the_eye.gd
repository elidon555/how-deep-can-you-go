extends Node2D
class_name TheEye
## What lives at the bottom: a colossal eye set into the Floor. It sleeps until something knocks
## (the drill's cutters striking the Floor). Awake, it watches the drill, spits orbs at it and
## the crew, and calls worms up through the rock; glowing veins in the Floor feed it, and while
## any vein lives nothing can hurt the eye. Break the veins and it opens fully: then it can be
## killed. Dying, it cracks the Floor open (the ending).
## Drawn from its rendered sheet (assets/sprites/eye.png, eye.json) when present, shapes until.

signal woke
signal health_changed(frac: float)
signal died(pos: Vector2)

const HP := 60
const ORB_EVERY := 4.5
const WORM_EVERY := 14.0
const VEINS := 3
const SHEET := "res://assets/sprites/eye.png"
const SHEET_GLOW := "res://assets/sprites/eye_glow.png"
const SHEET_INFO := "res://assets/sprites/eye.json"
const RX := 64.0               # the eye's half-width and height above the floor (hit area)
const RY := 60.0

enum State { ASLEEP, WAKING, GUARDED, OPEN, DYING, DEAD }

var world: World
var drill: Drill
var spawner: Spawner
var glow_parent: Node
var state := State.ASLEEP
var hp := HP
var veins: Array = []
var _t := 0.0
var _orb_t := ORB_EVERY
var _worm_t := 5.0
var _hurt_t := 0.0
var _anim_t := 0.0
var _sprite := Sprite2D.new()
var _glow := Sprite2D.new()
var _anims := {}
var _pulse := AudioStreamPlayer2D.new()


func _ready() -> void:
	add_to_group("boss")
	if ResourceLoader.exists(SHEET_INFO):
		var info = JSON.parse_string(FileAccess.get_file_as_string(SHEET_INFO))
		for name in info.anims:
			_anims[name] = [int(info.anims[name].row), int(info.anims[name].frames)]
		for s in [_sprite, _glow]:
			s.hframes = int(info.columns)
			s.vframes = _anims.size()
			s.centered = false
			s.offset = Vector2(-float(info.cell_w) / 2.0, -float(info.cell_h))     # bottom-centre on the floor
		_sprite.texture = Art.lit(SHEET)
		add_child(_sprite)
		if ResourceLoader.exists(SHEET_GLOW) and glow_parent:
			_glow.texture = load(SHEET_GLOW)
			glow_parent.add_child(_glow)
			tree_exiting.connect(_glow.queue_free)
	_pulse.stream = Sfx.looping("vein_pulse")
	_pulse.bus = "SFX"
	_pulse.max_distance = 1400.0
	add_child(_pulse)


## Veins grow out of the Floor at spots spread across the cavern, away from the drill.
func grow_veins(xs: Array) -> void:
	for x: float in xs:
		var v := Vein.new()
		v.eye = self
		v.position = Vector2(x, position.y)
		get_parent().add_child(v)
		veins.append(v)


## Something knocked on the Floor.
func knock() -> void:
	if state != State.ASLEEP:
		return
	state = State.WAKING
	_t = 2.5
	_anim_t = 0.0
	Sfx.play("eye_open", global_position, 6.0)
	if _pulse.stream:
		_pulse.play()
	woke.emit()


func _physics_process(dt: float) -> void:
	_t -= dt
	_hurt_t -= dt
	match state:
		State.WAKING:
			if _t <= 0.0:
				state = State.GUARDED
		State.GUARDED, State.OPEN:
			_attack(dt)
			veins = veins.filter(func(v): return is_instance_valid(v) and v.alive)
			if state == State.GUARDED and veins.is_empty():
				state = State.OPEN
				add_to_group("hittable")
				_anim_t = 0.0
				Sfx.play("eye_hurt", global_position, 6.0)
		State.DYING:
			if _t <= 0.0:
				state = State.DEAD
				died.emit(global_position + Vector2(0, -20))
	_animate(dt)
	queue_redraw()


func _attack(dt: float) -> void:
	var rage := 1.6 if state == State.OPEN else 1.0
	_orb_t -= dt * rage
	if _orb_t <= 0.0:
		_orb_t = ORB_EVERY
		var target := drill.global_position + Vector2(randf_range(-60, 60), 20)
		for p: Player in get_tree().get_nodes_in_group("player"):
			if not drill.contains(p.global_position) and randf() < 0.5:
				target = p.global_position
		var o := Orb.new()
		o.position = global_position + Vector2(0, -50)
		o.velocity = (target - o.position).normalized() * 150.0
		o.drill = drill
		o.world = world
		get_parent().add_child(o)
		Sfx.play("eye_hurt", global_position, -8.0, 0.3)
	_worm_t -= dt * rage
	if _worm_t <= 0.0 and get_tree().get_nodes_in_group("worm").size() < 2:
		_worm_t = WORM_EVERY
		spawner.spawn_worm()


## Turret bolts / the pickaxe: only lands while the eye is open.
func is_hit_by(p: Vector2) -> bool:
	var l := p - global_position
	return l.y < 0.0 and pow(l.x / RX, 2) + pow((l.y + RY * 0.5) / (RY * 0.6), 2) < 1.0


func hit(damage: int, _from: Vector2) -> void:
	if state != State.OPEN:
		return
	hp -= damage
	_hurt_t = 0.25
	health_changed.emit(float(hp) / HP)
	Sfx.play("eye_hurt", global_position, 2.0)
	if hp <= 0:
		state = State.DYING
		_t = 5.0
		_anim_t = 0.0
		remove_from_group("hittable")
		_pulse.stop()
		Sfx.play("eye_die", global_position, 8.0)


func _animate(dt: float) -> void:
	if _anims.is_empty():
		return
	var name := "closed"
	match state:
		State.WAKING:
			name = "opening"
		State.GUARDED, State.OPEN:
			name = "hurt" if _hurt_t > 0.0 else "open_look"
		State.DYING, State.DEAD:
			name = "dying"
	var a: Array = _anims[name]
	_anim_t += dt * 6.0
	var f := 0
	if name == "open_look":           # the iris follows the drill
		var dx := clampf((drill.global_position.x - global_position.x) / 400.0, -1.0, 1.0)
		f = clampi(int(round((dx + 1.0) * 0.5 * (int(a[1]) - 1))), 0, int(a[1]) - 1)
		if state == State.GUARDED and fmod(Time.get_ticks_msec() / 1000.0, 4.0) < 0.15 and _anims.has("blink"):
			a = _anims["blink"]
			f = 1
	elif name == "closed":
		f = int(_anim_t * 0.3) % int(a[1])
	else:
		f = mini(int(_anim_t), int(a[1]) - 1)
	_sprite.frame = a[0] * _sprite.hframes + f
	if _glow.texture:
		_glow.frame = _sprite.frame
		_glow.global_position = global_position
		_glow.modulate.a = 0.4 if state == State.ASLEEP else (1.0 if state != State.DEAD else 0.0)


func _draw() -> void:
	if not _anims.is_empty():
		return
	# placeholder until the rendered eye exists
	var open := 0.0 if state == State.ASLEEP else (1.0 if state != State.DEAD else 0.1)
	draw_circle(Vector2(0, -30), 56.0, Color("3a2a30"))
	draw_circle(Vector2(0, -30), 52.0 * (0.3 + 0.7 * open), Color("d8cfa0"))
	var dx := clampf((drill.global_position.x - global_position.x) / 400.0, -1.0, 1.0) * 20.0
	draw_circle(Vector2(dx, -30), 22.0 * open, Color(1.6, 1.2, 0.4))
	draw_rect(Rect2(dx - 3, -48, 6, 36 * open), Color("120810"))


## A glowing vein feeding the eye: while one lives, the eye can't be hurt. Group "hittable".
class Vein extends Node2D:
	const HP := 15
	var eye: TheEye
	var hp := HP
	var alive := true
	var _sprite := Sprite2D.new()
	var _anims := {}
	var _t := 0.0

	func _ready() -> void:
		add_to_group("hittable")
		var info_path := "res://assets/sprites/vein.json"
		if ResourceLoader.exists(info_path):
			var info = JSON.parse_string(FileAccess.get_file_as_string(info_path))
			for name in info.anims:
				_anims[name] = [int(info.anims[name].row), int(info.anims[name].frames)]
			_sprite.texture = Art.lit("res://assets/sprites/vein.png")
			_sprite.hframes = int(info.columns)
			_sprite.vframes = _anims.size()
			_sprite.centered = false
			_sprite.offset = Vector2(-float(info.cell_w) / 2.0, -float(info.cell_h))
			add_child(_sprite)

	func is_hit_by(p: Vector2) -> bool:
		return alive and p.distance_to(global_position + Vector2(0, -14)) < 18.0

	func hit(damage: int, _from: Vector2) -> void:
		if not alive or eye.state == TheEye.State.ASLEEP:
			return
		hp -= damage
		modulate = Color(2, 2, 2)
		create_tween().tween_property(self, "modulate", Color.WHITE, 0.15)
		if hp <= 0:
			alive = false
			_t = 0.0
			remove_from_group("hittable")
			Sfx.play("vein_burst", global_position, 4.0)
			eye._hurt_t = 0.4

	func _process(dt: float) -> void:
		_t += dt
		if not _anims.is_empty():
			var a: Array = _anims["pulse" if alive else "burst"]
			var f := int(_t * 6.0) % int(a[1]) if alive else mini(int(_t * 8.0), int(a[1]) - 1)
			_sprite.frame = a[0] * _sprite.hframes + f
		queue_redraw()

	func _draw() -> void:
		if not _anims.is_empty():
			return
		var k := 0.85 + 0.15 * sin(_t * 4.0)
		draw_circle(Vector2(0, -12), 12.0 * k if alive else 4.0, Color(1.6, 0.4, 1.2) if alive else Color("2a1820"))


## A glob of violet light the eye spits: drifts at its target, hurts the crew, cracks the hull.
class Orb extends Node2D:
	var velocity := Vector2.ZERO
	var drill: Drill
	var world: World
	var _life := 6.0

	func _ready() -> void:
		var m := CanvasItemMaterial.new()
		m.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED     # it glows
		material = m

	func _physics_process(dt: float) -> void:
		_life -= dt
		position += velocity * dt
		var hit := _life <= 0.0 or not world.is_air(global_position)
		for p: Player in get_tree().get_nodes_in_group("player"):
			if p.global_position.distance_to(global_position) < 14.0:
				p.hurt(1, global_position)
				hit = true
		var l := drill.to_local(global_position)
		if absf(l.x) < Drill.HW and l.y > Drill.TOP and l.y < 108.0:
			drill.damage(8.0, global_position)
			hit = true
		if hit:
			Sfx.play("vein_burst", global_position, -4.0)
			queue_free()
		queue_redraw()

	func _draw() -> void:
		var k := 0.8 + 0.2 * sin(_life * 20.0)
		draw_circle(Vector2.ZERO, 7.0 * k, Color(1.4, 0.5, 2.2, 0.6))
		draw_circle(Vector2.ZERO, 3.5, Color(2.4, 1.8, 2.8))
