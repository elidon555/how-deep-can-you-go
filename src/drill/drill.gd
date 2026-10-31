extends AnimatableBody2D
class_name Drill
## The crew's drilling machine. Bores straight down: the spinning head chews only the rock its
## cutters touch (cracks, then it crumbles) and the whole machine sinks as fast as the rock in
## front gives way; side reamers widen the shaft so there's a gap beside the hull. Braces grip
## the walls while it's still. The ladders fold away when everyone is aboard and telescope down
## when anyone is outside. Carries whoever is inside; burns fuel; falls if it breaks into a
## cave (and crashes if it falls far). It heats up with depth and while chewing hard rock or
## magma; overheated it stalls and its hull cooks until someone vents coolant.
## Damage (boulders, crawlers, crashes) opens hull breaches that leak until repaired.
## All of the machine's state lives here and stations only call these methods, so co-op can
## sync it from one place later.

signal changed                 # fuel / hull / speed / breaches changed (HUD)
signal wrecked
signal workbench_used(player: Player)
signal damaged(amount: float)
signal chewed(points: Array, mat: int)   # rock that just broke off at the cutters (for debris)
signal sonar_used(player: Player)
signal gunner_changed(player: Player)    # someone sat down at / got up from the turrets (or null)
signal bolt_hit(pos: Vector2, on_rock: bool)
signal vented                            # coolant flushed (steam)

enum Speed { STOP, SLOW, FULL }
const SPEED_NAMES := ["Stopped", "Slow", "Full"]
const DESCENT := [0.0, 0.35, 0.9]      # m/s it sinks at when the rock in front gives way
const FUEL_BURN := [0.0, 0.5, 1.2]     # fuel per second while the head turns
const HEAD_POWER := [0.0, 0.5, 1.0]
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
# the head's cutting face (left to right along its underside); cutters bite just beyond it
const FACE := [Vector2(-86, 54), Vector2(-34, 93), Vector2(0, 106), Vector2(34, 93), Vector2(86, 54)]
const CUTTER_R := 6.0
const CUTTER_REACH := 3.0      # how far in front of the face the cutters chew
const BITE := 1.0 / 7.0        # the cutters bite in pulses (s), not a smooth erosion
# side reamers at the hull's bottom corners widen the shaft beyond the hull (the crew's gap)
const REAMERS := [Vector2(-104, 60), Vector2(104, 60)]
const REAMER_R := 16.0
# heat: ambient heat rises with depth; cutting adds heat (per rock type); overheated it stalls
const HEAT_MAX := 100.0
const HEAT_RESUME := 65.0      # an overheated drill restarts once it's back under this
const HEAT_FROM_CUTTING := [0.6, 1.2, 2.2, 0.0, 2.0, 6.0]   # per second, by World.M rock
const COOLING := 1.6           # per second, toward the ambient heat
const OVERHEAT_DAMAGE := 1.5   # hull per second while overheated
const VENT := 45.0             # what one coolant flush takes off
const VENT_RECHARGE := 6.0
const BRACE_TIME := 0.35       # seconds for the braces to grip / let go
const LADDER_TIME := 0.9       # seconds for the ladders to fold away / come down
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
var grip := 1.0                # braces: 0 = pulled in, 1 = against the walls
var ladders_out := 1.0         # 0 = folded away, 1 = all the way down
var moving := false            # sinking this frame
var _ladders: Array[DrillLadder] = []
var _bite_power := 0.0         # cutting power saved up until the next bite
var _bite_clock := 0.0
var judder := Vector2.ZERO     # the hull shakes a pixel when a bite breaks rock (art reads it)
var chew_mat := -1             # what the cutters are biting (sparks only off stone)
var heat := 0.0
var overheated := false
var vent_ready_at := 0.0       # seconds (Time) when the coolant can flush again
var _alarm_t := 0.0
var gunner: Player = null      # who is on the turrets
var _seated_at := 0            # msec; the key that sat you down mustn't also stand you up
var turrets: Array[Turret] = []
var _fall_v := 0.0
var _bite_t := 0.0          # keeps "drilling" steady between frames that touch rock
var art := DrillArt.new()
var _engine := AudioStreamPlayer2D.new()
var _sounds := {}           # engine loop name -> stream


