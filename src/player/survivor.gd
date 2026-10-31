extends Player
class_name Survivor
## A miner from an earlier crew, trapped down here (a rescue contract, Contracts). Too weak to
## walk: someone taps E to hoist them onto their shoulders (like a downed crewmate) and carries
## them into the drill. Not part of the crew: no controls, no bag, not counted in main.players.

func _ready() -> void:
	super._ready()
	add_to_group("survivor")
	display_name = "Survivor"
	number = 0
	update_crew_look()
	health = 0
	_go_down()
	bleed = INF                    # they've held on this long


func crew_color() -> Color:
	return Color("8f8a78")       # faded, dusty work clothes


func tag_name() -> String:
	return "the survivor"


## Too weak to stand: only carrying works.
func revive(_by: Player = null) -> void:
	pass


func show_tag(_on: bool) -> void:
	_tag.visible = visible
