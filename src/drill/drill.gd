extends AnimatableBody2D
class_name Drill
## The crew's drilling machine: hull, fuel, speed, damage and breaches, the stations inside,
## the braces. Its systems are components (children):
##   cutter (drill_cutter.gd)  how it bores down, falls into caves and crashes
##   thermal (drill_heat.gd)   heat, overheating, the coolant flush
##   flooding (drill_flood.gd) water through breaches, the bilge pump
##   guns (drill_guns.gd)      the hull turrets and the gunner's seat
##   power (drill_power.gd)    the generator, brownouts, the fuse boxes
##   fires (drill_fires.gd)    fire in the cabin
##   modules (drill_modules.gd) what's been built onto it (cargo hold, floodlights ...)
## Carries whoever is inside. Braces grip the walls while it's still. The crew gets back in by
## grappling the hull (PlayerTools hooks it and climbs in at a door). The side doors are hatches
## that open for the crew (anyone near the doorway, inside or out) and are shut otherwise, so
## creatures (and water) only get in while one is open. Damage (boulders,
## crawlers, worms, crashes) opens hull breaches that leak hull until repaired. All of the
## machine's state lives here and in its components, and stations only call their methods, so
## online co-op syncs it from one place (net_state / net_apply): on clients the drill is a
## puppet that shows the host's.

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
const BRACE_HOLD := 0.6        # it has to stay still this long before the braces grip again
const HATCH_TIME := 0.35       # seconds for a hatch to slide open / shut
const HATCH_REACH := 44.0      # crew this close to a doorway opens its hatch
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
var hatches := [0.0, 0.0]      # left, right: 0 = shut, 1 = open
var _hatch_shapes: Array[CollisionShape2D] = []
var _still_t := 0.0
var cutter := DrillCutter.new()
var thermal := DrillHeat.new()
var flooding := DrillFlood.new()
var guns := DrillGuns.new()
var power := DrillPower.new()
var fires := DrillFires.new()
var modules := DrillModules.new()
var cargo_count := 0           # ore the head ground through, kept in the cargo hold (module)
var cargo_value := 0
var art := DrillArt.new()
var puppet := false            # online client: shows the host's drill, doesn't run it
var running := false           # the head is turning (engine on, not stalled)
var _medkit: Stations.Medkit
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
	for side in [-1.0, 1.0]:                                           # the hatches
		_hatch_shapes.append(_add_box(Rect2(-HW if side < 0 else HW - WALL, DOOR_TOP, WALL, FLOOR - DOOR_TOP)))
	var head := CollisionShape2D.new()
	var poly := ConvexPolygonShape2D.new()
	poly.points = PackedVector2Array(HEAD)
	head.shape = poly
	add_child(head)
	for c in [cutter, thermal, flooding, guns, power, fires, modules]:
		c.drill = self
		add_child(c)
	art.drill = self
	add_child(art)
	_add_station(Stations.Furnace.new(), Vector2(-66, FLOOR))
	_add_station(Stations.Workbench.new(), Vector2(-36, FLOOR))
	_medkit = _add_station(Stations.Medkit.new(), Vector2(-36, -16)) as Stations.Medkit
	_add_station(Stations.Sonar.new(), Vector2(-6, FLOOR))
	_add_station(Stations.GunnerSeat.new(), Vector2(18, FLOOR))
	_add_station(Stations.Coolant.new(), Vector2(42, FLOOR))
	_add_station(Stations.Helm.new(), Vector2(68, FLOOR))
	for i in 2:
		var j := Junction.new()
		j.index = i
		_add_station(j, Vector2(Junction.X[i], Junction.Y))
	guns.mount()
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
	modules.build()
	fuel = minf(fuel, max_fuel)
	changed.emit()


func _physics_process(dt: float) -> void:
	if puppet:
		_engine_sound(running and not is_wrecked)
		flooding.update_sounds()
		power.update_sounds()
		return
	if is_wrecked:
		return
	thermal.update(dt)
	flooding.update(dt)
	running = speed != Speed.STOP and fuel > 0.0 and not thermal.overheated and not flooding.drowned() \
		and power.powered("helm")
	power.update(dt)
	fires.update(dt)
	if running and not infinite_fuel():
		fuel = maxf(fuel - FUEL_BURN[speed] * dt, 0.0)
		if fuel == 0.0:
			Sfx.play("drill_stall", global_position)
			changed.emit()
	cutter.update(dt, running)
	_update_braces(dt)
	_update_hatches(dt)
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


## Braces let go while it sinks and grip when it holds still.
func _update_braces(dt: float) -> void:
	# (it sinks in little steps, so "still" means still for a moment, or the braces flutter)
	_still_t = 0.0 if cutter.moving else _still_t + dt
	grip = move_toward(grip, 1.0 if _still_t > BRACE_HOLD else 0.0, dt / BRACE_TIME)


