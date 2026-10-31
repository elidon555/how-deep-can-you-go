extends AnimatableBody2D
class_name Drill
## The crew's drilling machine. Bores straight down and carries whoever is inside; burns fuel
## while the head turns; falls if it breaks into a cave (and crashes if it falls far).
## Damage (boulders, crawlers, crashes) opens hull breaches that leak until repaired.
## All of the machine's state lives here and stations only call these methods, so co-op can
## sync it from one place later.

signal changed                 # fuel / hull / speed / breaches changed (HUD)
signal wrecked
signal workbench_used(player: Player)
signal damaged(amount: float)

enum Speed { STOP, SLOW, FULL }
const SPEED_NAMES := ["Stopped", "Slow", "Full"]
const DESCENT := [0.0, 0.35, 0.9]      # m/s it descends at when the rock gives way
const FUEL_BURN := [0.0, 0.5, 1.2]     # fuel per second while the head turns
const HEAD_POWER := [0.0, 0.5, 1.0]
const FUEL_PER_COAL := 12.0

# shape, in local px (y down). Inside: floor at FLOOR, roof underside at ROOF.
const HW := 96.0               # half the hull's width
const TOP := -56.0             # roof top
const ROOF := -48.0            # roof underside
const FLOOR := 40.0            # floor the crew stands on
const BOTTOM := 56.0           # underside of the hull, the head hangs below
const DOOR_TOP := -6.0         # side doors are open from here down to the floor
const WALL := 8.0
const HEAD := [Vector2(-84, 56), Vector2(84, 56), Vector2(34, 92), Vector2(0, 104), Vector2(-34, 92)]
# what the head cuts: a capsule a bit wider than the hull, leaving a gap at the sides
const CUT_HALF := 76.0
const CUT_Y := 70.0
const CUT_R := 44.0
const MAX_BREACHES := 4
const BREACH_LEAK := 0.35      # hull per second per open breach
const FALL_GRAVITY := 700.0
const CRASH_SPEED := 340.0     # landing faster than this damages the hull

var world: World
var speed := Speed.STOP
var fuel := 60.0
var max_fuel := 100.0
var hull := 100.0
var max_hull := 100.0
var drilling := false          # the head is turning and biting rock
var is_wrecked := false
var _fall_v := 0.0
var _bite_t := 0.0          # keeps "drilling" steady between frames that touch rock
var art := DrillArt.new()
var _engine := AudioStreamPlayer2D.new()
var _sounds := {}           # engine loop name -> stream


func _ready() -> void:
	# it's only ever moved from _physics_process, so it doesn't need syncing (which is on by
	# default and would hold position changes made before the first physics frame)
	sync_to_physics = false
	collision_layer = 1
	collision_mask = 0
	_add_box(Rect2(-HW, FLOOR, HW * 2.0, BOTTOM - FLOOR))              # floor
	_add_box(Rect2(-HW, TOP, HW * 2.0, ROOF - TOP))                    # roof
	_add_box(Rect2(-HW, TOP, WALL, DOOR_TOP - TOP))                    # left wall above the door
	_add_box(Rect2(HW - WALL, TOP, WALL, DOOR_TOP - TOP))              # right wall
	var head := CollisionShape2D.new()
	var poly := ConvexPolygonShape2D.new()
	poly.points = PackedVector2Array(HEAD)
	head.shape = poly
	add_child(head)
	art.drill = self
	add_child(art)
	_add_station(Stations.Helm.new(), Vector2(58, FLOOR))
	_add_station(Stations.Furnace.new(), Vector2(-62, FLOOR))
	_add_station(Stations.Workbench.new(), Vector2(-16, FLOOR))
	_add_station(Stations.Medkit.new(), Vector2(22, FLOOR - 28))
	for side in [-1, 1]:          # ladders outside, next to each door
		var l := Rope.new()
		l.ladder = true
		l.position = Vector2(side * (HW + 9.0), 0)
		l.top = DOOR_TOP
		l.bottom = BOTTOM + 30.0
		add_child(l)
	for n in ["drill_loop", "drill_idle"]:
		_sounds[n] = Sfx.looping(n)
	_engine.max_distance = 1200.0
	add_child(_engine)
	apply_upgrades()
	fuel = max_fuel * 0.6
	hull = max_hull


## Sits the drill on the ground at x, its head already cut into the dirt.
func place(at_x: float) -> void:
	var y := -60.0
	while world.is_air(Vector2(at_x, y)) and y < 200.0:
		y += 2.0
	position = Vector2(at_x, y - BOTTOM + 4.0)
	for i in 6:
		_cut(10.0)


func apply_upgrades() -> void:
	max_fuel = Progress.drill_fuel()
	max_hull = Progress.drill_hull()
	fuel = minf(fuel, max_fuel)
	changed.emit()


