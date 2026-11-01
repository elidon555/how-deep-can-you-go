class_name RunSave
## Saving a run to finish later (pause menu "Save and quit"; title screen "Continue"). Single
## player (and local co-op) only. The world comes back from its seed plus every chunk changed
## since the run began (NetWorld packs them, as for someone joining online); the drill, the
## miner and the run's stats are stored too. Creatures aren't: the caves fill up again. A saved
## run is used once: continuing it clears the save.

const PATH := "user://run.save"
const TEST_PATH := "user://run_test.save"   # tests never touch a real saved run
const VERSION := 1


static func _path() -> String:
	return TEST_PATH if Progress.dry_run else PATH


static func exists() -> bool:
	return FileAccess.file_exists(_path())


## How deep the saved run's drill is (m), for the title screen.
static func depth() -> int:
	var d := read()
	return int(d.get("depth", 0))


static func save(main) -> void:
	var chunks := []
	for key: Vector2i in main.world.touched:
		chunks.append(NetWorld.pack_chunk(main.world, key))
	var p: Player = main.player
	var data := {
		"version": VERSION, "seed": main.world.seed, "daily": main.daily_run,
		"depth": int(main.drill.global_position.y / World.METER),
		"run_time": main.run_time, "kills": main.kills, "notes": main.notes_read,
		"drill_pos": main.drill.global_position, "drill": main.drill.net_state(), "variant": main.drill.variant,
		"player": [p.global_position, p.health, p.max_health, p.ore_count, p.ore_value, p.coal, p.sold_value,
			p.tools.flares, p.tools.dynamite, p.role, p.helmet],
		"chunks": chunks,
	}
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f:
		f.store_var(data)


static func read() -> Dictionary:
	if not FileAccess.file_exists(_path()):
		return {}
	var f := FileAccess.open(_path(), FileAccess.READ)
	var d = f.get_var() if f else null
	return d if d is Dictionary and int(d.get("version", 0)) == VERSION else {}


static func clear() -> void:
	if FileAccess.file_exists(_path()):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path()))


## Puts a saved run back (main calls this once its world, drill and miner exist).
static func restore(main, d: Dictionary) -> void:
	for c: Array in d.chunks:
		NetWorld.apply(main.world, c)
	main.drill.variant = str(d.get("variant", "rustbucket"))
	main.drill.global_position = d.drill_pos
	main.drill.net_apply(d.drill)
	main.drill.apply_upgrades()
	var s: Array = d.player
	var p: Player = main.player
	p.global_position = s[0]
	p.health = s[1]
	p.max_health = s[2]
	p.ore_count = s[3]
	p.ore_value = s[4]
	p.coal = s[5]
	p.sold_value = s[6]
	p.tools.flares = s[7]
	p.tools.dynamite = s[8]
	p.role = s[9]
	p.helmet = s[10]
	p.update_crew_look()
	p.health_changed.emit(p.health, p.max_health)
	p.bag_changed.emit()
	main.run_time = d.run_time
	main.kills = d.kills
	main.notes_read = d.notes
	for m in main.MILESTONES:          # (no "the daylight is gone" again at 300 m)
		if m <= int(d.depth):
			main.shown[m] = true
