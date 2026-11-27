extends CanvasLayer
## In-game settings screen. Built in code so it stays in sync with the
## Settings autoload and needs no hand-maintained scene wiring.

signal closed

var settings: Variant
var tabs: TabContainer
var first_focus: Control
var rebind_action := StringName()
var rebind_button: Button
var rebind_slot := 0
var listening := false

@onready var ui_sounds: Variant = get_node("/root/UISounds")

var sliders: Dictionary = {}
var slider_labels: Dictionary = {}
var slider_inputs: Dictionary = {}
var checks: Dictionary = {}
var options: Dictionary = {}
var option_values: Dictionary = {}
var option_inputs: Dictionary = {}
var color_buttons: Dictionary = {}
var control_buttons: Dictionary = {}
var secondary_buttons: Dictionary = {}
var clear_secondary_buttons: Dictionary = {}
var gameplay_buttons: Array[Button] = []

const CROSSHAIR_STYLES := ["Off", "Dot", "Cross", "Ring", "Open Cross"]
const RESOLUTION_LABELS := ["Native", "1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160"]
const DEBUG_SECTIONS := [
	["timing", "Frame timing"],
	["monitors", "Performance monitors"],
	["rendering", "Rendering"],
	["memory", "Memory"],
	["physics", "Physics servers"],
	["audio", "Audio"],
	["input", "Input"],
	["display", "Display"],
	["engine", "Engine / OS"],
	["scene", "Scene tree"],
	["network", "Multiplayer / network"],
	["held_object", "Held object"],
]
const DEBUG_GAMEPLAY_KEYS := [
	"debug_gravity", "debug_game_speed", "debug_walk_speed", "debug_sprint_speed",
	"debug_jump_strength", "debug_pickup_range", "debug_hold_distance", "debug_physics_ticks",
	"debug_keep_physics_during_pause",
]
const FPS_VALUES := [0, 30, 60, 120, 144, 240]
const CUSTOM_VALUE := "__custom__"

const ACTION_NAMES := {
	"forward": "Move Forward", "backward": "Move Backward", "left": "Move Left", "right": "Move Right",
	"jump": "Jump", "sprint": "Sprint", "sprint2": "Super Sprint",
	"pickup": "Pick Up", "drop": "Put Down", "dupl": "Duplicate Object", "del": "Delete Object",
	"pause": "Pause Menu", "look_left": "Look Left", "look_right": "Look Right",
	"look_up": "Look Up", "look_down": "Look Down", "scaleup": "Scale Up", "scaledown": "Scale Down",
}


func _ready() -> void:
	# The settings screen is also opened from the pause menu, so it must keep
	# processing input while the rest of the SceneTree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 10
	visible = false
	settings = get_node("/root/Settings")
	_build_ui()
	_wire_ui_sounds()


func _build_ui() -> void:
	var theme := Theme.new()
	theme.default_font = load("res://gui/sources/Frutiger.ttf")
	theme.default_font_size = 20

	var panel := PanelContainer.new()
	panel.theme = theme
	panel.anchor_left = 0.08
	panel.anchor_top = 0.06
	panel.anchor_right = 0.92
	panel.anchor_bottom = 0.94
	add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	margin.add_child(column)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 42)
	column.add_child(title)

	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(tabs)

	_build_audio_tab(_tab("Audio"))
	_build_graphics_tab(_tab("Graphics"))
	_build_customization_tab(_tab("Customization"))
	_build_controls_tab(_tab("Controls"))
	_build_debug_tab(_tab("Debug"))
	_build_help_tab(_tab("Help"))

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 16)
	column.add_child(buttons)

	var reset_all := Button.new()
	reset_all.text = "Reset Everything"
	reset_all.pressed.connect(_on_reset_all)
	buttons.add_child(reset_all)

	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(close)
	buttons.add_child(back)


func _tab(tab_name: String) -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)
	return content


