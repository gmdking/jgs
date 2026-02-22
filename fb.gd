extends Control

@onready var file_list: ItemList = $Camera2D/Panel/VBoxContainer/FileList
@onready var back_button: Button = $Camera2D/Panel/VBoxContainer/BackButton

const ROOT_PATH := "res://maps/"
var current_path := ROOT_PATH


func _ready():
	file_list.item_activated.connect(_on_item_activated)
	back_button.pressed.connect(_on_back_pressed)
	load_directory(current_path)


func load_directory(path: String):
	current_path = path
	file_list.clear()

	print("Opening directory:", path)

	var dir := DirAccess.open(path)

	if dir == null:
		print("FAILED to open directory")
		return

	dir.list_dir_begin()

	var name := dir.get_next()

	if name == "":
		print("Directory is empty or inaccessible")

	while name != "":
		print("Found:", name, " | is_dir:", dir.current_is_dir())

		if name != "." and name != "..":
			if dir.current_is_dir():
				file_list.add_item("📁 " + name)
			elif name.ends_with(".tscn"):
				file_list.add_item("📄 " + name.get_basename())

		name = dir.get_next()

	dir.list_dir_end()

func _on_item_activated(index: int):
	var text := file_list.get_item_text(index)

	if text.begins_with("📁 "):
		var folder_name := text.substr(2)
		load_directory(current_path + folder_name + "/")

	elif text.begins_with("📄 "):
		var file_name := text.substr(2) + ".tscn"
		var full_path := current_path + file_name

		print("Loading: ", full_path)
		get_tree().change_scene_to_file(full_path)


func _on_back_pressed():
	if current_path == ROOT_PATH:
		return

	var trimmed := current_path.rstrip("/")
	var slash := trimmed.rfind("/")

	if slash >= ROOT_PATH.length():
		current_path = trimmed.substr(0, slash + 1)
	else:
		current_path = ROOT_PATH

	load_directory(current_path)


func update_back_button():
	back_button.disabled = current_path == ROOT_PATH
