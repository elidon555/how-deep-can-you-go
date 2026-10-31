extends Node
## Autoload "Sfx": plays the generated sounds in assets/sfx (tools/gen_sfx.py).
## Sfx.play("hit_stone", pos) picks a random variant (hit_stone_v1, _v2 ...) and varies pitch.
## Also runs the cave ambience (crossfades with depth), random water drips, and the music
## (title theme, deep-layer theme). Effects go to the "SFX" bus, music to "Music" (Settings).

const DIR := "res://assets/sfx/"
const POOL := 16

var _variants := {}      # name -> Array[AudioStream] (empty if the sound doesn't exist)
var _players: Array[AudioStreamPlayer2D] = []
var _next := 0
var _ui := AudioStreamPlayer.new()
var _amb := [AudioStreamPlayer.new(), AudioStreamPlayer.new()]   # cave, deep
var _music := AudioStreamPlayer.new()
var _music_name := ""
var _drip_t := 3.0
var listener: Node2D      # usually the player; drips play around it
var from_host := false    # online client: set while playing a sound the host sent (NetSession)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in POOL:
		var p := AudioStreamPlayer2D.new()
		p.max_distance = 900.0
		p.attenuation = 1.4
		p.bus = "SFX"
		add_child(p)
		_players.append(p)
	_ui.bus = "SFX"
	add_child(_ui)
	_music.bus = "Music"
	add_child(_music)
	for i in 2:
		_amb[i].stream = looping(["amb_cave", "amb_deep"][i])
		_amb[i].volume_db = -80.0
		_amb[i].bus = "SFX"
		add_child(_amb[i])


## A sound set up to loop seamlessly (for engines, ambience), or null if it doesn't exist.
func looping(name: String) -> AudioStream:
	var s := _stream(name)
	if s is AudioStreamWAV:
		s = s.duplicate()
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = s.data.size() / 2   # 16-bit mono
	return s


## Positional sound. pos = Vector2.INF plays it flat (UI / always audible).
## Online the host's game sounds play on every client (Net.echo), and a client only plays the
## ones the host sends (plus its own menu "ui_" sounds), so nothing is heard twice.
func play(name: String, pos := Vector2.INF, volume_db := 0.0, pitch_var := 0.08) -> void:
	if not name.begins_with("ui_"):
		if Net.is_client() and not from_host:
			return
		Net.echo(&"sfx", &"play", [name, pos, volume_db, pitch_var])
	_play_here(name, pos, volume_db, pitch_var)


func _play_here(name: String, pos: Vector2, volume_db: float, pitch_var: float) -> void:
	var list := _list(name)
	if list.is_empty():
		return
	var stream: AudioStream = list[randi() % list.size()]
	var pitch := 1.0 + randf_range(-pitch_var, pitch_var)
	if pos == Vector2.INF:
		_ui.stream = stream
		_ui.volume_db = volume_db
		_ui.pitch_scale = pitch
		_ui.play()
		return
	var p := _players[_next]
	_next = (_next + 1) % POOL
	p.stream = stream
	p.global_position = pos
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


## Plays a looping music track ("" = none), crossfading from whatever was on.
func music(name: String) -> void:
	if name == _music_name:
		return
	_music_name = name
	var tw := create_tween()
	if _music.playing:
		tw.tween_property(_music, "volume_db", -40.0, 1.5)
	tw.tween_callback(func():
		_music.stream = looping(name) if name != "" else null
		if _music.stream:
			_music.volume_db = -40.0
			_music.play()
			create_tween().tween_property(_music, "volume_db", 0.0, 2.5)
		else:
			_music.stop())


## Ambience mix for a depth in meters: silent at the surface, cave drone, deep drone past ~150 m.
func set_depth(depth_m: float) -> void:
	var under := clampf((depth_m - 2.0) / 10.0, 0.0, 1.0)
	var deep := clampf((depth_m - 120.0) / 80.0, 0.0, 1.0)
	_mix(_amb[0], under * (1.0 - deep))
	_mix(_amb[1], under * deep)


func _process(dt: float) -> void:
	if listener == null or not is_instance_valid(listener) or listener.global_position.y < 60.0:
		return
	_drip_t -= dt
	if _drip_t <= 0.0:
		_drip_t = randf_range(2.5, 7.0)
		_play_here("drip", listener.global_position + Vector2(randf_range(-300, 300), randf_range(-200, 120)), -6.0, 0.15)


func _mix(p: AudioStreamPlayer, w: float) -> void:
	if p.stream == null:
		return
	p.volume_db = linear_to_db(maxf(w, 0.0001)) - 4.0
	if w > 0.001 and not p.playing:
		p.play()
	elif w <= 0.001 and p.playing:
		p.stop()


func _list(name: String) -> Array:
	if not _variants.has(name):
		var found := []
		var s := _stream(name)
		if s:
			found.append(s)
		var v := 1
		while true:
			s = _stream("%s_v%d" % [name, v])
			if s == null:
				break
			found.append(s)
			v += 1
		_variants[name] = found
	return _variants[name]


func _stream(name: String) -> AudioStream:
	var path := DIR + name + ".wav"
	return load(path) if ResourceLoader.exists(path) else null
