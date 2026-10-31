extends Node
class_name Interactor
## Lets its player use things nearby (group "interactable", see Station): finds the closest one,
## shows its prompt, E to use, or hold E for things that take time (repairs).
## One per player, so it works the same in co-op.

signal prompt_changed(text: String)

const REACH := 40.0

var player: Player
var target: Node2D = null
var _hold := 0.0
var _prompt := ""
var _was_frozen := false


func _physics_process(dt: float) -> void:
	# a key that just closed a menu must not also re-open something
	var blocked := player.frozen or _was_frozen or player.health <= 0
	_was_frozen = player.frozen
	if blocked:
		_set_prompt("")
		return
	target = _nearest()
	if target == null:
		_hold = 0.0
		_set_prompt("")
		return
	var text: String = target.prompt(player)
	var need: float = target.hold_time()
	if need > 0.0:
		_hold = _hold + dt if Input.is_action_pressed("interact") else 0.0
		if _hold > 0.0:
			text += "  " + "▮".repeat(int(_hold / need * 10.0)) + "▯".repeat(10 - int(_hold / need * 10.0))
		if _hold >= need:
			_hold = 0.0
			target.interact(player)
	elif Input.is_action_just_pressed("interact"):
		target.interact(player)
	_set_prompt(text)


func _nearest() -> Node2D:
	var best: Node2D = null
	var best_score := INF
	for n: Node2D in get_tree().get_nodes_in_group("interactable"):
		var d := n.global_position.distance_to(player.global_position)
		var score: float = d - n.priority() * 100.0       # urgent things first, then the closest
		if d < REACH and score < best_score and n.prompt(player) != "":
			best = n
			best_score = score
	return best


func _set_prompt(text: String) -> void:
	if text != _prompt:
		_prompt = text
		prompt_changed.emit(text)
