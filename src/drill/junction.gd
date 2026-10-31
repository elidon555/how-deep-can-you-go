extends Station
class_name Junction
## A fuse box on the cabin wall (DrillPower: the left one feeds sonar, medkit, lights and pump; the
## right one the helm, turrets, coolant and modules). Its lamp is green while it works. Blown, it
## sparks, and the crew holds E on it to put in a new fuse.

const X := [-78.0, 78.0]       # local x of the left / right box
const Y := -14.0               # mounted on the wall, reachable from the floor
const REPAIR_TIME := 2.5
const TEX := Stations.DIR + "junction.png"
const TEX_GLOW := Stations.DIR + "junction_glow.png"

var index := 0
var _tex: Texture2D = Art.lit(TEX) if ResourceLoader.exists(TEX) else null
var _glow := Sprite2D.new()
var _sparks := CPUParticles2D.new()


func _ready() -> void:
	super._ready()
	var unlit := CanvasItemMaterial.new()
	unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	if ResourceLoader.exists(TEX_GLOW):
		_glow.texture = load(TEX_GLOW)
		_glow.offset = Vector2(0, -_glow.texture.get_height() / 2.0)
		_glow.material = unlit
		add_child(_glow)
	_sparks.position = Vector2(0, -8)
	_sparks.amount = 10
	_sparks.lifetime = 0.35
	_sparks.explosiveness = 0.6
	_sparks.direction = Vector2(-signf(X[index]), 0.3)
	_sparks.spread = 70.0
	_sparks.initial_velocity_min = 30.0
	_sparks.initial_velocity_max = 70.0
	_sparks.gravity = Vector2(0, 300)
	_sparks.color = Color(2.6, 2.0, 0.9)
	_sparks.material = unlit
	_sparks.emitting = false
	add_child(_sparks)


func prompt(_p: Player) -> String:
	return "Hold E: replace the blown fuse" if drill.power.blown[index] else ""


func hold_time() -> float:
	return REPAIR_TIME


func priority() -> int:
	return 1


func interact(_p: Player) -> void:
	drill.power.fix(index)


func _process(_dt: float) -> void:
	var dead: bool = drill.power.blown[index]
	_sparks.emitting = dead and fmod(Time.get_ticks_msec() / 1000.0, 1.3) < 0.15
	_glow.modulate = Color(0.3, 1.6, 0.6) if not dead else Color(1.8, 0.2, 0.15, 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.02))
	queue_redraw()


func _draw() -> void:
	if _tex:
		Stations.stand(self, _tex)
	else:
		draw_rect(Rect2(-6, -16, 12, 16), Color("3a3f47"))
		draw_rect(Rect2(-6, -16, 12, 16), Color("0c0a0e"), false, 1.0)
		var lamp := Color(0.3, 1.6, 0.6) if not drill.power.blown[index] else Color(1.8, 0.2, 0.15)
		draw_rect(Rect2(-2, -13, 4, 3), lamp)
