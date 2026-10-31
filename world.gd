extends TileMapLayer
class_name World
## Endless diggable ground, generated in chunks as the player goes down.
## 1 tile = 1 meter. Row 0 is the surface.
## Art is generated procedurally: every tile type has variants x 16 edge shapes
## (which sides touch air), so terrain gets outlines, lit lips and dark interiors.

signal tile_broken(cell: Vector2i, type: int)

const TILE := 16
const WIDTH := 48          # tiles across (outer columns are unbreakable walls)
const CHUNK := 32          # rows generated at a time
const AHEAD := 80          # keep this many rows generated below the player
const VARIANTS := 3

enum T { DIRT, STONE, HARD, ORE, BEDROCK, GRASS, FOSSIL }
enum G { ORE, MUSHROOM, WORM }   # rows of the glow (unlit, bloomed) layer

const HP := {T.DIRT: 1.0, T.GRASS: 1.0, T.FOSSIL: 1.5, T.STONE: 2.5, T.HARD: 5.5,
	T.ORE: 2.0, T.BEDROCK: INF}
const COLORS := {   # particle colours
	T.DIRT: Color("5a3a26"), T.GRASS: Color("4a6b34"), T.FOSSIL: Color("d8cfb8"),
	T.STONE: Color("56606e"), T.HARD: Color("3a3247"), T.ORE: Color("f2c14e"),
	T.BEDROCK: Color("15131a"),
}
const PAL := {   # dark, mid, light, accent
	"dirt": [Color("2e1d13"), Color("4a3120"), Color("654431"), Color("805c41")],
	"stone": [Color("232834"), Color("404a5a"), Color("586577"), Color("78879c")],
	"hard": [Color("18131f"), Color("2d263a"), Color("3f3552"), Color("594c6f")],
	"bedrock": [Color("07060a"), Color("100e15"), Color("17141e"), Color("201c2a")],
	"wall": [Color("1c1511"), Color("281f19"), Color("33281f"), Color("403228")],
}
const OUTLINE := Color("09070b")
const UP := Vector2i(0, -1)
const DOWN := Vector2i(0, 1)

var types := {}            # Vector2i -> T
var dug := {}              # cells the player dug out (not natural caves)
var damage := {}           # Vector2i -> damage dealt so far
var generated_rows := 0
var glow := TileMapLayer.new()   # glowing decor; main puts it on an unlit layer
var noise_cave := FastNoiseLite.new()
var noise_mat := FastNoiseLite.new()
var rng := RandomNumberGenerator.new()
var cracks := Node2D.new()
var ore_specks := []       # per variant: Array[Vector2i]


func _ready() -> void:
	var r := RandomNumberGenerator.new()
	r.seed = 99
	for v in VARIANTS:
		var s := []
		for k in 4 + v:
			s.append(Vector2i(2 + r.randi() % 11, 2 + r.randi() % 11))
		ore_specks.append(s)
	tile_set = _make_tileset()
	glow.tile_set = _make_glow_tileset()
	glow.modulate = Color(1.7, 1.7, 1.7)   # >1 = blooms with HDR glow

	rng.randomize()
	noise_cave.seed = rng.randi()
	noise_cave.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_cave.frequency = 0.07
	noise_mat.seed = rng.randi()
	noise_mat.frequency = 0.05
	# side walls above the surface so you can't walk off the world
	for y in range(-30, 0):
		types[Vector2i(0, y)] = T.BEDROCK
		types[Vector2i(WIDTH - 1, y)] = T.BEDROCK
	for y in range(-30, 0):
		_refresh(Vector2i(0, y))
		_refresh(Vector2i(WIDTH - 1, y))
	ensure_generated(AHEAD)
	cracks.z_index = 1
	add_child(cracks)
	cracks.draw.connect(_draw_cracks)


# ---------------------------------------------------------------- generation

func ensure_generated(row: int) -> void:
	while generated_rows < row:
		var g := generated_rows
		for y in range(g, g + CHUNK):
			_gen_row(y)
		generated_rows += CHUNK
		for y in range(maxi(g - 1, 0), g + CHUNK):
			for x in WIDTH:
				_refresh(Vector2i(x, y))
		_decorate(g)


