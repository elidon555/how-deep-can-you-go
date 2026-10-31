extends Node
class_name Spawner
## Brings the caves to life around the player: glowing eyes that watch from the dark, crawlers
## that hunt on cave floors (only in natural caves, out of view; despawned when left far
## behind), and every so often deep down, a worm that burrows toward the drill.

signal crawler_killed(pos: Vector2)
signal worm_coming(worm: Worm)
signal worm_killed(pos: Vector2)

const WATCHERS_FROM := 15.0    # meters
const CRAWLERS_FROM := 25.0
const DESPAWN_DIST := 800.0
const WORMS_FROM := 40.0       # meters (drill depth)
const WORM_EVERY := Vector2(70.0, 130.0)   # seconds between worms

var world: World
var player: Player
var drill: Drill
var lit_parent: Node           # creatures go here (lit by the lamp)
var glow_parent: Node          # glowing eyes go here (bloom)
var _watch_t := 5.0
var _crawl_t := 4.0
var _worm_t := 35.0


func _process(dt: float) -> void:
	var depth := player.global_position.y / World.METER
	_watch_t -= dt
	if depth > WATCHERS_FROM and _watch_t <= 0.0:
		_watch_t = randf_range(3.0, 8.0)
		if get_tree().get_nodes_in_group("watcher").size() < 3:
			_spawn_watcher()
	_crawl_t -= dt
	if depth > CRAWLERS_FROM and _crawl_t <= 0.0:
		_crawl_t = randf_range(2.0, 5.0)
		var cap := 2 + int(depth / 100.0)
		if get_tree().get_nodes_in_group("creature").size() < cap:
			_spawn_crawler()
	for c: Node2D in get_tree().get_nodes_in_group("creature"):
		if c.global_position.distance_to(player.global_position) > DESPAWN_DIST:
			c.queue_free()
	if drill.global_position.y / World.METER > WORMS_FROM and get_tree().get_nodes_in_group("worm").is_empty():
		_worm_t -= dt
		if _worm_t <= 0.0:
			_worm_t = randf_range(WORM_EVERY.x, WORM_EVERY.y)
			spawn_worm()


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
func _spawn_crawler() -> void:
	for i in 40:
		var pos := player.global_position + Vector2(randf_range(-460, 460), randf_range(-200, 260))
		var d := pos.distance_to(player.global_position)
		if d < 260.0 or d > 460.0 or not _open_cave(pos, 14.0):
			continue
		var floor_y := pos.y
		while world.is_air(Vector2(pos.x, floor_y + 4.0)) and floor_y < pos.y + 120.0:
			floor_y += 4.0
		if floor_y >= pos.y + 120.0:
			continue
		var c := Crawler.new()
		c.world = world
		c.player = player
		c.glow_parent = glow_parent
		c.position = Vector2(pos.x, floor_y - 9.0)
		c.killed.connect(crawler_killed.emit)
		lit_parent.add_child(c)
		return


func _open_cave(pos: Vector2, r: float) -> bool:
	if pos.x < 40 or pos.x > World.WIDTH_PX - 40 or pos.y < 60:
		return false
	for o in [Vector2.ZERO, Vector2(-r, 0), Vector2(r, 0), Vector2(0, -r), Vector2(0, r)]:
		var c := world.cell_at(pos + o)
		if world.get_fill(c.x, c.y) > 0.2 or world.dug.has(c):
			return false
	return true
