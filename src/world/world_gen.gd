extends RefCounted
class_name WorldGen
## Everything about making the world (World asks for it chunk by chunk): the noise, the rock
## layers, caves, ore, liquid pockets, loose boulders, cave props and decor, and ruined camps
## (camps.gd). All of it comes from the world's seed, so every world is different and a fixed
## seed (tests) gives the same one.

const PROP_NAMES := ["lantern", "beam", "crystal_p", "crystal_t", "skeleton", "roots", "cart", "crate", "chains",
	"tent_ruin", "bunk", "table", "barrel", "lamp_post"]
# liquid pockets: water from WATER_FROM m down to the magma layer, lava inside it
const WATER_FROM := 8.0
const LIQUID_POCKETS := 0.32     # noise threshold: higher = fewer, smaller pockets
# firedamp pockets trapped in the rock, in the coal-bearing depths
const GAS_FROM := 25.0
const GAS_TO := 330.0
const GAS_POCKETS := 0.6         # noise threshold

var world: World
var rng := RandomNumberGenerator.new()
var noise_cave := FastNoiseLite.new()
var noise_mat := FastNoiseLite.new()
var noise_surf := FastNoiseLite.new()
var noise_layer := FastNoiseLite.new()
var noise_liquid := FastNoiseLite.new()
var noise_gas := FastNoiseLite.new()
var deco_tex := {}
var props := {}                  # name -> [texture, glow texture or null]
var flicker := []                # lantern lights
var _time := 0.0


func _init(w: World) -> void:
	world = w
	_make_decor_textures()
	for p in PROP_NAMES:
		var g := "res://assets/props/%s_glow.png" % p
		props[p] = [Art.lit("res://assets/props/%s.png" % p), load(g) if ResourceLoader.exists(g) else null]
	if World.fixed_seed >= 0:
		rng.seed = World.fixed_seed
	else:
		rng.randomize()
	world.seed = rng.seed
	noise_cave.seed = rng.randi()
	noise_cave.frequency = 0.0045
	noise_cave.fractal_octaves = 4
	noise_mat.seed = rng.randi()
	noise_mat.frequency = 0.006
	noise_surf.seed = rng.randi()
	noise_surf.frequency = 0.01
	noise_layer.seed = rng.randi()
	noise_layer.frequency = 0.004
	noise_liquid.seed = rng.randi()
	noise_liquid.frequency = 0.012
	noise_gas.seed = rng.randi()
	noise_gas.frequency = 0.02


## Lantern lights flicker.
func update(dt: float) -> void:
	_time += dt
	for i in range(flicker.size() - 1, -1, -1):
		var l = flicker[i]
		if not is_instance_valid(l):
			flicker.remove_at(i)
			continue
		var ph := float(l.get_instance_id() % 97)
		l.energy = 1.1 * (0.85 + 0.15 * sin(_time * 9.0 + ph) * sin(_time * 5.3 + ph * 0.7))


func cell(gx: int, gy: int) -> Vector2:
	if gx < 2 or gx >= World.W - 2:
		return Vector2(1.0, World.M.BEDROCK)
	var px := gx * World.CELL + 4.0
	var py := gy * World.CELL + 4.0
	var surf := noise_surf.get_noise_1d(px) * 10.0          # gentle bumps at the surface
	if py < surf:
		return Vector2(0.0, World.M.DIRT)
	var depth := py / World.METER
	# caves: none right under the grass, bigger the deeper you go
	var t := 0.2 - minf(depth / 800.0, 0.08) + maxf(0.0, 8.0 - depth) * 0.15
	var fill := clampf(0.5 + (t - noise_cave.get_noise_2d(px, py)) * 5.0, 0.0, 1.0)
	fill = minf(fill, clampf((py - surf) / World.CELL + 0.5, 0.0, 1.0))
	if depth >= World.CAVERN_FROM and depth < World.BOTTOM:
		fill = _cavern(px, depth)
	return Vector2(fill, material(px, py, depth))