func _gen_row(y: int) -> void:
	for x in WIDTH:
		var c := Vector2i(x, y)
		if x == 0 or x == WIDTH - 1:
			types[c] = T.BEDROCK
			continue
		if y == 0:
			types[c] = T.GRASS
			continue
		var depth := float(y)
		# caves start a bit below the surface and get bigger deeper
		if y > 8 and noise_cave.get_noise_2d(x, y) > 0.5 - minf(depth / 500.0, 0.15):
			continue
		var m := noise_mat.get_noise_2d(x, y) * 0.5 + 0.5
		var t := T.DIRT
		if m < clampf((depth - 5.0) / 120.0, 0.0, 0.85):
			t = T.STONE
		if m < clampf((depth - 60.0) / 250.0, 0.0, 0.7):
			t = T.HARD
		if t != T.DIRT and rng.randf() < 0.035:
			t = T.ORE
		if t == T.DIRT and y > 6 and rng.randf() < 0.012:
			t = T.FOSSIL
		types[c] = t


func _decorate(g: int) -> void:
	for y in range(maxi(g, 2), g + CHUNK):
		for x in range(1, WIDTH - 1):
			var c := Vector2i(x, y)
			var solid := types.has(c)
			var above := types.has(c + UP)
			if solid and types[c] == T.ORE:
				glow.set_cell(c, 0, Vector2i(_variant(c), G.ORE))
			elif solid and not above and y > 10 and rng.randf() < 0.14:
				glow.set_cell(c + UP, 0, Vector2i(_variant(c), G.MUSHROOM))   # on cave floors
			elif not solid and above and y > 25 and rng.randf() < 0.10:
				glow.set_cell(c, 0, Vector2i(_variant(c), G.WORM))            # hanging from ceilings


func _variant(c: Vector2i) -> int:
	return absi((c.x * 73856093) ^ (c.y * 19349663)) % VARIANTS


func is_solid(c: Vector2i) -> bool:
	if c.x < 0 or c.x >= WIDTH or c.y >= generated_rows:
		return true
	return types.has(c)


func _refresh(c: Vector2i) -> void:
	if not types.has(c):
		erase_cell(c)
		return
	var mask := 0
	if not is_solid(c + UP): mask |= 1
	if not is_solid(c + Vector2i(1, 0)): mask |= 2
	if not is_solid(c + DOWN): mask |= 4
	if not is_solid(c + Vector2i(-1, 0)): mask |= 8
	set_cell(c, 0, Vector2i(mask + 16 * _variant(c), types[c]))


func get_type(cell: Vector2i) -> int:
	return types.get(cell, -1)


## Adds dig damage to a tile. Returns true if the tile broke.
func dig(cell: Vector2i, amount: float) -> bool:
	var t := get_type(cell)
	if t == -1 or t == T.BEDROCK:
		return false
	damage[cell] = damage.get(cell, 0.0) + amount
	cracks.queue_redraw()
	if damage[cell] >= HP[t]:
		damage.erase(cell)
		types.erase(cell)
		dug[cell] = true
		_refresh(cell)
		for d in [UP, DOWN, Vector2i(1, 0), Vector2i(-1, 0)]:
			_refresh(cell + d)
		glow.erase_cell(cell)
		if glow.get_cell_atlas_coords(cell + UP).y == G.MUSHROOM:
			glow.erase_cell(cell + UP)
		if glow.get_cell_atlas_coords(cell + DOWN).y == G.WORM:
			glow.erase_cell(cell + DOWN)
		tile_broken.emit(cell, t)
		return true
	return false


func _draw_cracks() -> void:
	for cell in damage:
		var t := get_type(cell)
		if t == -1:
			continue
		var p: float = clampf(damage[cell] / HP[t], 0.0, 1.0)
		var o := Vector2(cell * TILE)
		var col := Color(0, 0, 0, 0.45 + 0.4 * p)
		var lines := [
			[Vector2(8, 8), Vector2(3, 2)], [Vector2(8, 8), Vector2(14, 5)],
			[Vector2(8, 8), Vector2(5, 14)], [Vector2(8, 8), Vector2(13, 13)],
			[Vector2(3, 2), Vector2(1, 7)], [Vector2(14, 5), Vector2(15, 1)],
		]
		for i in int(ceil(p * lines.size())):
			cracks.draw_line(o + lines[i][0], o + lines[i][1], col, 1.0)


