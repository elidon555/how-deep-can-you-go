extends CharacterBody2D
class_name Mite
## A tick-sized cave mite. They come in swarms (the fungal caves teem with them): fast, hopping
## up small steps after whoever is closest, a nip each (1 damage) before they scatter for a
## moment. One hit kills one. They slip into the drill through hull breaches. Shy of flares.
## Group "hittable", "creature", "mite". Online: a puppet on clients.

signal killed(pos: Vector2)

const SPEED := 115.0
const GRAVITY := 900.0
const SIGHT := 280.0
const BITE_DIST := 12.0

enum State { RUN, SCATTER, DEAD }

var world: World
var glow_parent: Node
var puppet := false
var state := State.RUN
var dir := 1
var _t := 0.0
var _anim_t := randf() * 4.0
var _target: Player
var _look: CreatureSprite


func _ready() -> void:
	add_to_group("hittable")
	add_to_group("creature")
	add_to_group("mite")
	add_to_group("net")
	collision_layer = 0
	collision_mask = 1
	var cs := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 3.5
	cs.shape = shape
	add_child(cs)
	_look = CreatureSprite.new(self, "mite", glow_parent, Vector2(0, 3.5))


func _physics_process(dt: float) -> void:
	_anim_t += dt * (14.0 if state != State.DEAD else 8.0)
	if not puppet:
		_think(dt)
	_look.show("die" if state == State.DEAD else "run", _anim_t, dir < 0, state != State.DEAD)
	queue_redraw()


func _think(dt: float) -> void:
	_t -= dt
	velocity.y = minf(velocity.y + GRAVITY * dt, 500.0)
	match state:
		State.RUN:
			_target = _closest()
			var flare := Thrown.scary_near(get_tree(), global_position)
			if flare:
				dir = 1 if global_position.x > flare.global_position.x else -1
			elif _target:
				var to := _target.global_position + Vector2(0, Player.HALF_HEIGHT - 6.0) - global_position   # (the ankles)
				dir = 1 if to.x > 0 else -1
				if to.length() < BITE_DIST:
					_target.hurt(1, global_position)
					state = State.SCATTER
					_t = 0.6
					dir = -dir
				_board(to)
			velocity.x = dir * SPEED if _target or flare else 0.0
			if is_on_floor() and is_on_wall():
				velocity.y = -230.0            # hop up a step
		State.SCATTER:
			velocity.x = dir * SPEED
			if _t <= 0.0:
				state = State.RUN
		State.DEAD:
			velocity.x = 0.0
			modulate.a = clampf(_t / 0.6, 0.0, 1.0)
			if _t <= 0.0:
				queue_free()
	move_and_slide()


## Their target is in the drill and there's a breach: in through it.
func _board(to: Vector2) -> void:
	var d := get_tree().get_first_node_in_group("drill") as Drill
	if d == null or not d.contains(_target.global_position) or d.contains(global_position):
		return
	if to.length() > 150.0:
		return
	for b in d.get_breaches():
		if b.global_position.distance_to(global_position) < 60.0:
			global_position = b.global_position + Vector2(0, 6)
			velocity = Vector2.ZERO
			return


func _closest() -> Player:
	var best: Player = null
	for p: Player in get_tree().get_nodes_in_group("player"):
		var d := p.global_position.distance_to(global_position)
		if p.health > 0 and d < SIGHT and (best == null or d < best.global_position.distance_to(global_position)):
			best = p
	return best


func hit(_damage: int, _from: Vector2) -> void:
	if state == State.DEAD:
		return
	state = State.DEAD
	_t = 0.6
	_anim_t = 0.0
	remove_from_group("hittable")
	Sfx.play("mite_skitter", global_position, -2.0)
	killed.emit(global_position)


func _draw() -> void:
	if not _look.ok:
		draw_circle(Vector2.ZERO, 3.5, Color("6a5a48"))
		draw_rect(Rect2(dir * 2.0, -2, 1, 1), Color(2.4, 0.3, 0.2))


func net_state() -> Array:
	return [state, dir, modulate.a]


func net_apply(s: Array) -> void:
	if s[0] == State.DEAD and state != State.DEAD:
		_anim_t = 0.0
	state = s[0]
	dir = s[1]
	modulate.a = s[2]