## The vast cavern above the Floor: open, but for a few huge pillars (noise picks where) and a
## ragged ceiling.
func _cavern(px: float, depth: float) -> float:
	var ceiling := World.CAVERN_FROM + 4.0 + noise_layer.get_noise_1d(px * 3.0) * 4.0
	if depth < ceiling:
		return 1.0
	var pillar := noise_layer.get_noise_1d(px * 0.9 + 999.0)
	if pillar > 0.55 and absf(px - World.WIDTH_PX / 2.0) > 160.0:      # never under the drill
		return 1.0
	return 0.0


## Depth (m) as the layers see it: real depth nudged by noise, so boundaries wander.
func layer_depth(px: float, py: float, depth: float) -> float:
	return depth + noise_layer.get_noise_1d(px) * World.LAYER_WOBBLE + noise_layer.get_noise_2d(px, py) * 8.0


## Rock type: soil turning to stone and hard rock with depth, then the crystal caverns, deep
## basalt, and the magma layer. Layer boundaries wander with noise.
func material(px: float, py: float, depth: float) -> int:
	var m := noise_mat.get_noise_2d(px, py) * 0.5 + 0.5
	var d := layer_depth(px, py, depth)
	if depth >= World.BOTTOM:
		return World.M.FLOOR
	if d >= World.MAGMA_FROM:
		return World.M.HARD if m > 0.78 else World.M.MAGMA
	if d >= World.CRYSTAL_TO:
		return World.M.MAGMA if m < clampf((d - World.CRYSTAL_TO) / 400.0, 0.0, 0.2) else World.M.HARD
	if d >= World.CRYSTAL_FROM:
		return World.M.HARD if m > 0.72 else World.M.CRYSTAL
	var mat := World.M.DIRT
	if m < clampf((depth - 4.0) / 110.0, 0.0, 0.85):
		mat = World.M.STONE
	if m < clampf((depth - 50.0) / 250.0, 0.0, 0.7):
		mat = World.M.HARD
	return mat


## Liquid pockets in natural caves (noise), then settled: in every column, each run of open
## cells has its liquid stacked at the bottom, so pools sit in basins from the start.
func liquid_pockets(ch: World.Chunk) -> void:
	for j in World.C:
		for i in World.C:
			var k := j * World.C + i
			if ch.fill[k] >= 0.5:
				continue
			var gx := ch.key.x * World.C + i
			var gy := ch.key.y * World.C + j
			if gx < 3 or gx >= World.W - 3:
				continue
			var px := gx * World.CELL + 4.0
			var py := gy * World.CELL + 4.0
			var depth := py / World.METER
			if depth < WATER_FROM or depth > World.CAVERN_FROM - 5.0 or noise_liquid.get_noise_2d(px, py) < LIQUID_POCKETS:
				continue
			ch.liquid[k] = 1.0
			ch.ltype[k] = Liquids.LAVA if layer_depth(px, py, depth) >= World.MAGMA_FROM - 10.0 else Liquids.WATER
			ch.has_liquid = true
	if not ch.has_liquid:
		return
	for i in World.C:                       # settle each column's open runs
		var j := 0
		while j < World.C:
			if ch.fill[j * World.C + i] >= 0.5:
				j += 1
				continue
			var j0 := j
			var amount := 0.0
			var kind := Liquids.NONE
			while j < World.C and ch.fill[j * World.C + i] < 0.5:
				amount += ch.liquid[j * World.C + i]
				if ch.ltype[j * World.C + i] != Liquids.NONE:
					kind = ch.ltype[j * World.C + i]
				ch.liquid[j * World.C + i] = 0.0
				ch.ltype[j * World.C + i] = Liquids.NONE
				j += 1
			var y := j - 1
			while amount > 0.001 and y >= j0:
				ch.liquid[y * World.C + i] = minf(amount, 1.0)
				ch.ltype[y * World.C + i] = kind
				amount -= 1.0
				y -= 1


## Firedamp trapped in solid rock (World.gas): dug open, it leaks out as a GasCloud.
func _gas_pockets(ch: World.Chunk) -> void:
	for j in World.C:
		for i in World.C:
			if ch.fill[j * World.C + i] < 0.9:
				continue
			var gx := ch.key.x * World.C + i
			var gy := ch.key.y * World.C + j
			var px := gx * World.CELL + 4.0
			var py := gy * World.CELL + 4.0
			var depth := py / World.METER
			if depth >= GAS_FROM and depth <= GAS_TO and noise_gas.get_noise_2d(px, py) > GAS_POCKETS:
				world.gas[Vector2i(gx, gy)] = true


