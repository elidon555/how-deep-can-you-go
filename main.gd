extends Node2D
## Sets up the game: world, player, camera, darkness, glow, horror atmosphere, HUD.

const SAVE_PATH := "user://best.txt"
const MILESTONES := {
	10: "The daylight is gone", 25: "It's very quiet down here", 50: "Something is watching you",
	100: "100 m. Nobody has dug this deep", 200: "The rock feels... warm", 300: "You hear breathing",
	500: "Half a kilometer. Turn back?", 1000: "1 km. It knows you're here",
}
const VIGNETTE := """
shader_type canvas_item;
uniform float strength = 0.3;
void fragment() {
	vec2 uv = UV - 0.5;
	float v = smoothstep(0.3, 0.85, length(uv * vec2(1.7, 1.0))) * strength;
	float grain = fract(sin(dot(floor(UV * vec2(640.0, 360.0)) + floor(TIME * 24.0) * 7.13,
		vec2(12.9898, 78.233))) * 43758.5453);
	COLOR = vec4(0.0, 0.0, 0.0, clamp(v + grain * 0.07, 0.0, 1.0));
}
"""

var world: World
var player: Player
var cam := Camera2D.new()
var dark := CanvasModulate.new()
var glow_layer := CanvasLayer.new()
var back_wall := TextureRect.new()
var motes := CPUParticles2D.new()
var vignette := ColorRect.new()
var depth_label := Label.new()
var best_label := Label.new()
var ore_label := Label.new()
var toast := Label.new()
var help := Label.new()

var best := 0
var ore := 0
var shake := 0.0
var dust_t := 0.0
var watch_t := 5.0
var flicker_t := 0.0
var time := 0.0
var shown := {}


func _ready() -> void:
	_setup_input()
	best = _load_best()

	world = World.new()

	# dark rock wall behind the tiles (lit by the lamp, so caves read as caves)
	back_wall.texture = world.make_wall_texture()
	back_wall.stretch_mode = TextureRect.STRETCH_TILE
	back_wall.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	back_wall.position = Vector2(0, World.TILE * 0.5)
	back_wall.size = Vector2(World.WIDTH * World.TILE, 2.0e6)
	back_wall.z_index = -1
	add_child(back_wall)

	add_child(world)
	world.tile_broken.connect(_on_tile_broken)

	# glowing things live on their own layer: not darkened, they bloom
	glow_layer.layer = 1
	glow_layer.follow_viewport_enabled = true
	add_child(glow_layer)
	glow_layer.add_child(world.glow)

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

	add_child(dark)
	_setup_glow()
	_setup_motes()
	_setup_hud()
	_autotest()


func _process(dt: float) -> void:
	time += dt
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

	# gloomy sky -> pitch black; light fades within the first ~30 m
	var t := clampf(depth / 300.0, 0.0, 1.0)
	RenderingServer.set_default_clear_color(Color("56636f").lerp(Color("040508"), clampf(depth / 12.0, 0.0, 1.0)))
	var light := clampf(1.0 - depth / 30.0, 0.0, 1.0)
	dark.color = Color(1, 1, 1).lerp(Color(0.06, 0.065, 0.1), 1.0 - light)
	back_wall.modulate = Color(1, 1, 1).lerp(Color(0.8, 0.9, 1.15), t)
	player.lamp_on = light < 1.0
	motes.emitting = depth > 3
	vignette.material.set_shader_parameter("strength", lerpf(0.25, 0.85, clampf(depth / 60.0, 0.0, 1.0)))

	# lamp flicker: always a little, and sometimes it nearly dies
	player.light_mul = 0.94 + 0.06 * sin(time * 13.0) * sin(time * 7.3)
	flicker_t -= dt
	if depth > 30 and flicker_t < -2.0 and randf() < dt * 0.12:
		flicker_t = randf_range(0.2, 0.5)
	if flicker_t > 0.0:
		player.light_mul = randf_range(0.05, 0.6)

	# eyes in the dark
	watch_t -= dt
	if depth > 15 and watch_t <= 0.0:
		watch_t = randf_range(3.0, 8.0)
		if get_tree().get_nodes_in_group("watcher").size() < 3:
			_spawn_watcher()

	shake = maxf(shake - dt * 6.0, 0.0)
	cam.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * shake * 3.0
	dust_t -= dt
	if Input.is_action_just_pressed("restart"):
		_save_best()
		get_tree().reload_current_scene()


func _spawn_watcher() -> void:
	var pc := world.local_to_map(player.position)
	for i in 30:
		var c := pc + Vector2i(randi_range(-12, 12), randi_range(-7, 7))
		if c.x <= 0 or c.x >= World.WIDTH - 1 or c.y < 3:
			continue
		if world.get_type(c) != -1 or world.dug.has(c):
			continue   # only in natural caves, never in your own tunnel
		var pos := world.map_to_local(c)
		if pos.distance_to(player.position) < 110.0:
			continue
		var w := Watcher.new()
		w.player = player
		w.position = pos
		w.add_to_group("watcher")
		glow_layer.add_child(w)
		return


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
		_burst(cell, Color(2.0, 1.5, 0.5), 10, 120.0, true)


func _burst(cell: Vector2i, color: Color, amount: int, speed: float, glowing := false) -> void:
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
	p.color = color.lightened(0.15) if not glowing else color
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(6, 6)
	p.z_index = 2
	var parent: Node = glow_layer if glowing else self
	parent.add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)


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
	motes.emission_rect_extents = Vector2(230, 140)
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


func _setup_hud() -> void:
	var fx := CanvasLayer.new()
	fx.layer = 5
	add_child(fx)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = VIGNETTE
	vignette.material = mat
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	fx.add_child(vignette)

	var hud := CanvasLayer.new()
	hud.layer = 10
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
	toast.add_theme_color_override("font_color", Color("d9c9b0"))
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.size = Vector2(1280, 60)
	toast.position = Vector2(0, 150)
	toast.modulate.a = 0
	help.add_theme_font_size_override("font_size", 18)
	help.position = Vector2(24, 680)
	help.modulate.a = 0.6
	help.text = "A/D move · Space jump · S dig down · W dig up · walk into walls to dig · R restart"


func _toast(text: String) -> void:
	toast.text = text
	toast.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(2.0)
	tw.tween_property(toast, "modulate:a", 0.0, 1.2)


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


## Test mode: `godot -- --autotest=/path/shot.png` digs down by itself (fast) and saves screenshots.
func _autotest() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--autotest="):
			out = a.trim_prefix("--autotest=")
	if out == "":
		return
	player.dig_power = 12.0
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(out.replace(".png", "_0.png"))
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
		print("autotest depth=", int(player.position.y / World.TILE), " ore=", ore,
			" watchers=", get_tree().get_nodes_in_group("watcher").size())
		Input.action_press("down")
	get_tree().quit()
