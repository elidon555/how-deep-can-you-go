extends Node
class_name Quakes
## Now and then the ground shifts (deeper: more often). A groan first, then a quake: the screen
## shakes, rubble pours back into tunnels near the crew, a cave-in seals part of the drill's
## shaft above it (the way up has to be dug or grappled open again), loose boulders drop, and the
## knock can blow one of the drill's fuses. Host-only: the changed rock reaches clients through
## NetWorld, the rest is echoed.

const FROM := 50.0                 # m (drill depth)
const EVERY := Vector2(110.0, 220.0)
const WARNING := 2.5               # seconds of groaning before it hits
const RUBBLE_SPOTS := 6            # tunnel spots near each miner that fill back in
const SAFE := 30.0                 # px: never bury anyone

var main                           # the run (src/main.gd)
var _t := 90.0
var _warned := false


func _process(dt: float) -> void:
	if main.run_over or main.menus.on_title():
		return
	var depth: float = main.drill.global_position.y / World.METER
	if depth < FROM:
		return
	_t -= dt * (1.0 + depth / 400.0)
	if _t <= WARNING and not _warned:
		_warned = true
		Sfx.play("rumble", Vector2.INF, -6.0, 0.0)
		main.hud.toast("The rock groans...", 2.0)
	if _t <= 0.0:
		_t = randf_range(EVERY.x, EVERY.y)
		_warned = false
		quake()


func quake() -> void:
	Sfx.play("quake", Vector2.INF, 0.0, 0.0)
	main.add_shake(2.2)
	for p in main.players:
		_rubble_near(p.global_position)
	_cave_in_above(main.drill)
	_loosen_boulders()
	main.drill.power.knock(14.0)
	main.hud.toast("Quake! Tunnels are caving in.", 2.5)


## Rubble pours back into a few dug tunnel spots around someone (never on top of anyone).
func _rubble_near(at: Vector2) -> void:
	var w: World = main.world
	var near := []
	for c: Vector2i in w.dug:
		var p := Vector2(c) * World.CELL
		if p.distance_to(at) < 320.0 and p.distance_to(at) > 60.0:
			near.append(c)
	near.shuffle()
	for c: Vector2i in near.slice(0, RUBBLE_SPOTS):
		_fill_blob(c, 2)
	if not near.is_empty():
		Sfx.play("rubble", Vector2(near[0]) * World.CELL)


## A plug of rubble in the shaft the drill bored, a few metres above it.
func _cave_in_above(drill: Drill) -> void:
	var c: Vector2i = main.world.cell_at(drill.global_position + Vector2(0, Drill.TOP - randf_range(90.0, 180.0)))
	for dx in range(-14, 15, 3):
		_fill_blob(c + Vector2i(dx, 0), 2)
	Sfx.play("rubble", Vector2(c) * World.CELL, 2.0)


func _fill_blob(c: Vector2i, r: int) -> void:
	var w: World = main.world
	for gy in range(c.y - r, c.y + r + 1):
		for gx in range(c.x - r, c.x + r + 1):
			if Vector2(gx - c.x, gy - c.y).length() > r + 0.3 or gx < 2 or gx >= World.W - 2:
				continue
			var p := Vector2(gx * World.CELL + 4, gy * World.CELL + 4)
			if not w.is_air(p) or _occupied(p):
				continue
			w.place_rock(gx, gy, World.M.DIRT)
			w.dug.erase(Vector2i(gx, gy))


## Someone (or the drill) is there: no rubble on top of them.
func _occupied(p: Vector2) -> bool:
	for n: Node2D in main.get_tree().get_nodes_in_group("player"):
		if n.global_position.distance_to(p) < SAFE:
			return true
	for n: Node2D in main.get_tree().get_nodes_in_group("creature"):
		if n.global_position.distance_to(p) < 16.0:
			return true
	var d: Drill = main.drill
	var l := d.to_local(p)
	return absf(l.x) < Drill.HW + 30.0 and l.y > Drill.TOP - 20.0 and l.y < 120.0


## Loose rock overhead comes down around the crew.
func _loosen_boulders() -> void:
	for p in main.players:
		var at: Vector2 = p.global_position + Vector2(randf_range(-120, 120), -40)
		var y := at.y
		while main.world.is_air(Vector2(at.x, y - 4.0)) and y > at.y - 160.0:
			y -= 4.0
		if main.world.is_air(Vector2(at.x, y - 4.0)) or absf(at.x - p.global_position.x) < 20.0:
			continue
		var b := Boulder.new()
		b.world = main.world
		b.position = Vector2(at.x, y + Boulder.RADIUS + 2.0)
		b.shattered.connect(main.world.boulder_shattered.emit)
		main.world.add_child(b)
