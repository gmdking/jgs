extends Node
## Minimal TCP/IP multiplayer for JGS.
##
## The host is authoritative: it owns the map, runs physics, computes every
## interaction (pickup, throw, duplicate, delete, scale) and broadcasts the
## resulting object state. Clients only send intents and follow snapshots.
##
## Wire format: 4-byte big-endian payload length + UTF-8 JSON object.

const PLAYER_HZ := 30.0
const OBJECT_HZ := 30.0
const DIFF_HZ := 5.0
const MAX_PACKET := 16 * 1024 * 1024

enum Role { NONE, HOST, CLIENT }

var role: int = Role.NONE
var peer_id := 1
var map_path := ""
var status := "Offline"

var _server: TCPServer = null
var _client: StreamPeerTCP = null
var _client_state := {"tcp": null, "buf": PackedByteArray()}
var _peers := {}           # id -> {"tcp": StreamPeerTCP, "buf": PackedByteArray}
var _known_peers := {}     # id -> true
var _next_peer_id := 2
var _next_net_id := 1

var _world: Node = null
var _object_root: Node3D = null
var _objects := {}         # key -> RigidBody3D
var _signatures := {}      # key -> Array
var _held_by := {}         # peer_id -> object key
var _holder_of := {}       # object key -> peer_id
var _remote_players := {}  # id -> Node3D
var _remote_states := {}   # id -> player message

var _player_accum := 0.0
var _object_accum := 0.0
var _diff_accum := 0.0


func _ready() -> void:
	# Keep the connection alive while the in-game pause menu is open.
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_active() -> bool:
	return role != Role.NONE


func host(port: int) -> void:
	reset()
	_server = TCPServer.new()
	var err := _server.listen(port)
	if err != OK:
		status = "Could not listen on port %d (error %d)" % [port, err]
		_server = null
		return
	role = Role.HOST
	peer_id = 1
	_known_peers[1] = true
	status = "Hosting on port %d" % port


func join(address: String, port: int) -> void:
	reset()
	_client = StreamPeerTCP.new()
	var err := _client.connect_to_host(address, port)
	if err != OK:
		status = "Could not connect to %s:%d (error %d)" % [address, port, err]
		_client = null
		return
	role = Role.CLIENT
	peer_id = -1
	_client_state = {"tcp": _client, "buf": PackedByteArray()}
	status = "Connecting to %s:%d..." % [address, port]


func reset() -> void:
	if role == Role.HOST and _peers.size() > 0:
		_broadcast({"t": "bye"})
	if _server != null:
		_server.stop()
	if _client != null:
		_client.disconnect_from_host()
	for state in _peers.values():
		var tcp: StreamPeerTCP = state.get("tcp")
		if tcp != null:
			tcp.disconnect_from_host()
	_server = null
	_client = null
	_client_state = {"tcp": null, "buf": PackedByteArray()}
	_peers.clear()
	_known_peers.clear()
	role = Role.NONE
	peer_id = 1
	map_path = ""
	status = "Offline"
	_forget_world()


func _forget_world() -> void:
	_world = null
	_object_root = null
	_objects.clear()
	_signatures.clear()
	_held_by.clear()
	_holder_of.clear()
	_remote_states.clear()
	for node in _remote_players.values():
		if is_instance_valid(node) and node is Node:
			(node as Node).queue_free()
	_remote_players.clear()
	_player_accum = 0.0
	_object_accum = 0.0
	_diff_accum = 0.0


## Called by the file browser once the host has chosen a map.
func set_map_path(path: String) -> void:
	map_path = path
	if role == Role.HOST:
		_broadcast({"t": "map", "path": path})


## Held objects are moved on the physics step so they stay in sync with Jolt
## instead of jittering between render frames.
func _physics_process(_delta: float) -> void:
	if role == Role.HOST:
		_move_held_objects()


