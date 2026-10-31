extends Node
## Autoload "Settings": volumes (master / music / effects), fullscreen and the last address
## joined online, saved to user://settings.cfg. Sets up the "Music" and "SFX" audio buses.

const PATH := "user://settings.cfg"

var master := 0.8
var music := 0.6
var effects := 0.9
var fullscreen := false
var last_address := ""


func _ready() -> void:
	for bus in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
			AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		master = cfg.get_value("audio", "master", master)
		music = cfg.get_value("audio", "music", music)
		effects = cfg.get_value("audio", "effects", effects)
		fullscreen = cfg.get_value("video", "fullscreen", fullscreen)
		last_address = cfg.get_value("online", "last_address", last_address)
	apply()


func apply() -> void:
	_volume("Master", master)
	_volume("Music", music)
	_volume("SFX", effects)
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master)
	cfg.set_value("audio", "music", music)
	cfg.set_value("audio", "effects", effects)
	cfg.set_value("video", "fullscreen", fullscreen)
	cfg.set_value("online", "last_address", last_address)
	cfg.save(PATH)


func _volume(bus: String, v: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i >= 0:
		AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v, 0.0001)))
		AudioServer.set_bus_mute(i, v <= 0.001)
