class_name Camps
## Ruined camps of the crews who dug here before, generated per chunk: they dug themselves a
## chamber (a flat-floored room with timber supports at both ends, sometimes opening onto a
## cave, sometimes sealed in the rock) and left a random line-up of tents, bunks, tables,
## barrels and a lamp post, a crate or two to search, and one miner's note to read. Nothing is
## hand-placed: where, the layout, the loot and which note come from the world's seed.

const CHANCE := 0.07           # per chunk, in the right depths (about one camp every 35-40 m)
const FROM := 15.0             # m
const TO := 380.0
const ROOM := Vector2i(15, 6)  # chamber size in cells (width, height above the floor)
const PIECES := ["tent_ruin", "bunk", "table", "barrel", "barrel", "crate"]


static func try_place(world: World, ch: World.Chunk) -> void:
	var depth := ch.key.y * World.CHUNK_PX / World.METER
	if depth < FROM or depth > TO or world.rng.randf() > CHANCE:
		return
	# a spot fully inside this chunk (the chunk's neighbours may not exist yet)
	var i0 := world.rng.randi_range(2, World.C - ROOM.x - 2)
	var j0 := world.rng.randi_range(ROOM.y + 2, World.C - 3)          # floor row
	var gx0 := ch.key.x * World.C + i0
	if gx0 < 6 or gx0 + ROOM.x > World.W - 6:
		return
	_carve(ch, i0, j0)
	_build(world, Vector3i(gx0, ch.key.y * World.C + j0, ROOM.x))


## The crew's chamber: open air above a flat rock floor, liquid cleared out.
static func _carve(ch: World.Chunk, i0: int, j0: int) -> void:
	for i in range(i0, i0 + ROOM.x):
		ch.fill[j0 * World.C + i] = 1.0                    # the levelled floor
		for j in range(j0 - ROOM.y, j0):
			var k := j * World.C + i
			ch.fill[k] = 0.0
			ch.liquid[k] = 0.0
			ch.ltype[k] = Liquids.NONE


static func _build(world: World, spot: Vector3i) -> void:
	var rng := world.rng
	var floor_y := spot.y * World.CELL
	var x := spot.x * World.CELL + 10.0
	var end := (spot.x + spot.z) * World.CELL - 10.0
	var cell := Vector2i(spot.x + spot.z / 2, spot.y)
	# timber supports at both ends, a lamp post lighting the camp
	world.place_prop("beam", Vector2(spot.x * World.CELL + 3.0, floor_y + 3.0), false, cell)
	world.place_prop("beam", Vector2((spot.x + spot.z) * World.CELL - 3.0, floor_y + 3.0), false, cell)
	world.place_prop("lamp_post", Vector2(x, floor_y), false, cell, Color("ffb347"))
	x += 14.0
	var note_placed := false
	while x < end - 16.0:
		var piece: String = PIECES[rng.randi() % PIECES.size()]
		var w := 0.0
		match piece:
			"crate":
				var c := CampItems.LootCrate.new()
				c.position = Vector2(x + 8.0, floor_y)
				c.seed_value = rng.randi()
				world.add_child(c)
				world.add_decor(Vector2i(int(c.position.x) / World.CELL, spot.y), c)
				w = 18.0
			"table":
				world.place_prop("table", Vector2(x + 11.0, floor_y), false, cell)
				if not note_placed:
					note_placed = _note(world, Vector2(x + 11.0, floor_y - 14.0), spot.y, rng)
				w = 26.0
			_:
				var tex: Texture2D = world.props[piece][0] if world.props.has(piece) else null
				w = (tex.get_width() if tex else 16) + 6.0
				world.place_prop(piece, Vector2(x + w / 2.0, floor_y), false, cell)
		x += w + rng.randf_range(2.0, 14.0)
	if not note_placed:
		_note(world, Vector2(end - 6.0, floor_y), spot.y, rng)


static func _note(world: World, at: Vector2, gy: int, rng: RandomNumberGenerator) -> bool:
	var id := Lore.deal(rng)
	if id < 0:
		return false
	var n := CampItems.Note.new()
	n.note_id = id
	n.position = at
	world.add_child(n)
	world.add_decor(Vector2i(int(at.x) / World.CELL, gy), n)
	return true
