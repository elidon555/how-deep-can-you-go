extends Node2D
class_name World
## Endless smooth diggable ground. Under the hood: a fine grid of "fill" values
## (8 px cells, 1 = solid rock, 0 = air). The terrain shader draws the 0.5
## contour as smooth organic rock; collision uses the same contour (marching squares).
## Pickaxe hits add "damage" (drawn as cracks); a cell breaks once fill - damage < 0.5.
## Generated in 32x32-cell chunks as the player goes down. 24 px = 1 meter.

signal ore_found(pos: Vector2, kind: int)   # kind: index into ORES
signal boulder_shattered(pos: Vector2)

const CELL := 8
const METER := 24.0
const W := 128                  # cells across (outer 2 columns are bedrock)
const C := 32                   # chunk size in cells (code uses >>5 / &31)
const CHUNK_PX := C * CELL
const WIDTH_PX := W * CELL
const R_INT := 5                # how far (cells) the "deep inside rock" darkening reaches
enum M { DIRT, STONE, HARD, BEDROCK }
const HARDNESS := [1.0, 2.6, 5.5, INF]
const COLORS := [Color("5a3c27"), Color("566275"), Color("3d3350"), Color("1d1924")]
# name, value, nugget colour, glow colour, found from depth (m). Metals sell; coal is drill fuel.
const ORES := [
	["copper", 1, Color("d9824a"), Color("ff9c5a"), 0.0],
	["silver", 3, Color("c9d3e0"), Color("e8f2ff"), 40.0],
	["gold", 8, Color("f2c14e"), Color("ffd36a"), 110.0],
	["coal", 0, Color("26252b"), Color("9aa0ab"), 0.0],
]
const METALS := 3      # ORES[0..2]
const COAL := 3

class Chunk:
	var key: Vector2i
	var fill := PackedFloat32Array()
	var mat := PackedByteArray()
	var dmg := PackedFloat32Array()   # pickaxe damage not yet enough to break the cell
	var img: Image
	var tex_fill: ImageTexture
	var tex_mat: ImageTexture
	var rect: ColorRect
	var shape: ConcavePolygonShape2D
	var vis_dirty := false    # only fill values changed -> re-upload texture
	var int_dirty := false    # rock/air changed -> rebuild images (depth darkening)
	var col_dirty := false    # rock/air changed -> rebuild collision

var chunks := {}                # Vector2i -> Chunk
var next_row := -2              # next chunk row to generate (rows < -2 are open sky)
var dug := {}                   # cells the player carved (not natural caves)
var ores := {}                  # cell -> [lit Sprite2D, glow Sprite2D, ore kind]
var decor := {}                 # anchor cell -> Array[Node2D]
var _collect := true            # set per dig(): does broken ore get handed out?
static var fixed_seed := -1     # tests set this for the same world every run
var glow_root := Node2D.new()   # main moves this onto the unlit glow layer
var noise_cave := FastNoiseLite.new()
var noise_mat := FastNoiseLite.new()
var noise_surf := FastNoiseLite.new()
var rng := RandomNumberGenerator.new()
var terrain_shader: Shader = preload("res://src/world/terrain.gdshader")
var tx := {}
var deco_tex := {}
var props := {}                 # name -> [texture, glow texture or null]
var flicker := []               # lantern lights
var time := 0.0
const PROP_NAMES := ["lantern", "beam", "crystal_p", "crystal_t", "skeleton", "roots", "cart", "crate", "chains"]


func _ready() -> void:
	for n in ["dirt", "stone", "hard", "bedrock"]:
		tx["t_" + n] = load("res://assets/terrain/%s.png" % n)
		tx["n_" + n] = load("res://assets/terrain/%s_n.png" % n)
	_make_decor_textures()
	for p in PROP_NAMES:
		var g := "res://assets/props/%s_glow.png" % p
		props[p] = [Art.lit("res://assets/props/%s.png" % p), load(g) if ResourceLoader.exists(g) else null]
	if fixed_seed >= 0:
		rng.seed = fixed_seed
	else:
		rng.randomize()
	noise_cave.seed = rng.randi()
	noise_cave.frequency = 0.0045
	noise_cave.fractal_octaves = 4
	noise_mat.seed = rng.randi()
	noise_mat.frequency = 0.006
	noise_surf.seed = rng.randi()
	noise_surf.frequency = 0.01
	ensure_generated(CHUNK_PX * 4)


