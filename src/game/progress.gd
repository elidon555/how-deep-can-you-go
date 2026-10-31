extends Node
## Autoload "Progress": what carries over between runs (money, upgrades, best depth).
## Saved to user://progress.json. Ore you carry only counts once it's sold at the drill.

signal changed

const SAVE_PATH := "user://progress.json"
const OLD_BEST_PATH := "user://best.txt"
const UPGRADES := {
	"head": {"name": "Drill head", "desc": "Drill bores faster", "costs": [20, 60, 150, 350]},
	"plating": {"name": "Hull plating", "desc": "+25 drill hull", "costs": [25, 70, 180]},
	"tank": {"name": "Fuel tank", "desc": "+40 fuel capacity", "costs": [15, 45, 120]},
	"pick": {"name": "Sharper pickaxe", "desc": "Breaks rock faster", "costs": [15, 40, 90, 200, 450]},
	"arms": {"name": "Strong arms", "desc": "Swing faster", "costs": [25, 70, 160]},
	"lamp": {"name": "Brighter lamp", "desc": "See further in the dark", "costs": [10, 30, 80]},
	"coat": {"name": "Thick coat", "desc": "+1 health", "costs": [30, 90, 220]},
	"sled": {"name": "Ore sled", "desc": "Drag a sled: +15 ore carried", "costs": [40, 110]},
	# modules: built onto the drill once (DrillModules)
	"cargo": {"name": "Cargo hold", "desc": "Keeps the ore the drill grinds through", "costs": [80], "module": true},
	"floodlights": {"name": "Floodlights", "desc": "Light up the shaft around the drill", "costs": [40], "module": true},
	"sprinklers": {"name": "Sprinklers", "desc": "Douse fires in the cabin", "costs": [60], "module": true},
	"drone": {"name": "Defence drone", "desc": "Zaps creatures near the drill", "costs": [120], "module": true},
	"bunk": {"name": "Crew bunk", "desc": "Bled-out crew are back sooner", "costs": [50], "module": true},
}

var money := 0
var best := 0
var levels := {}   # upgrade id -> level bought
var found_notes: Array = []   # Lore.NOTES ids you've read, ever
var beaten := false           # the Floor has been opened at least once
var daily := {}               # date ("2026-10-31") -> best depth on that day's Daily Dig
var tips_seen: Array = []     # first-run hints already shown (Tips)
var dry_run := false   # tests: keep everything in memory
var mirroring := false # online client: money and upgrades are the host's (the crew's), not saved


func _ready() -> void:
	_load()


func level(id: String) -> int:
	return levels.get(id, 0)


## Price of the next level, or -1 when maxed out.
func cost(id: String) -> int:
	var costs: Array = UPGRADES[id].costs
	return costs[level(id)] if level(id) < costs.size() else -1


func buy(id: String) -> bool:
	var c := cost(id)
	if c < 0 or not can_afford(c):
		return false
	if not GameConfig.infinite_resources():
		money -= c
	levels[id] = level(id) + 1
	save()
	return true


func can_afford(price: int) -> bool:
	return GameConfig.infinite_resources() or money >= price


## The Daily Dig: the same world for everyone today.
static func today() -> String:
	return Time.get_date_string_from_system()


static func daily_seed() -> int:
	return hash("how-deep-daily-" + today()) & 0x7fffffff


func record_daily(depth: int) -> void:
	if depth > daily.get(today(), 0):
		daily[today()] = depth
		save()


func see_tip(id: String) -> void:
	if not tips_seen.has(id):
		tips_seen.append(id)
		save()


func beat_the_game() -> void:
	beaten = true
	save()


func find_note(id: int) -> void:
	if not found_notes.has(id):
		found_notes.append(id)
		save()


func add_money(amount: int) -> void:
	money += amount
	save()


func record_depth(depth: int) -> bool:
	if depth <= best:
		return false
	best = depth
	return true


# ---------------------------------------------------------------- what upgrades do

func drill_power() -> float:
	return 5.0 * pow(1.3, level("head"))


func drill_hull() -> float:
	return 100.0 + 25.0 * level("plating")


func drill_fuel() -> float:
	return 100.0 + 40.0 * level("tank")


func pick_power() -> float:
	return 3.0 * pow(1.35, level("pick"))


func swing_speed() -> float:
	return 1.0 + 0.15 * level("arms")


func lamp_scale() -> float:
	return 1.0 + 0.25 * level("lamp")


func max_health() -> int:
	return 3 + level("coat")


func bag_bonus() -> int:
	return 15 * level("sled")


# ---------------------------------------------------------------- online co-op

## Host: the crew's money and upgrades, for clients to mirror.
func mirror_state() -> Dictionary:
	return {"money": money, "levels": levels}


## Client: show the host's money and upgrades (until end_mirror; never saved here).
func mirror(state: Variant) -> void:
	if not (state is Dictionary):
		return
	mirroring = true
	money = int(state.get("money", 0))
	levels.clear()
	for k in state.get("levels", {}):
		levels[k] = int(state.levels[k])
	changed.emit()


## Left the host's game: back to this machine's own save.
func end_mirror() -> void:
	if not mirroring:
		return
	mirroring = false
	money = 0
	levels.clear()
	found_notes.clear()
	tips_seen.clear()
	daily.clear()
	_load()
	changed.emit()


# ---------------------------------------------------------------- saving

func save() -> void:
	if dry_run or mirroring or GameConfig.infinite_resources():   # free stuff doesn't stick to the real save
		changed.emit()
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"money": money, "best": best, "levels": levels, "notes": found_notes,
			"beaten": beaten, "daily": daily, "tips": tips_seen}))
	changed.emit()


func _load() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var d = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
		if d is Dictionary:
			money = int(d.get("money", 0))
			best = int(d.get("best", 0))
			for k in d.get("levels", {}):
				levels[k] = int(d.levels[k])
			for n in d.get("notes", []):
				found_notes.append(int(n))
			beaten = bool(d.get("beaten", false))
			for t in d.get("tips", []):
				tips_seen.append(str(t))
			for k in d.get("daily", {}):
				daily[k] = int(d.daily[k])
	elif FileAccess.file_exists(OLD_BEST_PATH):
		best = int(FileAccess.get_file_as_string(OLD_BEST_PATH))
