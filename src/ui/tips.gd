extends Node
class_name Tips
## First-run hints: the first time a situation comes up, a short tip says what to do (once per
## save; Progress.tips_seen). Checked a few times a second against the game's state.

const ALL := {
	"start": "Walk to the helm (the console on the right) and press E to start the drill.",
	"outside": "The drill keeps going without you. Go out a hatch, dig for ore and coal, climb the ladders back.",
	"dig": "Hold Left click to swing the pick the way you point.",
	"ore": "Sell ore at the workbench (E) inside the drill, and buy upgrades there.",
	"breach": "A breach! Hold E on it to patch it before the hull leaks away.",
	"heat": "The drill is running hot. Vent coolant at the blue tank (E).",
	"flood": "Water is getting in! Patch the breaches; the pump drains the rest.",
	"worm": "Something big is coming. Sit at the gunner's seat (E) and shoot it as it surfaces.",
	"water": "Underwater you run out of air: watch the bubbles.",
	"rope": "Right click hangs a rope above you. Climb it with W.",
}

var main: Node
var _t := 0.0
var _shown_this_run := {}


func _process(dt: float) -> void:
	_t -= dt
	if _t > 0.0 or main.menus.on_title() or main.run_over:
		return
	_t = 0.4
	var d: Drill = main.drill
	var p: Player = main.player
	if d.speed == Drill.Speed.STOP and main.run_time > 3.0:
		_tip("start")
	if d.speed != Drill.Speed.STOP and main.run_time > 20.0:
		_tip("outside")
	if not d.contains(p.global_position):
		_tip("dig")
		if p.global_position.y - d.global_position.y < -60.0 or main.run_time > 90.0:
			_tip("rope")
	if p.ore_count > 0:
		_tip("ore")
	if d.get_breaches().size() > 0:
		_tip("breach")
	if d.thermal.heat > 70.0:
		_tip("heat")
	if d.flooding.leaking > 0:
		_tip("flood")
	if not get_tree().get_nodes_in_group("worm").is_empty():
		_tip("worm")
	if p.in_water and p.breath < Player.BREATH * 0.8:
		_tip("water")


func _tip(id: String) -> void:
	if Progress.tips_seen.has(id) or _shown_this_run.has(id):
		return
	_shown_this_run[id] = true
	Progress.see_tip(id)
	main.hud.toast(ALL[id], 4.0)
