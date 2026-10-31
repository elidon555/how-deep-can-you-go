extends Node2D
class_name Broodmother
## The mid-boss, in the ice: a huge pale cave mother with a glowing egg sac, in a lair the quake
## of her waking tears open beside the drill's shaft (Spawner makes it). Asleep until the crew or
## the drill comes near; awake, she stalks her lair's floor, spits acid at the drill and the
## crew, slams anyone close (and the rock shakes), and drops mites from her sac. Every weapon
## hurts her. Dead: a rich reward. Group "boss", "hittable", "creature". Online: a puppet.

signal woke
signal health_changed(frac: float)
signal died(pos: Vector2)

const HP := 45
const WAKE_DIST := 380.0
const WALK := 42.0
const SPIT_EVERY := 3.5
const SLAM_EVERY := 6.0
const SLAM_REACH := 90.0
const BROOD_EVERY := 12.0
const REWARD := 120

enum State { ASLEEP, AWAKE, SPIT, SLAM, DEAD }

var world: World
var drill: Drill
var glow_parent: Node
var lair := Vector2(0, 0)          # x range (left, right) she walks
var puppet := false
var state := State.ASLEEP
var hp := HP
var facing := -1
var _t := 0.0
var _spit_t := SPIT_EVERY
var _slam_t := SLAM_EVERY
var _brood_t := BROOD_EVERY
var _anim_t := 0.0
var _hurt_t := 0.0
var _look: CreatureSprite


func _ready() -> void:
	add_to_group("boss")
	add_to_group("hittable")
	add_to_group("creature")
	add_to_group("net")
	_look = CreatureSprite.new(self, "brood", glow_parent)


func _physics_process(dt: float) -> void:
	_anim_t += dt * 7.0
	_hurt_t -= dt
	if not puppet:
		_think(dt)
	var anim := "idle"
	match state:
		State.AWAKE:
			anim = "hurt" if _hurt_t > 0.0 else "walk"
		State.SPIT:
			anim = "spit"
		State.SLAM:
			anim = "slam"
		State.DEAD:
			anim = "die"
	_look.show(anim, _anim_t, facing < 0, anim in ["idle", "walk", "hurt"])
	queue_redraw()


func _think(dt: float) -> void:
	_t -= dt
	var target: Vector2 = _target()
	match state:
		State.ASLEEP:
			if target.distance_to(global_position) < WAKE_DIST:
				state = State.AWAKE
				Sfx.play("brood_roar", global_position, 6.0)
				woke.emit()
		State.AWAKE:
			facing = 1 if target.x > global_position.x else -1
			if absf(target.x - global_position.x) > 40.0:
				global_position.x = clampf(global_position.x + facing * WALK * dt, lair.x, lair.y)
			_spit_t -= dt
			_slam_t -= dt
			_brood_t -= dt
			if _slam_t <= 0.0 and _nearest_player_dist() < SLAM_REACH:
				_start(State.SLAM, 0.9)
			elif _spit_t <= 0.0:
				_start(State.SPIT, 0.8)
			elif _brood_t <= 0.0:
				_brood_t = BROOD_EVERY
				_drop_mites()
		State.SPIT:
			if _t <= 0.4 and _spit_t <= 0.0:
				_spit_t = SPIT_EVERY
				_spit(target)
			if _t <= 0.0:
				state = State.AWAKE
		State.SLAM:
			if _t <= 0.45 and _slam_t <= 0.0:
				_slam_t = SLAM_EVERY
				_slam()
			if _t <= 0.0:
				state = State.AWAKE
		State.DEAD:
			modulate.a = clampf(_t / 2.0, 0.0, 1.0)
			if _t <= 0.0:
				queue_free()


func _start(s: State, secs: float) -> void:
	state = s
	_t = secs
	_anim_t = 0.0


## Where to go for: the nearest miner, or the drill if it's closer.
func _target() -> Vector2:
	var best := drill.global_position
	for p: Player in get_tree().get_nodes_in_group("player"):
		if p.health > 0 and p.global_position.distance_to(global_position) < best.distance_to(global_position):
			best = p.global_position
	return best


func _nearest_player_dist() -> float:
	var d := INF
	for p: Player in get_tree().get_nodes_in_group("player"):
		if p.health > 0:
			d = minf(d, p.global_position.distance_to(global_position))
	return d


func _spit(at: Vector2) -> void:
	var o := TheEye.Orb.new()
	o.tint = Color(1.0, 2.2, 0.6)
	o.position = global_position + Vector2(facing * 50.0, -60.0)
	o.velocity = (at - o.position).normalized() * 170.0
	o.drill = drill
	o.world = world
	get_parent().add_child(o)
	Sfx.play("brood_spit", global_position)


func _slam() -> void:
	Sfx.play("explosion", global_position, -4.0)
	for p: Player in get_tree().get_nodes_in_group("player"):
		if p.global_position.distance_to(global_position) < SLAM_REACH:
			p.hurt(2, global_position)
	world.dig(global_position + Vector2(facing * 50.0, 6.0), global_position + Vector2(facing * 50.0, 6.0), 18.0, 6.0, false)
	get_tree().call_group("run", "add_shake", 1.6, global_position)


func _drop_mites() -> void:
	for i in 3:
		var m := Mite.new()
		m.world = world
		m.glow_parent = glow_parent
		m.position = global_position + Vector2(randf_range(-30, 30), -20)
		get_parent().add_child(m)
	Sfx.play("mite_skitter", global_position)


func is_hit_by(p: Vector2) -> bool:
	var l := p - global_position
	return state != State.DEAD and absf(l.x) < 70.0 and l.y < 0.0 and l.y > -90.0


func hit(damage: int, _from: Vector2) -> void:
	if state == State.DEAD:
		return
	if state == State.ASLEEP:
		state = State.AWAKE
		woke.emit()
	hp -= damage
	_hurt_t = 0.25
	health_changed.emit(float(hp) / HP)
	Sfx.play("creature_hurt", global_position, 2.0)
	if hp <= 0:
		_start(State.DEAD, 3.0)
		remove_from_group("hittable")
		Sfx.play("brood_die", global_position, 6.0)
		died.emit(global_position)


func _draw() -> void:
	if _look.ok:
		return
	draw_circle(Vector2(0, -40), 40.0, Color("c9c2b8"))
	draw_circle(Vector2(-facing * 30.0, -50), 24.0, Color(0.8, 1.8, 0.5))


func net_state() -> Array:
	return [state, facing, hp, _hurt_t]


func net_apply(s: Array) -> void:
	if s[0] != state:
		_anim_t = 0.0
	state = s[0]
	facing = s[1]
	hp = s[2]
	_hurt_t = maxf(_hurt_t, s[3])


func is_awake() -> bool:
	return state != State.ASLEEP and state != State.DEAD
