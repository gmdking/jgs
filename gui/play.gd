extends Button #extends the button class
@onready var hover_sound = $Hover
@onready var click_sound = $Click
func _on_pressed() -> void: # on press change scene to main
	click_sound.play()
	await get_tree().create_timer(0.3).timeout
	get_tree().change_scene_to_file("res://gui/fb.tscn")

func _ready():
	focus_entered.connect(_on_focus_entered) # controller/keyboard hover

func _on_mouse_entered():
	hover_sound.play()

func _on_focus_entered():
	hover_sound.play() # makes controller navigation also play hover sound
