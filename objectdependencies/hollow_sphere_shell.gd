extends AnimatableBody3D

## Hollow interior for the orb. The parent rigid body keeps a solid sphere so the
## orb collides with the ground and can be picked up. This body is the inside
## wall, on layer 2 with the loose objects, so they bounce around in here.
##
## A triangle sphere still has no thickness, so after each physics step any
## corner that crossed the wall is pulled back inside.

@export var radius := 3.2446697
@export var shell_inset := 0.1
@export var rings := 18
@export var segments := 24

var _built := false


func _ready() -> void:
	collision_layer = 2
	collision_mask = 2
	sync_to_physics = false
	var material := PhysicsMaterial.new()
	material.bounce = 0.35
	material.friction = 0.45
	physics_material_override = material
	if _built:
		return
	_built = true
	_build_shell()


func _physics_process(_delta: float) -> void:
	# A parent rigid body moves this node, but that does not update the
	# kinematic body on its own. Push the current transform into the physics server.
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, global_transform)
	_contain_contents()


func _shell_radius() -> float:
	var scale := global_basis.get_scale()
	var uniform := maxf(scale.x, maxf(scale.y, scale.z))
	return maxf(radius - shell_inset, 0.1) * uniform


func _build_shell() -> void:
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.data = _sphere_faces(maxf(radius - shell_inset, 0.1), maxi(rings, 3), maxi(segments, 3))

	var col := CollisionShape3D.new()
	col.shape = shape
	add_child(col)


func _sphere_faces(shell_radius: float, ring_count: int, segment_count: int) -> PackedVector3Array:
	var rows: Array = []
	for i in ring_count + 1:
		var lat := lerpf(-PI * 0.5, PI * 0.5, float(i) / float(ring_count))
		var row: Array[Vector3] = []
		if i == 0:
			row.append(Vector3(0.0, -shell_radius, 0.0))
		elif i == ring_count:
			row.append(Vector3(0.0, shell_radius, 0.0))
		else:
			var ring_r := cos(lat) * shell_radius
			var y := sin(lat) * shell_radius
			for j in segment_count:
				var lon := TAU * float(j) / float(segment_count)
				row.append(Vector3(sin(lon) * ring_r, y, cos(lon) * ring_r))
		rows.append(row)

	var faces := PackedVector3Array()
	for i in ring_count:
		var lower: Array = rows[i]
		var upper: Array = rows[i + 1]
		if lower.size() == 1:
			var bottom: Vector3 = lower[0]
			for j in upper.size():
				faces = _add_tri(faces, bottom, upper[(j + 1) % upper.size()], upper[j])
		elif upper.size() == 1:
			var top: Vector3 = upper[0]
			for j in lower.size():
				faces = _add_tri(faces, lower[j], lower[(j + 1) % lower.size()], top)
		else:
			for j in segment_count:
				var j2 := (j + 1) % segment_count
				var a: Vector3 = lower[j]
				var b: Vector3 = lower[j2]
				var c: Vector3 = upper[j]
				var d: Vector3 = upper[j2]
				faces = _add_tri(faces, a, c, b)
				faces = _add_tri(faces, b, c, d)
	return faces


func _add_tri(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3) -> PackedVector3Array:
	if a.distance_squared_to(b) < 0.0000001 or b.distance_squared_to(c) < 0.0000001 or c.distance_squared_to(a) < 0.0000001:
		return faces
	faces.push_back(a)
	faces.push_back(b)
	faces.push_back(c)
	return faces


func _contain_contents() -> void:
	var host := get_parent()
	if host == null:
		return
	var center := global_position
	var limit := _shell_radius() - 0.02
	for child in host.get_children():
		if child is RigidBody3D:
			_constrain_body(child, center, limit)


func _constrain_body(body: RigidBody3D, center: Vector3, limit: float) -> void:
	for _step in 8:
		var worst_dist := limit
		var worst_point := Vector3.ZERO
		var outside := false
		for point in _outer_points(body, center):
			var dist := point.distance_to(center)
			if dist > worst_dist:
				worst_dist = dist
				worst_point = point
				outside = true
		if not outside:
			return

		var normal := (worst_point - center) / worst_dist
		var rel := worst_point - body.global_position
		var xf := body.global_transform
		xf.origin -= normal * (worst_dist - limit)
		body.global_transform = xf

		var outward := body.linear_velocity.dot(normal)
		if outward > 0.0:
			body.linear_velocity -= normal * outward * 1.35

		var axis := rel.cross(normal)
		var denom := axis.length_squared()
		if denom > 0.000001:
			var outward_spin := body.angular_velocity.cross(rel).dot(normal)
			if outward_spin > 0.0:
				body.angular_velocity -= axis * (outward_spin / denom)


func _outer_points(body: Node, center: Vector3) -> PackedVector3Array:
	return _collect_outer_points(body, center, PackedVector3Array())


func _collect_outer_points(node: Node, center: Vector3, points: PackedVector3Array) -> PackedVector3Array:
	for child in node.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape:
			var col := child as CollisionShape3D
			var xf := col.global_transform
			var shape := col.shape
			if shape is BoxShape3D:
				var he := (shape as BoxShape3D).size * 0.5
				for ix in [-1.0, 1.0]:
					for iy in [-1.0, 1.0]:
						for iz in [-1.0, 1.0]:
							points.push_back(xf * Vector3(he.x * ix, he.y * iy, he.z * iz))
			elif shape is SphereShape3D:
				var scale := xf.basis.get_scale()
				var world_r := (shape as SphereShape3D).radius * maxf(scale.x, maxf(scale.y, scale.z))
				var away := xf.origin - center
				if away.length_squared() < 0.000001:
					points.push_back(xf.origin + Vector3.UP * world_r)
				else:
					points.push_back(xf.origin + away.normalized() * world_r)
			elif shape is ConvexPolygonShape3D:
				for p in (shape as ConvexPolygonShape3D).points:
					points.push_back(xf * p)
		elif child is PhysicsBody3D:
			continue
		else:
			points = _collect_outer_points(child, center, points)
	return points
