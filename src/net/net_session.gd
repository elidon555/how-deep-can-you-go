extends Node
class_name NetSession
## One online run, seen from this machine (main adds it while Net is online). Everyone crews
## the same drill. The host runs the game for the whole crew and sends the result 20 times a
## second; clients send their controls every frame and show what arrives:
##   NetInput     (net_input.gd)     a remote miner's controls, fed into their Player
##   NetWorld     (net_world.gd)     dug rock and flowing liquid
##   NetEntities  (net_entities.gd)  the drill, the miners, creatures and things in the world
## Effects, sounds, toasts and the end of the run are the host's calls repeated on clients
## (Net.echo into ECHO_TARGETS). The host's upgrades and money are the crew's: clients mirror them
## (Progress.mirror) and buy through the host.

const RATE := 1.0 / 20.0
const ECHO_TARGETS := [&"fx", &"sfx", &"hud", &"menus", &"main"]

var main                       # the run (src/main.gd)
var entities := NetEntities.new()
var _capture := NetInput.Capture.new()
var _ready_peers := {}         # host: peer id -> their Player
var _t := 0.0


func _ready() -> void:
	name = "NetSession"
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 100        # after everything moved this frame
	entities.main = main
	Net.session = self
	tree_exiting.connect(func(): if Net.session == self: Net.session = null)
	if Net.is_host():
		main.world.record = true
		Progress.changed.connect(_send_progress)
	else:
		Net.send(1, "ready")


## Host: what a joining client needs to load this run.
func run_info() -> Dictionary:
	return {"seed": main.world.seed, "daily": main.daily_run}


func is_full() -> bool:
	return main.players.size() >= Net.MAX_PLAYERS


func _physics_process(dt: float) -> void:
	if Net.is_client():
		if main.player:
			Net.send_unreliable(1, "input", _capture.pack(main.player))
		return
	_t += dt
	if _t < RATE:
		return
	_t = fmod(_t, RATE)
	var cells := NetWorld.take_changes(main.world)
	if not cells.is_empty():
		Net.send_all("cells", cells)
	if not _ready_peers.is_empty():
		Net.send_all_unreliable("snap", entities.snapshot())


func _process(dt: float) -> void:
	if Net.is_client():
		entities.smooth(dt)


# ---------------------------------------------------------------- messages

func receive(from: int, kind: String, data: Variant) -> void:
	if Net.is_host():
		_host_receive(from, kind, data)
	else:
		_client_receive(kind, data)


func _host_receive(from: int, kind: String, data: Variant) -> void:
	match kind:
		"ready":
			_add_peer(from)
		"input":
			var p: Player = _ready_peers.get(from)
			if p and data is Array:
				(p.input as NetInput).receive(data)
		"buy":
			Progress.buy(str(data))
		"menu_closed":
			var p: Player = _ready_peers.get(from)
			if p:
				p.frozen = false


func _client_receive(kind: String, data: Variant) -> void:
	match kind:
		"snap":
			entities.apply(data)
		"cells", "chunk":
			NetWorld.apply(main.world, data)
		"progress":
			Progress.mirror(data)
		"tell":
			_told(data)
		"echo":
			_echo(data)


## The host made a call (effect, sound, toast, menu): make it here too.
func _echo(data: Array) -> void:
	var target: StringName = data[0]
	if not ECHO_TARGETS.has(target):
		return
	var n: Object = Sfx if target == &"sfx" else main if target == &"main" else main.get(target)
	if target == &"sfx":
		Sfx.from_host = true
	n.callv(data[1], data[2])
	Sfx.from_host = false


# ---------------------------------------------------------------- host: the crew

## A client loaded the world: give them a miner in the drill and everything that's changed.
func _add_peer(peer: int) -> void:
	if _ready_peers.has(peer) or is_full():
		return
	var p: Player = main.add_remote_player(NetInput.new(peer))
	_ready_peers[peer] = p
	for key: Vector2i in main.world.touched:
		Net.send(peer, "chunk", NetWorld.pack_chunk(main.world, key))
	_send_progress()
	main.hud.toast("Player %d joined the crew." % p.number, 2.0)


## Host: someone disconnected (their miner leaves with them).
func peer_left(peer: int) -> void:
	var p: Player = _ready_peers.get(peer)
	_ready_peers.erase(peer)
	if p and is_instance_valid(p):
		main.hud.toast("Player %d left." % p.number, 2.0)
		main.remove_player(p)


## Host: something for one remote miner's screen only: "menu" (shop, sonar, "note:<id>"),
## "note" (a message, [text, seconds]) or "shake" (amount).
func tell(p: Player, what: String, data: Variant) -> void:
	if p.input is NetInput:
		Net.send((p.input as NetInput).peer, "tell", [what, data])


func _told(d: Array) -> void:
	match d[0]:
		"menu":
			main.open_menu(str(d[1]))
		"note":
			main.hud.note(str(d[1][0]), float(d[1][1]))
		"shake":
			main.shake = maxf(main.shake, float(d[1]))


## Client: a menu this machine opened for the host has closed (unfreeze our miner there).
func menu_closed() -> void:
	Net.send(1, "menu_closed")


func buy(id: String) -> void:
	Net.send(1, "buy", id)


func _send_progress() -> void:
	Net.send_all("progress", Progress.mirror_state())