# ---------------------------------------------------------------- generation

func ensure_generated(y_px: float) -> void:
	var want := int(floor(y_px / CHUNK_PX)) + 1
	while next_row <= want:
		for cx in W / C:
			_gen_chunk(Vector2i(cx, next_row))
		for cx in W / C:
			_populate(chunks[Vector2i(cx, next_row)])
		# the row above can now see this row (margins, collision across the seam)
		for cx in W / C:
			for r in [next_row - 1, next_row]:
				var ch: Chunk = chunks.get(Vector2i(cx, r))
				if ch:
					ch.int_dirty = true
					ch.col_dirty = true
		next_row += 1
	_flush()


func _gen_chunk(key: Vector2i) -> void:
	var ch := Chunk.new()
	ch.key = key
	ch.fill.resize(C * C)
	ch.mat.resize(C * C)
	ch.dmg.resize(C * C)
	for j in C:
		for i in C:
			var v := _gen_cell(key.x * C + i, key.y * C + j)
			ch.fill[j * C + i] = v.x
			ch.mat[j * C + i] = int(v.y)
	ch.rect = ColorRect.new()
	ch.rect.position = Vector2(key) * CHUNK_PX
	ch.rect.size = Vector2(CHUNK_PX, CHUNK_PX)
	ch.rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = terrain_shader
	for k in tx:
		mat.set_shader_parameter(k, tx[k])
	mat.set_shader_parameter("origin", ch.rect.position)
	ch.rect.material = mat
	add_child(ch.rect)
	var body := StaticBody2D.new()
	body.position = ch.rect.position
	var cs := CollisionShape2D.new()
	ch.shape = ConcavePolygonShape2D.new()
	cs.shape = ch.shape
	body.add_child(cs)
	add_child(body)
	chunks[key] = ch


func _gen_cell(gx: int, gy: int) -> Vector2:
	if gx < 2 or gx >= W - 2:
		return Vector2(1.0, M.BEDROCK)
	var px := gx * CELL + 4.0
	var py := gy * CELL + 4.0
	var surf := noise_surf.get_noise_1d(px) * 10.0          # gentle bumps at the surface
	if py < surf:
		return Vector2(0.0, M.DIRT)
	var depth := py / METER
	# caves: none right under the grass, bigger the deeper you go
	var t := 0.2 - minf(depth / 800.0, 0.08) + maxf(0.0, 8.0 - depth) * 0.15
	var fill := clampf(0.5 + (t - noise_cave.get_noise_2d(px, py)) * 5.0, 0.0, 1.0)
	fill = minf(fill, clampf((py - surf) / CELL + 0.5, 0.0, 1.0))
	var m := noise_mat.get_noise_2d(px, py) * 0.5 + 0.5
	var mat := M.DIRT
	if m < clampf((depth - 4.0) / 110.0, 0.0, 0.85):
		mat = M.STONE
	if m < clampf((depth - 50.0) / 250.0, 0.0, 0.7):
		mat = M.HARD
	return Vector2(fill, mat)


