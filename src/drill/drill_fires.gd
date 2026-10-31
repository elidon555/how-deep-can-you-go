extends Node
class_name DrillFires
## Fire in the cabin. It starts from an overheating drill, a sparking fuse box or a blast against
## the hull. A fire grows, spreads along the floor, heats the drill, eats hull and burns whoever
## stands in it. The crew beats it out (hold E on it), sprays it with an extinguisher, or it
## drowns in flood water; the sprinkler module douses it on its own.

const MAX_FIRES := 6
const GROW := 0.06             # intensity per second
const SPREAD := 0.12           # chance per second a big fire jumps along the floor
const HULL_BURN := 0.6         # hull per second at full intensity
const HEAT := 2.5              # heat per second at full intensity
const BURN_EVERY := 1.2        # seconds between burns for someone standing in it
const SPRINKLE := 0.35         # intensity per second the sprinklers take off each fire

var drill: Drill
var _burn_t := 0.0


## Starts (or feeds) a fire at local x on the cabin floor.
func ignite(x: float, intensity := 0.3) -> void:
	x = clampf(x, -Drill.HW + Drill.WALL + 6.0, Drill.HW - Drill.WALL - 6.0)
	for f: Flame in fires():
		if absf(f.position.x - x) < 14.0:
			f.intensity = maxf(f.intensity, intensity)
			return
	if fires().size() >= MAX_FIRES:
		return
	var f := Flame.new()
	f.position = Vector2(x, Drill.FLOOR)
	f.intensity = intensity
	f.fires = self
	drill.add_child(f)
	Sfx.play("fire_ignite", f.global_position)


func fires() -> Array:
	return drill.get_children().filter(func(c): return c is Flame and not c.is_queued_for_deletion())


func update(dt: float) -> void:
	_burn_t -= dt
	var list := fires()
	for f: Flame in list:
		f.intensity = minf(f.intensity + GROW * dt, 1.0)
		if f.intensity > 0.7 and list.size() < MAX_FIRES and randf() < SPREAD * dt:
			ignite(f.position.x + (22.0 if randf() < 0.5 else -22.0), 0.2)
		drill.damage_quietly(HULL_BURN * f.intensity * dt)
		drill.thermal.heat += HEAT * f.intensity * dt
		if drill.flooding.surface_y() < Drill.FLOOR - 6.0:     # water over the floor
			f.douse(dt * 0.8)
		if Progress.level("sprinklers") > 0:
			f.douse(SPRINKLE * drill.power.level("modules") * dt)
		for i in 2:                                            # a fire under a fuse box
			if absf(f.position.x - Junction.X[i]) < 16.0 and f.intensity > 0.6 and randf() < 0.05 * dt:
				drill.power.blow(i)
	if _burn_t <= 0.0 and not list.is_empty():
		_burn_t = BURN_EVERY
		for p: Player in drill.get_tree().get_nodes_in_group("player"):
			for f: Flame in list:
				var l := drill.to_local(p.global_position)
				if absf(l.x - f.position.x) < 8.0 + 6.0 * f.intensity and l.y > Drill.FLOOR - 40.0 and l.y < Drill.FLOOR:
					p.hurt(1, f.global_position)
					break
	if drill.thermal.heat > 92.0 and randf() < 0.08 * dt:      # running far too hot
		ignite(randf_range(-60.0, 60.0))


## Client: the host's fires ([x, intensity] pairs).
func show_fires(s: PackedFloat32Array) -> void:
	var have := fires()
	var keep := {}
	for k in range(0, s.size(), 2):
		var f: Flame = null
		for h: Flame in have:
			if absf(h.position.x - s[k]) < 0.5:
				f = h
		if f == null:
			f = Flame.new()
			f.position = Vector2(s[k], Drill.FLOOR)
			f.fires = self
			f.puppet = true
			drill.add_child(f)
		f.intensity = s[k + 1]
		keep[f] = true
	for h: Flame in have:
		if not keep.has(h):
			h.queue_free()


