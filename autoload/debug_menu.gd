extends CanvasLayer
## F3 debug overlay. Autoloaded so it exists in every scene, including while
## the SceneTree is paused. Everything is built in code: no scene to forget.

const HISTORY := 240
const REFRESH_INTERVAL := 0.1

# Godot 4 has no get_monitor_name() helper, so the built-in monitor names are
# kept here in index order (Performance.MONITOR_MAX == 59 in 4.7).
const MONITOR_NAMES := [
	"Time/FPS", "Time/Frame Process", "Time/Physics Process", "Time/Navigation Process",
	"Memory/Static", "Memory/Static Max", "Memory/Message Buffer Max",
	"Objects/Count", "Objects/Resources", "Objects/Nodes", "Objects/Orphan Nodes",
	"Rendering/Objects in Frame", "Rendering/Primitives in Frame", "Rendering/Draw Calls in Frame",
	"Rendering/Video Memory", "Rendering/Texture Memory", "Rendering/Buffer Memory",
	"Physics 2D/Active Objects", "Physics 2D/Collision Pairs", "Physics 2D/Islands",
	"Physics 3D/Active Objects", "Physics 3D/Collision Pairs", "Physics 3D/Islands",
	"Audio/Output Latency",
	"Navigation/Active Maps", "Navigation/Regions", "Navigation/Agents", "Navigation/Links",
	"Navigation/Polygons", "Navigation/Edges", "Navigation/Edges Merged",
	"Navigation/Edges Connected", "Navigation/Edges Free", "Navigation/Obstacles",
	"Pipeline/Compilations Canvas", "Pipeline/Compilations Mesh", "Pipeline/Compilations Surface",
	"Pipeline/Compilations Draw", "Pipeline/Compilations Specialization",
	"Navigation 2D/Active Maps", "Navigation 2D/Regions", "Navigation 2D/Agents",
	"Navigation 2D/Links", "Navigation 2D/Polygons", "Navigation 2D/Edges",
	"Navigation 2D/Edges Merged", "Navigation 2D/Edges Connected", "Navigation 2D/Edges Free",
	"Navigation 2D/Obstacles",
	"Navigation 3D/Active Maps", "Navigation 3D/Regions", "Navigation 3D/Agents",
	"Navigation 3D/Links", "Navigation 3D/Polygons", "Navigation 3D/Edges",
	"Navigation 3D/Edges Merged", "Navigation 3D/Edges Connected", "Navigation 3D/Edges Free",
	"Navigation 3D/Obstacles",
]

const RENDER_INFO_NAMES := [
	"Objects in Frame", "Primitives in Frame", "Draw Calls in Frame", "Texture Memory",
	"Buffer Memory", "Video Memory", "Pipeline Compiles (Canvas)", "Pipeline Compiles (Mesh)",
	"Pipeline Compiles (Surface)", "Pipeline Compiles (Draw)", "Pipeline Compiles (Specialization)",
]

const TIME_MONITORS := [1, 2, 3, 23]
const MEMORY_MONITORS := [4, 5, 6, 14, 15, 16]

# Keys in Settings used by the Debug tab to show/hide overlay sections.
const SECTION_SETTINGS := {
	"timing": "debug_show_timing",
	"monitors": "debug_show_monitors",
	"rendering": "debug_show_rendering",
	"memory": "debug_show_memory",
	"physics": "debug_show_physics",
	"audio": "debug_show_audio",
	"input": "debug_show_input",
	"display": "debug_show_display",
	"engine": "debug_show_engine",
	"scene": "debug_show_scene",
	"network": "debug_show_network",
	"held_object": "debug_show_held_object",
}

# Every RigidBody3D / PhysicsBody3D / CollisionObject3D property we know about.
# Read through _prop() so a property renamed between Godot versions can never
# throw an "invalid access" error in the overlay.
const PHYSICS_PROPERTY_NAMES := [
	"mass", "gravity_scale", "linear_damp", "angular_damp",
	"linear_damp_mode", "angular_damp_mode",
	"linear_velocity", "angular_velocity",
	"freeze", "freeze_mode", "can_sleep", "sleeping",
	"contact_monitor", "max_contacts_reported", "continuous_cd",
	"disable_mode", "collision_layer", "collision_mask",
	"collision_priority", "input_ray_pickable",
	"center_of_mass_mode", "center_of_mass", "inertia",
	"axis_lock_linear_x", "axis_lock_linear_y", "axis_lock_linear_z",
	"axis_lock_angular_x", "axis_lock_angular_y", "axis_lock_angular_z",
	"physics_material_override", "physics_interpolation_mode",
	"process_physics_priority",
]


