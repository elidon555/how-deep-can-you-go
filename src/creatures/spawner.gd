extends Node
class_name Spawner
## Brings the caves to life around the crew: glowing eyes that watch from the dark, crawlers
## that hunt on cave floors and swarms of mites (only in natural caves, out of view; despawned
## when left far behind), bat roosts, and deeper down worms and borers that go for the drill.
## In the ice, once, the Broodmother's lair opens beside the shaft.

signal crawler_killed(pos: Vector2)
signal bat_killed(pos: Vector2)
signal worm_coming(worm: Worm)
signal worm_killed(pos: Vector2)
signal creature_killed(pos: Vector2, bounty: int)   # mites, borers
signal brood_spawned(brood: Broodmother)

const WATCHERS_FROM := 15.0    # meters
const CRAWLERS_FROM := 25.0
const DESPAWN_DIST := 800.0
const BATS_FROM := 12.0
const MAX_BATS := 10
const WORMS_FROM := 40.0       # meters (drill depth)
const WORM_EVERY := Vector2(70.0, 130.0)   # seconds between worms
const MITES_FROM := 60.0
const MAX_MITES := 14
const BORERS_FROM := 150.0     # m (drill depth)
const BORER_EVERY := Vector2(50.0, 100.0)
const BROOD_AT := 330.0        # m (drill depth): her lair opens

var world: World
var player: Player             # this machine's miner: the watching eyes are for them
var puppet := false            # online client: creatures come from the host; only eyes made here
var drill: Drill
var lit_parent: Node           # creatures go here (lit by the lamp)
var glow_parent: Node          # glowing eyes go here (bloom)
var _watch_t := 5.0
var _crawl_t := 4.0
var _worm_t := 35.0
var _bat_t := 3.0
var _mite_t := 6.0
var _borer_t := 40.0
var _brood_done := false


func _process(dt: float) -> void:
	_watch_t -= dt
	if player.global_position.y / World.METER > WATCHERS_FROM and _watch_t <= 0.0:
		_watch_t = randf_range(3.0, 8.0)
		if get_tree().get_nodes_in_group("watcher").size() < 3:
			_spawn_watcher()
	if puppet:
		return
	var around := _anyone()           # co-op: things turn up around every miner in turn
	var depth := around.global_position.y / World.METER
	_crawl_t -= dt
	if depth > CRAWLERS_FROM and _crawl_t <= 0.0:
		_crawl_t = randf_range(2.0, 5.0)
		var cap := 2 + int(depth / 100.0)
		if get_tree().get_nodes_in_group("creature").size() - get_tree().get_nodes_in_group("bat").size() < cap:
			_spawn_crawler(around)
	_bat_t -= dt
	if depth > BATS_FROM and _bat_t <= 0.0:
		_bat_t = randf_range(4.0, 9.0)
		if get_tree().get_nodes_in_group("bat").size() < MAX_BATS:
			_spawn_roost(around)
	for c: Node2D in get_tree().get_nodes_in_group("creature"):
		if _distance_to_crew(c.global_position) > DESPAWN_DIST:
			c.queue_free()
	_mite_t -= dt
	if depth > MITES_FROM and _mite_t <= 0.0:
		var fungal := world.gen.fungal(around.global_position.x, around.global_position.y, depth)
		_mite_t = randf_range(4.0, 8.0) if fungal else randf_range(14.0, 26.0)
		if get_tree().get_nodes_in_group("mite").size() < MAX_MITES:
			_spawn_mites(around, randi_range(4, 6) if fungal else randi_range(2, 4))
	var drill_depth := drill.global_position.y / World.METER
	if drill_depth > BORERS_FROM:
		_borer_t -= dt
		if _borer_t <= 0.0:
			_borer_t = randf_range(BORER_EVERY.x, BORER_EVERY.y)
			if get_tree().get_nodes_in_group("borer").size() < 2:
				spawn_borer()
	if drill_depth > BROOD_AT and not _brood_done:
		_brood_done = true
		spawn_brood()
	if drill.global_position.y / World.METER > WORMS_FROM and get_tree().get_nodes_in_group("worm").is_empty():
		_worm_t -= dt
		if _worm_t <= 0.0:
			_worm_t = randf_range(WORM_EVERY.x, WORM_EVERY.y)
			spawn_worm()


## A miner picked at random (living ones first).
func _anyone() -> Player:
	var crew := get_tree().get_nodes_in_group("player").filter(func(p): return p.health > 0)
	return crew.pick_random() if not crew.is_empty() else player


func _distance_to_crew(p: Vector2) -> float:
	var d := INF
	for q: Player in get_tree().get_nodes_in_group("player"):
		d = minf(d, q.global_position.distance_to(p))
	return d


## A roost of 3-5 bats hanging from a natural cave ceiling, off screen.
func _spawn_roost(around: Player) -> void:
	for i in 40:
		var pos := around.global_position + Vector2(randf_range(-420, 420), randf_range(-260, 200))
		var d := pos.distance_to(around.global_position)
		if d < 230.0 or not _open_cave(pos, 10.0):
			continue
		var ceil_y := pos.y
		while world.is_air(Vector2(pos.x, ceil_y - 4.0)) and ceil_y > pos.y - 120.0:
			ceil_y -= 4.0
		if ceil_y <= pos.y - 120.0:
			continue
		for k in randi_range(3, 5):
			var at := Vector2(pos.x + k * 9.0 - 18.0, ceil_y)
			if not world.is_air(at + Vector2(0, 4)) or world.is_air(at + Vector2(0, -4)):
				continue        # needs rock right above to hang from
			var b := Bat.new()
			b.world = world
			b.glow_parent = glow_parent
			b.position = at
			b.killed.connect(bat_killed.emit)
			lit_parent.add_child(b)
		return


