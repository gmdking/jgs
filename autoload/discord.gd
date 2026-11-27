extends Node

var presence := DiscordRichPresence.new()
var _last_scene: Node = null
var _start_time: int = int(Time.get_unix_time_from_system())
var _enabled := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	presence.app_id = "1574351339549364285"

	presence.presence_connected.connect(func(u): print("Discord connected: ", u.get("username", "")))
	presence.presence_disconnected.connect(func(): print("Discord disconnected"))

	var settings := get_node_or_null("/root/Settings")
	if settings != null:
		_apply_enabled(bool(settings.get_value("discord_rich_presence", true)))
		settings.changed.connect(_on_settings_changed)
	else:
		_apply_enabled(true)


func _on_settings_changed(key: String, value: Variant) -> void:
	if key == "discord_rich_presence":
		_apply_enabled(bool(value))


func _apply_enabled(enabled: bool) -> void:
	_enabled = enabled
	var tree := get_tree()

	if enabled:
		if not presence.is_inside_tree():
			add_child(presence)  # addon _ready() calls connect_now()
		if not tree.tree_changed.is_connected(_check_scene):
			tree.tree_changed.connect(_check_scene, CONNECT_DEFERRED)
		_last_scene = null  # important: force a fresh activity update
		_check_scene.call_deferred()
	else:
		if tree.tree_changed.is_connected(_check_scene):
			tree.tree_changed.disconnect(_check_scene)
		_last_scene = null
		if presence.is_inside_tree():
			presence.clear_activity()          # queues SET_ACTIVITY null
			await get_tree().process_frame     # let one _process() send it
			if not _enabled:
				remove_child(presence)         # addon _exit_tree() drops IPC

func _exit_tree() -> void:
	var tree := get_tree()
	if tree and tree.tree_changed.is_connected(_check_scene):
		tree.tree_changed.disconnect(_check_scene)


func _check_scene() -> void:
	if not is_inside_tree():
		return
	var scene := get_tree().current_scene
	if scene == null or scene == _last_scene:
		return
	_last_scene = scene

	var state: String = scene.name
	if state.is_empty():
		state = "Playing"  # Discord rejects empty strings
	print("DRP scene: ", scene.name)
	presence.set_activity({
		"details": "Jolt Physics Godot Sandbox",
		"state": state,
		"timestamps": {"start": _start_time},
	})
