## The drill's stations. Each is small: a prompt, what using it does (via the Drill), and how
## it looks: a Blender sprite (assets/drill) standing on the floor at the station's position,
## plus whatever changes in play drawn on top.

class_name Stations

const DIR := "res://assets/drill/"


## Draws a station sprite with its bottom-centre at the station's origin.
static func stand(ci: CanvasItem, tex: Texture2D) -> void:
	ci.draw_texture(tex, Vector2(-tex.get_width() / 2.0, -tex.get_height()))


## Speed lever + depth screen.
class Helm extends Station:
	var _tex: Texture2D = Art.lit(Stations.DIR + "helm.png")

	func prompt(_p: Player) -> String:
		var next: String = Drill.SPEED_NAMES[(drill.speed + 1) % 3]
		if drill.fuel <= 0.0:
			return "Helm: no fuel! Shovel coal into the furnace"
		return "E: drill speed → %s" % next

	func interact(_p: Player) -> void:
		drill.cycle_speed()
		queue_redraw()

	func _process(_dt: float) -> void:
		queue_redraw()

	func _draw() -> void:
		Stations.stand(self, _tex)
		var lit := Color("3fd0c0") if drill.fuel > 0.0 else Color("d04a3f")
		for i in 3:      # speed bars
			if i < drill.speed or (i == 0 and drill.speed == 0):
				draw_rect(Rect2(-7 + i * 5, -13 - i * 2, 4, 2 + i * 2), lit if drill.speed > 0 else Color("d0a03f"))
		var ang: float = -0.6 + 0.6 * drill.speed       # the lever
		draw_line(Vector2(8, -2), Vector2(8, -2) + Vector2(sin(ang), -cos(ang)) * 12.0, Color("1a1a1e"), 3.0)
		draw_circle(Vector2(8, -2) + Vector2(sin(ang), -cos(ang)) * 12.0, 2.5, Color("c8322a"))


## Coal goes in here; the mouth glows while the head is turning.
class Furnace extends Station:
	var _tex: Texture2D = Art.lit(Stations.DIR + "furnace.png")
	var _fire := Sprite2D.new()
	var _embers := CPUParticles2D.new()

	func _ready() -> void:
		super._ready()
		_fire.texture = load(Stations.DIR + "furnace_glow.png")
		_fire.offset = Vector2(0, -_fire.texture.get_height() / 2.0)
		var unlit := CanvasItemMaterial.new()
		unlit.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
		_fire.material = unlit
		add_child(_fire)
		_embers.position = Vector2(0, -12)
		_embers.amount = 6
		_embers.lifetime = 1.4
		_embers.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
		_embers.emission_rect_extents = Vector2(5, 2)
		_embers.direction = Vector2(0, -1)
		_embers.spread = 25.0
		_embers.initial_velocity_min = 8.0
		_embers.initial_velocity_max = 20.0
		_embers.gravity = Vector2(0, -6)
		_embers.color = Color(2.2, 0.9, 0.3)
		var fade := Gradient.new()
		fade.set_color(0, Color.WHITE)
		fade.set_color(1, Color(1, 1, 1, 0))
		_embers.color_ramp = fade
		_embers.material = unlit
		add_child(_embers)

	func prompt(p: Player) -> String:
		if p.coal > 0:
			return "E: shovel in %d coal (+%d fuel)" % [p.coal, int(p.coal * Drill.FUEL_PER_COAL)]
		if Drill.infinite_fuel():
			return ""
		return "Furnace: dig up coal to fuel the drill" if drill.fuel < drill.max_fuel * 0.5 else ""

	func interact(p: Player) -> void:
		var c := p.take_coal()
		if c > 0:
			drill.add_fuel(c * Drill.FUEL_PER_COAL)
			Sfx.play("furnace", global_position)

	func _process(_dt: float) -> void:
		queue_redraw()

	func _draw() -> void:
		Stations.stand(self, _tex)
		# the fire burns brighter while the head is cutting rock, and flickers
		var heat := 0.5 + (0.9 if drill.drilling else 0.0) + 0.15 * sin(Time.get_ticks_msec() * 0.02)
		_fire.modulate = Color(heat, heat, heat) if drill.fuel > 0.0 else Color(0.2, 0.2, 0.2)
		_embers.emitting = drill.fuel > 0.0


## Sells the metal ore you carry, restocks ropes and opens the upgrades.
class Workbench extends Station:
	var _tex: Texture2D = Art.lit(Stations.DIR + "workbench.png")

	func prompt(p: Player) -> String:
		if p.ore_value > 0:
			return "E: sell %d ore ($%d) and upgrade" % [p.ore_count, p.ore_value]
		return "E: workbench (upgrades, ropes)"

	func interact(p: Player) -> void:
		var v := p.take_ore_value()
		if v > 0:
			Progress.add_money(v)
			Sfx.play("coins", global_position)
		p.refill_ropes()
		drill.workbench_used.emit(p)

	func _draw() -> void:
		Stations.stand(self, _tex)


