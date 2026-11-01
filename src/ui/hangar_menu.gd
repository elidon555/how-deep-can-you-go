extends Control
class_name HangarMenu
## The Hangar (title screen): pick your drill and your helmet's colour from what you've
## unlocked (Unlocks). Locked ones say how to earn them. Saved in Settings.

var _list := VBoxContainer.new()


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var box := UiStyle.centered_box(self, 640)
	box.add_child(UiStyle.label("Hangar", 36))
	_list.add_theme_constant_override("separation", 6)
	box.add_child(_list)
	box.add_child(UiStyle.button("Back", close))


func open() -> void:
	visible = true
	_refresh()


func close() -> void:
	visible = false
	Settings.save()


func _refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	_list.add_child(UiStyle.label("Drill", 24, UiStyle.DIM))
	for id in Unlocks.DRILLS:
		var d: Dictionary = Unlocks.DRILLS[id]
		_row(d.name, d.desc, d.how, Unlocks.unlocked(id), Settings.drill == id, func():
			Settings.drill = id
			_refresh())
	_list.add_child(UiStyle.label("Helmet", 24, UiStyle.DIM))
	for id in Unlocks.HELMETS:
		var h: Dictionary = Unlocks.HELMETS[id]
		_row(h.name, "", h.how, Unlocks.unlocked(id), Settings.helmet == id, func():
			Settings.helmet = id
			_refresh())


func _row(title: String, desc: String, how: String, open: bool, chosen: bool, pick: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := Label.new()
	l.text = ("▶ " if chosen else "   ") + title + ("   " + desc if desc != "" and open else "")
	l.custom_minimum_size = Vector2(420, 0)
	l.add_theme_font_size_override("font_size", 18)
	l.modulate = Color.WHITE if open else Color(1, 1, 1, 0.45)
	row.add_child(l)
	var b := Button.new()
	b.text = "Chosen" if chosen else ("Pick" if open else "🔒 " + how)
	b.disabled = chosen or not open
	b.pressed.connect(pick)
	row.add_child(b)
	_list.add_child(row)


func _unhandled_input(event: InputEvent) -> void:
	if visible and Controls.any_pressed(event, "ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
