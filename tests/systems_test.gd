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
	p.pick.mouse_aim = false     # aim with the keys, like J / a controller
	main.fx.hitstop_enabled = false
	var saved_money := Progress.money
	var saved_levels := Progress.levels.duplicate()
	await _drill_ride()
	await _furnace_and_workbench()
	await _breach()
	await _heat()
	await _flooding()
	_layers()
	await _sonar_and_worm()
	await _mouse_aim()
	await _rope_climb()
	await _camps()
	await _liquids()
	await _gas()
	await _crawler_fight()
	await _coop()
	await _the_bottom()
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
	var min_grip := 1.0
	for i in 60 * 8:
		await get_tree().physics_frame
		min_grip = minf(min_grip, d.grip)
	_check("braces let go while it sinks", min_grip <= 0.0)
	_check("ladders fold away with everyone aboard", d.ladders_out == 0.0)
	var down := (d.global_position.y - y0) / World.METER
	_check("drill bores down", down > 2.0, "%.1f m in 8 s" % down)
	if Drill.infinite_fuel():
		_check("fuel never runs out (infinite for now)", d.fuel == fuel0)
	else:
		_check("drill burns fuel", d.fuel < fuel0, "%.0f -> %.0f" % [fuel0, d.fuel])
	_check("crew rides along inside", d.contains(p.global_position))
	_station(Stations.Helm).interact(p)
	_check("helm stops it", d.speed == Drill.Speed.STOP)
	await _frames(70)
	_check("braces grip when it stops", d.grip >= 1.0)
	var back := p.global_position
	p.global_position = d.global_position + Vector2(Drill.HW + 20.0, Drill.FLOOR - 30.0)   # step outside
	await _frames(70)
	_check("ladders come down when someone is outside", d.ladders_out == 1.0)
	p.global_position = back
	p.velocity = Vector2.ZERO
	await _frames(70)
	_check("and fold away again once they're back in", d.ladders_out == 0.0)
	await _hatches()