func _process(delta: float) -> void:
	if role == Role.NONE:
		return

	var scene := get_tree().current_scene
	if scene != _world:
		_on_world_changed(scene)
	if role == Role.NONE:
		return

	if role == Role.HOST:
		_poll_server()
	else:
		_poll_client()
	_poll_messages()
	if role == Role.NONE:
		return

	_player_accum += delta
	if _player_accum >= 1.0 / PLAYER_HZ:
		_player_accum = 0.0
		_send_player_state()

	if role == Role.HOST:
		_object_accum += delta
		if _object_accum >= 1.0 / OBJECT_HZ:
			_object_accum = 0.0
			_send_object_states()

		_diff_accum += delta
		if _diff_accum >= 1.0 / DIFF_HZ:
			_diff_accum = 0.0
			_scan_objects(false)


func _on_world_changed(scene: Node) -> void:
	if scene == null:
		return
	_forget_world()
	_world = scene
	_object_root = scene.get_node_or_null("NetObjects") as Node3D
	if _object_root == null:
		_object_root = Node3D.new()
		_object_root.name = "NetObjects"
		scene.add_child(_object_root)
	_scan_objects(true)
	# Menus have no player; don't clutter them with remote capsules.
	if _local_player() != null:
		for id in _known_peers:
			if int(id) != peer_id:
				_ensure_remote_player(int(id))


# ---------------------------------------------------------------- sockets ---

func _poll_server() -> void:
	if _server == null:
		return
	for id in _peers.keys():
		var state: Dictionary = _peers.get(id)
		var tcp: StreamPeerTCP = state.get("tcp") if state != null else null
		if tcp == null or tcp.get_status() == StreamPeerTCP.STATUS_NONE or tcp.get_status() == StreamPeerTCP.STATUS_ERROR:
			_remove_peer(int(id))
	while _server.is_connection_available():
		var tcp := _server.take_connection()
		if tcp == null:
			continue
		tcp.set_no_delay(true)
		var id := _next_peer_id
		_next_peer_id += 1
		_peers[id] = {"tcp": tcp, "buf": PackedByteArray()}
		_known_peers[id] = true
		_ensure_remote_player(id)
		var players: Array = [1]
		for known in _known_peers:
			players.append(int(known))
		_send_to(id, {"t": "hello", "id": id, "map": map_path, "players": players})
		# Late joiners need objects that existed before they connected.
		for key in _objects.keys():
			var object = _objects.get(key)
			if is_instance_valid(object) and object is RigidBody3D:
				_send_to(id, _spawn_msg(key, object))


func _poll_client() -> void:
	if _client == null:
		return
	_client.poll()
	var state := _client.get_status()
	if state == StreamPeerTCP.STATUS_CONNECTED:
		_client_state["tcp"] = _client
		if status.begins_with("Connecting"):
			status = "Waiting for host..."
	elif state == StreamPeerTCP.STATUS_ERROR or state == StreamPeerTCP.STATUS_NONE:
		reset()
		status = "Disconnected from host"
		get_tree().change_scene_to_file("res://gui/menu.tscn")


func _poll_messages() -> void:
	if role == Role.HOST:
		for id in _peers.keys():
			var state: Dictionary = _peers.get(id)
			if state == null:
				continue
			for msg in _drain(state):
				_handle_message(int(id), msg)
				if role != Role.HOST:
					break
	elif role == Role.CLIENT:
		for msg in _drain(_client_state):
			_handle_message(1, msg)
			if role != Role.CLIENT:
				break


func _drain(state: Dictionary) -> Array:
	var out: Array = []
	var tcp: StreamPeerTCP = state.get("tcp")
	if tcp == null:
		return out
	var available := tcp.get_available_bytes()
	if available > 0:
		var result: Array = tcp.get_data(available)
		if result.size() == 2 and result[0] == OK:
			var data: PackedByteArray = result[1]
			var buf: PackedByteArray = state.get("buf", PackedByteArray())
			buf.append_array(data)
			state["buf"] = buf
	return _parse_buffer(state)


