extends Node
class_name Liquids
## Water and lava flowing on the dig grid (World stores them per cell, 0..1). Each tick a cell
## pours down first, then levels out sideways; lava moves only every few ticks. Pockets are
## generated in caves and pre-settled (World._gen_liquid); digging into one lets it pour out.
## Water meeting lava turns the lava to rock in a burst of steam. Only liquid near the crew
## and the drill is simulated; settled liquid sleeps until something next to it changes.
## Drawn per chunk by liquid_water / liquid_lava.gdshader: water over the scene, lava glowing.

signal reacted(pos: Vector2)      # water met lava

enum { NONE, WATER, LAVA }
const MIN := 0.01
const TICK := 1.0 / 20.0
const LAVA_EVERY := 3             # lava flows on every 3rd tick
const SPREAD := [0.0, 0.3, 0.18]  # share of the level difference that moves sideways per tick
const RADIUS := 96                # cells around each player / the drill that simulate (beyond the screen,
                                  # so pockets mostly settle before you see them)
const FILM := 0.1                 # a thin film that can't flow anywhere dries up / cools away
const SHADERS := [preload("res://src/world/liquid_water.gdshader"), preload("res://src/world/liquid_lava.gdshader")]

var world: World
var drill: Drill
var _active := {}                 # Vector2i -> true: cells that may still move
var _dirty_chunks := {}           # chunk key -> true: liquid image needs rebuilding
var _woken := {}                  # chunk keys already woken once
var _t := 0.0
var _tick := 0
var step_usec := 0                # how long the last simulation tick took (for profiling)


func _ready() -> void:
	world.opened.connect(func(gx, gy): wake(gx, gy))


## A cell's liquid changed (World.set_liquid): redraw it and its neighbours' margins.
func cell_changed(gx: int, gy: int) -> void:
	for kx in world._keys_covering(gx, 1):
		for ky in world._keys_covering(gy, 1):
			_dirty_chunks[Vector2i(kx, ky)] = true


## Puts liquid into a cell from outside the simulation (events, tests) and lets it flow.
func pour(gx: int, gy: int, amount: float, kind: int) -> void:
	world.set_liquid(gx, gy, amount, kind)
	_active[Vector2i(gx, gy)] = true


## Something changed around a cell (it was dug out): liquid next to it may move again.
func wake(gx: int, gy: int) -> void:
	for dy in range(-2, 2):
		for dx in range(-1, 2):
			if world.get_liquid(gx + dx, gy + dy) > MIN:
				_active[Vector2i(gx + dx, gy + dy)] = true


func _physics_process(dt: float) -> void:
	_t += dt
	while _t >= TICK:
		_t -= TICK
		var t0 := Time.get_ticks_usec()
		_step()
		step_usec = Time.get_ticks_usec() - t0
	_redraw()


func _centres() -> Array:
	var out := []
	for p: Node2D in get_tree().get_nodes_in_group("player"):
		out.append(world.cell_at(p.global_position))
	if drill:
		out.append(world.cell_at(drill.global_position))
	return out


func _near(c: Vector2i, centres: Array) -> bool:
	for k: Vector2i in centres:
		if absi(c.x - k.x) < RADIUS and absi(c.y - k.y) < RADIUS:
			return true
	return false


func _step() -> void:
	_tick += 1
	var centres := _centres()
	_wake_chunks_near(centres)
	_clear_inside_drill()
	var cells := _active.keys()
	cells.sort_custom(func(a: Vector2i, b: Vector2i): return a.y > b.y)   # bottom first
	var next := {}
	for c: Vector2i in cells:
		var kind := world.get_ltype(c.x, c.y)
		var a := world.get_liquid(c.x, c.y)
		if a <= MIN or kind == NONE:
			continue
		if not _near(c, centres) or (kind == LAVA and _tick % LAVA_EVERY != 0):
			next[c] = true                     # out of range / lava's turn later: keep, don't move
			continue
		if _flow(c, kind, a, next):
			next[c] = true
			var up := c + Vector2i(0, -1)      # whatever sits above may fall now
			if world.get_liquid(up.x, up.y) > MIN:
				next[up] = true
	_active = next


## Moves liquid out of cell c: down first, then diagonally down a slope, then sideways toward
## lower neighbours.
## Returns true if anything moved (the cell stays awake).
func _flow(c: Vector2i, kind: int, a: float, next: Dictionary) -> bool:
	var moved := false
	var below := c + Vector2i(0, 1)
	if _open(below):
		var bk := world.get_ltype(below.x, below.y)
		var ba := world.get_liquid(below.x, below.y)
		if bk != NONE and bk != kind:
			_react(c, below)
			return true
		var f := minf(a, 1.0 - ba)
		if f > MIN:
			_move(c, below, f, kind)
			a -= f
			moved = true
			next[below] = true
	var sides := [Vector2i(-1, 0), Vector2i(1, 0)]
	if randi() % 2 == 0:
		sides.reverse()
	if a > MIN:                       # slide down a slope: side cell open and open below it
		for d: Vector2i in sides:
			var s := c + d
			var sd := s + Vector2i(0, 1)
			if not (_open(s) and _open(sd)):
				continue
			var dk := world.get_ltype(sd.x, sd.y)
			if dk != NONE and dk != kind:
				_react(c, sd)
				return true
			var f := minf(a * (0.5 if kind == WATER else 0.3), 1.0 - world.get_liquid(sd.x, sd.y))
			if f > MIN:
				_move(c, sd, f, kind)
				a -= f
				moved = true
				next[sd] = true
	if a > MIN:
		for d: Vector2i in sides:
			var s := c + d
			if not _open(s):
				continue
			var sk := world.get_ltype(s.x, s.y)
			var sa := world.get_liquid(s.x, s.y)
			if sk != NONE and sk != kind:
				_react(c, s)
				return true
			if sa < a - 0.03:
				var f: float = (a - sa) * SPREAD[kind]
				_move(c, s, f, kind)
				a -= f
				moved = true
				next[s] = true
	if not moved and a < FILM:        # stuck on a slope as a film: gone
		world.set_liquid(c.x, c.y, 0.0, NONE)
	return moved