func _build_audio_tab(parent: Control) -> void:
	var heading := Label.new()
	heading.text = "Volume"
	heading.add_theme_font_size_override("font_size", 26)
	parent.add_child(heading)

	first_focus = _add_slider(parent, "Music volume", "music_volume", 0.0, 1.0, 0.01, "%")
	_add_slider(parent, "Sound effects", "sfx_volume", 0.0, 1.0, 0.01, "%")
	_add_check(parent, "Mute all audio", "mute")


func _build_graphics_tab(parent: Control) -> void:
	_add_section(parent, "Renderer")
	_add_option(parent, "Rendering method", "renderer", ["Forward+", "Mobile", "Compatibility"], ["forward_plus", "mobile", "gl_compatibility"])
	var restart_note := Label.new()
	restart_note.text = "Renderer changes require a restart."
	restart_note.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	parent.add_child(restart_note)

	_add_section(parent, "Display")
	_add_option(parent, "Window mode", "window_mode", ["Windowed", "Fullscreen", "Exclusive Fullscreen"])
	_add_check(parent, "Borderless window", "borderless")
	_add_check(parent, "Always on top", "always_on_top")
	_add_option(parent, "Resolution", "resolution", RESOLUTION_LABELS + ["Custom"], RESOLUTION_LABELS + [CUSTOM_VALUE])
	_add_option(parent, "VSync", "vsync", ["Off", "Enabled", "Adaptive", "Mailbox"])
	var fps_labels := []
	for fps in FPS_VALUES:
		fps_labels.append("Unlimited" if int(fps) == 0 else "%d FPS" % int(fps))
	_add_option(parent, "Frame rate limit", "fps_limit", fps_labels, FPS_VALUES + [-1])
	_add_check(parent, "Low processor mode", "low_processor")

	_add_section(parent, "Rendering")
	_add_slider(parent, "3D render scale", "render_scale", 0.5, 2.0, 0.05, "x")
	_add_option(parent, "Upscaling mode", "scaling_mode", ["Bilinear", "FSR", "FSR2", "MetalFX Spatial", "MetalFX Temporal", "Nearest"])
	_add_option(parent, "3D MSAA", "msaa", ["Disabled", "2x", "4x", "8x"])
	_add_option(parent, "2D MSAA", "msaa_2d", ["Disabled", "2x", "4x", "8x"])
	_add_check(parent, "Temporal AA", "taa")
	_add_option(parent, "Screen-space AA", "screen_space_aa", ["Disabled", "FXAA", "SMAA"])
	_add_check(parent, "Debanding", "debanding")
	_add_check(parent, "Shadows", "shadows")
	_add_option(parent, "Shadow atlas size", "shadow_atlas_size", ["Off", "512", "1024", "2048", "4096", "8192"], [0, 512, 1024, 2048, 4096, 8192])

	_add_section(parent, "Environment effects")
	_add_check(parent, "Glow / Bloom", "glow")
	_add_check(parent, "SSAO", "ssao")
	_add_check(parent, "SSIL", "ssil")
	_add_check(parent, "SDFGI", "sdfgi")
	_add_check(parent, "Distance fog", "fog")


func _build_customization_tab(parent: Control) -> void:
	_add_section(parent, "Crosshair")
	_add_option(parent, "Style", "crosshair_style", CROSSHAIR_STYLES)
	_add_check(parent, "Invert colors (Nullifies your color!)", "crosshair_inverted")
	_add_color(parent, "Color", "crosshair_color")
	_add_slider(parent, "Size", "crosshair_size", 2.0, 64.0, 1.0, "px")
	_add_slider(parent, "Thickness", "crosshair_thickness", 1.0, 8.0, 1.0, "px")
	_add_slider(parent, "Center gap", "crosshair_gap", 0.0, 32.0, 1.0, "px")

	var note := Label.new()
	note.text = "Choose 'Off' as your crosshair to hide it."
	note.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	parent.add_child(note)
	
	_add_section(parent, "External Integrations")
	_add_check(parent, "Discord Rich Presence", "discord_rich_presence")

