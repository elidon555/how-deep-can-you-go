class_name NetEntities
## Online co-op: the drill, the miners and everything that moves or can be used, sent by the
## host 20 times a second (snapshot) and shown on clients (apply, then smooth every frame).
## Something shared joins group "net" and has:
##   var puppet := false          set on clients: it's shown, not simulated (its logic is skipped)
##   func net_state() -> Array    host: what a client needs to show it, besides where it is
##   func net_apply(s: Array)     client: show that
## Positions and velocities are handled here for all of them (the client slides things toward
## where they'll be by now). Things far from every player and the drill aren't sent: clients drop
## them and make them again when someone comes near. The drill is in every snapshot.

const RANGE := 1400.0          # px from a player or the drill
const SMOOTH := 16.0           # how fast clients slide things to where the host has them
const SNAP_DIST := 160.0       # further off than this: jump there
const LOOKAHEAD := 0.2         # s of velocity to extrapolate at most

## kind, class, where clients put it ("world" or "main", like the host does)
static var TYPES := [
	["player", Player, "main"], ["bat", Bat, "main"], ["crawler", Crawler, "main"],
	["worm", Worm, "main"], ["eye", TheEye, "main"], ["vein", TheEye.Vein, "main"],
	["orb", TheEye.Orb, "main"], ["bolt", Turret.Bolt, "main"], ["gas", GasCloud, "main"],
	["boulder", Boulder, "world"], ["crate", CampItems.LootCrate, "world"],
	["note", CampItems.Note, "world"], ["drone", Drone, "main"],
]

var main                       # the run (src/main.gd)
var _next_id := 1
var _nodes := {}               # client: id -> node
var _target := {}              # client: id -> [position, velocity, received at (s)]


# ---------------------------------------------------------------- host

func snapshot() -> Array:
	var tree: SceneTree = main.get_tree()
	var centres: Array[Vector2] = [main.drill.global_position]
	for p: Player in main.players:
		centres.append(p.global_position)
	var ents := []
	for n: Node2D in tree.get_nodes_in_group("net"):
		if n.is_queued_for_deletion() or not _near(n.global_position, centres):
			continue
		if not n.has_meta("net_id"):
			n.set_meta("net_id", _next_id)
			n.set_meta("net_kind", _kind_of(n))
			_next_id += 1
		var kind: int = n.get_meta("net_kind")
		if kind < 0:
			continue
		ents.append([n.get_meta("net_id"), kind, n.global_position, _velocity(n), n.net_state()])
	return [main.drill.global_position, main.drill.net_state(), ents]


static func _kind_of(n: Node) -> int:
	for i in TYPES.size():
		if is_instance_of(n, TYPES[i][1]):
			return i
	push_warning("NetEntities: %s is in group \"net\" but isn't a known kind" % n)
	return -1


static func _velocity(n: Node) -> Vector2:
	var v = n.get("velocity")
	return v if v is Vector2 else Vector2.ZERO


static func _near(p: Vector2, centres: Array[Vector2]) -> bool:
	for c in centres:
		if p.distance_squared_to(c) < RANGE * RANGE:
			return true
	return false


# ---------------------------------------------------------------- client

func apply(snap: Array) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_target[0] = [snap[0], Vector2.ZERO, now]
	_nodes[0] = main.drill
	main.drill.net_apply(snap[1])
	var seen := {0: true}
	for e: Array in snap[2]:
		var id: int = e[0]
		seen[id] = true
		var n: Node2D = _nodes.get(id)
		if n == null or not is_instance_valid(n):
			n = _spawn(e[1], e[2], e[4])
			if n == null:
				continue
			_nodes[id] = n
		n.net_apply(e[4])
		_target[id] = [e[2], e[3], now]
	for id in _nodes.keys():
		if not seen.has(id):
			_despawn(id)


## Every frame: slide everything toward where the host has it (plus a little lookahead).
func smooth(dt: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var k := 1.0 - exp(-SMOOTH * dt)
	for id in _target:
		var n: Node2D = _nodes.get(id)
		if n == null or not is_instance_valid(n):
			continue
		var t: Array = _target[id]
		var want: Vector2 = t[0] + t[1] * minf(now - t[2], LOOKAHEAD)
		if n.global_position.distance_to(want) > SNAP_DIST:
			n.global_position = want
		else:
			n.global_position = n.global_position.lerp(want, k)


func node(id: int) -> Node2D:
	var n: Node2D = _nodes.get(id)
	return n if n != null and is_instance_valid(n) else null


## The host's id for a node shown here (players carry it in their state too), or 0.
func id_of(n: Node) -> int:
	return n.get_meta("net_id", 0) if n else 0


func _spawn(kind: int, at: Vector2, state: Array) -> Node2D:
	var t: Array = TYPES[kind]
	if t[0] == "player":
		var p: Player = main.puppet_player(int(state[0]))
		p.global_position = at
		return p
	if t[0] == "vein" and main.eye == null:
		return null                     # its eye hasn't shown up yet: next snapshot
	var n: Node2D = t[1].new()
	for f in ["world", "drill", "spawner"]:
		if f in n:
			n.set(f, main.get(f))
	if "glow_parent" in n:
		n.glow_parent = main.glow_layer
	if "eye" in n:
		n.eye = main.eye
	n.puppet = true
	n.position = at                     # (both parents sit at the origin)
	(main.world if t[2] == "world" else main).add_child(n)
	if t[0] == "eye":
		main.eye = n
	return n


func _despawn(id: int) -> void:
	var n: Node2D = _nodes.get(id)
	_nodes.erase(id)
	_target.erase(id)
	if n == null or not is_instance_valid(n):
		return
	if n is Player:
		main.remove_player(n)
	else:
		n.queue_free()
