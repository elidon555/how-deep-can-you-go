class_name UiStyle
## The look shared by every menu: dark panels with a brass border, chunky buttons, big titles.

const BRASS := Color("8a6a42")
const PAPER := Color("f4e3c1")
const DIM := Color("d9c9b0")


static func panel() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.05, 0.04, 0.06, 0.93)
	s.border_color = BRASS
	s.set_border_width_all(3)
	s.set_corner_radius_all(6)
	s.set_content_margin_all(26)
	return s


static func label(text: String, size: int, color := PAPER) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", maxi(4, size / 6))
	return l


static func button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(300, 46)
	b.add_theme_font_size_override("font_size", 24)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.14, 0.11, 0.09)
	normal.border_color = BRASS
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(4)
	var hover := normal.duplicate()
	hover.bg_color = Color(0.3, 0.22, 0.13)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("focus", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.pressed.connect(func():
		Sfx.play("ui_click", Vector2.INF, -4.0, 0.0)
		on_press.call())
	return b


## A centred column inside a panel, added to `parent` (full screen).
static func centered_box(parent: Control, width := 420.0) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(center)
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", panel())
	pc.custom_minimum_size = Vector2(width, 0)
	center.add_child(pc)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	pc.add_child(box)
	return box


## A button that cycles your crew role (Roles, saved in Settings) and shows its perk.
static func role_button() -> Button:
	var b := button("", func(): pass)
	b.custom_minimum_size = Vector2(380, 46)
	var show := func(): b.text = "Role: %s — %s" % [Roles.NAMES[Settings.role], Roles.PERKS[Settings.role]]
	show.call()
	b.pressed.connect(func():
		Settings.role = Roles.next(Settings.role)
		Settings.save()
		show.call())
	return b
