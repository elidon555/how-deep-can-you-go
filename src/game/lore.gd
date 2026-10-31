class_name Lore
## The miners' notes found in ruined camps: the story of the crews who dug here before you.
## Each run deals them out in a random order (unfound ones first); found ones are remembered
## (Progress.found_notes).

const NOTES := [
	{"title": "Shift roster, Drill No. 4", "text": "Deepline Mining Co. — six crew, forty days of coal, one drill.\nForeman says the seam goes down further than the survey shows.\nForeman says a lot of things."},
	{"title": "Torn page", "text": "Day 9. Found a camp older than ours down here.\nNo company stamp on the crates. The lamps were still warm."},
	{"title": "Letter, never sent", "text": "Mara —\nThe pay is good and the work is honest. The dark is just dark.\nI keep telling myself that.\nTell the boy I'll bring him a crystal."},
	{"title": "Foreman's log", "text": "Lost Pell at 140 metres. Something took the rope from below.\nWe hauled it up. Clean cut. Nothing down there has teeth like that.\nNothing that we know of."},
	{"title": "Scratched into a crate", "text": "IT HEARS THE DRILL"},
	{"title": "Survey note", "text": "The crystal beds sing when you strike them. Not a ring — a note.\nAll of them the same note.\nWho tuned them?"},
	{"title": "Mechanic's scrawl", "text": "Coolant's holding. Hull's holding. Crew's not.\nWick won't sleep. Says he hears breathing through the hull plates.\nI told him that's the pumps. It isn't the pumps."},
	{"title": "Journal, water-stained", "text": "The burrowers don't eat rock. They eat the warmth out of it.\nThey come for the drill because the drill is the warmest thing down here.\nWe're the second warmest."},
	{"title": "Half a map", "text": "Below the magma there's a void the sonar can't fill.\nThe ping goes out and doesn't come back.\nNot an echo. Not an absence of echo. It just doesn't come back."},
	{"title": "Prayer card", "text": "Keep the lamp lit. Keep the drill turning.\nDon't dig toward the knocking."},
	{"title": "Foreman's log, later", "text": "Four of six left. Company radio answers in a voice I don't know.\nIt tells us to keep digging. It knows our names.\nIt knows Pell's name."},
	{"title": "Child's drawing", "text": "A drill, very small. Under it, a very big circle with an eye in it.\nOn the back: 'Daddy's going to see the bottom.'"},
	{"title": "Last entry", "text": "We found the bottom. It isn't the bottom.\nIt's a floor. Something lives on the other side of it.\nIt's been waiting for someone to knock."},
	{"title": "Note pinned with a nail", "text": "If you're reading this you came down in a drill like ours.\nTurn back while the ropes still reach.\n— D."},
	{"title": "Company memo", "text": "Re: Drill No. 4 — crew lost, equipment recoverable.\nAuthorise Drill No. 5. Hire from out of town.\nDo not mention No. 4."},
]

static var _dealt := {}     # notes already placed in this run


static func reset_run() -> void:
	_dealt.clear()


## A note id for a new camp: unfound ones first, never the same one twice in a run.
static func deal(rng: RandomNumberGenerator) -> int:
	var fresh := []
	var seen := []
	for i in NOTES.size():
		if _dealt.has(i):
			continue
		(seen if Progress.found_notes.has(i) else fresh).append(i)
	var pool := fresh if not fresh.is_empty() else seen
	if pool.is_empty():
		return -1
	var id: int = pool[rng.randi() % pool.size()]
	_dealt[id] = true
	return id
