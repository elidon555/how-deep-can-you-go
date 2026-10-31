extends Node2D
## Sets up the game: world, player, camera, darkness + lamp, HUD, juice.

const SAVE_PATH := "user://best.txt"
const MILESTONES := {
	10: "Under the grass", 25: "Getting dark...", 50: "Deeper than a well",
	100: "100 m! Stone country", 200: "Hard rock begins", 300: "Very deep",
	500: "Half a kilometer!", 1000: "1 km — deeper than most mines",
}

var world: World
var player: Player
var cam := Camera2D.new()
var dark := CanvasModulate.new()
var lamp := PointLight2D.new()
var depth_label := Label.new()
var best_label := Label.new()
var ore_label := Label.new()
var toast := Label.new()
var help := Label.new()

var best := 0
var ore := 0
var shake := 0.0
var dust_t := 0.0
var shown := {}
var back_wall := ColorRect.new()


func _ready() -> void:
	_setup_input()
	best = _load_best()

	# dark wall behind the tiles (gets lit by the lamp, so caves read as caves)
	back_wall.position = Vector2(0, World.TILE * 0.5)
	back_wall.size = Vector2(World.WIDTH * World.TILE, 1.0e7)
	back_wall.z_index = -1
	add_child(back_wall)

	world = World.new()
	add_child(world)
	world.tile_broken.connect(_on_tile_broken)

	player = Player.new()
	player.world = world
	player.position = Vector2(World.WIDTH * World.TILE / 2.0, -20)
	add_child(player)
	player.digging.connect(_on_digging)

	cam.zoom = Vector2(3, 3)
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 8.0
	cam.limit_left = 0
	cam.limit_right = World.WIDTH * World.TILE
	player.add_child(cam)

	# darkness that grows with depth, plus a lamp on the player's helmet
	add_child(dark)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 256
	gt.height = 256
	lamp.texture = gt
	lamp.texture_scale = 0.7
	lamp.color = Color("ffe7b0")
	lamp.energy = 1.2
	lamp.position = Vector2(0, -2)
	player.add_child(lamp)

	_setup_hud()
	_autotest()


func _process(dt: float) -> void:
	var depth := maxi(0, int(floor(player.position.y / World.TILE)) + 1)
	world.ensure_generated(depth + World.AHEAD)

	depth_label.text = "%d m" % depth
	if depth > best:
		best = depth
		best_label.add_theme_color_override("font_color", Color("f2c14e"))
	best_label.text = "Best: %d m" % best
	ore_label.text = "Ore: %d" % ore
	for m in MILESTONES:
		if depth >= m and not shown.has(m):
			shown[m] = true
			_toast(MILESTONES[m])

	# sky → brown → black as you go down
	var t := clampf(depth / 300.0, 0.0, 1.0)
	var sky := Color("8fc7e8").lerp(Color("2a1d17"), clampf(depth / 15.0, 0.0, 1.0))
	RenderingServer.set_default_clear_color(sky.lerp(Color("07060a"), t))
	back_wall.color = Color("3a2618").lerp(Color("1e1c26"), t)
	var light := clampf(1.0 - depth / 40.0, 0.0, 1.0)
	dark.color = Color(1, 1, 1).lerp(Color(0.09, 0.08, 0.12), 1.0 - light)
	lamp.texture_scale = lerpf(0.7, 0.45, t)
	lamp.enabled = light < 1.0

	shake = maxf(shake - dt * 6.0, 0.0)
	cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake * 3.0
	dust_t -= dt
	if Input.is_action_just_pressed("restart"):
		_save_best()
		get_tree().reload_current_scene()


func _on_digging(cell: Vector2i) -> void:
	shake = maxf(shake, 0.15)
	if dust_t <= 0:
		dust_t = 0.08
		_burst(cell, World.COLORS[world.get_type(cell)], 3, 40.0)


