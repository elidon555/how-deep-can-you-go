extends Node
class_name Contracts
## Jobs radioed down from the surface every so often (at most MAX at a time), each with a
## deadline depth: when the drill passes it, the job is lost.
##   sell     sell this much ore at the workbench (counted from when the job came in)
##   hunt     kill this many creatures
##   rescue   a miner from an earlier crew is trapped in a cave below: carry them into the drill
## Done jobs pay into the crew's money. Host-only (clients see the list through Hud.set_contracts).

signal changed

const MAX := 2
const FIRST_AFTER := 40.0          # seconds into a run
const EVERY := Vector2(90.0, 160.0)
const RESCUE_FROM := 30.0          # m: rescues only once there are caves worth getting lost in

var main                           # the run (src/main.gd)
var jobs: Array[Dictionary] = []   # {kind, text, goal, base, reward, until}
var _t := FIRST_AFTER


func _process(dt: float) -> void:
	if main.run_over or main.menus.on_title():
		return
	_t -= dt
	if _t <= 0.0:
		_t = randf_range(EVERY.x, EVERY.y)
		if jobs.size() < MAX:
			_offer()
	var depth: float = main.drill.global_position.y / World.METER
	for j in jobs.duplicate():
		if _progress(j) >= j.goal:
			_finish(j, true)
		elif depth > j.until:
			_finish(j, false)
		elif j.kind == "rescue" and not is_instance_valid(j.survivor):
			_finish(j, false)
	_show()


## A new job over the radio.
func _offer() -> void:
	var depth: float = main.drill.global_position.y / World.METER
	var kinds := ["sell", "hunt"]
	if depth > RESCUE_FROM:
		kinds.append("rescue")
	var kind: String = kinds.pick_random()
	var j := {"kind": kind, "until": depth + randf_range(60.0, 110.0)}
	match kind:
		"sell":
			j.goal = 20 + int(depth / 4.0) + randi_range(0, 10)
			j.base = _sold()
			j.reward = int(j.goal * 0.6)
			j.text = "Sell $%d of ore" % j.goal
		"hunt":
			j.goal = randi_range(4, 8)
			j.base = main.kills
			j.reward = 6 * j.goal
			j.text = "Kill %d creatures" % j.goal
		"rescue":
			var s := _place_survivor(depth + randf_range(35.0, 70.0))
			if s == null:
				return
			j.goal = 1
			j.base = 0
			j.survivor = s
			j.reward = 40 + int(depth / 5.0)
			j.text = "Rescue the trapped miner (%d m)" % int(s.global_position.y / World.METER)
			main.show_ping(s.global_position, 1, "SOS")
	jobs.append(j)
	Sfx.play("radio", Vector2.INF, -2.0, 0.0)
	main.hud.toast("Radio: %s before %d m — $%d" % [j.text, int(j.until), j.reward], 4.0)
	changed.emit()


func _progress(j: Dictionary) -> int:
	match j.kind:
		"sell":
			return _sold() - j.base
		"hunt":
			return main.kills - j.base
		"rescue":
			var s: Survivor = j.survivor
			return 1 if is_instance_valid(s) and s.carried_by and main.drill.contains(s.global_position) else 0
	return 0


func _sold() -> int:
	var total := 0
	for p in main.players:
		total += p.sold_value
	return total


func _finish(j: Dictionary, done: bool) -> void:
	jobs.erase(j)
	if j.kind == "rescue" and is_instance_valid(j.survivor):
		var s: Survivor = j.survivor
		if s.carried_by:
			s.carried_by.carrying = null
		s.queue_free()                    # (rescued: they rest in the drill; lost: gone)
	if done:
		Progress.add_money(j.reward)
		Sfx.play("contract_done", Vector2.INF, 0.0, 0.0)
		main.hud.toast("Job done: %s. +$%d" % [j.text, j.reward], 3.0)
	else:
		main.hud.toast("Job lost: %s" % j.text, 2.5)
	changed.emit()


## A natural cave floor around `depth_m`, away from the drill's shaft: the survivor lies there.
func _place_survivor(depth_m: float) -> Survivor:
	var w: World = main.world
	w.ensure_generated(depth_m * World.METER + 400.0)
	for i in 80:
		var x := randf_range(60.0, World.WIDTH_PX - 60.0)
		if absf(x - main.drill.global_position.x) < 160.0:
			continue
		var y := depth_m * World.METER + randf_range(-120.0, 120.0)
		if not w.is_air(Vector2(x, y)) or not w.is_air(Vector2(x, y - 30.0)):
			continue
		while w.is_air(Vector2(x, y + 2.0)) and y < depth_m * World.METER + 300.0:
			y += 2.0
		if w.is_air(Vector2(x, y + 2.0)):
			continue
		var s := Survivor.new()
		s.world = w
		s.position = Vector2(x, y - Player.HALF_HEIGHT - 1.0)
		main.add_child(s)
		return s
	return null


func _show() -> void:
	var lines := []
	for j in jobs:
		lines.append("◆ %s  (%d/%d)  by %d m  $%d" % [j.text, mini(_progress(j), j.goal), j.goal, int(j.until), j.reward])
	main.hud.set_contracts(lines)
