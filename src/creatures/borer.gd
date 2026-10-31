extends Node2D
class_name Borer
## An armoured borer: it tunnels through the rock straight for the drill (grinding a little
## tunnel behind it), chews at the hull until it breaks through (a breach) and climbs into the
## cabin. Inside it scuttles along the floor after the crew (bites, 1 damage) and gnaws at a fuse
## box it passes (blows it). Turret bolts, the pickaxe and dynamite kill it. Group "hittable",
## "creature". Online: a puppet on clients.

signal killed(pos: Vector2)

const HP := 5
const BURROW_SPEED := 38.0
const WALK_SPEED := 55.0
const CHEW_TIME := 3.0
const BITE_EVERY := 1.0
const GNAW_TIME := 4.0           # chewing at a fuse box until it blows

enum State { BURROW, CHEW, INSIDE, DEAD }

var world: World
var drill: Drill
var glow_parent: Node
var puppet := false
var state := State.BURROW
var hp := HP
var facing := 1
var _local := Vector2.ZERO        # inside: position in the drill (it moves with it)
var _t := 0.0
var _anim_t := 0.0
var _gnaw := 0.0
var _biting := 0.0
var _look: CreatureSprite
var _drone := AudioStreamPlayer2D.new()


func _ready() -> void:
	add_to_group("hittable")
	add_to_group("creature")
	add_to_group("borer")
	add_to_group("net")
	z_index = 1
	_look = CreatureSprite.new(self, "borer", glow_parent, Vector2(0, 8))
	_drone.stream = Sfx.looping("borer_drill")
	_drone.bus = "SFX"
	_drone.volume_db = -6.0
	_drone.max_distance = 600.0
	add_child(_drone)
	if _drone.stream:
		_drone.play()


func _physics_process(dt: float) -> void:
	_anim_t += dt * 10.0
	_biting -= dt
	if not puppet:
		_think(dt)
	var anim := "burrow"
	match state:
		State.INSIDE:
			anim = "bite" if _biting > 0.0 else "walk"
		State.CHEW:
			anim = "bite"
		State.DEAD:
			anim = "die"
	_look.show(anim, _anim_t, facing < 0, state != State.DEAD)
	_drone.stream_paused = state == State.INSIDE or state == State.DEAD
	queue_redraw()


func _think(dt: float) -> void:
	_t -= dt
	match state:
		State.BURROW:
			var aim := drill.global_position + Vector2(signf(global_position.x - drill.global_position.x) * (Drill.HW + 4.0), 10.0)
			var to := aim - global_position
			facing = 1 if to.x > 0 else -1
			global_position += to.normalized() * BURROW_SPEED * dt
			world.dig(global_position, global_position, 9.0, 8.0 * dt * 6.0, false)
			if to.length() < 10.0 or drill.blocks(global_position + Vector2(facing * 8.0, 0), false):
				state = State.CHEW
				_t = CHEW_TIME
				Sfx.play("borer_hiss", global_position)
		State.CHEW:
			if _t <= 0.0:                     # through: a breach, and in it comes
				drill.damage(6.0, global_position)
				state = State.INSIDE
				_local = Vector2(clampf(drill.to_local(global_position).x, -Drill.HW + 14.0, Drill.HW - 14.0), Drill.FLOOR - 4.0)
				Sfx.play("borer_hiss", global_position, 2.0)
		State.INSIDE:
			var target := _closest_inside()
			if target:
				var tx := drill.to_local(target.global_position).x
				facing = 1 if tx > _local.x else -1
				if absf(tx - _local.x) > 10.0:
					_local.x += facing * WALK_SPEED * dt
				elif _t <= 0.0:
					_t = BITE_EVERY
					_biting = 0.3
					target.hurt(1, global_position)
			_local.x = clampf(_local.x, -Drill.HW + Drill.WALL + 8.0, Drill.HW - Drill.WALL - 8.0)
			global_position = drill.to_global(_local)
			for i in 2:                                  # passing a fuse box: it gnaws at it
				if absf(_local.x - Junction.X[i]) < 14.0 and not drill.power.blown[i]:
					_gnaw += dt
					if _gnaw >= GNAW_TIME:
						_gnaw = 0.0
						drill.power.blow(i)
		State.DEAD:
			if state == State.DEAD and _t <= 0.0:
				queue_free()
	if state == State.DEAD:
		modulate.a = clampf(_t / 0.8, 0.0, 1.0)


func _closest_inside() -> Player:
	var best: Player = null
	for p: Player in get_tree().get_nodes_in_group("player"):
		if p.health <= 0 or not drill.contains(p.global_position):
			continue
		if best == null or absf(p.global_position.x - global_position.x) < absf(best.global_position.x - global_position.x):
			best = p
	return best


func is_hit_by(p: Vector2) -> bool:
	return state != State.DEAD and p.distance_to(global_position) < 16.0


func hit(damage: int, _from: Vector2) -> void:
	if state == State.DEAD:
		return
	hp -= damage
	modulate = Color(2.5, 2.5, 2.5)
	create_tween().tween_property(self, "modulate", Color.WHITE, 0.15)
	Sfx.play("creature_hurt", global_position)
	if hp <= 0:
		state = State.DEAD
		_t = 0.8
		_anim_t = 0.0
		remove_from_group("hittable")
		Sfx.play("creature_die", global_position)
		killed.emit(global_position)


func _draw() -> void:
	if _look.ok:
		return
	draw_rect(Rect2(-12, -6, 24, 12), Color("7a4a2a"))
	draw_colored_polygon(PackedVector2Array([Vector2(facing * 12, -5), Vector2(facing * 20, 0), Vector2(facing * 12, 5)]), Color("b0b4ba"))


func net_state() -> Array:
	return [state, facing, _biting, modulate.a]


func net_apply(s: Array) -> void:
	if s[0] != state:
		_anim_t = 0.0
	state = s[0]
	facing = s[1]
	_biting = maxf(_biting, s[2])
	modulate.a = s[3]
