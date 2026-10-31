class_name Roles
## Crew roles, picked before a run (title screen / Play online; Settings.role). Each has a perk:
##   miner     digs 30% harder and carries 10 more ore
##   engineer  repairs breaches, fuses and fires twice as fast
##   gunner    the turrets reload much faster while they're on them
##   medic     helps the downed up quickly (and with 2 hearts); the medkit recharges faster

const ALL := ["miner", "engineer", "gunner", "medic"]
const NAMES := {"miner": "Miner", "engineer": "Engineer", "gunner": "Gunner", "medic": "Medic"}
const PERKS := {
	"miner": "Digs harder, carries more ore",
	"engineer": "Repairs twice as fast",
	"gunner": "Turrets reload faster",
	"medic": "Helps the downed up fast",
}


static func next(role: String) -> String:
	return ALL[(ALL.find(role) + 1) % ALL.size()]


static func pick_mult(role: String) -> float:
	return 1.3 if role == "miner" else 1.0


static func bag_bonus(role: String) -> int:
	return 10 if role == "miner" else 0


## How much faster this role does a hold-E job on `target` (1 = normal).
static func work_rate(role: String, target: Node) -> float:
	if role == "engineer" and (target is Stations.Breach or target is Junction or target is DrillFires.Flame):
		return 2.0
	if role == "medic" and target is ReviveSpot:
		return 2.5
	return 1.0


static func reload_mult(role: String) -> float:
	return 1.7 if role == "gunner" else 1.0


static func revive_health(role: String) -> int:
	return 2 if role == "medic" else 1