## Ore, bones, glowing mushrooms and worms.
func populate(ch: World.Chunk) -> void:
	_gas_pockets(ch)
	for j in World.C:
		for i in World.C:
			var gx := ch.key.x * World.C + i
			var gy := ch.key.y * World.C + j
			if gx < 3 or gx >= World.W - 3 or gy < 2:
				continue
			var f := ch.fill[j * World.C + i]
			var m := ch.mat[j * World.C + i]
			var depth := gy * World.CELL / World.METER
			var pos := Vector2(gx * World.CELL + 4, gy * World.CELL + 4)
			if f >= 0.5:
				if depth > 2 and rng.randf() < (0.006 if m == World.M.DIRT else 0.008):
					var kind := World.COAL if rng.randf() < 0.55 else _ore_kind(depth)
					var lit := _sprite(deco_tex.ore[kind], pos, world, 1)
					var gl := _sprite(deco_tex.ore_glow[kind], pos, world.glow_root, 0)
					world.ores[Vector2i(gx, gy)] = [lit, gl, kind]
				elif m == World.M.DIRT and depth > 3 and rng.randf() < 0.0008:
					world.add_decor(Vector2i(gx, gy), _sprite(deco_tex.skull, pos, world, 1))
				elif depth > 5 and world.get_fill(gx, gy - 1) < 0.5 and world.get_fill(gx, gy - 2) < 0.5 \
						and rng.randf() < 0.06:
					var mush := _sprite(deco_tex.mushroom, Vector2(pos.x, gy * World.CELL - 5), world.glow_root, 0)
					world.add_decor(Vector2i(gx, gy), mush)
					if rng.randf() < 0.5:
						world.add_decor(Vector2i(gx, gy), _light(Vector2(pos.x, gy * World.CELL - 8), Color("3fe0c0"), 0.55, 0.9))
			elif depth > 10 and world.get_fill(gx, gy - 1) >= 0.5 and rng.randf() < 0.035:
				var worm := _sprite(deco_tex.worm, Vector2(pos.x, gy * World.CELL + 10), world.glow_root, 0)
				world.add_decor(Vector2i(gx, gy - 1), worm)
			if f < 0.5 or gx < 6 or gx >= World.W - 6:
				continue
			var surf := Vector2(gx * World.CELL + 4, gy * World.CELL)
			if world.get_fill(gx, gy - 1) < 0.5 and world.get_fill(gx, gy - 2) < 0.5:   # a floor
				_floor_props(Vector2i(gx, gy), surf, depth)
	_place_boulders(ch)
	Camps.try_place(world, ch)
	# ceilings: an air cell right under rock
	for j in World.C:
		for i in World.C:
			var gx := ch.key.x * World.C + i
			var gy := ch.key.y * World.C + j
			if gx < 6 or gx >= World.W - 6 or gy < 3:
				continue
			if ch.fill[j * World.C + i] < 0.5 and world.get_fill(gx, gy - 1) >= 0.5 and world.get_fill(gx, gy + 1) < 0.5:
				_ceiling_props(Vector2i(gx, gy - 1), Vector2(gx * World.CELL + 4, gy * World.CELL), gy * World.CELL / World.METER)


## Loose boulders sit in small pockets inside dirt and stone (dig under one and it drops).
## Kept away from chunk edges so the pocket stays inside this chunk.
func _place_boulders(ch: World.Chunk) -> void:
	for j in range(3, World.C - 3):
		for i in range(3, World.C - 3):
			var gx := ch.key.x * World.C + i
			var gy := ch.key.y * World.C + j
			if gx < 8 or gx >= World.W - 8 or gy * World.CELL / World.METER < 8.0:
				continue
			if ch.fill[j * World.C + i] < 0.99 or ch.mat[j * World.C + i] == World.M.HARD or rng.randf() > 0.0012:
				continue
			var centre := Vector2(gx * World.CELL, gy * World.CELL)
			for dj in range(-2, 3):
				for di in range(-2, 3):
					var c := Vector2((gx + di) * World.CELL + 4, (gy + dj) * World.CELL + 4)
					if c.distance_to(centre) < Boulder.RADIUS + 3.0:
						ch.fill[(j + dj) * World.C + i + di] = 0.0
			var b := Boulder.new()
			b.world = world
			b.position = centre
			b.shattered.connect(world.boulder_shattered.emit)
			world.add_entity(b)


