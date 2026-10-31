extends Control
class_name NoteView
## Reading a miner's note: a yellowed page over the paused game. E / Esc / click closes.
## Group "note_view" (CampItems.Note calls show_note).

var _title := UiStyle.label("", 28, Color("3a2a18"))
var _body := Label.new()
var _count := UiStyle.label("", 16, Color("6a5236"))


func _ready() -> void:
	add_to_group("note_view")
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var paper := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color("d9c7a0")
	s.border_color = Color("8a6a42")
	s.set_border_width_all(2)
	s.set_content_margin_all(30)
	s.shadow_size = 8
	s.shadow_color = Color(0, 0, 0, 0.5)
	paper.add_theme_stylebox_override("panel", s)
	paper.custom_minimum_size = Vector2(560, 0)
	center.add_child(paper)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	paper.add_child(box)
	_title.add_theme_constant_override("outline_size", 0)
	box.add_child(_title)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD
	_body.custom_minimum_size = Vector2(500, 0)
	_body.add_theme_font_size_override("font_size", 20)
	_body.add_theme_color_override("font_color", Color("2e2214"))
	box.add_child(_body)
	_count.add_theme_constant_override("outline_size", 0)
	box.add_child(_count)


func show_note(id: int) -> void:
	var n: Dictionary = Lore.NOTES[id]
	_title.text = n.title
	_body.text = n.text
	_count.text = "Notes found: %d / %d   ·   E to close" % [Progress.found_notes.size(), Lore.NOTES.size()]
	visible = true
	get_tree().paused = true


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if Controls.any_pressed(event, "interact") or Controls.any_pressed(event, "ui_cancel") \
			or (event is InputEventMouseButton and event.pressed):
		visible = false
		get_tree().paused = false
		get_viewport().set_input_as_handled()
