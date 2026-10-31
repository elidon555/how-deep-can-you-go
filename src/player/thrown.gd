extends Node2D
class_name Thrown
## Something a miner threw (PlayerTools): it arcs, bounces off rock and comes to rest.
##   flare     burns red for LIFE seconds: light in the dark, and creatures keep their distance
##             (they ask Thrown.scary_near)
##   dynamite  fuse, then a blast: a big crater, hurts whoever's close (crew included), knocks
##             the drill, kills creatures and sets off gas (main handles the effects)
## Online: the host's is simulated, clients show it (net_state / net_apply).

signal exploded(pos: Vector2, size: float)

const GRAVITY := 700.0
const FLARE_LIFE := 25.0
const FUSE := 3.0
const BLAST := 34.0              # dynamite crater radius
const SCARE := 90.0              # creatures keep this far from a burning flare
const DIR := "res://assets/props/"

var kind := "flare"
var world: World
var velocity := Vector2.ZERO
var puppet := false
var life := 0.0                  # seconds left: flare burning / fuse
var resting := false
var _sprite := Sprite2D.new()
var _light := PointLight2D.new()
var _sound := AudioStreamPlayer2D.new()
var _t := 0.0


## Is there a burning flare near p? (creatures shy away)
static func scary_near(tree: SceneTree, p: Vector2) -> Node2D:
	for t: Thrown in tree.get_nodes_in_group("flare"):
		if t.life > 0.0 and t.global_position.distance_to(p) < SCARE:
			return t
	return null


func _ready() -> void:
	add_to_group("net")
	add_to_group(kind)
	z_index = 2
	life = FLARE_LIFE if kind == "flare" else FUSE
	add_child(_sprite)
	add_child(_light)
	_sound.bus = "SFX"
	_sound.volume_db = -10.0
	_sound.max_distance = 500.0
	add_child(_sound)
	_dress()


## Looks and sound for its kind (again if a client learns it's the other kind).
func _dress() -> void:
	var tex := DIR + kind + ".png"
	_sprite.texture = Art.lit(tex) if ResourceLoader.exists(tex) else null
	for c in _sprite.get_children():
		c.queue_free()
	if _sprite.texture and ResourceLoader.exists(DIR + kind + "_glow.png"):
		var g := Sprite2D.new()
		g.texture = load(DIR + kind + "_glow.png")
		var unlit := CanvasItemMaterial.new()
		unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		g.material = unlit
		_sprite.add_child(g)
	_light.texture = DrillArt._radial_texture()
	_light.color = Color("ff3a2a") if kind == "flare" else Color("ffb060")
	_light.texture_scale = 3.2 if kind == "flare" else 0.5
	_sound.stream = Sfx.looping("flare_burn" if kind == "flare" else "fuse")
	if _sound.stream:
		_sound.play()


func _physics_process(dt: float) -> void:
	_t += dt
	_light.energy = (1.6 if kind == "flare" else 0.8) * (0.85 + 0.15 * sin(_t * 23.0) * sin(_t * 9.0))
	queue_redraw()
	if puppet:
		return
	life -= dt
	if kind == "flare" and life <= 0.0:
		queue_free()
		return
	if kind == "dynamite" and life <= 0.0:
		_explode()
		return
	if resting:
		if world.is_air(global_position + Vector2(0, 4)):
			resting = false                  # what it lay on was dug away
		return
	velocity.y += GRAVITY * dt
	var next := global_position + velocity * dt
	if not world.is_air(next):
		var side := not world.is_air(Vector2(next.x, global_position.y))
		if side:
			velocity.x *= -0.4
		else:
			velocity.y *= -0.3
			velocity.x *= 0.6
		if velocity.length() < 40.0:
			resting = true
			velocity = Vector2.ZERO
	else:
		global_position = next


func _explode() -> void:
	exploded.emit(global_position, BLAST)
	world.dig(global_position, global_position, BLAST, 30.0, false)
	for p: Player in get_tree().get_nodes_in_group("player"):
		var d := p.global_position.distance_to(global_position)
		if d < BLAST * 1.5:
			p.hurt(2 if d < BLAST else 1, global_position)
	for dr: Drill in get_tree().get_nodes_in_group("drill"):
		if dr.global_position.distance_to(global_position) < BLAST + Drill.HW:
			dr.damage(15.0, global_position)
	for h in get_tree().get_nodes_in_group("hittable"):
		if (h as Node2D).global_position.distance_to(global_position) < BLAST * 1.4:
			h.hit(10, global_position)
	GasCloud.spark(get_tree(), global_position)
	queue_free()


func _draw() -> void:
	if _sprite.texture:
		return
	if kind == "flare":
		draw_rect(Rect2(-1, -5, 2, 8), Color("8a2a20"))
		draw_circle(Vector2(0, -5), 1.8 + 0.4 * sin(_t * 30.0), Color(2.6, 0.6, 0.4))
	else:
		draw_rect(Rect2(-3, -6, 6, 8), Color("b0302a"))
		if fmod(_t, 0.2) < 0.1:
			draw_circle(Vector2(0, -8), 1.2, Color(2.6, 2.0, 0.8))


func net_state() -> Array:
	return [kind, life, resting]


func net_apply(s: Array) -> void:
	if kind != s[0]:
		remove_from_group(kind)
		kind = s[0]
		add_to_group(kind)
		_dress()
	life = s[1]
	resting = s[2]
