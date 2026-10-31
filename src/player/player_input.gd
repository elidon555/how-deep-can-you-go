extends RefCounted
class_name PlayerInput
## One player's controls: their action names (prefix "" = player one on keyboard + mouse,
## "p2_" = a second player on their own controller, see Controls.add_pad_player) and whether
## they aim with the mouse. Everything a player does reads input through this, never Input
## directly, so each player only moves themselves. Online, a remote player's controls come in
## over the network instead (NetInput, src/net/net_input.gd).

## A menu on this machine has the controls (online the game doesn't pause behind it).
static var menu_open := false

var prefix := ""
var uses_mouse := true


func _init(action_prefix := "", mouse := true) -> void:
	prefix = action_prefix
	uses_mouse = mouse


## Controls on this machine (not someone's over the network)?
func is_local() -> bool:
	return true


## Called as the player's frame starts (NetInput takes in what arrived).
func update(_p: Player) -> void:
	pass


func pressed(action: String) -> bool:
	return not menu_open and Input.is_action_pressed(prefix + action)


func just_pressed(action: String) -> bool:
	return not menu_open and Input.is_action_just_pressed(prefix + action)


func just_released(action: String) -> bool:
	return Input.is_action_just_released(prefix + action)


func axis(negative: String, positive: String) -> float:
	return 0.0 if menu_open else Input.get_axis(prefix + negative, prefix + positive)


## Is this event one of this player's presses of `action`? (for menus that listen to events)
func is_event(event: InputEvent, action: String) -> bool:
	return event.is_action_pressed(prefix + action)