## Hatches open for the crew and shut behind them; shut, a crawler can't get into the cabin.
func _hatches() -> void:
	var d: Drill = main.drill
	var home := p.global_position
	p.global_position = d.global_position + Vector2(-Drill.HW + 20.0, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	await _frames(40)
	_check("a hatch opens for the crew", d.hatch_open(-1.0))
	p.global_position = home
	await _frames(40)
	_check("and shuts when nobody's near", not d.hatch_open(-1.0) and not d.hatch_open(1.0))
	var c := Crawler.new()
	c.world = w
	c.player = p
	c.position = d.global_position + Vector2(-Drill.HW - 30.0, Drill.FLOOR - 9.0)
	main.add_child(c)
	c.state = Crawler.State.CHASE
	for i in 60 * 3:
		await get_tree().physics_frame
		c.dir = 1
		c.velocity.x = Crawler.CHASE_SPEED
	_check("a shut hatch keeps creatures out", not d.contains(c.global_position))
	_check("bats treat the shut hull as solid", d.blocks(d.global_position + Vector2(-Drill.HW + 3.0, 20.0), false))
	c.queue_free()


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


func _heat() -> void:
	var d: Drill = main.drill
	d.speed = Drill.Speed.SLOW
	d.thermal.heat = DrillHeat.MAX + 5.0
	await _frames(5)
	_check("overheated drill stalls", d.thermal.overheated and not d.cutter.drilling)
	_station(Stations.Coolant).interact(p)
	await _frames(5)
	_check("venting coolant cools it and it restarts", d.thermal.heat < DrillHeat.RESUME and not d.thermal.overheated,
		"heat %.0f" % d.thermal.heat)
	d.speed = Drill.Speed.STOP


## Layers are generated from noise: count the rock types in bands at different depths.
func _layers() -> void:
	var counts := {}
	for band: float in [200.0, 460.0]:
		var c := {}
		for i in 400:
			var px := randf_range(40.0, World.WIDTH_PX - 40.0)
			var mat := w.gen.material(px, band * World.METER + randf_range(-60, 60), band)
			c[mat] = c.get(mat, 0) + 1
		counts[band] = c
	_check("crystal caverns around 200 m", counts[200.0].get(World.M.CRYSTAL, 0) > 200, str(counts[200.0]))
	_check("magma layer around 460 m", counts[460.0].get(World.M.MAGMA, 0) > 200, str(counts[460.0]))


func _sonar_and_worm() -> void:
	var d: Drill = main.drill
	_station(Stations.Sonar).interact(p)
	await _frames(5)
	_check("sonar screen opens", main.sonar.visible and p.frozen)
	main.sonar.close()
	await _frames(5)
	_check("sonar closes", not main.sonar.visible and not p.frozen)
	for b in d.get_breaches():
		d.repair(b)
	await _frames(2)
	d.hull = d.max_hull
	var w: Worm = main.spawner.spawn_worm()
	var h := d.hull
	for i in 60 * 20:
		await get_tree().physics_frame
		if d.hull < h - 5.0:
			break
	_check("the worm burrows over and rams the drill", d.hull < h - 5.0, "hull %.0f -> %.0f" % [h, d.hull])
	_station(Stations.GunnerSeat).interact(p)
	await _frames(20)
	_check("gunner seat takes the turrets", d.guns.gunner == p and p.frozen)
	Input.action_press("dig")
	for i in 60 * 25:
		if not is_instance_valid(w) or w.state == Worm.State.DEAD:
			break
		p.aim_override = w.body[0]
		await get_tree().physics_frame
	Input.action_release("dig")
	p.aim_override = Vector2.INF
	_check("turret bolts kill the worm", not is_instance_valid(w) or w.state == Worm.State.DEAD,
		"hull %.0f, breaches %d, heat %.0f" % [d.hull, d.get_breaches().size(), d.thermal.heat])
	Input.action_press("interact")
	await _frames(2)
	Input.action_release("interact")
	await _frames(5)
	_check("getting up from the turrets", d.guns.gunner == null and not p.frozen)
	for b in d.get_breaches():
		d.repair(b)
	d.hull = d.max_hull


## Mouse aiming: the cursor sets the direction (here: far off, down and to the right); the swing
## hits the first rock that way, and nothing in other directions.
func _mouse_aim() -> void:
	w.ensure_generated(320 * World.CELL)
	_arena(280)
	p.heal_full()
	p.global_position = Vector2(60 * World.CELL, 280 * World.CELL - 19)
	await _frames(30)
	var cursor := p.global_position + Vector2(150, 190)      # far away, down and to the right
	var in_front := p.global_position + Vector2(16, 22)      # the floor that way
	var other_side := p.global_position + Vector2(-16, 22)
	p.pick.mouse_aim = true
	p.pick.aim_at = cursor
	_check("aiming down-right picks a diagonal swing", Pickaxe._kind_towards(cursor - (p.global_position + Pickaxe.SHOULDER)) == "dig_diag")
	await _hold(["dig"], 1.5)
	_check("hits the rock in front, not at the cursor", w.is_air(in_front) and not w.is_air(cursor))
	_check("rock in other directions is untouched", not w.is_air(other_side))
	p.pick.aim_at = Vector2.INF
	p.pick.mouse_aim = false


func _rope_climb() -> void:
	for b in get_tree().get_nodes_in_group("hittable"):   # a boulder dropping into the test shaft
		if b is Boulder:                                   # would wedge above the miner (as it should)
			b.queue_free()
	p.global_position = Vector2(200, -40)       # well away from the drill
	await _frames(60)
	await _hold(["dig", "down"], 6.0)
	var depth := p.global_position.y / World.METER
	_check("dug down a shaft", depth > 3.0, "%.1f m" % depth)
	var ropes: int = p.ropes
	Input.action_press("rope")
	await _frames(2)
	Input.action_release("rope")
	var used := 0 if GameConfig.infinite_resources() else 1
	_check("threw a rope", p.ropes == ropes - used and get_tree().get_nodes_in_group("rope").size() > 2)
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
	var top := -1.0
	for r in get_tree().get_nodes_in_group("rope"):
		if not r is DrillLadder:
			top = r.top_y()
	var cols := []
	for i in p.get_slide_collision_count():
		var col := p.get_slide_collision(i)
		cols.append("%s n%s at %s" % [col.get_collider().get_class() + ":" + str(col.get_collider().name), col.get_normal().round(), (col.get_position() - p.global_position).round()])
	var above := ""
	for dy in [-24, -32, -40]:
		var c := w.cell_at(p.global_position + Vector2(0, dy))
		above += "%.1f/%d " % [w.get_fill(c.x, c.y), w.get_mat(c.x, c.y)]
	_check("climbed to the top", p.global_position.y < 0.0, "y=%.0f, rope top %.0f, %s, ceil %s, above %s, frozen %s, on rope %s, hp %d, vel %s" % [
		p.global_position.y, top, why, p.is_on_ceiling(), above, p.frozen, p.rope != null, p.health, str(cols)])
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


## Camps are generated: there's at least one in the first 300 m, its crate pays out once and
## its note gets read. Then a bat roost wakes up, bites, and dies to the pickaxe.
func _camps() -> void:
	w.ensure_generated(int(300 * World.METER))
	var crates := []
	var notes := []
	for n in w.get_children():
		if n is CampItems.LootCrate:
			crates.append(n)
		elif n is CampItems.Note:
			notes.append(n)
	_check("ruined camps are generated", crates.size() > 0 and notes.size() > 0,
		"%d crates, %d notes" % [crates.size(), notes.size()])
	if crates.is_empty() or notes.is_empty():
		return
	var v := p.ore_value
	crates[0].interact(p)
	var v2 := p.ore_value
	crates[0].interact(p)
	_check("a crate pays out once", v2 > v and p.ore_value == v2, "$%d -> $%d" % [v, v2])
	var nid: int = notes[0].note_id
	notes[0].interact(p)
	await _frames(2)
	_check("reading a note remembers it", Progress.found_notes.has(nid) and main.menus.note_view.visible)
	main.menus.note_view.visible = false
	get_tree().paused = false
	# bats
	_arena(340)
	p.heal_full()
	p.global_position = Vector2(64 * World.CELL, 340 * World.CELL - 19)
	await _frames(60)
	var b := Bat.new()
	b.world = w
	b.glow_parent = main.glow_layer
	b.position = p.global_position + Vector2(40, -70)
	main.add_child(b)
	var hp := p.health
	for i in 60 * 6:
		await get_tree().physics_frame
		if p.health < hp:
			break
	_check("a bat wakes and bites", b.state != Bat.State.HANG and p.health < hp, "hp %d -> %d" % [hp, p.health])
	b.hit(1, p.global_position)
	_check("one hit kills a bat", b.state == Bat.State.DEAD)
	p.heal_full()


## Water pours out of a pocket you open, swims / takes your breath; water meets lava -> rock.
func _liquids() -> void:
	w.ensure_generated(420 * World.CELL)
	_arena(400)                                   # open room, floor at row 400
	var liq: Liquids = main.liquids
	# a water tank: cells x 40..47, rows 392..399, walled off on the right by a rock column
	for gy in range(388, 400):
		w.place_rock(48, gy, World.M.STONE)
		for gx in range(40, 48):
			liq.pour(gx, gy, 1.0, Liquids.WATER)
	w._flush()
	p.global_position = Vector2(56 * World.CELL, 400 * World.CELL - 19)
	p.heal_full()
	await _frames(20)
	var before := w.get_liquid(52, 399)
	for gy in range(388, 400):                    # knock the wall down
		w.dig(Vector2(48 * World.CELL + 4, gy * World.CELL + 4), Vector2(48 * World.CELL + 4, gy * World.CELL + 4), 3.0, 50.0)
	await _frames(60 * 3)
	_check("opened water pours out across the floor", w.get_liquid(52, 399) > before + 0.1,
		"%.2f -> %.2f" % [before, w.get_liquid(52, 399)])
	# dunk the miner: fill a column over him
	for gy in range(392, 400):
		for gx in range(54, 60):
			liq.pour(gx, gy, 1.0, Liquids.WATER)
	p.global_position = Vector2(57 * World.CELL, 398 * World.CELL)
	await _frames(30)
	_check("in the water", p.in_water)
	var b0 := p.breath
	await _frames(60)
	_check("underwater uses up breath", p.breath < b0, "%.1f -> %.1f" % [b0, p.breath])
	# lava next to water
	_arena(430)
	for gx in range(60, 64):
		liq.pour(gx, 429, 1.0, Liquids.LAVA)
	for gy in range(424, 428):
		liq.pour(61, gy, 1.0, Liquids.WATER)
	w._flush()
	p.global_position = Vector2(40 * World.CELL, 430 * World.CELL - 19)
	var reacted := [false]
	liq.reacted.connect(func(_pos): reacted[0] = true)
	await _frames(60 * 2)
	_check("water poured on lava hisses into rock", reacted[0] and w.get_fill(61, 429) >= 0.5)
	p.heal_full()
	await _frames(70)
	var hp := p.health
	for gx in range(36, 44):
		liq.pour(gx, 429, 1.0, Liquids.LAVA)
	await _frames(30)
	_check("lava burns", p.health < hp, "hp %d -> %d" % [hp, p.health])
	for gy in range(380, 440):                   # tidy up for the next test
		for gx in range(2, World.W - 2):
			if w.get_liquid(gx, gy) > 0.0:
				w.set_liquid(gx, gy, 0.0, Liquids.NONE)
	p.heal_full()


## Firedamp: pockets are generated; dug open they leak a cloud; a spark sets it off.
func _gas() -> void:
	_check("firedamp pockets are generated", w.gas.size() > 0, "%d cells" % w.gas.size())
	_arena(450)
	p.heal_full()
	p.global_position = Vector2(50 * World.CELL, 450 * World.CELL - 19)
	await _frames(70)
	for old in get_tree().get_nodes_in_group("gas"):     # clouds from earlier digging
		old.remove_from_group("gas")
		old.queue_free()
	var at := Vector2(70 * World.CELL + 4, 446 * World.CELL + 4)     # the cell's centre
	w.place_rock(70, 446, World.M.STONE)
	w.gas[Vector2i(70, 446)] = true
	w._flush()
	w.dig(at, at, 3.0, 50.0)                      # dig it open: the gas leaks out
	await _frames(5)
	var clouds := get_tree().get_nodes_in_group("gas")
	_check("digging into a pocket releases gas", clouds.size() == 1)
	p.global_position = at + Vector2(-20, 4)
	await _frames(10)
	var hp := p.health
	GasCloud.spark(get_tree(), at + Vector2(5, 0))
	await _frames(5)
	_check("a spark sets it off", get_tree().get_nodes_in_group("gas").is_empty() and p.health < hp,
		"hp %d -> %d" % [hp, p.health])
	_check("the blast digs a crater", w.is_air(at + Vector2(0, 16)))
	p.heal_full()


## A breached drill sitting in water floods; patched, the pump drains it.
func _flooding() -> void:
	var d: Drill = main.drill
	for b in d.get_breaches():
		d.repair(b)
	await _frames(2)
	d.damage(5.0, d.global_position + Vector2(-40, 0))
	# water against the hull on both sides at breach height
	var c := w.cell_at(d.global_position + Vector2(-Drill.HW - 14.0, 10))
	var c2 := w.cell_at(d.global_position + Vector2(Drill.HW + 14.0, 10))
	for k in [c, c2]:
		for dy in range(-6, 6):
			w.set_liquid(k.x, k.y + dy, 1.0, Liquids.WATER)
	await _frames(60 * 4)
	_check("a breach under water floods the cabin", d.flooding.level > 0.05 and d.flooding.leaking > 0,
		"level %.2f" % d.flooding.level)
	d.flooding.level = 0.8
	await _frames(2)
	_check("the crew swims in a flooded cabin", p.in_water)
	for b in d.get_breaches():
		d.repair(b)
	var lv := d.flooding.level
	await _frames(60 * 2)
	_check("patched, the pump drains it", d.flooding.level < lv, "%.2f -> %.2f" % [lv, d.flooding.level])
	d.flooding.level = 0.0
	for k in [c, c2]:
		for dy in range(-6, 6):
			w.set_liquid(k.x, k.y + dy, 0.0, Liquids.NONE)


## Local co-op: Start on a controller adds player two, who moves on their own; the camera frames
## both; a downed player comes back in the drill while the other plays on.
func _coop() -> void:
	var d: Drill = main.drill
	p.global_position = d.global_position + Vector2(-30, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	p.heal_full()
	await _frames(10)
	var start := InputEventJoypadButton.new()
	start.button_index = JOY_BUTTON_START
	start.device = 0
	start.pressed = true
	Input.parse_input_event(start)
	await _frames(5)
	_check("Start on a controller adds player two", main.players.size() == 2)
	if main.players.size() < 2:
		return
	var p2: Player = main.players[1]
	var x1 := p.global_position.x
	var x2 := p2.global_position.x
	Input.action_press("p2_right")
	await _frames(30)
	Input.action_release("p2_right")
	_check("player two moves on their own", p2.global_position.x > x2 + 10.0 and absf(p.global_position.x - x1) < 1.0)
	_check("the camera frames both", main.cam.get_parent() == main)
	p2.hurt(99, p2.global_position + Vector2(10, 0))
	await _frames(5)
	_check("a downed player waits while the other plays on", not main.run_over and p2.frozen)
	await get_tree().create_timer(8.5).timeout
	_check("and comes back in the drill", p2.health > 0 and d.contains(p2.global_position))
	main.players.erase(p2)
	p2.queue_free()


## The bottom: the Floor can't be cut; the drill knocking on it wakes the Eye; veins shield it;
## break them, kill it, and the run ends with the ending.
func _the_bottom() -> void:
	var d: Drill = main.drill
	w.ensure_generated(World.BOTTOM * World.METER + 400.0)
	for i in 30:
		await _frames(1)
		if main.eye:
			break
	var eye: TheEye = main.eye
	_check("the Eye is waiting in the Floor", eye != null and eye.state == TheEye.State.ASLEEP)
	if eye == null:
		return
	var floor_y := eye.position.y
	var probe := Vector2(World.WIDTH_PX / 2.0, floor_y + 12.0)
	w.dig(probe, probe, 10.0, 999.0)
	_check("the Floor can't be cut", not w.is_air(probe))
	d.position = Vector2(World.WIDTH_PX / 2.0, floor_y - 107.0)
	p.global_position = d.global_position + Vector2(-20, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	d.speed = Drill.Speed.FULL
	for i in 60 * 4:
		await get_tree().physics_frame
		if eye.state != TheEye.State.ASLEEP:
			break
	_check("knocking on the Floor wakes it", eye.state != TheEye.State.ASLEEP)
	d.speed = Drill.Speed.STOP
	await _frames(60 * 3)
	var hp := eye.hp
	eye.hit(10, Vector2.ZERO)
	_check("the veins shield it", eye.hp == hp and eye.state == TheEye.State.GUARDED)
	for v in eye.veins:
		v.hit(99, Vector2.ZERO)
	await _frames(5)
	_check("with the veins broken it opens", eye.state == TheEye.State.OPEN)
	var ended := [false]
	eye.died.connect(func(_pos): ended[0] = true)
	for i in 30:
		eye.hit(3, Vector2.ZERO)
	await get_tree().create_timer(5.5).timeout
	_check("killing it ends the run", ended[0] and main.ending)


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
	# a roll: fast, and nothing hurts you while rolling
	await _frames(60)                     # (the last swing finishes, the hit's grace period ends)
	var x0 := p.global_position.x
	var hp2 := p.health
	Input.action_press("roll")
	await _frames(2)
	Input.action_release("roll")
	_check("rolling", p.is_rolling())
	p.hurt(1, p.global_position + Vector2(20, 0))
	_check("can't be hurt mid-roll", p.health == hp2)
	await _frames(25)
	_check("a roll covers ground", absf(p.global_position.x - x0) > 40.0, "%.0f px" % absf(p.global_position.x - x0))


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
