extends Node2D
class_name DrillArt
## How the drill looks: Blender-rendered pieces (assets/drill, tools/drill_blender.py) layered
## as a cutaway — back wall, crew + stations, hull frame in front, spinning head below — plus
## what moves in play: braces gripping / pulling in (8 rendered frames, drill_braces_*.png),
## spinning side reamers, lights, the alarm beacon, smoke, sparks. (Ladders: DrillLadder.)
## Never animated by rotating / scaling sprite images: real frames only.


const DIR := "res://assets/drill/"
# where each piece's top-left pixel sits, in the drill's local space (see tools/drill_blender.py)
const BACK_AT := Vector2(-88, -48)
const FRAME_AT := Vector2(-124, -76)
const HEAD_AT := Vector2(-88, 54)
var drill: Drill
var _spin := 0.0
var _back: Texture2D = Art.lit(DIR + "drill_back.png")
var _frame := Sprite2D.new()      # in front of the crew
var _braces := [Sprite2D.new(), Sprite2D.new()]
var _brace_frames := 0
var _head := Sprite2D.new()
var _head_frames := 6
var _interior := PointLight2D.new()
var _beacon := PointLight2D.new()
var _heads := [PointLight2D.new(), PointLight2D.new()]
var _smoke := CPUParticles2D.new()
var _sparks := CPUParticles2D.new()   # off the cutters while biting rock
var _grit := CPUParticles2D.new()     # rock dust blown up the gap beside the hull
var _steam := CPUParticles2D.new()    # coolant flush
var _flood := Node2D.new()            # water inside the cabin, over the crew
var _hatches := Node2D.new()          # the hatch doors, in front like the frame


func _ready() -> void:
	z_index = -1
	var frame: Texture2D = Art.lit(DIR + "drill_frame.png")
	_frame.centered = false
	_frame.z_index = 2                 # draws over the crew: the hull's front edges
	_frame.z_as_relative = false
	add_child(_frame)
	if ResourceLoader.exists(DIR + "drill_braces.json"):
		_frame.texture = frame
		_frame.position = FRAME_AT
		var bi = JSON.parse_string(FileAccess.get_file_as_string(DIR + "drill_braces.json"))
		_brace_frames = int(bi.frames)
		for i in 2:
			var b: Sprite2D = _braces[i]
			b.texture = Art.lit(DIR + ("drill_braces_l.png" if i == 0 else "drill_braces_r.png"))
			b.hframes = _brace_frames
			b.centered = false
			b.position = Vector2(bi.left_top_left[0], bi.left_top_left[1]) if i == 0 \
				else Vector2(bi.right_top_left[0], bi.right_top_left[1])
			b.z_index = 1                  # behind the frame
			b.z_as_relative = false
			add_child(b)
	else:
		# older art: braces baked into the frame (they just stay put)
		_frame.texture = frame
		_frame.position = FRAME_AT
	var info = JSON.parse_string(FileAccess.get_file_as_string(DIR + "drill_head.json"))
	if info is Dictionary:
		_head_frames = int(info.get("frames", 6))
	_head.texture = Art.lit(DIR + "drill_head.png")
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
	_particles(_sparks, Vector2(0, 100), Vector2(150, 8), 40, 0.45, Color(2.4, 1.5, 0.6), 1.2, true)
	_sparks.direction = Vector2(0, -1)
	_sparks.spread = 70.0
	_sparks.initial_velocity_min = 60.0
	_sparks.initial_velocity_max = 160.0
	_sparks.gravity = Vector2(0, 500)
	_particles(_grit, Vector2(0, 60), Vector2(118, 10), 30, 1.4, Color(0.5, 0.44, 0.38, 0.6), 3.5, false)
	_grit.direction = Vector2(0, -1)
	_grit.spread = 25.0
	_grit.initial_velocity_min = 20.0
	_grit.initial_velocity_max = 50.0
	_grit.gravity = Vector2(0, 20)
	_particles(_steam, Vector2(0, Drill.TOP - 2), Vector2(70, 2), 60, 1.6, Color(0.9, 0.92, 0.95, 0.55), 6.0, false)
	_steam.one_shot = true
	_steam.explosiveness = 0.8
	_steam.direction = Vector2(0, -1)
	_steam.spread = 50.0
	_steam.initial_velocity_min = 40.0
	_steam.initial_velocity_max = 110.0
	_steam.gravity = Vector2(0, -20)
	drill.vented.connect(func(): _steam.restart())
	_flood.z_index = 2
	_flood.z_as_relative = false
	_flood.draw.connect(_draw_flood)
	add_child(_flood)
	_hatches.z_index = 2
	_hatches.z_as_relative = false
	_hatches.draw.connect(_draw_hatches)
	add_child(_hatches)