func _build_controls_tab(parent: Control) -> void:
	var info := Label.new()
	info.text = "Select Primary or Secondary, then press a key, mouse button, or controller input. Press ESC to cancel."
	info.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	parent.add_child(info)

	for action in settings.get_actions():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		parent.add_child(row)

		var label := Label.new()
		label.text = str(ACTION_NAMES.get(str(action), str(action))) + ":"
		label.custom_minimum_size.x = 220
		row.add_child(label)

		var primary := Button.new()
		primary.text = str(settings.binding_display(action, 0))
		primary.custom_minimum_size.x = 260
		primary.pressed.connect(_on_rebind_pressed.bind(action, primary, 0))
		row.add_child(primary)
		control_buttons[action] = primary

		var secondary := Button.new()
		secondary.text = str(settings.binding_display(action, 1))
		secondary.custom_minimum_size.x = 260
		secondary.pressed.connect(_on_rebind_pressed.bind(action, secondary, 1))
		row.add_child(secondary)
		secondary_buttons[action] = secondary

		var clear := Button.new()
		clear.text = "Clear"
		clear.disabled = settings.binding_display(action, 1) == "Unbound"
		clear.pressed.connect(_on_clear_secondary.bind(action))
		row.add_child(clear)
		clear_secondary_buttons[action] = clear

	_add_section(parent, "Gameplay feel")
	_add_slider(parent, "Mouse sensitivity", "mouse_sensitivity", 0.0002, 0.01, 0.0001, "sens")
	_add_slider(parent, "Controller sensitivity", "controller_sensitivity", 0.5, 10.0, 0.1, "sens")

	var reset := Button.new()
	reset.text = "Reset Controls to Default"
	reset.pressed.connect(_on_reset_controls)
	parent.add_child(reset)
	
func _build_debug_tab(parent: Control) -> void:
	_add_section(parent, "Debug overlay")
	_add_check(parent, "Show overlay on startup", "debug_overlay_startup")
	_add_check(parent, "Show frame graph", "debug_graph")
	_add_slider(parent, "Refresh interval", "debug_refresh_interval", 0.05, 1.0, 0.05, "s")

	var toggle := Button.new()
	toggle.text = "Toggle overlay (F3)"
	toggle.pressed.connect(_on_debug_toggle)
	parent.add_child(toggle)

	var copy_report := Button.new()
	copy_report.text = "Copy debug report to clipboard"
	copy_report.pressed.connect(_on_debug_copy)
	parent.add_child(copy_report)

	var reset := Button.new()
	reset.text = "Reset frame history"
	reset.pressed.connect(_on_debug_reset)
	parent.add_child(reset)

	_add_section(parent, "Overlay sections")
	for entry in DEBUG_SECTIONS:
		_add_check(parent, str(entry[1]), "debug_show_" + str(entry[0]))

	_add_section(parent, "Multiplayer privacy")
	_add_check(parent, "Reveal IPs, ports & local paths", "debug_net_reveal_sensitive")

	_add_section(parent, "Gameplay tuning")
	_add_check(parent, "Keep physics running while paused", "debug_keep_physics_during_pause")
	_add_slider(parent, "Gravity", "debug_gravity", -1000.0, 1000.0, 0.1, "m/s")
	_add_slider(parent, "Game speed", "debug_game_speed", -20.0, 20.0, 0.05, "x")
	_add_slider(parent, "Walk speed", "debug_walk_speed", -500.0, 500.0, 0.5, "m/s")
	_add_slider(parent, "Sprint speed", "debug_sprint_speed", -1000.0, 1000.0, 1.0, "m/s")
	_add_slider(parent, "Jump strength", "debug_jump_strength", -500.0, 500.0, 0.5, "m/s")
	_add_slider(parent, "Pickup range", "debug_pickup_range", -100.0, 100.0, 0.5, "m")
	_add_slider(parent, "Hold distance", "debug_hold_distance", -100.0, 100.0, 0.5, "m")
	_add_slider(parent, "Physics ticks", "debug_physics_ticks", 1.0, 1000.0, 1.0, "Hz")

	var presets := HBoxContainer.new()
	for speed in [-2.0, 0.0, 0.25, 1.0, 2.0]:
		var preset := Button.new()
		preset.text = "Freeze" if is_equal_approx(float(speed), 0.0) else "%sx" % str(speed)
		preset.pressed.connect(_on_game_speed_preset.bind(float(speed)))
		presets.add_child(preset)
		gameplay_buttons.append(preset)
	parent.add_child(presets)

	var reset_gameplay := Button.new()
	reset_gameplay.text = "Reset gameplay tuning"
	reset_gameplay.pressed.connect(_on_debug_reset_gameplay)
	parent.add_child(reset_gameplay)
	gameplay_buttons.append(reset_gameplay)

	var note := Label.new()
	note.text = "Gameplay values apply immediately. In multiplayer the host controls them. Physics will never pause when playing multiplayer."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 0.0
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	parent.add_child(note)


