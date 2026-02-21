extends Button  # or Control if attached to parent

# Reference to the Camera2D
@export var camera: Camera2D

# Target coordinates
@export var target_position := Vector2(0, 5000) 

func _ready():
	connect("pressed", Callable(self, "_on_button_pressed"))


func _on_button_pressed():
	if camera:
		camera.global_position = target_position
