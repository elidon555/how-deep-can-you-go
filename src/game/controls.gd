class_name Controls
## All input bindings in one place (keyboard, mouse, controller), registered at startup.

const KEYS := {
	"left": [KEY_A, KEY_LEFT], "right": [KEY_D, KEY_RIGHT],
	"up": [KEY_W, KEY_UP], "down": [KEY_S, KEY_DOWN],
	"jump": [KEY_SPACE, KEY_W, KEY_UP],   # W / Up jump too (on a rope they climb instead)
	"dig": [KEY_J],
	"rope": [KEY_Q],
	"interact": [KEY_E],
	"restart": [KEY_R],
}
const MOUSE := {"dig": MOUSE_BUTTON_LEFT, "rope": MOUSE_BUTTON_RIGHT}
const PAD := {
	"left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT,
	"up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN,
	"jump": JOY_BUTTON_A, "dig": JOY_BUTTON_X, "rope": JOY_BUTTON_Y,
	"interact": JOY_BUTTON_B, "restart": JOY_BUTTON_BACK,
}
const STICK := {"left": [JOY_AXIS_LEFT_X, -1.0], "right": [JOY_AXIS_LEFT_X, 1.0],
	"up": [JOY_AXIS_LEFT_Y, -1.0], "down": [JOY_AXIS_LEFT_Y, 1.0]}
const HELP := "A/D move · Space/W jump · hold Left click to dig where you point (or J + W/A/S/D) · Q/Right-click rope · E use · R restart"


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
		var b := InputEventJoypadButton.new()
		b.button_index = PAD[action]
		InputMap.action_add_event(action, b)
		if STICK.has(action):
			var s := InputEventJoypadMotion.new()
			s.axis = STICK[action][0]
			s.axis_value = STICK[action][1]
			InputMap.action_add_event(action, s)