func _move(from: Vector2i, to: Vector2i, f: float, kind: int) -> void:
	world.set_liquid(from.x, from.y, world.get_liquid(from.x, from.y) - f, kind)
	world.set_liquid(to.x, to.y, world.get_liquid(to.x, to.y) + f, kind)


## Water + lava: the lava cell cools to rock, some water boils away.
func _react(a: Vector2i, b: Vector2i) -> void:
	var lava := a if world.get_ltype(a.x, a.y) == LAVA else b
	var water := b if lava == a else a
	world.place_rock(lava.x, lava.y, World.M.HARD)
	world.set_liquid(water.x, water.y, world.get_liquid(water.x, water.y) - 0.4, WATER)
	reacted.emit(Vector2(lava.x * World.CELL + 4, lava.y * World.CELL + 4))
	wake(lava.x, lava.y)


## Open for liquid: not rock, not the world's edge, not inside the drill.
func _open(c: Vector2i) -> bool:
	if c.x < 2 or c.x >= World.W - 2 or world.get_fill(c.x, c.y) >= 0.5:
		return false
	return drill == null or not _in_drill(c)


func _in_drill(c: Vector2i) -> bool:
	var l := drill.to_local(Vector2(c.x * World.CELL + 4, c.y * World.CELL + 4))
	return absf(l.x) < Drill.HW + 2.0 and l.y > Drill.TOP - 2.0 and l.y < 108.0


## The hull pushes liquid out of its way as it sinks (what's inside its outline is gone).
func _clear_inside_drill() -> void:
	if drill == null:
		return
	var c0 := world.cell_at(drill.global_position + Vector2(-Drill.HW, Drill.TOP))
	var c1 := world.cell_at(drill.global_position + Vector2(Drill.HW, 108))
	for gy in range(c0.y, c1.y + 1):
		for gx in range(c0.x, c1.x + 1):
			if world.get_liquid(gx, gy) > 0.0 and _in_drill(Vector2i(gx, gy)):
				world.set_liquid(gx, gy, 0.0, NONE)
				wake(gx, gy - 1)


## Liquid in chunks that come into range starts moving (generation only pre-settled columns).
func _wake_chunks_near(centres: Array) -> void:
	for k: Vector2i in centres:
		for ky in range((k.y - RADIUS) >> 5, ((k.y + RADIUS) >> 5) + 1):
			for kx in range(0, World.W / World.C):
				var key := Vector2i(kx, ky)
				if _woken.has(key):
					continue
				var ch: World.Chunk = world.chunks.get(key)
				if ch == null:
					continue
				_woken[key] = true
				if not ch.has_liquid:
					continue
				for dk in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(0, 0),
						Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
					_dirty_chunks[key + dk] = true       # draw it (and the margins around it)
				for j in World.C:
					for i in World.C:
						if ch.liquid[j * World.C + i] > MIN:
							_active[Vector2i(kx * World.C + i, ky * World.C + j)] = true


# ---------------------------------------------------------------- drawing

## Rebuilds the liquid map of chunks whose liquid changed: R = water, G = lava, with the same
## one-cell margin as the fill map.
func _redraw() -> void:
	var later := {}
	for key: Vector2i in _dirty_chunks:
		var ch: World.Chunk = world.chunks.get(key)
		if ch == null:
			continue
		if ch.tex_fill == null:          # terrain image not built yet: try next frame
			later[key] = true
			continue
		var n := World.C + 2
		var data := PackedByteArray()
		data.resize(n * n * 4)
		var any := false
		for j in n:
			for i in n:
				var gx := key.x * World.C - 1 + i
				var gy := key.y * World.C - 1 + j
				var a := world.get_liquid(gx, gy)
				if a <= 0.0:
					continue
				any = true
				var k := (j * n + i) * 4
				data[k + (0 if world.get_ltype(gx, gy) == WATER else 1)] = int(clampf(a, 0.0, 1.0) * 255.0)
				data[k + 3] = 255
		if not any and ch.liq_tex == null:
			continue
		var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, data)
		if ch.liq_tex == null:
			ch.liq_tex = ImageTexture.create_from_image(img)
			ch.liq_rects = [_rect(ch, ch.liq_tex, 0), _rect(ch, ch.liq_tex, 1)]
		else:
			ch.liq_tex.update(img)
	_dirty_chunks = later


func _rect(ch: World.Chunk, tex: ImageTexture, mode: int) -> ColorRect:
	var r := ColorRect.new()
	r.position = ch.rect.position
	r.size = ch.rect.size
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.z_index = 1                    # over the crew: they're in it, not in front of it
	var m := ShaderMaterial.new()
	m.shader = SHADERS[mode]
	m.set_shader_parameter("liquid_map", tex)
	m.set_shader_parameter("fill_map", ch.tex_fill)
	m.set_shader_parameter("origin", ch.rect.position)
	r.material = m
	world.add_child(r)
	return r
