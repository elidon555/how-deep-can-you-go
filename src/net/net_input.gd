extends PlayerInput
class_name NetInput
## A remote player's controls (online co-op): what they hold, what they pressed and where they
## aim, sent by their machine every frame (NetInput.Capture packs it there). The host's Player
## reads this like any PlayerInput. Presses travel as counters, so a quick click survives a
## dropped packet and still counts exactly once.

const ACTIONS := ["left", "right", "up", "down", "jump", "dig", "tool", "interact", "roll", "ui_cancel", "ping",
	"tool_next"]

var peer := 0
var aim := Vector2.INF        # where they point (world), from their own mouse / stick
var mouse_aim := false        # their pick follows the pointer (vs. the direction keys)
var _held := 0                # a bit per ACTIONS entry, as last sent
var _taps := 0                # pressed since the last frame
var _counts := PackedByteArray()
var _now := 0                 # this frame's buttons
var _before := 0              # last frame's
var _move := Vector2.ZERO     # analog left/right and up/down


func _init(peer_id := 0) -> void:
	peer = peer_id
	uses_mouse = false
	_counts.resize(ACTIONS.size())


func is_local() -> bool:
	return false


## Their machine's latest controls (Capture.pack()).
func receive(d: Array) -> void:
	if d.size() < 6:
		return
	_held = int(d[0])
	var counts: PackedByteArray = d[1]
	for i in mini(counts.size(), ACTIONS.size()):
		if counts[i] != _counts[i]:
			_taps |= 1 << i
			_counts[i] = counts[i]
	_move = d[2]
	aim = d[3]
	mouse_aim = bool(d[4])
	uses_mouse = bool(d[5])


## Once per physics frame, as their Player starts its frame: this frame's buttons, their aim.
func update(p: Player) -> void:
	_before = _now
	_now = _held | _taps
	_taps = 0
	p.aim_override = aim
	p.pick.aim_at = aim
	p.pick.mouse_aim = mouse_aim


func pressed(action: String) -> bool:
	return _now & _bit(action) != 0


func just_pressed(action: String) -> bool:
	var b := _bit(action)
	return _now & b != 0 and _before & b == 0


func just_released(action: String) -> bool:
	var b := _bit(action)
	return _before & b != 0 and _now & b == 0


func axis(negative: String, positive: String) -> float:
	if negative == "left" and positive == "right":
		return _move.x
	if negative == "up" and positive == "down":
		return _move.y
	return float(pressed(positive)) - float(pressed(negative))


func is_event(_event: InputEvent, _action: String) -> bool:
	return false


static func _bit(action: String) -> int:
	var i := ACTIONS.find(action)
	return 0 if i < 0 else 1 << i


## This machine's side: packs the local player's controls to send to the host.
class Capture:
	var _counts := PackedByteArray()

	func _init() -> void:
		_counts.resize(ACTIONS.size())

	func pack(p: Player) -> Array:
		var held := 0
		for i in ACTIONS.size():
			if p.input.pressed(ACTIONS[i]):
				held |= 1 << i
			if p.input.just_pressed(ACTIONS[i]):
				_counts[i] = (_counts[i] + 1) & 255
		var move := Vector2(p.input.axis("left", "right"), p.input.axis("up", "down"))
		return [held, _counts, move, p.aim_point(), p.pick.mouse_aim, p.input.uses_mouse]
