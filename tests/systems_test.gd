extends Node
## Headless end-to-end check of the game systems: the drill (descending with the crew inside,
## furnace, workbench + shop, breaches and repairs), the grapple, a crawler fight and a
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
	_calm()
	await _furnace_and_workbench()
	_calm()
	await _breach()
	_calm()
	await _heat()
	_calm()
	await _flooding()
	_calm()
	await _ship_systems()
	_calm()
	await _gear()
	_calm()
	await _jobs_and_quakes()
	_calm()
	await _deep_things()
	_calm()
	_layers()
	await _sonar_and_worm()
	_calm()
	await _mouse_aim()
	_calm()
	await _shaft_climb()
	_calm()
	await _camps()
	_calm()
	await _liquids()
	_calm()
	await _gas()
	_calm()
	await _crawler_fight()
	_calm()
	await _coop()
	_calm()
	await _the_bottom()
	_calm()
	await _boulder()
	Progress.money = saved_money
	Progress.levels = saved_levels
	print("RESULT: ", "ALL PASS" if fails == 0 else "%d FAILED" % fails)
	get_tree().quit()


## Between sections: no fires burning, fuses whole, the drill cool and patched, so one
## section's mishaps (a fire, a blown fuse) don't spill into the next.
func _calm() -> void:
	var d: Drill = main.drill
	for f in d.fires.fires():
		f.free()
	d.power.blown = [false, false]
	d.power.output = DrillPower.Output.NORMAL
	d.thermal.heat = 0.0
	d.thermal.overheated = false
	d.hull = d.max_hull


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
	p.global_position = d.global_position + Vector2(Drill.HW + 20.0, Drill.FLOOR + 30.0)   # outside, below the door
	p.velocity = Vector2.ZERO
	await _frames(40)
	p.tools.index = PlayerTools.ALL.find("grapple")
	p.aim_override = d.global_position + Vector2(Drill.HW - 2.0, Drill.FLOOR - 20.0)
	await _hold(["tool"], 0.05)
	await _frames(60)
	p.aim_override = Vector2.INF
	_check("grappling the hull climbs back in at the door", d.contains(p.global_position), str(p.global_position - d.global_position))
	p.global_position = back
	p.velocity = Vector2.ZERO
	await _frames(10)
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
	for band: float in [200.0, 350.0, 460.0]:
		var c := {}
		for i in 400:
			var px := randf_range(40.0, World.WIDTH_PX - 40.0)
			var mat := w.gen.material(px, band * World.METER + randf_range(-60, 60), band)
			c[mat] = c.get(mat, 0) + 1
		counts[band] = c
	_check("crystal caverns around 200 m", counts[200.0].get(World.M.CRYSTAL, 0) > 200, str(counts[200.0]))
	_check("magma layer around 460 m", counts[460.0].get(World.M.MAGMA, 0) > 200, str(counts[460.0]))
	_check("the ice layer around 350 m", counts[350.0].get(World.M.ICE, 0) > 200, str(counts[350.0]))
	var fungal := 0
	for i in 200:
		var px := randf_range(40.0, World.WIDTH_PX - 40.0)
		fungal += int(w.gen.fungal(px, 100.0 * World.METER, 100.0))
	_check("fungal caves around 100 m", fungal > 150, "%d / 200" % fungal)


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
	d.power.blown = [false, false]          # (its ram may have blown a fuse: the turrets need power)
	_station(Stations.GunnerSeat).interact(p)
	await _frames(20)
	_check("gunner seat takes the turrets", d.guns.gunner == p and p.frozen)
	Input.action_press("dig")
	for i in 60 * 25:
		if not is_instance_valid(w) or w.state == Worm.State.DEAD:
			break
		p.aim_override = w.body[0]
		d.power.blown = [false, false]      # (the crew would be on the fuse box; here we're testing the guns)
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


