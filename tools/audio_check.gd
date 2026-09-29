extends SceneTree
# Headless validation for CHAudioSystem (procedural SFX + ambient band volumes).
#
#   1. Headless detection: under --headless the system flags itself and all
#      play calls become no-ops (no AudioStreamPlayer nodes created).
#   2. Stream builders: _make_click / _make_tone / _make_drone produce
#      correctly-sized 16-bit mono WAV buffers at 44.1 kHz.
#   3. Band volume mapping: calm maps to -80 dB (silent), louder bands map to
#      linear_to_db of their configured linear volume, insane is the loudest.
#   4. No-crash: play_deal / play_win / play_loss / set_band run cleanly
#      headless (guarded no-ops).

var _failures: Array[String] = []
var _systems: Array[CHAudioSystem] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	_check_headless_detection()
	_check_stream_builders()
	_check_band_volume_mapping()
	_check_noop_calls()
	for sys in _systems:
		sys.free()

	if _failures.is_empty():
		print("audio_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("audio_check: %d failure(s)" % _failures.size())
		quit(1)


func _make_system() -> CHAudioSystem:
	var sys: CHAudioSystem = CHAudioSystem.new()
	# Headless: _ready() returns early after flagging, so players/stays null.
	sys._ready()
	_systems.append(sys)
	return sys


# --- 1. Headless detection ---
func _check_headless_detection() -> void:
	var sys := _make_system()
	_expect(sys._headless == true, "headless: _headless flag set under --headless")
	_expect(sys._player == null, "headless: no AudioStreamPlayer created")
	_expect(sys._ambient_player == null, "headless: no ambient player created")


# --- 2. Stream builders ---
func _check_stream_builders() -> void:
	var sys := _make_system()
	var click := sys._make_click(0.04)
	_expect(click != null, "click: stream built")
	_expect(click.format == AudioStreamWAV.FORMAT_16_BITS, "click: 16-bit format")
	_expect(click.mix_rate == 44100, "click: 44100 mix rate")
	_expect(click.stereo == false, "click: mono")
	_expect(click.data.size() == int(0.04 * 44100) * 2, "click: byte size = samples*2, got %d" % click.data.size())

	var win := sys._make_tone(0.2, 440.0, 660.0, 0.25)
	_expect(win != null and win.data.size() == int(0.2 * 44100) * 2, "win tone: byte size, got %d" % (win.data.size() if win else -1))

	var loss := sys._make_tone(0.2, 330.0, 220.0, 0.25)
	_expect(loss != null and loss.data.size() == int(0.2 * 44100) * 2, "loss tone: byte size, got %d" % (loss.data.size() if loss else -1))

	var drone := sys._make_drone(2.0, 80.0)
	_expect(drone != null and drone.data.size() == int(2.0 * 44100) * 2, "drone: byte size, got %d" % (drone.data.size() if drone else -1))


# --- 3. Band volume mapping ---
func _check_band_volume_mapping() -> void:
	var sys := _make_system()
	_expect(sys._band_volume_db("calm") == -80.0, "band: calm is silent (-80 dB), got %s" % str(sys._band_volume_db("calm")))
	var strained: float = sys._band_volume_db("strained")
	var fraying: float = sys._band_volume_db("fraying")
	var insane: float = sys._band_volume_db("insane")
	_expect(absf(strained - linear_to_db(0.08)) < 0.001, "band: strained = linear_to_db(0.08), got %s" % str(strained))
	_expect(absf(fraying - linear_to_db(0.15)) < 0.001, "band: fraying = linear_to_db(0.15), got %s" % str(fraying))
	_expect(absf(insane - linear_to_db(0.25)) < 0.001, "band: insane = linear_to_db(0.25), got %s" % str(insane))
	_expect(strained < fraying and fraying < insane, "band: volume ordering strained < fraying < insane")
	_expect(sys._band_volume_db("unknown_band") == -80.0, "band: unknown band falls back to silent")


# --- 4. No-crash no-ops ---
func _check_noop_calls() -> void:
	var sys := _make_system()
	sys.play_deal()
	sys.play_win()
	sys.play_loss()
	sys.set_band("insane")
	sys.set_band("calm")
	_expect(sys._current_band == "calm", "noop: set_band updates _current_band")
