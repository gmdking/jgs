extends Node
## Persistent settings: audio buses, graphics options, input rebinding, and
## gameplay sensitivities. Autoloaded as `Settings` so every scene can use it.

signal changed(key: String, value: Variant)

const CONFIG_PATH := "user://settings.cfg"
const OVERRIDE_PATH := "res://override.cfg"

# Gameplay tuning is special in multiplayer: the host owns it, and clients get
# a session-only copy that is never written to settings.cfg.
const GAMEPLAY_TUNING_KEYS := [
	"debug_gravity", "debug_game_speed", "debug_walk_speed", "debug_sprint_speed",
	"debug_jump_strength", "debug_pickup_range", "debug_hold_distance",
	"debug_physics_ticks", "debug_keep_physics_during_pause",
]

const DEFAULTS := {
	"music_volume": 0.8,
	"sfx_volume": 0.9,
	"mute": false,
	"window_mode": 1,
	# "Native" or "WxH" (for example "1920x1080").
	"resolution": "Native",
	"vsync": 2,
	# 0 means unlimited; any other value is an exact frame-rate cap.
	"fps_limit": 0,
	"render_scale": 1.0,
	"scaling_mode": 0,
	"msaa": 0,
	"msaa_2d": 0,
	"taa": false,
	"glow": false,
	"ssao": false,
	"ssil": false,
	"sdfgi": false,
	"fog": false,
	"shadows": true,
	"low_processor": false,
	"mouse_sensitivity": 0.002,
	"controller_sensitivity": 3.0,
	"discord_rich_presence": true,

	# Customization / crosshair
	"crosshair_style": 2,
	"crosshair_inverted": false,
	"crosshair_color": Color(1, 1, 1, 0.9),
	"crosshair_size": 10.0,
	"crosshair_thickness": 2.0,
	"crosshair_gap": 3.0,

	# Extra graphics options
	"renderer": "forward_plus",
	"screen_space_aa": 0,
	"shadow_atlas_size": 2048,
	"debanding": false,
	"borderless": false,
	"always_on_top": false,

	# Debug overlay (Settings > Debug tab / F3)
	"debug_overlay_startup": false,
	"debug_graph": true,
	"debug_refresh_interval": 0.1,
	"debug_show_timing": true,
	"debug_show_monitors": true,
	"debug_show_rendering": true,
	"debug_show_memory": true,
	"debug_show_physics": true,
	"debug_show_audio": true,
	"debug_show_input": true,
	"debug_show_display": true,
	"debug_show_engine": true,
	"debug_show_scene": true,
	"debug_show_network": true,
	"debug_show_held_object": true,

	# Multiplayer privacy. Off by default: IPs, ports and local paths stay
	# masked in the F3 report until explicitly revealed here.
	"debug_net_reveal_sensitive": false,

	# Debug gameplay tuning. These apply immediately and persist so testers can
	# keep the same sandbox setup between launches.
	"debug_gravity": 9.8,
	"debug_game_speed": 1.0,
	"debug_walk_speed": 5.0,
	"debug_sprint_speed": 10.0,
	"debug_jump_strength": 4.5,
	"debug_pickup_range": 4.0,
	"debug_hold_distance": 3.0,
	"debug_physics_ticks": 60,
	"debug_keep_physics_during_pause": false,

	"config_version": 2,
}

var values: Dictionary = DEFAULTS.duplicate(true)
var input_defaults: Dictionary = {}

# Overrides supplied by the host for the current multiplayer session only.
# These live in memory, are never saved, and are discarded when the session ends.
var session_values: Dictionary = {}
var session_active := false

var config := ConfigFile.new()


func _ready() -> void:
	# Settings are changed from the pause menu, so this autoload must keep
	# running while the SceneTree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_capture_input_defaults()
	_load()
	# The buses normally come from res://default_bus_layout.tres, which is
	# required for audio to work in exported Web builds. Keep these as a safety
	# net for old projects/configs where the layout has not been applied yet.
	_ensure_bus("Music")
	_ensure_bus("SFX")
	apply_all()
	# The first scene is not current yet while autoloads are initializing.
	call_deferred("_apply_all_deferred")
	get_tree().scene_changed.connect(_on_scene_changed)


func _apply_all_deferred() -> void:
	apply_all()