class DebugGraph extends Control:
	const HISTORY := 240
	var names: PackedStringArray = PackedStringArray()
	var colors: Array = []
	var data: Array[PackedFloat32Array] = []
	var _scale := 33.0

	func configure(p_names: PackedStringArray, p_colors: Array) -> void:
		names = p_names
		colors = p_colors
		for _i in p_names.size():
			data.append(PackedFloat32Array())

	func add_samples(values: Array) -> void:
		for i in data.size():
			var series := data[i]
			series.append(float(values[i]) if i < values.size() else 0.0)
			if series.size() > HISTORY:
				series.remove_at(0)
			data[i] = series
		var peak := 16.7
		for series in data:
			for value in series:
				peak = maxf(peak, value)
		_scale = lerpf(_scale, maxf(33.0, peak * 1.15), 0.08)
		if is_visible_in_tree():
			queue_redraw()

	func clear() -> void:
		for i in data.size():
			data[i] = PackedFloat32Array()
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.05, 0.92), true)
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.18), false)

		# 60 FPS / 30 FPS reference lines.
		for target in [16.67, 33.33]:
			var y := h - clampf(float(target) / _scale, 0.0, 1.0) * (h - 13.0) - 2.0
			draw_line(Vector2(0, y), Vector2(w, y), Color(1, 1, 1, 0.12), 1.0)
			draw_string(ThemeDB.fallback_font, Vector2(2, y - 2), "%.0fms" % float(target), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, 0.28))

		for i in data.size():
			var series := data[i]
			if series.size() < 2:
				continue
			var points := PackedVector2Array()
			var span := float(maxi(1, series.size() - 1))
			for j in series.size():
				var x := float(j) / span * w
				var y := h - clampf(series[j] / _scale, 0.0, 1.0) * (h - 13.0) - 2.0
				points.append(Vector2(x, y))
			draw_polyline(points, colors[i], 1.5)

		var legend_x := 4.0
		for i in names.size():
			draw_rect(Rect2(Vector2(legend_x, 3), Vector2(8, 8)), colors[i], true)
			draw_string(ThemeDB.fallback_font, Vector2(legend_x + 12, 11), names[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.85))
			legend_x += 14.0 + names[i].length() * 6.5
		draw_string(ThemeDB.fallback_font, Vector2(w - 52, 11), "%.1fms" % _scale, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.5))


var _panel: PanelContainer
var _reader: RichTextLabel
var _graph: DebugGraph
var _history := PackedFloat32Array()
var _process_history := PackedFloat32Array()
var _physics_history := PackedFloat32Array()
var _refresh_accum := 0.0
var _refresh_interval := REFRESH_INTERVAL
var settings: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 120
	visible = false
	_build_ui()
	settings = get_node_or_null("/root/Settings")
	_apply_settings()
	apply_gameplay_settings()
	if settings != null:
		settings.changed.connect(_on_settings_changed)
	get_tree().scene_changed.connect(_on_scene_changed)
	# Opening here (rather than in _build_ui) avoids touching a half-built UI
	# while autoloads are still initializing.
	call_deferred("_apply_startup_visibility")


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = 10.0
	_panel.offset_top = 10.0
	_panel.offset_right = 650.0
	_panel.offset_bottom = 730.0
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var column := VBoxContainer.new()
	margin.add_child(column)

	var title := Label.new()
	title.text = "F3  DEBUG OVERLAY   (F3 / Esc to close, PgUp / PgDn to scroll)"
	title.add_theme_color_override("font_color", Color(0.55, 0.95, 1.0))
	column.add_child(title)

	_graph = DebugGraph.new()
	_graph.custom_minimum_size = Vector2(620, 100)
	_graph.configure(
		PackedStringArray(["Frame", "Process", "Physics"]),
		[Color(1, 0.45, 0.45), Color(0.45, 1, 0.55), Color(0.45, 0.7, 1)]
	)
	column.add_child(_graph)

	_reader = RichTextLabel.new()
	_reader.scroll_active = true
	_reader.scroll_following = false
	_reader.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_reader.custom_minimum_size = Vector2(620, 540)
	_reader.add_theme_color_override("default_color", Color(0.92, 0.94, 0.98))
	_reader.text = "Initializing..."
	column.add_child(_reader)


func _input(event: InputEvent) -> void:
	if not event is InputEventKey or event.is_echo():
		return
	var key := event as InputEventKey
	var code := key.keycode
	if code == KEY_UNKNOWN or code == 0:
		code = key.physical_keycode

	if code == KEY_F3 and key.pressed:
		if visible:
			hide_menu()
		else:
			show_menu()
		get_viewport().set_input_as_handled()
		return

	if not visible or not key.pressed:
		return
	match code:
		KEY_ESCAPE:
			hide_menu()
			get_viewport().set_input_as_handled()
		KEY_PAGEUP, KEY_PAGEDOWN, KEY_HOME, KEY_END:
			_scroll_reader(code)
			get_viewport().set_input_as_handled()


func _scroll_reader(code: int) -> void:
	var bar := _reader.get_v_scroll_bar()
	if bar == null:
		return
	match code:
		KEY_HOME:
			bar.value = bar.min_value
		KEY_END:
			bar.value = bar.max_value
		KEY_PAGEUP:
			bar.value = clampf(bar.value - 120.0, bar.min_value, bar.max_value)
		KEY_PAGEDOWN:
			bar.value = clampf(bar.value + 120.0, bar.min_value, bar.max_value)


func show_menu() -> void:
	_show_seed_sample()
	# Deliberately leave the mouse mode alone: F3 must not free the cursor
	# during gameplay. Scroll with PgUp/PgDn/Home/End instead.
	visible = true
	_refresh()


func hide_menu() -> void:
	visible = false


func toggle_menu() -> void:
	if visible:
		hide_menu()
	else:
		show_menu()


func reset_history() -> void:
	_history.clear()
	_process_history.clear()
	_physics_history.clear()
	_show_seed_sample()
	if _graph != null:
		_graph.clear()
	_refresh_accum = 0.0
	if visible:
		_refresh()


func get_snapshot() -> String:
	if _history.is_empty():
		_show_seed_sample()
	return "\n".join(_build_report())


func copy_snapshot() -> void:
	DisplayServer.clipboard_set(get_snapshot())


func _show_seed_sample() -> void:
	if _history.is_empty():
		_history.append(0.0)
		_process_history.append(0.0)
		_physics_history.append(0.0)


func _on_settings_changed(key: String, _value: Variant) -> void:
	if key == "__all__" or key.begins_with("debug_"):
		_apply_settings()
		apply_gameplay_settings()
		match key:
			"debug_overlay_startup", "__all__":
				_apply_startup_visibility()


