extends Node3D

@export var linked_portal: Node3D

@onready var portal_camera: Camera3D = $SubViewport/Camera3D
@onready var area: Area3D = $Area3D

var tracked_bodies = {}

func _ready():
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)


func _process(delta):

	update_portal_camera()

	for body in tracked_bodies.keys():

		var previous_side = tracked_bodies[body]
		var current_side = get_side(body.global_transform.origin)

		if previous_side != current_side:
			teleport(body)

		tracked_bodies[body] = current_side


func update_portal_camera():

	var player_camera = get_viewport().get_camera_3d()

	if player_camera == null or linked_portal == null:
		return

	var relative = global_transform.affine_inverse() * player_camera.global_transform

	portal_camera.global_transform = linked_portal.global_transform * relative


func get_side(point: Vector3) -> bool:
	var local_point = to_local(point)
	return local_point.z > 0


func teleport(body):

	var relative = global_transform.affine_inverse() * body.global_transform

	body.global_transform = linked_portal.global_transform * relative


func _on_body_entered(body):
	tracked_bodies[body] = get_side(body.global_transform.origin)


func _on_body_exited(body):
	tracked_bodies.erase(body)
