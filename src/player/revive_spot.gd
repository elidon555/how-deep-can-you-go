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
	if downed.carried_by:
		return ""
	return "Hold E: help %s up · tap E: carry" % downed.tag_name()


func interact(p: Player) -> void:
	downed.revive(p)


## A quick tap (not a hold): hoist them onto your shoulders instead.
func tap(p: Player) -> void:
	p.carry(downed)


func hold_time() -> float:
	return HOLD


## Before breaches: a crewmate bleeding out comes first.
func priority() -> int:
	return 2
