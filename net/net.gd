extends Node

const PLAYER_HZ := 30.0
const OBJECT_HZ := 30.0
const DIFF_HZ := 5.0
const MAX_PACKET := 16 * 1024 * 1024

## StreamPeer.put_data()/get_data() block the calling thread until the whole
## request fits through the socket. A slow or distant peer can therefore stall
## the host for seconds. All traffic goes through bounded, non-blocking queues
## instead; stale snapshots are superseded rather than queued up.
const SEND_BUDGET_PER_PEER := 256 * 1024   # bytes handed to one socket per frame
const RECV_BUDGET_PER_PEER := 256 * 1024
const MAX_OUT_QUEUE := 64 * 1024 * 1024
const MAX_MESSAGES_PER_READ := 64
const MAX_ACCEPTS_PER_FRAME := 16
const MAX_EXTRAPOLATION := 0.15            # seconds of remote-player prediction
const FULL_STATE_HZ := 1.0                 # periodic full snapshot / resync
const KEEPALIVE_HZ := 1.0                  # tiny packet even in idle menus

const EYES_TEXTURE_PATH := "res://player/eyes.png"
# The local eyes are authored for a first-person camera (tiny and very flat).
# Keep that exact shape on remote capsules, just enlarged enough to see.
const REMOTE_EYES_SCALE := 1.0

# Kept in sync with Settings.GAMEPLAY_TUNING_KEYS. The host owns these values
# for the whole session; clients receive them as session-only overrides.
const GAMEPLAY_TUNING_KEYS := [
	"debug_gravity", "debug_game_speed", "debug_walk_speed", "debug_sprint_speed",
	"debug_jump_strength", "debug_pickup_range", "debug_hold_distance",
	"debug_physics_ticks", "debug_keep_physics_during_pause",
]

enum Role { NONE, HOST, CLIENT }

var role: int = Role.NONE
var peer_id := 1
var map_path := ""
var status := "Offline"

var _server: TCPServer = null
var _client: StreamPeerTCP = null
var _client_state := {"tcp": null, "buf": PackedByteArray(), "out": [], "stats": _new_stats()}
var _peers := {}           # id -> {"tcp": StreamPeerTCP, "buf": PackedByteArray, "out": Array}
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
var _remote_targets := {}  # id -> {"x": Transform3D, "v": Vector3, "t": msec}
var _last_sent_states := {} # key -> last transform broadcast to peers

var _player_accum := 0.0
var _object_accum := 0.0
var _diff_accum := 0.0
var _full_state_accum := 0.0
var _force_full_snapshot := false
var _keepalive_accum := 0.0
var _tcp_connected_at := 0
var _client_connected_at := 0


func _new_stats() -> Dictionary:
	return {
		"sent_msgs": 0, "sent_bytes": 0, "recv_msgs": 0, "recv_bytes": 0,
		"dropped": 0, "last_send": 0, "last_recv": 0, "rtt_ms": 0.0,
		"sent_types": {}, "recv_types": {},
	}


## Absolute get_node() paths are invalid for Net instances created outside the
## active tree (headless protocol tests), so resolve through the tree root.
func _settings_node() -> Node:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath("Settings"))


func _ready() -> void:
	# Keep the connection alive while the in-game pause menu is open.
	process_mode = Node.PROCESS_MODE_ALWAYS
	var settings := _settings_node()
	if settings != null and not settings.changed.is_connected(_on_settings_changed):
		settings.changed.connect(_on_settings_changed)


func _on_settings_changed(key: String, _value: Variant) -> void:
	# The host's gameplay tuning is part of the session state. Any edit (or a
	# full reset) is propagated immediately; clients apply it in memory only.
	if role != Role.HOST:
		return
	if key == "__all__" or key == "__session__" or (key.begins_with("debug_") and key in GAMEPLAY_TUNING_KEYS):
		_broadcast_tuning()


func _gameplay_tuning() -> Dictionary:
	var settings := _settings_node()
	if settings == null:
		return {}
	var values := {}
	for key in GAMEPLAY_TUNING_KEYS:
		values[key] = settings.call("get_value", key, null)
	return values


func _broadcast_tuning() -> void:
	if role != Role.HOST:
		return
	_broadcast({"t": "tuning", "values": _gameplay_tuning()})