func _process(dt: float) -> void:
	if drill.cutter.drilling:
		_spin += dt * 18.0
	elif drill.speed != Drill.Speed.STOP and drill.fuel > 0.0:
		_spin += dt * 6.0
	var alarm := drill.get_breaches().size() > 0 or drill.hull < drill.max_hull * 0.25
	_beacon.enabled = alarm and fmod(Time.get_ticks_msec() / 1000.0, 0.6) < 0.3
	_smoke.emitting = drill.speed != Drill.Speed.STOP and drill.fuel > 0.0
	_sparks.emitting = drill.cutter.drilling and (drill.cutter.chew_mat == World.M.STONE or drill.cutter.chew_mat == World.M.HARD)
	position = drill.cutter.judder
	_flood.queue_redraw()
	_hatches.queue_redraw()
	# running hot: the hull glows red (a colour change, the art itself doesn't move)
	var hot := clampf((drill.thermal.heat - 55.0) / 45.0, 0.0, 1.0)
	_frame.modulate = Color(1.0 + hot * 0.6, 1.0 - hot * 0.25, 1.0 - hot * 0.35)
	_grit.emitting = drill.cutter.drilling
	_interior.energy = 1.1 if drill.fuel > 0.0 else 0.5 + 0.2 * sin(Time.get_ticks_msec() * 0.01)
	_head.frame = int(_spin) % _head_frames
	if _brace_frames > 0:              # 0 = pulled in .. last = gripping the wall
		for b: Sprite2D in _braces:
			b.frame = int(round(drill.grip * (_brace_frames - 1)))
	queue_redraw()


func _draw() -> void:
	draw_texture(_back, BACK_AT)
	for r: Vector2 in DrillCutter.REAMERS:
		_draw_reamer(r)


## Each hatch is a riveted steel plate that slides up into the wall above the doorway.
func _draw_hatches() -> void:
	var h := Drill.FLOOR - Drill.DOOR_TOP
	for i in 2:
		var shut: float = 1.0 - drill.hatches[i]
		if shut <= 0.01:
			continue
		var x := -Drill.HW if i == 0 else Drill.HW - Drill.WALL
		var r := Rect2(x, Drill.DOOR_TOP, Drill.WALL, h * shut)
		_hatches.draw_rect(r, Color("4a5059"))
		_hatches.draw_rect(Rect2(r.position, Vector2(r.size.x, 1)), Color("6b737d"))
		_hatches.draw_rect(r, Color("0c0a0e"), false, 1.0)
		var y := Drill.DOOR_TOP + 6.0
		while y < Drill.DOOR_TOP + h * shut - 3.0:                   # rivets
			_hatches.draw_rect(Rect2(x + Drill.WALL / 2.0 - 0.5, y, 1, 1), Color("8a929c"))
			y += 10.0
		if shut > 0.15:                                               # hazard stripes on the edge
			for k in 4:
				_hatches.draw_rect(Rect2(x + k * 2.0, r.end.y - 3.0, 2, 3), Color("e0b23a") if k % 2 == 0 else Color("0c0a0e"))


## The water flooding the cabin: translucent, with a rippling surface line.
func _draw_flood() -> void:
	if drill.flooding.level <= 0.005:
		return
	var y := drill.flooding.surface_y()
	var x0 := -Drill.HW + Drill.WALL
	var w := (Drill.HW - Drill.WALL) * 2.0
	_flood.draw_rect(Rect2(x0, y, w, Drill.FLOOR - y), Color(0.1, 0.28, 0.45, 0.55))
	var t := Time.get_ticks_msec() * 0.004
	var x := x0
	while x < x0 + w:
		var dy := sin(t + x * 0.3) * 1.0
		_flood.draw_rect(Rect2(x, y + dy - 1.0, 4.0, 1.0), Color(0.62, 0.8, 0.95, 0.85))
		x += 4.0


## A side reamer: a toothed disc spinning at the hull's bottom corner.
func _draw_reamer(c: Vector2) -> void:
	draw_circle(c, 10.0, Color("2b2f36"))
	draw_circle(c, 7.0, Color("6f757e"))
	var a0 := _spin * 0.9 * (1.0 if c.x > 0.0 else -1.0)
	for k in 8:
		var a := a0 + k * TAU / 8.0
		var d := Vector2(cos(a), sin(a))
		draw_line(c + d * 6.0, c + d * 11.0, Color("c9ccd1"), 2.0)
	draw_circle(c, 2.5, Color("1a1c20"))


func _particles(p: CPUParticles2D, at: Vector2, extents: Vector2, amount: int, life: float,
		color: Color, size: float, glowing: bool) -> void:
	p.position = at
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = extents
	p.amount = amount
	p.lifetime = life
	p.color = color
	p.scale_amount_min = size * 0.5
	p.scale_amount_max = size
	p.emitting = false
	var fade := Gradient.new()
	fade.set_color(0, Color.WHITE)
	fade.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = fade
	if glowing:                     # bright and unaffected by the dark, so it blooms
		var m := CanvasItemMaterial.new()
		m.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		p.material = m
	add_child(p)


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
