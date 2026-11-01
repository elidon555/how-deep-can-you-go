extends CanvasLayer
class_name Menus
## The menu screens over the game: title, pause (Esc), settings, online co-op, the run summary
## and reading notes. It tells the game when to start a run, host one, or restart (to the title
## or straight back in).

signal start_run
signal restart(to_title: bool)
signal daily
signal host(port: int)
signal save_and_quit
signal continue_run

var title := TitleMenu.new()
var pause := PauseMenu.new()
var settings := SettingsMenu.new()
var game_over := GameOver.new()
var note_view := NoteView.new()
var online := OnlineMenu.new()
var hangar := HangarMenu.new()
var can_pause := func() -> bool: return true    # the game says when Esc may pause


func _ready() -> void:
	layer = 20
	for m in [title, pause, settings, game_over, note_view, online, hangar]:
		add_child(m)
	title.visible = false
	title.start_pressed.connect(func():
		title.visible = false
		Sfx.music("")
		start_run.emit())
	title.daily_pressed.connect(func(): daily.emit())
	title.online_pressed.connect(online.open)
	title.hangar_pressed.connect(hangar.open)
	title.continue_pressed.connect(func(): continue_run.emit())
	pause.save_pressed.connect(func(): save_and_quit.emit())
	online.host_pressed.connect(func(port): host.emit(port))
	title.settings_pressed.connect(settings.open)
	pause.settings_pressed.connect(settings.open)
	pause.restart_pressed.connect(func(): restart.emit(false))
	pause.title_pressed.connect(func(): restart.emit(true))
	game_over.again_pressed.connect(func(): restart.emit(false))
	game_over.title_pressed.connect(func(): restart.emit(true))


func show_title(notice := "") -> void:
	title.set_notice(notice)
	title.visible = true
	Sfx.music("music_title")


func on_title() -> bool:
	return title.visible


func show_run(stats: Dictionary) -> void:
	game_over.show_run(stats)


func _unhandled_input(event: InputEvent) -> void:
	# Esc pauses, unless something else used it first (shop, sonar, the turret seat) or a menu
	# is already up
	if Controls.any_pressed(event, "ui_cancel") and not title.visible and not pause.visible \
			and not note_view.visible and not game_over.visible and not online.visible and not hangar.visible \
			and can_pause.call():
		pause.open()
		get_viewport().set_input_as_handled()