func _apply_tuning(values: Variant) -> void:
	if role != Role.CLIENT or not values is Dictionary:
		return
	var settings := _settings_node()
	if settings != null:
		settings.call("set_session_values", values)


func is_active() -> bool:
	return role != Role.NONE


## Structured snapshot used by the F3 debug overlay. Keeping this here avoids
## fragile reflection into the networking internals from the overlay script.
func debug_snapshot() -> Dictionary:
	var role_names := ["NONE", "HOST", "CLIENT"]
	var peers := {}
	for id in _peers.keys():
		var state: Dictionary = _peers.get(id, {})
		var tcp: StreamPeerTCP = state.get("tcp")
		var out: Array = state.get("out", [])
		peers[int(id)] = {
			"address": str(tcp.get_connected_host()) if tcp != null else "",
			"port": int(tcp.get_connected_port()) if tcp != null else 0,
			"local_port": int(tcp.get_local_port()) if tcp != null else 0,
			"socket_state": int(tcp.get_status()) if tcp != null else -1,
			"connected_ago_ms": Time.get_ticks_msec() - int(state.get("connected_at", Time.get_ticks_msec())),
			"queued_bytes": _queue_bytes(out),
			"queued_packets": out.size(),
			"stats": (state.get("stats", {}) as Dictionary).duplicate(true),
		}
	var client_tcp: StreamPeerTCP = _client_state.get("tcp")
	var client_out: Array = _client_state.get("out", [])
	return {
		"role": role,
		"role_name": role_names[clampi(role, 0, 2)],
		"status": status,
		"peer_id": peer_id,
		"map_path": map_path,
		"server_listening": _server != null and _server.is_listening(),
		"server_port": _server.get_local_port() if _server != null else 0,
		"known_peers": _known_peers.keys(),
		"next_peer_id": _next_peer_id,
		"peers": peers,
		"client_socket_state": int(client_tcp.get_status()) if client_tcp != null else -1,
		"client_address": str(client_tcp.get_connected_host()) if client_tcp != null else "",
		"client_port": int(client_tcp.get_connected_port()) if client_tcp != null else 0,
		"client_local_port": int(client_tcp.get_local_port()) if client_tcp != null else 0,
		"client_connected_ago_ms": Time.get_ticks_msec() - _tcp_connected_at if _tcp_connected_at > 0 else -1,
		"client_handshake_ago_ms": Time.get_ticks_msec() - _client_connected_at if _client_connected_at > 0 else -1,
		"client_queued_bytes": _queue_bytes(client_out),
		"client_queued_packets": client_out.size(),
		"client_stats": (_client_state.get("stats", {}) as Dictionary).duplicate(true),
		"objects": {
			"tracked": _objects.size(),
			"signatures": _signatures.size(),
			"last_sent_states": _last_sent_states.size(),
			"held": _held_by.size(),
			"detail": _debug_object_entries(),
		},
		"players": {
			"remote_visuals": _remote_players.size(),
			"remote_states": _remote_states.size(),
			"remote_targets": _remote_targets.size(),
		},
		"held_by": _held_by.duplicate(true),
		"holder_of": _holder_of.duplicate(true),
		"force_full_snapshot": _force_full_snapshot,
		"accumulators": {
			"player": _player_accum,
			"object": _object_accum,
			"diff": _diff_accum,
			"full_state": _full_state_accum,
			"keepalive": _keepalive_accum,
		},
		"constants": {
			"PLAYER_HZ": PLAYER_HZ,
			"OBJECT_HZ": OBJECT_HZ,
			"DIFF_HZ": DIFF_HZ,
			"FULL_STATE_HZ": FULL_STATE_HZ,
			"KEEPALIVE_HZ": KEEPALIVE_HZ,
			"SEND_BUDGET_PER_PEER": SEND_BUDGET_PER_PEER,
			"RECV_BUDGET_PER_PEER": RECV_BUDGET_PER_PEER,
			"MAX_OUT_QUEUE": MAX_OUT_QUEUE,
			"MAX_MESSAGES_PER_READ": MAX_MESSAGES_PER_READ,
			"MAX_ACCEPTS_PER_FRAME": MAX_ACCEPTS_PER_FRAME,
			"MAX_EXTRAPOLATION": MAX_EXTRAPOLATION,
			"MAX_PACKET": MAX_PACKET,
		},
	}


