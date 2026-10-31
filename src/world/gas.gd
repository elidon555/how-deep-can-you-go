extends Node2D
class_name GasCloud
## Firedamp: a pocket of gas trapped in the rock (WorldGen marks the cells) leaks out as a hissing
## haze when it's dug open, drifts up and thins over time. Any spark inside it (a pick on stone,
## the drill's cutters, a bolt hitting rock, lava) sets it off: a blast that digs a crater,
## hurts the crew and the drill, kills creatures, and sets off other clouds nearby.
## Group "gas". Use GasCloud.release() and GasCloud.spark().

signal exploded(pos: Vector2, size: float)

const LIFE := 25.0             # seconds until a cloud has thinned away
const BASE_R := 22.0           # radius of a one-cell cloud
const R_PER_CELL := 2.5
const MAX_R := 70.0
const DRIFT := Vector2(0, -6)  # px/s, gas rises

var world: World
var volume := 0                # cells of gas released into it
var _age := 0.0
var _haze := CPUParticles2D.new()
var _hiss := AudioStreamPlayer2D.new()
var _gone := false
var puppet := false            # online client: the host's cloud, shown (net_state / net_apply)


## A gas cell was dug open at `pos`: join a cloud nearby or start one. Returns the cloud.
static func release(tree: SceneTree, parent: Node, world: World, pos: Vector2) -> GasCloud:
	for c: GasCloud in tree.get_nodes_in_group("gas"):
		if c.global_position.distance_to(pos) < c.radius():
			c.volume += 1
			c._age = minf(c._age, 4.0)
			return c
	var g := GasCloud.new()
	g.world = world
	g.position = pos
	g.volume = 1
	parent.add_child(g)
	Sfx.play("gas_release", pos, -2.0)
	return g


## A spark at `pos`: every cloud it's inside goes off.
static func spark(tree: SceneTree, pos: Vector2) -> void:
	for c: GasCloud in tree.get_nodes_in_group("gas"):
		if not c._gone and c.global_position.distance_to(pos) < c.radius():
			c.explode()


func radius() -> float:
	var r := minf(BASE_R + volume * R_PER_CELL, MAX_R)
	return r * clampf(1.0 - (_age - LIFE * 0.6) / (LIFE * 0.4), 0.3, 1.0)


func _ready() -> void:
	add_to_group("gas")
	add_to_group("net")
	_haze.amount = 40
	_haze.lifetime = 3.0
	_haze.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_haze.direction = Vector2(0, -1)
	_haze.spread = 180.0
	_haze.initial_velocity_min = 2.0
	_haze.initial_velocity_max = 8.0
	_haze.gravity = Vector2(0, -4)
	_haze.scale_amount_min = 6.0
	_haze.scale_amount_max = 13.0
	_haze.color = Color(0.85, 1.0, 0.35, 0.3)
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0))
	fade.add_point(0.3, Color.WHITE)
	fade.set_color(fade.get_point_count() - 1, Color(1, 1, 1, 0))
	_haze.color_ramp = fade
	var m := CanvasItemMaterial.new()
	m.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED       # a sickly glow you can spot
	_haze.material = m
	add_child(_haze)
	_hiss.stream = Sfx.looping("gas_hiss")
	_hiss.bus = "SFX"
	add_child(_hiss)
	if _hiss.stream:
		_hiss.play()


func _process(dt: float) -> void:
	if _gone:
		return
	_haze.emission_sphere_radius = radius() * 0.8
	_haze.amount = clampi(20 + volume * 2, 20, 90)
	if puppet:
		return
	_age += dt
	position += DRIFT * dt
	# lava inside the cloud lights it
	if fmod(_age, 0.5) < dt:
		for i in 4:
			var p := global_position + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * radius()
			if world.liquid_at(p).y == Liquids.LAVA:
				explode()
				return
	if _age >= LIFE:
		queue_free()


func net_state() -> Array:
	return [volume, _age, _gone]


func net_apply(s: Array) -> void:
	volume = s[0]
	_age = s[1]
	if s[2] and not _gone:
		_gone = true
		_hiss.stop()
		_haze.emitting = false


func explode() -> void:
	if _gone:
		return
	_gone = true
	var size := radius()
	_hiss.stop()
	_haze.emitting = false
	Sfx.play("explosion", global_position, 4.0)
	# the blast digs a crater (breaking rock, not picking ore up)
	world.dig(global_position, global_position, size * 0.6, 12.0, false)
	for p: Player in get_tree().get_nodes_in_group("player"):
		var d := p.global_position.distance_to(global_position)
		if d < size * 1.3:
			p.hurt(2 if d < size * 0.7 else 1, global_position)
	for d: Drill in get_tree().get_nodes_in_group("drill"):
		var l := d.to_local(global_position)
		if absf(l.x) < Drill.HW + size and l.y > Drill.TOP - size and l.y < 108.0 + size:
			d.damage(18.0, global_position)
	for h in get_tree().get_nodes_in_group("hittable"):
		if (h as Node2D).global_position.distance_to(global_position) < size * 1.2:
			h.hit(10, global_position)
	exploded.emit(global_position, size)
	# other clouds caught in the blast go too, a moment later
	for c: GasCloud in get_tree().get_nodes_in_group("gas"):
		if c != self and not c._gone and c.global_position.distance_to(global_position) < size + c.radius():
			c.get_tree().create_timer(0.12).timeout.connect(c.explode)
	queue_free()
