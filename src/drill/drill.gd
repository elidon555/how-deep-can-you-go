extends AnimatableBody2D
class_name Drill
## The crew's drilling machine: hull, fuel, speed, damage and breaches, the stations inside,
## the braces and the ladders. Its systems are components (children):
##   cutter (drill_cutter.gd)  how it bores down, falls into caves and crashes
##   thermal (drill_heat.gd)   heat, overheating, the coolant flush
##   flooding (drill_flood.gd) water through breaches, the bilge pump
##   guns (drill_guns.gd)      the hull turrets and the gunner's seat
## Carries whoever is inside. Braces grip the walls while it's still; the ladders fold away
## when everyone is aboard and telescope down when anyone is outside. Damage (boulders,
## crawlers, worms, crashes) opens hull breaches that leak hull until repaired. All of the
## machine's state lives here and in its components, and stations only call their methods, so
## co-op can sync it from one place later.

signal changed                 # fuel / hull / speed / breaches changed (HUD)
signal wrecked
signal workbench_used(player: Player)
signal damaged(amount: float)
signal sonar_used(player: Player)
signal vented                            # coolant flushed (steam)

enum Speed { STOP, SLOW, FULL }
const SPEED_NAMES := ["Stopped", "Slow", "Full"]
const FUEL_BURN := [0.0, 0.5, 1.2]     # fuel per second while the head turns
const FUEL_PER_COAL := 12.0
const INFINITE_FUEL := true    # for now the drill never runs dry (furnace / coal stay for later)


# shape, in local px (y down). Inside: floor at FLOOR, roof underside at ROOF.
const HW := 96.0               # half the hull's width
const TOP := -56.0             # roof top
const ROOF := -48.0            # roof underside
const FLOOR := 40.0            # floor the crew stands on
const BOTTOM := 56.0           # underside of the hull, the head hangs below
const DOOR_TOP := -6.0         # side doors are open from here down to the floor
const WALL := 8.0
const HEAD := [Vector2(-84, 56), Vector2(84, 56), Vector2(34, 92), Vector2(0, 104), Vector2(-34, 92)]
const BRACE_TIME := 0.35       # seconds for the braces to grip / let go
const LADDER_TIME := 0.9       # seconds for the ladders to fold away / come down
const MAX_BREACHES := 4
const BREACH_LEAK := 0.35      # hull per second per open breach

var world: World
var speed := Speed.STOP
var fuel := 60.0
var max_fuel := 100.0
var hull := 100.0
var max_hull := 100.0
var is_wrecked := false
var grip := 1.0                # braces: 0 = pulled in, 1 = against the walls
var ladders_out := 1.0         # 0 = folded away, 1 = all the way down
var _ladders: Array[DrillLadder] = []
var cutter := DrillCutter.new()
var thermal := DrillHeat.new()
var flooding := DrillFlood.new()
var guns := DrillGuns.new()
var art := DrillArt.new()
var _engine := AudioStreamPlayer2D.new()
var _sounds := {}           # engine loop name -> stream


## Fuel never runs out (for now, or with [game] infinite_resources in project.godot).
static func infinite_fuel() -> bool:
	return INFINITE_FUEL or GameConfig.infinite_resources()


func _ready() -> void:
	add_to_group("drill")
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
	for c in [cutter, thermal, flooding, guns]:
		c.drill = self
		add_child(c)
	art.drill = self
	add_child(art)
	_add_station(Stations.Furnace.new(), Vector2(-66, FLOOR))
	_add_station(Stations.Workbench.new(), Vector2(-36, FLOOR))
	_add_station(Stations.Medkit.new(), Vector2(-36, -16))
	_add_station(Stations.Sonar.new(), Vector2(-6, FLOOR))
	_add_station(Stations.GunnerSeat.new(), Vector2(18, FLOOR))
	_add_station(Stations.Coolant.new(), Vector2(42, FLOOR))
	_add_station(Stations.Helm.new(), Vector2(68, FLOOR))
	guns.mount()
	for side in [-1, 1]:          # ladders outside, next to each door
		var l := DrillLadder.new()
		l.position = Vector2(side * (HW + 9.0), 0)
		l.top = DOOR_TOP
		add_child(l)
		_ladders.append(l)
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
	cutter.dig_start_pit()     # set down in a pit shaped to its head


func apply_upgrades() -> void:
	max_fuel = Progress.drill_fuel()
	max_hull = Progress.drill_hull()
	fuel = minf(fuel, max_fuel)
	changed.emit()


func _physics_process(dt: float) -> void:
	if is_wrecked:
		return
	thermal.update(dt)
	flooding.update(dt)
	var running := speed != Speed.STOP and fuel > 0.0 and not thermal.overheated and not flooding.drowned()
	if running and not infinite_fuel():
		fuel = maxf(fuel - FUEL_BURN[speed] * dt, 0.0)
		if fuel == 0.0:
			Sfx.play("drill_stall", global_position)
			changed.emit()
	cutter.update(dt, running)
	_update_braces_and_ladders(dt)
	guns.update()
	_engine_sound(running)
	var leaks := get_breaches().size()
	if leaks > 0:
		damage_quietly(BREACH_LEAK * leaks * dt)


## Grinding while it bites rock, idling while it runs without, silent when stopped.
func _engine_sound(running: bool) -> void:
	var want: AudioStream = null
	if running:
		want = _sounds.get("drill_loop" if cutter.drilling else "drill_idle")
	if want != _engine.stream:
		_engine.stream = want
		if want:
			_engine.play()
	elif want == null and _engine.playing:
		_engine.stop()


## Braces let go while it sinks and grip when it holds still. Ladders come down whenever a
## crew member is outside (so nobody gets locked out) and fold away once everyone is aboard.
func _update_braces_and_ladders(dt: float) -> void:
	grip = move_toward(grip, 0.0 if cutter.moving else 1.0, dt / BRACE_TIME)
	var want := 1.0 if _anyone_outside() else 0.0
	if want != ladders_out and (ladders_out == 0.0 or ladders_out == 1.0):
		Sfx.play("lever", global_position, -8.0)          # the fold / unfold starts
	ladders_out = move_toward(ladders_out, want, dt / LADDER_TIME)
	for l in _ladders:
		l.extend = ladders_out


func _anyone_outside() -> bool:
	for p: Player in get_tree().get_nodes_in_group("player"):
		if not contains(p.global_position) or p.rope in _ladders:
			return true
	return false


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
