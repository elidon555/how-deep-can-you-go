extends Node2D
## Puts the game together: world, the drill, player, camera, lighting, creatures, HUD.
## Game rules that span systems live here: who gets the ore, throws, the drill being wrecked,
## dying, milestones. The drill (src/drill) is the crew's base: ore is sold at its workbench.
## Co-op: a second player on a controller (Start), or online (src/net, up to Net.MAX_PLAYERS):
## the host runs this whole game for the crew, a client runs it as a puppet show of the host's
## (its world, drill, liquids and spawner are puppets, see NetSession).

static var skip_title := false  # set when restarting a run, so it goes straight back in
static var daily_run := false   # this run is today's Daily Dig
static var resume := {}         # a saved run to put back (RunSave), set by "Continue"

const MILESTONES := {
	10: "The daylight is gone", 25: "It's very quiet down here", 50: "Something is watching you",
	100: "100 m. Nobody has dug this deep", 200: "The rock feels... warm", 300: "You hear breathing",
	500: "Half a kilometer. Turn back?", 1000: "1 km. It knows you're here",
}
const ZOOM_INSIDE := 1.6        # see the whole drill while you're in it
const ZOOM_OUTSIDE := 2.0
const ZOOM_GUNNER := 1.1         # see far around the drill while on the turrets
const WORM_BOUNTY := 15

var world: World
var player: Player
var cam := Camera2D.new()
var dark := CanvasModulate.new()
var glow_layer := CanvasLayer.new()
var backdrop := Backdrop.new()
var fx := Fx.new()
var hud := Hud.new()
var shop := Shop.new()
var sonar := SonarView.new()
var menus := Menus.new()
var run_time := 0.0
var kills := 0
var run_over := false
var drill := Drill.new()
var liquids := Liquids.new()
var eye: TheEye = null              # what lives at the bottom (spawned when the world reaches it)
var ending := false
var players: Array[Player] = []     # player one first; a second joins with Start on a controller
var _menu_user: Player = null       # who opened the shop / sonar (unfrozen when it closes)
const RESPAWN_TIME := 8.0
const RESPAWN_TIME_BUNK := 3.0     # with the crew bunk module
var notes_read := 0
var tips := Tips.new()
var spawner := Spawner.new()
var motes := CPUParticles2D.new()
var session: NetSession = null       # online: this machine's side of the shared run
var contracts := Contracts.new()     # jobs from the surface (host)
var quakes := Quakes.new()           # the ground shifting (host)
var _self_bound := false             # client: our own miner has been matched to the host's

var shake := 0.0
var time := 0.0
var flicker_t := 0.0
var shown := {}
var new_best := false


