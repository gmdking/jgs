extends Node
## Shared UI click/hover sounds with voice pools. Autoloaded as `UISounds` so
## every menu can use the same streams without owning its own players.

const CLICK_STREAM = preload("res://gui/sources/click2.wav")
const HOVER_STREAM = preload("res://gui/sources/click1.wav")
const VOICES := 12

var click_voices: Array[AudioStreamPlayer] = []
var hover_voices: Array[AudioStreamPlayer] = []
var click_cursor := 0
var hover_cursor := 0


func _ready() -> void:
	# Menus can be shown while the SceneTree is paused; sounds must still play.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_pool(click_voices, CLICK_STREAM)
	_build_pool(hover_voices, HOVER_STREAM)


func play_click() -> void:
	click_cursor = _play(click_voices, click_cursor)


func play_hover() -> void:
	hover_cursor = _play(hover_voices, hover_cursor)


func _build_pool(pool: Array[AudioStreamPlayer], stream: AudioStream) -> void:
	for _i in VOICES:
		var voice := AudioStreamPlayer.new()
		voice.stream = stream
		voice.bus = "SFX"
		# Web exports default to stream playback for this project; set it here
		# as well so these pooled voices work even with older saved settings.
		voice.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
		add_child(voice)
		pool.append(voice)


func _play(pool: Array[AudioStreamPlayer], cursor: int) -> int:
	if pool.is_empty():
		return cursor
	for i in pool.size():
		var voice := pool[(cursor + i) % pool.size()]
		if not voice.playing:
			voice.play()
			return (cursor + i + 1) % pool.size()
	# All voices busy: reuse the oldest one rather than dropping the sound.
	pool[cursor % pool.size()].play()
	return (cursor + 1) % pool.size()