# SceneTree.scene_changed has no arguments in Godot 4; the connection is
# rejected if the callable expects one, which stopped settings reapplying.
func _on_scene_changed() -> void:
	apply_all()


func get_value(key: String, fallback: Variant = null) -> Variant:
	if session_active and session_values.has(key):
		return session_values[key]
	return values.get(key, DEFAULTS.get(key, fallback))


func _autoload(name: String) -> Node:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(name))


## Clients may not edit gameplay tuning while a multiplayer session is active.
## The controls are disabled too; this is a second line of defence.
func is_gameplay_locked() -> bool:
	var net := _autoload("Net")
	if net == null or not bool(net.call("is_active")):
		return false
	return int(net.get("role")) == 2  # Net.Role.CLIENT


func set_value(key: String, value: Variant) -> void:
	if is_gameplay_locked() and key in GAMEPLAY_TUNING_KEYS:
		return
	values[key] = value
	config.set_value("settings", key, value)
	# Save immediately: a debounced timer would never fire while paused.
	config.save(CONFIG_PATH)
	_apply(key)
	changed.emit(key, value)


## Apply the host's tuning for this session without touching the saved config.
## Only gameplay keys are accepted.
func set_session_values(incoming: Dictionary) -> void:
	var next := {}
	for key in GAMEPLAY_TUNING_KEYS:
		if incoming.has(key):
			next[key] = incoming[key]
	session_values = next
	session_active = true
	for key in next.keys():
		changed.emit(key, next[key])
	changed.emit("__session__", next)


## Drop the host's overrides and restore this machine's saved tuning.
func clear_session_values() -> void:
	if not session_active and session_values.is_empty():
		return
	session_active = false
	session_values.clear()
	for key in GAMEPLAY_TUNING_KEYS:
		changed.emit(key, values.get(key, DEFAULTS.get(key, null)))
	changed.emit("__session__", {})


func apply_all() -> void:
	apply_audio()
	apply_graphics()


func apply_audio() -> void:
	_set_bus_volume("Music", float(get_value("music_volume")))
	_set_bus_volume("SFX", float(get_value("sfx_volume")))
	var master := AudioServer.get_bus_index("Master")
	if master >= 0:
		AudioServer.set_bus_mute(master, bool(get_value("mute")))


func apply_graphics() -> void:
	# The renderer can only be selected before the engine boots, so persist it
	# and let the UI tell the player to restart.
	var renderer_methods := ["forward_plus", "mobile", "gl_compatibility"]
	var renderer := str(get_value("renderer"))
	if not renderer_methods.has(renderer):
		renderer = "forward_plus"
	if str(ProjectSettings.get_setting("rendering/renderer/rendering_method", renderer)) != renderer:
		_write_renderer_override(renderer)

	var modes := [
		DisplayServer.WINDOW_MODE_WINDOWED,
		DisplayServer.WINDOW_MODE_FULLSCREEN,
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
	]
	DisplayServer.window_set_mode(int(modes[clampi(int(get_value("window_mode")), 0, modes.size() - 1)]))

	var vsync_modes := [
		DisplayServer.VSYNC_DISABLED,
		DisplayServer.VSYNC_ENABLED,
		DisplayServer.VSYNC_ADAPTIVE,
		DisplayServer.VSYNC_MAILBOX,
	]
	DisplayServer.window_set_vsync_mode(int(vsync_modes[clampi(int(get_value("vsync")), 0, vsync_modes.size() - 1)]))

	var fps_limit := clampi(int(get_value("fps_limit")), 0, 1000)
	Engine.max_fps = fps_limit

	var size := _resolution_size(str(get_value("resolution")))
	if size.x > 0 and int(get_value("window_mode")) == 0:
		DisplayServer.window_set_size(size)

	var viewport := get_viewport()
	viewport.scaling_3d_scale = clampf(float(get_value("render_scale")), 0.5, 2.0)
	viewport.scaling_3d_mode = clampi(int(get_value("scaling_mode")), 0, Viewport.SCALING_3D_MODE_MAX - 1)
	viewport.msaa_3d = clampi(int(get_value("msaa")), 0, Viewport.MSAA_MAX - 1)
	viewport.msaa_2d = clampi(int(get_value("msaa_2d")), 0, Viewport.MSAA_MAX - 1)
	viewport.use_taa = bool(get_value("taa"))
	viewport.screen_space_aa = clampi(int(get_value("screen_space_aa")), 0, Viewport.SCREEN_SPACE_AA_MAX - 1)
	viewport.positional_shadow_atlas_size = int(get_value("shadow_atlas_size"))
	viewport.use_debanding = bool(get_value("debanding"))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, bool(get_value("borderless")))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, bool(get_value("always_on_top")))

	OS.low_processor_usage_mode = bool(get_value("low_processor"))
	# This sleep is a hard frame-rate cap of its own (20,000 us = 50 FPS), so
	# never let it overpower the FPS limit the user selected.
	OS.low_processor_usage_mode_sleep_usec = 0 if fps_limit > 0 else 6900

	_apply_world_environment()
	_apply_shadows()