## Ore, bones, glowing mushrooms and worms.
func _populate(ch: Chunk) -> void:
	for j in C:
		for i in C:
			var gx := ch.key.x * C + i
			var gy := ch.key.y * C + j
			if gx < 3 or gx >= W - 3 or gy < 2:
				continue
			var f := ch.fill[j * C + i]
			var m := ch.mat[j * C + i]
			var depth := gy * CELL / METER
			var pos := Vector2(gx * CELL + 4, gy * CELL + 4)
			if f >= 0.5:
				if depth > 2 and rng.randf() < (0.006 if m == M.DIRT else 0.008):
					var kind := COAL if rng.randf() < 0.55 else _ore_kind(depth)
					var lit := _sprite(deco_tex.ore[kind], pos, self, 1)
					var gl := _sprite(deco_tex.ore_glow[kind], pos, glow_root, 0)
					ores[Vector2i(gx, gy)] = [lit, gl, kind]
				elif m == M.DIRT and depth > 3 and rng.randf() < 0.0008:
					_add_decor(Vector2i(gx, gy), _sprite(deco_tex.skull, pos, self, 1))
				elif depth > 5 and get_fill(gx, gy - 1) < 0.5 and get_fill(gx, gy - 2) < 0.5 \
						and rng.randf() < 0.06:
					var mush := _sprite(deco_tex.mushroom, Vector2(pos.x, gy * CELL - 5), glow_root, 0)
					_add_decor(Vector2i(gx, gy), mush)
					if rng.randf() < 0.5:
						_add_decor(Vector2i(gx, gy), _light(Vector2(pos.x, gy * CELL - 8), Color("3fe0c0"), 0.55, 0.9))
			elif depth > 10 and get_fill(gx, gy - 1) >= 0.5 and rng.randf() < 0.035:
				var worm := _sprite(deco_tex.worm, Vector2(pos.x, gy * CELL + 10), glow_root, 0)
				_add_decor(Vector2i(gx, gy - 1), worm)
			if f < 0.5 or gx < 6 or gx >= W - 6:
				continue
			var surf := Vector2(gx * CELL + 4, gy * CELL)
			if get_fill(gx, gy - 1) < 0.5 and get_fill(gx, gy - 2) < 0.5:   # a floor
				_floor_props(Vector2i(gx, gy), surf, depth)
	_place_boulders(ch)
	# ceilings: an air cell right under rock
	for j in C:
		for i in C:
			var gx := ch.key.x * C + i
			var gy := ch.key.y * C + j
			if gx < 6 or gx >= W - 6 or gy < 3:
				continue
			if ch.fill[j * C + i] < 0.5 and get_fill(gx, gy - 1) >= 0.5 and get_fill(gx, gy + 1) < 0.5:
				_ceiling_props(Vector2i(gx, gy - 1), Vector2(gx * CELL + 4, gy * CELL), gy * CELL / METER)


## Loose boulders sit in small pockets inside dirt and stone (dig under one and it drops).
## Kept away from chunk edges so the pocket stays inside this chunk.
func _place_boulders(ch: Chunk) -> void:
	for j in range(3, C - 3):
		for i in range(3, C - 3):
			var gx := ch.key.x * C + i
			var gy := ch.key.y * C + j
			if gx < 8 or gx >= W - 8 or gy * CELL / METER < 8.0:
				continue
			if ch.fill[j * C + i] < 0.99 or ch.mat[j * C + i] == M.HARD or rng.randf() > 0.0012:
				continue
			var centre := Vector2(gx * CELL, gy * CELL)
			for dj in range(-2, 3):
				for di in range(-2, 3):
					var c := Vector2((gx + di) * CELL + 4, (gy + dj) * CELL + 4)
					if c.distance_to(centre) < Boulder.RADIUS + 3.0:
						ch.fill[(j + dj) * C + i + di] = 0.0
			var b := Boulder.new()
			b.world = self
			b.position = centre
			b.shattered.connect(boulder_shattered.emit)
			add_child(b)


## Deepest ore found at this depth, sometimes a cheaper one.
func _ore_kind(depth: float) -> int:
	var k := 0
	for i in METALS:
		if depth >= ORES[i][4]:
			k = i
	while k > 0 and rng.randf() < 0.45:
		k -= 1
	return k


func _floor_props(cell: Vector2i, p: Vector2, depth: float) -> void:
	var r := rng.randf()
	if depth > 4 and depth < 180 and r < 0.03:
		# mine support beam: needs a flat floor and a ceiling 8-11 cells up
		var h := 1
		while h < 13 and get_fill(cell.x, cell.y - h) < 0.5:
			h += 1
		var flat := true
		for dx in [-3, 3]:
			if get_fill(cell.x + dx, cell.y) < 0.5 or get_fill(cell.x + dx, cell.y - 1) >= 0.5:
				flat = false
		if flat and h >= 8 and h <= 11:
			_prop("beam", p + Vector2(0, 3), false, cell)
			return
	r = rng.randf()
	if depth > 50 and r < 0.014:
		var c := "crystal_p" if depth > 90 and rng.randf() < 0.7 else "crystal_t"
		_prop(c, p + Vector2(0, 3), false, cell, Color("b06cff") if c == "crystal_p" else Color("4ff0d0"))
	elif depth > 12 and r < 0.018:
		_prop("skeleton", p + Vector2(0, 2), false, cell)
	elif depth > 8 and depth < 200 and r < 0.021:
		_prop("cart", p + Vector2(0, 3), false, cell)
	elif depth > 5 and r < 0.025:
		_prop("crate", p + Vector2(0, 2), false, cell)


