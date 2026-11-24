extends Node2D

# One place owns main-menu navigation, camera paging, and UI sounds.
# Every button below used to have its own tiny script (several with broken
# signal connections); the root now wires them all up instead.

enum Page { MAIN, SETTINGS, QUIT }

const MAIN_POS := Vector2(0, 0)
const SETTINGS_POS := Vector2(5000, 0)
const QUIT_POS := Vector2(0, 5000)

@onready var camera: Camera2D = $Camera2D
@onready var play_button: Button = $Buttons/Main/Play
@onready var settings_button: Button = get_node("Buttons/Main/Options and help")
@onready var quit_button: Button = $Buttons/Main/Quit
@onready var multiplayer_button: Button = $Buttons/Main/Multiplayer
@onready var back_button: Button = $Buttons/Settings/Back
@onready var no_button: Button = $Buttons/Quit/No
@onready var yes_button: Button = $Buttons/Quit/Yes
@onready var click_sound: AudioStreamPlayer = $Click
@onready var hover_sound: AudioStreamPlayer = $Hover
@onready var settings_ui: Variant = get_node("/root/SettingsUI")
@onready var help_text: Node2D = $Text/Settings
@onready var settings_buttons: Node2D = $Buttons/Settings

var current_page: Page = Page.MAIN
var transitioning := false

const VOICES := 12
var click_voices: Array[AudioStreamPlayer] = []
var hover_voices: Array[AudioStreamPlayer] = []
var click_voice_cursor := 0
var hover_voice_cursor := 0

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	var buttons := [play_button, settings_button, quit_button, multiplayer_button, no_button, yes_button]
	for button in buttons:
		button.focus_mode = Control.FOCUS_ALL
		button.pressed.connect(_on_button_pressed.bind(button))
		button.focus_entered.connect(_on_button_focused)
		button.mouse_entered.connect(_on_button_focused)

	_setup_focus_neighbors()
	_build_voice_pool(click_sound, click_voices)
	_build_voice_pool(hover_sound, hover_voices)
	settings_ui.closed.connect(_return_to_main)
	play_button.grab_focus()

func _build_voice_pool(template: AudioStreamPlayer, pool: Array[AudioStreamPlayer]) -> void:
	template.bus = "SFX"
	template.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	pool.append(template)
	for i in range(1, VOICES):
		var voice := AudioStreamPlayer.new()
		voice.stream = template.stream
		voice.bus = "SFX"
		voice.volume_db = template.volume_db
		voice.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
		add_child(voice)
		pool.append(voice)

# Arrow keys / left stick wrap across each page, and up/down never jump to a
# button on another (off-screen) page.
func _setup_focus_neighbors() -> void:
	play_button.focus_neighbor_left = quit_button.get_path()
	play_button.focus_neighbor_right = settings_button.get_path()
	settings_button.focus_neighbor_left = play_button.get_path()
	settings_button.focus_neighbor_right = multiplayer_button.get_path()
	multiplayer_button.focus_neighbor_left = settings_button.get_path()
	multiplayer_button.focus_neighbor_right = quit_button.get_path()
	quit_button.focus_neighbor_left = multiplayer_button.get_path()
	quit_button.focus_neighbor_right = play_button.get_path()

	no_button.focus_neighbor_left = yes_button.get_path()
	no_button.focus_neighbor_right = yes_button.get_path()
	yes_button.focus_neighbor_left = no_button.get_path()
	yes_button.focus_neighbor_right = no_button.get_path()

	for button in [play_button, settings_button, quit_button, multiplayer_button, no_button, yes_button]:
		button.focus_neighbor_top = button.get_path()
		button.focus_neighbor_bottom = button.get_path()

	back_button.focus_mode = Control.FOCUS_NONE
	help_text.visible = true
	settings_buttons.visible = true

func _unhandled_input(event: InputEvent) -> void:
	# Controller B / Esc acts as "back" from the sub-pages.
	if event.is_action_pressed("ui_cancel") and current_page != Page.MAIN:
		_return_to_main()
		get_viewport().set_input_as_handled()

func _on_button_pressed(button: Button) -> void:
	_play_click()
	if transitioning:
		return

	if button == play_button:
		transitioning = true
		await get_tree().create_timer(0.5).timeout
		get_tree().change_scene_to_file("res://gui/fb.tscn")
	elif button == multiplayer_button:
		transitioning = true
		await get_tree().create_timer(0.5).timeout
		get_tree().change_scene_to_file("res://net/net_menu.tscn")
	elif button == settings_button:
		current_page = Page.SETTINGS
		camera.global_position = SETTINGS_POS
		help_text.visible = false
		settings_buttons.visible = false
		settings_ui.show_settings()
	elif button == quit_button:
		current_page = Page.QUIT
		camera.global_position = QUIT_POS
		no_button.grab_focus()
	elif button == back_button or button == no_button:
		_return_to_main()
	elif button == yes_button:
		transitioning = true
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()

func _return_to_main() -> void:
	current_page = Page.MAIN
	camera.global_position = MAIN_POS
	settings_ui.hide_settings()
	help_text.visible = true
	settings_buttons.visible = true
	play_button.grab_focus()

# Non-positional AudioStreamPlayers keep UI sounds at full volume regardless
# of where the camera moves, so they can never attenuate or pan away.
func _play_click() -> void:
	var voice := _next_voice(click_voices, click_voice_cursor)
	click_voice_cursor = (click_voice_cursor + 1) % click_voices.size()
	voice.play()

func _on_button_focused() -> void:
	var voice := _next_voice(hover_voices, hover_voice_cursor)
	hover_voice_cursor = (hover_voice_cursor + 1) % hover_voices.size()
	voice.play()

# Prefer a voice that has finished; only restart a busy one if all are in use.
func _next_voice(pool: Array[AudioStreamPlayer], cursor: int) -> AudioStreamPlayer:
	for i in pool.size():
		var voice := pool[(cursor + i) % pool.size()]
		if not voice.playing:
			return voice
	return pool[cursor % pool.size()]