# Writes ONLY the renderer choice to override.cfg. ProjectSettings.save_custom()
# would dump a snapshot of every project setting (autoload paths, input map,
# etc.) and silently override project.godot with stale values after any edit.
# Note: res:// is read-only in exported builds, so this only persists from the
# editor; the failure is harmless.
func _write_renderer_override(renderer: String) -> void:
	var override := ConfigFile.new()
	override.set_value("rendering", "renderer/rendering_method", renderer)
	var err := override.save(OVERRIDE_PATH)
	if err != OK:
		push_warning("Could not save %s (error %d); renderer change will not persist." % [OVERRIDE_PATH, err])


func _resolution_size(value: String) -> Vector2i:
	# "Native" leaves the window at its default size; anything else must be WxH.
	if value.strip_edges() == "Native":
		return Vector2i.ZERO
	var parts := value.split("x")
	if parts.size() != 2:
		return Vector2i.ZERO
	var width := int(parts[0].strip_edges())
	var height := int(parts[1].strip_edges())
	if width < 320 or height < 240 or width > 8192 or height > 8192:
		return Vector2i.ZERO
	return Vector2i(width, height)


func get_actions() -> Array[StringName]:
	var result: Array[StringName] = []
	for action in InputMap.get_actions():
		if not str(action).begins_with("ui_"):
			result.append(StringName(action))
	result.sort()
	return result


func action_display(action: StringName) -> String:
	var labels := PackedStringArray()
	for event in InputMap.action_get_events(action):
		labels.append(event_label(event))
	if labels.is_empty():
		return "(unbound)"
	return ", ".join(labels)


# Slot 0 is the primary binding, slot 1 is the optional secondary binding.
# Any further events (controller defaults, etc.) are left untouched.
func binding_display(action: StringName, slot: int) -> String:
	var events := InputMap.action_get_events(action)
	if slot >= 0 and slot < events.size():
		var event: InputEvent = events[slot]
		if _is_unbound_event(event):
			return "Unbound"
		return event_label(event)
	return "Unbound"


# A cleared slot keeps an inert placeholder so later default bindings do not
# shift up and appear as the secondary. It can never match real player input.
func _unbound_event() -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = 0
	event.physical_keycode = 0
	event.pressed = false
	return event


func _is_unbound_event(event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var key := event as InputEventKey
	return key.keycode == 0 and key.physical_keycode == 0 and not key.pressed


func event_label(event: InputEvent) -> String:
	if _is_unbound_event(event):
		return "Unbound"
	if event is InputEventKey:
		var key := event as InputEventKey
		var text := OS.get_keycode_string(key.keycode)
		if text.is_empty():
			text = OS.get_keycode_string(key.physical_keycode)
		return text if not text.is_empty() else "Key"
	if event is InputEventMouseButton:
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT: return "LMB"
			MOUSE_BUTTON_RIGHT: return "RMB"
			MOUSE_BUTTON_MIDDLE: return "MMB"
			MOUSE_BUTTON_WHEEL_UP: return "Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
			_: return "Mouse %d" % (event as InputEventMouseButton).button_index
	if event is InputEventJoypadButton:
		return "Pad Button %d" % (event as InputEventJoypadButton).button_index
	if event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		var axis_names := {
			JOY_AXIS_LEFT_X: "Left X", JOY_AXIS_LEFT_Y: "Left Y",
			JOY_AXIS_RIGHT_X: "Right X", JOY_AXIS_RIGHT_Y: "Right Y",
			JOY_AXIS_TRIGGER_LEFT: "L Trigger", JOY_AXIS_TRIGGER_RIGHT: "R Trigger",
		}
		var axis := str(axis_names.get(motion.axis, "Axis %d" % motion.axis))
		return "Pad %s%s" % [axis, "+" if motion.axis_value > 0.0 else "-"]
	return "Unknown"


func is_rebindable(event: InputEvent) -> bool:
	if event is InputEventKey:
		var key := event as InputEventKey
		return key.pressed and not key.is_echo() and key.keycode != KEY_ESCAPE and not (key.keycode == 0 and key.physical_keycode == 0)
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).pressed
	if event is InputEventJoypadButton:
		return (event as InputEventJoypadButton).pressed
	if event is InputEventJoypadMotion:
		return absf((event as InputEventJoypadMotion).axis_value) > 0.5
	return false


