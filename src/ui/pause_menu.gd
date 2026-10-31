extends Control
class_name PauseMenu
## Esc in play: freezes the game. Resume, settings, restart the run, back to the title.

signal settings_pressed
signal restart_pressed
signal title_pressed


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.5)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var box := UiStyle.centered_box(self, 380)
	box.add_child(UiStyle.label("Paused", 40))
	box.add_child(UiStyle.button("Resume", close))
	box.add_child(UiStyle.button("Settings", func(): settings_pressed.emit()))
	box.add_child(UiStyle.button("Restart run", func(): restart_pressed.emit()))
	box.add_child(UiStyle.button("Quit to title", func(): title_pressed.emit()))
	box.add_child(seed_text)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


var seed_text := UiStyle.label("", 16, UiStyle.DIM)


func open() -> void:
	visible = true
	get_tree().paused = true
	Sfx.play("ui_open", Vector2.INF, -4.0, 0.0)


func close() -> void:
	visible = false
	get_tree().paused = false
	Sfx.play("ui_close", Vector2.INF, -4.0, 0.0)