func _debug_menu() -> Node:
	return get_node_or_null("/root/DebugMenu")


func _on_debug_toggle() -> void:
	var debug := _debug_menu()
	if debug != null:
		debug.call("toggle_menu")


func _on_debug_copy() -> void:
	var debug := _debug_menu()
	if debug != null:
		debug.call("copy_snapshot")


func _on_debug_reset() -> void:
	var debug := _debug_menu()
	if debug != null:
		debug.call("reset_history")


func _on_debug_reset_gameplay() -> void:
	settings.reset_keys(DEBUG_GAMEPLAY_KEYS)
	_refresh_inputs()


func _on_game_speed_preset(value: float) -> void:
	settings.set_value("debug_game_speed", value)
	var slider: HSlider = sliders.get("debug_game_speed")
	if slider != null:
		slider.value = value
	_refresh_inputs()


func _build_help_tab(parent: Control) -> void:
	var help_lines := PackedStringArray([
		"CONTROLS",
		"",
		"Keyboard & mouse",
		"  Look around .......... Move the mouse",
		"  Move ................. WASD / Arrow keys",
		"  Jump ................. Space",
		"  Sprint ............... Shift",
		"  Super sprint ......... Shift + Ctrl",
		"  Pick up / put down ... E / Left click, Q / Right click",
		"  Duplicate / delete ... 1 or T / 0 or B",
		"  Scale objects ........ Mouse wheel",
		"  Pause menu ........... Esc",
		"",
		"Controller",
		"  Look around .......... Right thumbstick",
		"  Move ................. Left thumbstick / D-pad",
		"  Jump ................. A / B",
		"  Sprint ............... Y",
		"  Super sprint ......... Y + X",
		"  Pick up / put down ... Left trigger / Right trigger",
		"  Duplicate / delete ... Left bumper + stick click / Right bumper + stick click",
		"  Scale objects ........ D-pad Up + Down",
		"  Pause menu ........... Menu button",
		"",
		"Debug",
		"  F3 toggles the debug overlay (FPS, frametimes, and every available",
		"  performance counter). PgUp/PgDn scroll it, Esc closes it.",
		"  The Debug tab also tunes gravity, game speed, movement, and physics ticks.",
		"",
		"All game controls can be rebound in the Controls tab, with optional Primary and Secondary slots.",
	])
	var text := RichTextLabel.new()
	text.scroll_active = false
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text.text = "\n".join(help_lines)
	parent.add_child(text)


func _add_section(parent: Control, title: String) -> void:
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
	parent.add_child(label)


func _add_slider(parent: Control, text: String, key: String, min_value: float, max_value: float, step: float, suffix: String) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 230
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = float(settings.get_value(key))
	slider.custom_minimum_size.x = 300
	slider.value_changed.connect(_on_slider_changed.bind(key))
	row.add_child(slider)
	sliders[key] = slider

	var value_input := LineEdit.new()
	value_input.text = _format_value(slider.value, suffix)
	value_input.custom_minimum_size.x = 110
	value_input.tooltip_text = "Type a value and press Enter"
	value_input.text_submitted.connect(_on_slider_text_submitted.bind(key, min_value, max_value, suffix, value_input))
	value_input.focus_exited.connect(_on_slider_text_committed.bind(key, min_value, max_value, suffix, value_input))
	row.add_child(value_input)
	slider_labels[key] = value_input
	slider_inputs[key] = value_input
	slider.value_changed.connect(_on_slider_label.bind(value_input, suffix))
	return slider


