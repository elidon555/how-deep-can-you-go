class_name CampItems
## Things in ruined camps you can use (E): crates to search and notes to read.


## An old supply crate: search it once for whatever the last crew left (ore, coal, rope).
class LootCrate extends Station:
	signal searched(pos: Vector2, text: String)
	var seed_value := 0
	var opened := false
	var puppet := false        # online client: the host's crate

	func _ready() -> void:
		super._ready()
		add_to_group("net")

	func net_state() -> Array:
		return [opened]

	func net_apply(s: Array) -> void:
		if opened != s[0]:
			opened = s[0]
			queue_redraw()
	var _closed: Texture2D = Art.lit("res://assets/props/crate.png")
	var _open: Texture2D = Art.lit("res://assets/props/crate_open.png")

	func prompt(_p: Player) -> String:
		return "" if opened else "E: search the crate"

	func interact(p: Player) -> void:
		if opened:
			return
		opened = true
		var r := RandomNumberGenerator.new()
		r.seed = seed_value
		var depth := global_position.y / World.METER
		var found := []
		var value := r.randi_range(2, 6) + int(depth / 30.0)
		p.add_value(value)
		found.append("$%d of ore" % value)
		var coal := r.randi_range(0, 3)
		for i in coal:
			p.add_ore(World.COAL)
		if coal > 0:
			found.append("%d coal" % coal)
		if r.randf() < 0.4:
			p.ropes += 2
			p.bag_changed.emit()
			found.append("2 ropes")
		Sfx.play("crate_open", global_position)
		get_tree().call_group("hud", "toast", "Found " + ", ".join(found), 1.6)
		queue_redraw()

	func _draw() -> void:
		var t := _open if opened else _closed
		draw_texture(t, Vector2(-t.get_width() / 2.0, -t.get_height()))


## A note left by someone who came down before: read it (E). Adds it to what you've found.
class Note extends Station:
	var note_id := 0
	var puppet := false        # online client: the host's note

	func _ready() -> void:
		super._ready()
		add_to_group("net")

	func net_state() -> Array:
		return [note_id]

	func net_apply(s: Array) -> void:
		note_id = s[0]
	var _tex: Texture2D = Art.lit("res://assets/props/journal.png")
	var _bob := randf() * TAU

	func prompt(_p: Player) -> String:
		return "E: read the note"

	func interact(p: Player) -> void:
		Progress.find_note(note_id)
		get_tree().call_group("run", "note_read", p, note_id)    # (shows it to whoever read it)
		Sfx.play("note_pickup", global_position)
		queue_free()

	func _process(dt: float) -> void:
		_bob += dt
		queue_redraw()

	func _draw() -> void:
		draw_texture(_tex, Vector2(-_tex.get_width() / 2.0, -_tex.get_height()))
		# a faint glint so it can be spotted in the dark (a colour pulse, nothing moves)
		var a := 0.35 + 0.35 * sin(_bob * 3.0)
		draw_rect(Rect2(-1, -_tex.get_height() - 1, 2, 2), Color(1.6, 1.4, 1.0, a))
