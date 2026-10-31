extends Node
## Online co-op, end to end: two real game processes on this machine. One hosts (and judges),
## the other joins over localhost; the host acts, then asks the client what it sees.
##   tests/net_test.sh   (runs both headless and reports)
## or by hand:
##   godot --headless --path . res://tests/net_test.tscn -- --role=host --port=24711
##   godot --headless --path . res://tests/net_test.tscn -- --role=client --port=24711
##   (a second client with --delay=20 joins mid-run: it must get everything changed so far)
## Without --headless (e.g. under xvfb-run) with --shots=DIR, the client saves what it sees.
## The driver lives on the scene tree's root, so it survives the scene changes of joining and
## restarting.


func _ready() -> void:
	var d := Driver.new()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			d.role = a.trim_prefix("--role=")
		elif a.begins_with("--port="):
			d.port = int(a.trim_prefix("--port="))
		elif a.begins_with("--delay="):
			d.delay = float(a.trim_prefix("--delay="))
		elif a.begins_with("--shots="):
			d.shots = a.trim_prefix("--shots=")
	get_tree().root.add_child.call_deferred(d)


class Driver extends Node:
	const MAIN := "res://src/main.tscn"
	var role := "host"
	var port := 24711
	var delay := 0.5               # client: seconds before joining
	var shots := ""                # where to save screenshots ("" = none)
	var fails := 0
	var _replies := {}
	var _step := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		Progress.dry_run = true
		World.fixed_seed = 7
		Net.message.connect(_on_message)
		if role == "host":
			_host.call_deferred()
		else:
			_client.call_deferred()

	func main() -> Node:
		return get_tree().current_scene

	func _check(name: String, ok: bool, info := "") -> void:
		print(("PASS  " if ok else "FAIL  ") + name + ("  (" + info + ")" if info != "" else ""))
		if not ok:
			fails += 1

	func _wait(sec: float) -> void:
		await get_tree().create_timer(sec).timeout

	func _until(cond: Callable, timeout: float) -> bool:
		var t := 0.0
		while t < timeout:
			if cond.call():
				return true
			await get_tree().process_frame
			t += get_process_delta_time()
		return false

	# ------------------------------------------------------------ host: acts and judges

	func _host() -> void:
		var err := Net.host(port)
		if err != OK:
			_check("hosting", false)
			_finish()
			return
		_check("hosting", err == OK)
		get_tree().change_scene_to_file(MAIN)
		await _until(func(): return main() != null and main().get("session") != null, 10.0)
		_check("the run is online", main().session != null)
		var joined := await _until(func(): return main().players.size() == 2, 30.0)
		_check("a client joined the crew", joined)
		if not joined:
			_finish()
			return
		var m := main()
		var remote: Player = m.players[1]
		await _wait(1.0)
		var seed: int = await _ask("seed")
		_check("same world seed", seed == m.world.seed, "%d / %d" % [seed, m.world.seed])
		var start_cs := _checksum(Rect2i(0, -16, World.W, 80))
		var their_start: Array = await _ask("cells", [0, -16, World.W, 80])
		_check("same generated ground", their_start == start_cs, "%s / %s" % [their_start, start_cs])

		# the host digs: the client's ground changes the same way
		var hole: Vector2 = m.drill.global_position + Vector2(-260, 120)
		m.world.dig(hole, hole + Vector2(0, 40), 24.0, 99.0)
		await _wait(0.6)
		await _compare_cells("a hole dug on the host shows up", Rect2i(m.world.cell_at(hole) - Vector2i(6, 6), Vector2i(13, 20)))

		# the drill bores down: same place, same state, same shaft
		var y0: float = m.drill.global_position.y
		m.drill.speed = Drill.Speed.FULL
		await _wait(8.0)
		m.drill.speed = Drill.Speed.STOP
		await _wait(1.0)
		var dr: Array = await _ask("drill")
		_check("the drill is in the same place", (dr[0] as Vector2).distance_to(m.drill.global_position) < 3.0,
			"%s / %s" % [dr[0], m.drill.global_position])
		_check("the drill went down", m.drill.global_position.y > y0 + 24.0, "%.0f -> %.0f" % [y0, m.drill.global_position.y])
		_check("same drill state", dr[1] == m.drill.speed and absf(dr[2] - m.drill.hull) < 0.5)
		var dc: Vector2i = m.world.cell_at(m.drill.global_position)
		await _compare_cells("the shaft it bored is the same", Rect2i(dc.x - 16, dc.y - 10, 32, 28))

		# the client's miner moves by their controls (simulated here, shown there)
		var x0 := remote.global_position.x
		await _ask("press", ["left", 0.5])
		await _wait(0.4)
		_check("the client's controls move their miner", remote.global_position.x < x0 - 20.0,
			"%.0f -> %.0f" % [x0, remote.global_position.x])
		var where: Array = await _ask("players")
		var host_where := []
		for p: Player in m.players:
			host_where.append(p.global_position)
		var same := where.size() == host_where.size()
		for i in mini(where.size(), host_where.size()):
			same = same and (where[i] as Vector2).distance_to(host_where[i]) < 6.0
		_check("everyone sees the miners in the same places", same, "%s / %s" % [where, host_where])

		# their pickaxe digs the host's world (out on the open ground, away from the drill)
		var gx: float = m.drill.global_position.x + 300.0
		var gy := -40.0
		while m.world.is_air(Vector2(gx, gy + Player.HALF_HEIGHT + 2.0)):
			gy += 2.0
		remote.global_position = Vector2(gx, gy - 2.0)
		remote.velocity = Vector2.ZERO
		await _wait(0.6)
		var feet := remote.global_position + Vector2(0, Player.HALF_HEIGHT + 6)
		var before: float = m.world.get_fill(m.world.cell_at(feet).x, m.world.cell_at(feet).y)
		await _ask("dig_down", 1.6)
		await _wait(0.5)
		var rc: Vector2i = m.world.cell_at(remote.global_position)
		var dug: bool = m.world.dug.keys().any(func(c: Vector2i): return absi(c.x - rc.x) < 4 and c.y > rc.y)
		_check("the client's pickaxe digs", dug, "fill under them was %.2f" % before)
		await _compare_cells("and both see the same hole", Rect2i(rc.x - 8, rc.y - 6, 16, 18))

		# creatures exist once, on the host, and show on the client
		var c := Crawler.new()
		c.world = m.world
		c.player = remote
		c.glow_parent = m.glow_layer
		c.position = remote.global_position + Vector2(140, -20)
		m.add_child(c)
		await _wait(0.6)
		var counts: Array = await _ask("count")
		_check("a crawler on the host shows on the client", counts[0] == get_tree().get_nodes_in_group("creature").size()
			and counts[0] > 0, "%s" % [counts])
		c.queue_free()

		# liquid poured on the host flows on the client too
		var wpos: Vector2i = m.world.cell_at(hole + Vector2(0, 30))
		for i in 6:
			m.liquids.pour(wpos.x + i - 3, wpos.y, 1.0, Liquids.WATER)
		await _wait(1.5)
		await _compare_cells("water flows the same", Rect2i(wpos.x - 10, wpos.y - 8, 20, 22))

		await _ask("shot", "client_water")

		# someone joins mid-run: they get every chunk changed so far, and the crew as it is
		var three: bool = await _until(func(): return main().players.size() == 3, 40.0)
		_check("a second client joins mid-run", three)
		if three:
			var late: int = m.players[2].peer
			await _wait(1.5)
			var r: Rect2i = Rect2i(m.world.cell_at(hole) - Vector2i(10, 8), Vector2i(20, 30))
			_check("the late joiner gets the ground dug before they came",
				await _ask("cells", [r.position.x, r.position.y, r.size.x, r.size.y], late) == _checksum(r))
			var sc: Vector2i = m.world.cell_at(m.drill.global_position)
			r = Rect2i(sc.x - 16, sc.y - 10, 32, 28)
			_check("and the drill's shaft", await _ask("cells", [r.position.x, r.position.y, r.size.x, r.size.y], late) == _checksum(r))
			var seen: Array = await _ask("players", null, late)
			_check("and sees the whole crew", seen.size() == 3, str(seen.size()))
			await _ask("shot", "late_joiner", late)
			await _ask("leave", null, late)
			_check("leaving takes their miner out of the run",
				await _until(func(): return main().players.size() == 2, 5.0))

		# the crew's money is the host's; toasts reach everyone
		Progress.add_money(37)
		m.hud.toast("hello crew", 3.0)
		await _wait(0.5)
		var money: int = await _ask("money")
		_check("the client mirrors the crew's money", money == Progress.money, "%d / %d" % [money, Progress.money])
		var toast: String = await _ask("toast")
		_check("toasts reach the client", toast == "hello crew", toast)

		# a station used by the client opens the menu on their screen
		m._on_workbench_used(remote)
		await _wait(0.4)
		_check("the client's shop opens on their screen", await _ask("shop_open") == true and not m.shop.visible)
		_check("their miner waits while it's open", remote.frozen)
		await _ask("close_shop")
		await _wait(0.4)
		_check("closing it lets them move again", not remote.frozen)

		# the host restarts: everyone loads the new world
		World.fixed_seed = 99         # (tests keep their seed; a real restart picks a random one)
		var old_run := m.get_instance_id()
		m._restart()
		var next_run := func(): return main() != null and main().get_instance_id() != old_run and main().get("session") != null
		await _until(next_run, 10.0)
		var rejoined := await _until(func(): return main().players.size() == 2, 20.0)
		_check("the crew comes along to the next run", rejoined)
		if rejoined:
			await _wait(0.5)
			var seed2: int = await _ask("seed")
			_check("the next run has a new world, the same for both", seed2 == main().world.seed and seed2 == 99,
				"%d / %d" % [seed2, main().world.seed])
		_finish()

	func _finish() -> void:
		Net.send_all("test", [-1, "done", null])
		await _wait(0.5)
		print("RESULT: " + ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
		get_tree().quit(1 if fails > 0 else 0)

	func _compare_cells(name: String, r: Rect2i) -> void:
		var theirs: Array = await _ask("cells", [r.position.x, r.position.y, r.size.x, r.size.y])
		var mine := _checksum(r)
		_check(name, theirs == mine, "%s / %s" % [theirs, mine])

	## Fill and liquid of a block of cells, quantized like they travel.
	func _checksum(r: Rect2i) -> Array:
		var w: World = main().world
		var fill := 0
		var liquid := 0
		for gy in range(r.position.y, r.end.y):
			for gx in range(r.position.x, r.end.x):
				fill += int(round(clampf(w.get_fill(gx, gy), 0.0, 1.0) * 65535.0))
				liquid += int(clampf(w.get_liquid(gx, gy), 0.0, 1.0) * 255.0) / 8   # (a little slack)
		return [fill, liquid]

	## Ask the client (`peer`, or the first one) and wait for its answer.
	func _ask(kind: String, data: Variant = null, peer := 0) -> Variant:
		_step += 1
		var step := _step
		if peer == 0:
			peer = main().players[1].peer if main().players.size() > 1 else 0
		Net.send(peer, "test", [step, kind, data])
		var got := await _until(func(): return _replies.has(step), 15.0)
		if not got:
			_check("client answered " + kind, false)
			return null
		var r = _replies[step]
		_replies.erase(step)
		return r

	func _on_message(from: int, kind: String, data: Variant) -> void:
		if kind == "test_reply" and role == "host":
			_replies[data[0]] = data[1]
		elif kind == "test" and role == "client" and from == 1:
			_answer(data[0], data[1], data[2])

	# ------------------------------------------------------------ client: does and reports

	func _client() -> void:
		await _wait(delay)                      # (the host is starting up)
		Net.join("127.0.0.1", port)
		await _until(func(): return main() != null and main().get("session") != null, 20.0)
		print("client: in the run, seed %d" % main().world.seed)

	func _answer(step: int, kind: String, data: Variant) -> void:
		var m := main()
		var r: Variant = null
		match kind:
			"done":
				await _wait(0.2)
				get_tree().quit()
				return
			"seed":
				r = m.world.seed
			"cells":
				r = _checksum(Rect2i(data[0], data[1], data[2], data[3]))
			"drill":
				r = [m.drill.global_position, m.drill.speed, m.drill.hull]
			"players":
				r = []
				var ps: Array = m.players.duplicate()
				ps.sort_custom(func(a, b): return a.number < b.number)
				for p: Player in ps:
					r.append(p.global_position)
			"press":
				Input.action_press(data[0])
				await _wait(data[1])
				Input.action_release(data[0])
			"dig_down":
				m.player.pick.mouse_aim = false
				Input.action_press("down")
				Input.action_press("dig")
				await _wait(data)
				Input.action_release("dig")
				Input.action_release("down")
			"count":
				r = [get_tree().get_nodes_in_group("creature").size()]
			"money":
				r = Progress.money
			"toast":
				r = m.hud._toast.text
			"shop_open":
				r = m.shop.visible
			"close_shop":
				m.shop.close()
			"shot":
				if shots != "" and DisplayServer.get_name() != "headless":
					await RenderingServer.frame_post_draw
					get_viewport().get_texture().get_image().save_png("%s/%s.png" % [shots, data])
			"leave":
				Net.send(1, "test_reply", [step, true])
				await _wait(0.2)
				Net.leave()
				get_tree().quit()
				return
		Net.send(1, "test_reply", [step, r])