func _parse_buffer(state: Dictionary) -> Array:
	var out: Array = []
	var buf: PackedByteArray = state.get("buf", PackedByteArray())
	while buf.size() >= 4:
		var size := (int(buf[0]) << 24) | (int(buf[1]) << 16) | (int(buf[2]) << 8) | int(buf[3])
		if size <= 0 or size > MAX_PACKET:
			buf = PackedByteArray()
			break
		if buf.size() < 4 + size:
			break
		var payload := buf.slice(4, 4 + size)
		buf = buf.slice(4 + size)
		var parsed = JSON.parse_string(payload.get_string_from_utf8())
		if parsed is Dictionary:
			out.append(parsed)
	state["buf"] = buf
	return out


func _send_to(id: int, msg: Dictionary) -> void:
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var size := payload.size()
	var packet := PackedByteArray()
	packet.append((size >> 24) & 0xFF)
	packet.append((size >> 16) & 0xFF)
	packet.append((size >> 8) & 0xFF)
	packet.append(size & 0xFF)
	packet.append_array(payload)
	if role == Role.HOST:
		var state: Dictionary = _peers.get(id)
		if state != null:
			var tcp: StreamPeerTCP = state.get("tcp")
			if tcp != null:
				tcp.put_data(packet)
	elif role == Role.CLIENT and id == 1 and _client != null:
		_client.put_data(packet)


func _broadcast(msg: Dictionary, except_id: int = -1) -> void:
	if role != Role.HOST:
		return
	for id in _peers.keys():
		if int(id) != except_id:
			_send_to(int(id), msg)


func _route(msg: Dictionary) -> void:
	if role == Role.HOST:
		_broadcast(msg)
	elif role == Role.CLIENT:
		_send_to(1, msg)


# --------------------------------------------------------------- messages ---

func _handle_message(id: int, msg: Dictionary) -> void:
	var t := String(msg.get("t", ""))
	if role == Role.HOST:
		match t:
			"player":
				_known_peers[id] = true
				_remote_states[id] = msg
				_apply_player_state(id, msg)
				_broadcast(msg, id)
			"req":
				_handle_request(id, msg)
			"bye":
				_remove_peer(id, false)
	else:
		match t:
			"hello":
				peer_id = int(msg.get("id", -1))
				map_path = String(msg.get("map", ""))
				for p in msg.get("players", []):
					_known_peers[int(p)] = true
				status = "Connected as P%d" % peer_id
				_ensure_remote_player(1)
				if map_path != "":
					_load_map(map_path)
			"map":
				map_path = String(msg.get("path", ""))
				if map_path != "":
					_load_map(map_path)
			"player":
				var pid := int(msg.get("id", 1))
				_known_peers[pid] = true
				_remote_states[pid] = msg
				_apply_player_state(pid, msg)
			"states":
				_apply_states(msg)
			"spawn":
				_apply_spawn(msg)
			"despawn":
				_apply_despawn(msg)
			"scale":
				_apply_scale(msg)
			"grab":
				# Someone else got the object we are drawing locally.
				if int(msg.get("by", -1)) != peer_id:
					_clear_local_hold(String(msg.get("key", "")))
			"deny":
				_clear_local_hold(String(msg.get("key", "")))
			"leave":
				_remove_player_visual(int(msg.get("id", -1)))
			"bye":
				reset()
				status = "Host closed the session"
				get_tree().change_scene_to_file("res://gui/menu.tscn")


func _load_map(path: String) -> void:
	var current := get_tree().current_scene
	if current == null or current.scene_file_path != path:
		get_tree().change_scene_to_file(path)


func _remove_peer(id: int, notify: bool = true) -> void:
	_peers.erase(id)
	_known_peers.erase(id)
	_remote_states.erase(id)
	_server_release(id, false)
	_remove_player_visual(id)
	if notify:
		_broadcast({"t": "leave", "id": id})


func _remove_player_visual(id: int) -> void:
	var node = _remote_players.get(id)
	if is_instance_valid(node) and node is Node:
		(node as Node).queue_free()
	_remote_players.erase(id)


# ------------------------------------------------------- interactions (host) ---

