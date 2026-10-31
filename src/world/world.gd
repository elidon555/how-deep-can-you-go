extends Node2D
class_name World
## Endless smooth diggable ground. Under the hood: a fine grid of "fill" values
## (8 px cells, 1 = solid rock, 0 = air). The terrain shader draws the 0.5
## contour as smooth organic rock; collision uses the same contour (marching squares).
## Pickaxe hits add "damage" (drawn as cracks); a cell breaks once fill - damage < 0.5.
## Generated in 32x32-cell chunks as the player goes down. 24 px = 1 meter.

signal ore_found(pos: Vector2, kind: int)   # kind: index into ORES
signal boulder_shattered(pos: Vector2)
signal opened(gx: int, gy: int)          # a cell just became open (dug out): liquids may flow in
signal gas_released(pos: Vector2)        # a firedamp cell was dug open
signal ore_ground(pos: Vector2, kind: int)   # ore broken without being collected (the drill's head)

const CELL := 8
const METER := 24.0
const W := 128                  # cells across (outer 2 columns are bedrock)
const C := 32                   # chunk size in cells (code uses >>5 / &31)
const CHUNK_PX := C * CELL
const WIDTH_PX := W * CELL
const R_INT := 5                # how far (cells) the "deep inside rock" darkening reaches
enum M { DIRT, STONE, HARD, BEDROCK, CRYSTAL, MAGMA, FLOOR, ICE }
const HARDNESS := [1.0, 2.6, 5.5, INF, 3.8, 6.5, INF, 2.2]
const COLORS := [Color("5a3c27"), Color("566275"), Color("3d3350"), Color("1d1924"), Color("7a58b0"), Color("3a2420"),
	Color("1c1f2a"), Color("8fc8e0")]
const MAT_NAMES := ["dirt", "stone", "hard", "bedrock", "crystal", "magma", "floor", "ice"]
# Depth layers (m). Their boundaries wander with noise, so every world is different.
const FUNGAL_FROM := 60.0       # the fungal caves: bigger caves, glowing mushrooms, mite swarms
const FUNGAL_TO := 140.0
const CRYSTAL_FROM := 150.0     # the crystal caverns
const CRYSTAL_TO := 300.0       # then the ice layer (slippery), down to the magma
const MAGMA_FROM := 400.0       # the magma layer
const CAVERN_FROM := 585.0      # the vast cavern above the bottom
const BOTTOM := 620.0           # the Floor: carved, glowing, unbreakable. Something lives below.
const LAYER_WOBBLE := 30.0      # how far (m) a boundary drifts up/down across the world
# name, value, nugget colour, glow colour, found from depth (m). Metals sell; coal is drill fuel.
const ORES := [
	["copper", 1, Color("d9824a"), Color("ff9c5a"), 0.0],
	["silver", 3, Color("c9d3e0"), Color("e8f2ff"), 40.0],
	["gold", 8, Color("f2c14e"), Color("ffd36a"), 110.0],
	["amethyst", 15, Color("b07ae8"), Color("e2b8ff"), 150.0],
	["coal", 0, Color("26252b"), Color("9aa0ab"), 0.0],
]
const METALS := 4      # ORES[0..3] sell; the rest are fuel
const COAL := 4

class Chunk:
	var key: Vector2i
	var fill := PackedFloat32Array()
	var mat := PackedByteArray()
	var dmg := PackedFloat32Array()   # pickaxe damage not yet enough to break the cell
	var img: Image
	var tex_fill: ImageTexture
	var tex_mat: ImageTexture
	var tex_mat2: ImageTexture        # second material map: crystal, magma
	var glows := false                # has crystal / magma, gets a glow pass
	var glow_rect: ColorRect
	var liquid := PackedFloat32Array()   # 0..1 per cell (see Liquids)
	var ltype := PackedByteArray()       # Liquids.NONE / WATER / LAVA
	var has_liquid := false
	var liq_tex: ImageTexture          # liquid map for the liquid shaders (Liquids draws it)
	var liq_rects: Array = []
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
var gas := {}                   # cells of rock with firedamp trapped in them
var _collect := true            # set per dig(): does broken ore get handed out?
static var fixed_seed := -1     # tests / the Daily Dig set this for a known world
var seed := 0                   # this world's seed (shown in the pause menu)
var glow_root := Node2D.new()   # main moves this onto the unlit glow layer
var terrain_shader: Shader = preload("res://src/world/terrain.gdshader")
var tx := {}
var glow_tx := {}
var terrain_glow_shader: Shader = preload("res://src/world/terrain_glow.gdshader")
var liquids: Liquids             # set by main; told when a chunk's liquid changes
var gen: WorldGen               # makes the chunks (world_gen.gd)
# online co-op (NetWorld): the host records what changes; a client shows the host's ground
var record := false             # host: note every changed cell in `changes` / `touched`
var changes := {}               # cells changed since NetWorld last sent them
var touched := {}               # chunk keys changed since the run began (for late joiners)
var puppet := false             # client: generated the same, but only the host changes it
                                # (no ore, gas or caving in here; entities come from the host)


