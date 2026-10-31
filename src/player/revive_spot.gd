extends Node2D
class_name ReviveSpot
## On a downed miner: crewmates hold E on them to help them back up (group "interactable",
## used through each player's Interactor like a station). Child of the Player it's for.

const HOLD := 2.0

var downed: Player


func _ready() -> void:
	add_to_group("interactable")


func prompt(p: Player) -> String:
	if p == downed or not downed.downed or p.downed:
		return ""
	return "Hold E: help %s up" % downed.tag_name()


func interact(_p: Player) -> void:
	downed.revive()


func hold_time() -> float:
	return HOLD


## Before breaches: a crewmate bleeding out comes first.
func priority() -> int:
	return 2