## Entry points for the host's own player controller. The host is the server,
## so its actions go through the same authoritative code as client intents.
func server_pickup(_player: Node, target: Node) -> void:
	if role == Role.HOST and target != null:
		_server_pickup(1, _key_for(target))


func server_drop(_player: Node) -> void:
	if role == Role.HOST:
		_server_release(1, true)


func server_duplicate(_player: Node, target: Node) -> void:
	if role == Role.HOST and target != null:
		_server_duplicate(1, _key_for(target))


func server_delete(_player: Node, target: Node) -> void:
	if role == Role.HOST and target != null:
		_server_delete(_key_for(target))


func server_scale(_player: Node, target: Node, factor: float) -> void:
	if role == Role.HOST and target != null:
		_server_scale(1, _key_for(target), factor)


## Clients only ask; the host decides what actually happens.
func request_pickup(target: Node) -> void:
	if role == Role.CLIENT and target != null:
		var key := _key_for(target)
		if key != "":
			_send_to(1, {"t": "req", "kind": "pickup", "key": key})


func request_drop() -> void:
	if role == Role.CLIENT:
		_send_to(1, {"t": "req", "kind": "drop"})


func request_duplicate(target: Node) -> void:
	if role == Role.CLIENT and target != null:
		var key := _key_for(target)
		if key != "":
			_send_to(1, {"t": "req", "kind": "duplicate", "key": key})


func request_delete(target: Node) -> void:
	if role == Role.CLIENT and target != null:
		var key := _key_for(target)
		if key != "":
			_send_to(1, {"t": "req", "kind": "delete", "key": key})


func request_scale(target: Node, factor: float) -> void:
	if role == Role.CLIENT and target != null:
		var key := _key_for(target)
		if key != "":
			_send_to(1, {"t": "req", "kind": "scale", "key": key, "factor": factor})


func key_for(node: Node) -> String:
	return _key_for(node)


func _handle_request(peer: int, msg: Dictionary) -> void:
	var kind := String(msg.get("kind", ""))
	var key := String(msg.get("key", ""))
	match kind:
		"pickup":
			_server_pickup(peer, key)
		"drop":
			_server_release(peer, true)
		"duplicate":
			_server_duplicate(peer, key)
		"delete":
			_server_delete(key)
		"scale":
			_server_scale(peer, key, float(msg.get("factor", 1.1)))


func _server_pickup(peer: int, key: String) -> void:
	var object = _objects.get(key)
	if key == "" or _holder_of.has(key) or not (is_instance_valid(object) and object is RigidBody3D):
		# Tell the requester so it can drop its locally predicted visual.
		if peer != 1:
			_send_to(peer, {"t": "deny", "kind": "pickup", "key": key})
		return
	if _held_by.has(peer):
		_server_release(peer, false)
	_held_by[peer] = key
	_holder_of[key] = peer
	object.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	object.freeze = true
	object.linear_velocity = Vector3.ZERO
	object.angular_velocity = Vector3.ZERO
	_move_held_objects()
	_broadcast({"t": "grab", "key": key, "by": peer})


func _server_release(peer: int, throw: bool) -> void:
	var key: String = _held_by.get(peer, "")
	if key == "":
		return
	_held_by.erase(peer)
	_holder_of.erase(key)
	var object = _objects.get(key)
	if is_instance_valid(object) and object is RigidBody3D:
		object.freeze = false
		object.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		var velocity := Vector3.ZERO
		if throw:
			var pose := _pose_for(peer)
			var pitch := float(pose.get("pitch", 0.0))
			if pitch > 0.07:
				velocity = (pose["forward"] as Vector3) * pitch * 12.0
		object.linear_velocity = velocity
		_broadcast({"t": "throw", "key": key, "lv": _pack_v(velocity), "by": peer})