func _ready() -> void:
	for n in MAT_NAMES:
		var f: String = n if ResourceLoader.exists("res://assets/terrain/%s.png" % n) else "hard"   # art not made yet
		var key: String = "bed" if n == "bedrock" else n                                          # shader names
		tx["t_" + key] = load("res://assets/terrain/%s.png" % f)
		tx["n_" + key] = load("res://assets/terrain/%s_n.png" % f)
	for n in ["crystal", "magma", "floor", "ice"]:
		var g := "res://assets/terrain/%s_glow.png" % n
		glow_tx["g_" + n] = load(g) if ResourceLoader.exists(g) else null
	gen = WorldGen.new(self)
	ensure_generated(CHUNK_PX * 4)


# ---------------------------------------------------------------- generation

func ensure_generated(y_px: float) -> void:
	var want := int(floor(y_px / CHUNK_PX)) + 1
	while next_row <= want:
		for cx in W / C:
			_gen_chunk(Vector2i(cx, next_row))
		for cx in W / C:
			gen.populate(chunks[Vector2i(cx, next_row)])
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
	ch.liquid.resize(C * C)
	ch.ltype.resize(C * C)
	for j in C:
		for i in C:
			var v := gen.cell(key.x * C + i, key.y * C + j)
			ch.fill[j * C + i] = v.x
			ch.mat[j * C + i] = int(v.y)
			if int(v.y) >= M.CRYSTAL:      # crystal, magma, the Floor, ice: they glow
				ch.glows = true
	gen.liquid_pockets(ch)
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
	if ch.glows:      # crystals and hot cracks glow: same shape, drawn again on the bloom layer
		var g := ColorRect.new()
		g.position = ch.rect.position
		g.size = ch.rect.size
		g.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var gm := ShaderMaterial.new()
		gm.shader = terrain_glow_shader
		for k in glow_tx:
			gm.set_shader_parameter(k, glow_tx[k])
		gm.set_shader_parameter("origin", ch.rect.position)
		g.material = gm
		glow_root.add_child(g)
		ch.glow_rect = g
	var body := StaticBody2D.new()
	body.position = ch.rect.position
	var cs := CollisionShape2D.new()
	ch.shape = ConcavePolygonShape2D.new()
	cs.shape = ch.shape
	body.add_child(cs)
	add_child(body)
	chunks[key] = ch


## Something generated into the world that the host owns online (boulders, crates, notes).
## On a client it's made (the generator's dice roll the same) but dropped: the host's copy is
## shown instead (NetEntities).
func add_entity(n: Node2D) -> bool:
	if puppet:
		n.free()
		return false
	add_child(n)
	return true


func add_decor(cell: Vector2i, n: Node2D) -> void:
	if not decor.has(cell):
		decor[cell] = []
	decor[cell].append(n)


# ---------------------------------------------------------------- queries

func get_liquid(gx: int, gy: int) -> float:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	return ch.liquid[(gy & 31) * C + (gx & 31)] if ch and gx >= 0 and gx < W else 0.0


func get_ltype(gx: int, gy: int) -> int:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	return ch.ltype[(gy & 31) * C + (gx & 31)] if ch and gx >= 0 and gx < W else Liquids.NONE


func set_liquid(gx: int, gy: int, amount: float, kind: int) -> void:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	if ch == null or gx < 0 or gx >= W:
		return
	var k := (gy & 31) * C + (gx & 31)
	if amount <= Liquids.MIN:
		amount = 0.0
		kind = Liquids.NONE
	ch.liquid[k] = amount
	ch.ltype[k] = kind
	if amount > 0.0:
		ch.has_liquid = true
	if liquids:
		liquids.cell_changed(gx, gy)
	if record:
		_note_change(gx, gy)


## Liquid at a world point: Vector2(amount, kind).
func liquid_at(p: Vector2) -> Vector2:
	var c := cell_at(p)
	return Vector2(get_liquid(c.x, c.y), get_ltype(c.x, c.y))


## Water meeting lava: a cell turns to solid rock.
func place_rock(gx: int, gy: int, mat: int) -> void:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	if ch == null:
		return
	var k := (gy & 31) * C + (gx & 31)
	ch.fill[k] = 1.0
	ch.mat[k] = mat
	ch.dmg[k] = 0.0
	ch.liquid[k] = 0.0
	ch.ltype[k] = Liquids.NONE
	_closed(gx, gy)
	if record:
		_note_change(gx, gy)


