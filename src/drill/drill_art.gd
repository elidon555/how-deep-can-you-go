extends Node2D
class_name DrillArt
## How the drill looks, drawn in code for now (a Blender pass can replace it later):
## a cutaway hull (back wall, plated frame, grated floor, pipes, door frames), braces against
## the shaft walls, an exhaust, a spinning toothed head, lights, and a red alarm beacon.

const STEEL := Color("59606b")
const STEEL_LIT := Color("7d8591")
const STEEL_DARK := Color("3a3f47")
const OUTLINE := Color("0c0a0e")
const BACK := Color("2a2622")
const BACK_LINE := Color("1e1b18")

var drill: Drill
var _spin := 0.0
var _interior := PointLight2D.new()
var _beacon := PointLight2D.new()
var _heads := [PointLight2D.new(), PointLight2D.new()]
var _smoke := CPUParticles2D.new()


func _ready() -> void:
	z_index = -1
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
		_spin += dt * 40.0
	elif drill.speed != Drill.Speed.STOP and drill.fuel > 0.0:
		_spin += dt * 12.0
	var alarm := drill.get_breaches().size() > 0 or drill.hull < drill.max_hull * 0.25
	_beacon.enabled = alarm and fmod(Time.get_ticks_msec() / 1000.0, 0.6) < 0.3
	_smoke.emitting = drill.speed != Drill.Speed.STOP and drill.fuel > 0.0
	_interior.energy = 1.1 if drill.fuel > 0.0 else 0.5 + 0.2 * sin(Time.get_ticks_msec() * 0.01)
	queue_redraw()


func _draw() -> void:
	var hw := Drill.HW
	var w := Drill.WALL
	# back wall (the cutaway's inside)
	draw_rect(Rect2(-hw + w, Drill.ROOF, hw * 2 - w * 2, Drill.FLOOR - Drill.ROOF), BACK)
	for x in range(int(-hw + w) + 24, int(hw - w), 24):
		draw_line(Vector2(x, Drill.ROOF), Vector2(x, Drill.FLOOR), BACK_LINE, 1.0)
		for y in [Drill.ROOF + 6, Drill.FLOOR - 6]:
			draw_rect(Rect2(x - 3, y, 1, 1), Color("4a443d"))
	# pipes under the roof
	draw_rect(Rect2(-hw + w, Drill.ROOF + 4, hw * 2 - w * 2, 3), Color("6b4a2e"))
	for x in range(int(-hw + w) + 16, int(hw - w), 40):
		draw_rect(Rect2(x, Drill.ROOF + 3, 4, 5), Color("8a6a42"))
	# braces pushing on the shaft walls
	for side in [-1, 1]:
		for y in [-36.0, 20.0]:
			var x0: float = side * hw
			draw_rect(Rect2(minf(x0, x0 + side * 20), y, 20, 5), STEEL_DARK)
			draw_rect(Rect2(x0 + side * 18 - (2 if side > 0 else 0), y - 3, 4, 11), STEEL)
	# frame: roof, walls above the doors, floor + machinery band
	box(self, Rect2(-hw, Drill.TOP, hw * 2, Drill.ROOF - Drill.TOP), STEEL)
	box(self, Rect2(-hw, Drill.TOP, w, Drill.DOOR_TOP - Drill.TOP), STEEL)
	box(self, Rect2(hw - w, Drill.TOP, w, Drill.DOOR_TOP - Drill.TOP), STEEL)
	box(self, Rect2(-hw, Drill.FLOOR, hw * 2, Drill.BOTTOM - Drill.FLOOR), STEEL_DARK)
	for x in range(int(-hw) + 4, int(hw) - 4, 6):        # floor grating
		draw_rect(Rect2(x, Drill.FLOOR + 1, 3, 2), Color("23262c"))
	for i in 4:                                            # turning gears in the machinery band
		var c := Vector2(-60 + i * 40, Drill.FLOOR + 9)
		draw_circle(c, 5.0, Color("2b2f36"))
		var a := _spin * (1 if i % 2 == 0 else -1) * 0.2
		for k in 4:
			draw_line(c, c + Vector2(cos(a + k * PI / 2), sin(a + k * PI / 2)) * 5.0, STEEL_LIT, 1.0)
	# hazard stripes on the door frames
	for side in [-1, 1]:
		var x: float = side * (hw - w / 2.0) - 1
		for k in range(0, 8):
			draw_rect(Rect2(x, Drill.DOOR_TOP - 4 + k * 0.0, 2, 4), Color("e0b23a") if k % 2 == 0 else OUTLINE)
		for y in range(int(Drill.DOOR_TOP), int(Drill.DOOR_TOP) + 6, 3):
			draw_rect(Rect2(side * hw - (w if side > 0 else 0), y, w, 2), Color("e0b23a") if (y / 3) % 2 == 0 else OUTLINE)
	# rivets
	for x in range(int(-hw) + 6, int(hw), 12):
		draw_rect(Rect2(x, Drill.TOP + 2, 1, 1), STEEL_LIT)
	# exhaust and beacon on the roof
	box(self, Rect2(-66, Drill.TOP - 20, 8, 20), STEEL_DARK)
	box(self, Rect2(-68, Drill.TOP - 22, 12, 4), STEEL)
	box(self, Rect2(-4, Drill.TOP - 8, 8, 8), Color("7a1a14") if not _beacon.enabled else Color(2.0, 0.4, 0.3))
	_draw_head()


func _draw_head() -> void:
	var pts := PackedVector2Array(Drill.HEAD)
	draw_colored_polygon(pts, Color("6f757e"))
	# cutter teeth: diagonal bands sliding sideways as it spins
	var off := fmod(_spin * 6.0, 12.0)
	for k in range(-10, 10):
		var x := k * 12.0 + off
		var a := Vector2(x, Drill.BOTTOM + 2)
		var b := Vector2(x * 0.42 - 6, 92)
		if absf(a.x) < 84 and absf(b.x) < 34:
			draw_line(a, b, Color("c9ccd1"), 2.0)
			draw_line(a + Vector2(3, 0), b + Vector2(3, 0), Color("2a2d33"), 1.0)
	draw_polyline(pts + PackedVector2Array([pts[0]]), OUTLINE, 1.5)
	draw_colored_polygon(PackedVector2Array([Vector2(-8, 96), Vector2(8, 96), Vector2(0, 108)]), Color("c9ccd1"))


## Filled rect with a 1 px outline, a lit top edge and a shaded bottom edge.
static func box(ci: CanvasItem, r: Rect2, c: Color) -> void:
	ci.draw_rect(r, c)
	ci.draw_rect(Rect2(r.position, Vector2(r.size.x, 1)), c.lightened(0.25))
	ci.draw_rect(Rect2(r.position + Vector2(0, r.size.y - 1), Vector2(r.size.x, 1)), c.darkened(0.35))
	ci.draw_rect(r, OUTLINE, false, 1.0)


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