func _server_duplicate(peer: int, key: String) -> void:
	if _object_root == null or key == "":
		return
	var object = _objects.get(key)
	if not (is_instance_valid(object) and object is RigidBody3D):
		return
	var copy := (object as RigidBody3D).duplicate() as RigidBody3D
	if copy == null:
		return
	_object_root.add_child(copy)
	copy.global_transform = object.global_transform
	copy.global_transform.origin += (_pose_for(peer)["forward"] as Vector3) * 1.5
	copy.freeze = false
	copy.linear_velocity = Vector3.ZERO
	copy.angular_velocity = Vector3.ZERO
	_scan_objects(false)


func _server_delete(key: String) -> void:
	var object = _objects.get(key)
	if not is_instance_valid(object):
		return
	if _holder_of.has(key):
		_held_by.erase(_holder_of[key])
		_holder_of.erase(key)
	_objects.erase(key)
	_signatures.erase(key)
	(object as Node).queue_free()
	_broadcast({"t": "despawn", "key": key})


func _server_scale(peer: int, key: String, factor: float) -> void:
	var object = _objects.get(key)
	if not (is_instance_valid(object) and object is RigidBody3D):
		return
	object.scale *= factor
	object.mass *= factor
	_signatures[key] = _signature(object)
	_send_scale(key, object)


func _move_held_objects() -> void:
	if _world == null:
		return
	for id in _held_by.keys():
		var key: String = _held_by[id]
		var object = _objects.get(key)
		if not (is_instance_valid(object) and object is RigidBody3D):
			continue
		var pose := _pose_for(int(id))
		var hold := float(pose.get("hold", 3.0))
		object.global_transform.origin = (pose["origin"] as Vector3) + (pose["forward"] as Vector3) * hold
		object.linear_velocity = Vector3.ZERO
		object.angular_velocity = Vector3.ZERO


## Camera pose used to place held objects and compute throw velocity. Remote
## peers only send yaw + pitch, so their camera origin is reconstructed from
## the local player's authored camera offset (pitch removed).
func _pose_for(id: int) -> Dictionary:
	if id == 1:
		var player := _local_player()
		if player != null:
			var cam := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
			if cam != null:
				var p = player.get("pitch")
				var h = player.get("hold_distance")
				return {
					"forward": -cam.global_transform.basis.z.normalized(),
					"origin": cam.global_transform.origin,
					"pitch": float(p) if p != null else 0.0,
					"hold": float(h) if h != null else 3.0
				}
	var state: Dictionary = _remote_states.get(id, {})
	var x := _unpack_xform(state.get("x", []))
	var pitch := float(state.get("pitch", 0.0))
	var look_basis := x.basis * Basis(Vector3.RIGHT, pitch)
	return {
		"forward": -look_basis.z.normalized(),
		"origin": x.origin + x.basis * _camera_offset(),
		"pitch": pitch,
		"hold": 3.0
	}


func _camera_offset() -> Vector3:
	var player := _local_player()
	if player != null:
		var pivot := player.get_node_or_null("CameraPivot") as Node3D
		var cam := player.get_node_or_null("CameraPivot/Camera3D") as Node3D
		if pivot != null and cam != null:
			var b := pivot.transform.basis
			var sx := b.x.length()
			var sy := b.y.length()
			var sz := b.z.length()
			var rot := Basis(b.x.normalized(), b.y.normalized(), b.z.normalized())
			var local_cam := Vector3(
				cam.transform.origin.x * sx,
				cam.transform.origin.y * sy,
				cam.transform.origin.z * sz
			)
			return pivot.transform.origin + rot * local_cam
	return Vector3(0, 0.7, 0)


# ----------------------------------------------------------------- players ---

func _local_player() -> CharacterBody3D:
	for node in get_tree().get_nodes_in_group("player"):
		if is_instance_valid(node) and node is CharacterBody3D:
			return node
	return null


func _ensure_remote_player(id: int) -> Node3D:
	if id == peer_id or _world == null or _local_player() == null:
		return null
	var existing = _remote_players.get(id)
	if is_instance_valid(existing) and existing is Node:
		return existing

	var root := Node3D.new()
	root.name = "NetPlayer_%d" % id
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.35
	mesh.height = 1.8
	var body := MeshInstance3D.new()
	body.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.75, 1.0)
	body.material_override = material
	root.add_child(body)

	var label := Label3D.new()
	label.text = "P%d" % id
	label.position = Vector3(0, 1.35, 0)
	label.font_size = 48
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(label)

	_world.add_child(root)
	_remote_players[id] = root
	return root


