extends Node
## Headless end-to-end check of the game systems: the drill (descending with the crew inside,
## furnace, workbench + shop, breaches and repairs), rope climbing, a crawler fight and a
## falling boulder. Prints PASS/FAIL per check.
##   godot --headless --path . --fixed-fps 60 res://tests/systems_test.tscn
## Uses the real save in memory only (never writes it).

var main: Node
var w: World
var p: Player
var fails := 0


func _ready() -> void:
	Progress.dry_run = true     # never touch the real save
	World.fixed_seed = 7        # same world every run
	main = load("res://src/main.tscn").instantiate()
	add_child(main)
	await _frames(30)
	w = main.world
	p = main.player
	main.fx.hitstop_enabled = false
	var saved_money := Progress.money
	var saved_levels := Progress.levels.duplicate()
	await _drill_ride()
	await _furnace_and_workbench()
	await _breach()
	await _rope_climb()
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


func _station(kind) -> Station:
	for c in main.drill.get_children():
		if is_instance_of(c, kind):
			return c
	return null


func _drill_ride() -> void:
	var d: Drill = main.drill
	_check("starts inside the drill", d.contains(p.global_position))
	var y0 := d.global_position.y
	var fuel0 := d.fuel
	_station(Stations.Helm).interact(p)
	_station(Stations.Helm).interact(p)
	_check("helm sets full speed", d.speed == Drill.Speed.FULL)
	await _frames(60 * 8)
	var down := (d.global_position.y - y0) / World.METER
	_check("drill bores down", down > 2.0, "%.1f m in 8 s" % down)
	_check("drill burns fuel", d.fuel < fuel0, "%.0f -> %.0f" % [fuel0, d.fuel])
	_check("crew rides along inside", d.contains(p.global_position))
	_station(Stations.Helm).interact(p)
	_check("helm stops it", d.speed == Drill.Speed.STOP)


func _furnace_and_workbench() -> void:
	var d: Drill = main.drill
	p.coal = 3
	var fuel0 := d.fuel
	_station(Stations.Furnace).interact(p)
	_check("furnace burns coal into fuel", p.coal == 0 and d.fuel > fuel0, "%.0f -> %.0f" % [fuel0, d.fuel])
	p.ore_count = 2
	p.ore_value = 5
	var money := Progress.money
	_station(Stations.Workbench).interact(p)
	_check("workbench sells ore", Progress.money == money + 5 and p.ore_value == 0)
	_check("workbench opens the shop", main.shop.visible and p.frozen)
	Progress.money = 1000
	var lvl := Progress.level("plating")
	main.shop._buy("plating")
	_check("bought hull plating", Progress.level("plating") == lvl + 1 and d.max_hull > 100.0,
		"max hull %.0f" % d.max_hull)
	main.shop.close()
	await _frames(3)
	_check("shop closes", not main.shop.visible and not p.frozen)


func _breach() -> void:
	var d: Drill = main.drill
	d.hull = d.max_hull
	d.damage(10.0, d.global_position + Vector2(40, 0))
	var breaches := d.get_breaches()
	_check("a hit tears a breach", breaches.size() == 1)
	var h := d.hull
	await _frames(120)
	_check("breach leaks hull", d.hull < h, "%.1f -> %.1f" % [h, d.hull])
	var b: Node2D = breaches[0]
	p.global_position = Vector2(b.global_position.x, d.global_position.y + Drill.FLOOR - Player.HALF_HEIGHT - 1)
	await _frames(10)
	await _hold(["interact"], 2.2)
	await _frames(2)
	_check("holding E repairs it", d.get_breaches().is_empty())


func _rope_climb() -> void:
	p.global_position = Vector2(200, -40)       # well away from the drill
	await _frames(60)
	await _hold(["dig", "down"], 6.0)
	var depth := p.global_position.y / World.METER
	_check("dug down a shaft", depth > 3.0, "%.1f m" % depth)
	var ropes: int = p.ropes
	Input.action_press("rope")
	await _frames(2)
	Input.action_release("rope")
	_check("threw a rope", p.ropes == ropes - 1 and get_tree().get_nodes_in_group("rope").size() > 2)
	await _hold(["up"], 0.1)
	_check("grabbed the rope", p.rope != null)
	Input.action_press("up")
	var why := ""
	for i in 600:
		await get_tree().physics_frame
		if p.rope == null or p.global_position.y < -20:
			why = "hp %d, on rope %s" % [p.health, p.rope != null]
			break
	Input.action_release("up")
	_check("climbed to the top", p.global_position.y < 0.0, "y=%.0f, %s" % [p.global_position.y, why])
	await _hold(["right"], 0.5)
	await _frames(30)
	_check("stepped off onto the surface", p.rope == null and p.is_on_floor(), "y=%.0f" % p.global_position.y)


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
