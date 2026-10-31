extends Node2D
class_name Drone
## The drone module: a little defence drone that hovers by the drill and zaps the nearest
## creature in reach every so often (needs power: the right fuse box). Online: the host's flies,
## clients show it (net_state / net_apply).

const REACH := 150.0
const ZAP_EVERY := 1.5
const DAMAGE := 1
const TEX := "res://assets/drill/drone.png"
const TEX_GLOW := "res://assets/drill/drone_glow.png"

var drill: Drill
var puppet := false
var velocity := Vector2.ZERO
var _t := randf() * 10.0
var _zap_t := 0.0
var _zap_to := Vector2.ZERO        # where the last zap went (global), drawn for a moment
var _cool := ZAP_EVERY
var _sprite := Sprite2D.new()
var _buzz := AudioStreamPlayer2D.new()


func _ready() -> void:
	add_to_group("net")
	z_index = 3
	if ResourceLoader.exists(TEX):
		_sprite.texture = Art.lit(TEX)
		add_child(_sprite)
		if ResourceLoader.exists(TEX_GLOW):
			var g := Sprite2D.new()
			g.texture = load(TEX_GLOW)
			var unlit := CanvasItemMaterial.new()
			unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
			g.material = unlit
			_sprite.add_child(g)
	_buzz.stream = Sfx.looping("drone_buzz")
	_buzz.bus = "SFX"
	_buzz.volume_db = -16.0
	_buzz.max_distance = 400.0
	add_child(_buzz)
	if _buzz.stream:
		_buzz.play()


func _physics_process(dt: float) -> void:
	_t += dt
	_zap_t -= dt
	queue_redraw()
	if puppet or drill == null:
		return
	if not drill.modules.has("drone"):
		queue_free()
		return
	# hover beside the drill's roof, drifting in a slow figure-eight
	var home := drill.global_position + Vector2(sin(_t * 0.7) * 70.0, Drill.TOP - 26.0 + sin(_t * 1.4) * 10.0)
	velocity = velocity.lerp((home - global_position) * 2.0, 3.0 * dt)
	global_position += velocity * dt
	_cool -= dt * drill.power.level("modules")
	if _cool <= 0.0:
		var target := _nearest_creature()
		if target:
			_cool = ZAP_EVERY
			_zap_to = target.global_position
			_zap_t = 0.12
			target.hit(DAMAGE, global_position)
			Sfx.play("spark", global_position, -6.0)


func _nearest_creature() -> Node2D:
	var best: Node2D = null
	for n: Node2D in get_tree().get_nodes_in_group("hittable"):
		if n is Boulder or n.global_position.distance_to(global_position) > REACH:
			continue
		if best == null or n.global_position.distance_to(global_position) < best.global_position.distance_to(global_position):
			best = n
	return best


func _draw() -> void:
	if not _sprite.texture:
		draw_circle(Vector2.ZERO, 4.0, Color("3a3f47"))
		draw_circle(Vector2(2, 0), 1.5, Color(0.4, 1.8, 2.2))
	if _zap_t > 0.0:
		var to := to_local(_zap_to)
		var mid := to * 0.5 + Vector2(randf_range(-4, 4), randf_range(-4, 4))
		draw_polyline(PackedVector2Array([Vector2.ZERO, mid, to]), Color(1.2, 2.2, 2.6), 1.0)


func net_state() -> Array:
	return [_zap_to, _zap_t]


func net_apply(s: Array) -> void:
	_zap_to = s[0]
	_zap_t = maxf(_zap_t, s[1])
