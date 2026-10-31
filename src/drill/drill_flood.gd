extends Node
class_name DrillFlood
## Flooding: each breach (and each open hatch) with water outside the hull at its height lets
## water into the cabin
## (`level`: fraction of the cabin's height, floor to roof). The crew swims in it, it cools the
## engine, and above STALL the engine drowns. The bilge pump drains it once nothing is leaking.

const LEAK := 0.03             # per second per breach with water outside it
const PUMP := 0.025            # per second while nothing leaks
const STALL := 0.55            # the engine drowns above this

var drill: Drill
var level := 0.0
var leaking := 0               # breaches letting water in right now
var _leak_sound := AudioStreamPlayer2D.new()
var _pump_sound := AudioStreamPlayer2D.new()


func _ready() -> void:
	_leak_sound.stream = Sfx.looping("water_leak")
	_pump_sound.stream = Sfx.looping("pump")
	for p in [_leak_sound, _pump_sound]:
		p.bus = "SFX"
		add_child(p)


func update(dt: float) -> void:
	leaking = 0
	for b in drill.get_breaches():
		for side in [-1.0, 1.0]:
			var outside := drill.world.liquid_at(drill.global_position + Vector2(side * (Drill.HW + 14.0), b.position.y))
			if outside.y == Liquids.WATER and outside.x > 0.3:
				leaking += 1
				break
	for side in [-1.0, 1.0]:              # an open hatch with water outside it
		if drill.hatch_open(side):
			var at := drill.global_position + Vector2(side * (Drill.HW + 6.0), Drill.FLOOR - 6.0)
			var outside := drill.world.liquid_at(at)
			if outside.y == Liquids.WATER and outside.x > 0.3:
				leaking += 1
	var before := level
	if leaking > 0:
		level = minf(level + LEAK * leaking * dt, 1.0)
	else:
		level = maxf(level - PUMP * drill.power.level("pump") * dt, 0.0)
	if level > 0.0:
		drill.thermal.cool(10.0 * level * dt)
	update_sounds()
	if (before < STALL) != (level < STALL):
		drill.changed.emit()


## Leak hiss while water comes in, the pump while it drains (also on online clients).
func update_sounds() -> void:
	_loop(_leak_sound, leaking > 0)
	_loop(_pump_sound, leaking == 0 and level > 0.0)


func drowned() -> bool:
	return level >= STALL


## Local y of the water's surface in the cabin.
func surface_y() -> float:
	return Drill.FLOOR - level * (Drill.FLOOR - Drill.ROOF)


## Is this (global) point in the water flooding the cabin?
func flooded_at(p: Vector2) -> bool:
	if level <= 0.01 or not drill.contains(p):
		return false
	return drill.to_local(p).y > surface_y()


func _loop(p: AudioStreamPlayer2D, on: bool) -> void:
	if on and not p.playing and p.stream:
		p.play()
	elif not on and p.playing:
		p.stop()