func _add_check(parent: Control, text: String, key: String) -> CheckButton:
	var check := CheckButton.new()
	check.text = text
	check.button_pressed = bool(settings.get_value(key))
	check.toggled.connect(_on_check_toggled.bind(key))
	parent.add_child(check)
	checks[key] = check
	return check


func _add_option(parent: Control, text: String, key: String, items: Array, values: Array = []) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 230
	row.add_child(label)

	var option := OptionButton.new()
	for item in items:
		option.add_item(str(item))
	if values.is_empty():
		option.selected = clampi(int(settings.get_value(key)), 0, option.item_count - 1)
	else:
		option_values[key] = values
		var current := values.find(settings.get_value(key))
		if current >= 0:
			option.selected = current
	option.item_selected.connect(_on_option_selected.bind(key))
	option.custom_minimum_size.x = 300
	row.add_child(option)
	options[key] = option

	if key == "resolution" or key == "fps_limit":
		var input := LineEdit.new()
		input.text = str(settings.get_value(key))
		input.custom_minimum_size.x = 140
		input.tooltip_text = "Type a custom value and press Enter"
		input.text_submitted.connect(_on_option_text_submitted.bind(key, input))
		input.focus_exited.connect(_on_option_text_committed.bind(key, input))
		row.add_child(input)
		option_inputs[key] = input
		_sync_option_from_value(key)
	return option


func _add_color(parent: Control, text: String, key: String) -> ColorPickerButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 230
	row.add_child(label)

	var picker := ColorPickerButton.new()
	var color: Color = settings.get_value(key)
	if color is Color:
		picker.color = color
	picker.custom_minimum_size.x = 140
	picker.color_changed.connect(_on_color_changed.bind(key))
	row.add_child(picker)
	color_buttons[key] = picker
	return picker


func _format_value(value: float, suffix: String) -> String:
	match suffix:
		"%": return "%d%%" % int(value * 100.0)
		"x": return "%.2fx" % value
		"s": return "%.2fs" % value
		"sens": return "%.4f" % value
		"px": return "%d px" % int(value)
		"m/s": return "%.2f m/s" % value
		"m": return "%.2f m" % value
		"Hz": return "%d Hz" % int(value)
	return "%.2f" % value


func _on_slider_changed(value: float, key: String) -> void:
	settings.set_value(key, value)


func _on_slider_label(value: float, label: LineEdit, suffix: String) -> void:
	label.text = _format_value(value, suffix)


func _on_slider_text_submitted(_text: String, key: String, min_value: float, max_value: float, suffix: String, input: LineEdit) -> void:
	_apply_slider_text(key, min_value, max_value, suffix, input)


func _on_slider_text_committed(key: String, min_value: float, max_value: float, suffix: String, input: LineEdit) -> void:
	_apply_slider_text(key, min_value, max_value, suffix, input)


func _apply_slider_text(key: String, min_value: float, max_value: float, suffix: String, input: LineEdit) -> void:
	var slider: HSlider = sliders.get(key)
	if slider == null:
		return
	var text := input.text.strip_edges().replace("m/s", "").replace("Hz", "").replace("sens", "").replace("%", "").replace("x", "").replace("s", "").replace("m", "").replace(",", "").strip_edges()
	if text.is_empty():
		input.text = _format_value(slider.value, suffix)
		return
	var value := text.to_float()
	if suffix == "%":
		value /= 100.0
	slider.value = clampf(value, min_value, max_value)
	input.text = _format_value(slider.value, suffix)


func _on_check_toggled(pressed: bool, key: String) -> void:
	settings.set_value(key, pressed)


func _on_color_changed(color: Color, key: String) -> void:
	settings.set_value(key, color)


