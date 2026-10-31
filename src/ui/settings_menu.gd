extends Control
class_name SettingsMenu
## Volume sliders and fullscreen (Autoload Settings). Back returns to whoever opened it.

signal closed


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := UiStyle.centered_box(self, 460)
	box.add_child(UiStyle.label("Settings", 36))
	_slider(box, "Master volume", Settings.master, func(v): Settings.master = v)
	_slider(box, "Music", Settings.music, func(v): Settings.music = v)
	_slider(box, "Effects", Settings.effects, func(v): Settings.effects = v)
	var fs := CheckButton.new()
	fs.text = "Fullscreen"
	fs.add_theme_font_size_override("font_size", 22)
	fs.button_pressed = Settings.fullscreen
	fs.toggled.connect(func(on):
		Settings.fullscreen = on
		Settings.apply())
	box.add_child(fs)
	box.add_child(UiStyle.button("Back", close))


func open() -> void:
	visible = true


func close() -> void:
	Settings.save()
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _slider(box: VBoxContainer, text: String, value: float, set_value: Callable) -> void:
	box.add_child(UiStyle.label(text, 20, UiStyle.DIM))
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = value
	s.custom_minimum_size = Vector2(360, 24)
	s.value_changed.connect(func(v):
		set_value.call(v)
		Settings.apply())
	box.add_child(s)
