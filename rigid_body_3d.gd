extends RigidBody3D

@export var pickup_key := "pickup"  # Map this action to “E”
@export var drop_key := "drop"      # Optional separate drop input
@export var hold_distance := 3.0
@export var pickup_range := 4.0
@onready var camera: Camera3D = $CameraPivot/Camera3D

var held_object: RigidBody3D = null

func _physics_process(delta):
	# If holding an object, move it toward the hold point
	if held_object:
		var target_pos = $Camera3D.global_transform.origin + $Camera3D.global_transform.basis.z * -hold_distance
		# Freeze/disable physics and assign collisions if desired
		held_object.freeze = true
		held_object.global_transform.origin = target_pos
		
		# Optional: If drop key pressed
		if Input.is_action_just_pressed(drop_key):
			drop_object()

	else:
		# Not holding — detect pickup
		if Input.is_action_just_pressed(pickup_key):
			try_pickup()

func try_pickup():
	if camera == null:
		return

	var mouse_pos = get_viewport().get_mouse_position()

	# ray origin and direction from camera
	var from = camera.project_ray_origin(mouse_pos)
	var dir = camera.project_ray_normal(mouse_pos)
	var to = from + dir * pickup_range

	# build the query
	var ray_query = PhysicsRayQueryParameters3D.new()
	ray_query.from = from
	ray_query.to = to
	ray_query.exclude = [self]  # don’t hit the player

	# cast
	var result = get_world_3d().direct_space_state.intersect_ray(ray_query)

	if result and result.has("collider") and result["collider"] is RigidBody3D:
		held_object = result["collider"]
		held_object.freeze = false
		held_object.set_collision_layer_value(1, true) # Re‑enable collisions

func drop_object():
	if held_object:
		# Re‑enable physics
		held_object.freeze = false
		held_object.set_collision_layer_value(1, true) # Re‑enable collisions
		# Optional: add throw impulse
		held_object.linear_velocity = $Camera3D.global_transform.basis.z * -10
		held_object = null