func _ready() -> void:
	add_to_group("run")
	Controls.setup()
	Lore.reset_run()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest"):
			Progress.dry_run = true   # the test's changes stay in memory, never in the save
	add_child(backdrop)
	world = World.new()
	world.puppet = Net.is_client()
	add_child(world)
	world.ore_found.connect(_on_ore_found)
	world.boulder_shattered.connect(_on_boulder_shattered)
	world.gas_released.connect(_on_gas_released)

	# glowing things live on their own layer: not darkened, they bloom
	glow_layer.layer = 1
	glow_layer.follow_viewport_enabled = true
	add_child(glow_layer)
	glow_layer.add_child(world.glow_root)

	drill.world = world
	drill.puppet = Net.is_client()
	var want_drill: String = str(Net.run.get("drill", "rustbucket")) if Net.is_client() else Settings.drill
	drill.variant = want_drill if Unlocks.DRILLS.has(want_drill) and (Net.is_client() or Unlocks.unlocked(want_drill)) else "rustbucket"
	add_child(drill)
	liquids.world = world
	liquids.drill = drill
	liquids.puppet = Net.is_client()
	world.liquids = liquids
	add_child(liquids)
	liquids.reacted.connect(_on_liquid_reacted)
	drill.place(World.WIDTH_PX / 2.0)
	drill.workbench_used.connect(_on_workbench_used)
	drill.wrecked.connect(_on_drill_wrecked)
	drill.damaged.connect(func(amount): add_shake(minf(amount / 10.0, 1.2), drill.global_position))
	drill.cutter.chewed.connect(_on_drill_chewed)
	drill.cutter.knocked.connect(func(_pos): if eye: eye.knock())
	drill.sonar_used.connect(_on_sonar_used)
	drill.guns.bolt_hit.connect(_on_bolt_hit)

	player = _add_player(PlayerInput.new())
	player.puppet = Net.is_client()
	player.role = Settings.role
	player.helmet = Settings.helmet if Unlocks.unlocked(Settings.helmet) else "brass"
	player.update_crew_look()
	player.health_changed.connect(hud.set_health)
	player.bag_changed.connect(_update_bag)
	player.breath_changed.connect(hud.set_breath)
	player.interactor.prompt_changed.connect(hud.set_prompt)
	Sfx.listener = player

	fx.lit = self
	fx.glow = glow_layer
	add_child(fx)
	cam.zoom = Vector2(2, 2)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 8.0
	cam.limit_left = 0
	cam.limit_right = World.WIDTH_PX
	player.add_child(cam)
	add_child(dark)
	_setup_glow()
	_setup_motes()

	spawner.world = world
	spawner.player = player
	spawner.puppet = Net.is_client()
	spawner.drill = drill
	spawner.worm_coming.connect(_on_worm_coming)
	spawner.worm_killed.connect(_on_worm_killed)
	spawner.bat_killed.connect(func(pos):
		kills += 1
		fx.burst(pos, Color("3a2a30"), 6, 90.0, Vector2.UP, 160.0, 0.5, 2.0, false, 500.0, true))
	spawner.lit_parent = self
	spawner.glow_parent = glow_layer
	spawner.crawler_killed.connect(_on_crawler_killed)
	spawner.creature_killed.connect(func(pos, bounty):
		kills += 1
		fx.gore(pos)
		var p := _nearest_player(pos)
		if p:
			p.add_value(bounty))
	spawner.brood_spawned.connect(_on_brood_spawned)
	add_child(spawner)

	add_child(hud)
	hud.add_child(shop)
	hud.add_child(sonar)
	sonar.drill = drill
	sonar.world = world
	sonar.closed.connect(_on_menu_closed)
	shop.closed.connect(_on_menu_closed)
	Progress.changed.connect(_on_progress_changed)
	hud.set_health(player.health, player.max_health)
	_update_bag()
	_setup_menus()
	tips.main = self
	if not Progress.dry_run:
		add_child(tips)
	if not resume.is_empty():
		RunSave.restore(self, resume)
		resume = {}
		RunSave.clear()                  # (a save is used once)
	if not Net.is_client():              # (a client sees the host's)
		contracts.main = self
		add_child(contracts)
		quakes.main = self
		add_child(quakes)
	if Net.is_online():
		go_online()
	_autotest()


func _process(dt: float) -> void:
	time += dt
	_frame_camera(dt)
	var depth_m := player.position.y / World.METER
	var depth := maxi(0, int(floor(depth_m)))
	var deepest := player.position.y
	for p in players:
		deepest = maxf(deepest, p.position.y)
	world.ensure_generated(deepest + 900.0)
	if eye == null and not Net.is_client() and world.next_row * World.CHUNK_PX > World.BOTTOM * World.METER + 64.0:
		_spawn_eye()
	backdrop.follow(cam, depth_m)
	Sfx.set_depth(depth_m)

	if Progress.record_depth(depth):
		new_best = true
	if daily_run:
		Progress.record_daily(depth)
	hud.set_depth(depth, Progress.best, new_best)
	if not menus.on_title():
		run_time += dt
		Sfx.music(_music(depth_m))
	hud.set_crew(players.filter(func(p): return p != player))
	for p in players:
		p.show_tag(players.size() > 1 and p != player)
	PlayerInput.menu_open = menus.pause.visible or menus.settings.visible   # (online it doesn't pause)
	for m in MILESTONES:
		if depth >= m and not shown.has(m):
			shown[m] = true
			hud.toast(MILESTONES[m])
	_update_light(depth, dt)
	if fmod(time, 2.0) < dt:
		for u in Unlocks.fresh():            # (each machine its own)
			hud.note("Unlocked: %s! Pick it in the Hangar." % u, 3.5)
	hud.set_drill(drill, depth_m)

	shake = maxf(shake - dt * 6.0, 0.0)
	cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake * 3.0
	if Input.is_action_just_pressed("restart") and not menus.on_title() and not Net.is_client():
		_restart()