func _send_player_state() -> void:
	var player := _local_player()
	if player == null:
		return
	var pitch_value = player.get("pitch")
	var msg := {
		"t": "player",
		"id": peer_id,
		"x": _pack_xform(player.global_transform),
		"v": _pack_v(player.velocity),
		"pitch": float(pitch_value) if pitch_value != null else 0.0
	}
	if role == Role.HOST:
		_remote_states[peer_id] = msg
		_broadcast(msg)
	else:
		_send_to(1, msg)


func _apply_player_state(id: int, msg: Dictionary) -> void:
	var visual := _ensure_remote_player(id)
	if visual != null:
		visual.global_transform = _unpack_xform(msg.get("x", []))


# ----------------------------------------------------------------- objects ---

func _send_object_states() -> void:
	var states: Array = []
	for key in _objects.keys():
		var node = _objects.get(key)
		if is_instance_valid(node) and node is RigidBody3D:
			states.append([key, _pack_xform(node.global_transform)])
	_broadcast({"t": "states", "states": states})


func _apply_states(msg: Dictionary) -> void:
	# The owning client draws its held object locally; don't fight that with
	# host snapshots until it lets go.
	var local := _local_player()
	var local_held: Node = null
	if local != null:
		local_held = local.get("held_object")
	var local_held_key := _key_for(local_held) if local_held != null else ""
	for entry in msg.get("states", []):
		if not (entry is Array) or entry.size() < 2:
			continue
		var key := String(entry[0])
		if role == Role.CLIENT and key == local_held_key:
			continue
		var node = _objects.get(key)
		if is_instance_valid(node) and node is RigidBody3D:
			node.global_transform = _unpack_xform(entry[1])
			node.freeze = true
			node.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			node.linear_velocity = Vector3.ZERO
			node.angular_velocity = Vector3.ZERO


func _key_for(node: Node) -> String:
	if _world == null or not is_instance_valid(node) or not _world.is_ancestor_of(node):
		return ""
	return String(_world.get_path_to(node))


func _signature(node: RigidBody3D) -> Array:
	return [
		node.scene_file_path,
		snappedf(node.scale.x, 0.001),
		snappedf(node.scale.y, 0.001),
		snappedf(node.scale.z, 0.001),
		snappedf(node.mass, 0.001)
	]


func _collect(node: Node, out: Dictionary) -> void:
	for child in node.get_children():
		if child is RigidBody3D:
			var key := _key_for(child)
			if key != "":
				out[key] = child
		_collect(child, out)


func _scan_objects(initial: bool) -> void:
	if _world == null:
		return
	var found := {}
	_collect(_world, found)

	var added: Array = []
	for key in found:
		if not _objects.has(key) or not is_instance_valid(_objects.get(key)):
			added.append(key)

	if not initial:
		for key in _objects.keys():
			if not found.has(key) or not is_instance_valid(_objects.get(key)):
				_despawn_key(key)

	for key in added:
		var node: RigidBody3D = found[key]
		var final_key := String(key)
		if not initial:
			final_key = _normalize_object(node)
			if final_key == "":
				continue
		_objects[final_key] = node
		_signatures[final_key] = _signature(node)
		_send_spawn(final_key, node)

	if not initial:
		for key in _objects.keys():
			var node = _objects.get(key)
			if not is_instance_valid(node) or not (node is RigidBody3D):
				continue
			var sig := _signature(node)
			if _signatures.get(key) != sig:
				_signatures[key] = sig
				_send_scale(key, node)


func _normalize_object(node: Node) -> String:
	if _object_root == null:
		return ""
	node.name = "N%d" % _next_net_id
	_next_net_id += 1
	if node.get_parent() != _object_root:
		node.reparent(_object_root, true)
	return _key_for(node)


