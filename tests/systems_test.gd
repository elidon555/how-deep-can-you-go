extends Node
## Headless end-to-end check of the game systems: rope climb back to the surface and selling
## ore, the shop, a crawler fight, and a falling boulder. Prints PASS/FAIL per check.
##   godot --headless --path . --fixed-fps 60 res://tests/systems_test.tscn
## Uses the real save in memory only (never writes it).

var main: Node
var w: World
var p: Player
var fails := 0


func _ready() -> void:
	Progress.dry_run = true     # never touch the real save
	main = load("res://src/main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	w = main.world
	p = main.player
	main.fx.hitstop_enabled = false
	var saved_money := Progress.money
	var saved_levels := Progress.levels.duplicate()
	await _rope_and_sell()
	await _shop()
	await _crawler_fight()
	await _boulder()
	Progress.money = saved_money
	Progress.levels = saved_levels
	print("RESULT: ", "ALL PASS" if fails == 0 else "%d FAILED" % fails)
	get_tree().quit()


func _check(name: String, ok: bool, info := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + ("  (" + info + ")" if info != "" else ""))
	if not ok:
		fails += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _hold(keys: Array, secs: float) -> void:
	for k in keys:
		Input.action_press(k)
	await _frames(int(secs * 60))
	for k in keys:
		Input.action_release(k)


func _rope_and_sell() -> void:
	p.global_position = Vector2(World.WIDTH_PX / 2.0 + 60, -40)
	await _frames(60)
	await _hold(["dig", "down"], 6.0)
	var depth := p.global_position.y / World.METER
	_check("dug down a shaft", depth > 3.0, "%.1f m" % depth)
	main.carried = 2
	main.carried_value = 5
	var money := Progress.money
	var ropes: int = main.ropes
	Input.action_press("rope")
	await _frames(2)
	Input.action_release("rope")
	_check("threw a rope", main.ropes == ropes - 1 and get_tree().get_nodes_in_group("rope").size() > 0)
	await _hold(["up"], 0.1)
	_check("grabbed the rope", p.rope != null)
	Input.action_press("up")
	for i in 600:
		await get_tree().physics_frame
		if p.rope == null or p.global_position.y < -20:
			break
	Input.action_release("up")
	_check("climbed to the top", p.global_position.y < 0.0, "y=%.0f" % p.global_position.y)
	await _hold(["right"], 0.5)
	await _frames(30)
	_check("stepped off onto the surface", p.rope == null and p.is_on_floor(), "y=%.0f" % p.global_position.y)
	_check("sold ore at the surface", Progress.money == money + 5 and main.carried == 0,
		"money %d -> %d" % [money, Progress.money])


func _shop() -> void:
	p.global_position = Vector2(main.camp.position.x + 10, main.camp.ground_y - 30)
	await _frames(30)
	_check("near the stall", main.camp.near(p.global_position))
	Input.action_press("interact")
	await _frames(2)
	Input.action_release("interact")
	_check("shop opens", main.shop.visible and p.frozen)
	Progress.money = 1000
	var lvl := Progress.level("pick")
	main.shop._buy("pick")
	_check("bought an upgrade", Progress.level("pick") == lvl + 1 and Progress.money < 1000)
	main.shop.close()
	await _frames(2)
	_check("shop closes", not main.shop.visible and not p.frozen)


## A flat arena deep down with a crawler next to the player.
func _arena(y_cell: int) -> void:
	for gy in range(y_cell - 12, y_cell + 8):
		for gx in range(30, 98):
			var ch: World.Chunk = w.chunks.get(Vector2i(gx >> 5, gy >> 5))
			ch.fill[(gy & 31) * World.C + (gx & 31)] = 0.0 if gy < y_cell else 1.0
			ch.dmg[(gy & 31) * World.C + (gx & 31)] = 0.0
			ch.mat[(gy & 31) * World.C + (gx & 31)] = World.M.STONE
	for ch: World.Chunk in w.chunks.values():
		ch.int_dirty = true
		ch.col_dirty = true
	w._flush()


func _crawler_fight() -> void:
	main.spawner.set_process(false)
	w.ensure_generated(320 * World.CELL)
	_arena(260)
	p.global_position = Vector2(60 * World.CELL, 260 * World.CELL - 19)
	p.velocity = Vector2.ZERO
	p.heal_full()
	await _frames(30)
	var c := Crawler.new()
	c.world = w
	c.player = p
	c.glow_parent = main.glow_layer
	c.position = p.global_position + Vector2(90, 8)
	main.add_child(c)
	var hp := p.health
	for i in 240:
		await get_tree().physics_frame
		if p.health < hp:
			break
	_check("crawler attacks", p.health < hp, "hp %d -> %d" % [hp, p.health])
	p.facing = 1 if c.global_position.x > p.global_position.x else -1
	var dir := "right" if p.facing > 0 else "left"
	for i in 360:
		if not is_instance_valid(c) or c.state == Crawler.State.DEAD:
			break
		p.facing = 1 if c.global_position.x > p.global_position.x else -1
		Input.action_press("dig")
		await get_tree().physics_frame
	Input.action_release("dig")
	_check("crawler dies to the pickaxe", not is_instance_valid(c) or c.state == Crawler.State.DEAD)


func _boulder() -> void:
	_arena(300)
	p.heal_full()
	p.global_position = Vector2(64 * World.CELL, 300 * World.CELL - 19)
	await _frames(40)
	# a boulder resting on a thin shelf right above the player's head
	var b := Boulder.new()
	b.world = w
	b.position = p.global_position + Vector2(0, -60)
	w.add_child(b)
	await _frames(40)
	var hp := p.health
	for i in 240:
		await get_tree().physics_frame
		if not is_instance_valid(b):
			break
	_check("unsupported boulder falls and shatters", not is_instance_valid(b))
	_check("falling boulder hurts", p.health < hp, "hp %d -> %d" % [hp, p.health])