## Fuel never runs out (for now, or with [game] infinite_resources in project.godot).
static func infinite_fuel() -> bool:
	return INFINITE_FUEL or GameConfig.infinite_resources()


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
	_add_station(Stations.Furnace.new(), Vector2(-66, FLOOR))
	_add_station(Stations.Workbench.new(), Vector2(-36, FLOOR))
	_add_station(Stations.Medkit.new(), Vector2(-36, -16))
	_add_station(Stations.Sonar.new(), Vector2(-6, FLOOR))
	_add_station(Stations.GunnerSeat.new(), Vector2(18, FLOOR))
	_add_station(Stations.Coolant.new(), Vector2(42, FLOOR))
	_add_station(Stations.Helm.new(), Vector2(68, FLOOR))
	for side in [-1, 1]:          # harpoon turrets on the hull's sides, above the doors
		var t := Turret.new()
		t.side = side
		t.world = world
		t.position = Vector2(side * (HW + 6.0), -20.0)     # just above the door, below the upper brace
		t.bolt_hit.connect(bolt_hit.emit)
		add_child(t)
		turrets.append(t)
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
	# set down in a pit dug to the head's shape (the cutters only ever chew in front of it)
	var pit_a := global_position + Vector2(-80, 74)
	var pit_b := global_position + Vector2(80, 74)
	for i in 4:
		world.dig(pit_a, pit_b, 40.0, 10.0, false)
		_cut_reamers(10.0)
	_bite_clock = BITE


func apply_upgrades() -> void:
	max_fuel = Progress.drill_fuel()
	max_hull = Progress.drill_hull()
	fuel = minf(fuel, max_fuel)
	changed.emit()


func _physics_process(dt: float) -> void:
	if is_wrecked:
		return
	_update_heat(dt)
	var running := speed != Speed.STOP and fuel > 0.0 and not overheated
	_bite_t -= dt
	judder = Vector2.ZERO
	if running:
		if not infinite_fuel():
			fuel = maxf(fuel - FUEL_BURN[speed] * dt, 0.0)
		_bite_power += Progress.drill_power() * HEAD_POWER[speed] * dt
		_bite_clock -= dt
		if _bite_clock <= 0.0:         # a bite: all the saved-up cutting at once
			_bite_clock = BITE
			var bite := _cut_face(_bite_power)
			_cut_reamers(_bite_power * 0.8)
			_bite_power = 0.0
			if bite.hit:
				_bite_t = 0.3
				chew_mat = bite.mat
			if bite.points.size() > 0:
				judder = Vector2(randf_range(-1, 1), randf_range(0, 1)).round()
				chewed.emit(bite.points, bite.mat)
		if fuel == 0.0:
			Sfx.play("drill_stall", global_position)
			changed.emit()
	drilling = running and _bite_t > 0.0
	moving = false
	if not _fall(dt):
		_sink(dt, running)
	_update_braces_and_ladders(dt)
	_man_turrets()
	_engine_sound(running)
	var leaks := get_breaches().size()
	if leaks > 0:
		damage_quietly(BREACH_LEAK * leaks * dt)


## Ambient heat grows with depth (none until ~200 m, about 60 down in the magma); cutting adds
## heat by rock type; it cools toward ambient. Past HEAT_MAX it stalls and the hull cooks.
func _update_heat(dt: float) -> void:
	var depth := global_position.y / World.METER
	var ambient := clampf((depth - 200.0) / 350.0, 0.0, 1.0) * 60.0
	if drilling and chew_mat >= 0:
		heat += HEAT_FROM_CUTTING[chew_mat] * (2.0 if speed == Speed.FULL else 1.0) * dt
	heat = move_toward(heat, ambient, COOLING * dt)
	var under := world.liquid_at(global_position + Vector2(0, 100))     # what the head sits in
	if under.y == Liquids.LAVA and under.x > 0.2:
		heat += 14.0 * dt
	elif under.y == Liquids.WATER and under.x > 0.2:
		heat -= 8.0 * dt
	heat = clampf(heat, 0.0, HEAT_MAX)
	if heat >= HEAT_MAX and not overheated:
		overheated = true
		Sfx.play("drill_stall", global_position)
		changed.emit()
	elif overheated and heat < HEAT_RESUME:
		overheated = false
		changed.emit()
	if overheated:
		damage_quietly(OVERHEAT_DAMAGE * dt)
	_alarm_t -= dt
	if heat > 80.0 and _alarm_t <= 0.0:
		_alarm_t = 2.5
		Sfx.play("heat_alarm", global_position, -6.0, 0.0)


## The coolant station: a big flush of steam takes the heat down, then it recharges.
func vent_coolant() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now < vent_ready_at:
		return false
	vent_ready_at = now + VENT_RECHARGE
	heat = maxf(heat - VENT, 0.0)
	Sfx.play("steam_vent", global_position)
	vented.emit()
	changed.emit()
	return true


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


