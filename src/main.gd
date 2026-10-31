extends Node2D
## Puts the game together: world, the drill, player, camera, lighting, creatures, HUD.
## Game rules that span systems live here: who gets the ore, ropes, the drill being wrecked,
## dying, milestones. The drill (src/drill) is the crew's base: ore is sold at its workbench.

static var skip_title := false  # set when restarting a run, so it goes straight back in

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
var menus := CanvasLayer.new()
var title := TitleMenu.new()
var pause := PauseMenu.new()
var settings_menu := SettingsMenu.new()
var game_over := GameOver.new()
var run_time := 0.0
var kills := 0
var run_over := false
var drill := Drill.new()
var spawner := Spawner.new()
var motes := CPUParticles2D.new()

var shake := 0.0
var time := 0.0
var flicker_t := 0.0
var shown := {}
var new_best := false


func _ready() -> void:
	Controls.setup()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest"):
			Progress.dry_run = true   # the test's changes stay in memory, never in the save
	add_child(backdrop)
	world = World.new()
	add_child(world)
	world.ore_found.connect(_on_ore_found)
	world.boulder_shattered.connect(_on_boulder_shattered)

	# glowing things live on their own layer: not darkened, they bloom
	glow_layer.layer = 1
	glow_layer.follow_viewport_enabled = true
	add_child(glow_layer)
	glow_layer.add_child(world.glow_root)

	drill.world = world
	add_child(drill)
	drill.place(World.WIDTH_PX / 2.0)
	drill.workbench_used.connect(_on_workbench_used)
	drill.wrecked.connect(_on_drill_wrecked)
	drill.damaged.connect(func(amount): shake = maxf(shake, minf(amount / 10.0, 1.2)))
	drill.chewed.connect(_on_drill_chewed)
	drill.sonar_used.connect(_on_sonar_used)
	drill.bolt_hit.connect(_on_bolt_hit)

	player = Player.new()
	player.world = world
	player.position = drill.position + Vector2(-34, Drill.FLOOR - Player.HALF_HEIGHT - 1)
	add_child(player)
	player.pick.struck.connect(_on_struck)
	player.pick.hit_thing.connect(_on_hit_thing)
	player.rope_requested.connect(_on_rope_requested)
	player.health_changed.connect(hud.set_health)
	player.died.connect(_on_died)
	player.bag_changed.connect(_update_bag)
	player.kicked_dust.connect(fx.dust)
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
	spawner.drill = drill
	spawner.worm_coming.connect(_on_worm_coming)
	spawner.worm_killed.connect(_on_worm_killed)
	spawner.lit_parent = self
	spawner.glow_parent = glow_layer
	spawner.crawler_killed.connect(_on_crawler_killed)
	add_child(spawner)

	add_child(hud)
	hud.add_child(shop)
	hud.add_child(sonar)
	sonar.drill = drill
	sonar.world = world
	sonar.closed.connect(func(): player.frozen = false)
	shop.closed.connect(func(): player.frozen = false)
	Progress.changed.connect(_on_progress_changed)
	hud.set_health(player.health, player.max_health)
	_update_bag()
	_setup_menus()
	_autotest()


func _process(dt: float) -> void:
	time += dt
	var depth_m := player.position.y / World.METER
	var depth := maxi(0, int(floor(depth_m)))
	world.ensure_generated(player.position.y + 900.0)
	backdrop.follow(cam, depth_m)
	Sfx.set_depth(depth_m)

	if Progress.record_depth(depth):
		new_best = true
	hud.set_depth(depth, Progress.best, new_best)
	if not title.visible:
		run_time += dt
		Sfx.music("music_deep" if depth_m > 300.0 else "")
	for m in MILESTONES:
		if depth >= m and not shown.has(m):
			shown[m] = true
			hud.toast(MILESTONES[m])
	_update_light(depth, dt)
	hud.set_drill(drill, depth_m)
	var inside := drill.contains(player.global_position)
	var want_zoom := ZOOM_GUNNER if drill.gunner == player else (ZOOM_INSIDE if inside else ZOOM_OUTSIDE)
	var z := lerpf(cam.zoom.x, want_zoom, 3.0 * dt)
	cam.zoom = Vector2(z, z)

	shake = maxf(shake - dt * 6.0, 0.0)
	cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake * 3.0
	if Input.is_action_just_pressed("restart") and not title.visible:
		_restart()


## Gloomy sky -> pitch black within ~30 m; the lamp takes over, flickering now and then.
func _update_light(depth: int, dt: float) -> void:
	RenderingServer.set_default_clear_color(Color("56636f").lerp(Color("040508"), clampf(depth / 12.0, 0.0, 1.0)))
	var light := clampf(1.0 - depth / 30.0, 0.0, 1.0)
	dark.color = Color(1, 1, 1).lerp(Color(0.13, 0.15, 0.22), 1.0 - light)
	if "--bright" in OS.get_cmdline_user_args():
		dark.color = Color.WHITE
	player.lamp_on = light < 1.0
	player.sprite.modulate = Color(1, 1, 1).lerp(Color(0.72, 0.74, 0.82), 1.0 - light)
	motes.emitting = depth > 3
	hud.set_vignette(lerpf(0.25, 0.85, clampf(depth / 60.0, 0.0, 1.0)))
	player.light_mul = 0.94 + 0.06 * sin(time * 13.0) * sin(time * 7.3)
	flicker_t -= dt
	if depth > 30 and flicker_t < -2.0 and randf() < dt * 0.12:
		flicker_t = randf_range(0.2, 0.5)
	if flicker_t > 0.0:
		player.light_mul = randf_range(0.05, 0.6)