## Per-object physics summary for the F3 overlay. Read-only; never mutates the
## replicated world.
func _debug_object_entries() -> Array:
	var result := []
	for key in _objects.keys():
		var node = _objects.get(key)
		if not is_instance_valid(node) or not (node is RigidBody3D):
			continue
		var body := node as RigidBody3D
		var bounds := AABB()
		var found := false
		for child in body.find_children("*", "MeshInstance3D", true, false):
			if not (child is MeshInstance3D):
				continue
			var mesh: Mesh = (child as MeshInstance3D).mesh
			if mesh == null:
				continue
			var box: AABB = mesh.get_aabb()
			if not found:
				bounds = box
				found = true
			else:
				bounds = bounds.merge(box)
		result.append({
			"key": String(key),
			"name": String(body.name),
			"holder": int(_holder_of.get(String(key), -1)),
			"mass": float(body.mass),
			"gravity_scale": float(body.gravity_scale),
			"scale": body.scale,
			"size": bounds.size if found else Vector3.ZERO,
			"has_size": found,
			"position": body.global_position if body.is_inside_tree() else body.position,
			"linear_velocity": body.linear_velocity,
			"angular_velocity": body.angular_velocity,
			"linear_damp": float(body.linear_damp),
			"angular_damp": float(body.angular_damp),
			"freeze": body.freeze,
			"freeze_mode": int(body.freeze_mode),
			"sleeping": body.sleeping,
			"contact_monitor": body.contact_monitor,
			"collision_layer": int(body.collision_layer),
			"collision_mask": int(body.collision_mask),
		})
	return result


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
	_update_host_status(port)
	print("Net: hosting on port %d" % port)


func _update_host_status(port: int = -1) -> void:
	if role != Role.HOST:
		return
	var listening := _server != null and _server.is_listening()
	if _server != null:
		port = _server.get_local_port()
	var count := _peers.size()
	status = "Hosting port %d (%d peer%s, listening=%s)" % [port, count, "" if count == 1 else "s", str(listening)]


func join(address: String, port: int) -> void:
	reset()
	_client = StreamPeerTCP.new()
	var err := _client.connect_to_host(address, port)
	if err != OK:
		status = "Could not connect to %s:%d (error %d)" % [address, port, err]
		_client = null
		return
	# Nagle would hold small player/input packets until an ACK arrives.
	_client.set_no_delay(true)
	role = Role.CLIENT
	peer_id = -1
	_client_state = {"tcp": _client, "buf": PackedByteArray(), "out": [], "stats": _new_stats()}
	status = "Connecting to %s:%d..." % [address, port]


func reset() -> void:
	if role == Role.HOST and _peers.size() > 0:
		_broadcast({"t": "bye"})
		# Flush without blocking so peers actually learn the session is over.
		for state in _peers.values():
			_flush_outbound(state, state.get("tcp"), MAX_OUT_QUEUE)
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
	_client_state = {"tcp": null, "buf": PackedByteArray(), "out": [], "stats": _new_stats()}
	_peers.clear()
	_known_peers.clear()
	role = Role.NONE
	peer_id = 1
	map_path = ""
	status = "Offline"
	_forget_world()
	var settings := _settings_node()
	if settings != null:
		settings.call("clear_session_values")


func _forget_world() -> void:
	_world = null
	_object_root = null
	_objects.clear()
	_signatures.clear()
	_held_by.clear()
	_holder_of.clear()
	_remote_states.clear()
	_remote_targets.clear()
	_last_sent_states.clear()
	for node in _remote_players.values():
		if is_instance_valid(node) and node is Node:
			(node as Node).queue_free()
	_remote_players.clear()
	_player_accum = 0.0
	_object_accum = 0.0
	_diff_accum = 0.0
	_full_state_accum = 0.0
	_force_full_snapshot = false
	_keepalive_accum = 0.0
	_tcp_connected_at = 0
	_client_connected_at = 0