## A worm starts burrowing toward the drill from ~16 m away, off to one side and below.
func spawn_worm() -> Worm:
	var a := randf_range(0.15, PI - 0.15)                 # somewhere below the horizon
	var at := drill.global_position + Vector2(cos(a), sin(a)) * 380.0
	at.x = clampf(at.x, 40.0, World.WIDTH_PX - 40.0)
	var w := Worm.new()
	w.world = world
	w.drill = drill
	w.position = at
	w.heading = (drill.global_position - at).normalized()
	w.killed.connect(worm_killed.emit)
	lit_parent.add_child(w)
	worm_coming.emit(w)
	return w


func _spawn_watcher() -> void:
	for i in 30:
		var pos := player.global_position + Vector2(randf_range(-300, 300), randf_range(-170, 170))
		if pos.distance_to(player.global_position) < 180.0 or not _open_cave(pos, 12.0):
			continue
		var w := Watcher.new()
		w.player = player
		w.position = pos
		w.add_to_group("watcher")
		glow_parent.add_child(w)
		return


## A floor spot in a natural cave, 260-460 px away (off screen at the default zoom).
func _spawn_crawler(around: Player) -> void:
	for i in 40:
		var pos := around.global_position + Vector2(randf_range(-460, 460), randf_range(-200, 260))
		var d := pos.distance_to(around.global_position)
		if d < 260.0 or d > 460.0 or not _open_cave(pos, 14.0):
			continue
		var floor_y := pos.y
		while world.is_air(Vector2(pos.x, floor_y + 4.0)) and floor_y < pos.y + 120.0:
			floor_y += 4.0
		if floor_y >= pos.y + 120.0:
			continue
		var c := Crawler.new()
		c.world = world
		c.player = around
		c.glow_parent = glow_parent
		c.position = Vector2(pos.x, floor_y - 9.0)
		c.killed.connect(crawler_killed.emit)
		lit_parent.add_child(c)
		return


## A swarm of mites on a natural cave floor near someone, off screen.
func _spawn_mites(around: Player, n: int) -> void:
	for i in 40:
		var pos := around.global_position + Vector2(randf_range(-420, 420), randf_range(-200, 240))
		var d := pos.distance_to(around.global_position)
		if d < 240.0 or not _open_cave(pos, 10.0):
			continue
		for k in n:
			var m := Mite.new()
			m.world = world
			m.glow_parent = glow_parent
			m.position = pos + Vector2(k * 7.0 - n * 3.5, 0)
			m.killed.connect(creature_killed.emit.bind(1))
			lit_parent.add_child(m)
		return


## A borer starts tunnelling toward the drill from inside the rock, off to one side and below.
func spawn_borer() -> Borer:
	var side := -1.0 if randf() < 0.5 else 1.0
	var at := drill.global_position + Vector2(side * randf_range(260.0, 360.0), randf_range(60.0, 220.0))
	at.x = clampf(at.x, 40.0, World.WIDTH_PX - 40.0)
	var b := Borer.new()
	b.world = world
	b.drill = drill
	b.glow_parent = glow_parent
	b.position = at
	b.killed.connect(creature_killed.emit.bind(8))
	lit_parent.add_child(b)
	Sfx.play("borer_hiss", at, 2.0)
	return b


## The Broodmother's lair tears open beside the shaft, just below the drill, and there she is.
func spawn_brood() -> Broodmother:
	var side := -1.0 if drill.global_position.x > World.WIDTH_PX / 2.0 else 1.0
	var c := drill.global_position + Vector2(side * 300.0, 200.0)
	c.x = clampf(c.x, 260.0, World.WIDTH_PX - 260.0)
	world.dig(c + Vector2(-150, 0), c + Vector2(150, 0), 66.0, 99.0, false)
	var floor_y := c.y
	while world.is_air(Vector2(c.x, floor_y + 2.0)) and floor_y < c.y + 120.0:
		floor_y += 2.0
	var b := Broodmother.new()
	b.world = world
	b.drill = drill
	b.glow_parent = glow_parent
	b.lair = Vector2(c.x - 110.0, c.x + 110.0)
	b.position = Vector2(c.x, floor_y)
	lit_parent.add_child(b)
	Sfx.play("quake", Vector2.INF)
	brood_spawned.emit(b)
	return b


func _open_cave(pos: Vector2, r: float) -> bool:
	if pos.x < 40 or pos.x > World.WIDTH_PX - 40 or pos.y < 60:
		return false
	for o in [Vector2.ZERO, Vector2(-r, 0), Vector2(r, 0), Vector2(0, -r), Vector2(0, r)]:
		var c := world.cell_at(pos + o)
		if world.get_fill(c.x, c.y) > 0.2 or world.dug.has(c):
			return false
	return true
