extends Node2D
class_name Worm
## A huge worm that burrows through solid rock (leaving real tunnels) to ram the drill:
## it hunts toward the hull, charges, rams (hull damage + a breach), backs off, and comes back.
## Bites anyone outside it passes. Takes hits from the pickaxe and the turrets (group "hittable").
## Drawn from rendered sprites: round segments (the same from every angle) and a head rendered
## in 16 directions x mouth closed/open; never by rotating an image. Shapes if art is missing.

signal killed(pos: Vector2)

const SEGMENTS := 10
const SPACING := 9.0
const SPEED := 55.0
const RAM_SPEED := 160.0
const TURN := 2.2              # radians per second
const HP := 14
const RAM_DAMAGE := 14.0
const BURROW_R := 12.0         # the tunnel it leaves
const FLESH := Color("b8a0a8")
const FLESH_DARK := Color("5e4652")
const OUTLINE := Color("0c0a0e")
const ART := "res://assets/sprites/"

enum State { HUNT, RAM, RETREAT, DEAD }

var world: World
var drill: Drill
var state := State.HUNT
var hp := HP
var body: Array[Vector2] = []  # global positions, [0] is the head
var heading := Vector2.DOWN
var _t := 0.0
var _side := 1.0
var _flash := 0.0
var _bite_t := 0.0
var _sound := AudioStreamPlayer2D.new()
var _seg_tex: Texture2D
var _seg_rects := []           # [Rect2 per size], biggest first
var _seg_sizes := []
var _head_tex: Texture2D
var _head_info := {}
var puppet := false            # online client: the host's worm, shown (net_state / net_apply)
var _net_body := PackedVector2Array()   # client: where the host has the segments (slid toward)


func _ready() -> void:
	add_to_group("hittable")
	add_to_group("worm")
	add_to_group("net")
	top_level = true
	for i in SEGMENTS:
		body.append(global_position - heading * SPACING * i)
	_side = 1.0 if randf() < 0.5 else -1.0
	if ResourceLoader.exists(ART + "worm_head.json") and ResourceLoader.exists(ART + "worm_segment.json"):
		var si = JSON.parse_string(FileAccess.get_file_as_string(ART + "worm_segment.json"))
		for r in si.rects:
			_seg_rects.append(Rect2(r[0], r[1], r[2], r[3]))
		_seg_sizes = si.sizes
		_seg_tex = Art.lit(ART + "worm_segment.png")
		_head_info = JSON.parse_string(FileAccess.get_file_as_string(ART + "worm_head.json"))
		_head_tex = Art.lit(ART + "worm_head.png")
	_sound.stream = Sfx.looping("worm_burrow")
	_sound.max_distance = 900.0
	add_child(_sound)
	if _sound.stream:
		_sound.play()
	Sfx.play("worm_roar", global_position)


func _physics_process(dt: float) -> void:
	if puppet:
		_flash = maxf(_flash - dt * 6.0, 0.0)
		var k := 1.0 - exp(-NetEntities.SMOOTH * dt)
		for i in mini(_net_body.size(), body.size()):
			body[i] = body[i].lerp(_net_body[i], k)
		queue_redraw()
		return
	_t -= dt
	_flash = maxf(_flash - dt * 6.0, 0.0)
	_bite_t -= dt
	if state == State.DEAD:
		modulate.a = clampf(_t / 1.5, 0.0, 1.0)
		if _t <= 0.0:
			queue_free()
		return
	var head := body[0]
	var target := head
	var speed := SPEED
	match state:
		State.HUNT:      # aim for the rock beside the hull, below the doors
			target = drill.global_position + Vector2(_side * (Drill.HW + 40.0), 30.0)
			if head.distance_to(target) < 70.0:
				state = State.RAM
				Sfx.play("worm_roar", head, 2.0)
		State.RAM:
			target = drill.global_position + Vector2(0, 10)
			speed = RAM_SPEED
			if _touches_hull(head):
				drill.damage(RAM_DAMAGE, head)
				state = State.RETREAT
				_t = 2.5
				_side = -_side if randf() < 0.5 else _side
		State.RETREAT:
			target = head + (head - drill.global_position).normalized() * 100.0
			if _t <= 0.0:
				state = State.HUNT
	_steer(target, dt)
	var wiggle := Vector2(-heading.y, heading.x) * sin(Time.get_ticks_msec() * 0.006) * 0.35
	body[0] = head + (heading + wiggle).normalized() * speed * dt
	world.dig(body[0], body[0], BURROW_R, 6.0 * dt * 8.0, false)     # grinds a tunnel
	for i in range(1, SEGMENTS):      # each segment follows the one ahead at a fixed distance
		var d := body[i] - body[i - 1]
		if d.length() > SPACING:
			body[i] = body[i - 1] + d.normalized() * SPACING
	global_position = body[0]
	_bite_players()
	queue_redraw()


func net_state() -> Array:
	return [state, PackedVector2Array(body), heading, _flash, modulate.a]


