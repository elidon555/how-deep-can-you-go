extends Node2D
class_name Station
## Something on the drill a player can use (group "interactable"). Stations only call the
## Drill's methods, never keep state of their own that matters, so co-op can sync the drill.
## Override prompt / interact (and hold_time for things you hold E for).

var drill: Drill


func _ready() -> void:
	add_to_group("interactable")


## What the prompt says for this player ("" = nothing to do here right now).
func prompt(_p: Player) -> String:
	return ""


func interact(_p: Player) -> void:
	pass


## Seconds to hold E (0 = a single press).
func hold_time() -> float:
	return 0.0
