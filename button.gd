extends Button
# to add this on pressed function press on the "Button" in the scene navigator on the left(?) and instead of using inspector, go to signals and use pressed()
func _on_pressed() -> void:
	get_tree().change_scene_to_file("res://node_3d.tscn") #change scene to the file containing the main game, godot UI is just about as that!
