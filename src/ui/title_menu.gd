extends Control
class_name TitleMenu
## The title screen, shown over the live world (the drill waiting at the surface).

signal start_pressed
signal daily_pressed
signal online_pressed
signal hangar_pressed
signal continue_pressed
signal settings_pressed

var _notice := UiStyle.label("", 20, Color("e05a4a"))    # e.g. "The host ended the game."


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
	_notice.visible = false
	col.add_child(_notice)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 90)         # the drill shows through here
	col.add_child(gap)
	var buttons := []
	if RunSave.exists():
		buttons.append(UiStyle.button("Continue (%d m)" % RunSave.depth(), func(): continue_pressed.emit()))
	buttons.append_array([UiStyle.button("Start digging", func(): start_pressed.emit()),
		UiStyle.button("Daily Dig (best today: %d m)" % Progress.daily.get(Progress.today(), 0), func(): daily_pressed.emit()),
		UiStyle.button("Play online", func(): online_pressed.emit())])
	for b in buttons:
		var row := CenterContainer.new()
		row.add_child(b)
		col.add_child(row)
	var role := CenterContainer.new()
	role.add_child(UiStyle.role_button())
	col.add_child(role)
	var small := HBoxContainer.new()            # the rest, side by side
	small.alignment = BoxContainer.ALIGNMENT_CENTER
	small.add_theme_constant_override("separation", 10)
	for b in [UiStyle.button("Hangar", func(): hangar_pressed.emit()),
			UiStyle.button("Settings", func(): settings_pressed.emit()),
			UiStyle.button("Quit", func(): get_tree().quit())]:
		b.custom_minimum_size = Vector2(150, 42)
		small.add_child(b)
	col.add_child(small)
	col.add_child(UiStyle.label("Best depth: %d m   ·   Notes found: %d / %d" % [
		Progress.best, Progress.found_notes.size(), Lore.NOTES.size()], 20, UiStyle.DIM))
	if Progress.beaten:
		col.add_child(UiStyle.label("The Floor has been opened.", 18, Color("e0b8ff")))


## A line under the title for why you're back here ("" for none).
func set_notice(text: String) -> void:
	_notice.text = text
	_notice.visible = text != ""