## Called by the file browser once the host has chosen a map.
func set_map_path(path: String) -> void:
	map_path = path
	if role == Role.HOST:
		_broadcast({"t": "map", "path": path})
		_broadcast_tuning()


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
		_update_host_status()
		_poll_server()
	else:
		_poll_client()
	_poll_messages()
	_update_remote_visuals()
	if role == Role.NONE:
		return

	# Delta snapshots can be completely empty (especially while the host is
	# still in the menu). Without any traffic, NATs/firewalls expire the TCP
	# mapping and the peer abruptly "disconnects". Keep a tiny packet flowing
	# in both directions regardless of scene state.
	_keepalive_accum += delta
	if _keepalive_accum >= 1.0 / KEEPALIVE_HZ:
		_keepalive_accum = 0.0
		var stamp := Time.get_ticks_msec()
		if role == Role.HOST:
			_broadcast({"t": "ping", "ts": stamp})
		else:
			_send_to(1, {"t": "ping", "ts": stamp})

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

		_full_state_accum += delta
		if _full_state_accum >= 1.0 / FULL_STATE_HZ:
			_full_state_accum = 0.0
			_force_full_snapshot = true


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
		if state == null:
			continue
		var tcp: StreamPeerTCP = state.get("tcp")
		if tcp == null:
			_remove_peer(int(id))
			continue
		# Accepted sockets need polling too, otherwise status never changes and
		# we keep writing to a peer that already hung up.
		tcp.poll()
		var tcp_state := tcp.get_status()
		if tcp_state == StreamPeerTCP.STATUS_NONE or tcp_state == StreamPeerTCP.STATUS_ERROR:
			var reason := "socket error" if tcp_state == StreamPeerTCP.STATUS_ERROR else "connection closed by peer"
			var held := Time.get_ticks_msec() - int(state.get("connected_at", Time.get_ticks_msec()))
			print("Net: peer %d %s after %d ms" % [int(id), reason, held])
			_remove_peer(int(id))
			continue
		_flush_outbound(state, tcp, SEND_BUDGET_PER_PEER)

	var accepted := 0
	while accepted < MAX_ACCEPTS_PER_FRAME and _server.is_connection_available():
		var tcp := _server.take_connection()
		if tcp == null:
			break
		accepted += 1
		tcp.set_no_delay(true)
		var id := _next_peer_id
		_next_peer_id += 1
		var state := {"tcp": tcp, "buf": PackedByteArray(), "out": [], "stats": _new_stats(), "connected_at": Time.get_ticks_msec()}
		_peers[id] = state
		_known_peers[id] = true
		print("Net: peer %d connected from %s:%d" % [id, tcp.get_connected_host(), tcp.get_connected_port()])
		_ensure_remote_player(id)
		var players: Array = [1]
		for known in _known_peers:
			players.append(int(known))
		_update_host_status()
		_send_to(id, {
			"t": "hello", "id": id, "map": map_path,
			"players": players, "tuning": _gameplay_tuning(),
		})
		# Late joiners need objects that existed before they connected.
		for key in _objects.keys():
			var object = _objects.get(key)
			if _object_usable(object, key):
				_send_to(id, _spawn_msg(key, object))
		_flush_outbound(state, tcp, SEND_BUDGET_PER_PEER)


func _poll_client() -> void:
	if _client == null:
		return
	_client.poll()
	var state := _client.get_status()
	if state == StreamPeerTCP.STATUS_CONNECTED:
		_client_state["tcp"] = _client
		if status.begins_with("Connecting"):
			_tcp_connected_at = Time.get_ticks_msec()
			status = "Waiting for host..."
			print("Net: TCP connection established, waiting for host handshake")
		_flush_outbound(_client_state, _client, SEND_BUDGET_PER_PEER)
	elif state == StreamPeerTCP.STATUS_ERROR or state == StreamPeerTCP.STATUS_NONE:
		var never_connected := _tcp_connected_at == 0
		var no_handshake := _client_connected_at == 0
		var connected_ms := Time.get_ticks_msec() - _client_connected_at
		if not status.begins_with("Disconnected") and not status.begins_with("Could not reach"):
			if never_connected:
				print("Net: TCP connect timed out - host unreachable at %s" % status)
			else:
				var reason := "socket error" if state == StreamPeerTCP.STATUS_ERROR else "connection closed by peer"
				var held := "before handshake" if _client_connected_at == 0 else "after %d ms" % (Time.get_ticks_msec() - _client_connected_at)
				print("Net: client %s %s, giving up" % [reason, held])
		reset()
		if never_connected:
			status = "Could not reach host - check IP / port forward / firewall"
		elif no_handshake:
			status = "Connected but host never replied - check host process"
		else:
			status = "Disconnected from host after %ds" % (connected_ms / 1000)
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
	var tcp: StreamPeerTCP = state.get("tcp")
	if tcp == null or tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return []
	var budget := RECV_BUDGET_PER_PEER
	var received_bytes := 0
	while budget > 0:
		# get_data() blocks until the requested byte count arrives; partial
		# reads return immediately and let a slow peer hold up nobody.
		var result: Array = tcp.get_partial_data(mini(budget, 64 * 1024))
		if result.size() != 2 or int(result[0]) != OK:
			break
		var data: PackedByteArray = result[1]
		if data.is_empty():
			break
		budget -= data.size()
		received_bytes += data.size()
		var buf: PackedByteArray = state.get("buf", PackedByteArray())
		buf.append_array(data)
		state["buf"] = buf
	var messages: Array = _parse_buffer(state)
	if received_bytes > 0 or not messages.is_empty():
		var st := _stats_for(state)
		st["recv_bytes"] = int(st["recv_bytes"]) + received_bytes
		st["recv_msgs"] = int(st["recv_msgs"]) + messages.size()
		st["last_recv"] = Time.get_ticks_msec()
	return messages