func net_state() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for f: Flame in fires():
		out.append_array([f.position.x, f.intensity])
	return out


## One fire on the cabin floor. Interactable: hold E to beat it down.
class Flame extends Node2D:
	const SHEET := "res://assets/props/fire.png"
	const SHEET_GLOW := "res://assets/props/fire_glow.png"
	const SHEET_INFO := "res://assets/props/fire.json"
	var fires: DrillFires
	var intensity := 0.3
	var puppet := false            # online client: the host's fire
	var _t := randf() * 10.0
	var _sprite := Sprite2D.new()
	var _glow := Sprite2D.new()
	var _light := PointLight2D.new()
	var _crackle := AudioStreamPlayer2D.new()

	func _ready() -> void:
		add_to_group("interactable")
		z_index = 2
		var unlit := CanvasItemMaterial.new()
		unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		if ResourceLoader.exists(SHEET_INFO):
			var info = JSON.parse_string(FileAccess.get_file_as_string(SHEET_INFO))
			for s: Sprite2D in [_sprite, _glow]:
				s.hframes = int(info.frames)
				s.centered = false
				s.offset = Vector2(-float(info.frame_w) / 2.0, -float(info.frame_h))
				s.material = unlit
				add_child(s)
			_sprite.texture = load(SHEET)
			_glow.texture = load(SHEET_GLOW) if ResourceLoader.exists(SHEET_GLOW) else null
		_light.texture = DrillArt._radial_texture()
		_light.color = Color("ff9a3c")
		_light.texture_scale = 0.6
		add_child(_light)
		_crackle.stream = Sfx.looping("fire_crackle")
		_crackle.bus = "SFX"
		_crackle.max_distance = 400.0
		add_child(_crackle)
		if _crackle.stream:
			_crackle.play()

	func prompt(p: Player) -> String:
		return "" if p.tools.current() == "extinguisher" else "Hold E: beat out the fire"

	func hold_time() -> float:
		return 0.8

	func priority() -> int:
		return 1

	func interact(_p: Player) -> void:
		douse(0.45)

	func douse(amount: float) -> void:
		intensity -= amount
		if intensity <= 0.0 and not is_queued_for_deletion():
			Sfx.play("extinguish", global_position, -6.0)
			queue_free()

	func _process(dt: float) -> void:
		_t += dt
		var k := 0.5 + 0.5 * intensity
		_light.energy = (1.2 + 0.4 * sin(_t * 17.0) * sin(_t * 7.0)) * k
		_crackle.volume_db = linear_to_db(0.3 + 0.7 * intensity)
		if _sprite.texture:
			var f := int(_t * 12.0) % _sprite.hframes
			_sprite.frame = f
			_glow.frame = f
			_sprite.modulate.a = clampf(intensity * 1.6, 0.3, 1.0)
			_glow.modulate.a = _sprite.modulate.a
		queue_redraw()

	func _draw() -> void:
		var flames := 1 + int(intensity * 3.0)        # bigger fires: more tongues of flame
		for i in flames:
			var x := (i - (flames - 1) / 2.0) * 6.0
			if _sprite.texture and i == 0:
				continue                              # the rendered flame is the middle one
			var h := 8.0 + 10.0 * intensity * (0.8 + 0.2 * sin(_t * 13.0 + i * 2.0))
			var w := 3.0 + 2.0 * intensity
			draw_colored_polygon(PackedVector2Array([Vector2(x - w, 0), Vector2(x + w, 0),
				Vector2(x + sin(_t * 9.0 + i) * 2.0, -h)]), Color(2.4, 1.0, 0.25, 0.85))
			draw_colored_polygon(PackedVector2Array([Vector2(x - w * 0.5, 0), Vector2(x + w * 0.5, 0),
				Vector2(x, -h * 0.6)]), Color(2.8, 2.2, 0.9, 0.9))
