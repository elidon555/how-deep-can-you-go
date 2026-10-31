class_name Ruins
## Halls of something older than any crew, deep down (in and above the magma): a long chamber
## shelled in hard rock, pillars at the ends, a hooded statue, a sealed door, and
## a relic to take (it sells well). Generated per chunk from the world's seed, like Camps.

const CHANCE := 0.09           # per chunk, in the right depths
const FROM := 420.0            # m
const TO := 570.0
const ROOM := Vector2i(24, 7)  # hall size in cells (width, height above the floor)


static func try_place(world: World, ch: World.Chunk) -> void:
	var depth := ch.key.y * World.CHUNK_PX / World.METER
	if depth < FROM or depth > TO or world.gen.rng.randf() > CHANCE:
		return
	var i0 := world.gen.rng.randi_range(2, World.C - ROOM.x - 2)
	var j0 := world.gen.rng.randi_range(ROOM.y + 3, World.C - 3)          # floor row
	var gx0 := ch.key.x * World.C + i0
	if gx0 < 6 or gx0 + ROOM.x > World.W - 6:
		return
	_carve(ch, i0, j0)
	_build(world, Vector2i(gx0, ch.key.y * World.C + j0))


## The hall: a hard-rock shell (floor, roof, end walls) around open air, lava cleared out.
static func _carve(ch: World.Chunk, i0: int, j0: int) -> void:
	for i in range(i0 - 1, i0 + ROOM.x + 1):
		for j in range(j0 - ROOM.y - 1, j0 + 2):
			var k := j * World.C + i
			var shell := j >= j0 or j == j0 - ROOM.y - 1 or i == i0 - 1 or i == i0 + ROOM.x
			ch.fill[k] = 1.0 if shell else 0.0
			ch.mat[k] = World.M.HARD if shell else ch.mat[k]
			ch.liquid[k] = 0.0
			ch.ltype[k] = Liquids.NONE
	# a breach in one end wall, so it can be found from a cave (and dug into from anywhere else)
	var side := i0 - 1 if (i0 % 2 == 0) else i0 + ROOM.x
	for j in range(j0 - 4, j0):
		ch.fill[j * World.C + side] = 0.0


static func _build(world: World, floor_cell: Vector2i) -> void:
	var rng := world.gen.rng
	var y := floor_cell.y * World.CELL
	var x0 := floor_cell.x * World.CELL
	var cell := Vector2i(floor_cell.x + ROOM.x / 2, floor_cell.y)
	world.gen.place_prop("ruin_pillar", Vector2(x0 + 12.0, y), false, cell, Color("4ff0d0"))
	world.gen.place_prop("ruin_pillar", Vector2(x0 + ROOM.x * World.CELL - 12.0, y), false, cell, Color("4ff0d0"))
	world.gen.place_prop("ruin_statue", Vector2(x0 + ROOM.x * World.CELL * rng.randf_range(0.35, 0.65), y), false, cell)
	world.gen.place_prop("ruin_door", Vector2(x0 + 36.0 if rng.randf() < 0.5 else x0 + ROOM.x * World.CELL - 36.0, y),
		false, cell, Color("4ff0d0"))
	var relic := CampItems.Relic.new()
	relic.position = Vector2(x0 + ROOM.x * World.CELL * rng.randf_range(0.2, 0.8), y)
	relic.value = rng.randi_range(30, 70)
	if world.add_entity(relic):
		world.add_decor(cell, relic)