func _parse_buffer(state: Dictionary) -> Array:
	var out: Array = []
	var buf: PackedByteArray = state.get("buf", PackedByteArray())
	var offset := 0
	while buf.size() - offset >= 4 and out.size() < MAX_MESSAGES_PER_READ:
		var size := (int(buf[offset]) << 24) | (int(buf[offset + 1]) << 16) | (int(buf[offset + 2]) << 8) | int(buf[offset + 3])
		if size <= 0 or size > MAX_PACKET:
			buf = PackedByteArray()
			offset = 0
			break
		if buf.size() - offset < 4 + size:
			break
		var payload := buf.slice(offset + 4, offset + 4 + size)
		offset += 4 + size
		var parsed = JSON.parse_string(payload.get_string_from_utf8())
		if parsed is Dictionary:
			out.append(parsed)
	if offset > 0:
		state["buf"] = buf.slice(offset)
	else:
		state["buf"] = buf
	return out


func _pack_packet(msg: Dictionary) -> PackedByteArray:
	var payload := JSON.stringify(msg).to_utf8_buffer()
	var size := payload.size()
	var packet := PackedByteArray()
	packet.append((size >> 24) & 0xFF)
	packet.append((size >> 16) & 0xFF)
	packet.append((size >> 8) & 0xFF)
	packet.append(size & 0xFF)
	packet.append_array(payload)
	return packet


func _send_to(id: int, msg: Dictionary, transient: bool = false) -> void:
	var state: Dictionary = {}
	if role == Role.HOST:
		state = _peers.get(id, {})
	elif role == Role.CLIENT and id == 1:
		state = _client_state
	if state.is_empty():
		return
	_record_type(state, "sent", String(msg.get("t", "")))
	_queue_packet(state, _pack_packet(msg), transient)


func _broadcast(msg: Dictionary, except_id: int = -1, transient: bool = false) -> void:
	if role != Role.HOST:
		return
	# Serialize once, then enqueue the same bytes for every peer.
	var packet := _pack_packet(msg)
	for id in _peers.keys():
		if int(id) == except_id:
			continue
		var state: Dictionary = _peers.get(id, {})
		if not state.is_empty():
			_record_type(state, "sent", String(msg.get("t", "")))
			_queue_packet(state, packet, transient)


## Append a framed packet to a peer's outbound queue. Transient updates
## (player/object snapshots) supersede older ones: a lagging peer gets the
## freshest state instead of seconds of stale snapshots. A packet that is
## already partly written is always finished so the stream stays framed.
func _stats_for(state: Dictionary) -> Dictionary:
	if not state.has("stats"):
		state["stats"] = _new_stats()
	return state["stats"]


func _record_rtt(state: Dictionary, sample_ms: float) -> void:
	if sample_ms < 0.0 or sample_ms > 60000.0:
		return
	var st := _stats_for(state)
	var previous := float(st.get("rtt_ms", 0.0))
	st["rtt_ms"] = sample_ms if previous <= 0.0 else lerpf(previous, sample_ms, 0.25)


