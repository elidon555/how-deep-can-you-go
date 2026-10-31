extends Node
class_name DrillGuns
## The hull turrets and whoever mans them from the gunner's seat: the mouse picks the side and
## aims, click fires, E / Esc gets up.

signal gunner_changed(player: Player)    # sat down / got up (null)
signal bolt_hit(pos: Vector2, on_rock: bool)

var drill: Drill
var gunner: Player = null
var turrets: Array[Turret] = []
var _seated_at := 0            # msec; the key that sat you down mustn't also stand you up


## Mounts a harpoon turret on each side of the hull, just above the doors (below the braces).
func mount() -> void:
	for side in [-1, 1]:
		var t := Turret.new()
		t.side = side
		t.world = drill.world
		t.position = Vector2(side * (Drill.HW + 6.0), -20.0)
		t.bolt_hit.connect(bolt_hit.emit)
		drill.add_child(t)
		turrets.append(t)


func take(p: Player) -> void:
	gunner = p
	_seated_at = Time.get_ticks_msec()
	p.frozen = true
	Sfx.play("lever", drill.global_position, -6.0)
	gunner_changed.emit(p)


func update() -> void:
	if gunner == null:
		return
	var settled := Time.get_ticks_msec() - _seated_at > 250
	if (settled and gunner.wants_leave()) or gunner.health <= 0:
		gunner.frozen = false
		gunner = null
		gunner_changed.emit(null)
		return
	var aim := gunner.aim_point()
	var t: Turret = turrets[1] if aim.x >= drill.global_position.x else turrets[0]
	t.aim_at(aim)
	if gunner.wants_fire() and drill.power.powered("guns"):
		t.fire(drill.power.ratio() * Roles.reload_mult(gunner.role))