## A cell turned solid: redraw (depth darkening) and rebuild collision around it.
func _closed(gx: int, gy: int) -> void:
	for kx in _keys_covering(gx, R_INT + 1):
		for ky in _keys_covering(gy, R_INT + 1):
			var o: Chunk = chunks.get(Vector2i(kx, ky))
			if o:
				o.int_dirty = true
				o.col_dirty = true


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
			if HARDNESS[m] == INF:          # bedrock, the Floor
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
	if record:
		_note_change(gx, gy)
	if old >= 0.5 and nf < 0.5:
		if not puppet:
			opened.emit(gx, gy)
		if gas.has(Vector2i(gx, gy)):
			gas.erase(Vector2i(gx, gy))
			if not puppet:
				gas_released.emit(Vector2(gx * CELL + 4, gy * CELL + 4))
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
			if not puppet:
				if _collect:
					ore_found.emit(Vector2(gx * CELL + 4, gy * CELL + 4), o[2])
				else:
					ore_ground.emit(Vector2(gx * CELL + 4, gy * CELL + 4), o[2])
		if decor.has(cell):
			for n in decor[cell]:
				if is_instance_valid(n):      # (a note may already have been picked up)
					n.queue_free()
			decor.erase(cell)


func _set_dmg(gx: int, gy: int, d: float) -> void:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	if ch == null:
		return
	ch.dmg[(gy & 31) * C + (gx & 31)] = d
	_set_pixel(gx, gy, ch.fill[(gy & 31) * C + (gx & 31)], d)
	if record:
		_note_change(gx, gy)


func _note_change(gx: int, gy: int) -> void:
	changes[Vector2i(gx, gy)] = true
	touched[Vector2i(gx >> 5, gy >> 5)] = true


## Client: a cell as the host has it now (NetWorld). Ore and props in a cell that opens go,
## like when it's dug here.
func net_set_cell(gx: int, gy: int, fill: float, dmg: float, mat: int, liquid: float, ltype: int) -> void:
	var ch: Chunk = chunks.get(Vector2i(gx >> 5, gy >> 5))
	if ch == null or gx < 0 or gx >= W:
		return
	var k := (gy & 31) * C + (gx & 31)
	var old := ch.fill[k]
	if ch.mat[k] != mat:
		ch.mat[k] = mat
		_closed(gx, gy)           # (a material change redraws the same way)
	if absf(old - fill) > 0.0001 or absf(ch.dmg[k] - dmg) > 0.003:
		_set_fill(gx, gy, fill, old)
		if fill >= 0.5 and old < 0.5:
			_closed(gx, gy)
		if dmg > 0.0:
			_set_dmg(gx, gy, dmg)
	if absf(ch.liquid[k] - liquid) > 0.003 or ch.ltype[k] != ltype:
		set_liquid(gx, gy, liquid, ltype)


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
	gen.update(dt)


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
	var mdata := PackedByteArray()      # one-hot dirt, stone, hard, bedrock
	mdata.resize(n * n * 4)
	var mdata2 := PackedByteArray()     # one-hot crystal, magma
	mdata2.resize(n * n * 4)
	for j in n:
		for i in n:
			var gx := ch.key.x * C - 1 + i
			var gy := ch.key.y * C - 1 + j
			var k := (j * n + i) * 4
			data[k] = int(clampf(get_fill(gx, gy), 0.0, 1.0) * 255.0)
			data[k + 1] = int(clampf((dist[(j + R_INT) * ext + i + R_INT] - 1.0) / R_INT, 0.0, 1.0) * 255.0)
			data[k + 2] = int(_crack(get_fill(gx, gy), get_dmg(gx, gy)) * 255.0)
			data[k + 3] = 255
			var mt := get_mat(gx, gy)
			if mt < M.CRYSTAL:
				mdata[k + mt] = 255
			else:
				mdata2[k + mt - M.CRYSTAL] = 255
	ch.img = Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, data)
	var mimg := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, mdata)
	var mimg2 := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, mdata2)
	if ch.tex_fill == null:
		ch.tex_fill = ImageTexture.create_from_image(ch.img)
		ch.tex_mat = ImageTexture.create_from_image(mimg)
		ch.tex_mat2 = ImageTexture.create_from_image(mimg2)
		for r in [ch.rect, ch.glow_rect]:
			if r:
				r.material.set_shader_parameter("fill_map", ch.tex_fill)
				r.material.set_shader_parameter("mat_map", ch.tex_mat)
				r.material.set_shader_parameter("mat_map2", ch.tex_mat2)
	else:
		ch.tex_fill.update(ch.img)
		ch.tex_mat.update(mimg)
		ch.tex_mat2.update(mimg2)


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
