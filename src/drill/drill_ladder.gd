extends Rope
class_name DrillLadder
## A telescoping steel ladder on the drill's hull, next to a door. `extend` (0..1, set by the
## Drill) slides its sections out of each other: the top section first, then each one below,
## with a little settle bounce when a section locks. Climbable like any Rope, as far as it
## currently reaches.

const SECTIONS := 4
const SECTION := 24.0          # length of one section
const OVERLAP := 4.0           # how much each section stays inside the one above
const RUNG := 6.0

var extend := 1.0:
	set(v):
		extend = v
		bottom = top + _length()
		queue_redraw()


func _ready() -> void:
	super._ready()
	ladder = true
	bottom = top + _length()


## How far the ladder reaches below its top: the sections unfold one after another.
func _length() -> float:
	var l := SECTION
	for i in range(1, SECTIONS):
		l += (SECTION - OVERLAP) * _section_out(i)
	return l


## 0..1 for section i (1 = fully out), staggered so they slide out in turn, eased.
func _section_out(i: int) -> float:
	var span := 1.0 / (SECTIONS - 1)
	var t := clampf((extend - (i - 1) * span) / span, 0.0, 1.0)
	return 1.0 - pow(1.0 - t, 3.0)      # ease out: fast, then settles into place


func _draw() -> void:
	# from the bottom section up, so upper (wider) sections draw over the ones inside them
	var y_top := [top]
	for i in range(1, SECTIONS):
		y_top.append(y_top[i - 1] + (SECTION - OVERLAP) * _section_out(i))
	for i in range(SECTIONS - 1, -1, -1):
		var y0: float = y_top[i]
		var half := 5.0 - i * 0.5                         # inner sections are a bit narrower
		var rail := Color("2a2d33").lightened(0.06 * i)
		for x in [-half, half]:
			draw_line(Vector2(x, y0), Vector2(x, y0 + SECTION), rail, 2.0)
		var y := y0 + 3.0
		while y < y0 + SECTION - 1.0:
			draw_line(Vector2(-half, y), Vector2(half, y), Color("6d7480"), 2.0)
			y += RUNG
		draw_rect(Rect2(-half - 1, y0 + SECTION - 2, half * 2 + 2, 2), Color("e0b23a"))   # hazard foot
	draw_rect(Rect2(-7, top - 2, 14, 4), Color("3a3f47"))   # hinge bracket on the hull
