extends Node2D
class_name Pickaxe
## The miner's pickaxe: turns held keys into swings, and breaks rock only when a swing lands.
## A swing needs room: if rock is in the way of the wind-up, the pick knocks into it instead
## (chips it a little, no real dig), so cramped spots slowly open up rather than trap you.
## Lives as a child of the Player; draws the swoosh trail itself.

signal struck(pos: Vector2, mat: int, broke: int, kind: String)   # hit rock; kind "bonk" = no room

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
# points (facing right, from the miner's centre) the pick passes through on the wind-up, over
# and behind the head (top of head is -18); they must be open air. Our own tunnels are carved
# tall enough to keep these clear.
const ROOM := {"dig_side": [Vector2(-2, -22), Vector2(-9, -19)],
	"dig_down": [Vector2(-3, -24), Vector2(-7, -20)], "dig_diag": [Vector2(-3, -24), Vector2(-7, -20)],
	"dig_up": [Vector2(-12, 8), Vector2(-8, 14)]}

var player: Player
var world: World
var power := 3.0          # rock removed per second at the centre of a dig (dirt), on average
var kind := ""            # current swing: dig_side / dig_down / dig_diag / dig_up, "" = none
var frame := 0            # current frame of the swing animation
var _t := 0.0
var _trail_t := 9.0
var _cooldown := 0.0


func _ready() -> void:
	var unlit := CanvasItemMaterial.new()
	unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	material = unlit
	z_index = 1


## Animation row to show for the current swing ("" when not digging).
func anim() -> String:
	return "dig_down" if kind == "dig_diag" else kind


## Called by the player every physics frame with the horizontal input.
func update(dt: float, dir: float) -> void:
	_trail_t += dt
	_cooldown -= dt
	queue_redraw()
	var want := _intent(dir)
	if kind == "":
		if want == "" or _cooldown > 0.0:
			return
		kind = want
		frame = 1          # skip the lift on the first swing, feels snappier
		_t = 0.0
	elif want == "" and (frame < IMPACT or not player.is_on_floor()):
		kind = ""          # let go before the hit (after it, the recoil plays out)
		return
	_t += dt
	while _t >= FRAMES[frame]:
		_t -= FRAMES[frame]
		frame += 1
		if frame == PEAK and not _has_room():
			return
		if frame == IMPACT - 1:
			_trail_t = 0.0
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


## What holding the current keys should dig, or "" for nothing.
func _intent(dir: float) -> String:
	var down := Input.is_action_pressed("down")
	if down and dir != 0:
		return "dig_diag"
	if down:
		return "dig_down"
	if Input.is_action_pressed("up"):
		return "dig_up"
	if dir == 0:
		return ""
	# rock in front of the head/chest (or within a step of it): keep chopping while you walk in.
	# Also when holding a direction without getting anywhere, e.g. pinched by a tunnel's round end.
	var c := player.global_position
	var rock_ahead := false
	for x in [10, 20, 28]:
		for y in [-14, 2]:
			if world.is_diggable(c + Vector2(dir * x, y)):
				rock_ahead = true
			elif world.is_bedrock(c + Vector2(dir * x, y)):
				return ""   # the edge of the world: nothing to dig
	if rock_ahead or player.is_on_wall() or absf(player.get_real_velocity().x) < 20.0:
		return "dig_side"
	return ""


## The pick lands: break rock. Each swing removes on average what continuous digging used to.
func _strike(dir: int) -> void:
	var c := player.global_position
	var amount := power * SWING_TIME
	var res: Dictionary
	var at := c
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


## Tunnel sideways, a bit taller than you: a hole ahead that reaches head and feet height at
## your front edge, plus a clearance pass around your body so half-dug cells can't pinch you.
func _dig_side(c: Vector2, dir: float, amount: float) -> Dictionary:
	# tall enough to leave room for the next wind-up (see ROOM)
	var ahead := world.dig(c + Vector2(dir * 13, -20), c + Vector2(dir * 13, 12), 11.0, amount)
	return _merge(ahead, world.dig(c + Vector2(0, -19), c + Vector2(0, 10), 10.0, amount))


static func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	return {"hit": a.hit or b.hit, "mat": a.mat if a.hit else b.mat, "broke": a.broke + b.broke}


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
