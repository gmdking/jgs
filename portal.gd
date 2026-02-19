extends Node3D

@export var other_portal: Node3D
@export var player: CharacterBody3D
@export var player_camera: Camera3D

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var area: Area3D = $Area3D
@onready var viewport: SubViewport = $SubViewport
@onready var portal_camera: Camera3D = $SubViewport/Camera3D

var teleport_cooldown := false
const TELEPORT_COOLDOWN_TIME := 0.2

func _ready():
	area.body_entered.connect(_on_body_entered)

	var mat := mesh.get_active_material(0)
	if mat:
		mat.set_shader_parameter(
			"portal_texture",
			viewport.get_texture()
		)

func _process(delta):
	if other_portal == null or player_camera == null:
		return
	update_portal_camera()

func update_portal_camera():
	var player_cam_transform = player_camera.global_transform

	var local_transform = global_transform.affine_inverse() * player_cam_transform
	local_transform = flip_transform(local_transform)

	var new_transform = other_portal.global_transform * local_transform
	portal_camera.global_transform = new_transform

	portal_camera.fov = player_camera.fov
	portal_camera.near = 0.01
	portal_camera.far = 1000.0

func _on_body_entered(body):
	if teleport_cooldown:
		return
	if body == player or body is RigidBody3D:
		teleport(body)

func teleport(body):
	teleport_cooldown = true
	other_portal.teleport_cooldown = true

	var relative_transform = global_transform.affine_inverse() * body.global_transform
	relative_transform = flip_transform(relative_transform)

	if body is CharacterBody3D:
		body.global_transform = other_portal.global_transform * relative_transform
		body.velocity = transform_velocity(body.velocity)
	elif body is RigidBody3D:
		# freeze instead of changing mode
		var was_frozen = body.freeze
		var prev_freeze_mode = body.freeze_mode

		body.freeze = true
		body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC

		body.global_transform = other_portal.global_transform * relative_transform
		body.linear_velocity = transform_velocity(body.linear_velocity)
		body.angular_velocity = transform_velocity(body.angular_velocity)

		body.freeze = was_frozen
		body.freeze_mode = prev_freeze_mode

	await get_tree().create_timer(TELEPORT_COOLDOWN_TIME).timeout

	teleport_cooldown = false
	other_portal.teleport_cooldown = false

func flip_transform(t: Transform3D) -> Transform3D:
	var flipped_basis = Basis(Vector3.UP, PI) * t.basis
	return Transform3D(flipped_basis, t.origin)

func transform_velocity(vel: Vector3) -> Vector3:
	var local_vel = global_transform.basis.inverse() * vel
	local_vel = Basis(Vector3.UP, PI) * local_vel
	return other_portal.global_transform.basis * local_vel