func _ceiling_props(cell: Vector2i, p: Vector2, depth: float) -> void:
	var r := rng.randf()
	if depth > 2 and depth < 45 and get_mat(cell.x, cell.y) == M.DIRT and r < 0.05:
		_prop("roots", p - Vector2(0, 3), true, cell)
	elif depth > 6 and depth < 150 and r < 0.058:
		var open := true
		for k in range(1, 6):
			if get_fill(cell.x, cell.y + k) >= 0.5:
				open = false
		if open:
			var l := _prop("lantern", p - Vector2(0, 2), true, cell, Color("ffb347"))
			flicker.append(l)
	elif depth > 30 and r < 0.064:
		_prop("chains", p - Vector2(0, 2), true, cell)
	elif depth > 70 and r < 0.072:
		var c := "crystal_p" if rng.randf() < 0.6 else "crystal_t"
		_prop(c, p - Vector2(0, 3), true, cell, Color("b06cff") if c == "crystal_p" else Color("4ff0d0"))


## Places a Blender prop. anchor_top: hangs from p (ceiling); else stands on p (floor).
## Returns the light if one was added.
func _prop(name: String, p: Vector2, anchor_top: bool, cell: Vector2i, light := Color(0, 0, 0, 0)) -> PointLight2D:
	var t: Array = props[name]
	var tex: Texture2D = t[0]
	var flip := rng.randf() < 0.5
	var off := Vector2(0, tex.get_height() / 2.0 * (1 if anchor_top else -1))
	for k in 2:
		if k == 1 and t[1] == null:
			continue
		var s := Sprite2D.new()
		s.texture = t[k]
		s.position = p
		s.offset = off
		s.flip_h = flip
		s.flip_v = anchor_top and name.begins_with("crystal")
		s.z_index = -1 if name == "beam" else 0
		var parent: Node = glow_root if k == 1 else self
		parent.add_child(s)
		_add_decor(cell, s)
	if light.a > 0:
		var l := _light(p + off, light, 0.9 if name == "lantern" else 0.7, 1.1)
		_add_decor(cell, l)
		return l
	return null


func _light(pos: Vector2, color: Color, scale: float, energy: float) -> PointLight2D:
	var l := PointLight2D.new()
	l.texture = deco_tex.light
	l.texture_scale = scale
	l.color = color
	l.energy = energy
	l.height = 40.0
	l.position = pos
	add_child(l)
	return l


func _sprite(t: Texture2D, pos: Vector2, parent: Node, z: int) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = t
	s.position = pos
	s.z_index = z
	s.flip_h = rng.randf() < 0.5
	parent.add_child(s)
	return s


func _add_decor(cell: Vector2i, n: Node2D) -> void:
	if not decor.has(cell):
		decor[cell] = []
	decor[cell].append(n)


# ---------------------------------------------------------------- queries

func get_fill(gx: int, gy: int) -> float:
	if gx < 0 or gx >= W:
		return 1.0
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	if ch == null:
		return 0.0 if (gy >> 5) < -2 else 1.0
	return ch.fill[(gy & 31) * C + (gx & 31)]


func get_dmg(gx: int, gy: int) -> float:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	return ch.dmg[(gy & 31) * C + (gx & 31)] if ch and gx >= 0 and gx < W else 0.0


func get_mat(gx: int, gy: int) -> int:
	if gx < 0 or gx >= W:
		return M.BEDROCK
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	if ch == null:
		return M.STONE
	return ch.mat[(gy & 31) * C + (gx & 31)]


func cell_at(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / CELL)), int(floor(p.y / CELL)))


func is_air(p: Vector2) -> bool:
	var c := cell_at(p)
	return get_fill(c.x, c.y) < 0.5


func is_bedrock(p: Vector2) -> bool:
	var c := cell_at(p)
	return get_mat(c.x, c.y) == M.BEDROCK


func mat_at(p: Vector2) -> int:
	var c := cell_at(p)
	return get_mat(c.x, c.y)


func is_diggable(p: Vector2) -> bool:
	return not is_air(p) and not is_bedrock(p)


# ---------------------------------------------------------------- digging