func rebind_action(action: StringName, event: InputEvent) -> void:
	set_binding(action, 0, event)


func set_binding(action: StringName, slot: int, event: InputEvent) -> void:
	if not InputMap.has_action(action) or not is_rebindable(event):
		return
	var serialized := serialize_event(event)
	# A binding can only belong to one action/slot at a time.
	for other in InputMap.get_actions():
		for existing in InputMap.action_get_events(other).duplicate():
			if serialize_event(existing) == serialized:
				InputMap.action_erase_event(other, existing)

	var events: Array = InputMap.action_get_events(action).duplicate()
	var target_slot := slot
	# Secondary needs a primary to sit behind; fall back to primary if missing.
	if target_slot == 1 and events.is_empty():
		target_slot = 0
	if target_slot < events.size():
		events[target_slot] = event
	else:
		events.append(event)

	InputMap.action_erase_events(action)
	for item in events:
		InputMap.action_add_event(action, item)
	_save_input()


func clear_binding(action: StringName, slot: int) -> void:
	if not InputMap.has_action(action):
		return
	var events: Array = InputMap.action_get_events(action).duplicate()
	if slot < 0 or slot >= events.size():
		events.resize(slot + 1)
		for i in events.size():
			if events[i] == null:
				events[i] = _unbound_event()
	elif not _is_unbound_event(events[slot]):
		events[slot] = _unbound_event()
	else:
		return
	InputMap.action_erase_events(action)
	for item in events:
		InputMap.action_add_event(action, item)
	_save_input()


func reset_controls() -> void:
	for action in input_defaults.keys():
		if not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		for event in input_defaults[action]:
			InputMap.action_add_event(action, event)
	_save_input()


func reset_all() -> void:
	var locked := is_gameplay_locked()
	var kept_gameplay := {}
	if locked:
		# The host owns gameplay values; never overwrite our saved copies.
		for key in GAMEPLAY_TUNING_KEYS:
			kept_gameplay[key] = values.get(key, DEFAULTS.get(key, null))
	values = DEFAULTS.duplicate(true)
	for key in kept_gameplay.keys():
		values[key] = kept_gameplay[key]
	for key in values.keys():
		config.set_value("settings", key, values[key])
	reset_controls()
	apply_all()
	config.save(CONFIG_PATH)
	changed.emit("__all__", values)


func reset_keys(keys: Array) -> void:
	var locked := is_gameplay_locked()
	var reset: Array[String] = []
	for key in keys:
		var key_name := str(key)
		if not DEFAULTS.has(key_name):
			continue
		if locked and key_name in GAMEPLAY_TUNING_KEYS:
			continue
		values[key_name] = DEFAULTS[key_name]
		config.set_value("settings", key_name, values[key_name])
		reset.append(key_name)
	apply_all()
	config.save(CONFIG_PATH)
	for key_name in reset:
		changed.emit(key_name, values[key_name])


func serialize_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		var key := event as InputEventKey
		return {"type": "key", "keycode": key.keycode, "physical": key.physical_keycode}
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		return {"type": "mouse", "button": mouse.button_index}
	if event is InputEventJoypadButton:
		var pad := event as InputEventJoypadButton
		return {"type": "joy_button", "device": pad.device, "button": pad.button_index}
	if event is InputEventJoypadMotion:
		var motion := event as InputEventJoypadMotion
		return {"type": "joy_motion", "device": motion.device, "axis": motion.axis, "value": motion.axis_value}
	return {}


