extends Control
class_name SonarView
## The sonar screen (opened at the drill's sonar station): every ping sweeps out from the drill
## and shows rock walls, open caves, ore (coloured blips), crawlers and worms (red) and the
## crew (white) within ~24 m. E / Esc closes.

signal closed

const RANGE_CELLS := 72        # radius in world cells (8 px each)
const STEP := 2                # one sonar pixel = 2x2 cells, chunky like an old CRT
const PING_EVERY := 2.4
const SWEEP_TIME := 0.9
const RADIUS := 250.0          # on screen
const EDGE := Color(0.3, 0.95, 0.8)
const ROCK := Color(0.05, 0.2, 0.18)
const OPEN := Color(0.01, 0.05, 0.05)

var drill: Drill
var world: World
var _img: Image
var _tex: ImageTexture
var _center := Vector2.ZERO    # world position of the last ping
var _blips := []               # [world pos, colour, size]
var _since := 99.0


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func open() -> void:
	visible = true
	_since = PING_EVERY       # ping right away


func close() -> void:
	if visible:
		visible = false
		closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and (event.is_action_pressed("interact") or event.is_action_pressed("ui_cancel")):
		close()
		get_viewport().set_input_as_handled()


func _process(dt: float) -> void:
	if not visible:
		return
	_since += dt
	if _since >= PING_EVERY:
		_ping()
	queue_redraw()


func _ping() -> void:
	_since = 0.0
	_center = drill.global_position
	Sfx.play("sonar_ping", Vector2.INF, -4.0, 0.0)
	var n := RANGE_CELLS * 2 / STEP + 1
	if _img == null:
		_img = Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c0 := world.cell_at(_center) - Vector2i(RANGE_CELLS, RANGE_CELLS)
	var r2 := (n / 2) * (n / 2)
	for j in n:
		for i in n:
			if (i - n / 2) * (i - n / 2) + (j - n / 2) * (j - n / 2) > r2:
				_img.set_pixel(i, j, Color(0, 0, 0, 0))
				continue
			var gx := c0.x + i * STEP
			var gy := c0.y + j * STEP
			var rock := world.get_fill(gx, gy) >= 0.5
			var col := OPEN
			if rock:
				var edge := world.get_fill(gx - STEP, gy) < 0.5 or world.get_fill(gx + STEP, gy) < 0.5 \
					or world.get_fill(gx, gy - STEP) < 0.5 or world.get_fill(gx, gy + STEP) < 0.5
				col = EDGE if edge else ROCK
			_img.set_pixel(i, j, col)
	if _tex == null:
		_tex = ImageTexture.create_from_image(_img)
	else:
		_tex.update(_img)
	_blips.clear()
	var reach := RANGE_CELLS * World.CELL
	for cell in world.ores:
		var p := Vector2(cell.x * World.CELL + 4, cell.y * World.CELL + 4)
		if p.distance_to(_center) < reach:
			var ore: Array = World.ORES[world.ores[cell][2]]
			_blips.append([p, (ore[3] as Color) if ore[0] != "coal" else Color("8a8f99"), 3.0])
	for c: Node2D in get_tree().get_nodes_in_group("creature"):
		if c.global_position.distance_to(_center) < reach:
			_blips.append([c.global_position, Color(1.6, 0.25, 0.2), 4.0])
	for w: Worm in get_tree().get_nodes_in_group("worm"):
		for i in w.body.size():
			if w.body[i].distance_to(_center) < reach:
				_blips.append([w.body[i], Color(1.8, 0.2, 0.15), w._radius(i) * 0.5 + 2.0])
	for p: Node2D in get_tree().get_nodes_in_group("player"):
		_blips.append([p.global_position, Color.WHITE, 3.0])


func _draw() -> void:
	var mid := get_viewport_rect().size / 2.0
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), Color(0, 0, 0, 0.55))
	draw_circle(mid, RADIUS + 14.0, Color("1b1e22"))
	draw_circle(mid, RADIUS + 4.0, Color("06120f"))
	if _tex:
		draw_texture_rect(_tex, Rect2(mid - Vector2(RADIUS, RADIUS), Vector2(RADIUS, RADIUS) * 2.0), false)
	var scale := RADIUS / (RANGE_CELLS * World.CELL)
	var sweep := clampf(_since / SWEEP_TIME, 0.0, 1.0) * RADIUS
	for b in _blips:              # blips light up as the sweep passes them, then fade
		var off: Vector2 = (b[0] - _center) * scale
		if off.length() > sweep:
			continue
		var fade := clampf(1.0 - (_since - off.length() / RADIUS * SWEEP_TIME) / PING_EVERY, 0.25, 1.0)
		var col: Color = b[1]
		draw_circle(mid + off, b[2], Color(col.r, col.g, col.b, fade))
	# the drill itself, the sweep ring, range rings
	var hull := Vector2(Drill.HW * 2.0, Drill.BOTTOM - Drill.TOP) * scale
	draw_rect(Rect2(mid + (drill.global_position - _center) * scale - hull / 2.0, hull), Color(0.8, 1.0, 0.9), false, 1.5)
	if _since < SWEEP_TIME:
		draw_arc(mid, sweep, 0.0, TAU, 64, Color(0.5, 1.6, 1.3, 1.0 - _since / SWEEP_TIME), 2.0)
	for k in [0.33, 0.66, 1.0]:
		draw_arc(mid, RADIUS * k, 0.0, TAU, 64, Color(0.3, 0.9, 0.8, 0.25), 1.0)
	var font := get_theme_default_font()
	draw_string(font, mid + Vector2(-RADIUS, RADIUS + 40.0), "SONAR  %d m range · E to close" % (RANGE_CELLS * World.CELL / World.METER),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.5, 1.0, 0.9))
