extends Node2D
class_name DrillModules
## What's been built onto the drill (bought once at the workbench, Progress "modules"), each
## visible on the hull and run off the right fuse box:
##   cargo        a hold on the roof: ore the head grinds through is kept, sold at the workbench
##   floodlights  lamps on the roof lighting the shaft around the drill
##   sprinklers   ceiling nozzles that douse cabin fires (DrillFires)
##   drone        a little defence drone that zaps creatures near the drill
##   bunk         crew quarters: a bled-out miner is back sooner (main)

const DIR := "res://assets/drill/"
const ALL := ["cargo", "floodlights", "sprinklers", "drone", "bunk"]
const CARGO_RANGE := 150.0     # ore ground this close to the drill goes into the hold

var drill: Drill
var _built := {}               # module -> its visuals (Node2D)
var _lights: Array[PointLight2D] = []


func _ready() -> void:
	drill.world.ore_ground.connect(_on_ore_ground)


func has(m: String) -> bool:
	return Progress.level(m) > 0


## (Re)builds the visuals for what's installed (upgrades bought, or a client's mirror changed).
func build() -> void:
	for m in ALL:
		if has(m) and not _built.has(m):
			_built[m] = _make(m)
			add_child(_built[m])


func _make(m: String) -> Node2D:
	var n := Node2D.new()
	match m:
		"cargo":
			n.add_child(_sprite("cargo.png", Vector2(-50, Drill.TOP)))
		"floodlights":
			for side in [-1.0, 1.0]:
				n.add_child(_sprite("floodlight.png", Vector2(side * 76.0, Drill.TOP)))
				var l := PointLight2D.new()
				l.texture = Player._cone_texture()
				l.color = Color("fff0d0")
				l.texture_scale = 2.6
				l.energy = 1.1
				l.position = Vector2(side * 80.0, Drill.TOP - 4.0)
				l.rotation = PI / 2.0 + side * 0.55       # (a light's aim, not a sprite)
				n.add_child(l)
				_lights.append(l)
		"sprinklers":
			for x in [-50.0, 0.0, 50.0]:
				n.add_child(_sprite("sprinkler.png", Vector2(x, Drill.ROOF + 6.0)))
		"drone":
			n.add_child(_sprite("drone.png", Vector2(50, Drill.TOP)))       # its dock
			if not Net.is_client():
				var d := Drone.new()
				d.drill = drill
				d.position = drill.global_position + Vector2(50, Drill.TOP - 10)
				drill.get_parent().add_child.call_deferred(d)
		"bunk":
			n.add_child(_sprite("../props/bunk.png", Vector2(10, Drill.TOP)))
	return n


func _sprite(file: String, bottom_centre: Vector2) -> Node2D:
	var path := DIR + file
	if not ResourceLoader.exists(path):
		var box := Polygon2D.new()                 # until the art exists
		box.polygon = PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 0), Vector2(-8, 0)])
		box.color = Color("4a4f58")
		box.position = bottom_centre
		return box
	var s := Sprite2D.new()
	s.texture = Art.lit(path)
	s.centered = false
	s.offset = Vector2(-s.texture.get_width() / 2.0, -s.texture.get_height())
	s.position = bottom_centre
	var glow := path.get_basename() + "_glow.png"
	if ResourceLoader.exists(glow):
		var g := Sprite2D.new()
		g.texture = load(glow)
		g.centered = false
		g.offset = s.offset
		var unlit := CanvasItemMaterial.new()
		unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		g.material = unlit
		s.add_child(g)
	return s


func _process(_dt: float) -> void:
	var on := drill.power.level("modules")
	for l in _lights:
		l.enabled = on > 0.05
		l.energy = 1.1 * on


func _on_ore_ground(pos: Vector2, kind: int) -> void:
	if not has("cargo") or pos.distance_to(drill.global_position) > CARGO_RANGE or kind == World.COAL:
		return
	drill.cargo_count += 1
	drill.cargo_value += World.ORES[kind][1]
	drill.changed.emit()