func _apply_startup_visibility() -> void:
	if not _setting("debug_overlay_startup", false):
		return
	show_menu()


func _apply_settings() -> void:
	if _graph != null:
		_graph.visible = bool(_setting("debug_graph", true))
	_refresh_interval = clampf(float(_setting("debug_refresh_interval", REFRESH_INTERVAL)), 0.05, 1.0)
	if visible:
		_refresh()


func _setting(key: String, fallback: Variant) -> Variant:
	if settings == null:
		return fallback
	return settings.get_value(key, fallback)


func _section_enabled(section: String) -> bool:
	var key: String = SECTION_SETTINGS.get(section, "")
	if key.is_empty():
		return true
	return bool(_setting(key, true))


func _on_scene_changed() -> void:
	# New players and worlds need the current tuning reapplied after they load.
	call_deferred("apply_gameplay_settings")


func apply_gameplay_settings() -> void:
	_apply_world_gravity()
	Engine.time_scale = clampf(float(_setting("debug_game_speed", 1.0)), -20.0, 20.0)
	Engine.physics_ticks_per_second = clampi(int(_setting("debug_physics_ticks", 60)), 1, 1000)
	_apply_player_values()
	if visible:
		_refresh()


func _apply_world_gravity() -> void:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var world: World3D = viewport.world_3d
	if world == null:
		return
	var space: RID = world.space
	if not space.is_valid():
		return
	var gravity := clampf(float(_setting("debug_gravity", 9.8)), -1000.0, 1000.0)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY, gravity)


func _apply_player_values() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var jump := clampf(float(_setting("debug_jump_strength", 4.5)), -500.0, 500.0)
	for node in tree.get_nodes_in_group("player"):
		node.set("gravity", clampf(float(_setting("debug_gravity", 9.8)), -1000.0, 1000.0))
		node.set("walk_speed", clampf(float(_setting("debug_walk_speed", 5.0)), -500.0, 500.0))
		node.set("sprint_speed", clampf(float(_setting("debug_sprint_speed", 10.0)), -1000.0, 1000.0))
		node.set("lowjump", jump)
		node.set("highjump", jump * 2.0)
		node.set("curjump", jump)
		node.set("pickup_range", clampf(float(_setting("debug_pickup_range", 4.0)), -100.0, 100.0))
		node.set("hold_distance", clampf(float(_setting("debug_hold_distance", 3.0)), -100.0, 100.0))


func _process(delta: float) -> void:
	var frame_ms := delta * 1000.0
	_history.append(frame_ms)
	_process_history.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_history.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	if _history.size() > HISTORY:
		_history.remove_at(0)
	if _process_history.size() > HISTORY:
		_process_history.remove_at(0)
	if _physics_history.size() > HISTORY:
		_physics_history.remove_at(0)
	_graph.add_samples([frame_ms, _process_history[_process_history.size() - 1], _physics_history[_physics_history.size() - 1]])

	_refresh_accum += delta
	if visible and _refresh_accum >= _refresh_interval:
		_refresh_accum = 0.0
		_refresh()


func _refresh() -> void:
	if _reader == null:
		return
	_reader.text = "\n".join(_build_report())


func _build_report() -> PackedStringArray:
	var lines := PackedStringArray()
	if _section_enabled("timing"):
		_add_timing(lines)
	if _section_enabled("monitors"):
		_add_performance_monitors(lines)
	if _section_enabled("rendering"):
		_add_rendering(lines)
	if _section_enabled("memory"):
		_add_memory(lines)
	if _section_enabled("physics"):
		_add_physics(lines)
	if _section_enabled("audio"):
		_add_audio(lines)
	if _section_enabled("input"):
		_add_input(lines)
	if _section_enabled("display"):
		_add_display(lines)
	if _section_enabled("engine"):
		_add_engine_os(lines)
	if _section_enabled("scene"):
		_add_scene(lines)
	if _section_enabled("network"):
		_add_network(lines)
	if _section_enabled("held_object"):
		_add_held_object(lines)
	return lines


func _row(lines: PackedStringArray, key: String, value: Variant) -> void:
	lines.append("%-32s %s" % [key, str(value)])


func _section(lines: PackedStringArray, title: String) -> void:
	lines.append("")
	lines.append("===== %s =====" % title)


func _num(value: float, digits := 2) -> String:
	return "%.*f" % [digits, value]


func _mem(value: float) -> String:
	var amount := absf(value)
	if amount >= 1073741824.0:
		return "%s GiB" % _num(value / 1073741824.0, 2)
	if amount >= 1048576.0:
		return "%s MiB" % _num(value / 1048576.0, 2)
	if amount >= 1024.0:
		return "%s KiB" % _num(value / 1024.0, 1)
	return "%d B" % int(value)


