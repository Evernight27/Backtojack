extends SceneTree
# Headless validation for CHHeatSystem (M8) — the suspicion / backoff model.
#
#   1. Tell + decay: on_tell adds gain*sensitivity; on_hand sheds a fixed
#      DECAY_PER_HAND; values stay clamped to [0, MAX].
#   2. Sensitivity: the tier multiplier scales every tell gain.
#   3. Backoff latch: heat >= threshold latches pending_backoff; decay does NOT
#      clear it; reset(floor) clears it and re-seats heat at the floor.
#   4. Loop wiring (heat_active=false): heat is never built (stays at floor).
#   5. Loop wiring (heat_active=true): a latched backoff is resolved on the next
#      begin_hand — heat_backoff emits and heat resets to the tier floor.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906


var _failures: Array[String] = []


func _init() -> void:
	_check_model_tell_and_decay()
	_check_model_sensitivity()
	_check_model_backoff_latch()
	_check_loop_inactive()
	_check_loop_backoff_resets()

	if _failures.is_empty():
		print("heat_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("heat_check: %d failure(s)" % _failures.size())
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _make_loop(p_heat_active: bool) -> CHGameLoop:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.allows_split = true
	c.max_split_hands = 4
	c.split_aces_one_card_only = true
	c.allows_double_after_split = true
	c.allows_insurance = true
	c.heat_active = p_heat_active
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_PRACTICE)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(c, state, disc, SEED)


# Settles whatever hand is in play so the loop returns to an idle state.
func _finish_hand(loop: CHGameLoop) -> void:
	if loop.phase() == CHGameLoop.PHASE_BET:
		loop.place_bet(loop.optimal_bet_units())
	var guard := 0
	while not loop.is_idle() and guard < 64:
		loop.apply_action(loop.optimal_action())
		guard += 1


# --- 1. Tell + decay ---
func _check_model_tell_and_decay() -> void:
	var h := CHHeatSystem.new()
	h.reset(0.0)
	var d1: float = h.on_tell(CHHeatSystem.BET_TELL_GAIN)
	_expect(absf(d1 - 6.0) < 0.001, "tell gain base = 6.0, got %s" % d1)
	_expect(absf(h.heat - 6.0) < 0.001, "heat after tell = 6, got %s" % h.heat)
	var d2: float = h.on_hand()
	_expect(absf(d2 - CHHeatSystem.DECAY_PER_HAND) < 0.001, "decay = %s, got %s" % [CHHeatSystem.DECAY_PER_HAND, d2])
	_expect(absf(h.heat - (6.0 - CHHeatSystem.DECAY_PER_HAND)) < 0.001, "heat after decay, got %s" % h.heat)
	# Clamps at the ceiling.
	h.reset(95.0)
	h.on_tell(100.0)
	_expect(h.heat == CHHeatSystem.MAX_HEAT, "heat clamps at MAX, got %s" % h.heat)


# --- 2. Sensitivity ---
func _check_model_sensitivity() -> void:
	var h := CHHeatSystem.new()
	h.reset(0.0)
	h.apply_sensitivity(2.0)
	var d: float = h.on_tell(CHHeatSystem.DEV_TELL_GAIN)
	_expect(absf(d - 4.0) < 0.001, "sensitivity-scaled tell = 4.0, got %s" % d)


# --- 3. Backoff latch ---
func _check_model_backoff_latch() -> void:
	var h := CHHeatSystem.new()
	h.reset(0.0)
	h.apply_sensitivity(1.0)
	var guard := 0
	while not h.has_pending_backoff() and guard < 1000:
		h.on_tell(CHHeatSystem.BET_TELL_GAIN)
		guard += 1
	_expect(h.heat >= CHHeatSystem.BACKOFF_THRESHOLD, "heat >= threshold, got %s" % h.heat)
	_expect(h.has_pending_backoff(), "backoff latched at threshold")
	h.on_hand()
	_expect(h.has_pending_backoff(), "decay does not clear the backoff latch")
	h.reset(0.0)
	_expect(not h.has_pending_backoff(), "reset clears the backoff latch")
	_expect(h.heat == 0.0, "heat re-seated to floor after reset, got %s" % h.heat)


# --- 4. Loop wiring: heat inactive ---
func _check_loop_inactive() -> void:
	var loop := _make_loop(false)
	for i in 20:
		if not loop.begin_hand():
			break
		_finish_hand(loop)
	_expect(loop.heat() == 0.0, "heat inactive stays at floor, got %s" % loop.heat())
	_expect(not loop.needs_backoff(), "no backoff when heat inactive")


# --- 5. Loop wiring: backoff resolved on next begin_hand ---
func _check_loop_backoff_resets() -> void:
	var loop := _make_loop(true)
	if not loop.begin_hand():
		_failures.append("begin_hand returned false on a fresh session")
		return
	# Force a latched backoff through the live model.
	var h: CHHeatSystem = loop.get_heat_system()
	var guard := 0
	while not h.has_pending_backoff() and guard < 1000:
		h.on_tell(CHHeatSystem.BET_TELL_GAIN)
		guard += 1
	if not h.has_pending_backoff():
		_failures.append("could not latch a backoff in the loop")
		return
	_finish_hand(loop)
	# Lambdas capture by value in GDScript, so use a Dictionary (by reference)
	# to record whether the signal fired.
	var flag := {"emitted": false}
	loop.heat_backoff.connect(func(): flag.emitted = true)
	loop.begin_hand()
	_expect(bool(flag.emitted), "heat_backoff emitted when backoff is resolved")
	_expect(loop.heat() == 0.0, "heat reset to floor (0) after backoff, got %s" % loop.heat())
	_expect(not loop.needs_backoff(), "backoff cleared after resolution")
