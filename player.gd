extends CharacterBody3D
#dear god.... (now with server-authoritative net interactions)
@export var sprint_speed := 10.0
@export var gravity := 9.8
@export var mouse_sensitivity := 0.002
@export var controller_look_sensitivity := 3.0  # adjust to taste
var lowjump := 4.5
var highjump := 9
var curjump := 9
var current_speed := 5.0
var walk_speed := 5.0
@export var pickup_key := "pickup"
@export var drop_key := "drop"
@export var duplicate_key := "dupl"
@export var delete_key := "del"
@export var hold_distance := 3.0
@export var pickup_range := 4.0
@onready var pivot = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var ray: RayCast3D = $CameraPivot/Camera3D/InteractRay
@onready var spawn_point = $CameraPivot/Camera3D/Marker3D
# varied variables that get varied later on
var held_object: RigidBody3D = null
var pitch := 0.0
var wants_pickup := false
var wants_drop := false
var menu_open = false

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if has_node("/root/Settings"):
		var s: Variant = get_node("/root/Settings")
		mouse_sensitivity = float(s.get_value("mouse_sensitivity", mouse_sensitivity))
		controller_look_sensitivity = float(s.get_value("controller_sensitivity", controller_look_sensitivity))
	if ray:
		ray.enabled = true

func _input(event):
	#camera movement
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, -PI/2, PI/2)
		pivot.rotation.x = pitch
	#self explanatory
	if event.is_action_pressed(pickup_key):
		wants_pickup = true
	if event.is_action_pressed(drop_key):
		wants_drop = true
	if event.is_action_pressed(duplicate_key):
		duplicate_target()
	if event.is_action_pressed(delete_key):
		delete_target()

func _physics_process(delta):
	#controller right thumbstick camera look
	var look_x := Input.get_axis("look_left", "look_right")
	var look_y := Input.get_axis("look_up", "look_down")
	if abs(look_x) > 0.1 or abs(look_y) > 0.1:  # deadzone
		rotate_y(-look_x * controller_look_sensitivity * delta)
		pitch -= look_y * controller_look_sensitivity * delta
		pitch = clamp(pitch, -PI/2, PI/2)
		pivot.rotation.x = pitch

	#standard jump
	if not is_on_floor():
		velocity.y -= gravity * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = curjump

	#sprinting, also affects the jump height
	#super sprint
	if Input.is_action_pressed("sprint") and Input.is_action_pressed("sprint2"):
		current_speed = sprint_speed * 2
		curjump = highjump * 2
	#sprint
	elif Input.is_action_pressed("sprint"):
		current_speed = sprint_speed
		curjump = highjump
	#normal
	else:
		current_speed = walk_speed
		curjump = lowjump

	#movement
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	velocity.x = direction.x * current_speed
	velocity.z = direction.z * current_speed
	move_and_slide()

	#pickup and drop flags
	if wants_pickup:
		wants_pickup = false
		_try_pickup()
	if wants_drop:
		wants_drop = false
		_drop_object()

	# Move the held object with the camera. Offline this is the whole story;
	# as a client this is local visual prediction while the host runs physics,
	# and as host it is the authoritative placement.
	if held_object:
		var target_pos = camera.global_transform.origin + (-camera.global_transform.basis.z * hold_distance)
		held_object.global_position = target_pos
		held_object.linear_velocity = Vector3.ZERO
		held_object.angular_velocity = Vector3.ZERO

	#scale feature, suprisingly easy
	#scale up
	if Input.is_action_just_pressed("scaleup"):
		var target = _get_target_object()
		if target != null:
			_scale_target(target, 1.1)
	#scale down
	if Input.is_action_just_pressed("scaledown"):
		var target = _get_target_object()
		if target != null:
			_scale_target(target, 0.9)

# In multiplayer, clients send intents and the host computes the result.
func _try_pickup():
	if held_object:
		return
	var from = camera.global_transform.origin
	var to = from + (-camera.global_transform.basis.z * pickup_range)
	var query = PhysicsRayQueryParameters3D.new()
	query.from = from
	query.to = to
	query.exclude = [self.get_rid()]
	var result = get_world_3d().direct_space_state.intersect_ray(query)
	if result and result.has("collider") and result["collider"] is RigidBody3D:
		var target: RigidBody3D = result["collider"]
		if Net.is_active():
			if Net.peer_id == 1:
				Net.server_pickup(self, target)
			else:
				# Draw it at our own camera while the host resolves the intent;
				# host snapshots skip an object we are holding locally.
				held_object = target
				held_object.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				held_object.freeze = true
				Net.request_pickup(target)
			return
		held_object = target
		held_object.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		held_object.freeze = true

#most of this is also self explanatory
func _drop_object():
	if Net.is_active():
		if Net.peer_id == 1:
			Net.server_drop(self)
		else:
			Net.request_drop()
			# Hand the object back to host snapshots as soon as we let go.
			if held_object:
				held_object.freeze = false
				held_object.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
				held_object = null
		return
	if not held_object:
		return
	held_object.freeze = false
	held_object.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	if pitch > 0.07:
		held_object.linear_velocity = -camera.global_transform.basis.z * pitch * 12
	held_object = null

#get the object, make sure its a rigidbody3d
func _get_target_object() -> RigidBody3D:
	if ray and ray.is_colliding():
		var obj = ray.get_collider()
		if obj and obj is RigidBody3D:
			return obj
	return null

func _scale_target(target: RigidBody3D, factor: float) -> void:
	if Net.is_active():
		if Net.peer_id == 1:
			Net.server_scale(self, target, factor)
		else:
			Net.request_scale(target, factor)
		return
	target.scale *= factor
	target.mass *= factor

#delete opject being percieved, self explanatory
func duplicate_target():
	var target = _get_target_object()
	if target == null: #or target == held_object: (commented this out because its BORING)
		return
	if Net.is_active():
		if Net.peer_id == 1:
			Net.server_duplicate(self, target)
		else:
			Net.request_duplicate(target)
		return
	var copy = target.duplicate()
	target.get_parent().add_child(copy)
	copy.global_transform = target.global_transform
	copy.global_transform.origin += -camera.global_transform.basis.z * 1.5
	copy.freeze = false
	copy.linear_velocity = Vector3.ZERO
	copy.angular_velocity = Vector3.ZERO

#delete opject being percieved, self explanatory
func delete_target():
	var target = _get_target_object()
	if target == null:
		return
	if Net.is_active():
		if Net.peer_id == 1:
			Net.server_delete(self, target)
		else:
			Net.request_delete(target)
		return
	if target == held_object:
		held_object = null
	target.queue_free()
