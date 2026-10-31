extends CanvasLayer
class_name Hud
## On-screen info: depth, best, health, your bag, money, the drill's state, messages, prompts.
## Also owns the vignette + film grain overlay underneath it.

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
const GOLD := Color("f2c14e")

var _depth := Label.new()
var _best := Label.new()
var _ore := Label.new()
var _money := Label.new()
var _ropes := Label.new()
var _toast := Label.new()
var _prompt := Label.new()
var _help := Label.new()
var _hearts := Hearts.new()
var _breath := Breath.new()
var _drill := DrillPanel.new()
var _vignette := ColorRect.new()
var _toast_tween: Tween


func _ready() -> void:
	layer = 10
	var under := CanvasLayer.new()
	under.layer = 5
	add_child(under)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = VIGNETTE
	_vignette.material = mat
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	under.add_child(_vignette)

	_label(_depth, Vector2(24, 12), 56)
	_label(_best, Vector2(28, 84), 24)
	_hearts.position = Vector2(30, 122)
	add_child(_hearts)
	_breath.position = Vector2(30, 248)
	add_child(_breath)
	_label(_ore, Vector2(28, 150), 24, GOLD)
	_label(_money, Vector2(28, 180), 24, Color("9fd88a"))
	_label(_ropes, Vector2(28, 210), 24, Color("d9b98a"))
	_drill.position = Vector2(1280 - 300, 20)
	add_child(_drill)
	_label(_toast, Vector2(0, 150), 36, Color("d9c9b0"))
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.size = Vector2(1280, 60)
	_toast.modulate.a = 0
	_label(_prompt, Vector2(0, 560), 26, Color("f4e3c1"))
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.size = Vector2(1280, 40)
	_label(_help, Vector2(24, 680), 18)
	_help.modulate.a = 0.6
	_help.text = Controls.HELP


func _label(l: Label, pos: Vector2, size: int, color := Color.WHITE) -> void:
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 8)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)


func set_depth(depth: int, best: int, new_best: bool) -> void:
	_depth.text = "%d m" % depth
	_best.text = "Best: %d m" % best
	_best.add_theme_color_override("font_color", GOLD if new_best else Color.WHITE)


func set_health(health: int, max_health: int) -> void:
	_hearts.health = health
	_hearts.max_health = max_health
	_hearts.queue_redraw()


func set_breath(left: float) -> void:
	if not is_equal_approx(left, _breath.left):
		_breath.left = left
		_breath.queue_redraw()


func set_bag(p: Player) -> void:
	_ore.text = ("Ore: %d ($%d)" % [p.ore_count, p.ore_value] if p.ore_count > 0 else "Ore: 0") \
		+ "   Coal: %d" % p.coal
	_ropes.text = "Ropes: unlimited" if GameConfig.infinite_resources() else "Ropes: %d" % p.ropes


func set_drill(d: Drill, player_depth: float) -> void:
	_drill.drill = d
	_drill.away = d.to_local(Vector2(d.global_position.x, player_depth * World.METER)).y / World.METER
	_drill.queue_redraw()


func set_money(money: int) -> void:
	_money.text = "$ unlimited" if GameConfig.infinite_resources() else "$%d" % money


func set_prompt(text: String) -> void:
	_prompt.text = text


func set_vignette(strength: float) -> void:
	_vignette.material.set_shader_parameter("strength", strength)


func toast(text: String, seconds := 2.0) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(seconds)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 1.2)


## Drill status: depth, speed, fuel and hull bars, breach warning, how far you are from it.
class DrillPanel extends Control:
	var drill: Drill
	var away := 0.0     # meters the player is below (+) or above (-) the drill

	func _draw() -> void:
		if drill == null:
			return
		var font := get_theme_default_font()
		draw_rect(Rect2(0, 0, 280, 146), Color(0.04, 0.035, 0.05, 0.75))
		draw_rect(Rect2(0, 0, 280, 146), Color("8a6a42"), false, 2.0)
		var depth := maxi(0, int(drill.global_position.y / World.METER))
		draw_string(font, Vector2(12, 26), "DRILL  %d m" % depth, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("f4e3c1"))
		var sp: String = Drill.SPEED_NAMES[drill.speed]
		if drill.fuel <= 0.0:
			sp = "NO FUEL"
		elif drill.overheated:
			sp = "OVERHEATED"
		draw_string(font, Vector2(150, 26), sp, HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
			Color("d04a3f") if drill.fuel <= 0.0 or drill.overheated else Color("3fd0c0"))
		if Drill.infinite_fuel():
			draw_string(font, Vector2(12, 56), "Fuel   unlimited", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("e0a23a"))
		else:
			_bar(Vector2(12, 40), "Fuel", drill.fuel / drill.max_fuel, Color("e0a23a"))
		_bar(Vector2(12, 66), "Hull", drill.hull / drill.max_hull, Color("c8c8d0"))
		_bar(Vector2(12, 88), "Heat", drill.heat / Drill.HEAT_MAX, Color("e05a3a"), true)
		var leaks := drill.get_breaches().size()
		if leaks > 0 and fmod(Time.get_ticks_msec() / 1000.0, 0.8) < 0.55:
			draw_string(font, Vector2(12, 132), "BREACH x%d — hold E on it to repair" % leaks,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("ff5a4a"))
		elif absf(away) > 3.0:
			var where := "above" if away < 0.0 else "below"
			draw_string(font, Vector2(12, 132), "You are %d m %s the drill" % [absi(int(away)), where],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("d9c9b0"))

	func _bar(at: Vector2, label: String, frac: float, c: Color, high_is_bad := false) -> void:
		var font := get_theme_default_font()
		draw_string(font, at + Vector2(0, 16), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("d9c9b0"))
		draw_rect(Rect2(at + Vector2(50, 4), Vector2(206, 14)), Color(0.1, 0.1, 0.12))
		var bad := frac > 0.8 if high_is_bad else frac <= 0.25
		draw_rect(Rect2(at + Vector2(50, 4), Vector2(206 * clampf(frac, 0.0, 1.0), 14)),
			Color("ff3a2a") if bad and fmod(Time.get_ticks_msec() / 1000.0, 0.5) < 0.25 else (c if not bad else Color("d04a3f")))


## Air bubbles while underwater: they pop one by one; hidden when your breath is full.
class Breath extends Control:
	const BUBBLES := 8
	var left := 1.0

	func _draw() -> void:
		if left >= 0.999:
			return
		for i in BUBBLES:
			var full := float(i) < left * BUBBLES
			var c := Vector2(i * 22 + 9, 9)
			if full:
				draw_circle(c, 8.0, Color(0.55, 0.8, 1.0, 0.9))
				draw_circle(c + Vector2(-3, -3), 2.0, Color(1, 1, 1, 0.9))
			else:
				draw_arc(c, 7.0, 0.0, TAU, 16, Color(0.4, 0.55, 0.7, 0.5), 1.5)


## Pixel hearts, full or empty.
class Hearts extends Control:
	const SHAPE := [".xx.xx.", "xxxxxxx", "xxxxxxx", ".xxxxx.", "..xxx..", "...x..."]
	const PX := 4
	var health := 3
	var max_health := 3

	func _draw() -> void:
		for h in max_health:
			var full := h < health
			for y in SHAPE.size():
				for x in SHAPE[y].length():
					if SHAPE[y][x] == "x":
						var c := Color("d8323a") if full else Color(0.2, 0.15, 0.17, 0.8)
						if full and y == 1 and x == 1:
							c = Color("ff8a8a")
						draw_rect(Rect2(h * 34 + x * PX, y * PX, PX, PX), c)
