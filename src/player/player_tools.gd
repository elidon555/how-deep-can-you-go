extends Node2D
class_name PlayerTools
## A miner's tool belt besides the pickaxe. Q / right click (controller Y) uses the one in hand,
## Tab / mouse wheel (controller: right stick click) switches.
##   grapple       shoot a hook at the rock you aim at and get hauled up to it: the way back up
##                 a shaft (no limit, a short cooldown). At a ledge you climb onto it; otherwise
##                 you hang there: fire again to go higher, jump to let go, S to drop. Hooking the
##                 drill's hull climbs you back in at a door.
##   flare         throw a burning flare: light for a while, and creatures keep away from it
##   dynamite      throw a lit bundle: it blows a big crater a few seconds later (Thrown)
##   extinguisher  hold to spray: puts out cabin fires in front of you
## Flares and dynamite are restocked at the workbench, like ropes. Child of the Player; draws the
## grapple's chain and the spray.

signal throw_requested(kind: String, from: Vector2, velocity: Vector2)

const ALL := ["grapple", "flare", "dynamite", "extinguisher"]
const NAMES := {"flare": "Flare", "dynamite": "Dynamite", "grapple": "Grapple", "extinguisher": "Extinguisher"}
const STOCK := {"flare": 4, "dynamite": 2}
const THROW_SPEED := 300.0
const GRAPPLE_REACH := 220.0
const GRAPPLE_SPEED := 430.0
const GRAPPLE_COOLDOWN := 0.35
const SPRAY_REACH := 52.0
const SPRAY_POWER := 1.3        # fire intensity per second
const COOLDOWN := 0.4

var player: Player
var index := 0
var flares := STOCK.flare
var dynamite := STOCK.dynamite
var grapple_at := Vector2.INF   # where the hook bit (global) while it hauls you in
var _on_drill: Drill = null     # hooked onto the drill's hull: where on it (local), it moves
var _drill_hook := Vector2.ZERO
var _miss_t := 0.0              # a hook that found nothing flies out and drops back (drawn)
var _miss_to := Vector2.ZERO
var _stuck := 0                 # frames in a row the haul made no headway
var hanging := false            # arrived, no ledge to climb onto: hanging from the hook
var spraying := false
var _cool := 0.0
var _hiss_t := 0.0
var _spray := CPUParticles2D.new()


func _ready() -> void:
	z_index = 2
	_spray.amount = 40
	_spray.lifetime = 0.45
	_spray.spread = 12.0
	_spray.initial_velocity_min = 90.0
	_spray.initial_velocity_max = 140.0
	_spray.gravity = Vector2(0, 60)
	_spray.scale_amount_min = 1.5
	_spray.scale_amount_max = 3.5
	_spray.color = Color(0.92, 0.95, 1.0, 0.7)
	_spray.emitting = false
	_spray.position = Vector2(0, -6)
	add_child(_spray)


func current() -> String:
	return ALL[index]


## How many of a tool are left (-1 = no limit).
func count(t: String) -> int:
	if GameConfig.infinite_resources():
		return -1
	match t:
		"flare":
			return flares
		"dynamite":
			return dynamite
	return -1


func restock() -> void:
	flares = maxi(flares, STOCK.flare)
	dynamite = maxi(dynamite, STOCK.dynamite)


## Called by the Player every physics frame it's free to act.
func update(dt: float) -> void:
	_cool -= dt
	var input := player.input
	if input.just_pressed("tool_next"):
		index = (index + 1) % ALL.size()
		player.bag_changed.emit()             # (the HUD shows the tool in hand)
	spraying = current() == "extinguisher" and input.pressed("tool")
	if spraying:
		_spray_fires(dt)
	if not input.just_pressed("tool") or _cool > 0.0:
		return
	_cool = COOLDOWN
	var aim := player.aim_point()
	var dir := (aim - (player.global_position + Pickaxe.SHOULDER)).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2(player.facing, 0)
	match current():
		"flare", "dynamite":
			var t := current()
			if count(t) == 0:
				player.tell("No %s left. More at the drill's workbench." % NAMES[t].to_lower())
				return
			if t == "flare":
				flares -= 1 if count(t) > 0 else 0
			else:
				dynamite -= 1 if count(t) > 0 else 0
			player.start_throw()
			Sfx.play("throw", player.global_position, -6.0)
			throw_requested.emit(t, player.global_position + Vector2(0, -12), (dir + Vector2(0, -0.35)).normalized() * THROW_SPEED)
			player.bag_changed.emit()
		"grapple":
			_cool = GRAPPLE_COOLDOWN
			_fire_grapple(dir)


func _fire_grapple(dir: Vector2) -> void:
	Sfx.play("grapple_fire", player.global_position, -4.0)
	var from := player.global_position + Pickaxe.SHOULDER
	var drill := get_tree().get_first_node_in_group("drill") as Drill
	var outside := drill == null or not drill.contains(player.global_position)
	var d := 8.0
	while d < GRAPPLE_REACH:
		var p := from + dir * d
		if outside and drill and drill.blocks(p, false):      # the hull: climb back aboard
			_on_drill = drill
			_drill_hook = drill.to_local(p - dir * 2.0)
			grapple_at = p - dir * 2.0
			_stuck = 0
			hanging = false
			Sfx.play("grapple_hit", p, -2.0)
			return
		if player.world.is_diggable(p) or player.world.is_bedrock(p):
			grapple_at = p - dir * 2.0
			_on_drill = null
			_stuck = 0
			hanging = false
			Sfx.play("grapple_hit", p, -2.0)
			return
		d += 4.0
	_miss_t = 0.3
	_miss_to = from + dir * GRAPPLE_REACH


