extends PanelContainer
class_name Shop
## The merchant's shop: spend banked money on upgrades (Progress.UPGRADES).
## Click a row's button or press its number key; E / Esc closes.

signal closed

var _money := Label.new()
var _rows := VBoxContainer.new()


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.07, 0.94)
	style.border_color = Color("8a6a42")
	style.set_border_width_all(3)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(22)
	add_theme_stylebox_override("panel", style)
	position = Vector2(340, 40)
	custom_minimum_size = Vector2(600, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	add_child(box)
	var title := Label.new()
	title.text = "Workbench"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color("f4e3c1"))
	box.add_child(title)
	_money.add_theme_font_size_override("font_size", 24)
	_money.add_theme_color_override("font_color", Color("9fd88a"))
	box.add_child(_money)
	_rows.add_theme_constant_override("separation", 8)
	box.add_child(_rows)
	var hint := Label.new()
	hint.text = "Number keys or click to buy · E to close"
	hint.modulate.a = 0.6
	box.add_child(hint)
	Progress.changed.connect(_refresh)


func open() -> void:
	visible = true
	_refresh()
	await get_tree().process_frame
	for row in _rows.get_children():                # focus the first button (controllers)
		var b: Button = row.get_child(row.get_child_count() - 1)
		if not b.disabled:
			b.grab_focus()
			break


func close() -> void:
	if visible:
		visible = false
		closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if Controls.any_pressed(event, "interact") or Controls.any_pressed(event, "ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		var n: int = event.physical_keycode - KEY_1
		var ids := Progress.UPGRADES.keys()
		if n >= 0 and n < ids.size():
			_buy(ids[n])
			get_viewport().set_input_as_handled()


func _buy(id: String) -> void:
	if Net.is_client():                # online the crew's money is on the host: it buys
		Net.session.buy(id)
		Sfx.play("ui_click", Vector2.INF, -2.0, 0.0)
		return
	if Progress.buy(id):
		Sfx.play("coins")
	else:
		Sfx.play("ui_click", Vector2.INF, -6.0, 0.0)


func _refresh() -> void:
	_money.text = "Unlimited money (playtest mode)" if GameConfig.infinite_resources() else "You have $%d" % Progress.money
	for c in _rows.get_children():
		c.queue_free()
	var i := 1
	for id in Progress.UPGRADES:
		var u: Dictionary = Progress.UPGRADES[id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var name := Label.new()
		var lvl := Progress.level(id)
		var pips: String = "" if u.get("module", false) else "●".repeat(lvl) + "○".repeat(u.costs.size() - lvl)
		name.text = ("%d. " % i if i <= 9 else "    ") + "%s  %s" % [u.name, pips]
		name.custom_minimum_size = Vector2(330, 0)
		name.tooltip_text = u.desc
		row.add_child(name)
		var desc := Label.new()
		desc.text = u.desc
		desc.modulate.a = 0.6
		desc.custom_minimum_size = Vector2(0, 0)
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(desc)
		var b := Button.new()
		var cost := Progress.cost(id)
		b.text = ("BUILT" if u.get("module", false) else "MAX") if cost < 0 else "$%d" % cost
		b.disabled = cost < 0 or not Progress.can_afford(cost)
		b.custom_minimum_size = Vector2(80, 0)
		b.focus_mode = Control.FOCUS_ALL        # a controller can move between the buttons
		b.pressed.connect(_buy.bind(id))
		row.add_child(b)
		_rows.add_child(row)
		i += 1
