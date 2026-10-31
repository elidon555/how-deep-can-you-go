extends Node2D
class_name Backdrop
## Everything behind the playfield: the rock wall behind caves (lit by the lamp, holes show
## through), and the parallax layers on a canvas layer below: gloomy hills and forest above
## ground, cave formations below, tinted by depth zone.

# fog colours per depth zone (m): backdrop, far, mid, near
const ZONES := [
	[0.0, Color("0e252b"), Color("2b616b"), Color("1b444c"), Color("0f2b32")],     # teal caves
	[150.0, Color("17112a"), Color("4a3870"), Color("33264f"), Color("1d1530")],   # purple deep
	[400.0, Color("1c0a08"), Color("5c2418"), Color("3d1810"), Color("200c08")],   # red, near the mantle
]
const SKY := [["hills_far", 0.08, 0.3, Color("3b4652")], ["hills_near", 0.2, 0.5, Color("2a333c")],
	["forest", 0.35, 0.7, Color("181d23")]]
const CAVE := [["cave_far", 0.15], ["cave_mid", 0.35], ["cave_near", 0.6]]
const DEEP_FAR_FROM := 350.0   # m: the far layer becomes the vast deep cavern
const BOTTOM_FAR_FROM := World.CAVERN_FROM - 15.0   # and then the carved void above the Floor

var wall := ColorRect.new()
var _layer := CanvasLayer.new()
var _fill := ColorRect.new()
var _sky_clip := Control.new()
var _cave_clip := Control.new()
var _sky := []    # [TextureRect, horizontal scroll, vertical scroll, tint]
var _cave := []   # [TextureRect, scroll, zone colour index]
var _far_tex: Texture2D
var _far_deep_tex: Texture2D
var _far_bottom_tex: Texture2D


func _ready() -> void:
	var wm := ShaderMaterial.new()
	wm.shader = preload("res://src/world/backwall.gdshader")
	wm.set_shader_parameter("wall_tex", load("res://assets/terrain/wall.png"))
	wm.set_shader_parameter("wall_n", load("res://assets/terrain/wall_n.png"))
	wm.set_shader_parameter("mask_tex", load("res://assets/terrain/wall_mask.png"))
	wall.material = wm
	wall.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wall.size = Vector2(900, 560)
	wall.z_index = -1
	add_child(wall)

	_layer.layer = -10
	add_child(_layer)
	_fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_fill)
	for c in [_sky_clip, _cave_clip]:
		c.clip_contents = true
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_layer.add_child(c)
	for d in SKY:
		var t := _tiled(d[0], Vector2(1280 / 2 + 1024, 160))
		_sky_clip.add_child(t)
		_sky.append([t, d[1], d[2], d[3]])
	for i in CAVE.size():
		var t := _tiled(CAVE[i][0], Vector2(1280 / 2 + 512, 720 / 2 + 512))
		_cave_clip.add_child(t)
		_cave.append([t, CAVE[i][1], i])
	_far_tex = _cave[0][0].texture
	var deep := "res://assets/bg/cave_far_deep.png"
	_far_deep_tex = load(deep) if ResourceLoader.exists(deep) else _far_tex
	var bottom := "res://assets/bg/cave_far_bottom.png"
	_far_bottom_tex = load(bottom) if ResourceLoader.exists(bottom) else _far_deep_tex


## Call every frame with the camera.
func follow(cam: Camera2D, depth_m: float) -> void:
	var vs := get_viewport().get_visible_rect().size
	var center := cam.get_screen_center_position()
	var z := cam.zoom.x
	wall.global_position = center - wall.size / 2.0
	wall.modulate = Color(1, 1, 1).lerp(Color(0.8, 0.9, 1.15), clampf(depth_m / 300.0, 0.0, 1.0))
	var horizon := clampf(vs.y / 2.0 - center.y * z, 0.0, vs.y)
	_sky_clip.size = Vector2(vs.x, horizon)
	_cave_clip.position = Vector2(0, horizon)
	_cave_clip.size = Vector2(vs.x, vs.y - horizon)
	var zc := _zone_colours(depth_m)
	if depth_m > BOTTOM_FAR_FROM:
		_cave[0][0].texture = _far_bottom_tex
	else:
		_cave[0][0].texture = _far_deep_tex if depth_m > DEEP_FAR_FROM else _far_tex
	_fill.color = Color("4a5663").lerp(zc[0], clampf(depth_m / 6.0, 0.0, 1.0))
	for L in _sky:
		var t: TextureRect = L[0]
		var bottom: float = vs.y / 2.0 - center.y * z * L[2] + 64.0   # tucks under the ground line
		t.position = Vector2(-fposmod(center.x * L[1], 1024.0) * 2.0, bottom - 320.0)
		t.modulate = L[3]
	for L in _cave:
		var t: TextureRect = L[0]
		var off: Vector2 = center * L[1]
		t.position = Vector2(-fposmod(off.x, 512.0), -fposmod(off.y, 512.0)) * 2.0 - _cave_clip.position
		t.modulate = zc[1 + L[2]]


## Backdrop, far, mid, near colours blended between depth zones.
func _zone_colours(depth_m: float) -> Array:
	var zc: Array = ZONES[0].slice(1)
	for i in range(ZONES.size() - 1):
		var a: Array = ZONES[i]
		var b: Array = ZONES[i + 1]
		if depth_m >= a[0]:
			var t := clampf((depth_m - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			zc = []
			for k in range(1, 5):
				zc.append((a[k] as Color).lerp(b[k], t))
	return zc


func _tiled(name: String, size: Vector2) -> TextureRect:
	var t := TextureRect.new()
	t.texture = load("res://assets/bg/%s.png" % name)
	t.stretch_mode = TextureRect.STRETCH_TILE
	t.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	t.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.scale = Vector2(2, 2)
	t.size = size
	return t