## What's playing: the boss's theme once it's awake, the ending, the deep theme past 300 m.
func _music(depth_m: float) -> String:
	if ending:
		return "music_ending"
	if eye and eye.is_awake() and eye.state < TheEye.State.DYING:
		return "music_boss"
	for b: Broodmother in get_tree().get_nodes_in_group("boss").filter(func(n): return n is Broodmother):
		if b.is_awake():
			return "music_boss"
	return "music_deep" if depth_m > 300.0 else ""


## A jolt of camera shake. Online it's sent to every screen; each shakes only if its own miner
## is near `at` (anywhere when at is INF).
func add_shake(amount: float, at := Vector2.INF) -> void:
	Net.echo(&"main", &"add_shake", [amount, at])
	if at == Vector2.INF or player.global_position.distance_to(at) < 500.0:
		shake = maxf(shake, amount)


## Gloomy sky -> pitch black within ~30 m; the lamp takes over, flickering now and then.
func _update_light(depth: int, dt: float) -> void:
	RenderingServer.set_default_clear_color(Color("56636f").lerp(Color("040508"), clampf(depth / 12.0, 0.0, 1.0)))
	var light := clampf(1.0 - depth / 30.0, 0.0, 1.0)
	dark.color = Color(1, 1, 1).lerp(Color(0.13, 0.15, 0.22), 1.0 - light)
	if "--bright" in OS.get_cmdline_user_args():
		dark.color = Color.WHITE
	for p in players:
		p.lamp_on = light < 1.0
		p.sprite.modulate = Color(1, 1, 1).lerp(Color(0.72, 0.74, 0.82), 1.0 - light)
	motes.emitting = depth > 3
	hud.set_vignette(lerpf(0.25, 0.85, clampf(depth / 60.0, 0.0, 1.0)))
	var mul := 0.94 + 0.06 * sin(time * 13.0) * sin(time * 7.3)
	flicker_t -= dt
	if depth > 30 and flicker_t < -2.0 and randf() < dt * 0.12:
		flicker_t = randf_range(0.2, 0.5)
	if flicker_t > 0.0:
		mul = randf_range(0.05, 0.6)
	for p in players:
		p.light_mul = mul


## Upgrades bought at the workbench apply right away.
func _on_progress_changed() -> void:
	drill.apply_upgrades()
	if drill.contains(player.global_position):
		player.restock()
	_update_bag()


func _update_bag() -> void:
	hud.set_bag(player)
	hud.set_money(Progress.money)


# ---------------------------------------------------------------- events

## Someone read a note (CampItems.Note): it shows on their screen.
func note_read(p: Player, id: int) -> void:
	notes_read += 1
	_show_to(p, "note:%d" % id)


# ---------------------------------------------------------------- players (co-op)

## A player with every game hook wired up, standing in the drill.
func _add_player(input: PlayerInput) -> Player:
	var p := Player.new()
	p.world = world
	p.input = input
	p.number = _free_number()
	p.peer = (input as NetInput).peer if input is NetInput else Net.my_id()
	p.position = drill.position + Vector2(-34 + 24 * players.size(), Drill.FLOOR - Player.HALF_HEIGHT - 1)
	add_child(p)
	if not input.uses_mouse:
		p.pick.mouse_aim = false
	p.pick.struck.connect(_on_struck.bind(p))
	p.pick.hit_thing.connect(_on_hit_thing.bind(p))
	p.went_down.connect(_on_player_down.bind(p))
	p.bled_out.connect(_on_player_bled_out.bind(p))
	p.revived.connect(func(): hud.toast("%s is back on their feet." % p.tag_name(), 1.5))
	p.kicked_dust.connect(fx.dust)
	p.pinged.connect(func(at): show_ping(at, p.number, p.tag_name()))
	p.message.connect(func(text): _tell(p, text, 1.6))
	p.tools.throw_requested.connect(_throw)
	players.append(p)
	return p


