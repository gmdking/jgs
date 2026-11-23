extends CanvasLayer
## Configurable crosshair overlay. It is hidden whenever the mouse is visible,
## so menus and the pause screen never show it. The shader samples the screen
## behind the crosshair when inversion is enabled.

var drawable: ColorRect
var shader_material: ShaderMaterial

@onready var settings: Variant = get_node("/root/Settings")


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS

	var shader := load("res://gui/crosshair.gdshader") as Shader
	shader_material = ShaderMaterial.new()
	shader_material.shader = shader

	drawable = ColorRect.new()
	drawable.color = Color.WHITE
	drawable.set_anchors_preset(Control.PRESET_FULL_RECT)
	drawable.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drawable.material = shader_material
	add_child(drawable)

	settings.changed.connect(_on_settings_changed)
	_sync_shader()


func _process(_delta: float) -> void:
	var should_show := (
		Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE
		and int(settings.get_value("crosshair_style")) != 0
	)
	if visible != should_show:
		visible = should_show


func _sync_shader() -> void:
	if shader_material == null:
		return
	var style := clampi(int(settings.get_value("crosshair_style")), 0, 4)
	shader_material.set_shader_parameter("style", style)

	var color: Color = settings.get_value("crosshair_color")
	if not color is Color:
		color = Color.WHITE
	shader_material.set_shader_parameter("cross_color", color)

	var size := clampf(float(settings.get_value("crosshair_size")), 2.0, 64.0)
	var thick := clampf(float(settings.get_value("crosshair_thickness")), 1.0, 8.0)
	var center_gap := clampf(float(settings.get_value("crosshair_gap")), 0.0, 32.0)
	shader_material.set_shader_parameter("cross_size", size)
	shader_material.set_shader_parameter("thickness", thick)
	shader_material.set_shader_parameter("gap", center_gap)
	shader_material.set_shader_parameter("inverted", bool(settings.get_value("crosshair_inverted")))


func _on_settings_changed(key: String, _value: Variant) -> void:
	if str(key).begins_with("crosshair") or key == "__all__":
		_sync_shader()