func _add_timing(lines: PackedStringArray) -> void:
	_section(lines, "FRAME TIMING")
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var engine_fps := Engine.get_frames_per_second()
	_row(lines, "FPS (Performance / Engine)", "%s / %s" % [_num(fps, 1), _num(engine_fps, 1)])
	_row(lines, "Frame time now", "%s ms" % _num(_history[_history.size() - 1], 3))
	_row(lines, "Frame time avg (last %d)" % HISTORY, "%s ms" % _num(_average(_history), 3))
	_row(lines, "Frame time min / max", "%s / %s ms" % [_num(_minimum(_history), 3), _num(_maximum(_history), 3)])
	var sorted: Array[float] = []
	for sample in _history:
		sorted.append(sample)
	sorted.sort()
	var p95 := sorted[clampi(int(float(sorted.size()) * 0.95) - 1, 0, sorted.size() - 1)]
	var p99 := sorted[clampi(int(float(sorted.size()) * 0.99) - 1, 0, sorted.size() - 1)]
	_row(lines, "Frame time p95 / p99", "%s / %s ms" % [_num(p95, 3), _num(p99, 3)])
	_row(lines, "Approx. 1% low FPS", _num(1000.0 / maxf(p99, 0.01), 1))
	_row(lines, "Process time (Performance)", "%s ms" % _num(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 3))
	_row(lines, "Physics time (Performance)", "%s ms" % _num(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 3))
	_row(lines, "Navigation process time", "%s ms" % _num(Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0, 3))
	_row(lines, "Render setup CPU time", "%s ms" % _num(RenderingServer.get_frame_setup_time_cpu() * 1000.0, 3))
	_row(lines, "Physics interpolation", _num(Engine.get_physics_interpolation_fraction(), 3))
	_row(lines, "Frames drawn / process / physics", "%d / %d / %d" % [Engine.get_frames_drawn(), Engine.get_process_frames(), Engine.get_physics_frames()])
	_row(lines, "Time scale / physics ticks", "%s / %d" % [_num(Engine.time_scale, 3), Engine.physics_ticks_per_second])
	_row(lines, "Max FPS / max physics steps", "%d / %d" % [Engine.max_fps, Engine.max_physics_steps_per_frame])
	_row(lines, "VSync mode", DisplayServer.window_get_vsync_mode())
	_row(lines, "Uptime", "%s s (%s ms)" % [_num(float(Time.get_ticks_msec()) / 1000.0, 1), Time.get_ticks_msec()])


func _add_performance_monitors(lines: PackedStringArray) -> void:
	_section(lines, "ALL BUILT-IN PERFORMANCE MONITORS")
	var last_category := ""
	for i in mini(MONITOR_NAMES.size(), Performance.MONITOR_MAX):
		var full_name: String = MONITOR_NAMES[i]
		var category := full_name.split("/")[0]
		if category != last_category:
			lines.append("--- %s ---" % category)
			last_category = category
		var value := Performance.get_monitor(i)
		var formatted: String
		if i == 0:
			formatted = "%s FPS" % _num(value, 1)
		elif TIME_MONITORS.has(i):
			formatted = "%s ms" % _num(value * 1000.0, 3)
		elif MEMORY_MONITORS.has(i):
			formatted = _mem(value)
		else:
			formatted = "%d" % int(value)
		_row(lines, "  " + full_name.substr(full_name.find("/") + 1), formatted)

	var custom_names := Performance.get_custom_monitor_names()
	var custom_types := Performance.get_custom_monitor_types()
	if custom_names.size() > 0:
		lines.append("--- Custom ---")
		for i in custom_names.size():
			var id = custom_names[i]
			var value = Performance.get_custom_monitor(id)
			var type_name: String = ["Quantity", "Memory", "Time", "Percentage"][custom_types[i]] if i < custom_types.size() else "?"
			_row(lines, "  " + str(id), "%s (%s)" % [str(value), type_name])


func _add_rendering(lines: PackedStringArray) -> void:
	_section(lines, "RENDERING")
	for i in RENDER_INFO_NAMES.size():
		var value := RenderingServer.get_rendering_info(i)
		_row(lines, "  " + RENDER_INFO_NAMES[i], _mem(float(value)) if i >= 3 else "%d" % value)
	_row(lines, "Driver / method", "%s / %s" % [RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_current_rendering_method()])
	_row(lines, "Video adapter", RenderingServer.get_video_adapter_name())
	_row(lines, "Adapter vendor", RenderingServer.get_video_adapter_vendor())
	_row(lines, "Adapter API version", RenderingServer.get_video_adapter_api_version())
	_row(lines, "Adapter type", RenderingServer.get_video_adapter_type())
	_row(lines, "Default clear color", RenderingServer.get_default_clear_color())
	_row(lines, "Rendering device", RenderingServer.get_rendering_device())
	_row(lines, "On render thread", RenderingServer.is_on_render_thread())
	_row(lines, "OS video driver info", OS.get_video_adapter_driver_info())


func _add_memory(lines: PackedStringArray) -> void:
	_section(lines, "MEMORY")
	_row(lines, "Static memory", _mem(float(OS.get_static_memory_usage())))
	_row(lines, "Static memory peak", _mem(float(OS.get_static_memory_peak_usage())))
	var info := OS.get_memory_info()
	for key in info.keys():
		_row(lines, "OS " + str(key), _mem(float(info[key])))


func _add_physics(lines: PackedStringArray) -> void:
	_section(lines, "PHYSICS SERVERS")
	_row(lines, "  2D active objects", PhysicsServer2D.get_process_info(PhysicsServer2D.INFO_ACTIVE_OBJECTS))
	_row(lines, "  2D collision pairs", PhysicsServer2D.get_process_info(PhysicsServer2D.INFO_COLLISION_PAIRS))
	_row(lines, "  2D islands", PhysicsServer2D.get_process_info(PhysicsServer2D.INFO_ISLAND_COUNT))
	_row(lines, "  3D active objects", PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS))
	_row(lines, "  3D collision pairs", PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_COLLISION_PAIRS))
	_row(lines, "  3D islands", PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ISLAND_COUNT))
	_row(lines, "World gravity", "%s m/s^2" % _num(float(_setting("debug_gravity", 9.8)), 2))
	_row(lines, "Game speed", "%sx" % _num(float(_setting("debug_game_speed", 1.0)), 2))
	_row(lines, "In physics frame", Engine.is_in_physics_frame())


