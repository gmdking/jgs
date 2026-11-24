extends Node

var presence := DiscordRichPresence.new()
var _last_scene: Node = null
var _start_time: int = int(Time.get_unix_time_from_system())


func _ready() -> void:
	presence.app_id = "1574351339549364285"
	add_child(presence)
	presence.presence_connected.connect(func(u): print("Discord connected: ", u.get("username", "")))
	presence.presence_disconnected.connect(func(): print("Discord disconnected"))
	get_tree().tree_changed.connect(_check_scene, CONNECT_DEFERRED)
	_check_scene.call_deferred()
	
	print("DRP: os=", OS.get_name(), " display=", DisplayServer.get_name())
	if OS.get_name() == "Windows":
		for i in 10:
			var p := FileAccess.open("\\\\?\\pipe\\discord-ipc-%d" % i, FileAccess.READ_WRITE)
			print("DRP: pipe ", i, " -> ", "OPEN" if p else error_string(FileAccess.get_open_error()))
	else:
		var out := []
		print("DRP: nc found: ", OS.execute("which", ["nc"], out) == 0, " ", out)
		for k in ["XDG_RUNTIME_DIR", "TMPDIR"]:
			print("DRP: ", k, "=", OS.get_environment(k))
		for d in ["/tmp", OS.get_environment("XDG_RUNTIME_DIR")]:
			if d != "" and DirAccess.dir_exists_absolute(d):
				print("DRP: sockets in ", d, ": ", Array(DirAccess.get_files_at(d)).filter(func(f): return f.begins_with("discord-ipc")))

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