# ---------------------------------------------------------------- tile art

func _make_tileset() -> TileSet:
	var cols := 16 * VARIANTS
	var img := Image.create(TILE * cols, TILE * T.size(), false, Image.FORMAT_RGBA8)
	for t in T.size():
		for v in VARIANTS:
			var base := _base_pattern(t, v)
			for mask in 16:
				_paint(img, mask + 16 * v, t, t, v, mask, base)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_physics_layer()
	var src := TileSetAtlasSource.new()
	src.texture = make_lit_texture(img)
	src.texture_region_size = Vector2i(TILE, TILE)
	ts.add_source(src, 0)
	var h := TILE / 2.0
	var poly := PackedVector2Array([Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)])
	for t in T.size():
		for x in cols:
			src.create_tile(Vector2i(x, t))
			var td := src.get_tile_data(Vector2i(x, t), 0)
			td.add_collision_polygon(0)
			td.set_collision_polygon_points(0, 0, poly)
	return ts


## Base texture of a tile type+variant (shared by all 16 edge shapes so digging
## next to a tile doesn't change its look).
func _base_pattern(t: int, v: int) -> PackedColorArray:
	var r := RandomNumberGenerator.new()
	r.seed = t * 1000 + v * 17 + 5
	var px := PackedColorArray()
	px.resize(TILE * TILE)
	match t:
		T.DIRT, T.GRASS, T.FOSSIL:
			_dirt(px, r, PAL.dirt, v)
		T.STONE, T.ORE:
			_rocks(px, r, PAL.stone, 5)
		T.HARD:
			_rocks(px, r, PAL.hard, 7)
			_walk(px, r, Color("4d1f2e"), r.randi() % TILE, 0, 14)   # dark red veins
		T.BEDROCK:
			_rocks(px, r, PAL.bedrock, 6)
	if t == T.ORE:
		for s in ore_specks[v]:
			_px(px, s.x, s.y, Color("f2c14e"))
			_px(px, s.x + 1, s.y, Color("c9922f"))
			_px(px, s.x, s.y + 1, Color("6b4a1a"))
	if t == T.FOSSIL:
		var bone := Color("cfc6ae")
		var hole := Color("140c08")
		var sx := 4 + v * 2
		var sy := 4 + v
		if v == 2:   # ribs
			for i in 4:
				for k in 7:
					_px(px, sx - 2 + k, sy + i * 2, bone if k != 3 else bone.darkened(0.2))
		else:        # skull
			var skull := [".xxxx.", "xxxxxx", "xooxox", "xxxxxx", ".xxxx.", ".x.x.."]
			for yy in skull.size():
				for xx in skull[yy].length():
					var ch: String = skull[yy][xx]
					if ch != ".":
						_px(px, sx + xx, sy + yy, bone if ch == "x" else hole)
	return px


func _dirt(px: PackedColorArray, r: RandomNumberGenerator, pal: Array, v: int) -> void:
	var n := FastNoiseLite.new()
	n.seed = r.randi()
	n.frequency = 0.2
	for y in TILE:
		for x in TILE:
			var k := n.get_noise_2d(x, y)
			px[y * TILE + x] = pal[0] if k < -0.3 else (pal[1] if k < 0.2 else pal[2])
	for i in 12:
		_px(px, r.randi() % TILE, r.randi() % TILE, pal[3] if i % 2 else pal[0])
	for i in 2:   # pebbles
		var x := 1 + r.randi() % 13
		var y := 1 + r.randi() % 13
		_px(px, x, y, Color("6e625a"))
		_px(px, x + 1, y, Color("4a403a"))
		_px(px, x, y + 1, Color("4a403a"))
	if v == 1:    # roots
		_walk(px, r, Color("1a100a"), r.randi() % TILE, 0, 12)