func _add_audio(lines: PackedStringArray) -> void:
	_section(lines, "AUDIO")
	_row(lines, "Driver / device", AudioServer.get_driver_name())
	_row(lines, "Mix rate", "%d Hz" % int(AudioServer.get_mix_rate()))
	_row(lines, "Output latency", "%s ms" % _num(AudioServer.get_output_latency() * 1000.0, 3))
	_row(lines, "Speaker mode", AudioServer.get_speaker_mode())
	_row(lines, "Input buffer frames", AudioServer.get_input_buffer_length_frames())
	_row(lines, "Input frames available", AudioServer.get_input_frames_available())
	_row(lines, "Bus count", AudioServer.bus_count)
	for i in AudioServer.bus_count:
		var peak := -100.0
		if AudioServer.get_bus_channels(i) > 0:
			peak = maxf(AudioServer.get_bus_peak_volume_left_db(i, 0), AudioServer.get_bus_peak_volume_right_db(i, 0))
		_row(lines, "  Bus: " + AudioServer.get_bus_name(i), "%s dB" % _num(peak, 1))


func _add_input(lines: PackedStringArray) -> void:
	_section(lines, "INPUT")
	_row(lines, "Mouse position", get_viewport().get_mouse_position())
	_row(lines, "Mouse velocity", Input.get_last_mouse_velocity())
	_row(lines, "Mouse button mask", Input.get_mouse_button_mask())
	_row(lines, "Mouse mode", Input.mouse_mode)
	_row(lines, "Anything pressed", Input.is_anything_pressed())
	var joypads := Input.get_connected_joypads()
	_row(lines, "Connected joypads", joypads.size())
	for device in joypads:
		_row(lines, "  Pad %d" % device, "%s [%s]" % [Input.get_joy_name(device), Input.get_joy_guid(device)])
	for action in InputMap.get_actions():
		var action_name := StringName(action)
		var strength := Input.get_action_strength(action_name)
		if strength > 0.0:
			_row(lines, "  Action: " + str(action_name), _num(strength, 2))


func _add_display(lines: PackedStringArray) -> void:
	_section(lines, "DISPLAY")
	_row(lines, "Display server", DisplayServer.get_name())
	_row(lines, "Window size / position", "%s / %s" % [str(DisplayServer.window_get_size()), str(DisplayServer.window_get_position())])
	_row(lines, "Window mode / focused", "%d / %s" % [DisplayServer.window_get_mode(), DisplayServer.window_is_focused()])
	_row(lines, "Current / primary screen", "%d / %d" % [DisplayServer.window_get_current_screen(), DisplayServer.get_primary_screen()])
	_row(lines, "Screen count", DisplayServer.get_screen_count())
	var screen := DisplayServer.window_get_current_screen()
	_row(lines, "Screen size", DisplayServer.screen_get_size(screen))
	_row(lines, "Screen refresh rate", "%s Hz" % _num(DisplayServer.screen_get_refresh_rate(screen), 2))
	_row(lines, "Screen DPI / scale", "%d / %s" % [DisplayServer.screen_get_dpi(screen), _num(DisplayServer.screen_get_scale(screen), 2)])
	_row(lines, "Viewport size", get_viewport().size)
	_row(lines, "Touchscreen available", DisplayServer.is_touchscreen_available())


func _add_engine_os(lines: PackedStringArray) -> void:
	_section(lines, "ENGINE / OS")
	var version := Engine.get_version_info()
	_row(lines, "Engine version", version.get("string", str(version)))
	_row(lines, "Engine architecture", Engine.get_architecture_name())
	_row(lines, "Project name", ProjectSettings.get_setting("application/config/name", "?"))
	_row(lines, "OS / version", "%s / %s" % [OS.get_name(), OS.get_version()])
	_row(lines, "Distribution / model", "%s / %s" % [OS.get_distribution_name(), OS.get_model_name()])
	_row(lines, "Processor / threads", "%s / %d" % [OS.get_processor_name(), OS.get_processor_count()])
	_row(lines, "Locale / unique id", "%s / %s" % [OS.get_locale(), OS.get_unique_id()])
	_row(lines, "Process id", OS.get_process_id())
	_row(lines, "Executable", OS.get_executable_path())
	_row(lines, "Data dir / user dir", "%s / %s" % [OS.get_data_dir(), OS.get_user_data_dir()])
	_row(lines, "Debug build / sandboxed", "%s / %s" % [str(OS.is_debug_build()), str(OS.is_sandboxed())])
	_row(lines, "Command line", str(OS.get_cmdline_args()))


