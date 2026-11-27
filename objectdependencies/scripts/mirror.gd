extends RigidBody3D
## A live planar mirror.
##
## The SubViewport renders the world from a camera placed at the reflected
## position of the viewer's camera. Its texture is drawn on the glass with an
## unshaded spatial shader, so the surface shows the scene instead of a flat
## colour. The mirror's own meshes live on visual layer 20, which the
## reflection camera does not render, so mirrors never reflect themselves.

const MIRROR_VISUAL_LAYER := 20
const USER_VISUAL_LAYERS := 0x000FFFFF
const CLIP_LAYER_BIT := 1 << (MIRROR_VISUAL_LAYER - 1)

@export var reflection_resolution: Vector2i = Vector2i(512, 384)
@export var reflection_tint: Color = Color(1, 1, 1, 1)
@export var stay_upright: bool = true
@export var update_when_offscreen: bool = false

@onready var _viewport: SubViewport = $ReflectionViewport
@onready var _reflection_camera: Camera3D = $ReflectionViewport/ReflectionCamera
@onready var _glass: MeshInstance3D = $Glass
@onready var _frame: MeshInstance3D = $Frame

var _last_screen_size := Vector2i.ZERO
# Visuals temporarily moved to the mirror layer so the reflection camera skips
# them. The regular camera still renders layer 20, so they stay visible normally.
var _hidden_visuals: Dictionary = {}


func _ready() -> void:
	# Mirrors should no longer stay put. Yay!
	# set_meta("no_pickup", true)
	lock_rotation = stay_upright
	reflection_resolution = Vector2i(maxi(reflection_resolution.x, 2), maxi(reflection_resolution.y, 2))
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_reflection_camera.current = true
	_reflection_camera.cull_mask = USER_VISUAL_LAYERS & ~(1 << (MIRROR_VISUAL_LAYER - 1))

	# Keep the mirror out of its own reflection. Regular cameras still see
	# layer 20 because their default cull mask covers all user layers.
	var mirror_bit := 1 << (MIRROR_VISUAL_LAYER - 1)
	_glass.layers = mirror_bit
	_frame.layers = mirror_bit

	# Duplicate the material so each spawned mirror samples its own viewport.
	var glass_material := _glass.get_active_material(0) as ShaderMaterial
	if glass_material != null:
		glass_material = glass_material.duplicate() as ShaderMaterial
		_glass.set_surface_override_material(0, glass_material)
		glass_material.set_shader_parameter("mirror_texture", _viewport.get_texture())
		glass_material.set_shader_parameter("tint", reflection_tint)


func _process(_delta: float) -> void:
	# Restore last frame's hidden visuals before the next reflection is built.
	_restore_hidden_visuals()

	var screen_size: Vector2i = get_viewport().size
	if screen_size != _last_screen_size:
		_last_screen_size = screen_size
		_update_reflection_size(screen_size)

	var viewer := get_viewport().get_camera_3d()
	if viewer == null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return

	# The front of the glass is the mirror's local +Z axis. No point rendering
	# a reflection when the viewer is behind it or the mirror is off screen.
	var to_viewer := viewer.global_position - global_position
	if to_viewer.dot(global_transform.basis.z) <= 0.0:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	if not update_when_offscreen and not viewer.is_position_in_frustum(global_position):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return

	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_copy_camera_settings(viewer)

	# Work in mirror space: the reflecting surface is the local z = 0 plane.
	var viewer_local := global_transform.affine_inverse() * viewer.global_transform
	_reflection_camera.global_transform = global_transform * _reflect_across_glass(viewer_local)

	# The reflection camera sits behind the glass. Anything else behind that
	# plane would appear in front of it in the render, so keep it out of the
	# reflection while leaving it on screen for the normal camera.
	_hide_visuals_behind_glass()


func _exit_tree() -> void:
	_restore_hidden_visuals()


func _restore_hidden_visuals() -> void:
	for entry in _hidden_visuals.values():
		var node: Node = entry.get("node")
		if is_instance_valid(node):
			node.layers = int(entry.get("layers"))
	_hidden_visuals.clear()


func _hide_visuals_behind_glass() -> void:
	# Hidden objects only sit on layer 20 during the reflection render. Make
	# sure normal lights still affect them in the main view.
	for light in get_tree().root.find_children("*", "Light3D", true, false):
		var light_layers: int = light.layers
		if (light_layers & CLIP_LAYER_BIT) == 0:
			light.layers = light_layers | CLIP_LAYER_BIT

	var front := global_transform.basis.z
	var origin := global_position
	for node in get_tree().root.find_children("*", "VisualInstance3D", true, false):
		if node == self or is_ancestor_of(node):
			continue
		# Lights are not geometry; changing their layer would break lighting.
		if node is Light3D:
			continue
		if not is_instance_valid(node):
			continue
		if (node.global_position - origin).dot(front) > 0.0:
			continue
		var layers: int = node.layers
		if layers == CLIP_LAYER_BIT:
			continue
		_hidden_visuals[node.get_instance_id()] = {
			"node": node,
			"layers": layers,
		}
		# Replace, not OR: any surviving shared bit would still match the
		# reflection camera's mask and render the object behind the glass.
		node.layers = CLIP_LAYER_BIT


func _update_reflection_size(screen_size: Vector2i) -> void:
	if screen_size.x <= 0 or screen_size.y <= 0:
		return
	var screen_aspect := float(screen_size.x) / float(screen_size.y)
	var target_aspect := float(reflection_resolution.x) / float(reflection_resolution.y)
	var width := reflection_resolution.x
	var height := reflection_resolution.y
	if screen_aspect > target_aspect:
		width = maxi(2, int(round(height * screen_aspect)))
	else:
		height = maxi(2, int(round(width / screen_aspect)))
	_viewport.size = Vector2i(width, height)


func _copy_camera_settings(viewer: Camera3D) -> void:
	_reflection_camera.projection = viewer.projection
	_reflection_camera.fov = viewer.fov
	_reflection_camera.near = maxf(viewer.near, 0.01)
	_reflection_camera.far = viewer.far
	_reflection_camera.keep_aspect = viewer.keep_aspect
	_reflection_camera.size = viewer.size
	_reflection_camera.h_offset = viewer.h_offset
	_reflection_camera.v_offset = viewer.v_offset
	_reflection_camera.environment = viewer.environment
	_reflection_camera.attributes = viewer.attributes


func _reflect_across_glass(viewer_local: Transform3D) -> Transform3D:
	var basis := viewer_local.basis
	var x := Vector3(basis.x.x, basis.x.y, -basis.x.z)
	var y := Vector3(basis.y.x, basis.y.y, -basis.y.z)
	var z := Vector3(basis.z.x, basis.z.y, -basis.z.z)
	if x.length_squared() < 0.000001:
		x = Vector3.RIGHT
	if y.length_squared() < 0.000001:
		y = Vector3.UP
	if z.length_squared() < 0.000001:
		z = Vector3.BACK

	# Reflecting the basis flips its handedness. Negating the horizontal axis
	# gives a valid right-handed camera; the glass shader flips U to match.
	var reflected := Basis(-x.normalized(), y.normalized(), z.normalized())
	var origin := viewer_local.origin
	origin.z = -origin.z
	return Transform3D(reflected, origin)