func _on_option_selected(index: int, key: String) -> void:
	var values: Array = option_values.get(key, [])
	if not values.is_empty() and index >= 0 and index < values.size():
		var value: Variant = values[index]
		# The trailing "Custom" entry just keeps the typed value as-is.
		if str(value) == CUSTOM_VALUE or (value is int and int(value) < 0):
			return
		settings.set_value(key, value)
	else:
		settings.set_value(key, index)
	if option_inputs.has(key):
		option_inputs[key].text = str(settings.get_value(key))


func _on_option_text_submitted(_text: String, key: String, input: LineEdit) -> void:
	_apply_option_text(key, input)


func _on_option_text_committed(key: String, input: LineEdit) -> void:
	_apply_option_text(key, input)


func _apply_option_text(key: String, input: LineEdit) -> void:
	var text := input.text.strip_edges()
	match key:
		"resolution":
			var parts := text.split("x")
			if parts.size() != 2:
				input.text = str(settings.get_value("resolution"))
				return
			var width := int(parts[0].strip_edges())
			var height := int(parts[1].strip_edges())
			if width < 320 or height < 240 or width > 8192 or height > 8192:
				input.text = str(settings.get_value("resolution"))
				return
			var value := "%dx%d" % [width, height]
			settings.set_value("resolution", value)
			input.text = value
		"fps_limit":
			var fps := clampi(int(text), 0, 1000)
			settings.set_value("fps_limit", fps)
			input.text = str(fps)
	_sync_option_from_value(key)


func _sync_option_from_value(key: String) -> void:
	var option: OptionButton = options.get(key)
	if option == null or option.item_count == 0:
		return
	var index := -1
	match key:
		"resolution":
			var label := str(settings.get_value("resolution"))
			index = RESOLUTION_LABELS.find(label)
			if index < 0:
				index = option.item_count - 1
				option.set_item_text(index, "Custom: " + label)
		"fps_limit":
			var fps := int(settings.get_value("fps_limit"))
			index = FPS_VALUES.find(fps)
			if index < 0:
				index = option.item_count - 1
				option.set_item_text(index, "Custom: %d FPS" % fps)
	if index >= 0 and index < option.item_count:
		option.selected = index


func _wire_ui_sounds() -> void:
	for control in _collect_controls(self):
		if control is Button or control is Slider or control is LineEdit or control is TabBar:
			control.mouse_entered.connect(_play_hover)
			control.focus_entered.connect(_play_hover)
		if control is OptionButton:
			control.item_selected.connect(_play_click_arg)
		elif control is Button:
			control.pressed.connect(_play_click)
		if control is Slider:
			control.value_changed.connect(_play_hover_arg)
		if control is LineEdit:
			control.text_submitted.connect(_play_click_arg)
		if control is TabBar:
			control.tab_changed.connect(_play_click_arg)


func _collect_controls(node: Node) -> Array[Control]:
	var result: Array[Control] = []
	for child in node.get_children():
		if child is Control:
			result.append(child)
		result.append_array(_collect_controls(child))
	return result


func _play_hover() -> void:
	ui_sounds.play_hover()


func _play_click() -> void:
	ui_sounds.play_click()


func _play_click_arg(_unused: Variant) -> void:
	ui_sounds.play_click()


func _play_hover_arg(_unused: Variant) -> void:
	ui_sounds.play_hover()


func _on_rebind_pressed(action: StringName, button: Button, slot: int) -> void:
	if listening and rebind_button != null:
		rebind_button.text = str(settings.binding_display(rebind_action, rebind_slot))
	rebind_action = action
	rebind_button = button
	rebind_slot = slot
	listening = true
	button.text = "Press a key / button..."
	button.grab_focus()


func _on_clear_secondary(action: StringName) -> void:
	settings.clear_binding(action, 1)
	_refresh_controls()


func _on_reset_controls() -> void:
	settings.reset_controls()
	_refresh_controls()


func _on_reset_all() -> void:
	settings.reset_all()
	_refresh_controls()
	_refresh_inputs()