func _add_network(lines: PackedStringArray) -> void:
	_section(lines, "MULTIPLAYER / NETWORK")
	var net := get_node_or_null("/root/Net")
	if net == null:
		_row(lines, "Net autoload", "MISSING")
		return
	if not net.has_method("debug_snapshot"):
		_row(lines, "Net debug API", "debug_snapshot() missing - update net.gd")
		return
	var snap: Dictionary = net.call("debug_snapshot")
	var reveal := bool(_setting("debug_net_reveal_sensitive", false))
	var hidden := "<hidden>"

	# --- Session ---
	_row(lines, "Role", snap.get("role_name", "?"))
	_row(lines, "Status", snap.get("status", ""))
	_row(lines, "Local peer id", snap.get("peer_id", 0))
	_row(lines, "Map path", snap.get("map_path", "") if reveal else hidden)
	_row(lines, "Server listening", snap.get("server_listening", false))
	_row(lines, "Server port", snap.get("server_port", 0) if reveal else hidden)
	_row(lines, "Known peers", str(snap.get("known_peers", [])))
	_row(lines, "Next peer id", snap.get("next_peer_id", 0))
	_row(lines, "Force full snapshot", snap.get("force_full_snapshot", false))

	# --- Client socket ---
	var client_state := int(snap.get("client_socket_state", -1))
	_row(lines, "Client socket state", client_state)
	if client_state >= 0:
		_row(lines, "Client address", "%s:%s" % [snap.get("client_address", ""), snap.get("client_port", 0)] if reveal else hidden)
		_row(lines, "Client local port", snap.get("client_local_port", 0) if reveal else hidden)
		_row(lines, "Client TCP ago", "%d ms" % int(snap.get("client_connected_ago_ms", -1)))
		_row(lines, "Client handshake ago", "%d ms" % int(snap.get("client_handshake_ago_ms", -1)))
		_row(lines, "Client queue", "%s / %d packets" % [_mem(float(snap.get("client_queued_bytes", 0))), int(snap.get("client_queued_packets", 0))])
		_add_net_stats(lines, "Client", snap.get("client_stats", {}))

	# --- Host peers ---
	var peers: Dictionary = snap.get("peers", {})
	_row(lines, "Connected peers", peers.size())
	for id in peers.keys():
		var p: Dictionary = peers.get(id, {})
		lines.append("--- Peer %d ---" % int(id))
		_row(lines, "  Address", "%s:%s" % [p.get("address", ""), p.get("port", 0)] if reveal else hidden)
		_row(lines, "  Local port", p.get("local_port", 0) if reveal else hidden)
		_row(lines, "  Socket state", p.get("socket_state", -1))
		_row(lines, "  Connected ago", "%d ms" % int(p.get("connected_ago_ms", -1)))
		_row(lines, "  Queue", "%s / %d packets" % [_mem(float(p.get("queued_bytes", 0))), int(p.get("queued_packets", 0))])
		_add_net_stats(lines, "  Peer", p.get("stats", {}))

	# --- Replication state ---
	var objects: Dictionary = snap.get("objects", {})
	_row(lines, "Tracked objects", int(objects.get("tracked", 0)))
	_row(lines, "Object signatures", int(objects.get("signatures", 0)))
	_row(lines, "Last sent states", int(objects.get("last_sent_states", 0)))
	_row(lines, "Held objects", int(objects.get("held", 0)))
	var details: Array = objects.get("detail", [])
	if not details.is_empty():
		lines.append("--- Tracked objects (scale / mass / size / physics) ---")
		for entry in details:
			var d: Dictionary = entry
			var size_text: String = str(d.get("size", Vector3.ZERO)) if bool(d.get("has_size", false)) else "n/a"
			_row(lines, "  %s" % str(d.get("name", "?")), "holder=%s mass=%s scale=%s size=%s" % [
				d.get("holder", -1), _num(float(d.get("mass", 0.0)), 3),
				str(d.get("scale", Vector3.ZERO)), size_text,
			])
			_row(lines, "    physics", "grav=%s damp=%s/%s freeze=%s sleep=%s layer=%s mask=%s" % [
				_num(float(d.get("gravity_scale", 0.0)), 2), _num(float(d.get("linear_damp", 0.0)), 2),
				_num(float(d.get("angular_damp", 0.0)), 2), str(d.get("freeze", false)),
				str(d.get("sleeping", false)), d.get("collision_layer", 0), d.get("collision_mask", 0),
			])
			_row(lines, "    motion", "pos=%s vel=%s ang=%s" % [
				str(d.get("position", Vector3.ZERO)), str(d.get("linear_velocity", Vector3.ZERO)),
				str(d.get("angular_velocity", Vector3.ZERO)),
			])
	var players: Dictionary = snap.get("players", {})
	_row(lines, "Remote visuals", int(players.get("remote_visuals", 0)))
	_row(lines, "Remote states", int(players.get("remote_states", 0)))
	_row(lines, "Remote targets", int(players.get("remote_targets", 0)))
	_row(lines, "Holders (peer -> key)", str(snap.get("held_by", {})) if reveal else hidden)
	_row(lines, "Held keys -> peer", str(snap.get("holder_of", {})) if reveal else hidden)

	# --- Timing / tuning ---
	var accum: Dictionary = snap.get("accumulators", {})
	_row(lines, "Accumulators", "player=%s object=%s diff=%s full=%s keepalive=%s" % [
		_num(float(accum.get("player", 0.0)), 3), _num(float(accum.get("object", 0.0)), 3),
		_num(float(accum.get("diff", 0.0)), 3), _num(float(accum.get("full_state", 0.0)), 3),
		_num(float(accum.get("keepalive", 0.0)), 3),
	])
	var constants: Dictionary = snap.get("constants", {})
	_row(lines, "Rates", "player=%s object=%s diff=%s full=%s keepalive=%s Hz" % [
		constants.get("PLAYER_HZ", 0), constants.get("OBJECT_HZ", 0),
		constants.get("DIFF_HZ", 0), constants.get("FULL_STATE_HZ", 0),
		constants.get("KEEPALIVE_HZ", 0),
	])
	_row(lines, "Send / recv budget", "%s / %s per peer/frame" % [_mem(float(constants.get("SEND_BUDGET_PER_PEER", 0))), _mem(float(constants.get("RECV_BUDGET_PER_PEER", 0)))])
	_row(lines, "Limits", "queue=%s packet=%s msgs/read=%s accepts/frame=%s" % [
		_mem(float(constants.get("MAX_OUT_QUEUE", 0))), _mem(float(constants.get("MAX_PACKET", 0))),
		constants.get("MAX_MESSAGES_PER_READ", 0), constants.get("MAX_ACCEPTS_PER_FRAME", 0),
	])
	_row(lines, "Extrapolation cap", "%s s" % _num(float(constants.get("MAX_EXTRAPOLATION", 0.0)), 3))