func _despawn_key(key: String) -> void:
	_objects.erase(key)
	_signatures.erase(key)
	if _holder_of.has(key):
		_held_by.erase(_holder_of[key])
		_holder_of.erase(key)
	_route({"t": "despawn", "key": key})


func _spawn_msg(key: String, node: RigidBody3D) -> Dictionary:
	return {
		"t": "spawn",
		"key": key,
		"scene": node.scene_file_path,
		"x": _pack_xform(node.global_transform),
		"m": node.mass,
		"lv": _pack_v(node.linear_velocity),
		"av": _pack_v(node.angular_velocity),
		"f": node.freeze
	}


func _send_spawn(key: String, node: RigidBody3D) -> void:
	_route(_spawn_msg(key, node))


func _send_scale(key: String, node: RigidBody3D) -> void:
	var s := node.scale
	_route({
		"t": "scale",
		"key": key,
		"s": [s.x, s.y, s.z],
		"m": node.mass
	})


func _apply_spawn(msg: Dictionary) -> void:
	var key := String(msg.get("key", ""))
	if key == "" or _object_root == null or _objects.has(key):
		return
	var scene_path := String(msg.get("scene", ""))
	if not ResourceLoader.exists(scene_path):
		return
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return
	var node := packed.instantiate()
	if not (node is RigidBody3D):
		node.free()
		return
	node.name = key.get_file()
	_object_root.add_child(node)
	node.global_transform = _unpack_xform(msg.get("x", []))
	node.mass = float(msg.get("m", node.mass))
	node.linear_velocity = _unpack_v(msg.get("lv", []))
	node.angular_velocity = _unpack_v(msg.get("av", []))
	node.freeze = bool(msg.get("f", false))
	_objects[key] = node
	_signatures[key] = _signature(node)


func _apply_despawn(msg: Dictionary) -> void:
	var key := String(msg.get("key", ""))
	var node = _objects.get(key)
	_objects.erase(key)
	_signatures.erase(key)
	_clear_local_hold(key)
	if is_instance_valid(node) and node is Node:
		(node as Node).queue_free()


## Stop drawing a locally predicted held object and hand it back to host
## snapshots (used when the host denies our grab, someone else wins it, or it
## is deleted).
func _clear_local_hold(key: String) -> void:
	var local := _local_player()
	if local == null:
		return
	var held: Node = local.get("held_object")
	if not is_instance_valid(held) or (key != "" and _key_for(held) != key):
		return
	if held is RigidBody3D:
		(held as RigidBody3D).freeze = false
		(held as RigidBody3D).freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	local.set("held_object", null)


func _apply_scale(msg: Dictionary) -> void:
	var key := String(msg.get("key", ""))
	var node = _objects.get(key)
	if not is_instance_valid(node) or not (node is RigidBody3D):
		return
	var s: Array = msg.get("s", [])
	if s.size() == 3:
		(node as RigidBody3D).scale = Vector3(s[0], s[1], s[2])
	(node as RigidBody3D).mass = float(msg.get("m", node.mass))
	_signatures[key] = _signature(node)


# ------------------------------------------------------------------ helpers ---

func _pack_xform(x: Transform3D) -> Array:
	var b := x.basis
	return [
		b.x.x, b.x.y, b.x.z,
		b.y.x, b.y.y, b.y.z,
		b.z.x, b.z.y, b.z.z,
		x.origin.x, x.origin.y, x.origin.z
	]


func _unpack_xform(a: Array) -> Transform3D:
	if a.size() < 12:
		return Transform3D.IDENTITY
	return Transform3D(
		Vector3(a[0], a[1], a[2]),
		Vector3(a[3], a[4], a[5]),
		Vector3(a[6], a[7], a[8]),
		Vector3(a[9], a[10], a[11])
	)


func _pack_v(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


func _unpack_v(a: Array) -> Vector3:
	if a.size() < 3:
		return Vector3.ZERO
	return Vector3(a[0], a[1], a[2])