## The hook hauls the miner in; it lets go on arrival, on a jump, or when something's in the way.
func haul(dt: float) -> bool:
	if grapple_at == Vector2.INF:
		return false
	if _on_drill:
		grapple_at = _on_drill.to_global(_drill_hook)        # the hull moves
	var input := player.input
	_cool -= dt
	if input.just_pressed("tool") and _cool <= 0.0 and current() == "grapple":
		_cool = GRAPPLE_COOLDOWN                             # hook again from here
		var hold := grapple_at
		var hung := hanging
		_fire_grapple((player.aim_point() - (player.global_position + Pickaxe.SHOULDER)).normalized())
		if grapple_at == hold:
			hanging = hung                                   # (missed: still hanging where we were)
	if hanging:
		player.velocity = Vector2.ZERO
		if input.just_pressed("jump"):
			release(false)
			player.velocity.y = Player.JUMP_V * 0.7
			return false
		if input.pressed("down"):
			release(false)
			return false
		return true
	var to := grapple_at - player.global_position
	if input.just_pressed("jump"):
		release(false)
		return false
	if to.length() < 14.0:
		_arrive()
		return grapple_at != Vector2.INF       # (hanging: still on the hook)
	player.velocity = to.normalized() * GRAPPLE_SPEED
	var before := to.length()
	player.move_and_slide()                   # (slides up along a shaft wall it scrapes)
	_stuck = _stuck + 1 if before - (grapple_at - player.global_position).length() < GRAPPLE_SPEED * dt * 0.15 else 0
	if _stuck > 5:
		_arrive()                             # wedged against the rock: as far as it goes
	return true


## Got there: in at a door (the hull), up onto a ledge, or hang from the hook.
func _arrive() -> void:
	if _on_drill or _mantle(grapple_at):
		release(true)
	else:
		hanging = true
		player.velocity = Vector2.ZERO


## Lets go of the hook (arrived: in at the door if it was the hull).
func release(arrived: bool) -> void:
	grapple_at = Vector2.INF
	hanging = false
	player.velocity *= 0.25
	if not arrived:
		_on_drill = null
		return
	if _on_drill:                    # in at the nearest door
		var side := signf(_drill_hook.x) if _drill_hook.x != 0.0 else 1.0
		player.global_position = _on_drill.to_global(Vector2(side * (Drill.HW - Drill.WALL - 12.0),
			Drill.FLOOR - Player.HALF_HEIGHT - 1.0))
		player.velocity = Vector2.ZERO
		_on_drill = null


func _mantle(hook: Vector2) -> bool:
	var w := player.world
	var x := hook.x + signf(hook.x - player.global_position.x) * 6.0    # onto the rock side
	var top := hook.y
	while not w.is_air(Vector2(x, top)) and top > hook.y - 28.0:
		top -= 2.0
	if not w.is_air(Vector2(x, top)) or w.is_air(Vector2(x, top + 3.0)):
		return false
	for dy in [8.0, 20.0, 34.0]:                          # room to stand up there
		if not w.is_air(Vector2(x, top - dy)):
			return false
	player.global_position = Vector2(x, top - Player.HALF_HEIGHT - 1.0)
	player.velocity = Vector2.ZERO
	return true


func _spray_fires(dt: float) -> void:
	var aim := (player.aim_point() - player.global_position).normalized()
	if aim == Vector2.ZERO:
		aim = Vector2(player.facing, 0)
	_spray.direction = aim
	for d: Drill in get_tree().get_nodes_in_group("drill"):
		for f: DrillFires.Flame in d.fires.fires():
			var to := f.global_position + Vector2(0, -8) - player.global_position
			if to.length() < SPRAY_REACH and to.normalized().dot(aim) > 0.4:
				f.douse(SPRAY_POWER * dt)
	_hiss_t -= dt
	if _hiss_t <= 0.0:
		_hiss_t = 0.5
		Sfx.play("extinguish", player.global_position, -8.0, 0.05)


func _process(dt: float) -> void:
	_spray.emitting = spraying
	_miss_t -= dt
	queue_redraw()


func _draw() -> void:
	if _miss_t > 0.0:                # a miss: the chain flies out and falls back
		var k := _miss_t / 0.3
		draw_line(Pickaxe.SHOULDER, to_local(_miss_to).lerp(Pickaxe.SHOULDER, 1.0 - k), Color(0.55, 0.57, 0.6, k), 1.0)
	if grapple_at == Vector2.INF:
		return
	var to := to_local(grapple_at)
	var from := Pickaxe.SHOULDER
	var links := int(from.distance_to(to) / 4.0)
	for i in links:                                  # a chain of little links
		var p := from.lerp(to, (i + 0.5) / maxf(links, 1))
		draw_rect(Rect2(p - Vector2(1, 1), Vector2(2, 2)), Color("8a8f98") if i % 2 == 0 else Color("5a5f68"))
	draw_circle(to, 2.5, Color("c9ccd1"))


# ---------------------------------------------------------------- online (in Player.net_state)

func net_state() -> Array:
	return [index, grapple_at, spraying, flares, dynamite, hanging]


func net_apply(s: Array) -> void:
	index = s[0]
	grapple_at = s[1]
	spraying = s[2]
	flares = s[3]
	dynamite = s[4]
	hanging = s[5]