func _add_net_stats(lines: PackedStringArray, label: String, stats: Variant) -> void:
	if not (stats is Dictionary):
		return
	var sent_msgs := int(stats.get("sent_msgs", 0))
	var sent_bytes := int(stats.get("sent_bytes", 0))
	var recv_msgs := int(stats.get("recv_msgs", 0))
	var recv_bytes := int(stats.get("recv_bytes", 0))
	var dropped := int(stats.get("dropped", 0))
	var now := Time.get_ticks_msec()
	var last_send := int(stats.get("last_send", 0))
	var last_recv := int(stats.get("last_recv", 0))
	_row(lines, label + " RTT", "%s ms" % _num(float(stats.get("rtt_ms", 0.0)), 1))
	_row(lines, label + " sent", "%d msgs / %s" % [sent_msgs, _mem(sent_bytes)])
	_row(lines, label + " received", "%d msgs / %s" % [recv_msgs, _mem(recv_bytes)])
	_row(lines, label + " superseded", dropped)
	_row(lines, label + " sent types", _join_types(stats.get("sent_types", {})))
	_row(lines, label + " recv types", _join_types(stats.get("recv_types", {})))
	_row(lines, label + " last send/recv", "%d / %d ms ago" % [
		now - last_send if last_send > 0 else -1,
		now - last_recv if last_recv > 0 else -1,
	])


func _join_types(types: Variant) -> String:
	if not (types is Dictionary) or (types as Dictionary).is_empty():
		return "-"
	var keys: Array = (types as Dictionary).keys()
	keys.sort()
	var parts := PackedStringArray()
	for key in keys:
		parts.append("%s=%d" % [str(key), int((types as Dictionary)[key])])
	return ", ".join(parts)


func _call_or(obj: Object, method: String, fallback: Variant) -> Variant:
	if obj != null and obj.has_method(method):
		return obj.call(method)
	return fallback


func _add_held_object(lines: PackedStringArray) -> void:
	_section(lines, "HELD OBJECT")
	var player: Node = null
	for node in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(node) and node is CharacterBody3D:
			player = node
			break
	if player == null:
		_row(lines, "Local player", "(no node in group 'player')")
		return
	_row(lines, "Local player", "%s [%s]" % [player.name, player.scene_file_path])

	var held = player.get("held_object")
	if not (is_instance_valid(held) and held is RigidBody3D):
		_row(lines, "Held object", "(none)")
		return
	var rigid := held as RigidBody3D
	var basis := rigid.global_transform.basis
	var mat: PhysicsMaterial = rigid.physics_material_override

	_row(lines, "Object", "%s [%s]" % [rigid.name, rigid.scene_file_path])
	_row(lines, "Class / RID", "%s / %s" % [rigid.get_class(), str(rigid.get_rid())])
	_row(lines, "Instance id", rigid.get_instance_id())
	_row(lines, "Script", rigid.get_script())
	_row(lines, "Groups", ", ".join(rigid.get_groups()))
	_row(lines, "Inside tree / visible", "%s / %s" % [str(rigid.is_inside_tree()), str(rigid.visible)])
	_row(lines, "Process mode", rigid.process_mode)
	_row(lines, "Children", rigid.get_child_count())

	lines.append("--- Transform / scale ---")
	_row(lines, "Global position", rigid.global_position)
	_row(lines, "Global rotation (deg)", rigid.global_rotation_degrees)
	_row(lines, "Global scale", basis.get_scale())
	_row(lines, "Local position", rigid.position)
	_row(lines, "Local rotation (deg)", rigid.rotation_degrees)
	_row(lines, "Local scale", rigid.scale)
	_row(lines, "Basis X", basis.x)
	_row(lines, "Basis Y", basis.y)
	_row(lines, "Basis Z", basis.z)
	_row(lines, "Global transform", rigid.global_transform)

	lines.append("--- Size / collision shapes ---")
	_row(lines, "Visual bounds size", _visual_bounds_size(rigid))
	_row(lines, "Collision shape owners", str(_call_or(rigid, "get_shape_owners", [])))
	_add_collision_shapes(lines, rigid)

	lines.append("--- Physics (all properties) ---")
	for name in PHYSICS_PROPERTY_NAMES:
		var value: Variant = _prop(rigid, name)
		if value == null:
			continue
		_row(lines, name, _format_value(name, value))
	if mat == null:
		_row(lines, "physics_material_override", "(default)")
	else:
		_row(lines, "physics_material_override", mat.resource_path if mat.resource_path != "" else mat.get_class())
		_row(lines, "  Friction", _num(float(mat.friction), 3))
		_row(lines, "  Bounce", _num(float(mat.bounce), 3))

	lines.append("--- Computed physics ---")
	_row(lines, "Linear speed", _num(rigid.linear_velocity.length(), 3))
	_row(lines, "Angular speed", _num(rigid.angular_velocity.length(), 3))
	_row(lines, "Freeze mode", _mode_label("freeze_mode", int(_prop(rigid, "freeze_mode", 0))))
	_row(lines, "Center of mass (effective)", _call_or(rigid, "get_center_of_mass", "n/a"))
	_row(lines, "Inertia tensor", _call_or(rigid, "get_inertia_tensor", _call_or(rigid, "get_inertia", "n/a")))
	_row(lines, "Inverse inertia tensor", _call_or(rigid, "get_inverse_inertia_tensor", "n/a"))
	_row(lines, "Contact count", _call_or(rigid, "get_contact_count", -1))
	_row(lines, "Collision exceptions", str(_call_or(rigid, "get_collision_exceptions", [])))

	var net := get_node_or_null("/root/Net")
	if net != null:
		var reveal := bool(_setting("debug_net_reveal_sensitive", false))
		var key := String(net.call("_key_for", rigid))
		var holders: Dictionary = net.get("_holder_of")
		_row(lines, "Net key", key if reveal else "<hidden>")
		_row(lines, "Holder peer", holders.get(key, -1))
		_row(lines, "Authority", "host" if int(net.get("role")) == 1 else "local prediction")


