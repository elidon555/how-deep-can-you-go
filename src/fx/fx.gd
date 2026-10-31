extends Node
class_name Fx
## One-shot effects: particle bursts (fading, spinning chunks), impact flashes, dust puffs,
## pickaxe impacts (with their sounds), creature deaths and hit-stop.
## Online, each public effect the host plays is played on every client too (Net.echo); the
## pieces an effect is made of (_burst, _flash, _dust) aren't sent on their own.

## Where bursts go: `lit` is darkened by the cave lighting, `glow` blooms.
var lit: Node
var glow: Node
const HIT_SOUND := ["hit_dirt", "hit_stone", "hit_hard", "bonk", "crystal_hit", "hit_hard", "bonk", "ice_crack"]   # by World.M

var hitstop_enabled := true
var _hitstop_id := 0


func _ready() -> void:
	Engine.time_scale = 1.0   # a reload during a hit-stop must not leave the game slowed


## Pickaxe hit: chunks fly back toward the miner, sparks off stone, a dust puff when rock breaks.
## kind "bonk" = the wind-up knocked into rock (no room to swing).
func impact(pos: Vector2, mat: int, broke: int, kind: String, facing: int) -> void:
	Net.echo(&"fx", &"impact", [pos, mat, broke, kind, facing])
	var away := Vector2(-facing, -0.6)      # side: back toward the miner
	match kind:
		"dig_down", "dig_diag":
			away = Vector2(-facing * 0.4, -1)
		"dig_up", "bonk":
			away = Vector2(0, 1)
	var rock: Color = World.COLORS[mat]
	_burst(pos, rock.lightened(0.15), 4 + broke, 130.0, away, 55.0, 0.5, 2.5, false, 600.0, true)
	_flash(pos, Color(1.6, 1.4, 1.1) if kind != "bonk" else Color(1.0, 0.9, 0.8), 7.0 if broke > 0 else 5.0)
	if mat == World.M.STONE or mat == World.M.HARD or mat == World.M.MAGMA:
		var n := 3 if broke > 0 else 7     # pick bouncing off hard rock: more sparks
		_burst(pos, Color(2.4, 1.9, 1.1), n, 220.0, away, 70.0, 0.22, 1.0, true)
	if mat == World.M.CRYSTAL:             # glowing shards
		_burst(pos, Color(1.6, 1.1, 2.6), 6 + broke, 180.0, away, 80.0, 0.5, 1.6, true, 400.0, true)
	if mat == World.M.MAGMA and broke > 0:
		_burst(pos, Color(2.6, 1.0, 0.3), 4, 60.0, Vector2.UP, 50.0, 0.9, 1.4, true, -60.0)   # embers
		Sfx.play("sizzle", pos, -8.0)
	if broke > 0:
		_dust(pos, 1.0)
		Sfx.play("crystal_break" if mat == World.M.CRYSTAL else "break", pos, -6.0)
	Sfx.play("bonk" if kind == "bonk" else HIT_SOUND[mat], pos, -2.0)
	hitstop(0.06 if broke > 0 else 0.035)


## Pickaxe landing on a creature or boulder.
func flesh(pos: Vector2, facing: int) -> void:
	Net.echo(&"fx", &"flesh", [pos, facing])
	_burst(pos, Color("d8cfd6"), 8, 150.0, Vector2(facing, -0.5), 60.0, 0.4, 2.0, false, 600.0, true)
	_flash(pos, Color(2.0, 1.9, 1.9), 8.0)
	hitstop(0.07)


## Rock the drill's cutters just broke off: chunks spat out sideways and up the gap beside the
## hull, with dust. `points` are where cells broke; a few are picked so it stays light.
func chunks(points: Array, mat: int, drill_x: float) -> void:
	Net.echo(&"fx", &"chunks", [points, mat, drill_x])
	var rock: Color = World.COLORS[clampi(mat, 0, World.COLORS.size() - 1)]
	for i in mini(points.size(), 4):
		var p: Vector2 = points[randi() % points.size()]
		var out := Vector2(signf(p.x - drill_x), -1.6).normalized()
		_burst(p, rock.lightened(0.1), 3, 150.0, out, 35.0, 0.7, 2.6, false, 500.0, true)
		_burst(p, rock.darkened(0.3), 2, 90.0, out, 60.0, 0.5, 1.8, false, 500.0, true)
	_dust(points[0], 0.6)