## One pickaxe hit on a capsule (segment a-b, radius r): damages rock, strongest at the
## centre, and breaks cells whose damage is enough. Already-open cells get cleaned up too.
## Returns {hit: touched rock, mat: its material, broke: cells broken, points: where they broke}.
## collect = false grinds up any ore it breaks (the drill's head) instead of handing it out.
func dig(a: Vector2, b: Vector2, r: float, amount: float, collect := true) -> Dictionary:
	_collect = collect
	var lo := cell_at(Vector2(minf(a.x, b.x) - r, minf(a.y, b.y) - r))
	var hi := cell_at(Vector2(maxf(a.x, b.x) + r, maxf(a.y, b.y) + r))
	var hit := false
	var hit_mat := -1
	var broke := 0
	var points := []
	for gy in range(lo.y, hi.y + 1):
		for gx in range(lo.x, hi.x + 1):
			var p := Vector2(gx * CELL + 4, gy * CELL + 4)
			var dist := Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p)
			if dist > r:
				continue
			var f := get_fill(gx, gy)
			if f <= 0.0:
				continue
			var m := get_mat(gx, gy)
			if m == M.BEDROCK:
				continue
			var d: float = get_dmg(gx, gy) + amount * (1.0 - 0.6 * dist / r) / HARDNESS[m]
			if f >= 0.5:
				hit = true
				hit_mat = m
			if f - d < 0.5:
				if f >= 0.5:
					broke += 1
					points.append(Vector2(gx * CELL + 4, gy * CELL + 4))
				_set_fill(gx, gy, maxf(0.0, f - d), f)
			else:
				_set_dmg(gx, gy, d)
	return {"hit": hit, "mat": hit_mat, "broke": broke, "points": points}


func _set_fill(gx: int, gy: int, nf: float, old: float) -> void:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	if ch == null:
		return
	ch.fill[(gy & 31) * C + (gx & 31)] = nf
	ch.dmg[(gy & 31) * C + (gx & 31)] = 0.0
	_set_pixel(gx, gy, nf, 0.0)
	if old >= 0.5 and nf < 0.5:
		var cell := Vector2i(gx, gy)
		dug[cell] = true
		for kx in _keys_covering(gx, R_INT + 1):
			for ky in _keys_covering(gy, R_INT + 1):
				var o: Chunk = chunks.get(Vector2i(kx, ky))
				if o:
					o.int_dirty = true
		for k in [Vector2i(gx, gy), Vector2i(gx - 1, gy), Vector2i(gx, gy - 1), Vector2i(gx - 1, gy - 1)]:
			var o: Chunk = chunks.get(Vector2i(k.x >> 5, k.y >> 5))
			if o:
				o.col_dirty = true
		if ores.has(cell):
			var o: Array = ores[cell]
			o[0].queue_free()
			o[1].queue_free()
			ores.erase(cell)
			if _collect:
				ore_found.emit(Vector2(gx * CELL + 4, gy * CELL + 4), o[2])
		if decor.has(cell):
			for n in decor[cell]:
				n.queue_free()
			decor.erase(cell)


func _set_dmg(gx: int, gy: int, d: float) -> void:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	if ch == null:
		return
	ch.dmg[(gy & 31) * C + (gx & 31)] = d
	_set_pixel(gx, gy, ch.fill[(gy & 31) * C + (gx & 31)], d)


## Updates the fill (R) and crack (B) pixel in every chunk image whose 1-cell margin covers it.
func _set_pixel(gx: int, gy: int, fill: float, d: float) -> void:
	for kx in _keys_covering(gx, 1):
		for ky in _keys_covering(gy, 1):
			var o: Chunk = chunks.get(Vector2i(kx, ky))
			if o and o.img:
				var li: int = gx - kx * C + 1
				var lj: int = gy - ky * C + 1
				var px := o.img.get_pixel(li, lj)
				px.r = fill
				px.b = _crack(fill, d)
				o.img.set_pixel(li, lj, px)
				o.vis_dirty = true


## How cracked a cell looks: 0 = untouched, 1 = about to break.
static func _crack(fill: float, d: float) -> float:
	return clampf(d / maxf(fill - 0.5, 0.01), 0.0, 1.0) if d > 0.0 else 0.0


## Chunk indices whose window [-margin, C-1+margin] contains global cell g.
func _keys_covering(g: int, margin: int) -> Array:
	var out := []
	for k in range((g - C + 1 - margin) >> 5, ((g + margin) >> 5) + 1):
		var l := g - k * C
		if l >= -margin and l < C + margin:
			out.append(k)
	return out


func _process(dt: float) -> void:
	_flush()
	time += dt
	for i in range(flicker.size() - 1, -1, -1):
		var l = flicker[i]
		if not is_instance_valid(l):
			flicker.remove_at(i)
			continue
		var ph := float(l.get_instance_id() % 97)
		l.energy = 1.1 * (0.85 + 0.15 * sin(time * 9.0 + ph) * sin(time * 5.3 + ph * 0.7))


