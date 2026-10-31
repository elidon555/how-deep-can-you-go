class_name GameConfig
## Switches for development / playtesting, read from project.godot's [game] section:
##   [game]
##   infinite_resources=true   ; free upgrades, endless ropes and drill fuel, nothing saved


static func infinite_resources() -> bool:
	return ProjectSettings.get_setting("game/infinite_resources", false)
