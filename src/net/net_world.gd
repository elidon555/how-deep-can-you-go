class_name NetWorld
## Online co-op: keeps every client's ground the same as the host's. Both sides generate the
## same world from the run's seed, so only what changed travels: the host's World records each
## cell that's dug, cracked, turned to rock or flooded (World.changes), the session sends those
## in batches, and a player joining late first gets every chunk changed since the run began
## (World.touched). Cells pack into 11 bytes each and the batch is compressed.

const CELL_BYTES := 11        # gx u8, gy s32, fill u16 (exact enough to never flip rock/air),
                              # damage, material, liquid, liquid type u8
const COMPRESSION := FileAccess.COMPRESSION_ZSTD


## Host: the cells changed since the last call, packed (empty when nothing changed).
static func take_changes(world: World) -> Array:
	if world.changes.is_empty():
		return []
	var cells: Array = world.changes.keys()
	world.changes.clear()
	return _pack(world, cells)


## Host: everything in a chunk, for someone who just joined.
static func pack_chunk(world: World, key: Vector2i) -> Array:
	var cells := []
	for j in World.C:
		for i in World.C:
			cells.append(Vector2i(key.x * World.C + i, key.y * World.C + j))
	return _pack(world, cells)


## Client: applies a batch from take_changes / pack_chunk, generating ahead if it reaches
## rows this machine hasn't made yet.
static func apply(world: World, packed: Array) -> void:
	if packed.size() != 2:
		return
	var data: PackedByteArray = (packed[1] as PackedByteArray).decompress(int(packed[0]), COMPRESSION)
	var deepest := -INF
	for o in range(0, data.size(), CELL_BYTES):
		deepest = maxf(deepest, data.decode_s32(o + 1))
	if deepest > -INF:
		world.ensure_generated((deepest + 1) * World.CELL)
	for o in range(0, data.size(), CELL_BYTES):
		world.net_set_cell(data[o], data.decode_s32(o + 1), data.decode_u16(o + 5) / 65535.0,
			data[o + 7] / 510.0, data[o + 8], data[o + 9] / 255.0, data[o + 10])


static func _pack(world: World, cells: Array) -> Array:
	var data := PackedByteArray()
	data.resize(cells.size() * CELL_BYTES)
	var o := 0
	for c: Vector2i in cells:
		data[o] = c.x
		data.encode_s32(o + 1, c.y)
		data.encode_u16(o + 5, int(round(clampf(world.get_fill(c.x, c.y), 0.0, 1.0) * 65535.0)))
		data[o + 7] = int(clampf(world.get_dmg(c.x, c.y), 0.0, 0.5) * 510.0)   # cells break at 0.5
		data[o + 8] = world.get_mat(c.x, c.y)
		data[o + 9] = int(clampf(world.get_liquid(c.x, c.y), 0.0, 1.0) * 255.0)
		data[o + 10] = world.get_ltype(c.x, c.y)
		o += CELL_BYTES
	return [data.size(), data.compress(COMPRESSION)]