func _record_type(state: Dictionary, direction: String, t: String) -> void:
	if t.is_empty():
		return
	var st := _stats_for(state)
	var key: String = direction + "_types"
	var types: Dictionary = st.get(key, {})
	types[t] = int(types.get(t, 0)) + 1
	st[key] = types


func _queue_packet(state: Dictionary, packet: PackedByteArray, transient: bool) -> void:
	var queue: Array = state.get("out", [])
	if transient:
		var kept: Array = []
		for i in queue.size():
			var item: Dictionary = queue[i]
			var sent := int(item.get("sent", 0))
			var data: PackedByteArray = item.get("data", PackedByteArray())
			if (i == 0 and sent > 0 and sent < data.size()) or not bool(item.get("transient", false)):
				kept.append(item)
		var dropped := queue.size() - kept.size()
		if dropped > 0:
			var st := _stats_for(state)
			st["dropped"] = int(st["dropped"]) + dropped
		queue = kept
	queue.append({"data": packet, "sent": 0, "transient": transient})
	state["out"] = queue
	if _queue_bytes(queue) > MAX_OUT_QUEUE:
		# Backpressure is handled by superseding transient updates, not by
		# kicking a peer with a slow link. Keep control traffic queued.
		push_warning("Network peer is behind on snapshots; older ones dropped.")
		var kept: Array = []
		for item in queue:
			var data: PackedByteArray = item.get("data", PackedByteArray())
			var sent := int(item.get("sent", 0))
			if (sent > 0 and sent < data.size()) or not bool(item.get("transient", false)):
				kept.append(item)
		var dropped := queue.size() - kept.size()
		if dropped > 0:
			var st := _stats_for(state)
			st["dropped"] = int(st["dropped"]) + dropped
		state["out"] = kept


func _queue_bytes(queue: Array) -> int:
	var total := 0
	for item in queue:
		var data: PackedByteArray = item.get("data", PackedByteArray())
		total += data.size() - int(item.get("sent", 0))
	return total


## Push at most `budget` bytes into the socket without ever blocking.
func _flush_outbound(state: Dictionary, tcp: StreamPeerTCP, budget: int) -> void:
	if tcp == null or tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var queue: Array = state.get("out", [])
	var st := _stats_for(state)
	while not queue.is_empty() and budget > 0:
		var item: Dictionary = queue[0]
		var data: PackedByteArray = item.get("data", PackedByteArray())
		var sent := int(item.get("sent", 0))
		if sent >= data.size():
			queue.pop_front()
			continue
		var chunk := data.slice(sent, sent + mini(data.size() - sent, budget))
		var result: Array = tcp.put_partial_data(chunk)
		if result.size() != 2 or int(result[0]) != OK:
			break
		var wrote := int(result[1])
		if wrote <= 0:
			break
		item["sent"] = sent + wrote
		budget -= wrote
		st["sent_bytes"] = int(st["sent_bytes"]) + wrote
		st["last_send"] = Time.get_ticks_msec()
		if int(item["sent"]) >= data.size():
			queue.pop_front()
			st["sent_msgs"] = int(st["sent_msgs"]) + 1
	state["out"] = queue


func _route(msg: Dictionary) -> void:
	if role == Role.HOST:
		_broadcast(msg)
	elif role == Role.CLIENT:
		_send_to(1, msg)


# --------------------------------------------------------------- messages ---

