extends Node

var presence := DiscordRichPresence.new()
var _last_scene: Node = null
var _start_time: int = int(Time.get_unix_time_from_system())

func _ready() -> void:
	presence.app_id = "1574351339549364285"
	add_child(presence)
	get_tree().tree_changed.connect(_check_scene)
	_check_scene()

func _check_scene() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene == null or scene == _last_scene:
		return
	_last_scene = scene
	presence.set_activity({
		"details": "Jolt Physics Godot Sandbox",
		"state": scene.name,
		"timestamps": {"start": _start_time},
	})
