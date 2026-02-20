extends Button #extends the button class

func _on_pressed() -> void: # on press change scene to main
	get_tree().change_scene_to_file("res://main.tscn")
