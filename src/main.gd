extends Node2D
## Puts the game together: world, player, camera, lighting, creatures, camp + shop, HUD.
## Game rules that span systems live here: carrying ore, selling it at the surface, ropes
## per trip, dying, milestones.

const MILESTONES := {
	10: "The daylight is gone", 25: "It's very quiet down here", 50: "Something is watching you",
	100: "100 m. Nobody has dug this deep", 200: "The rock feels... warm", 300: "You hear breathing",
	500: "Half a kilometer. Turn back?", 1000: "1 km. It knows you're here",
}
const CAMP_OFFSET := -110.0     # camp sits left of the spawn point

var world: World
var player: Player
var cam := Camera2D.new()
var dark := CanvasModulate.new()
var glow_layer := CanvasLayer.new()
var backdrop := Backdrop.new()
var fx := Fx.new()
var hud := Hud.new()
var shop := Shop.new()
var camp := Camp.new()
var spawner := Spawner.new()
var motes := CPUParticles2D.new()

var carried := 0          # ore pieces in your bag
var carried_value := 0
var ropes := 0
var shake := 0.0
var time := 0.0
var flicker_t := 0.0
var shown := {}
var new_best := false
var at_surface := false


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

	player = Player.new()
	player.world = world
	player.position = Vector2(World.WIDTH_PX / 2.0, -40)
	add_child(player)
	player.pick.struck.connect(_on_struck)
	player.pick.hit_thing.connect(_on_hit_thing)
	player.rope_requested.connect(_on_rope_requested)
	player.health_changed.connect(hud.set_health)
	player.died.connect(_on_died)
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

	add_child(camp)
	camp.place(world, World.WIDTH_PX / 2.0 + CAMP_OFFSET, glow_layer)
	spawner.world = world
	spawner.player = player
	spawner.lit_parent = self
	spawner.glow_parent = glow_layer
	spawner.crawler_killed.connect(_on_crawler_killed)
	add_child(spawner)

	add_child(hud)
	hud.add_child(shop)
	shop.closed.connect(func(): player.frozen = false)
	Progress.changed.connect(_on_progress_changed)
	ropes = Progress.rope_capacity()
	hud.set_health(player.health, player.max_health)
	_update_bag()
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
	for m in MILESTONES:
		if depth >= m and not shown.has(m):
			shown[m] = true
			hud.toast(MILESTONES[m])
	_update_light(depth, dt)
	_update_camp(depth)

	shake = maxf(shake - dt * 6.0, 0.0)
	cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake * 3.0
	if Input.is_action_just_pressed("restart"):
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


## Back at the surface: sell ore, heal, refill ropes. By the stall: open the shop.
func _update_camp(depth: int) -> void:
	var home := depth == 0 and player.is_on_floor() and player.health > 0
	if home and (not at_surface or carried > 0):
		if carried > 0:
			Progress.add_money(carried_value)
			hud.toast("Sold %d ore for $%d" % [carried, carried_value])
			Sfx.play("coins")
			carried = 0
			carried_value = 0
		player.heal_full()
		ropes = maxi(ropes, Progress.rope_capacity())
		Progress.save()
		_update_bag()
	at_surface = home
	var at_stall := camp.near(player.global_position) and player.health > 0
	hud.set_prompt("E: trade with the merchant" if at_stall and not shop.visible else "")
	if at_stall and not shop.visible and Input.is_action_just_pressed("interact"):
		shop.open()
		player.frozen = true
		Sfx.play("ui_click", Vector2.INF)


## Upgrades bought at the stall apply right away (more health, more ropes).
func _on_progress_changed() -> void:
	if at_surface:
		player.heal_full()
		ropes = maxi(ropes, Progress.rope_capacity())
	_update_bag()


func _update_bag() -> void:
	hud.set_ore(carried, carried_value)
	hud.set_money(Progress.money)
	hud.set_ropes(ropes)


# ---------------------------------------------------------------- events

func _on_struck(pos: Vector2, mat: int, broke: int, kind: String) -> void:
	shake = maxf(shake, 0.25 if kind == "bonk" else (0.6 if broke > 0 else 0.35))
	fx.impact(pos, mat, broke, kind, player.facing)


func _on_hit_thing(pos: Vector2) -> void:
	shake = maxf(shake, 0.5)
	fx.flesh(pos, player.facing)


func _on_ore_found(pos: Vector2, kind: int) -> void:
	var ore: Array = World.ORES[kind]
	carried += 1
	carried_value += ore[1]
	shake = maxf(shake, 0.8)
	var c: Color = ore[3]
	fx.burst(pos, Color(c.r * 2.0, c.g * 2.0, c.b * 2.0), 14, 140.0, Vector2.UP, 180.0, 0.6, 2.5, true)
	Sfx.play("ore", pos)
	hud.toast("+ %s" % ore[0], 0.6)
	_update_bag()


func _on_boulder_shattered(pos: Vector2) -> void:
	shake = maxf(shake, 0.9)
	fx.impact(pos, World.M.STONE, 3, "dig_down", player.facing)


func _on_crawler_killed(pos: Vector2) -> void:
	carried += 1
	carried_value += 2          # crawlers carry a shiny bit or two
	hud.toast("+ $2", 0.6)
	_update_bag()


func _on_rope_requested(feet: Vector2) -> void:
	if ropes <= 0:
		hud.toast("No ropes left. More at the surface.", 1.2)
		return
	ropes -= 1
	var r := Rope.hang(world, feet)
	world.add_child(r)
	Sfx.play("rope", feet)
	_update_bag()


func _on_died() -> void:
	var depth := maxi(0, int(player.position.y / World.METER))
	player.frozen = true
	hud.toast("You died at %d m. The ore you carried is lost." % depth, 3.0)
	Progress.save()
	await get_tree().create_timer(3.0).timeout
	get_tree().reload_current_scene()


func _restart() -> void:
	Progress.save()
	get_tree().reload_current_scene()


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


## Test mode: `godot -- --autotest=/path/shot.png` digs down by itself (fast) and saves screenshots.
func _autotest() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest="):
			out = a.trim_prefix("--autotest=")
	if out == "":
		return
	Progress.levels["pick"] = 3
	fx.hitstop_enabled = false
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(out.replace(".png", "_0.png"))
	Input.action_press("dig")
	Input.action_press("down")
	for i in 4:
		await get_tree().create_timer(5.0).timeout
		if i == 1 or i == 3:
			Input.action_release("down")
			Input.action_press("right")
			await get_tree().create_timer(1.2).timeout
			Input.action_release("right")
			await get_tree().create_timer(0.3).timeout
		get_viewport().get_texture().get_image().save_png(out.replace(".png", "_%d.png" % (i + 1)))
		print("autotest depth=", int(player.position.y / World.METER), " ore=", carried,
			" creatures=", get_tree().get_nodes_in_group("creature").size(), " hp=", player.health)
		Input.action_press("down")
	get_tree().quit()
