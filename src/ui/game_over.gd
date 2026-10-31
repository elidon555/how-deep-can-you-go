extends Control
class_name GameOver
## The end of a run: why it ended and what you did. Dig again, or back to the title.

signal again_pressed
signal title_pressed

var _box: VBoxContainer


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0, 0, 0.6)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	_box = UiStyle.centered_box(self, 480)


## stats: {reason, depth, best, new_best, earned, kills, seconds}
func show_run(stats: Dictionary) -> void:
	for c in _box.get_children():
		c.queue_free()
	var won: bool = stats.has("ending")
	_box.add_child(UiStyle.label(stats.reason, 34, Color("e0b23a") if won else Color("e05a4a")))
	if won:
		_box.add_child(UiStyle.label(stats.ending, 22, UiStyle.PAPER))
	_box.add_child(UiStyle.label("Reached %d m" % stats.depth, 30))
	if stats.new_best:
		_box.add_child(UiStyle.label("A new best!", 24, Color("e0b23a")))
	else:
		_box.add_child(UiStyle.label("Best: %d m" % stats.best, 22, UiStyle.DIM))
	var mins := int(stats.seconds) / 60
	_box.add_child(UiStyle.label("Ore sold: $%d   ·   Kills: %d   ·   Time: %d:%02d" % [
		stats.earned, stats.kills, mins, int(stats.seconds) % 60], 20, UiStyle.DIM))
	if stats.get("notes", 0) > 0:
		_box.add_child(UiStyle.label("Notes found this run: %d" % stats.notes, 18, UiStyle.DIM))
	if Net.is_client():        # the host starts the next run, and everyone comes along
		_box.add_child(UiStyle.label("Waiting for the host to dig again...", 20, UiStyle.DIM))
		_box.add_child(UiStyle.button("Leave the game", func(): title_pressed.emit()))
	else:
		_box.add_child(UiStyle.button("Dig again", func(): again_pressed.emit()))
		_box.add_child(UiStyle.button("Title screen", func(): title_pressed.emit()))
	visible = true
