extends RefCounted
class_name PlayerInput
## One player's controls: their action names (prefix "" = player one on keyboard + mouse,
## "p2_" = a second player on their own controller, see Controls.add_pad_player) and whether
## they aim with the mouse. Everything a player does reads input through this, never Input
## directly, so each player only moves themselves (and online co-op can feed it later).

var prefix := ""
var uses_mouse := true


func _init(action_prefix := "", mouse := true) -> void:
	prefix = action_prefix
	uses_mouse = mouse


func pressed(action: String) -> bool:
	return Input.is_action_pressed(prefix + action)


func just_pressed(action: String) -> bool:
	return Input.is_action_just_pressed(prefix + action)


func just_released(action: String) -> bool:
	return Input.is_action_just_released(prefix + action)


func axis(negative: String, positive: String) -> float:
	return Input.get_axis(prefix + negative, prefix + positive)


## Is this event one of this player's presses of `action`? (for menus that listen to events)
func is_event(event: InputEvent, action: String) -> bool:
	return event.is_action_pressed(prefix + action)