func _rocks(px: PackedColorArray, r: RandomNumberGenerator, pal: Array, count: int) -> void:
	var seeds := []
	for i in count:
		seeds.append(Vector2(r.randf() * TILE, r.randf() * TILE))
	for y in TILE:
		for x in TILE:
			var p := Vector2(x + 0.5, y + 0.5)
			var d1 := 999.0
			var d2 := 999.0
			var near := Vector2.ZERO
			for s in seeds:
				for ox in [-TILE, 0, TILE]:       # wrap so a tile repeats seamlessly
					for oy in [-TILE, 0, TILE]:
						var q: Vector2 = s + Vector2(ox, oy)
						var d := p.distance_to(q)
						if d < d1:
							d2 = d1
							d1 = d
							near = q
						elif d < d2:
							d2 = d
			var c: Color
			if d2 - d1 < 1.2:
				c = pal[0]                       # crack between stones
			else:
				var rel := (p - near)
				var lit := -(rel.x + rel.y)       # light from top-left
				c = pal[3] if lit > 3.0 else (pal[2] if lit > -1.5 else pal[1])
			px[y * TILE + x] = c


func _walk(px: PackedColorArray, r: RandomNumberGenerator, c: Color, x: int, y: int, steps: int) -> void:
	for i in steps:
		_px(px, x, y, c)
		y += 1
		x += r.randi_range(-1, 1)


func _px(px: PackedColorArray, x: int, y: int, c: Color) -> void:
	if x >= 0 and x < TILE and y >= 0 and y < TILE:
		px[y * TILE + x] = c


## Paints one tile: base pattern + edge treatment for the sides that touch air.
func _paint(img: Image, tx: int, ty: int, t: int, v: int, mask: int, base: PackedColorArray) -> void:
	var ox := tx * TILE
	var oy := ty * TILE
	var er := RandomNumberGenerator.new()
	er.seed = t * 7919 + v * 104729 + mask * 31
	var drips := []
	for i in TILE:
		drips.append(2 + (er.randi() % 4 if er.randf() < 0.3 else 0))
	for py in TILE:
		for px in TILE:
			var c: Color = base[py * TILE + px]
			var d := 99
			if mask & 1: d = mini(d, py)
			if mask & 2: d = mini(d, TILE - 1 - px)
			if mask & 4: d = mini(d, TILE - 1 - py)
			if mask & 8: d = mini(d, px)
			# rock gets darker the further it is from open air
			c = c.darkened(clampf((d - 2) / 7.0, 0.0, 1.0) * 0.45)
			if mask & 1 and py <= 1:
				c = c.lightened(0.28 if py == 0 else 0.12)          # lit top lip
			if mask & 4 and TILE - 1 - py < drips[px]:
				c = OUTLINE if py == TILE - 1 else c.darkened(0.5)  # dark underside
			if mask & 8 and px == 0:
				c = c.darkened(0.45)
			if mask & 2 and px == TILE - 1:
				c = c.darkened(0.45)
			if t == T.GRASS and mask & 1 and py < 3 + (px * 5 + v) % 3:
				c = Color("3f5c2c").lightened(0.15 if py == 0 else 0.0).darkened(er.randf() * 0.2)
			img.set_pixel(ox + px, oy + py, c)
	# chunky rounded corners where two open sides meet
	var corners := [[1 | 8, 0, 0, 1, 1], [1 | 2, TILE - 1, 0, -1, 1],
		[4 | 8, 0, TILE - 1, 1, -1], [4 | 2, TILE - 1, TILE - 1, -1, -1]]
	for k in corners:
		if mask & k[0] == k[0]:
			for p in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
				img.set_pixel(ox + k[1] + p.x * k[3], oy + k[2] + p.y * k[4], Color(0, 0, 0, 0))
			img.set_pixel(ox + k[1] + k[3], oy + k[2] + k[4], OUTLINE)


