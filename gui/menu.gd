extends Button

func _on_pressed(): #on press change scene to main menu
	get_tree().change_scene_to_file("res://gui/menu.tscn")
