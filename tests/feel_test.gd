extends Node
## Headless movement/dig "feel" test. Builds solid blocks of each material, holds inputs
## like a player would and reports speed, getting stuck and animation flicker.
##   godot --headless --path . --fixed-fps 60 res://tests/feel_test.tscn

const DIRT := 0
const STONE := 1
const HARD := 2
const NAMES := ["dirt", "stone", "hard"]
# arena in cells: a solid block with a small air pocket for the player
const AX0 := 20
const AX1 := 108
const AY0 := 196
const AY1 := 330

var main: Node
var w: World
var p: Player
var bonks := 0
var low := false   # arena pocket only a bit taller than the miner


func _ready() -> void:
	Progress.dry_run = true     # never touch the real save
	World.fixed_seed = 7        # same world every run
	main = load("res://src/main.tscn").instantiate()
	add_child(main)
	_run()


func _run() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	w = main.world
	p = main.player
	main.fx.hitstop_enabled = false
	p.pick.struck.connect(func(_pos, _mat, _broke, kind): if kind == "bonk": bonks += 1)
	w.ensure_generated(AY1 * World.CELL + 600)
	print("--- surface walk (generated terrain)")
	await _surface_walk()
	for m in [DIRT, STONE, HARD]:
		print("--- ", NAMES[m])
		await _scenario(m, "down", ["dig", "down"], 3.0)
		await _scenario(m, "side", ["dig", "right"], 3.0)
		await _scenario(m, "diag", ["dig", "down", "right"], 3.0)
		await _scenario(m, "up+jump", ["dig", "up"], 3.0, true)
		await _scenario(m, "down,then side", ["down"], 1.5, false, ["dig", "right"], 3.0)
		low = true
		await _scenario(m, "side, low cave", ["dig", "right"], 3.0)
		await _scenario(m, "down, low cave", ["dig", "down"], 3.0)
		low = false
	get_tree().quit()


func _arena(m: int) -> void:
	for gy in range(AY0, AY1):
		for gx in range(AX0, AX1):
			var ch: World.Chunk = w.chunks.get(Vector2i(gx >> 5, gy >> 5))
			var air := gx >= 60 and gx < 68 and gy >= (211 if low else 204) and gy < 216
			ch.fill[(gy & 31) * World.C + (gx & 31)] = 0.0 if air else 1.0
			ch.dmg[(gy & 31) * World.C + (gx & 31)] = 0.0
			ch.mat[(gy & 31) * World.C + (gx & 31)] = m
	for ch: World.Chunk in w.chunks.values():
		ch.int_dirty = true
		ch.col_dirty = true
	w.dug.clear()
	w._flush()
	p.global_position = Vector2(64 * World.CELL, 216 * World.CELL - 19)
	p.velocity = Vector2.ZERO
	for i in 20:
		await get_tree().physics_frame


func _release_all() -> void:
	for a in ["left", "right", "up", "down", "jump", "dig"]:
		Input.action_release(a)


## Holds `keys` for `secs` (then optionally `keys2` for `secs2`) and measures.
func _scenario(m: int, label: String, keys: Array, secs: float, jump := false,
		keys2: Array = [], secs2 := 0.0) -> void:
	await _arena(m)
	if not keys2.is_empty():
		for k in keys:
			Input.action_press(k)
		for i in int(secs * 60):
			await get_tree().physics_frame
		_release_all()
		keys = keys2
		secs = secs2
	var start := p.global_position
	var st := _Stats.new()
	bonks = 0
	for k in keys:
		Input.action_press(k)
	for i in int(secs * 60):
		if jump:
			if i % 30 == 0:
				Input.action_press("jump")
			elif i % 30 == 12:
				Input.action_release("jump")
		await get_tree().physics_frame
		st.sample(p)
	_release_all()
	var d := (p.global_position - start) / World.METER
	print("  %-15s  dx %+5.2f m  dy %+5.2f m  (%.2f m/s)  stuck %3d%%  bonks %2d  anim switches %.1f/s  on_floor %3d%%  %s" % [
		label, d.x, d.y, d.length() / secs, st.stuck * 100 / st.n, bonks, st.switches / secs,
		st.floor * 100 / st.n, st.kinds()])


func _surface_walk() -> void:
	for dir in ["right", "left"]:
		p.global_position = Vector2(World.WIDTH_PX / 2.0, -60)
		p.velocity = Vector2.ZERO
		for i in 90:
			await get_tree().physics_frame
		var start := p.global_position
		var st := _Stats.new()
		Input.action_press(dir)
		for i in 360:
			await get_tree().physics_frame
			st.sample(p)
		_release_all()
		var d := (p.global_position - start) / World.METER
		print("  walk %-5s  dx %+6.2f m  dy %+5.2f m  stuck %3d%%  anim switches %.1f/s  %s" % [
			dir, d.x, d.y, st.stuck * 100 / st.n, st.switches / 6.0, st.kinds()])


class _Stats:
	var n := 0
	var stuck := 0      # pressing a direction, not moving, not digging
	var floor := 0
	var switches := 0
	var last := ""
	var last_pos := Vector2.INF
	var counts := {}

	func sample(p: Player) -> void:
		n += 1
		if p.is_on_floor():
			floor += 1
		var moved := last_pos.distance_to(p.global_position) > 0.2
		last_pos = p.global_position
		if not moved and p.pick.kind == "":
			stuck += 1
		if p.anim != last:
			switches += 1
			last = p.anim
		counts[p.anim] = counts.get(p.anim, 0) + 1

	func kinds() -> String:
		var parts := []
		for k in counts:
			parts.append("%s %d%%" % [k, counts[k] * 100 / n])
		return ", ".join(parts)
