extends Button
func _on_pressed() -> void:
	await get_tree().create_timer(1).timeout
	get_tree().quit()#no more game
