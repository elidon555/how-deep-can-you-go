extends Node2D
class_name Pickaxe
## The miner's pickaxe: click (one swing) or hold (keep swinging) the dig button.
## With the mouse, the cursor only sets the direction: the swing goes that way and hits the
## first rock in front of you within arm's reach. With J / a
## controller, the direction keys aim it
## (down, up, down+side = diagonal, otherwise the way you face). Rock only breaks when a
## swing lands.
## A swing needs room: if rock is in the way of the wind-up, the pick knocks into it instead
## (chips it a little, no real dig), so cramped spots slowly open up rather than trap you.
## Lives as a child of the Player; draws the swoosh trail itself.

signal struck(pos: Vector2, mat: int, broke: int, kind: String)   # hit rock; kind "bonk" = no room
signal hit_thing(pos: Vector2)    # a swing landed on a creature or boulder (group "hittable")

# seconds per frame of a swing (lift, wind-up, peak, hold, strike, IMPACT, recoil, settle);
# matches the 8-frame dig rows in assets/sprites/miner.png
const FRAMES := [0.05, 0.05, 0.07, 0.05, 0.03, 0.08, 0.05, 0.04]
const SWING_TIME := 0.42
const IMPACT := 5
const PEAK := 2           # wind-up peak: where the swing needs its room
const BONK_COOLDOWN := 0.2
const BONK_CHIP := 0.6    # a knock does this fraction of a real hit
const DOWN_BONUS := 1.4   # straight down stays the fastest way deeper (diagonal digs two holes)
# swoosh arc per swing kind, facing right (radians, y down): start, end
const TRAIL := {"dig_side": [-1.75, 0.26], "dig_down": [-1.75, 1.4], "dig_diag": [-1.75, 1.1],
	"dig_up": [2.27, -1.66]}
const TRAIL_TIME := 0.13
const REACH := 32.0       # how far from the shoulder a mouse-aimed swing reaches
const AIM_R := 11.0       # size of the bite where a mouse-aimed swing lands
const SHOULDER := Vector2(0, -6)
# points (facing right, from the miner's centre) the pick passes through on the wind-up, over
# and behind the head (top of head is -18); they must be open air. Our own tunnels are carved
# tall enough to keep these clear.
const ROOM := {"dig_side": [Vector2(-2, -22), Vector2(-9, -19)],
	"dig_down": [Vector2(-3, -24), Vector2(-7, -20)], "dig_diag": [Vector2(-3, -24), Vector2(-7, -20)],
	"dig_up": [Vector2(-12, 8), Vector2(-8, 14)]}

var player: Player
var world: World
var power := 3.0          # rock removed per second at the centre of a dig (dirt), on average
var speed := 1.0          # swing speed multiplier
var kind := ""            # current swing: dig_side / dig_down / dig_diag / dig_up, "" = none
var frame := 0            # current frame of the swing animation
var _t := 0.0
var _trail_t := 9.0
var _cooldown := 0.0
var mouse_aim := true     # last aimed with the mouse (vs J / controller + direction keys)
var _target := Vector2.ZERO   # where a mouse-aimed swing lands: first rock that way (global)
var aim_at := Vector2.INF     # set to aim somewhere other than the local mouse (tests, co-op)


func _ready() -> void:
	var unlit := CanvasItemMaterial.new()
	unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material = unlit
	z_index = 1


## Animation row to show for the current swing ("" when not digging).
func anim() -> String:
	return "dig_down" if kind == "dig_diag" else kind


func _input(event: InputEvent) -> void:
	if not player.input.is_local():
		return                # someone else's (online): their machine says how they aim
	if not player.input.uses_mouse:
		mouse_aim = false
	elif event is InputEventMouseMotion or event is InputEventMouseButton:
		mouse_aim = true
	elif player.input.is_event(event, "dig"):   # J or a controller button
		mouse_aim = false


## Called by the player every physics frame with the horizontal input.
func update(dt: float, dir: float) -> void:
	_trail_t += dt
	_cooldown -= dt
	queue_redraw()
	if mouse_aim:
		_target = _aim_point()
	var want := _intent(dir)
	if kind == "":
		if want == "" or _cooldown > 0.0:
			return
		kind = want
		frame = 1          # skip the lift on the first swing, feels snappier
		_t = 0.0
	if mouse_aim and absf(_target.x - player.global_position.x) > 2.0:
		player.facing = 1 if _target.x > player.global_position.x else -1   # face where you swing
	power = Progress.pick_power() * Roles.pick_mult(player.role)
	speed = Progress.swing_speed()
	_t += dt * speed      # a started swing always plays out; holding the button chains them
	while _t >= FRAMES[frame]:
		_t -= FRAMES[frame]
		frame += 1
		if frame == PEAK and not _has_room():
			return
		if frame == IMPACT - 1:
			_trail_t = 0.0
			Sfx.play("swing", player.global_position, -10.0, 0.1)
		elif frame == IMPACT:
			_strike(player.facing)
		elif frame >= FRAMES.size():
			frame = 0
			kind = want
			if want == "":
				return


## Checks the wind-up path. If rock is in the way, the pick knocks into it: a small chip,
## sparks, and the swing is over.
func _has_room() -> bool:
	for p: Vector2 in ROOM[kind]:
		var at := player.global_position + Vector2(p.x * player.facing, p.y)
		if world.is_air(at):
			continue
		var res := world.dig(at, at, 8.0, power * SWING_TIME * BONK_CHIP)
		struck.emit(at, world.mat_at(at), res.broke, "bonk")
		kind = ""
		_cooldown = BONK_COOLDOWN
		return false
	return true