## Read a property only when the running Godot version actually has it. This
## avoids the "Invalid access to property" errors that killed the old report.
func _prop(obj: Object, name: String, fallback: Variant = null) -> Variant:
	if obj == null:
		return fallback
	for entry in obj.get_property_list():
		var info: Dictionary = entry
		if str(info.get("name", "")) == name:
			return obj.get(name)
	return fallback


func _mode_label(name: String, value: int) -> String:
	match name:
		"linear_damp_mode", "angular_damp_mode":
			return "REPLACE" if value == 0 else "ADD"
		"center_of_mass_mode":
			return "AUTO" if value == 0 else "CUSTOM"
		"freeze_mode":
			return "STATIC" if value == 0 else "KINEMATIC"
		"disable_mode":
			return ["REMOVE", "MAKE_STATIC", "KEEP_ACTIVE"][clampi(value, 0, 2)]
		"physics_interpolation_mode":
			return "OFF" if value == 0 else "ON"
	return "?"


func _format_value(name: String, value: Variant) -> String:
	if value is bool:
		return str(value)
	if value is int:
		if name.ends_with("_mode"):
			return "%d (%s)" % [int(value), _mode_label(name, int(value))]
		return str(value)
	if value is float:
		return _num(float(value), 4)
	if value is Vector3:
		var v := value as Vector3
		return "(%s, %s, %s)" % [_num(v.x, 3), _num(v.y, 3), _num(v.z, 3)]
	return str(value)


func _descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = []
	for child in node.get_children():
		result.append(child)
		result.append_array(_descendants(child))
	return result


func _visual_bounds_size(root: Node) -> String:
	var bounds := AABB()
	var found := false
	for node in _descendants(root):
		if not (node is MeshInstance3D):
			continue
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		var box: AABB = mesh.get_aabb()
		if not found:
			bounds = box
			found = true
		else:
			bounds = bounds.merge(box)
	if not found:
		return "(no mesh)"
	return "(%s, %s, %s)" % [_num(bounds.size.x, 3), _num(bounds.size.y, 3), _num(bounds.size.z, 3)]


func _add_collision_shapes(lines: PackedStringArray, root: Node) -> void:
	var count := 0
	for node in _descendants(root):
		if not (node is CollisionShape3D):
			continue
		var shape_node := node as CollisionShape3D
		count += 1
		_row(lines, "  Shape %d (%s)" % [count, shape_node.name], "%s disabled=%s" % [_shape_info(shape_node.shape), str(shape_node.disabled)])
		if shape_node.transform != Transform3D.IDENTITY:
			_row(lines, "    Shape transform", shape_node.transform)
	if count == 0:
		_row(lines, "  Collision shapes", "(none)")


func _shape_info(shape: Shape3D) -> String:
	if shape == null:
		return "(no shape)"
	match shape.get_class():
		"BoxShape3D":
			return "Box size=%s" % str(shape.get("size"))
		"SphereShape3D":
			return "Sphere radius=%s" % _num(float(shape.get("radius")), 3)
		"CapsuleShape3D", "CylinderShape3D":
			return "%s radius=%s height=%s" % [shape.get_class(), _num(float(shape.get("radius")), 3), _num(float(shape.get("height")), 3)]
		"ConvexPolygonShape3D":
			var points: Variant = shape.get("points")
			return "Convex points=%d" % (0 if points == null else (points as PackedVector3Array).size())
		"ConcavePolygonShape3D":
			var data: Variant = shape.get("data")
			return "Concave vertices=%d" % (0 if data == null else (data as PackedVector3Array).size())
		"HeightMapShape3D":
			return "HeightMap width=%s depth=%s" % [str(shape.get("width")), str(shape.get("depth"))]
		"WorldBoundaryShape3D":
			return "WorldBoundary normal=%s distance=%s" % [str(shape.get("normal")), str(shape.get("distance"))]
		_:
			return shape.get_class()


func _add_scene(lines: PackedStringArray) -> void:
	_section(lines, "SCENE TREE")
	var tree := get_tree()
	var scene := tree.current_scene
	_row(lines, "Current scene", scene.scene_file_path if scene != null else "(none)")
	_row(lines, "Scene root", scene.name if scene != null else "(none)")
	_row(lines, "Tree paused", tree.paused)
	_row(lines, "Node count", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_row(lines, "Root children", tree.root.get_child_count())
	if scene != null:
		var children := PackedStringArray()
		for child in scene.get_children():
			children.append(child.name)
		_row(lines, "Scene children", ", ".join(children))
	var viewport := get_viewport()
	if viewport.has_method("get_camera_2d"):
		var cam_2d = viewport.call("get_camera_2d")
		if cam_2d != null:
			_row(lines, "Camera2D", "%s @ %s zoom %s" % [cam_2d.name, str(cam_2d.global_position), str(cam_2d.zoom)])
	if viewport.has_method("get_camera_3d"):
		var cam_3d = viewport.call("get_camera_3d")
		if cam_3d != null:
			_row(lines, "Camera3D", "%s @ %s" % [cam_3d.name, str(cam_3d.global_position)])


func _average(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _minimum(values: PackedFloat32Array) -> float:
	var result := INF
	for value in values:
		result = minf(result, value)
	return result if result != INF else 0.0


func _maximum(values: PackedFloat32Array) -> float:
	var result := -INF
	for value in values:
		result = maxf(result, value)
	return result if result != -INF else 0.0