func _flush() -> void:
	for ch: Chunk in chunks.values():
		if ch.int_dirty:
			_build_images(ch)
			ch.int_dirty = false
			ch.vis_dirty = false
		elif ch.vis_dirty:
			ch.tex_fill.update(ch.img)
			ch.vis_dirty = false
		if ch.col_dirty:
			_build_collision(ch)
			ch.col_dirty = false


func _build_images(ch: Chunk) -> void:
	var n := C + 2
	var ext := n + 2 * R_INT
	var ox := ch.key.x * C - 1 - R_INT
	var oy := ch.key.y * C - 1 - R_INT
	# distance (in cells) to the nearest air, two-pass chamfer
	var dist := PackedFloat32Array()
	dist.resize(ext * ext)
	for j in ext:
		for i in ext:
			dist[j * ext + i] = 0.0 if get_fill(ox + i, oy + j) < 0.5 else 99.0
	for j in ext:
		for i in ext:
			var k := j * ext + i
			var d := dist[k]
			if d == 0.0:
				continue
			if i > 0: d = minf(d, dist[k - 1] + 1.0)
			if j > 0:
				d = minf(d, dist[k - ext] + 1.0)
				if i > 0: d = minf(d, dist[k - ext - 1] + 1.41)
				if i < ext - 1: d = minf(d, dist[k - ext + 1] + 1.41)
			dist[k] = d
	for j in range(ext - 1, -1, -1):
		for i in range(ext - 1, -1, -1):
			var k := j * ext + i
			var d := dist[k]
			if d == 0.0:
				continue
			if i < ext - 1: d = minf(d, dist[k + 1] + 1.0)
			if j < ext - 1:
				d = minf(d, dist[k + ext] + 1.0)
				if i < ext - 1: d = minf(d, dist[k + ext + 1] + 1.41)
				if i > 0: d = minf(d, dist[k + ext - 1] + 1.41)
			dist[k] = d
	var data := PackedByteArray()
	data.resize(n * n * 4)
	var mdata := PackedByteArray()
	mdata.resize(n * n * 4)
	for j in n:
		for i in n:
			var gx := ch.key.x * C - 1 + i
			var gy := ch.key.y * C - 1 + j
			var k := (j * n + i) * 4
			data[k] = int(clampf(get_fill(gx, gy), 0.0, 1.0) * 255.0)
			data[k + 1] = int(clampf((dist[(j + R_INT) * ext + i + R_INT] - 1.0) / R_INT, 0.0, 1.0) * 255.0)
			data[k + 2] = int(_crack(get_fill(gx, gy), get_dmg(gx, gy)) * 255.0)
			data[k + 3] = 255
			mdata[k + get_mat(gx, gy)] = 255
	ch.img = Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, data)
	var mimg := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, mdata)
	if ch.tex_fill == null:
		ch.tex_fill = ImageTexture.create_from_image(ch.img)
		ch.tex_mat = ImageTexture.create_from_image(mimg)
		ch.rect.material.set_shader_parameter("fill_map", ch.tex_fill)
		ch.rect.material.set_shader_parameter("mat_map", ch.tex_mat)
	else:
		ch.tex_fill.update(ch.img)
		ch.tex_mat.update(mimg)


func _build_collision(ch: Chunk) -> void:
	var bx := ch.key.x * C
	var by := ch.key.y * C
	var s := C + 1
	var f := PackedFloat32Array()
	f.resize(s * s)
	for j in s:
		for i in s:
			f[j * s + i] = get_fill(bx + i, by + j)
	var segs := PackedVector2Array()
	for j in C:
		for i in C:
			var a := f[j * s + i]
			var b := f[j * s + i + 1]
			var c := f[(j + 1) * s + i + 1]
			var d := f[(j + 1) * s + i]
			var idx := (8 if a >= 0.5 else 0) | (4 if b >= 0.5 else 0) | (2 if c >= 0.5 else 0) | (1 if d >= 0.5 else 0)
			if idx == 0 or idx == 15:
				continue
			var p := Vector2(i * CELL + CELL * 0.5, j * CELL + CELL * 0.5)
			var top := p + Vector2(_t(a, b) * CELL, 0)
			var right := p + Vector2(CELL, _t(b, c) * CELL)
			var bottom := p + Vector2(_t(d, c) * CELL, CELL)
			var left := p + Vector2(0, _t(a, d) * CELL)
			match idx:
				1, 14: segs.append_array([left, bottom])
				2, 13: segs.append_array([bottom, right])
				3, 12: segs.append_array([left, right])
				4, 11: segs.append_array([top, right])
				6, 9: segs.append_array([top, bottom])
				7, 8: segs.append_array([left, top])
				5: segs.append_array([left, top, bottom, right])
				10: segs.append_array([top, right, left, bottom])
	ch.shape.segments = segs