func _physics_process(dt: float) -> void:
	if is_wrecked:
		return
	var running := speed != Speed.STOP and fuel > 0.0
	_bite_t -= dt
	if running:
		fuel = maxf(fuel - FUEL_BURN[speed] * dt, 0.0)
		if _cut(Progress.drill_power() * HEAD_POWER[speed] * dt):
			_bite_t = 0.3
		if fuel == 0.0:
			Sfx.play("drill_stall", global_position)
			changed.emit()
	drilling = running and _bite_t > 0.0
	_descend(dt, running)
	_engine_sound(running)
	var leaks := get_breaches().size()
	if leaks > 0:
		damage_quietly(BREACH_LEAK * leaks * dt)


## Grinding while it bites rock, idling while it runs without, silent when stopped.
func _engine_sound(running: bool) -> void:
	var want: AudioStream = null
	if running:
		want = _sounds.get("drill_loop" if drilling else "drill_idle")
	if want != _engine.stream:
		_engine.stream = want
		if want:
			_engine.play()
	elif want == null and _engine.playing:
		_engine.stop()


## Moves down as far as the rock under the head allows; free-falls through open caves.
func _descend(dt: float, running: bool) -> void:
	var free := _free_below(64.0)
	var want: float = DESCENT[speed] * World.METER * dt if running else 0.0
	if free > 12.0:
		_fall_v = minf(_fall_v + FALL_GRAVITY * dt, 500.0)
	elif free <= 0.0:
		if _fall_v > CRASH_SPEED:     # crashed onto a cave floor (a drop of ~3.5 m or more)
			damage((_fall_v - CRASH_SPEED + 30.0) * 0.12, global_position + Vector2(randf_range(-40, 40), BOTTOM))
		_fall_v = 0.0
	var step := minf(free, maxf(want, _fall_v * dt))
	if step > 0.0:
		position.y += step


## Free space (px) under the head before it would touch rock, up to `limit`.
func _free_below(limit: float) -> float:
	var d := 0.0
	while d < limit:
		for p: Vector2 in [Vector2(-70, 86), Vector2(-34, 96), Vector2(0, 106), Vector2(34, 96), Vector2(70, 86)]:
			if not world.is_air(global_position + p + Vector2(0, d + 2.0)):
				return d
		d += 2.0
	return limit


func _cut(amount: float) -> bool:
	var a := global_position + Vector2(-CUT_HALF, CUT_Y)
	var b := global_position + Vector2(CUT_HALF, CUT_Y)
	return world.dig(a, b, CUT_R, amount, false).hit    # ore it grinds through is lost


# ---------------------------------------------------------------- crew actions (stations)

func cycle_speed() -> void:
	speed = ((speed + 1) % 3) as Speed
	Sfx.play("lever", global_position)
	if speed != Speed.STOP and fuel > 0.0:
		Sfx.play("drill_start", global_position)
	changed.emit()


func add_fuel(amount: float) -> void:
	fuel = minf(fuel + amount, max_fuel)
	changed.emit()


func repair(b: Stations.Breach) -> void:
	b.queue_free()
	Sfx.play("repair", b.global_position)
	changed.emit.call_deferred()


# ---------------------------------------------------------------- damage

## A hit on the hull at a global point: loses hull and tears a breach near there.
func damage(amount: float, at: Vector2) -> void:
	if is_wrecked:
		return
	damage_quietly(amount)
	damaged.emit(amount)
	Sfx.play("hull_hit", at)
	if get_breaches().size() < MAX_BREACHES and amount >= 3.0:
		var b := Stations.Breach.new()
		b.drill = self
		b.position = _hull_point_near(to_local(at))
		add_child(b)
		Sfx.play("breach", at)
		Sfx.play("alarm", global_position, -4.0, 0.0)
	changed.emit()


func damage_quietly(amount: float) -> void:
	hull = maxf(hull - amount, 0.0)
	if hull == 0.0 and not is_wrecked:
		is_wrecked = true
		speed = Speed.STOP
		_engine.stop()
		wrecked.emit()


func get_breaches() -> Array:
	var out := []
	for c in get_children():
		if c is Stations.Breach and not c.is_queued_for_deletion():
			out.append(c)
	return out


## Inside the hull's crew space (global point)?
func contains(p: Vector2) -> bool:
	var l := to_local(p)
	return absf(l.x) < HW and l.y > TOP and l.y < FLOOR + 2.0


## Where a hit shows up inside: a crack in the back wall behind the hit, at a height the
## crew can reach from the floor (cutaway view, like Barotrauma).
func _hull_point_near(l: Vector2) -> Vector2:
	return Vector2(clampf(l.x, -HW + 18.0, HW - 18.0), randf_range(-2.0, 22.0))


func _add_box(r: Rect2) -> void:
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = r.size
	cs.shape = shape
	cs.position = r.get_center()
	add_child(cs)


func _add_station(s: Station, at: Vector2) -> void:
	s.drill = self
	s.position = at
	add_child(s)
