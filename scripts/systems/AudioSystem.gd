class_name CHAudioSystem
extends Node
# Procedural audio layer for the counting house trainer.
# Generates short SFX (deal, win, loss) as AudioStreamWAV at startup and
# plays them through an AudioStreamPlayer. No external asset files required.
#
# Headless-safe: when the display server is "headless", all play calls are
# no-ops so the 28-tool test suite runs without audio side effects.

var _player: AudioStreamPlayer
var _deal_stream: AudioStreamWAV
var _win_stream: AudioStreamWAV
var _loss_stream: AudioStreamWAV
var _ambient_player: AudioStreamPlayer
var _ambient_stream: AudioStreamWAV
var _headless: bool = false
var _current_band: String = "calm"


const BAND_VOLUMES: Dictionary = {
	"calm": 0.0,
	"strained": 0.08,
	"fraying": 0.15,
	"insane": 0.25,
}


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if _headless:
		return

	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	add_child(_player)

	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.bus = "Master"
	add_child(_ambient_player)

	_deal_stream = _make_click(0.04)
	_win_stream = _make_tone(0.2, 440.0, 660.0, 0.25)
	_loss_stream = _make_tone(0.2, 330.0, 220.0, 0.25)
	_ambient_stream = _make_drone(2.0, 80.0)
	_ambient_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD

	_ambient_player.stream = _ambient_stream
	_ambient_player.volume_db = _band_volume_db(_current_band)
	_ambient_player.play()


func play_deal() -> void:
	if _headless or _player == null:
		return
	_player.stream = _deal_stream
	_player.play()


func play_win() -> void:
	if _headless or _player == null:
		return
	_player.stream = _win_stream
	_player.play()


func play_loss() -> void:
	if _headless or _player == null:
		return
	_player.stream = _loss_stream
	_player.play()


func set_band(band: String) -> void:
	_current_band = band
	if _headless or _ambient_player == null:
		return
	_ambient_player.volume_db = _band_volume_db(band)


func _band_volume_db(band: String) -> float:
	var vol: float = BAND_VOLUMES.get(band, 0.0)
	if vol <= 0.0:
		return -80.0
	return linear_to_db(vol)


func _make_click(duration: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t := float(i) / float(samples)
		var envelope: float = (1.0 - t) * (1.0 - t)
		var noise: float = randf_range(-1.0, 1.0)
		var value: int = int(noise * envelope * 16000)
		data[i * 2] = value & 0xFF
		data[i * 2 + 1] = (value >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream


func _make_tone(duration: float, freq_start: float, freq_end: float, volume: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var t := float(i) / float(samples)
		var freq := lerpf(freq_start, freq_end, t)
		var phase := TAU * freq * float(i) / float(sample_rate)
		var envelope := (1.0 - t) * 0.8 + 0.2
		var value: int = int(sin(phase) * envelope * volume * 32767.0)
		data[i * 2] = value & 0xFF
		data[i * 2 + 1] = (value >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream


func _make_drone(duration: float, freq: float) -> AudioStreamWAV:
	var sample_rate := 44100
	var samples := int(duration * sample_rate)
	var data := PackedByteArray()
	data.resize(samples * 2)
	for i in samples:
		var _t := float(i) / float(samples)
		var phase := TAU * freq * float(i) / float(sample_rate)
		var value: int = int(sin(phase) * 32767.0 * 0.5)
		data[i * 2] = value & 0xFF
		data[i * 2 + 1] = (value >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = sample_rate
	stream.stereo = false
	stream.data = data
	return stream
