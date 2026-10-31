extends TileMapLayer
class_name World
## Endless diggable ground, generated in chunks as the player goes down.
## 1 tile = 1 meter. Row 0 is the surface.

signal tile_broken(cell: Vector2i, type: int)

const TILE := 16
const WIDTH := 48          # tiles across (outer columns are unbreakable walls)
const CHUNK := 32          # rows generated at a time
const AHEAD := 80          # keep this many rows generated below the player

enum T { DIRT, STONE, HARD, ORE, BEDROCK, GRASS }
const HP := {T.DIRT: 1.0, T.GRASS: 1.0, T.STONE: 2.5, T.HARD: 5.5, T.ORE: 2.0, T.BEDROCK: INF}
const COLORS := {
	T.DIRT: Color("7a4e2d"), T.STONE: Color("6b6b73"), T.HARD: Color("3d3a4a"),
	T.ORE: Color("5e5e66"), T.BEDROCK: Color("1c1a22"), T.GRASS: Color("7a4e2d"),
}

var generated_rows := 0
var damage := {}  # Vector2i -> damage dealt so far
var noise_cave := FastNoiseLite.new()
var noise_mat := FastNoiseLite.new()
var rng := RandomNumberGenerator.new()
var cracks := Node2D.new()


func _ready() -> void:
	tile_set = _make_tileset()
	rng.randomize()
	noise_cave.seed = rng.randi()
	noise_cave.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_cave.frequency = 0.07
	noise_mat.seed = rng.randi()
	noise_mat.frequency = 0.05
	# side walls above the surface so you can't walk off the world
	for y in range(-30, 0):
		set_cell(Vector2i(0, y), 0, Vector2i(T.BEDROCK, 0))
		set_cell(Vector2i(WIDTH - 1, y), 0, Vector2i(T.BEDROCK, 0))
	ensure_generated(AHEAD)
	cracks.z_index = 1
	add_child(cracks)
	cracks.draw.connect(_draw_cracks)


func ensure_generated(row: int) -> void:
	while generated_rows < row:
		for y in range(generated_rows, generated_rows + CHUNK):
			_gen_row(y)
		generated_rows += CHUNK


func _gen_row(y: int) -> void:
	for x in WIDTH:
		var c := Vector2i(x, y)
		if x == 0 or x == WIDTH - 1:
			set_cell(c, 0, Vector2i(T.BEDROCK, 0))
			continue
		if y == 0:
			set_cell(c, 0, Vector2i(T.GRASS, 0))
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
		set_cell(c, 0, Vector2i(t, 0))


func get_type(cell: Vector2i) -> int:
	if get_cell_source_id(cell) == -1:
		return -1
	return get_cell_atlas_coords(cell).x


## Adds dig damage to a tile. Returns true if the tile broke.
func dig(cell: Vector2i, amount: float) -> bool:
	var t := get_type(cell)
	if t == -1 or t == T.BEDROCK:
		return false
	damage[cell] = damage.get(cell, 0.0) + amount
	cracks.queue_redraw()
	if damage[cell] >= HP[t]:
		damage.erase(cell)
		erase_cell(cell)
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
		var col := Color(0, 0, 0, 0.35 + 0.4 * p)
		# more crack lines the more damaged the tile is
		var lines := [
			[Vector2(8, 8), Vector2(3, 2)], [Vector2(8, 8), Vector2(14, 5)],
			[Vector2(8, 8), Vector2(5, 14)], [Vector2(8, 8), Vector2(13, 13)],
			[Vector2(3, 2), Vector2(1, 7)], [Vector2(14, 5), Vector2(15, 1)],
		]
		var n := int(ceil(p * lines.size()))
		for i in n:
			cracks.draw_line(o + lines[i][0], o + lines[i][1], col, 1.0)


func _make_tileset() -> TileSet:
	var n := T.size()
	var img := Image.create(TILE * n, TILE, false, Image.FORMAT_RGBA8)
	var r := RandomNumberGenerator.new()
	r.seed = 1234
	for i in n:
		var base: Color = COLORS[i]
		for px in TILE:
			for py in TILE:
				var c := base.darkened(r.randf() * 0.18)
				if px == 0 or py == 0:
					c = c.lightened(0.1)
				elif px == TILE - 1 or py == TILE - 1:
					c = c.darkened(0.25)
				if i == T.GRASS and py < 4 + (px * 7 % 3):
					c = Color("4f9a3a").darkened(r.randf() * 0.2)
				img.set_pixel(i * TILE + px, py, c)
		if i == T.ORE:
			for k in 9:
				var sx := 2 + r.randi() % 11
				var sy := 2 + r.randi() % 11
				var gold := Color("f2c14e").lightened(r.randf() * 0.3)
				img.set_pixel(i * TILE + sx, sy, gold)
				img.set_pixel(i * TILE + sx + 1, sy, gold.darkened(0.2))
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_physics_layer()
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(TILE, TILE)
	ts.add_source(src, 0)
	var h := TILE / 2.0
	var poly := PackedVector2Array([Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)])
	for i in n:
		src.create_tile(Vector2i(i, 0))
		var td := src.get_tile_data(Vector2i(i, 0), 0)
		td.add_collision_polygon(0)
		td.set_collision_polygon_points(0, 0, poly)
	return ts