## What the held keys aim at while the dig button is down, or "" for nothing.
## A click counts too, even if released within the same frame.
func _intent(dir: float) -> String:
	if not (player.input.pressed("dig") or player.input.just_pressed("dig")):
		return ""
	if mouse_aim:
		return _kind_towards(_target - (player.global_position + SHOULDER))
	var down := player.input.pressed("down")
	if down and dir != 0:
		return "dig_diag"
	if down:
		return "dig_down"
	if player.input.pressed("up"):
		return "dig_up"
	return "dig_side"


## The first rock in the direction of the cursor, within arm's reach (or the end of the reach
## if there's only air). The bite goes a little into the rock so it takes a real chunk.
func _aim_point() -> Vector2:
	var shoulder := player.global_position + SHOULDER
	var to := aim_at if aim_at != Vector2.INF else get_global_mouse_position()
	var dir := (to - shoulder).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2(player.facing, 0)
	var d := 8.0
	while d < REACH:
		if world.is_diggable(shoulder + dir * d):
			return shoulder + dir * minf(d + 4.0, REACH)
		d += 2.0
	return shoulder + dir * REACH


## Which swing (and animation) fits a direction from the shoulder.
static func _kind_towards(v: Vector2) -> String:
	var ang := rad_to_deg(atan2(v.y, absf(v.x)))     # -90 straight up .. 90 straight down
	if ang > 62.0:
		return "dig_down"
	if ang < -55.0:
		return "dig_up"
	if ang > 22.0:
		return "dig_diag"
	return "dig_side"


## The pick lands: break rock. Each swing removes on average what continuous digging used to.
func _strike(dir: int) -> void:
	var c := player.global_position
	var amount := power * SWING_TIME
	var res: Dictionary
	var at := c
	if mouse_aim:     # the first rock the way you point (+ keep room around your body when tunnelling)
		at = _target
		res = world.dig(at, at, AIM_R, amount * (DOWN_BONUS if kind == "dig_down" else 1.0))
		if kind == "dig_side" or kind == "dig_diag":
			res = _merge(res, world.dig(c + Vector2(0, -19), c + Vector2(0, 10), 10.0, amount))
		if res.hit:
			struck.emit(at, res.mat, res.broke, kind)
		_hit_things(at)
		return
	match kind:
		"dig_down":
			at = c + Vector2(0, 21)
			res = world.dig(at, at, 13.0, amount * DOWN_BONUS)
		"dig_up":
			at = c + Vector2(0, -21)
			res = world.dig(at, at, 13.0, amount)
		"dig_side":
			at = c + Vector2(dir * 18, -2)
			res = _dig_side(c, dir, amount)
		"dig_diag":   # body-sized hole ahead + the floor ahead
			at = c + Vector2(dir * 12, 14)
			var floor_at := c + Vector2(dir * 10, 20)
			res = _merge(_dig_side(c, dir, amount), world.dig(floor_at, floor_at, 12.0, amount))
	if res.hit:
		struck.emit(at, res.mat, res.broke, kind)
	_hit_things(at)


## Creatures and boulders where the pick lands take a hit too.
func _hit_things(at: Vector2) -> void:
	var damage := 1 + Progress.level("pick") / 2
	for n in get_tree().get_nodes_in_group("hittable"):
		var hits: bool = n.is_hit_by(at) if n.has_method("is_hit_by") else (n as Node2D).global_position.distance_to(at) < 22.0
		if hits:
			n.hit(damage, player.global_position)
			hit_thing.emit(at)


## Tunnel sideways, a bit taller than you: a hole ahead that reaches head and feet height at
## your front edge, plus a clearance pass around your body so half-dug cells can't pinch you.
func _dig_side(c: Vector2, dir: float, amount: float) -> Dictionary:
	# tall enough to leave room for the next wind-up (see ROOM)
	var ahead := world.dig(c + Vector2(dir * 13, -20), c + Vector2(dir * 13, 12), 11.0, amount)
	return _merge(ahead, world.dig(c + Vector2(0, -19), c + Vector2(0, 10), 10.0, amount))


static func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"hit": a.hit or b.hit, "mat": a.mat if a.hit else b.mat, "broke": a.broke + b.broke,
		"points": a.points + b.points}


## Online: how far along the swoosh is (host), and showing the host's swing (client puppet).
func trail_age() -> float:
	return _trail_t


func show_swing(swing: String, trail_age: float) -> void:
	kind = swing
	if trail_age < _trail_t:
		_trail_t = trail_age


func show_trail(dt: float) -> void:
	_trail_t += dt
	queue_redraw()


## Swoosh behind the pick head for the strike + impact frames.
func _draw() -> void:
	var alpha := 1.0 - _trail_t / TRAIL_TIME
	if alpha <= 0.0 or not TRAIL.has(kind):
		return
	var arc: Array = TRAIL[kind]
	var a0: float = arc[0]
	var a1: float = arc[1]
	if player.facing < 0:
		a0 = PI - a0
		a1 = PI - a1
	var c := Vector2(2 * player.facing, -9)
	draw_arc(c, 24.0, a0, a1, 16, Color(1, 0.95, 0.85, 0.25 * alpha), 6.0)
	draw_arc(c, 24.0, lerpf(a0, a1, 0.35), a1, 12, Color(1, 1, 1, 0.75 * alpha), 2.0)
