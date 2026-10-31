extends Node2D
class_name DrillArt
## How the drill looks: Blender-rendered pieces (assets/drill, tools/drill_blender.py) layered
## as a cutaway — back wall, crew + stations, hull frame in front, spinning head below — plus
## what changes in play, drawn here: lights, the alarm beacon, exhaust smoke.


const DIR := "res://assets/drill/"
# where each piece's top-left pixel sits, in the drill's local space (see tools/drill_blender.py)
const BACK_AT := Vector2(-88, -48)
const FRAME_AT := Vector2(-124, -76)
const HEAD_AT := Vector2(-88, 54)

var drill: Drill
var _spin := 0.0
var _back: Texture2D = load(DIR + "drill_back.png")
var _frame := Sprite2D.new()      # in front of the crew
var _head := Sprite2D.new()
var _head_frames := 6
var _interior := PointLight2D.new()
var _beacon := PointLight2D.new()
var _heads := [PointLight2D.new(), PointLight2D.new()]
var _smoke := CPUParticles2D.new()


func _ready() -> void:
	z_index = -1
	_frame.texture = load(DIR + "drill_frame.png")
	_frame.centered = false
	_frame.position = FRAME_AT
	_frame.z_index = 2                 # draws over the crew: the hull's front edges
	_frame.z_as_relative = false
	add_child(_frame)
	var info = JSON.parse_string(FileAccess.get_file_as_string(DIR + "drill_head.json"))
	if info is Dictionary:
		_head_frames = int(info.get("frames", 6))
	_head.texture = load(DIR + "drill_head.png")
	_head.hframes = _head_frames
	_head.centered = false
	_head.position = HEAD_AT
	add_child(_head)
	var radial := _radial_texture()
	_interior.texture = radial
	_interior.texture_scale = 1.6
	_interior.color = Color("ffd29a")
	_interior.energy = 1.1
	_interior.position = Vector2(0, -20)
	add_child(_interior)
	_beacon.texture = radial
	_beacon.texture_scale = 0.9
	_beacon.color = Color("ff3a2a")
	_beacon.position = Vector2(0, Drill.TOP - 6)
	add_child(_beacon)
	var cone := Player._cone_texture()
	for i in 2:                                   # headlights aimed down past the head
		var l: PointLight2D = _heads[i]
		l.texture = cone
		l.texture_scale = 1.8
		l.color = Color("fff0c8")
		l.energy = 1.2
		l.rotation = PI / 2 + (0.35 if i == 0 else -0.35)
		l.position = Vector2(-60 if i == 0 else 60, Drill.BOTTOM - 2)
		add_child(l)
	_smoke.amount = 24
	_smoke.lifetime = 2.0
	_smoke.position = Vector2(-62, Drill.TOP - 22)
	_smoke.direction = Vector2(0, -1)
	_smoke.spread = 20.0
	_smoke.initial_velocity_min = 12.0
	_smoke.initial_velocity_max = 24.0
	_smoke.gravity = Vector2(4, -6)
	_smoke.scale_amount_min = 2.0
	_smoke.scale_amount_max = 5.0
	_smoke.color = Color(0.25, 0.24, 0.24, 0.5)
	add_child(_smoke)


func _process(dt: float) -> void:
	if drill.drilling:
		_spin += dt * 18.0
	elif drill.speed != Drill.Speed.STOP and drill.fuel > 0.0:
		_spin += dt * 6.0
	var alarm := drill.get_breaches().size() > 0 or drill.hull < drill.max_hull * 0.25
	_beacon.enabled = alarm and fmod(Time.get_ticks_msec() / 1000.0, 0.6) < 0.3
	_smoke.emitting = drill.speed != Drill.Speed.STOP and drill.fuel > 0.0
	_interior.energy = 1.1 if drill.fuel > 0.0 else 0.5 + 0.2 * sin(Time.get_ticks_msec() * 0.01)
	_head.frame = int(_spin) % _head_frames
	queue_redraw()


func _draw() -> void:
	draw_texture(_back, BACK_AT)


static func _radial_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 256
	t.height = 256
	return t
