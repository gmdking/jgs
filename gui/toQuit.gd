extends Button  #or control

#camera it moves
@export var camera: Camera2D

#target
@export var target_position := Vector2(0, 5000) 

func _ready():
	connect("pressed", Callable(self, "_on_button_pressed"))


func _on_button_pressed():
	if camera:
		camera.global_position = target_position
