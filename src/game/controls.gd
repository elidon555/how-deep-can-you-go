class_name Controls
## All input bindings in one place (keyboard, mouse, controller), registered at startup.

const KEYS := {
	"left": [KEY_A, KEY_LEFT], "right": [KEY_D, KEY_RIGHT],
	"up": [KEY_W, KEY_UP], "down": [KEY_S, KEY_DOWN],
	"jump": [KEY_SPACE, KEY_W, KEY_UP],   # W / Up jump too
	"dig": [KEY_J],
	"tool": [KEY_Q],                     # use the tool in hand (grapple, flare, dynamite ...)
	"tool_next": [KEY_TAB],
	"interact": [KEY_E],
	"roll": [KEY_SHIFT],
	"ping": [KEY_F],
	"restart": [KEY_R],
}
const MOUSE := {"dig": MOUSE_BUTTON_LEFT, "tool": MOUSE_BUTTON_RIGHT, "ping": MOUSE_BUTTON_MIDDLE,
	"tool_next": MOUSE_BUTTON_WHEEL_DOWN}
const PAD := {
	"left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT,
	"up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN,
	"jump": JOY_BUTTON_A, "dig": JOY_BUTTON_X, "tool": JOY_BUTTON_Y, "tool_next": JOY_BUTTON_RIGHT_STICK,
	"interact": JOY_BUTTON_B, "restart": JOY_BUTTON_BACK, "roll": JOY_BUTTON_RIGHT_SHOULDER,
	"ping": JOY_BUTTON_LEFT_SHOULDER,
}
const STICK := {"left": [JOY_AXIS_LEFT_X, -1.0], "right": [JOY_AXIS_LEFT_X, 1.0],
	"up": [JOY_AXIS_LEFT_Y, -1.0], "down": [JOY_AXIS_LEFT_Y, 1.0]}
const HELP := "A/D move · W/Space jump · Shift roll · Left click dig (or J) · Right click / Q tool · Tab switch tool · E use · F ping"


static func setup() -> void:
	for action in KEYS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.4)
		for k in KEYS[action]:
			var e := InputEventKey.new()
			e.physical_keycode = k
			InputMap.action_add_event(action, e)
		if MOUSE.has(action):
			var m := InputEventMouseButton.new()
			m.button_index = MOUSE[action]
			InputMap.action_add_event(action, m)
		_add_pad_events(action, action, -1)


## Menus answer every player: is this event `action` from player one or a joined player?
static func any_pressed(event: InputEvent, action: String) -> bool:
	if event.is_action_pressed(action):
		return true
	return InputMap.has_action("p2_" + action) and event.is_action_pressed("p2_" + action)


## A second player on their own controller: the same actions with `prefix`, bound only to
## `device`. Player one's actions stop listening to that controller.
static func add_pad_player(prefix: String, device: int) -> void:
	for action in PAD:
		if InputMap.has_action(prefix + action):
			InputMap.erase_action(prefix + action)
		InputMap.add_action(prefix + action, 0.4)
		_add_pad_events(prefix + action, action, device)
	if InputMap.has_action(prefix + "ui_cancel"):
		InputMap.erase_action(prefix + "ui_cancel")
	InputMap.add_action(prefix + "ui_cancel", 0.4)
	var start := InputEventJoypadButton.new()
	start.button_index = JOY_BUTTON_START
	start.device = device
	InputMap.action_add_event(prefix + "ui_cancel", start)
	for action in PAD:                 # player one: keyboard + mouse (+ any other controller)
		for e in InputMap.action_get_events(action):
			if (e is InputEventJoypadButton or e is InputEventJoypadMotion) and e.device == -1:
				InputMap.action_erase_event(action, e)
				var copy: InputEvent = e.duplicate()
				for other in Input.get_connected_joypads():
					if other != device:
						copy = e.duplicate()
						copy.device = other
						InputMap.action_add_event(action, copy)


static func _add_pad_events(action: String, base: String, device: int) -> void:
	var b := InputEventJoypadButton.new()
	b.button_index = PAD[base]
	b.device = device
	InputMap.action_add_event(action, b)
	if STICK.has(base):
		var s := InputEventJoypadMotion.new()
		s.axis = STICK[base][0]
		s.axis_value = STICK[base][1]
		s.device = device
		InputMap.action_add_event(action, s)
