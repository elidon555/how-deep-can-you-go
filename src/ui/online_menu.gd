extends Control
class_name OnlineMenu
## Online co-op from the title screen: host a game (others join you, up to Net.MAX_PLAYERS),
## or join one by the host's address. The last address is remembered (Settings).

signal host_pressed(port: int)

var _name := LineEdit.new()
var _address := LineEdit.new()
var _port := SpinBox.new()
var _status := UiStyle.label("", 18, UiStyle.DIM)


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.5)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var box := UiStyle.centered_box(self, 520)
	box.add_child(UiStyle.label("Play together", 36))
	box.add_child(UiStyle.label("Up to %d miners crew the same drill." % Net.MAX_PLAYERS, 18, UiStyle.DIM))
	_name.placeholder_text = "your name"
	_name.max_length = 14
	_name.text = Settings.player_name
	_name.custom_minimum_size = Vector2(300, 42)
	_name.add_theme_font_size_override("font_size", 22)
	_name.text_changed.connect(func(t): Settings.player_name = t.strip_edges())
	box.add_child(_name)
	box.add_child(UiStyle.role_button())
	box.add_child(UiStyle.button("Host a game", func(): host_pressed.emit(int(_port.value))))
	box.add_child(UiStyle.label("— or join one —", 18, UiStyle.DIM))
	_address.placeholder_text = "host's address (e.g. 192.168.1.20)"
	_address.text = Settings.last_address
	_address.custom_minimum_size = Vector2(300, 42)
	_address.add_theme_font_size_override("font_size", 22)
	_address.text_submitted.connect(func(_t): _join())
	box.add_child(_address)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(UiStyle.label("Port", 20))
	_port.min_value = 1024
	_port.max_value = 65535
	_port.value = Net.DEFAULT_PORT
	row.add_child(_port)
	box.add_child(row)
	box.add_child(UiStyle.button("Join", _join))
	box.add_child(_status)
	box.add_child(UiStyle.button("Back", close))
	Net.status_changed.connect(_on_status)


func _on_status(text: String) -> void:
	_status.text = text


func open() -> void:
	visible = true
	_status.text = ""
	_address.grab_focus()


func close() -> void:
	visible = false
	Settings.save()
	if Net.is_client() and Net.run.is_empty():
		Net.leave()                 # gave up waiting


func _join() -> void:
	var address := _address.text.strip_edges()
	if address == "":
		_status.text = "Type the host's address first."
		return
	Settings.last_address = address
	Settings.save()
	Net.join(address, int(_port.value))


func _unhandled_input(event: InputEvent) -> void:
	if visible and Controls.any_pressed(event, "ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