## Deepest ore found at this depth, sometimes a cheaper one.
func _ore_kind(depth: float) -> int:
	var k := 0
	for i in World.METALS:
		if depth >= World.ORES[i][4]:
			k = i
	while k > 0 and rng.randf() < 0.45:
		k -= 1
	return k


func _floor_props(cell: Vector2i, p: Vector2, depth: float) -> void:
	var r := rng.randf()
	if depth > 4 and depth < 180 and r < 0.03:
		# mine support beam: needs a flat floor and a ceiling 8-11 cells up
		var h := 1
		while h < 13 and world.get_fill(cell.x, cell.y - h) < 0.5:
			h += 1
		var flat := true
		for dx in [-3, 3]:
			if world.get_fill(cell.x + dx, cell.y) < 0.5 or world.get_fill(cell.x + dx, cell.y - 1) >= 0.5:
				flat = false
		if flat and h >= 8 and h <= 11:
			place_prop("beam", p + Vector2(0, 3), false, cell)
			return
	r = rng.randf()
	if depth > 50 and r < 0.014:
		var c := "crystal_p" if depth > 90 and rng.randf() < 0.7 else "crystal_t"
		place_prop(c, p + Vector2(0, 3), false, cell, Color("b06cff") if c == "crystal_p" else Color("4ff0d0"))
	elif depth > 12 and r < 0.018:
		place_prop("skeleton", p + Vector2(0, 2), false, cell)
	elif depth > 8 and depth < 200 and r < 0.021:
		place_prop("cart", p + Vector2(0, 3), false, cell)
	elif depth > 5 and r < 0.025:
		place_prop("crate", p + Vector2(0, 2), false, cell)


func _ceiling_props(cell: Vector2i, p: Vector2, depth: float) -> void:
	var r := rng.randf()
	if depth > 2 and depth < 45 and world.get_mat(cell.x, cell.y) == World.M.DIRT and r < 0.05:
		place_prop("roots", p - Vector2(0, 3), true, cell)
	elif depth > 6 and depth < 150 and r < 0.058:
		var open := true
		for k in range(1, 6):
			if world.get_fill(cell.x, cell.y + k) >= 0.5:
				open = false
		if open:
			var l := place_prop("lantern", p - Vector2(0, 2), true, cell, Color("ffb347"))
			flicker.append(l)
	elif depth > 30 and r < 0.064:
		place_prop("chains", p - Vector2(0, 2), true, cell)
	elif depth > 70 and r < 0.072:
		var c := "crystal_p" if rng.randf() < 0.6 else "crystal_t"
		place_prop(c, p - Vector2(0, 3), true, cell, Color("b06cff") if c == "crystal_p" else Color("4ff0d0"))


## Places a Blender prop. anchor_top: hangs from p (ceiling); else stands on p (floor).
## Returns the light if one was added.
func place_prop(name: String, p: Vector2, anchor_top: bool, cell: Vector2i, light := Color(0, 0, 0, 0)) -> PointLight2D:
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
		var parent: Node = world.glow_root if k == 1 else world
		parent.add_child(s)
		world.add_decor(cell, s)
	if light.a > 0:
		var l := _light(p + off, light, 0.9 if name == "lantern" else 0.7, 1.1)
		world.add_decor(cell, l)
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
	world.add_child(l)
	return l


func _sprite(t: Texture2D, pos: Vector2, parent: Node, z: int) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = t
	s.position = pos
	s.z_index = z
	s.flip_h = rng.randf() < 0.5
	parent.add_child(s)
	return s



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
	for kind in World.ORES:
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
