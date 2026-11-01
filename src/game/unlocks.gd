class_name Unlocks
## What you earn across runs (picked in the Hangar on the title screen; Settings.drill / helmet):
## drill variants with their own trade-offs, tinted hulls, and helmet colours. Each is unlocked
## by something you've done (Progress); nothing is bought.

## id -> name, what it does, how to unlock it, hull tint, and its stats (multipliers)
const DRILLS := {
	"rustbucket": {"name": "Rustbucket", "desc": "The old faithful", "how": "", "tint": Color(1, 1, 1),
		"power": 1.0, "hull": 1.0, "heat": 1.0},
	"mole": {"name": "Mole", "desc": "Bores 30% faster, 20% less hull", "how": "Reach 200 m", "tint": Color(1.0, 0.86, 0.7),
		"power": 1.3, "hull": 0.8, "heat": 1.0},
	"tortoise": {"name": "Tortoise", "desc": "60% more hull, bores 20% slower", "how": "Kill the Broodmother",
		"tint": Color(0.8, 0.95, 0.8), "power": 0.8, "hull": 1.6, "heat": 1.0},
	"ember": {"name": "Ember", "desc": "Runs 40% cooler", "how": "Reach 450 m", "tint": Color(1.15, 0.8, 0.75),
		"power": 1.0, "hull": 1.0, "heat": 0.6},
	"pathfinder": {"name": "Pathfinder", "desc": "Faster, tougher, cooler", "how": "Open the Floor",
		"tint": Color(0.85, 0.85, 1.15), "power": 1.15, "hull": 1.2, "heat": 0.8},
}
## id -> name, how to unlock it, helmet hue (-1 = the helmet's own yellow)
const HELMETS := {
	"brass": {"name": "Brass", "how": "", "hue": -1.0},
	"copper": {"name": "Copper", "how": "Sell $150 of ore (all runs)", "hue": 0.04},
	"crystal": {"name": "Crystal", "how": "Reach 150 m", "hue": 0.78},
	"frost": {"name": "Frost", "how": "Reach 300 m", "hue": 0.52},
	"brood": {"name": "Brood", "how": "Kill the Broodmother", "hue": 0.3},
	"void": {"name": "Void", "how": "Open the Floor", "hue": 0.7},
}


static func unlocked(id: String) -> bool:
	match id:
		"rustbucket", "brass":
			return true
		"mole":
			return Progress.best >= 200
		"ember":
			return Progress.best >= 450
		"tortoise", "brood":
			return Progress.brood_killed
		"pathfinder", "void":
			return Progress.beaten
		"copper":
			return Progress.lifetime_sold >= 150
		"crystal":
			return Progress.best >= 150
		"frost":
			return Progress.best >= 300
	return false


static func drill(id: String) -> Dictionary:
	return DRILLS.get(id, DRILLS.rustbucket)


static func helmet_hue(id: String) -> float:
	return HELMETS.get(id, HELMETS.brass).hue


## Things newly earned since last asked (and remembers them), for a toast.
static func fresh() -> Array:
	var out := []
	for id in DRILLS.keys() + HELMETS.keys():
		var how: String = DRILLS[id].how if DRILLS.has(id) else HELMETS[id].how
		if how != "" and unlocked(id) and not Progress.unlocks_seen.has(id):     # (not the ones you start with)
			Progress.unlocks_seen.append(id)
			out.append(DRILLS[id].name + " drill" if DRILLS.has(id) else HELMETS[id].name + " helmet")
	if not out.is_empty():
		Progress.save()
	return out
