extends Node
## Autoload "Net": online co-op, up to MAX_PLAYERS miners crewing the one drill.
## One machine hosts: it runs the whole game (world, drill, creatures, liquids, every miner).
## The others join by address, send their controls and show what the host sends back.
## This file is the connection and the message transport only; what a run sends and how it's
## applied lives in NetSession (net_session.gd), which main adds while online.
##
## Messages are (kind, data). send / send_all are reliable and arrive in order; the
## _unreliable ones (snapshots, controls) can be dropped, the next one replaces them.
## Joining: the client says "hello", the host answers "welcome" with the run's seed, the client
## loads that world and says "ready" (NetSession takes it from there).

signal status_changed(text: String)               # for the join screen
signal message(from: int, kind: String, data: Variant)

const DEFAULT_PORT := 24680
const MAX_PLAYERS := 4
const VERSION := 1                 # a client must match the host's
const MAIN_SCENE := "res://src/main.tscn"

enum Mode { OFFLINE, HOST, CLIENT }

var mode := Mode.OFFLINE
var session: Node = null           # the run's NetSession, while one is up
var run := {}                      # client: what the host said about the run (seed, daily)
var notice := ""                   # shown on the title screen once (e.g. "The host left")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(func(): send(1, "hello", {"version": VERSION}))
	multiplayer.connection_failed.connect(func(): _drop("Couldn't reach the host."))
	multiplayer.server_disconnected.connect(func(): _drop("The host ended the game."))


func is_online() -> bool:
	return mode != Mode.OFFLINE


func is_host() -> bool:
	return mode == Mode.HOST


func is_client() -> bool:
	return mode == Mode.CLIENT


## This machine's peer id (1 = the host, and when offline).
func my_id() -> int:
	return multiplayer.get_unique_id() if is_online() else 1


# ---------------------------------------------------------------- sessions

func host(port := DEFAULT_PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		status_changed.emit("Couldn't host on port %d (%s)." % [port, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.HOST
	return OK


func join(address: String, port := DEFAULT_PORT) -> Error:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		status_changed.emit("Couldn't connect to %s (%s)." % [address, error_string(err)])
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	status_changed.emit("Connecting to %s:%d..." % [address, port])
	return OK


func leave() -> void:
	if not is_online():
		return
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if is_client():
		Progress.end_mirror()          # back to this machine's own save
	mode = Mode.OFFLINE
	run = {}


## Host: a new run is starting (restart); everyone loads the same world.
func new_run(info: Dictionary) -> void:
	if is_host():
		send_all("new_run", info)


## Client: lost the host (or never reached it): back to the title with a note.
func _drop(why: String) -> void:
	var was_in_run := is_client() and not run.is_empty()
	leave()
	status_changed.emit(why)
	if was_in_run:
		notice = why
		get_tree().paused = false
		get_tree().change_scene_to_file(MAIN_SCENE)


# ---------------------------------------------------------------- transport

func send(to: int, kind: String, data: Variant = null) -> void:
	if is_online():
		_msg.rpc_id(to, kind, data)


## Host: to every client.
func send_all(kind: String, data: Variant = null) -> void:
	if is_host():
		_msg.rpc(kind, data)


func send_unreliable(to: int, kind: String, data: Variant = null) -> void:
	if is_online():
		_umsg.rpc_id(to, kind, data)


func send_all_unreliable(kind: String, data: Variant = null) -> void:
	if is_host():
		_umsg.rpc(kind, data)


## Host: have every client make the same call (an effect, a sound, a toast, a menu).
## `target` is one of NetSession.ECHO_TARGETS. Sounds and effects may be dropped; the rest not.
func echo(target: StringName, method: StringName, args: Array) -> void:
	if not is_host() or multiplayer.get_peers().is_empty():
		return
	if target == &"fx" or target == &"sfx":
		_umsg.rpc("echo", [target, method, args])
	else:
		_msg.rpc("echo", [target, method, args])


@rpc("any_peer", "call_remote", "reliable")
func _msg(kind: String, data: Variant) -> void:
	_receive(multiplayer.get_remote_sender_id(), kind, data)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _umsg(kind: String, data: Variant) -> void:
	_receive(multiplayer.get_remote_sender_id(), kind, data)


func _receive(from: int, kind: String, data: Variant) -> void:
	if is_client() and from != 1:
		return                          # clients only listen to the host
	match kind:
		"hello":
			_on_hello(from, data)
		"welcome", "new_run":
			_start_run(data)
		"refused":
			_drop(str(data))
		_:
			message.emit(from, kind, data)
			if session:
				session.receive(from, kind, data)


# ---------------------------------------------------------------- joining

func _on_peer_connected(_id: int) -> void:
	pass                                # they introduce themselves with "hello"


func _on_peer_disconnected(id: int) -> void:
	if session:
		session.peer_left(id)


## Host: someone wants in. Same version and a run to join, or they're turned away.
func _on_hello(from: int, data: Variant) -> void:
	if not is_host():
		return
	var why := ""
	if not (data is Dictionary) or int(data.get("version", -1)) != VERSION:
		why = "The host runs a different version of the game."
	elif session == null:
		why = "The host isn't in a run right now."
	elif session.is_full():
		why = "The crew is full (%d players)." % MAX_PLAYERS
	if why != "":
		send(from, "refused", why)
		get_tree().create_timer(0.5).timeout.connect(func():
			if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
				multiplayer.multiplayer_peer.disconnect_peer(from))
		return
	send(from, "welcome", session.run_info())


## Client: load the host's world (their seed) and join in.
func _start_run(info: Variant) -> void:
	if not is_client() or not (info is Dictionary):
		return
	run = info
	World.fixed_seed = int(info.seed)
	status_changed.emit("Joined!")
	get_tree().paused = false
	get_tree().change_scene_to_file(MAIN_SCENE)