## Upgrades bought at the workbench apply right away.
func _on_progress_changed() -> void:
	drill.apply_upgrades()
	if drill.contains(player.global_position):
		player.refill_ropes()      # a bigger rope bag fills up right there at the workbench
	_update_bag()


func _update_bag() -> void:
	hud.set_bag(player)
	hud.set_money(Progress.money)


# ---------------------------------------------------------------- events

func _on_struck(pos: Vector2, mat: int, broke: int, kind: String) -> void:
	shake = maxf(shake, 0.25 if kind == "bonk" else (0.6 if broke > 0 else 0.35))
	fx.impact(pos, mat, broke, kind, player.facing)


func _on_hit_thing(pos: Vector2) -> void:
	shake = maxf(shake, 0.5)
	fx.flesh(pos, player.facing)


## Ore goes into the bag of whoever is closest (the one who dug it).
func _on_ore_found(pos: Vector2, kind: int) -> void:
	var ore: Array = World.ORES[kind]
	var p := _nearest_player(pos)
	if p == null:
		return               # dug while the drill was being set down, before anyone's here
	p.add_ore(kind)
	shake = maxf(shake, 0.8)
	var c: Color = ore[3]
	fx.burst(pos, Color(c.r * 2.0, c.g * 2.0, c.b * 2.0), 14, 140.0, Vector2.UP, 180.0, 0.6, 2.5, true)
	Sfx.play("ore", pos)
	hud.toast("+ %s" % ore[0], 0.6)


func _on_boulder_shattered(pos: Vector2) -> void:
	shake = maxf(shake, 0.9)
	fx.impact(pos, World.M.STONE, 3, "dig_down", player.facing)


## The cutters broke rock: debris, and a little rumble if you're near the drill.
func _on_drill_chewed(points: Array, mat: int) -> void:
	fx.chunks(points, mat, drill.global_position.x)
	if player.global_position.distance_to(drill.global_position) < 260.0:
		shake = maxf(shake, 0.18)


func _on_sonar_used(p: Player) -> void:
	sonar.open()
	p.frozen = true


func _on_bolt_hit(pos: Vector2, on_rock: bool) -> void:
	if on_rock:
		fx.impact(pos, world.mat_at(pos) if world.is_diggable(pos) else World.M.STONE, 1, "dig_side", 1)
	else:
		fx.flesh(pos, 1)


func _on_worm_coming(_w: Worm) -> void:
	Sfx.play("rumble", Vector2.INF, -2.0, 0.0)
	shake = maxf(shake, 0.6)
	hud.toast("Something big is burrowing toward the drill...", 3.0)


func _on_worm_killed(pos: Vector2) -> void:
	kills += 1
	fx.gore(pos)
	shake = maxf(shake, 1.2)
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
	shop.open()
	p.frozen = true
	Sfx.play("ui_click", Vector2.INF)


func _on_drill_wrecked() -> void:
	Sfx.play("drill_stall", drill.global_position)
	_game_over("The drill is wrecked.")


func _nearest_player(pos: Vector2) -> Player:
	var best: Player = null
	for p: Player in get_tree().get_nodes_in_group("player"):
		if best == null or p.global_position.distance_to(pos) < best.global_position.distance_to(pos):
			best = p
	return best


func _on_rope_requested(feet: Vector2) -> void:
	var p := _nearest_player(feet)
	if p.ropes <= 0:
		hud.toast("No ropes left. More at the drill's workbench.", 1.2)
		return
	if not GameConfig.infinite_resources():
		p.ropes -= 1
	world.add_child(Rope.hang(world, feet))
	Sfx.play("rope", feet)
	_update_bag()


func _on_died() -> void:
	player.lose_bag()
	_game_over("You died. The ore you carried is lost.")


func _game_over(reason: String) -> void:
	if run_over:
		return
	run_over = true
	player.frozen = true
	Progress.save()
	await get_tree().create_timer(1.5).timeout
	game_over.show_run({"reason": reason, "depth": maxi(0, int(drill.global_position.y / World.METER)),
		"best": Progress.best, "new_best": new_best, "earned": player.sold_value, "kills": kills,
		"seconds": run_time})


func _restart(to_title := false) -> void:
	Progress.save()
	skip_title = not to_title
	get_tree().paused = false
	get_tree().reload_current_scene()


# ---------------------------------------------------------------- menus

func _setup_menus() -> void:
	menus.layer = 20
	add_child(menus)
	for m in [title, pause, settings_menu, game_over]:
		menus.add_child(m)
	title.start_pressed.connect(_start_run)
	title.settings_pressed.connect(func(): settings_menu.open())
	pause.settings_pressed.connect(func(): settings_menu.open())
	pause.restart_pressed.connect(_restart)
	pause.title_pressed.connect(func(): _restart(true))
	game_over.again_pressed.connect(_restart)
	game_over.title_pressed.connect(func(): _restart(true))
	# tests and autotests go straight in; so does "dig again"
	if skip_title or Progress.dry_run:
		title.visible = false
		skip_title = false
	else:
		title.visible = true
		hud.visible = false
		player.frozen = true
		Sfx.music("music_title")


func _start_run() -> void:
	title.visible = false
	hud.visible = true
	player.frozen = false
	Sfx.music("")


func _unhandled_input(event: InputEvent) -> void:
	# Esc pauses, unless something else used it (shop, sonar, the turret seat take it first)
	if event.is_action_pressed("ui_cancel") and not title.visible and not run_over \
			and not pause.visible and drill.gunner != player:
		pause.open()
		get_viewport().set_input_as_handled()


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