func _t(a: float, b: float) -> float:
	return 0.5 if is_equal_approx(a, b) else clampf((0.5 - a) / (b - a), 0.0, 1.0)


# ---------------------------------------------------------------- decor art (placeholder until Blender props)

func _make_decor_textures() -> void:
	var lg := Gradient.new()
	lg.set_color(0, Color(1, 1, 1, 1))
	lg.set_color(1, Color(1, 1, 1, 0))
	lg.add_point(0.4, Color(1, 1, 1, 0.35))
	var lt := GradientTexture2D.new()
	lt.gradient = lg
	lt.fill = GradientTexture2D.FILL_RADIAL
	lt.fill_from = Vector2(0.5, 0.5)
	lt.fill_to = Vector2(1.0, 0.5)
	lt.width = 256
	lt.height = 256
	deco_tex.light = lt
	# ore: nuggets in the rock (lit) + just the shiny bits (glow), one pair per ore kind
	deco_tex.ore = []
	deco_tex.ore_glow = []
	for kind in ORES:
		var nug: Color = kind[2]
		var shine: Color = kind[3]
		var ore := Image.create(14, 12, false, Image.FORMAT_RGBA8)
		var ore_g := Image.create(14, 12, false, Image.FORMAT_RGBA8)
		var r := RandomNumberGenerator.new()
		r.seed = 3
		for k in 7:
			var x := 2 + r.randi() % 9
			var y := 2 + r.randi() % 7
			for p in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
				ore.set_pixelv(Vector2i(x, y) + p, nug.darkened(0.25 if p.y == 1 else 0.0))
				ore_g.set_pixelv(Vector2i(x, y) + p, shine if p == Vector2i.ZERO else nug.darkened(0.3))
			ore.set_pixel(x + 2, y + 1, Color("3a2a14"))
		deco_tex.ore.append(ImageTexture.create_from_image(ore))
		deco_tex.ore_glow.append(ImageTexture.create_from_image(ore_g))
	# glowing mushrooms
	var mu := Image.create(18, 12, false, Image.FORMAT_RGBA8)
	for m in [[4, 6], [9, 9], [14, 4]]:
		var x: int = m[0]
		var hgt: int = m[1]
		for k in hgt:
			mu.set_pixel(x, 11 - k, Color("a9d6cb"))
		var top := 11 - hgt
		for dx in range(-2, 3):
			mu.set_pixel(clampi(x + dx, 0, 17), top, Color("2fb8a0"))
		for dx in range(-1, 2):
			mu.set_pixel(clampi(x + dx, 0, 17), top - 1, Color("6ff4da"))
	deco_tex.mushroom = ImageTexture.create_from_image(mu)
	# glow-worm threads hanging from a ceiling
	var wo := Image.create(14, 22, false, Image.FORMAT_RGBA8)
	for w in [[2, 14], [5, 8], [8, 19], [12, 11]]:
		for k in w[1]:
			wo.set_pixel(w[0], k, Color(0.35, 0.65, 0.72, 0.5))
		wo.set_pixel(w[0], w[1], Color("c0fcff"))
		wo.set_pixel(w[0], w[1] - 1, Color("7fe6f0"))
	deco_tex.worm = ImageTexture.create_from_image(wo)
	# buried skull
	var sk := Image.create(10, 9, false, Image.FORMAT_RGBA8)
	var rows := ["..xxxxx...", ".xxxxxxx..", "xxxxxxxxx.", "xooxxxoox.", "xooxxxoox.",
		"xxxxoxxxx.", ".xxxxxxx..", "..x.x.x...", ".........."]
	for y in rows.size():
		for x in rows[y].length():
			var ch: String = rows[y][x]
			if ch == "x":
				sk.set_pixel(x, y, Color("cfc6ae").darkened(0.1 * float(y) / 8.0))
			elif ch == "o":
				sk.set_pixel(x, y, Color("120b08"))
	deco_tex.skull = ImageTexture.create_from_image(sk)
