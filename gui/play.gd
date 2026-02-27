extends Button #extends the button class
@onready var hover_sound = $Hover
@onready var click_sound = $Click
func _on_pressed() -> void: #on press change scene to main
	click_sound.play()
	await get_tree().create_timer(0.3).timeout
	get_tree().change_scene_to_file("res://gui/fb.tscn")