func _on_tile_broken(cell: Vector2i, type: int) -> void:
	shake = maxf(shake, 0.5 if type == World.T.DIRT else 0.9)
	_burst(cell, World.COLORS[type], 14, 90.0)
	if type == World.T.ORE:
		ore += 1
		_burst(cell, Color("f2c14e"), 10, 120.0)


func _burst(cell: Vector2i, color: Color, amount: int, speed: float) -> void:
	var p := CPUParticles2D.new()
	p.position = world.map_to_local(cell)
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = 0.6
	p.direction = Vector2(0, -1)
	p.spread = 180.0
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector2(0, 400)
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.5
	p.color = color.lightened(0.15)
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(6, 6)
	p.z_index = 2
	add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)


func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	add_child(hud)
	for l in [depth_label, best_label, ore_label, toast, help]:
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 8)
		hud.add_child(l)
	depth_label.add_theme_font_size_override("font_size", 56)
	depth_label.position = Vector2(24, 12)
	best_label.add_theme_font_size_override("font_size", 24)
	best_label.position = Vector2(28, 84)
	ore_label.add_theme_font_size_override("font_size", 24)
	ore_label.add_theme_color_override("font_color", Color("f2c14e"))
	ore_label.position = Vector2(28, 116)
	toast.add_theme_font_size_override("font_size", 36)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.size = Vector2(1280, 60)
	toast.position = Vector2(0, 150)
	toast.modulate.a = 0
	help.add_theme_font_size_override("font_size", 18)
	help.position = Vector2(24, 680)
	help.modulate.a = 0.7
	help.text = "A/D move · Space jump · S dig down · W dig up · walk into walls to dig · R restart"


func _toast(text: String) -> void:
	toast.text = text
	toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.5)
	tw.tween_property(toast, "modulate:a", 0.0, 0.8)


func _setup_input() -> void:
	var map := {
		"left": [KEY_A, KEY_LEFT], "right": [KEY_D, KEY_RIGHT],
		"up": [KEY_W, KEY_UP], "down": [KEY_S, KEY_DOWN],
		"jump": [KEY_SPACE, KEY_K], "restart": [KEY_R],
	}
	var pad := {
		"left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT,
		"up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN,
		"jump": JOY_BUTTON_A, "restart": JOY_BUTTON_BACK,
	}
	var stick := {"left": [JOY_AXIS_LEFT_X, -1.0], "right": [JOY_AXIS_LEFT_X, 1.0],
		"up": [JOY_AXIS_LEFT_Y, -1.0], "down": [JOY_AXIS_LEFT_Y, 1.0]}
	for action in map:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.4)
		for k in map[action]:
			var e := InputEventKey.new()
			e.physical_keycode = k
			InputMap.action_add_event(action, e)
		var b := InputEventJoypadButton.new()
		b.button_index = pad[action]
		InputMap.action_add_event(action, b)
		if stick.has(action):
			var m := InputEventJoypadMotion.new()
			m.axis = stick[action][0]
			m.axis_value = stick[action][1]
			InputMap.action_add_event(action, m)


func _load_best() -> int:
	if FileAccess.file_exists(SAVE_PATH):
		return int(FileAccess.get_file_as_string(SAVE_PATH))
	return 0


func _save_best() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(str(best))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_best()


## Test mode: `godot -- --autotest=/path/shot.png` digs down by itself and saves screenshots.
func _autotest() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest="):
			out = a.trim_prefix("--autotest=")
	if out == "":
		return
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(out.replace(".png", "_0.png"))
	Input.action_press("down")
	for i in 3:
		await get_tree().create_timer(5.0).timeout
		if i == 1:
			Input.action_press("right")
			await get_tree().create_timer(0.6).timeout
			Input.action_release("right")
		get_viewport().get_texture().get_image().save_png(out.replace(".png", "_%d.png" % (i + 1)))
		print("autotest depth=", int(player.position.y / World.TILE), " ore=", ore)
	get_tree().quit()