## Patches you up, then needs a while to recharge.
class Medkit extends Station:
	const RECHARGE := 45.0
	var _ready_at := 0.0
	var _tex: Texture2D = Art.lit(Stations.DIR + "medkit.png")

	func prompt(p: Player) -> String:
		if not p.is_hurt():
			return ""
		var wait := _ready_at - Time.get_ticks_msec() / 1000.0
		return "E: patch yourself up" if wait <= 0.0 else "Medkit recharging (%ds)" % ceili(wait)

	func interact(p: Player) -> void:
		if Time.get_ticks_msec() / 1000.0 < _ready_at:
			return
		p.heal_full()
		_ready_at = Time.get_ticks_msec() / 1000.0 + RECHARGE
		Sfx.play("repair", global_position)
		queue_redraw()

	func _process(_dt: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var ok := Time.get_ticks_msec() / 1000.0 >= _ready_at
		draw_texture(_tex, -_tex.get_size() / 2.0, Color.WHITE if ok else Color(0.45, 0.45, 0.45))


## A crack in the hull: sparks and hissing, leaks hull until someone holds E on it.
class Breach extends Station:
	const REPAIR_TIME := 1.6
	var _t := 0.0

	func _ready() -> void:
		super._ready()
		var p := CPUParticles2D.new()       # steam
		p.amount = 16
		p.lifetime = 0.8
		p.direction = Vector2(0, -1)
		p.spread = 40.0
		p.initial_velocity_min = 15.0
		p.initial_velocity_max = 35.0
		p.gravity = Vector2(0, -20)
		p.scale_amount_min = 1.5
		p.scale_amount_max = 3.5
		p.color = Color(0.8, 0.8, 0.82, 0.35)
		add_child(p)

	func prompt(_p: Player) -> String:
		return "Hold E: repair the breach"

	func hold_time() -> float:
		return REPAIR_TIME

	func priority() -> int:
		return 1

	func interact(_p: Player) -> void:
		drill.repair(self)

	func _process(dt: float) -> void:
		_t += dt
		queue_redraw()

	func _draw() -> void:
		var pts := PackedVector2Array([Vector2(-6, -3), Vector2(-1, -5), Vector2(1, -1), Vector2(6, -4),
			Vector2(3, 2), Vector2(5, 6), Vector2(-2, 3), Vector2(-5, 5)])
		draw_colored_polygon(pts, Color("0a0809"))
		if fmod(_t, 0.4) < 0.12:             # sparks
			for i in 3:
				var a := randf() * TAU
				draw_line(Vector2.ZERO, Vector2(cos(a), sin(a)) * randf_range(3, 8), Color(2.0, 1.6, 0.6), 1.0)


## Opens the sonar screen: pings show caves, ore and creatures around the drill.
class Sonar extends Station:
	var _tex: Texture2D = Art.lit(Stations.DIR + "sonar.png") if ResourceLoader.exists(Stations.DIR + "sonar.png") else null
	var _t := 0.0

	func prompt(_p: Player) -> String:
		return "E: sonar"

	func interact(p: Player) -> void:
		drill.sonar_used.emit(p)

	func _process(dt: float) -> void:
		_t += dt
		queue_redraw()

	func _draw() -> void:
		if _tex:
			Stations.stand(self, _tex)
		else:
			draw_rect(Rect2(-12, -30, 24, 30), Color("2b2f36"))
			draw_rect(Rect2(-12, -30, 24, 30), Color("0c0a0e"), false, 1.0)
		var c := Vector2(0, -20)          # the screen: a slow idle sweep
		draw_circle(c, 7.0, Color("06120f"))
		var a := _t * 2.0
		draw_line(c, c + Vector2(cos(a), sin(a)) * 7.0, Color(0.3, 1.4, 1.0), 1.0)


## The gunner's seat: take control of the hull turrets (mouse aims, click fires, E gets up).
class GunnerSeat extends Station:
	var _tex: Texture2D = Art.lit(Stations.DIR + "gunner.png") if ResourceLoader.exists(Stations.DIR + "gunner.png") else null

	func prompt(_p: Player) -> String:
		return "" if drill.gunner else "E: man the turrets"

	func interact(p: Player) -> void:
		drill.take_turrets(p)

	func _draw() -> void:
		if _tex:
			Stations.stand(self, _tex)
			return
		draw_rect(Rect2(-8, -14, 16, 14), Color("4a3320"))       # seat
		draw_rect(Rect2(-8, -24, 4, 10), Color("4a3320"))        # backrest
		draw_rect(Rect2(3, -46, 3, 26), Color("3a3f47"))         # periscope
		draw_rect(Rect2(-2, -24, 12, 3), Color("59606b"))        # grips


## Flushes coolant through the drill: heat down, a burst of steam, then it recharges.
class Coolant extends Station:
	var _tex: Texture2D = Art.lit(Stations.DIR + "coolant.png") if ResourceLoader.exists(Stations.DIR + "coolant.png") else null

	func prompt(_p: Player) -> String:
		var wait := drill.vent_ready_at - Time.get_ticks_msec() / 1000.0
		if wait > 0.0:
			return "Coolant recharging (%ds)" % ceili(wait)
		return "E: vent coolant (heat %d%%)" % int(drill.heat)

	func interact(_p: Player) -> void:
		drill.vent_coolant()

	func _process(_dt: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var gauge := Vector2(0, -30)       # where the gauge face sits on the tank
		if _tex:
			Stations.stand(self, _tex)
		else:
			draw_rect(Rect2(-9, -38, 18, 38), Color("3f6070"))
			draw_rect(Rect2(-9, -38, 18, 38), Color("0c0a0e"), false, 1.0)
			draw_circle(gauge, 4.0, Color("d8d4cc"))
		var a := lerpf(PI * 0.75, PI * 2.25, drill.heat / Drill.HEAT_MAX)     # needle: cold .. hot
		var col := Color("c8322a") if drill.heat > 80.0 else Color("1a1a1e")
		draw_line(gauge, gauge + Vector2(cos(a), sin(a)) * 3.5, col, 1.0)
