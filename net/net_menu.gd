extends Control

## Tiny host/join screen. The host picks a map next; clients wait here until
## the host sends the map path over the connection.

@onready var address_edit: LineEdit = $Panel/VBox/Address
@onready var port_edit: LineEdit = $Panel/VBox/Port
@onready var host_button: Button = $Panel/VBox/HostButton
@onready var join_button: Button = $Panel/VBox/JoinButton
@onready var back_button: Button = $Panel/VBox/BackButton
@onready var status_label: Label = $Panel/VBox/Status
@onready var hint_label: Label = $Panel/VBox/Hint


func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	back_button.pressed.connect(_on_back_pressed)


func _process(_delta: float) -> void:
	status_label.text = "Status: " + Net.status


func _port() -> int:
	var value := int(port_edit.text.strip_edges())
	if value < 1 or value > 65535:
		Net.status = "Port must be between 1 and 65535"
		return -1
	return value


func _on_host_pressed() -> void:
	var port := _port()
	if port < 0:
		return
	Net.host(port)
	if Net.is_active():
		get_tree().change_scene_to_file("res://gui/fb.tscn")


func _on_join_pressed() -> void:
	var port := _port()
	if port < 0:
		return
	var address := address_edit.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	Net.join(address, port)


func _on_back_pressed() -> void:
	Net.reset()
	get_tree().change_scene_to_file("res://gui/menu.tscn")
