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
var fx := Fx.new()
var back_wall := ColorRect.new()
var motes := CPUParticles2D.new()
var vignette := ColorRect.new()
var bg := CanvasLayer.new()
var bg_fill := ColorRect.new()
var sky_clip := Control.new()
var cave_clip := Control.new()
var sky_layers := []    # [TextureRect, horizontal scroll, vertical scroll, tint at surface]
var cave_layers := []   # [TextureRect, scroll, index]
# fog colours per depth zone (m): backdrop, far, mid, near
const ZONES := [
	[0.0, Color("0e252b"), Color("2b616b"), Color("1b444c"), Color("0f2b32")],     # teal caves
	[150.0, Color("17112a"), Color("4a3870"), Color("33264f"), Color("1d1530")],   # purple deep
	[400.0, Color("1c0a08"), Color("5c2418"), Color("3d1810"), Color("200c08")],   # red, near the mantle
]
var depth_label := Label.new()
var best_label := Label.new()
var ore_label := Label.new()
var toast := Label.new()
var help := Label.new()

var best := 0
var ore := 0
var shake := 0.0
var watch_t := 5.0
var flicker_t := 0.0
var time := 0.0
var shown := {}


func _ready() -> void:
	_setup_input()
	best = _load_best()

	world = World.new()

	# rock wall behind the caves (lit by the lamp); follows the camera, holes show the far background
	var wm := ShaderMaterial.new()
	wm.shader = preload("res://backwall.gdshader")
	wm.set_shader_parameter("wall_tex", load("res://assets/terrain/wall.png"))
	wm.set_shader_parameter("wall_n", load("res://assets/terrain/wall_n.png"))
	wm.set_shader_parameter("mask_tex", load("res://assets/terrain/wall_mask.png"))
	back_wall.material = wm
	back_wall.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back_wall.size = Vector2(900, 560)
	back_wall.z_index = -1
	add_child(back_wall)

	add_child(world)
	world.ore_found.connect(_on_ore_found)

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
	_setup_background()
	_setup_glow()
	_setup_motes()
	_setup_hud()
	_autotest()


func _process(dt: float) -> void:
	time += dt
	var depth := maxi(0, int(floor(player.position.y / World.METER)))
	world.ensure_generated(player.position.y + 900.0)
	back_wall.global_position = cam.get_screen_center_position() - back_wall.size / 2.0
	_update_background(player.position.y / World.METER)

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
	dark.color = Color(1, 1, 1).lerp(Color(0.13, 0.15, 0.22), 1.0 - light)
	if "--bright" in OS.get_cmdline_user_args():
		dark.color = Color.WHITE
	back_wall.modulate = Color(1, 1, 1).lerp(Color(0.8, 0.9, 1.15), t)
	player.lamp_on = light < 1.0
	player.sprite.modulate = Color(1, 1, 1).lerp(Color(0.72, 0.74, 0.82), 1.0 - light)
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
	if Input.is_action_just_pressed("restart"):
		_save_best()
		get_tree().reload_current_scene()


func _spawn_watcher() -> void:
	for i in 30:
		var pos := player.position + Vector2(randf_range(-300, 300), randf_range(-170, 170))
		if pos.x < 40 or pos.x > World.WIDTH_PX - 40 or pos.y < 60:
			continue
		if pos.distance_to(player.position) < 180.0:
			continue
		var ok := true
		for o in [Vector2.ZERO, Vector2(-12, 0), Vector2(12, 0), Vector2(0, -12), Vector2(0, 12)]:
			var c := world.cell_at(pos + o)
			if world.get_fill(c.x, c.y) > 0.2 or world.dug.has(c):
				ok = false   # only in open natural caves, never in your own tunnel
		if not ok:
			continue
		var w := Watcher.new()
		w.player = player
		w.position = pos
		w.add_to_group("watcher")
		glow_layer.add_child(w)
		return


func _on_struck(pos: Vector2, mat: int, broke: int, kind: String) -> void:
	shake = maxf(shake, 0.25 if kind == "bonk" else (0.6 if broke > 0 else 0.35))
	fx.impact(pos, mat, broke, kind, player.facing)


func _on_ore_found(pos: Vector2) -> void:
	ore += 1
	shake = maxf(shake, 0.8)
	fx.burst(pos, Color(2.0, 1.5, 0.5), 14, 140.0, Vector2.UP, 180.0, 0.6, 2.5, true)


func _setup_background() -> void:
	bg.layer = -10
	add_child(bg)
	bg_fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(bg_fill)
	for c in [sky_clip, cave_clip]:
		c.clip_contents = true
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bg.add_child(c)
	var sky := [["hills_far", 0.08, 0.3, Color("3b4652")], ["hills_near", 0.2, 0.5, Color("2a333c")],
		["forest", 0.35, 0.7, Color("181d23")]]
	for d in sky:
		var t := _bg_rect(d[0], Vector2(1280 / 2 + 1024, 160))
		sky_clip.add_child(t)
		sky_layers.append([t, d[1], d[2], d[3]])
	var cave := [["cave_far", 0.15], ["cave_mid", 0.35], ["cave_near", 0.6]]
	for i in cave.size():
		var t := _bg_rect(cave[i][0], Vector2(1280 / 2 + 512, 720 / 2 + 512))
		cave_clip.add_child(t)
		cave_layers.append([t, cave[i][1], i])


func _bg_rect(name: String, size: Vector2) -> TextureRect:
	var t := TextureRect.new()
	t.texture = load("res://assets/bg/%s.png" % name)
	t.stretch_mode = TextureRect.STRETCH_TILE
	t.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.scale = Vector2(2, 2)
	t.size = size
	return t


func _update_background(depth_m: float) -> void:
	var vs := get_viewport().get_visible_rect().size
	var center := cam.get_screen_center_position()
	var z := cam.zoom.x
	var horizon := clampf(vs.y / 2.0 - center.y * z, 0.0, vs.y)
	sky_clip.size = Vector2(vs.x, horizon)
	cave_clip.position = Vector2(0, horizon)
	cave_clip.size = Vector2(vs.x, vs.y - horizon)
	# fog colours blend between depth zones
	var zc: Array = ZONES[0]
	for i in range(ZONES.size() - 1):
		var a: Array = ZONES[i]
		var b: Array = ZONES[i + 1]
		if depth_m >= a[0]:
			var t := clampf((depth_m - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			zc = [0.0]
			for k in range(1, 5):
				zc.append((a[k] as Color).lerp(b[k], t))
	var under := clampf(depth_m / 6.0, 0.0, 1.0)
	bg_fill.color = Color("4a5663").lerp(zc[1], under)
	for L in sky_layers:
		var t: TextureRect = L[0]
		var bottom: float = vs.y / 2.0 - center.y * z * L[2] + 40.0
		t.position = Vector2(-fposmod(center.x * L[1], 1024.0) * 2.0, bottom - 320.0)
		t.modulate = L[3]
	for L in cave_layers:
		var t: TextureRect = L[0]
		var off: Vector2 = center * L[1]
		t.position = Vector2(-fposmod(off.x, 512.0), -fposmod(off.y, 512.0)) * 2.0 - cave_clip.position
		t.modulate = zc[2 + L[2]]


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
	player.pick.power = 9.0
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
		print("autotest depth=", int(player.position.y / World.METER), " ore=", ore,
			" watchers=", get_tree().get_nodes_in_group("watcher").size())
		Input.action_press("down")
	get_tree().quit()
