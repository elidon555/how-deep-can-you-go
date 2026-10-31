extends Control
class_name TitleMenu
## The title screen, shown over the live world (the drill waiting at the surface).

signal start_pressed
signal settings_pressed


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.35)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	center.add_child(col)
	col.add_child(UiStyle.label("HOW DEEP", 84))
	col.add_child(UiStyle.label("CAN YOU GO?", 54, Color("e0b23a")))
	col.add_child(UiStyle.label("Something is waiting at the bottom.", 22, UiStyle.DIM))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 150)        # the drill shows through here
	col.add_child(gap)
	for b in [UiStyle.button("Start digging", func(): start_pressed.emit()),
			UiStyle.button("Settings", func(): settings_pressed.emit()),
			UiStyle.button("Quit", func(): get_tree().quit())]:
		var row := CenterContainer.new()
		row.add_child(b)
		col.add_child(row)
	col.add_child(UiStyle.label("Best depth: %d m" % Progress.best, 20, UiStyle.DIM))
