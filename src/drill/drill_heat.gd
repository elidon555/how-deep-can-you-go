extends Node
class_name DrillHeat
## The drill's heat: ambient heat grows with depth (none until ~200 m, about 60 in the magma),
## cutting adds heat by rock type, lava under the head heats it, water cools it, and it cools
## toward ambient on its own. Past MAX it stalls (overheated) and the hull cooks until it's back
## under RESUME. The coolant station vents a big chunk of it, then needs to recharge.

const MAX := 100.0
const RESUME := 65.0           # an overheated drill restarts once it's back under this
const FROM_CUTTING := [0.6, 1.2, 2.2, 0.0, 2.0, 6.0]   # per second, by World.M rock
const COOLING := 1.6           # per second, toward the ambient heat
const OVERHEAT_DAMAGE := 1.5   # hull per second while overheated
const VENT := 45.0             # what one coolant flush takes off
const VENT_RECHARGE := 6.0

var drill: Drill
var heat := 0.0
var overheated := false
var vent_ready_at := 0.0       # seconds (Time) when the coolant can flush again
var _alarm_t := 0.0


func update(dt: float) -> void:
	var depth := drill.global_position.y / World.METER
	var ambient := clampf((depth - 200.0) / 350.0, 0.0, 1.0) * 60.0
	if drill.cutter.drilling and drill.cutter.chew_mat >= 0:
		heat += FROM_CUTTING[drill.cutter.chew_mat] * (2.0 if drill.speed == Drill.Speed.FULL else 1.0) * dt
	heat = move_toward(heat, ambient, COOLING * dt)
	var under := drill.world.liquid_at(drill.global_position + Vector2(0, 100))   # what the head sits in
	if under.y == Liquids.LAVA and under.x > 0.2:
		heat += 14.0 * dt
	elif under.y == Liquids.WATER and under.x > 0.2:
		heat -= 8.0 * dt
	heat = clampf(heat, 0.0, MAX)
	if heat >= MAX and not overheated:
		overheated = true
		Sfx.play("drill_stall", drill.global_position)
		drill.changed.emit()
	elif overheated and heat < RESUME:
		overheated = false
		drill.changed.emit()
	if overheated:
		drill.damage_quietly(OVERHEAT_DAMAGE * dt)
	_alarm_t -= dt
	if heat > 80.0 and _alarm_t <= 0.0:
		_alarm_t = 2.5
		Sfx.play("heat_alarm", drill.global_position, -6.0, 0.0)


## Online: seconds until the coolant can flush again (host), shown on a client.
func vent_wait() -> float:
	return maxf(vent_ready_at - Time.get_ticks_msec() / 1000.0, 0.0)


func show_vent_wait(wait: float) -> void:
	vent_ready_at = Time.get_ticks_msec() / 1000.0 + wait


func cool(amount: float) -> void:
	heat = maxf(heat - amount, 0.0)


## The coolant station: a big flush of steam takes the heat down, then it recharges.
func vent() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now < vent_ready_at:
		return false
	vent_ready_at = now + VENT_RECHARGE
	cool(VENT)
	Sfx.play("steam_vent", drill.global_position)
	drill.vented.emit()
	drill.changed.emit()
	return true