## A hatch slides open while any crew member is near its doorway (inside or out) and shuts
## when nobody is; shut, it blocks creatures, crew and water like the rest of the hull.
func _update_hatches(dt: float) -> void:
	for i in 2:
		var door := to_global(Vector2((-1.0 if i == 0 else 1.0) * (HW - WALL / 2.0), (DOOR_TOP + FLOOR) / 2.0))
		var want := 0.0
		for p: Player in get_tree().get_nodes_in_group("player"):
			if p.global_position.distance_to(door) < HATCH_REACH:
				want = 1.0
		if want != hatches[i] and (hatches[i] == 0.0 or hatches[i] == 1.0):
			Sfx.play("lever", door, -10.0)
		hatches[i] = move_toward(hatches[i], want, dt / HATCH_TIME)
		_hatch_shapes[i].disabled = hatches[i] > 0.3


func hatch_open(side: float) -> bool:
	return hatches[0 if side < 0.0 else 1] > 0.3


## For things that don't use physics (bats, orbs): is this point solid hull for something coming
## from inside the cabin (`from_inside`) or from outside? The cabin is only reachable from
## outside through an open hatch.
func blocks(p: Vector2, from_inside: bool) -> bool:
	var l := to_local(p)
	if absf(l.x) >= HW or l.y <= TOP or l.y >= BOTTOM + 50.0:
		return false
	if absf(l.x) >= HW - WALL and l.y > DOOR_TOP and l.y < FLOOR:      # a doorway
		return not hatch_open(signf(l.x))
	if absf(l.x) < HW - WALL and l.y > ROOF and l.y < FLOOR:          # the cabin
		return not from_inside
	return true                                                        # walls, roof, floor, head


# ---------------------------------------------------------------- crew actions (stations)

func cycle_speed() -> void:
	speed = ((speed + 1) % 3) as Speed
	Sfx.play("lever", global_position)
	if speed != Speed.STOP and fuel > 0.0:
		Sfx.play("drill_start", global_position)
	changed.emit()


## The cargo hold's ore, sold at the workbench: its value (the hold empties).
func take_cargo() -> int:
	var v := cargo_value
	cargo_count = 0
	cargo_value = 0
	changed.emit()
	return v


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
	power.knock(amount)
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


func _add_box(r: Rect2) -> CollisionShape2D:
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = r.size
	cs.shape = shape
	cs.position = r.get_center()
	add_child(cs)
	return cs


func _add_station(s: Station, at: Vector2) -> Station:
	s.drill = self
	s.position = at
	add_child(s)
	return s


# ---------------------------------------------------------------- online co-op

func net_state() -> Array:
	var breaches := PackedVector2Array()
	for b in get_breaches():
		breaches.append(b.position)
	var aims := []
	for t in guns.turrets:
		aims.append_array([t.target_aim(), t.recoil()])
	var gunner_id: int = guns.gunner.get_meta("net_id", 0) if guns.gunner else 0
	return [speed, fuel, max_fuel, hull, max_hull, is_wrecked, grip, hatches[0], hatches[1],
		running, cutter.drilling, cutter.moving, cutter.chew_mat, cutter.judder, thermal.heat,
		thermal.overheated, thermal.vent_wait(), flooding.level, flooding.leaking, gunner_id, aims,
		breaches, _medkit.wait(), power.net_state(), fires.net_state(), cargo_count, cargo_value]


func net_apply(s: Array) -> void:
	var before := [speed, fuel, hull, is_wrecked, thermal.overheated, flooding.level >= DrillFlood.STALL]
	speed = s[0] as Speed
	fuel = s[1]
	max_fuel = s[2]
	hull = s[3]
	max_hull = s[4]
	is_wrecked = s[5]
	grip = s[6]
	hatches = [s[7], s[8]]
	running = s[9]
	cutter.drilling = s[10]
	cutter.moving = s[11]
	cutter.chew_mat = s[12]
	cutter.judder = s[13]
	thermal.heat = s[14]
	thermal.overheated = s[15]
	thermal.show_vent_wait(s[16])
	flooding.level = s[17]
	flooding.leaking = s[18]
	var g: Node = Net.session.entities.node(s[19]) if s[19] != 0 and Net.session else null
	guns.gunner = g as Player
	var aims: Array = s[20]
	for i in mini(guns.turrets.size(), aims.size() / 2):
		guns.turrets[i].show_aim(aims[i * 2], aims[i * 2 + 1])
	_show_breaches(s[21])
	_medkit.show_wait(s[22])
	power.net_apply(s[23])
	fires.show_fires(s[24])
	cargo_count = s[25]
	cargo_value = s[26]
	if before != [speed, fuel, hull, is_wrecked, thermal.overheated, flooding.level >= DrillFlood.STALL]:
		changed.emit()


## Client: the host's breaches (a crack appears or gets patched here too).
func _show_breaches(at: PackedVector2Array) -> void:
	var have := get_breaches()
	for b in have:
		if not at.has(b.position):
			b.queue_free()
	for p in at:
		if not have.any(func(b): return b.position == p):
			var b := Stations.Breach.new()
			b.drill = self
			b.position = p
			add_child(b)