func _handle_message(id: int, msg: Dictionary) -> void:
	var t := String(msg.get("t", ""))
	var msg_state: Dictionary = _peers.get(id, {}) if role == Role.HOST else _client_state
	if not msg_state.is_empty():
		_record_type(msg_state, "recv", t)
	if role == Role.HOST:
		match t:
			"player":
				_known_peers[id] = true
				_remote_states[id] = msg
				_apply_player_state(id, msg)
				_broadcast(msg, id, true)
			"req":
				_handle_request(id, msg)
			"bye":
				_remove_peer(id, false)
			"ping":
				# Reply so the host can measure RTT as well as keep the NAT open.
				if msg.has("ts"):
					_send_to(id, {"t": "pong", "ts": int(msg["ts"])})
			"pong":
				if msg.has("ts"):
					var state: Dictionary = _peers.get(id, {})
					if not state.is_empty():
						_record_rtt(state, float(Time.get_ticks_msec() - int(msg["ts"])))
	else:
		match t:
			"ping":
				if msg.has("ts"):
					_send_to(1, {"t": "pong", "ts": int(msg["ts"])})
			"pong":
				if msg.has("ts"):
					_record_rtt(_client_state, float(Time.get_ticks_msec() - int(msg["ts"])))
			"hello":
				_client_connected_at = Time.get_ticks_msec()
				peer_id = int(msg.get("id", -1))
				map_path = String(msg.get("map", ""))
				for p in msg.get("players", []):
					_known_peers[int(p)] = true
				status = "Connected as P%d" % peer_id
				_apply_tuning(msg.get("tuning", {}))
				_ensure_remote_player(1)
				if map_path != "":
					_load_map(map_path)
			"map":
				map_path = String(msg.get("path", ""))
				if map_path != "":
					_load_map(map_path)
			"tuning":
				_apply_tuning(msg.get("values", {}))
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
	if _peers.has(id):
		print("Net: peer %d disconnected" % id)
	_peers.erase(id)
	if role == Role.HOST:
		_update_host_status()
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
	_remote_targets.erase(id)


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
	_last_sent_states.erase(key)
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
		if not _object_usable(object, key, false):
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

	# Copy the local player's authored capsule instead of assuming engine
	# defaults ( CapsuleMesh is radius 0.5 / height 2.0 here, not 0.3 / 1.0 ).
	var source_body: MeshInstance3D = null
	var source_eyes: Sprite3D = null
	var local := _local_player()
	if local != null:
		for node in local.find_children("*", "MeshInstance3D", true, false):
			source_body = node as MeshInstance3D
			break
		for node in local.find_children("*", "Sprite3D", true, false):
			source_eyes = node as Sprite3D
			break
	var mesh := CapsuleMesh.new()
	if source_body != null and source_body.mesh is CapsuleMesh:
		var source_mesh := source_body.mesh as CapsuleMesh
		mesh.radius = source_mesh.radius
		mesh.height = source_mesh.height
	else:
		mesh.radius = 0.5
		mesh.height = 2.0
	var body := MeshInstance3D.new()
	body.mesh = mesh
	body.scale = source_body.scale if source_body != null else Vector3.ONE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.25, 0.75, 1.0)
	body.material_override = material
	root.add_child(body)

	var scaled_radius: float = mesh.radius * body.scale.x
	var scaled_height: float = mesh.height * body.scale.y

	# Copy the real first-person Sprite3D instead of rebuilding it: its squashed
	# aspect, texture and material are exactly what the local capsule shows.
	# Only its scale and position change so it sits on the third-person body.
	var eyes: Sprite3D = null
	if source_eyes != null and local != null:
		eyes = source_eyes.duplicate() as Sprite3D
		var local_relative: Transform3D = local.global_transform.affine_inverse() * source_eyes.global_transform
		var basis := local_relative.basis
		basis = Basis(basis.x * REMOTE_EYES_SCALE, basis.y * REMOTE_EYES_SCALE, basis.z * REMOTE_EYES_SCALE)
		eyes.transform = Transform3D(basis, Vector3(0, scaled_height * 0.35, -scaled_radius - 0.01))
	elif load(EYES_TEXTURE_PATH) != null:
		eyes = Sprite3D.new()
		eyes.texture = load(EYES_TEXTURE_PATH)
		var eye_scale := 0.008
		eyes.transform = Transform3D(
			Vector3(-eye_scale, 0, 0),
			Vector3(0, eye_scale, 0),
			Vector3(0, 0, -eye_scale),
			Vector3(0, scaled_height * 0.35, -scaled_radius - 0.01)
		)
	if eyes != null:
		root.add_child(eyes)

	var label := Label3D.new()
	label.text = "P%d" % id
	label.position = Vector3(0, scaled_height * 0.5 + 0.25, 0)
	label.font_size = 32
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
		_broadcast(msg, -1, true)
	else:
		_send_to(1, msg, true)


func _apply_player_state(id: int, msg: Dictionary) -> void:
	var pose := _unpack_xform(msg.get("x", []))
	_remote_targets[id] = {
		"x": pose,
		"v": _unpack_v(msg.get("v", [])),
		"t": Time.get_ticks_msec()
	}
	var visual := _ensure_remote_player(id)
	if visual != null:
		visual.global_transform = pose


