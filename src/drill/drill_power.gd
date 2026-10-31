extends Node
class_name DrillPower
## The drill's electrics. The furnace drives a generator whose output the crew sets there
## (Low / Normal / Boost). Everything electric draws on it: the head (more at full speed), the
## turrets while manned, the bilge pump while it pumps, the modules. Asking for more than there
## is browns everything out: the head cuts slower, the pump and lights falter, the turrets reload
## slowly, and a long brownout can blow a fuse. Boost with little to power wastes the rest as heat.
## Two fuse boxes on the walls feed the stations (CIRCUITS); a hard knock on the hull, a surge or
## a fire can blow one, and what's on it is dead until someone replaces the fuse (Junction).

signal changed

enum Output { LOW, NORMAL, BOOST }
const OUTPUT_NAMES := ["Low", "Normal", "Boost"]
const SUPPLY := [40.0, 75.0, 110.0]
const DRAW_BASE := 10.0                    # lights, gauges
const DRAW_HEAD := [0.0, 25.0, 55.0]       # by drill speed, while the head turns
const DRAW_GUNS := 15.0                    # turrets, while someone's on them
const DRAW_PUMP := 15.0                    # bilge pump, while there's water inside
const DRAW_MODULE := {"floodlights": 8.0, "sprinklers": 4.0, "drone": 10.0}
const WASTE_HEAT := 0.05                   # heat per second per unit Boost doesn't use
const SURGE_AFTER := 6.0                   # seconds of deep brownout before a fuse may go
# what each fuse box (left, right) feeds
const CIRCUITS := [["sonar", "medkit", "lights", "pump"], ["helm", "guns", "coolant", "modules"]]

var drill: Drill
var output := Output.NORMAL
var blown := [false, false]
var demand := DRAW_BASE
var _surge_t := 0.0
var _hum := AudioStreamPlayer2D.new()


func _ready() -> void:
	_hum.stream = Sfx.looping("generator_hum")
	_hum.bus = "SFX"
	_hum.volume_db = -14.0
	_hum.max_distance = 500.0
	add_child(_hum)


func supply() -> float:
	return SUPPLY[output]


## 0..1: how much of what's asked for there is (1 = everything gets full power).
func ratio() -> float:
	return clampf(supply() / maxf(demand, 1.0), 0.0, 1.0)


## Is this system's fuse box working? ("sonar", "helm", "guns", ... see CIRCUITS)
func powered(system: String) -> bool:
	for i in CIRCUITS.size():
		if system in CIRCUITS[i]:
			return not blown[i]
	return true


## How strongly a system runs right now: 0 with its fuse blown, else the brownout ratio.
func level(system: String) -> float:
	return ratio() if powered(system) else 0.0


func cycle_output() -> void:
	output = ((output + 1) % 3) as Output
	Sfx.play("lever", drill.global_position, -6.0)
	Sfx.play("power_up" if output != Output.LOW else "power_down", drill.global_position, -8.0)
	changed.emit()


func blow(i: int) -> void:
	if blown[i]:
		return
	blown[i] = true
	var at := drill.global_position + Vector2(Junction.X[i], Junction.Y)
	Sfx.play("spark", at)
	Sfx.play("power_down", at, -4.0)
	if randf() < 0.3:                      # the box sparks: something catches
		drill.fires.ignite(Junction.X[i] * 0.85)
	changed.emit()


func fix(i: int) -> void:
	if not blown[i]:
		return
	blown[i] = false
	Sfx.play("power_up", drill.global_position + Vector2(Junction.X[i], Junction.Y))
	changed.emit()


## A hit on the hull: a hard one can blow a fuse.
func knock(amount: float) -> void:
	if amount >= 8.0 and randf() < amount / 60.0:
		blow(randi() % 2)


func update(dt: float) -> void:
	demand = DRAW_BASE
	if drill.running:
		demand += DRAW_HEAD[drill.speed]
	if drill.guns.gunner and powered("guns"):
		demand += DRAW_GUNS
	if drill.flooding.level > 0.0 and powered("pump"):
		demand += DRAW_PUMP
	if powered("modules"):
		for m in DRAW_MODULE:
			if Progress.level(m) > 0:
				demand += DRAW_MODULE[m]
	if output == Output.BOOST and supply() > demand:
		drill.thermal.heat += (supply() - demand) * WASTE_HEAT * dt
	_surge_t = _surge_t + dt if ratio() < 0.6 else 0.0
	if _surge_t > SURGE_AFTER:
		_surge_t = 0.0
		if randf() < 0.5:
			blow(randi() % 2)
	update_sounds()


func update_sounds() -> void:
	_hum.pitch_scale = 0.8 + 0.3 * output
	if _hum.stream and not _hum.playing:
		_hum.play()


# ---------------------------------------------------------------- online (part of Drill.net_state)

func net_state() -> Array:
	return [output, blown[0], blown[1], demand]


func net_apply(s: Array) -> void:
	output = s[0] as Output
	blown = [s[1], s[2]]
	demand = s[3]