## The lowest player number nobody has (their colour; someone may have left).
func _free_number() -> int:
	var n := 1
	while players.any(func(p): return p.number == n):
		n += 1
	return n


## Host: a miner for someone who joined online (their controls arrive over the network).
func add_remote_player(input: NetInput, display_name := "", role := "miner", helmet := "brass") -> Player:
	var p := _add_player(input)
	p.display_name = display_name
	p.role = role if role in Roles.ALL else "miner"
	p.helmet = helmet if Unlocks.HELMETS.has(helmet) else "brass"
	p.update_crew_look()
	return p


## Client: the miner the host has for `peer` (ours is the one made at the start).
func puppet_player(peer: int) -> Player:
	if peer == Net.my_id() and not _self_bound:
		_self_bound = true
		return player
	var p := _add_player(NetInput.new(peer))
	p.puppet = true
	return p


func remove_player(p: Player) -> void:
	if p == player:
		return
	players.erase(p)
	if drill.guns.gunner == p:
		drill.guns.gunner = null
	p.queue_free()


## Is this miner played on this machine (keyboard or a controller here)?
func _is_here(p: Player) -> bool:
	return p.input.is_local()


## Start on a controller adds player two (on that controller). Not on an online client.
func _input(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START \
			and not players.any(func(p): return p.input.prefix == "p2_") and players.size() < Net.MAX_PLAYERS \
			and not menus.on_title() and not run_over and not Net.is_client():
		Controls.add_pad_player("p2_", event.device)
		var p2 := _add_player(PlayerInput.new("p2_", false))
		hud.toast("%s joined!" % p2.tag_name(), 1.5)
		get_viewport().set_input_as_handled()


## One player here: the camera rides along. Several on this machine: it frames them all,
## zooming out as they spread. (Online, each machine follows its own miner.)
func _frame_camera(dt: float) -> void:
	var inside := drill.contains(player.global_position)
	var want := ZOOM_GUNNER if drill.guns.gunner == player else (ZOOM_INSIDE if inside else ZOOM_OUTSIDE)
	var here := players.filter(_is_here) if not Net.is_client() else [player]
	if here.size() > 1:
		if cam.get_parent() != self:
			cam.reparent(self)
		var lo: Vector2 = here[0].global_position
		var hi := lo
		for p: Player in here:
			lo = lo.min(p.global_position)
			hi = hi.max(p.global_position)
		cam.global_position = (lo + hi) / 2.0
		var vs := get_viewport_rect().size
		var spread := (hi - lo) + Vector2(160, 120)
		want = minf(want, minf(vs.x / spread.x, vs.y / spread.y))
		want = maxf(want, 0.9)
	var z := lerpf(cam.zoom.x, want, 3.0 * dt)
	cam.zoom = Vector2(z, z)


## Down: a crewmate can help them up (hold E on them) before they bleed out. If nobody is
## left standing, the run is over.
func _on_player_down(p: Player) -> void:
	if players.all(func(q): return q.health <= 0):
		_game_over("Everyone is down. The ore you carried is lost.")
		return
	hud.toast("%s is down! Hold E on them to help them up." % p.tag_name(), 3.0)


## Nobody helped in time: their bag is lost and they're back in the drill shortly.
func _on_player_bled_out(p: Player) -> void:
	p.lose_bag()
	p.frozen = true
	p.visible = false
	if players.all(func(q): return q.health <= 0):
		_game_over("Everyone is down. The ore you carried is lost.")
		return
	var wait := RESPAWN_TIME_BUNK if drill.modules.has("bunk") else RESPAWN_TIME
	hud.toast("%s didn't make it. Back in the drill in %d s." % [p.tag_name(), int(wait)], 2.5)
	await get_tree().create_timer(wait).timeout
	if run_over or not is_instance_valid(p):
		return
	p.global_position = drill.global_position + Vector2(0, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	p.velocity = Vector2.ZERO
	p.heal_full()
	p.visible = true
	p.frozen = false


# ---------------------------------------------------------------- the bottom

## The Eye sits in the Floor off to one side; three veins feed it, spread across the cavern.
func _spawn_eye() -> void:
	var floor_y := ceilf(World.BOTTOM * World.METER / World.CELL) * World.CELL
	var side := -1.0 if world.gen.rng.randf() < 0.5 else 1.0
	eye = TheEye.new()
	eye.world = world
	eye.drill = drill
	eye.spawner = spawner
	eye.glow_parent = glow_layer
	eye.position = Vector2(World.WIDTH_PX / 2.0 + side * 330.0, floor_y)
	add_child(eye)
	var xs := []
	for x in [70.0, 290.0, World.WIDTH_PX - 290.0, World.WIDTH_PX - 70.0]:
		if absf(x - eye.position.x) > 140.0:
			xs.append(x)
	eye.grow_veins(xs.slice(0, TheEye.VEINS))
	eye.woke.connect(func():
		Sfx.music("music_boss")
		hud.toast("Something below opens its eye.", 3.0)
		hud.set_boss("THE EYE", 1.0))
	eye.health_changed.connect(func(f): hud.set_boss("THE EYE", f))
	eye.died.connect(_on_eye_died)


## The Broodmother's lair has opened: a boss bar while she's awake, a reward when she's dead.
func _on_brood_spawned(b: Broodmother) -> void:
	hud.toast("The ice splits open beside the shaft. Something stirs.", 3.0)
	b.woke.connect(func(): hud.set_boss("THE BROODMOTHER", 1.0))
	b.health_changed.connect(func(f): hud.set_boss("THE BROODMOTHER", f))
	b.died.connect(func(pos):
		Progress.brood_killed = true
		Progress.save()
		hud.set_boss("", 0.0)
		kills += 1
		fx.gore(pos)
		fx.explosion(pos + Vector2(0, -40), 30.0)
		add_shake(1.6, pos)
		Progress.add_money(Broodmother.REWARD)
		hud.toast("The Broodmother is dead. +$%d for the crew" % Broodmother.REWARD, 3.0))


## The eye is dead: the Floor cracks and light pours up. The end of the run.
func _on_eye_died(pos: Vector2) -> void:
	hud.set_boss("", 0.0)
	fx.explosion(pos, 70.0)
	show_ending_light()
	Progress.beat_the_game()
	await get_tree().create_timer(5.0).timeout
	_end_run({"reason": "You reached the bottom.",
		"ending": "The Floor is open. Whatever was waiting down there\nhas seen you now."})


## The light from below fills the screen (on every screen, online).
func show_ending_light() -> void:
	Net.echo(&"main", &"show_ending_light", [])
	ending = true
	shake = 3.0
	var light := ColorRect.new()
	light.color = Color(1.0, 0.97, 0.88, 0.0)
	light.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	light.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(light)
	create_tween().tween_property(light, "color:a", 1.0, 4.0)


## Firedamp leaks out of rock you broke open: a cloud that a spark will set off.
func _on_gas_released(pos: Vector2) -> void:
	var cloud := GasCloud.release(get_tree(), self, world, pos)
	if not cloud.exploded.is_connected(_on_gas_exploded):
		cloud.exploded.connect(_on_gas_exploded)
		hud.toast("Firedamp! Keep sparks away from the gas.", 2.0)


func _on_gas_exploded(pos: Vector2, size: float) -> void:
	fx.explosion(pos, size)
	add_shake(2.0, pos)
	var l := drill.to_local(pos)
	if absf(l.x) < Drill.HW + size and l.y > Drill.TOP - size and l.y < Drill.BOTTOM + size:
		drill.fires.ignite(clampf(l.x, -70.0, 70.0), 0.5)     # the blast sets the cabin alight


## Steel on stone throws sparks: any gas around them goes up.
func _sparks_at(pos: Vector2, mat: int) -> void:
	if mat == World.M.STONE or mat == World.M.HARD or mat == World.M.MAGMA:
		GasCloud.spark(get_tree(), pos)


func _on_struck(pos: Vector2, mat: int, broke: int, kind: String, p: Player) -> void:
	_sparks_at(pos, mat)
	_shake_for(p, 0.25 if kind == "bonk" else (0.6 if broke > 0 else 0.35))
	fx.impact(pos, mat, broke, kind, p.facing)


func _on_hit_thing(pos: Vector2, p: Player) -> void:
	_shake_for(p, 0.5)
	fx.flesh(pos, p.facing)


## Shake only the screen of the miner it happened to (their own swing).
func _shake_for(p: Player, amount: float) -> void:
	if p == player or _is_here(p):
		shake = maxf(shake, amount)
	elif session:
		session.tell(p, "shake", amount)


## Ore goes into the bag of whoever is closest (the one who dug it).
func _on_ore_found(pos: Vector2, kind: int) -> void:
	var ore: Array = World.ORES[kind]
	var p := _nearest_player(pos)
	if p == null or not p.add_ore(kind):
		return               # nobody here yet (the drill setting down), or their bag is full
	_shake_for(p, 0.8)
	var c: Color = ore[3]
	fx.burst(pos, Color(c.r * 2.0, c.g * 2.0, c.b * 2.0), 14, 140.0, Vector2.UP, 180.0, 0.6, 2.5, true)
	Sfx.play("ore", pos)
	hud.toast("+ %s" % ore[0], 0.6)


func _on_boulder_shattered(pos: Vector2) -> void:
	add_shake(0.9, pos)
	fx.impact(pos, World.M.STONE, 3, "dig_down", 1)


## The cutters broke rock: debris, and a little rumble if you're near the drill.
func _on_drill_chewed(points: Array, mat: int) -> void:
	_sparks_at(points[0], mat)
	fx.chunks(points, mat, drill.global_position.x)
	add_shake(0.18, drill.global_position)


## Water hit lava: hiss, steam, new rock.
func _on_liquid_reacted(pos: Vector2) -> void:
	fx.burst(pos, Color(0.9, 0.92, 0.95, 0.5), 8, 60.0, Vector2.UP, 60.0, 1.0, 4.0, false, -40.0)
	Sfx.play("sizzle", pos, -4.0)


func _on_sonar_used(p: Player) -> void:
	p.frozen = true
	_show_to(p, "sonar")


func _on_bolt_hit(pos: Vector2, on_rock: bool) -> void:
	if on_rock:
		GasCloud.spark(get_tree(), pos)
		fx.impact(pos, world.mat_at(pos) if world.is_diggable(pos) else World.M.STONE, 1, "dig_side", 1)
	else:
		fx.flesh(pos, 1)


func _on_worm_coming(_w: Worm) -> void:
	Sfx.play("rumble", Vector2.INF, -2.0, 0.0)
	add_shake(0.6)
	hud.toast("Something big is burrowing toward the drill...", 3.0)


func _on_worm_killed(pos: Vector2) -> void:
	kills += 1
	fx.gore(pos)
	add_shake(1.2, pos)
	var p := _nearest_player(pos)
	if p:
		p.add_value(WORM_BOUNTY)
	hud.toast("The worm is dead. + $%d" % WORM_BOUNTY, 2.0)


func _on_crawler_killed(pos: Vector2) -> void:
	kills += 1
	fx.gore(pos)
	var p := _nearest_player(pos)
	if p:
		p.add_value(2)    # crawlers carry a shiny bit or two
	hud.toast("+ $2", 0.6)


func _on_workbench_used(p: Player) -> void:
	p.frozen = true
	_show_to(p, "shop")


## A flare or a lit bundle of dynamite leaves someone's hand.
func _throw(kind: String, from: Vector2, velocity: Vector2) -> void:
	var t := Thrown.new()
	t.kind = kind
	t.world = world
	t.position = from
	t.velocity = velocity
	t.exploded.connect(func(at, size):
		fx.explosion(at, size)
		add_shake(2.0, at)
		var l := drill.to_local(at)
		if absf(l.x) < Drill.HW + size and l.y > Drill.TOP - size and l.y < Drill.BOTTOM + size:
			drill.fires.ignite(clampf(l.x, -70.0, 70.0), 0.5))
	add_child(t)


## A crew marker at a spot, in that player's colour (on every screen, online).
func show_ping(at: Vector2, number: int, who: String) -> void:
	Net.echo(&"main", &"show_ping", [at, number, who])
	for old: Ping in get_tree().get_nodes_in_group("ping_%d" % number):
		old.queue_free()                 # one marker per player at a time
	var m := Ping.new()
	m.position = at
	m.color = Player.CREW_COLORS[(number - 1) % Player.CREW_COLORS.size()]
	m.who = who
	m.add_to_group("ping_%d" % number)
	glow_layer.add_child(m)
	Sfx.play("sonar_ping", at, -10.0, 0.05)


## Opens a menu (shop, sonar, "note:<id>") on the screen of the miner who asked for it: here,
## or on their machine online (it tells the host when it closes, see _on_menu_closed).
func _show_to(p: Player, menu: String) -> void:
	if _is_here(p) or p == player:
		open_menu(menu, p)
	elif session:
		session.tell(p, "menu", menu)


func open_menu(menu: String, p: Player = null) -> void:
	_menu_user = p if p else player
	if menu == "shop":
		shop.open()
		Sfx.play("ui_click", Vector2.INF)
	elif menu == "sonar":
		sonar.open()
	elif menu.begins_with("note:"):
		menus.note_view.show_note(int(menu.trim_prefix("note:")))


func _on_menu_closed() -> void:
	if Net.is_client():
		session.menu_closed()
	elif _menu_user:
		_menu_user.frozen = false


func _on_drill_wrecked() -> void:
	Sfx.play("drill_stall", drill.global_position)
	_game_over("The drill is wrecked.")


func _nearest_player(pos: Vector2) -> Player:
	var best: Player = null
	for p: Player in get_tree().get_nodes_in_group("player"):
		if best == null or p.global_position.distance_to(pos) < best.global_position.distance_to(pos):
			best = p
	return best


func _tell(p: Player, text: String, seconds := 2.0) -> void:
	if _is_here(p) or p == player:
		hud.note(text, seconds)
	elif session:
		session.tell(p, "note", [text, seconds])


func _game_over(reason: String) -> void:
	if run_over:
		return
	Progress.save()
	await get_tree().create_timer(1.5).timeout
	_end_run({"reason": reason})


## The run is over for the whole crew: everyone stops and sees the summary.
func _end_run(stats: Dictionary) -> void:
	run_over = true
	for p in players:
		p.frozen = true
	var earned := 0
	for p in players:
		earned += p.sold_value
	stats.merge({"depth": maxi(0, int(drill.global_position.y / World.METER)), "earned": earned,
		"kills": kills, "seconds": run_time, "notes": notes_read})
	show_run(stats)


## The run summary (online, on every screen; best depth is each machine's own).
func show_run(stats: Dictionary) -> void:
	Net.echo(&"main", &"show_run", [stats])
	run_over = true
	stats.merge({"best": Progress.best, "new_best": new_best}, true)
	menus.show_run(stats)


func _restart(to_title := false) -> void:
	if Net.is_client() and not to_title:
		return                       # online the host starts the next run (everyone comes along)
	Progress.save()
	if to_title:
		daily_run = false
		Net.leave()                  # (a host ending the session sends everyone home)
	if not daily_run and not Progress.dry_run:
		World.fixed_seed = -1        # a fresh random world
	if Net.is_host():
		if World.fixed_seed < 0:
			World.fixed_seed = randi() & 0x7fffffff   # picked here so the crew gets the same one
		Net.new_run({"seed": World.fixed_seed, "daily": daily_run,
			"drill": Settings.drill if Unlocks.unlocked(Settings.drill) else "rustbucket"})
	skip_title = not to_title
	get_tree().paused = false
	get_tree().reload_current_scene()


# ---------------------------------------------------------------- menus

func _setup_menus() -> void:
	add_child(menus)
	menus.start_run.connect(_start_run)
	menus.restart.connect(_restart)
	menus.daily.connect(func():
		daily_run = true
		World.fixed_seed = Progress.daily_seed()
		_restart())
	menus.host.connect(_host_game)
	menus.save_and_quit.connect(func():
		RunSave.save(self)
		_restart(true))
	menus.continue_run.connect(func():
		var d := RunSave.read()
		if d.is_empty():
			return
		resume = d
		daily_run = bool(d.daily)
		World.fixed_seed = int(d.seed)
		skip_title = true
		get_tree().paused = false
		get_tree().reload_current_scene())
	if Net.is_client():
		daily_run = bool(Net.run.get("daily", false))
	menus.pause.seed_text.text = ("Daily Dig %s · " % Progress.today() if daily_run else "") + "Seed %d" % world.seed
	menus.can_pause = func(): return not run_over and drill.guns.gunner != player
	# tests and autotests go straight in; so do "dig again" and joining someone's game
	if skip_title or Progress.dry_run or Net.is_online():
		skip_title = false
	else:
		menus.show_title(Net.notice)
		Net.notice = ""
		hud.visible = false
		player.frozen = true


func _start_run() -> void:
	hud.visible = true
	player.frozen = false
	player.role = Settings.role          # (picked on the title screen)


## Title screen "Host a game": open this run to others and start digging.
func _host_game(port: int) -> void:
	if Net.host(port) != OK:
		return                       # (the title shows why)
	go_online()
	menus.online.visible = false
	menus.title.visible = false
	Sfx.music("")
	_start_run()
	var ips := Array(IP.get_local_addresses()).filter(func(a: String):
		return a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."))
	hud.toast("Hosting on port %d. Friends join with: %s" % [port, ", ".join(ips) if ips else "your IP"], 8.0)


## This run is online now (hosting, or joined someone's): start syncing it.
func go_online() -> void:
	if session:
		return
	player.display_name = Settings.player_name
	player.update_crew_look()
	session = NetSession.new()
	session.main = self
	add_child(session)
	menus.pause.seed_text.text = ("Hosting" if Net.is_host() else "Online") + " · " + menus.pause.seed_text.text


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		Progress.save()


# ---------------------------------------------------------------- look

func _setup_glow() -> void:
	get_viewport().use_hdr_2d = true
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_strength = 1.1
	env.glow_hdr_threshold = 0.95
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _setup_motes() -> void:
	# dust floating in the air; only visible where the lamp shines
	motes.amount = 70
	motes.lifetime = 8.0
	motes.preprocess = 8.0
	motes.local_coords = false
	motes.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	motes.emission_rect_extents = Vector2(340, 200)
	motes.direction = Vector2(0, -1)
	motes.spread = 180.0
	motes.initial_velocity_min = 2.0
	motes.initial_velocity_max = 7.0
	motes.gravity = Vector2(0, 2)
	var g := Gradient.new()
	g.set_color(0, Color(1, 0.95, 0.8, 0))
	g.add_point(0.5, Color(1, 0.95, 0.8, 0.7))
	g.set_color(g.get_point_count() - 1, Color(1, 0.95, 0.8, 0))
	motes.color_ramp = g
	motes.z_index = 3
	player.add_child(motes)


## Test mode: `godot -- --autotest=/path/shot.png` runs the drill at full speed by itself and
## saves screenshots; then the miner climbs out and digs sideways for a bit.
func _autotest() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest="):
			out = a.trim_prefix("--autotest=")
	if out == "":
		return
	fx.hitstop_enabled = false
	player.pick.mouse_aim = false
	drill.fuel = drill.max_fuel
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(out.replace(".png", "_0.png"))
	drill.speed = Drill.Speed.FULL
	for i in 4:
		await get_tree().create_timer(6.0).timeout
		if i == 3:                  # out the door and into the rock
			Input.action_press("left")
			Input.action_press("dig")
			await get_tree().create_timer(3.0).timeout
			Input.action_release("left")
			Input.action_release("dig")
		get_viewport().get_texture().get_image().save_png(out.replace(".png", "_%d.png" % (i + 1)))
		print("autotest drill=%dm player=%dm fuel=%d hull=%d coal=%d ore=%d creatures=%d hp=%d" % [
			int(drill.global_position.y / World.METER), int(player.position.y / World.METER),
			int(drill.fuel), int(drill.hull), player.coal, player.ore_count,
			get_tree().get_nodes_in_group("creature").size(), player.health])
	get_tree().quit()