func _refresh_controls() -> void:
	for action in control_buttons.keys():
		var primary: Button = control_buttons[action]
		primary.text = str(settings.binding_display(action, 0))
		var secondary: Button = secondary_buttons.get(action)
		if secondary != null:
			secondary.text = str(settings.binding_display(action, 1))
		var clear: Button = clear_secondary_buttons.get(action)
		if clear != null:
			clear.disabled = settings.binding_display(action, 1) == "Unbound"


func _refresh_inputs() -> void:
	for key in sliders.keys():
		var slider: HSlider = sliders[key]
		slider.value = float(settings.get_value(key))
		if slider_labels.has(key):
			var label: LineEdit = slider_labels[key]
			label.text = _format_value(slider.value, _suffix_for(key))
	for key in checks.keys():
		var check: CheckButton = checks[key]
		check.button_pressed = bool(settings.get_value(key))
	for key in color_buttons.keys():
		var picker: ColorPickerButton = color_buttons[key]
		picker.color = settings.get_value(key) as Color
	for key in options.keys():
		if key == "resolution" or key == "fps_limit":
			_sync_option_from_value(key)
			if option_inputs.has(key):
				option_inputs[key].text = str(settings.get_value(key))
		else:
			var option: OptionButton = options[key]
			option.selected = clampi(int(settings.get_value(key)), 0, option.item_count - 1)
	_update_gameplay_lock()


## Only the host may tune gameplay during a multiplayer session. Clients get
## the host's values as in-memory session overrides and cannot edit them.
func _update_gameplay_lock() -> void:
	var locked := settings != null and bool(settings.call("is_gameplay_locked"))
	for key in DEBUG_GAMEPLAY_KEYS:
		var slider = sliders.get(key)
		if slider != null:
			slider.editable = not locked
			slider.scrollable = not locked
		var input = slider_inputs.get(key)
		if input != null:
			input.editable = not locked
		var check = checks.get(key)
		if check != null:
			check.disabled = locked
	for button in gameplay_buttons:
		button.disabled = locked


func _suffix_for(key: String) -> String:
	match key:
		"music_volume", "sfx_volume": return "%"
		"render_scale", "debug_game_speed": return "x"
		"debug_refresh_interval": return "s"
		"debug_gravity", "debug_walk_speed", "debug_sprint_speed", "debug_jump_strength": return "m/s"
		"debug_pickup_range", "debug_hold_distance": return "m"
		"debug_physics_ticks": return "Hz"
		"mouse_sensitivity", "controller_sensitivity": return "sens"
		"crosshair_size", "crosshair_thickness", "crosshair_gap": return "px"
	return ""


func show_settings() -> void:
	visible = true
	_update_gameplay_lock()
	if first_focus != null:
		first_focus.grab_focus()


func hide_settings() -> void:
	listening = false
	rebind_button = null
	rebind_action = StringName()
	rebind_slot = 0
	visible = false


func close() -> void:
	hide_settings()
	closed.emit()


func _input(event: InputEvent) -> void:
	if not visible:
		return

	if listening:
		var cancel_rebind: bool = event.is_action_pressed("pause") or (
			event is InputEventKey and (event as InputEventKey).keycode == KEY_ESCAPE and event.pressed
		)
		if cancel_rebind:
			_cancel_rebind()
			get_viewport().set_input_as_handled()
			return
		if settings.is_rebindable(event):
			settings.set_binding(rebind_action, rebind_slot, event)
			_cancel_rebind()
			get_viewport().set_input_as_handled()
		return

	var close_requested: bool = event.is_action_pressed("pause") or (
		event is InputEventKey and (event as InputEventKey).keycode == KEY_ESCAPE and event.pressed and not event.is_echo()
	)
	if close_requested:
		close()
		get_viewport().set_input_as_handled()


func _cancel_rebind() -> void:
	if rebind_button != null:
		rebind_button.text = str(settings.binding_display(rebind_action, rebind_slot))
	listening = false
	rebind_button = null
	rebind_action = StringName()
	rebind_slot = 0