## Sinks as far as the rock in front of the head and under the reamers allows.
func _sink(dt: float, running: bool) -> void:
	if not running:
		return
	var push: float = DESCENT[speed] * World.METER * dt
	var step := minf(push, minf(_free_below_face(push + 1.0), _free_below_reamers(push + 1.0)))
	if step > 0.0:
		position.y += step
		moving = true


## Braces let go while it sinks and grip when it holds still. Ladders come down whenever a
## crew member is outside (so nobody gets locked out) and fold away once everyone is aboard.
func _update_braces_and_ladders(dt: float) -> void:
	grip = move_toward(grip, 0.0 if moving else 1.0, dt / BRACE_TIME)
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


## Free-falls (head, hull and all) when it breaks into a cave with nothing under it.
## Returns true while falling.
func _fall(dt: float) -> bool:
	var open := _free_below_face(14.0) >= 14.0 and _free_below_reamers(14.0) >= 14.0
	if open:
		_fall_v = minf(_fall_v + FALL_GRAVITY * dt, 500.0)
		var step := minf(_fall_v * dt, minf(_free_below_face(64.0), _free_below_reamers(64.0)))
		position.y += step
		return step > 0.0
	if _fall_v > CRASH_SPEED:     # crashed onto a cave floor (a drop of ~3.5 m or more)
		damage((_fall_v - CRASH_SPEED + 30.0) * 0.12, global_position + Vector2(randf_range(-40, 40), BOTTOM))
	_fall_v = 0.0
	return false


## Free space (px) in front of the head's cutting face, up to `limit`.
func _free_below_face(limit: float) -> float:
	return _free_below(_face_points(), limit)


## Free space (px) under the hull's whole bottom, up to `limit`: the corners are what the
## reamers cut, the middle is where the head has already been.
func _free_below_reamers(limit: float) -> float:
	var pts := []
	for x in [-118.0, -104.0, -90.0, -60.0, -20.0, 20.0, 60.0, 90.0, 104.0, 118.0]:
		pts.append(Vector2(x, BOTTOM + 2.0))
	return _free_below(pts, limit)


func _free_below(points: Array, limit: float) -> float:
	var d := 0.0
	while d < limit:
		for p: Vector2 in points:
			if not world.is_air(global_position + p + Vector2(0, d + 2.0)):
				return d
		d += 1.0
	return limit


## Points along the cutting face (local), every ~8 px.
func _face_points() -> Array:
	var pts := []
	for i in FACE.size() - 1:
		var a: Vector2 = FACE[i]
		var b: Vector2 = FACE[i + 1]
		var n := int(ceil(a.distance_to(b) / 8.0))
		for k in n:
			pts.append(a.lerp(b, float(k) / n))
	pts.append(FACE[-1])
	return pts


## The cutters chew only the rock just in front of the face (cracks first, then it crumbles).
## Returns {hit, mat, points: where rock broke off}.
func _cut_face(amount: float) -> Dictionary:
	var out_res := {"hit": false, "mat": -1, "points": []}
	for i in FACE.size() - 1:
		var a: Vector2 = FACE[i]
		var b: Vector2 = FACE[i + 1]
		var out := (b - a).orthogonal().normalized()    # points away from the head (down/out)
		if out.y < 0.0:
			out = -out
		var off := out * CUTTER_REACH
		var r := world.dig(global_position + a + off, global_position + b + off, CUTTER_R, amount, false)
		if r.hit:      # (ore it grinds through is lost)
			out_res.hit = true
			out_res.mat = r.mat
			out_res.points.append_array(r.points)
	return out_res


func _cut_reamers(amount: float) -> void:
	for r: Vector2 in REAMERS:
		var at := global_position + r
		world.dig(at, at + Vector2(0, 6), REAMER_R, amount, false)


# ---------------------------------------------------------------- crew actions (stations)

func take_turrets(p: Player) -> void:
	gunner = p
	_seated_at = Time.get_ticks_msec()
	p.frozen = true
	Sfx.play("lever", global_position, -6.0)
	gunner_changed.emit(p)


## Whoever sits at the gunner's seat aims (the turret on the side they point at) and fires.
func _man_turrets() -> void:
	if gunner == null:
		return
	var settled := Time.get_ticks_msec() - _seated_at > 250
	if (settled and gunner.wants_leave()) or gunner.health <= 0:
		gunner.frozen = false
		gunner = null
		gunner_changed.emit(null)
		return
	var aim := gunner.aim_point()
	var t: Turret = turrets[1] if aim.x >= global_position.x else turrets[0]
	t.aim_at(aim)
	if gunner.wants_fire():
		t.fire()


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