func net_apply(s: Array) -> void:
	state = s[0]
	if _net_body.is_empty():          # just shown: start where the host has it
		for i in mini(s[1].size(), body.size()):
			body[i] = s[1][i]
	_net_body = s[1]
	heading = s[2]
	_flash = maxf(_flash, s[3])
	modulate.a = s[4]


func _steer(target: Vector2, dt: float) -> void:
	var want := (target - body[0]).normalized()
	if want == Vector2.ZERO:
		return
	var ang := heading.angle_to(want)
	heading = heading.rotated(clampf(ang, -TURN * dt, TURN * dt)).normalized()


func _touches_hull(p: Vector2) -> bool:
	var l := drill.to_local(p)
	return absf(l.x) < Drill.HW + 10.0 and l.y > Drill.TOP - 6.0 and l.y < Drill.BOTTOM + 52.0


func _bite_players() -> void:
	if _bite_t > 0.0:
		return
	for p: Player in get_tree().get_nodes_in_group("player"):
		if p.global_position.distance_to(body[0]) < 20.0 and not drill.contains(p.global_position):
			p.hurt(1, body[0])
			_bite_t = 1.0


## Is a point (a turret bolt) inside any part of the body?
func is_hit_by(p: Vector2) -> bool:
	for i in SEGMENTS:
		if p.distance_to(body[i]) < _radius(i) + 3.0:
			return true
	return false


func hit(damage: int, _from: Vector2) -> void:
	if state == State.DEAD:
		return
	hp -= damage
	_flash = 1.0
	Sfx.play("worm_hit", body[0])
	if state == State.HUNT:          # hurt: it charges
		state = State.RAM
	if hp <= 0:
		state = State.DEAD
		_t = 1.5
		_sound.stop()
		Sfx.play("worm_die", body[0])
		remove_from_group("hittable")
		killed.emit(body[0])


func _radius(i: int) -> float:
	return lerpf(11.0, 4.5, float(i) / (SEGMENTS - 1))


func _draw() -> void:
	var tint := Color(1, 1, 1) * (1.0 + _flash * 1.5)
	if _head_tex:
		_draw_sprites(tint)
	else:
		_draw_shapes(tint)


func _draw_sprites(tint: Color) -> void:
	for i in range(SEGMENTS - 1, 0, -1):          # tail first, head on top
		var want := _radius(i) * 2.0 + 2.0          # pick the closest rendered size
		var k := 0
		for j in _seg_sizes.size():
			if absf(_seg_sizes[j] - want) < absf(_seg_sizes[k] - want):
				k = j
		var r: Rect2 = _seg_rects[k]
		draw_texture_rect_region(_seg_tex, Rect2(to_local(body[i]) - r.size / 2.0, r.size), r, tint)
	var dirs := int(_head_info.dirs)
	var cell := float(_head_info.cell)
	var col := posmod(int(round(heading.angle() / TAU * dirs)), dirs)   # heading -> rendered direction
	var open := sin(Time.get_ticks_msec() * (0.02 if state == State.RAM else 0.008)) > 0.0
	var src := Rect2(col * cell, (1 if open else 0) * cell, cell, cell)
	draw_texture_rect_region(_head_tex, Rect2(to_local(body[0]) - Vector2(cell, cell) / 2.0, Vector2(cell, cell)), src, tint)


func _draw_shapes(tint: Color) -> void:
	var flash := tint
	for i in range(SEGMENTS - 1, -1, -1):          # tail first, head on top
		var c := to_local(body[i])
		var r := _radius(i)
		draw_circle(c, r + 1.0, OUTLINE)
		draw_circle(c, r, FLESH_DARK * flash)
		draw_circle(c + Vector2(-0.3, -0.3) * r, r * 0.7, FLESH * flash)
		draw_arc(c, r * 0.55, 0.0, TAU, 12, FLESH_DARK * flash, 1.0)    # ring ridge
	# head: a round maw with three hooked mandibles pointing the way it moves
	var h := to_local(body[0])
	var f := heading
	var s := Vector2(-f.y, f.x)
	var open := 0.5 + 0.5 * sin(Time.get_ticks_msec() * (0.02 if state == State.RAM else 0.008))
	draw_circle(h + f * 4.0, 6.0, Color("1a0c12"))
	for k: float in [-1.0, 0.0, 1.0]:
		var base := h + f * 6.0 + s * k * 6.0
		var tip := base + f * (8.0 + open * 3.0) + s * k * (3.0 + open * 3.0)
		var bend := tip - s * k * 3.0 - f * 2.0
		draw_colored_polygon(PackedVector2Array([base - s * 2.0, tip, base + s * 2.0]), Color("d8cfc4"))
		draw_line(tip, bend, Color("d8cfc4"), 1.5)
		draw_polyline(PackedVector2Array([base - s * 2.0, tip, base + s * 2.0]), OUTLINE, 1.0)