## Remote poses arrive regularly but always lag by at least half an RTT.
## Carry them forward with the last known velocity so distant players don't
## look like they are moving in the past. Capped so a lost packet can't send
## a capsule flying across the map.
func _update_remote_visuals() -> void:
	var now := Time.get_ticks_msec()
	for id in _remote_players.keys():
		var target: Dictionary = _remote_targets.get(int(id), {})
		if target.is_empty():
			continue
		var visual = _remote_players.get(id)
		if not (is_instance_valid(visual) and visual is Node3D):
			continue
		var age := minf(float(now - int(target.get("t", now))) / 1000.0, MAX_EXTRAPOLATION)
		var pose: Transform3D = target.get("x", Transform3D.IDENTITY)
		if age > 0.0:
			pose.origin += (target.get("v", Vector3.ZERO) as Vector3) * age
		(visual as Node3D).global_transform = pose


# ----------------------------------------------------------------- objects ---

func _send_object_states() -> void:
	var states: Array = []
	for key in _objects.keys():
		var node = _objects.get(key)
		# A queued-for-deletion node can still be valid for a frame after it
		# leaves the scene tree. Drop it from the caches instead of calling
		# global_transform() on it (which errors and returns IDENTITY).
		if not _object_usable(node, key):
			continue
		var x := _pack_xform((node as RigidBody3D).global_transform)
		var previous: Array = _last_sent_states.get(key, [])
		# A periodic full resync also keeps NAT/firewall mappings alive when
		# the scene is at rest and delta snapshots would be empty.
		if not _force_full_snapshot and previous.size() == x.size():
			var unchanged := true
			# Values are quantized, so identical transforms compare exactly;
			# is_equal_approx() would hide small moves at large coordinates.
			for i in x.size():
				if previous[i] != x[i]:
					unchanged = false
					break
			if unchanged:
				continue
		# TCP is reliable and ordered: peers already have every transform we
		# skipped, so only send objects that actually moved.
		_last_sent_states[key] = x
		states.append([key, x])
	_force_full_snapshot = false
	if states.is_empty():
		return
	_broadcast({"t": "states", "states": states}, -1, true)


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


## True only for a live RigidBody3D that is still attached to the scene tree.
## Stale entries are purged so the 30 Hz snapshot loop never touches a freed
## node (and so a despawn is not missed if the diff scan is late).
func _object_usable(node: Object, key: String = "", purge: bool = true) -> bool:
	if is_instance_valid(node) and node is RigidBody3D and (node as Node3D).is_inside_tree():
		return true
	if purge and key != "" and _objects.has(key):
		_objects.erase(key)
		_signatures.erase(key)
		_last_sent_states.erase(key)
		if _holder_of.has(key):
			_held_by.erase(_holder_of[key])
			_holder_of.erase(key)
	return false


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


## Only the outermost RigidBody3D of an object is networked. Decorative /
## internal physics (snowglobe flakes, the orb's inner bodies, ...) is left to
## run locally on each peer. Add a body to the `net_ignore` group to opt a
## whole top-level body out as well.
func _collect(node: Node, out: Dictionary) -> void:
	for child in node.get_children():
		if not is_instance_valid(child):
			continue
		if child is RigidBody3D:
			if child.is_in_group("net_ignore"):
				continue
			var key := _key_for(child)
			if key != "":
				out[key] = child
			# Don't descend into it: children with their own physics are local.
			continue
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
	_last_sent_states.erase(key)
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
	if not _object_usable(node, key):
		return
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
	_last_sent_states.erase(key)
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

## Round to millimetres: sub-millimetre digits are pure bandwidth waste in a
## 30 Hz JSON snapshot and make delta comparisons noisy.
func _q(v: float) -> float:
	return snappedf(v, 0.001)


func _pack_xform(x: Transform3D) -> Array:
	var b := x.basis
	return [
		_q(b.x.x), _q(b.x.y), _q(b.x.z),
		_q(b.y.x), _q(b.y.y), _q(b.y.z),
		_q(b.z.x), _q(b.z.y), _q(b.z.z),
		_q(x.origin.x), _q(x.origin.y), _q(x.origin.z)
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
	return [_q(v.x), _q(v.y), _q(v.z)]


func _unpack_v(a: Array) -> Vector3:
	if a.size() < 3:
		return Vector3.ZERO
	return Vector3(a[0], a[1], a[2])