func _make_glow_tileset() -> TileSet:
	var img := Image.create(TILE * VARIANTS, TILE * G.size(), false, Image.FORMAT_RGBA8)
	var r := RandomNumberGenerator.new()
	r.seed = 7
	for v in VARIANTS:
		var ox := v * TILE
		for s in ore_specks[v]:
			img.set_pixel(ox + s.x, s.y, Color("ffd36a"))
			img.set_pixel(ox + s.x + 1, s.y, Color("e0a840"))
		# glowing mushrooms standing on the floor (bottom of the tile)
		var oy := G.MUSHROOM * TILE
		for m in 2 + v % 2:
			var x := 2 + r.randi() % 12
			var hgt := 2 + r.randi() % 4
			for k in hgt:
				img.set_pixel(ox + x, oy + TILE - 1 - k, Color("9fc9bf"))
			var top := TILE - 1 - hgt
			for dx in [-2, -1, 0, 1, 2]:
				img.set_pixel(ox + clampi(x + dx, 0, TILE - 1), oy + top, Color("2fb8a0"))
			for dx in [-1, 0, 1]:
				img.set_pixel(ox + clampi(x + dx, 0, TILE - 1), oy + top - 1, Color("5ff0d4"))
			img.set_pixel(ox + x, oy + top - 1, Color("c0fff4"))
		# glow-worm threads hanging from the ceiling (top of the tile)
		oy = G.WORM * TILE
		for w in 3 + v:
			var x := 1 + r.randi() % 14
			var length := 3 + r.randi() % 10
			for k in length:
				img.set_pixel(ox + x, oy + k, Color(0.35, 0.65, 0.7, 0.55))
			img.set_pixel(ox + x, oy + length, Color("b8fbff"))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(TILE, TILE)
	ts.add_source(src, 0)
	for g in G.size():
		for v in VARIANTS:
			src.create_tile(Vector2i(v, g))
	return ts


## Seamless rock texture for the cave back wall.
func make_wall_texture() -> CanvasTexture:
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var r := RandomNumberGenerator.new()
	r.seed = 4242
	var pal: Array = PAL.wall
	var seeds := []
	for i in 14:
		seeds.append(Vector2(r.randf() * s, r.randf() * s))
	for y in s:
		for x in s:
			var p := Vector2(x + 0.5, y + 0.5)
			var d1 := 999.0
			var d2 := 999.0
			var near := Vector2.ZERO
			for sd in seeds:
				for ox in [-s, 0, s]:
					for oy in [-s, 0, s]:
						var q: Vector2 = sd + Vector2(ox, oy)
						var d := p.distance_to(q)
						if d < d1:
							d2 = d1
							d1 = d
							near = q
						elif d < d2:
							d2 = d
			var c: Color
			if d2 - d1 < 1.5:
				c = pal[0]
			else:
				var lit := -((p - near).x + (p - near).y)
				c = pal[3] if lit > 7.0 else (pal[2] if lit > -2.0 else pal[1])
			if r.randf() < 0.04:
				c = c.darkened(0.3)
			img.set_pixel(x, y, c)
	return make_lit_texture(img)


## Wraps an image with a generated normal map so 2D lights shade its bumps.
static func make_lit_texture(img: Image, strength := 3.0) -> CanvasTexture:
	var w := img.get_width()
	var h := img.get_height()
	var nrm := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var x0 := (x / TILE) * TILE if w > 64 else 0
			var y0 := (y / TILE) * TILE if w > 64 else 0
			var cw := TILE if w > 64 else w
			var ch := TILE if w > 64 else h
			var hl := _height(img, x0 + posmod(x - 1 - x0, cw), y)
			var hr := _height(img, x0 + posmod(x + 1 - x0, cw), y)
			var hu := _height(img, x, y0 + posmod(y - 1 - y0, ch))
			var hd := _height(img, x, y0 + posmod(y + 1 - y0, ch))
			var n := Vector3((hl - hr) * strength, (hd - hu) * strength, 1.0).normalized()
			nrm.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	var tex := CanvasTexture.new()
	tex.diffuse_texture = ImageTexture.create_from_image(img)
	tex.normal_texture = ImageTexture.create_from_image(nrm)
	return tex


static func _height(img: Image, x: int, y: int) -> float:
	var c := img.get_pixel(x, y)
	return c.get_luminance() * c.a