func _shaft_climb() -> void:
	for b in get_tree().get_nodes_in_group("hittable"):   # a boulder dropping into the test shaft
		if b is Boulder:                                   # would wedge above the miner (as it should)
			b.queue_free()
	p.global_position = Vector2(200, -40)       # well away from the drill
	await _frames(60)
	for i in 120:
		if p.is_on_floor():
			break
		await get_tree().physics_frame
	var ground := p.global_position.y
	await _hold(["dig", "down"], 6.0)
	var depth := p.global_position.y / World.METER
	_check("dug down a shaft", depth > 3.0, "%.1f m" % depth)
	p.tools.index = PlayerTools.ALL.find("grapple")
	var hooks := 0
	for i in 20:                                 # hook the shaft wall up high, again and again
		var side := 1.0 if i % 2 == 0 else -1.0
		p.aim_override = p.global_position + Vector2(side * 10.0, -120.0)
		await _hold(["tool"], 0.05)
		if p.tools.grapple_at != Vector2.INF:
			hooks += 1
		await get_tree().create_timer(PlayerTools.GRAPPLE_COOLDOWN + 0.2).timeout
		if p.global_position.y < ground + 30.0:
			break
	p.aim_override = Vector2.INF
	_check("the grapple gets you out of the shaft", p.global_position.y < ground + 30.0 and hooks > 0,
		"y=%.0f after %d hooks, ground was %.0f" % [p.global_position.y, hooks, ground])
	await _frames(30)
	_check("standing on the surface", p.is_on_floor(), "y=%.0f" % p.global_position.y)


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
	_check("each miner wears their own colour", p.crew_color() != p2.crew_color())
	Input.action_press("ping")
	await _frames(2)
	Input.action_release("ping")
	_check("a ping marks the spot for the crew", get_tree().get_nodes_in_group("ping_1").size() == 1)
	p2.hurt(99, p2.global_position + Vector2(10, 0))
	await _frames(5)
	_check("a downed player waits for help while the other plays on", not main.run_over and p2.downed)
	p.global_position = p2.global_position + Vector2(-12, 0)
	await _frames(3)
	_check("the crewmate is told to help them up", p.interactor.prompt_text().begins_with("Hold E: help"),
		p.interactor.prompt_text())
	Input.action_press("interact")
	await get_tree().create_timer(ReviveSpot.HOLD + 0.3).timeout
	Input.action_release("interact")
	_check("holding E helps them back up", not p2.downed and p2.health == 1)
	p2._invuln_t = 0.0
	p2.hurt(99, p2.global_position + Vector2(10, 0))
	await _frames(3)
	p.global_position = p2.global_position + Vector2(-12, 0)
	await _frames(3)
	await _hold(["interact"], 0.1)                # a tap, not a hold
	await _frames(3)
	_check("a tap hoists them onto your shoulders", p.carrying == p2 and p2.carried_by == p)
	var med: Stations.Medkit = _station(Stations.Medkit)
	p.global_position = d.global_position + Vector2(med.position.x + 4, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	await _frames(5)
	_check("they ride along", p2.global_position.distance_to(p.global_position) < 40.0)
	_check("the medkit offers to patch them up", p.interactor.prompt_text().begins_with("E: patch up"),
		p.interactor.prompt_text())
	await _hold(["interact"], 0.1)
	await _frames(3)
	_check("and does", not p2.downed and p2.health == p2.max_health and p.carrying == null)
	p2._invuln_t = 0.0                    # (just helped up: a moment's grace)
	p2.hurt(99, p2.global_position + Vector2(10, 0))
	await _frames(3)
	p2.bleed = 0.05                       # (nobody comes this time)
	await _frames(5)
	_check("nobody helped: they bled out", not p2.downed and not p2.visible)
	await get_tree().create_timer(8.5).timeout
	_check("and come back in the drill", p2.health > 0 and d.contains(p2.global_position))
	main.players.erase(p2)
	p2.queue_free()


## The ship: power (a blown fuse, a brownout, the generator), fire (beaten out, sprayed),
## and the modules (cargo hold, sprinklers, the drone).
func _ship_systems() -> void:
	var d: Drill = main.drill
	p.heal_full()
	d.power.blow(1)
	for f in d.fires.fires():           # (a sparking box can start a fire, which would come first)
		f.free()
	_check("a blown fuse cuts the helm", _station(Stations.Helm).prompt(p).begins_with("Helm: no power"))
	p.global_position = d.global_position + Vector2(Junction.X[1] - 4, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	await _frames(4)
	_check("the crew is told to fix it", p.interactor.prompt_text().begins_with("Hold E: replace"),
		p.interactor.prompt_text())
	await _hold(["interact"], Junction.REPAIR_TIME + 0.4)
	_check("holding E puts in a new fuse", not d.power.blown[1], "prompt \"%s\" at %s role %s" % [p.interactor.prompt_text(), p.global_position - d.global_position, p.role])
	d.power.output = DrillPower.Output.LOW
	d.speed = Drill.Speed.FULL
	await _frames(10)
	_check("full speed on low power browns out", d.power.ratio() < 1.0, "%.2f" % d.power.ratio())
	d.speed = Drill.Speed.STOP
	p.coal = 0
	_station(Stations.Furnace).interact(p)
	_check("the furnace turns the generator up", d.power.output == DrillPower.Output.NORMAL)
	# fire
	d.fires.ignite(-20.0, 0.5)
	await _frames(5)
	_check("a fire burns in the cabin", d.fires.fires().size() == 1)
	var hull0 := d.hull
	await _frames(60)
	_check("fire eats the hull", d.hull < hull0, "%.1f -> %.1f" % [hull0, d.hull])
	p.global_position = d.global_position + Vector2(-34, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	await _frames(3)
	_check("the crew can beat it out", p.interactor.prompt_text().begins_with("Hold E: beat"), p.interactor.prompt_text())
	await _hold(["interact"], 3.5)
	_check("beating it puts it out", d.fires.fires().is_empty())
	d.fires.ignite(30.0, 0.9)
	p.global_position = d.global_position + Vector2(-5, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	p.tools.index = PlayerTools.ALL.find("extinguisher")
	p.aim_override = d.global_position + Vector2(30, Drill.FLOOR - 8)
	await _hold(["tool"], 1.5)
	p.aim_override = Vector2.INF
	_check("the extinguisher sprays it out", d.fires.fires().is_empty())
	p.tools.index = 0
	# modules
	Progress.levels["cargo"] = 1
	Progress.levels["sprinklers"] = 1
	Progress.levels["drone"] = 1
	d.apply_upgrades()
	w.ore_ground.emit(d.global_position + Vector2(0, 90), 2)
	_check("the cargo hold keeps the ore the head grinds", d.cargo_value == World.ORES[2][1], str(d.cargo_value))
	var money := Progress.money
	_station(Stations.Workbench).interact(p)
	main.shop.close()
	_check("and it sells at the workbench", d.cargo_value == 0 and Progress.money > money)
	d.fires.ignite(40.0, 0.5)
	await get_tree().create_timer(2.5).timeout
	_check("sprinklers douse a fire", d.fires.fires().is_empty())
	await _frames(20)
	var bat := Bat.new()
	bat.world = w
	bat.position = d.global_position + Vector2(60, Drill.TOP - 40)
	main.add_child(bat)
	bat.state = Bat.State.PEEL
	bat._t = 99.0
	await get_tree().create_timer(3.0).timeout
	_check("the drone zaps a bat by the drill", not is_instance_valid(bat) or bat.state == Bat.State.DEAD)
	for m in ["cargo", "sprinklers", "drone"]:
		Progress.levels.erase(m)


## Gear outside: switching tools, a flare that creatures shy from, dynamite, the grapple; and
## the bag filling up.
func _gear() -> void:
	var d: Drill = main.drill
	var spot := Vector2(d.global_position.x - 330.0, -40.0)
	while w.is_air(spot + Vector2(0, Player.HALF_HEIGHT + 2.0)):
		spot.y += 2.0
	p.global_position = spot + Vector2(0, -2)
	p.velocity = Vector2.ZERO
	await _frames(20)
	p.tools.index = 0
	Input.action_press("tool_next")
	await _frames(2)
	Input.action_release("tool_next")
	_check("Tab switches tools", p.tools.current() == "flare")
	p.aim_override = p.global_position + Vector2(80, -10)
	await _hold(["tool"], 0.05)
	await get_tree().create_timer(1.5).timeout
	var flares := get_tree().get_nodes_in_group("flare")
	_check("a thrown flare lands and burns", flares.size() == 1 and flares[0].resting)
	if flares.size() == 1:
		var c := Crawler.new()
		c.world = w
		c.player = p
		c.glow_parent = main.glow_layer
		c.position = flares[0].global_position + Vector2(40, -10)
		main.add_child(c)
		var x0 := c.global_position.x
		await get_tree().create_timer(1.0).timeout
		_check("creatures back away from a flare", c.global_position.x > x0 + 10.0, "%.0f -> %.0f" % [x0, c.global_position.x])
		c.queue_free()
		flares[0].queue_free()
	p.tools.index = PlayerTools.ALL.find("dynamite")
	p.aim_override = p.global_position + Vector2(60, 10)
	await _hold(["tool"], 0.05)
	await _frames(30)
	var sticks := get_tree().get_nodes_in_group("dynamite")
	var at: Vector2 = sticks[0].global_position if sticks.size() > 0 else Vector2.ZERO
	p.global_position = spot + Vector2(-140, -2)               # stand clear
	await get_tree().create_timer(Thrown.FUSE + 0.3).timeout
	_check("dynamite blows a crater", sticks.size() == 1 and w.is_air(at + Vector2(0, 16)), str(at))
	# grapple: from the bottom of a shaft, at the rock up the side
	var shaft := spot + Vector2(-60, 0)
	w.dig(shaft, shaft + Vector2(0, 110), 12.0, 99.0)
	p.global_position = shaft + Vector2(0, 100)
	p.velocity = Vector2.ZERO
	await _frames(20)
	var y0 := p.global_position.y
	p.tools.index = PlayerTools.ALL.find("grapple")
	p.aim_override = p.global_position + Vector2(14, -55)
	await _hold(["tool"], 0.05)
	await _frames(25)
	_check("the grapple hauls you up the shaft", p.global_position.y < y0 - 24.0, "%.0f -> %.0f" % [y0, p.global_position.y])
	_check("and you hang there (no ledge)", p.tools.hanging or p.global_position.y < spot.y)
	await _hold(["jump"], 0.05)
	await _frames(5)
	_check("jump lets go", not p.tools.hanging)
	p.aim_override = Vector2.INF
	p.tools.index = 0
	# the bag holds so much (more for a miner, more with the sled)
	p.ore_count = 0
	p.coal = 0
	p.role = "engineer"
	var room := p.bag_space()
	p.role = "miner"
	_check("a miner carries more", p.bag_space() == room + 10)
	p.ore_count = p.bag_space() + p.ore_count
	_check("a full bag takes no more", not p.add_ore(0))
	p.ore_count = 0
	p.global_position = d.global_position + Vector2(-30, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	await _frames(10)


## Radio jobs (sell, hunt, rescue a trapped miner) and a quake.
func _jobs_and_quakes() -> void:
	var d: Drill = main.drill
	var c: Contracts = main.contracts
	c.jobs.clear()
	var money := Progress.money
	c._offer()
	_check("the radio brings a job", c.jobs.size() == 1, str(c.jobs))
	for j in c.jobs:
		if j.kind == "rescue":
			j.survivor.queue_free()
	c.jobs.clear()
	c.jobs.append({"kind": "sell", "text": "Sell", "goal": 20, "base": c._sold(), "reward": 12, "until": 9999.0})
	c.jobs.append({"kind": "hunt", "text": "Hunt", "goal": 4, "base": main.kills, "reward": 24, "until": 9999.0})
	p.sold_value += 999
	main.kills += 99
	await _frames(3)
	_check("selling and hunting finish them", c.jobs.is_empty() and Progress.money > money, str(c.jobs.size()))
	p.sold_value -= 999
	var s: Survivor = c._place_survivor(d.global_position.y / World.METER + 40.0)
	_check("a trapped miner is placed in a cave below", s != null)
	if s:
		c.jobs.append({"kind": "rescue", "text": "Rescue", "goal": 1, "base": 0, "survivor": s, "reward": 10,
			"until": 9999.0})
		p.global_position = s.global_position + Vector2(-12, 0)
		await _frames(4)
		_check("they can be carried", p.interactor.prompt_text().begins_with("Tap E: carry"), p.interactor.prompt_text())
		await _hold(["interact"], 0.1)
		await _frames(3)
		_check("and are", p.carrying == s)
		p.global_position = d.global_position + Vector2(-30, Drill.FLOOR - Player.HALF_HEIGHT - 1)
		await _frames(5)
		_check("carried into the drill, they're rescued", not is_instance_valid(s) or s.is_queued_for_deletion())
		_check("and your hands are free again", p.carrying == null)
	# a quake: a tunnel near the miner fills back in, and the shaft above the drill caves in
	var t := d.global_position + Vector2(-300, 200)
	w.dig(t, t + Vector2(120, 0), 14.0, 99.0)
	p.global_position = t + Vector2(-140, 0)
	var open_before := 0
	for x in range(0, 120, 8):
		open_before += int(w.is_air(t + Vector2(x, 0)))
	var shaft := d.global_position + Vector2(0, Drill.TOP - 135.0)
	main.quakes.quake()
	var open_after := 0
	for x in range(0, 120, 8):
		open_after += int(w.is_air(t + Vector2(x, 0)))
	_check("a quake fills tunnels back in", open_after < open_before, "%d -> %d open" % [open_before, open_after])
	var blocked := 0
	for dy in range(-50, 50, 4):
		blocked += int(not w.is_air(shaft + Vector2(0, dy)))
	_check("and caves in the shaft above the drill", blocked > 0)
	p.global_position = d.global_position + Vector2(-30, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	await _frames(10)


## Deeper things: ice underfoot, ruins with relics, a mite swarm, a borer breaking in, and the
## Broodmother.
func _deep_things() -> void:
	var d: Drill = main.drill
	# ice is slippery: you slide further when you let go
	var slide := {}
	for mat in [World.M.STONE, World.M.ICE]:
		_arena(40)
		for gy in range(40, 42):
			for gx in range(30, 98):
				var ch: World.Chunk = w.chunks.get(Vector2i(gx >> 5, gy >> 5))
				ch.mat[(gy & 31) * World.C + (gx & 31)] = mat
		p.global_position = Vector2(300, 40 * World.CELL - Player.HALF_HEIGHT - 1)
		p.velocity = Vector2.ZERO
		await _frames(10)
		await _hold(["right"], 0.6)
		var x0 := p.global_position.x
		await _frames(40)
		slide[mat] = p.global_position.x - x0
	_check("ice is slippery", slide[World.M.ICE] > slide[World.M.STONE] + 8.0, str(slide))
	# ruins
	w.ensure_generated(int(575 * World.METER))
	var relics := get_tree().get_nodes_in_group("net").filter(func(n): return n is CampItems.Relic)
	_check("ancient halls with relics deep down", relics.size() > 0, "%d relics" % relics.size())
	if relics.size() > 0:
		var money := p.ore_value
		relics[0].interact(p)
		_check("a relic is worth a lot", p.ore_value >= money + 30)
		p.lose_bag()
	# mites
	_arena(40)
	p.global_position = Vector2(300, 40 * World.CELL - Player.HALF_HEIGHT - 1)
	p.heal_full()
	await _frames(10)
	var mites := []
	for i in 3:
		var m := Mite.new()
		m.world = w
		m.glow_parent = main.glow_layer
		m.position = p.global_position + Vector2(90 + i * 8, 10)
		main.add_child(m)
		mites.append(m)
	await get_tree().create_timer(2.5).timeout
	_check("a mite swarm bites", p.health < p.max_health, "hp %d" % p.health)
	mites[0].hit(1, p.global_position)
	_check("one hit kills a mite", mites[0].state == Mite.State.DEAD)
	for m in mites:
		if is_instance_valid(m):
			m.queue_free()
	# a borer tunnels to the drill and breaks in
	p.global_position = d.global_position + Vector2(-30, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	p.heal_full()
	for b in d.get_breaches():
		d.repair(b)
	await _frames(3)
	var bo: Borer = main.spawner.spawn_borer()
	bo.global_position = d.global_position + Vector2(Drill.HW + 70.0, 20.0)
	for i in 60 * 10:
		await get_tree().physics_frame
		if bo.state == Borer.State.INSIDE:
			break
	_check("a borer chews through the hull and gets in", bo.state == Borer.State.INSIDE and d.get_breaches().size() > 0,
		"state %d" % bo.state)
	bo.hit(99, p.global_position)
	_check("and dies to the pick", bo.state == Borer.State.DEAD)
	for b in d.get_breaches():
		d.repair(b)
	# the Broodmother
	var bm: Broodmother = main.spawner.spawn_brood()
	_check("the Broodmother's lair opens below the drill", bm != null and w.is_air(bm.global_position + Vector2(0, -40)))
	p.global_position = bm.global_position + Vector2(-150, -30)
	await _frames(20)
	_check("she wakes when someone comes near", bm.is_awake())
	var money := Progress.money
	bm.hit(Broodmother.HP, p.global_position)
	await _frames(5)
	_check("killing her pays the crew", bm.state == Broodmother.State.DEAD and Progress.money >= money + Broodmother.REWARD)
	for m in get_tree().get_nodes_in_group("mite"):
		m.queue_free()
	p.global_position = d.global_position + Vector2(-30, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	p.heal_full()
	await _frames(10)


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
