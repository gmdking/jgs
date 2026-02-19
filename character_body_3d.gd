extends CharacterBody3D

@export var speed := 5.0
@export var jump_velocity := 4.5
@export var gravity := 9.8
@export var mouse_sensitivity := 0.002

@export var pickup_key := "pickup"
@export var drop_key := "drop"
@export var pickup_range := 4.0
@export var hold_distance := 3.0

@onready var pivot = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D

var pitch := 0.0
var held_object: RigidBody3D = null

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _input(event):
	if event is InputEventMouseMotion:
		# Left/right look
		rotate_y(-event.relative.x * mouse_sensitivity)

		# Up/down look
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, -PI/2, PI/2)
		pivot.rotation.x = pitch

func _physics_process(delta):
	# =========================
	# movement + gravity
	# =========================
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

	move_and_slide()

	# =========================
	# pickup handling
	# =========================
	if held_object:
		# move held object in front of camera
		var target_pos = camera.global_transform.origin + camera.global_transform.basis.z * -hold_distance
		held_object.freeze = true
		held_object.global_transform.origin = target_pos

		if Input.is_action_just_pressed(drop_key):
			drop_object()
	else:
		if Input.is_action_just_pressed(pickup_key):
			try_pickup()

func try_pickup():
	if camera == null:
		return

	var mouse_pos = get_viewport().get_mouse_position()
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * pickup_range

	var query = PhysicsRayQueryParameters3D.new()
	query.from = from
	query.to = to
	query.exclude = [self]

	var result = get_world_3d().direct_space_state.intersect_ray(query)
	if result and result.has("collider") and result["collider"] is RigidBody3D:
		held_object = result["collider"]
		held_object.freeze = true

func drop_object():
	if held_object:
		held_object.freeze = false
		# optional throw impulse
		held_object.linear_velocity = camera.global_transform.basis.z * -5
		held_object = null
