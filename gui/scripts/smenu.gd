extends CanvasLayer

# The pause menu has to keep processing (input, buttons, music) while the rest
# of the SceneTree is paused, so it runs in PROCESS_MODE_ALWAYS.

var resume_button: Button
var settings_button: Button
var menu_button: Button

@onready var panel: PanelContainer = $PanelContainer
@onready var menu_music: AudioStreamPlayer = $AudioStreamPlayer
@onready var settings_ui: Variant = get_node("/root/SettingsUI")
@onready var ui_sounds: Variant = get_node("/root/UISounds")

var settings_open := false

func _ready() -> void:
	# The menu is an overlay: it starts hidden and only appears while paused.
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	_resolve_buttons()
	if menu_music.stream is AudioStreamOggVorbis:
		menu_music.stream.loop = true
	menu_music.stop()

	# Make sure a previous pause can't leave the game frozen.
	get_tree().paused = false

	for button in [resume_button, settings_button, menu_button]:
		if button == null:
			continue
		button.focus_mode = Control.FOCUS_ALL
		button.focus_entered.connect(_on_button_focused)
		button.mouse_entered.connect(_on_button_focused)
	settings_ui.closed.connect(_on_settings_closed)
	# Music volume is handled by the Music bus (see Settings.apply_audio()), so
	# the player only supplies the mix level and the bus does the scaling.
	_center_panel()
	get_viewport().size_changed.connect(_center_panel)

# Resolve buttons by name first, then by their text, so renaming nodes in the
# scene does not leave the script holding null references.
func _resolve_buttons() -> void:
	var container := $PanelContainer/VBoxContainer
	resume_button = _find_button(container, "Resume", "Resume")
	settings_button = _find_button(container, "SettingsButton", "Settings")
	menu_button = _find_button(container, "MainMenu", "Main Menu")


func _find_button(container: Node, node_name: String, button_text: String) -> Button:
	var found := container.get_node_or_null(NodePath(node_name))
	if found is Button:
		return found
	for child in container.get_children():
		if child is Button and (child as Button).text.strip_edges() == button_text:
			return child
	push_warning("Smenu: missing button '%s' / '%s'" % [node_name, button_text])
	return null


func _input(event: InputEvent) -> void:
	# While settings are open, Esc belongs to the settings screen, not pause.
	if get_viewport().is_input_handled() or settings_open or settings_ui.visible:
		return
	if event.is_action_pressed("pause"):
		toggle_pause()
		get_viewport().set_input_as_handled()

func toggle_pause() -> void:
	if get_tree().paused:
		resume()
	else:
		pause()

func _center_panel() -> void:
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -430.0
	panel.offset_top = -192.5
	panel.offset_right = 430.0
	panel.offset_bottom = 192.5

func pause() -> void:
	get_tree().paused = true
	visible = true
	_center_panel()
	panel.visible = true
	menu_music.play()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# Let controller players navigate the menu without touching the mouse.
	if resume_button != null:
		resume_button.grab_focus()

func resume() -> void:
	get_tree().paused = false
	settings_open = false
	visible = false
	panel.visible = true
	settings_ui.hide_settings()
	menu_music.stop()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if resume_button != null:
		resume_button.release_focus()

func _show_settings() -> void:
	settings_open = true
	panel.visible = false
	settings_ui.show_settings()

func _on_settings_closed() -> void:
	settings_open = false
	panel.visible = true
	if resume_button != null:
		resume_button.grab_focus()
	ui_sounds.play_click()

func _on_button_focused() -> void:
	ui_sounds.play_hover()

func _on_button_pressed() -> void:
	ui_sounds.play_click()
	resume()

func _on_settings_button_pressed() -> void:
	ui_sounds.play_click()
	_show_settings()

func _on_button_2_pressed() -> void:
	ui_sounds.play_click()
	# Unpause before leaving, otherwise the main menu would load frozen.
	menu_music.stop()
	settings_ui.hide_settings()
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file("res://gui/menu.tscn")
