extends CanvasLayer
class_name Hud
## On-screen info: depth, best, health, ore carried, money, ropes, messages, prompts, controls.
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
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	under.add_child(_vignette)

	_label(_depth, Vector2(24, 12), 56)
	_label(_best, Vector2(28, 84), 24)
	_hearts.position = Vector2(30, 122)
	add_child(_hearts)
	_label(_ore, Vector2(28, 150), 24, GOLD)
	_label(_money, Vector2(28, 180), 24, Color("9fd88a"))
	_label(_ropes, Vector2(28, 210), 24, Color("d9b98a"))
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


func set_ore(count: int, value: int) -> void:
	_ore.text = "Ore: %d  ($%d)" % [count, value] if count > 0 else "Ore: 0"


func set_money(money: int) -> void:
	_money.text = "$%d" % money


func set_ropes(ropes: int) -> void:
	_ropes.text = "Ropes: %d" % ropes


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
