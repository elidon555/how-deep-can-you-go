extends Node
class_name Fx
## One-shot effects: particle bursts, pickaxe impacts and hit-stop.

## Where bursts go: `lit` is darkened by the cave lighting, `glow` blooms.
var lit: Node
var glow: Node
var hitstop_enabled := true
var _hitstop_id := 0


func _ready() -> void:
	Engine.time_scale = 1.0   # a reload during a hit-stop must not leave the game slowed


## Pickaxe hit: chunks fly back toward the miner, sparks off stone, a dust puff when rock breaks.
## kind "bonk" = the wind-up knocked into rock (no room to swing).
func impact(pos: Vector2, mat: int, broke: int, kind: String, facing: int) -> void:
	var away := Vector2(-facing, -0.6)      # side: back toward the miner
	match kind:
		"dig_down", "dig_diag":
			away = Vector2(-facing * 0.4, -1)
		"dig_up", "bonk":
			away = Vector2(0, 1)
	var rock: Color = World.COLORS[mat]
	burst(pos, rock.lightened(0.15), 4 + broke, 130.0, away, 55.0, 0.5, 2.5)
	if mat == World.M.STONE or mat == World.M.HARD:
		var n := 3 if broke > 0 else 7     # pick bouncing off hard rock: more sparks
		burst(pos, Color(2.4, 1.9, 1.1), n, 220.0, away, 70.0, 0.22, 1.0, true)
	if broke > 0:
		burst(pos, Color(0.55, 0.52, 0.5, 0.5), 6, 35.0, away, 180.0, 0.7, 4.0, false, 40.0)
	hitstop(0.06 if broke > 0 else 0.035)


func burst(pos: Vector2, color: Color, amount: int, speed: float, dir := Vector2.UP, spread := 180.0,
		life := 0.6, size := 2.5, glowing := false, gravity := 600.0) -> void:
	var p := CPUParticles2D.new()
	p.position = pos
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = maxi(amount, 1)
	p.lifetime = life
	p.direction = dir.normalized()
	p.spread = spread
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector2(0, gravity)
	p.scale_amount_min = size * 0.4
	p.scale_amount_max = size
	p.color = color
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(4, 4)
	p.z_index = 2
	(glow if glowing else lit).add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)


## Freeze the game for a moment so hits land with weight.
func hitstop(sec: float) -> void:
	if not hitstop_enabled:
		return
	_hitstop_id += 1
	var id := _hitstop_id
	Engine.time_scale = 0.05
	await get_tree().create_timer(sec, true, false, true).timeout
	if id == _hitstop_id:
		Engine.time_scale = 1.0