## A crawler dies: pale chunks, dark ichor, a puff.
func gore(pos: Vector2) -> void:
	Net.echo(&"fx", &"gore", [pos])
	_burst(pos, Color("c9bfc8"), 12, 160.0, Vector2.UP, 120.0, 0.7, 3.0, false, 600.0, true)
	_burst(pos, Color("2a1c2a"), 10, 110.0, Vector2.UP, 160.0, 0.9, 2.0, false, 500.0)
	_dust(pos, 1.2)


## A firedamp blast: a huge flash, a fireball, burning debris, smoke.
func explosion(pos: Vector2, size: float) -> void:
	Net.echo(&"fx", &"explosion", [pos, size])
	_flash(pos, Color(3.0, 2.2, 1.2), size * 0.9)
	_burst(pos, Color(3.0, 1.4, 0.4), 40, size * 6.0, Vector2.UP, 180.0, 0.6, 5.0, true, 200.0)
	_burst(pos, Color(2.2, 0.7, 0.15), 24, size * 4.0, Vector2.UP, 180.0, 1.0, 3.0, true, 500.0, true)
	_burst(pos, Color(0.18, 0.16, 0.15, 0.7), 26, size * 1.5, Vector2.UP, 180.0, 2.2, 9.0, false, -30.0)
	hitstop(0.12)


func dust(pos: Vector2, strength: float) -> void:
	Net.echo(&"fx", &"dust", [pos, strength])
	_dust(pos, strength)


func flash(pos: Vector2, color: Color, size: float) -> void:
	Net.echo(&"fx", &"flash", [pos, color, size])
	_flash(pos, color, size)


func burst(pos: Vector2, color: Color, amount: int, speed: float, dir := Vector2.UP, spread := 180.0,
		life := 0.6, size := 2.5, glowing := false, gravity := 600.0, spin := false) -> void:
	Net.echo(&"fx", &"burst", [pos, color, amount, speed, dir, spread, life, size, glowing, gravity, spin])
	_burst(pos, color, amount, speed, dir, spread, life, size, glowing, gravity, spin)


## Soft dust puff (footsteps, landings, breaking rock). strength ~0.3 (step) .. 1.5 (big landing).
func _dust(pos: Vector2, strength: float) -> void:
	var n := int(3 + strength * 6)
	_burst(pos + Vector2(0, -2), Color(0.62, 0.56, 0.5, 0.55), n, 30.0 + 40.0 * strength, Vector2(0, -1),
		85.0, 0.5 + 0.4 * strength, 2.0 + 2.5 * strength, false, -10.0)


## A quick bright star at an impact, on the bloom layer.
func _flash(pos: Vector2, color: Color, size: float) -> void:
	var f := Flash.new()
	f.position = pos
	f.color = color
	f.size = size
	glow.add_child(f)


## Particles that fade out; `spin` makes them tumbling chunks (debris) instead of specks.
func _burst(pos: Vector2, color: Color, amount: int, speed: float, dir := Vector2.UP, spread := 180.0,
		life := 0.6, size := 2.5, glowing := false, gravity := 600.0, spin := false) -> void:
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
	var fade := Gradient.new()
	fade.set_color(0, Color.WHITE)
	fade.add_point(0.7, Color.WHITE)
	fade.set_color(fade.get_point_count() - 1, Color(1, 1, 1, 0))
	p.color_ramp = fade
	if spin:
		p.angle_min = 0.0
		p.angle_max = 360.0
		p.angular_velocity_min = -540.0
		p.angular_velocity_max = 540.0
		p.scale_amount_min = size * 0.6
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(4, 4)
	p.z_index = 2
	(glow if glowing else lit).add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)


## Expanding four-point star that fades in ~0.12 s.
class Flash extends Node2D:
	var color := Color.WHITE
	var size := 6.0
	var _t := 0.0

	func _process(dt: float) -> void:
		_t += dt
		if _t > 0.12:
			queue_free()
		queue_redraw()

	func _draw() -> void:
		var k := _t / 0.12
		var r := size * (0.6 + k)
		var c := Color(color.r, color.g, color.b, 1.0 - k)
		draw_line(Vector2(-r, 0), Vector2(r, 0), c, 2.0)
		draw_line(Vector2(0, -r), Vector2(0, r), c, 2.0)
		draw_circle(Vector2.ZERO, r * 0.35, c)


## Freeze the game for a moment so hits land with weight.
func hitstop(sec: float) -> void:
	if not hitstop_enabled or Net.is_online():     # online it would slow the game for everyone
		return
	_hitstop_id += 1
	var id := _hitstop_id
	Engine.time_scale = 0.05
	await get_tree().create_timer(sec, true, false, true).timeout
	if id == _hitstop_id:
		Engine.time_scale = 1.0
