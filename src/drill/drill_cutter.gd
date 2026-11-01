extends Node
class_name DrillCutter
## How the drill goes down. The cutters bite in pulses: each bite chews only the rock just in
## front of the head's face (cracks first, then it crumbles; ore it grinds through is lost) and
## the side reamers widen the shaft past the hull. The machine sinks only as fast as the rock
## in front gives way, free-falls when it breaks into a cave, and crashes if it falls far.

signal chewed(points: Array, mat: int)   # rock that just broke off (for debris)
signal knocked(pos: Vector2)             # the cutters hit the Floor, which nothing can cut

const DESCENT := [0.0, 0.35, 0.9]      # m/s it sinks at when the rock in front gives way
const HEAD_POWER := [0.0, 0.5, 1.0]
# the head's cutting face (left to right along its underside); cutters bite just beyond it
const FACE := [Vector2(-86, 54), Vector2(-34, 93), Vector2(0, 106), Vector2(34, 93), Vector2(86, 54)]
const CUTTER_R := 6.0
const CUTTER_REACH := 3.0      # how far in front of the face the cutters chew
const BITE := 1.0 / 7.0        # the cutters bite in pulses (s), not a smooth erosion
# side reamers at the hull's bottom corners widen the shaft beyond the hull (the crew's gap)
const REAMERS := [Vector2(-104, 60), Vector2(104, 60)]
const REAMER_R := 16.0
const FALL_GRAVITY := 700.0
const CRASH_SPEED := 340.0     # landing faster than this damages the hull

var drill: Drill
var drilling := false          # the head is turning and biting rock
var moving := false            # sinking this frame
var chew_mat := -1             # what the cutters are biting (sparks only off stone)
var judder := Vector2.ZERO     # the hull shakes a pixel when a bite breaks rock (art reads it)
var _bite_power := 0.0         # cutting power saved up until the next bite
var _bite_clock := 0.0
var _bite_t := 0.0             # keeps "drilling" steady between bites
var _fall_v := 0.0
var _knock_t := 0.0


## Digs the pit the drill starts in, shaped to its head.
func dig_start_pit() -> void:
	var g := drill.global_position
	for i in 4:
		drill.world.dig(g + Vector2(-80, 74), g + Vector2(80, 74), 40.0, 10.0, false)
		_cut_reamers(10.0)
	_bite_clock = BITE


func update(dt: float, running: bool) -> void:
	_bite_t -= dt
	judder = Vector2.ZERO
	if running:
		_bite_power += Progress.drill_power() * Unlocks.drill(drill.variant).power * HEAD_POWER[drill.speed] \
			* drill.power.ratio() * dt
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
	drilling = running and _bite_t > 0.0
	_knock_t -= dt
	if running and _knock_t <= 0.0 and free_below_face(3.0) < 1.0:
		var tip := drill.global_position + Vector2(0, 110)
		if drill.world.mat_at(tip) == World.M.FLOOR:
			_knock_t = 2.0
			Sfx.play("knock", tip, 4.0)
			knocked.emit(tip)
	moving = false
	if not _fall(dt):
		_sink(dt, running)


## Sinks as far as the rock in front of the head and under the reamers allows.
func _sink(dt: float, running: bool) -> void:
	if not running:
		return
	var push: float = DESCENT[drill.speed] * World.METER * dt
	var step := minf(push, minf(free_below_face(push + 1.0), _free_below_hull(push + 1.0)))
	if step > 0.0:
		drill.position.y += step
		moving = true


## Free-falls (head, hull and all) when it breaks into a cave with nothing under it.
## Returns true while falling.
func _fall(dt: float) -> bool:
	var open := free_below_face(14.0) >= 14.0 and _free_below_hull(14.0) >= 14.0
	if open:
		_fall_v = minf(_fall_v + FALL_GRAVITY * dt, 500.0)
		var step := minf(_fall_v * dt, minf(free_below_face(64.0), _free_below_hull(64.0)))
		drill.position.y += step
		return step > 0.0
	if _fall_v > CRASH_SPEED:     # crashed onto a cave floor (a drop of ~3.5 m or more)
		drill.damage((_fall_v - CRASH_SPEED + 30.0) * 0.12,
			drill.global_position + Vector2(randf_range(-40, 40), Drill.BOTTOM))
	_fall_v = 0.0
	return false


## Free space (px) in front of the head's cutting face, up to `limit`.
func free_below_face(limit: float) -> float:
	return _free_below(_face_points(), limit)


## Free space (px) under the hull's whole bottom, up to `limit`: the corners are what the
## reamers cut, the middle is where the head has already been.
func _free_below_hull(limit: float) -> float:
	var pts := []
	for x in [-118.0, -104.0, -90.0, -60.0, -20.0, 20.0, 60.0, 90.0, 104.0, 118.0]:
		pts.append(Vector2(x, Drill.BOTTOM + 2.0))
	return _free_below(pts, limit)


func _free_below(points: Array, limit: float) -> float:
	var d := 0.0
	while d < limit:
		for p: Vector2 in points:
			if not drill.world.is_air(drill.global_position + p + Vector2(0, d + 2.0)):
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
		var g := drill.global_position
		var r := drill.world.dig(g + a + off, g + b + off, CUTTER_R, amount, false)
		if r.hit:      # (ore it grinds through is lost)
			out_res.hit = true
			out_res.mat = r.mat
			out_res.points.append_array(r.points)
	return out_res


func _cut_reamers(amount: float) -> void:
	for r: Vector2 in REAMERS:
		var at := drill.global_position + r
		drill.world.dig(at, at + Vector2(0, 6), REAMER_R, amount, false)