func deserialize_event(data: Dictionary) -> InputEvent:
	match str(data.get("type", "")):
		"key":
			var key_event := InputEventKey.new()
			key_event.keycode = int(data.get("keycode", 0))
			key_event.physical_keycode = int(data.get("physical", 0))
			return key_event
		"mouse":
			var mouse_event := InputEventMouseButton.new()
			mouse_event.button_index = int(data.get("button", 0))
			mouse_event.pressed = true
			return mouse_event
		"joy_button":
			var pad_event := InputEventJoypadButton.new()
			pad_event.device = int(data.get("device", 0))
			pad_event.button_index = int(data.get("button", 0))
			pad_event.pressed = true
			return pad_event
		"joy_motion":
			var motion_event := InputEventJoypadMotion.new()
			motion_event.device = int(data.get("device", 0))
			motion_event.axis = int(data.get("axis", 0))
			motion_event.axis_value = float(data.get("value", 1.0))
			return motion_event
	return null


func _capture_input_defaults() -> void:
	for action in InputMap.get_actions():
		if str(action).begins_with("ui_"):
			continue
		input_defaults[action] = InputMap.action_get_events(action).duplicate()


func _load() -> void:
	if config.load(CONFIG_PATH) != OK:
		return
	for key in DEFAULTS.keys():
		values[key] = config.get_value("settings", key, DEFAULTS[key])

	# Older configs stored resolution and fps limit as option indexes. Convert
	# them to real values once so typed/custom entries work going forward.
	if int(config.get_value("settings", "config_version", 1)) < 2:
		var legacy_fps := [0, 24, 30, 60, 120, 144, 240, 360, 480]
		var fps_index := int(values.get("fps_limit", 0))
		if fps_index >= 0 and fps_index < legacy_fps.size():
			values["fps_limit"] = legacy_fps[fps_index]
		var legacy_res := ["Native", "1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160"]
		var res_index := int(values.get("resolution", 0))
		if res_index >= 0 and res_index < legacy_res.size():
			values["resolution"] = legacy_res[res_index]
		values["config_version"] = 2
		for key in ["config_version", "fps_limit", "resolution"]:
			config.set_value("settings", key, values[key])
		config.save(CONFIG_PATH)

	var saved: Array = config.get_value("input", "actions", [])
	for entry in saved:
		if not entry is Dictionary:
			continue
		var action := StringName(entry.get("action", ""))
		if not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		for item in entry.get("events", []):
			var event := deserialize_event(item)
			if event != null:
				InputMap.action_add_event(action, event)


func _save_input() -> void:
	var saved := []
	for action in get_actions():
		var events := []
		for event in InputMap.action_get_events(action):
			events.append(serialize_event(event))
		saved.append({"action": str(action), "events": events})
	config.set_value("input", "actions", saved)
	config.save(CONFIG_PATH)


func _apply(key: String) -> void:
	if key.begins_with("music_") or key.begins_with("sfx_") or key == "mute":
		apply_audio()
	elif key in ["renderer", "window_mode", "resolution", "vsync", "fps_limit", "render_scale",
		"scaling_mode", "msaa", "msaa_2d", "taa", "screen_space_aa", "shadow_atlas_size",
		"debanding", "borderless", "always_on_top", "glow", "ssao", "ssil", "sdfgi", "fog",
		"shadows", "low_processor"]:
		apply_graphics()


func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, "Master")


func _set_bus_volume(bus_name: String, linear: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	var db := -80.0 if linear <= 0.001 else linear_to_db(clampf(linear, 0.0, 1.0))
	AudioServer.set_bus_volume_db(index, db)


func _apply_world_environment() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	for node in scene.find_children("*", "WorldEnvironment", true, false):
		var world := node as WorldEnvironment
		if world == null or world.environment == null:
			continue
		var environment: Environment = world.environment
		environment.glow_enabled = bool(get_value("glow"))
		environment.ssao_enabled = bool(get_value("ssao"))
		environment.ssil_enabled = bool(get_value("ssil"))
		environment.sdfgi_enabled = bool(get_value("sdfgi"))
		environment.fog_enabled = bool(get_value("fog"))


func _apply_shadows() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	for node in scene.find_children("*", "DirectionalLight3D", true, false):
		var light := node as DirectionalLight3D
		if light != null:
			light.shadow_enabled = bool(get_value("shadows"))
