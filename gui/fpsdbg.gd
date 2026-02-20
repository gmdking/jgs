extends Label

func _process(delta):
	Engine.get_frames_per_second()
	text = "FPS: %d" % Engine.get_frames_per_second()
