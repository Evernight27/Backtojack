extends SceneTree
# Headless validation for the per-tier mental-stability profiles (CHMentalConfig)
# and the "going insane" spiral wiring (M-spiral):
#
#   1. Per-tier profiles — CHMentalConfig.for_tier() returns the expected
#      erosion / recovery / band thresholds / insane amplifier / heat link for
#      every tier. Tiers 1-2 keep the historical defaults; the ladder tightens
#      as the table gets harder.
#   2. Monotonic ladder — harder tiers erode faster (bigger mistake base, higher
#      escalation), recover slower (smaller recovery base), and flip insane at a
#      lower stability. The teaching tiers never amplify (amplifier == 1.0).
#   3. configure() applies — a configured model actually uses the new base in
#      on_mistake (a tier-6 model loses 12, not the historical 8).
#   4. Insane amplifier — while already insane, a mistake costs base * amp (the
#      spiral). No-op at amp 1.0.
#   5. min_stability — the model records the lowest stability it ever reached.
#   6. depth() / misread_probability() — continuous levers: depth rises as the
#      player falls; misread is 0 above the fraying band, ramps across it, flat
#      at the ceiling once fully insane.
#   7. Heat link + tilt — the loop's _tell_multiplier() is 1.0 while calm,
#      heat_link() while insane, TILT_TELL_MULTIPLIER while tilt-detected, and
#      the product when both.
#   8. Bet-sizing feeds composure — a mis-sized bet (non-cover) erodes, scaled
#      by severity; an optimal bet is composure-neutral; a declared cover bet
#      never erodes.
#   9. Count miss feeds composure — a big miscount erodes, a clean report steadies.
#  10. Ground recovery — the ACT_GROUND action tops up composure, breaks the
#      streak, and is budgeted per shoe (reset on a new shoe).
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260914

var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	print("mental_config_check: starting")
	_check_profiles()
	_check_monotonic_ladder()
	_check_configure_applies()
	_check_insane_amplifier()
	_check_min_stability()
	_check_depth_and_misread()
	_check_heat_link()
	_check_bet_feeds_composure()
	_check_count_miss_feeds_composure()
	_check_ground_recovery()
	_check_ground_band_signals()
	_check_auto_play_composure_neutral()
	_finish()


# --- 1. Per-tier profiles ---
func _check_profiles() -> void:
	# Teaching tiers keep the historical (tier-1) defaults.
	var t1: CHMentalConfig = CHMentalConfig.for_tier(1)
	_expect(t1.mistake_base == 8.0, "t1 mistake_base 8.0, got %s" % t1.mistake_base)
	_expect(t1.streak_escalation == 0.5, "t1 escalation 0.5, got %s" % t1.streak_escalation)
	_expect(t1.recovery_base == 6.0, "t1 recovery 6.0, got %s" % t1.recovery_base)
	_expect(t1.fraying_threshold == 50.0, "t1 fraying 50.0, got %s" % t1.fraying_threshold)
	_expect(t1.insane_threshold == 25.0, "t1 insane 25.0, got %s" % t1.insane_threshold)
	_expect(t1.insane_amplifier == 1.0, "t1 amplifier 1.0, got %s" % t1.insane_amplifier)
	_expect(t1.heat_link == 1.0, "t1 heat_link 1.0, got %s" % t1.heat_link)

	# Tier 4: the first tier with a real amplifier + heat link.
	var t4: CHMentalConfig = CHMentalConfig.for_tier(4)
	_expect(t4.mistake_base == 10.0, "t4 mistake_base 10.0, got %s" % t4.mistake_base)
	_expect(t4.streak_escalation == 0.6, "t4 escalation 0.6, got %s" % t4.streak_escalation)
	_expect(t4.recovery_base == 5.0, "t4 recovery 5.0, got %s" % t4.recovery_base)
	_expect(t4.fraying_threshold == 46.0, "t4 fraying 46.0, got %s" % t4.fraying_threshold)
	_expect(t4.insane_threshold == 22.0, "t4 insane 22.0, got %s" % t4.insane_threshold)
	_expect(t4.insane_amplifier == 1.3, "t4 amplifier 1.3, got %s" % t4.insane_amplifier)
	_expect(t4.heat_link == 1.1, "t4 heat_link 1.1, got %s" % t4.heat_link)

	# Tier 6: max severity.
	var t6: CHMentalConfig = CHMentalConfig.for_tier(6)
	_expect(t6.mistake_base == 12.0, "t6 mistake_base 12.0, got %s" % t6.mistake_base)
	_expect(t6.streak_escalation == 0.7, "t6 escalation 0.7, got %s" % t6.streak_escalation)
	_expect(t6.recovery_base == 4.0, "t6 recovery 4.0, got %s" % t6.recovery_base)
	_expect(t6.fraying_threshold == 42.0, "t6 fraying 42.0, got %s" % t6.fraying_threshold)
	_expect(t6.insane_threshold == 18.0, "t6 insane 18.0, got %s" % t6.insane_threshold)
	_expect(t6.insane_amplifier == 1.75, "t6 amplifier 1.75, got %s" % t6.insane_amplifier)
	_expect(t6.heat_link == 1.25, "t6 heat_link 1.25, got %s" % t6.heat_link)

	# Tier 7 (CSS contrast): a hard table that still recovers.
	var t7: CHMentalConfig = CHMentalConfig.for_tier(7)
	_expect(t7.mistake_base == 11.0, "t7 mistake_base 11.0, got %s" % t7.mistake_base)
	_expect(t7.insane_amplifier == 1.5, "t7 amplifier 1.5, got %s" % t7.insane_amplifier)
	_expect(t7.heat_link == 1.2, "t7 heat_link 1.2, got %s" % t7.heat_link)
	_expect(t7.recovery_base > 0.0, "t7 still recovers (recovery > 0), got %s" % t7.recovery_base)


# --- 2. Monotonic ladder ---
func _check_monotonic_ladder() -> void:
	var prev: CHMentalConfig = null
	for t in [1, 2, 3, 4, 5, 6]:
		var c: CHMentalConfig = CHMentalConfig.for_tier(t)
		if prev != null:
			_expect(c.mistake_base >= prev.mistake_base,
				"ladder: t%d mistake_base (%s) >= t%d (%s)" % [
					t, c.mistake_base, t - 1, prev.mistake_base])
			_expect(c.recovery_base <= prev.recovery_base,
				"ladder: t%d recovery (%s) <= t%d (%s)" % [
					t, c.recovery_base, t - 1, prev.recovery_base])
			_expect(c.insane_threshold <= prev.insane_threshold,
				"ladder: t%d insane threshold (%s) <= t%d (%s)" % [
					t, c.insane_threshold, t - 1, prev.insane_threshold])
		prev = c
	# Teaching tiers never amplify.
	_expect(CHMentalConfig.for_tier(1).insane_amplifier == 1.0, "t1 no amplification")
	_expect(CHMentalConfig.for_tier(2).insane_amplifier == 1.0, "t2 no amplification")


# --- 3. configure() applies ---
func _check_configure_applies() -> void:
	var m := CHMentalStateSystem.new()
	m.configure(CHMentalConfig.for_tier(6))
	var lost: float = m.on_mistake()  # streak 0 -> base * (1 + 0) * 1.0 = 12
	_expect(absf(lost - 12.0) < 0.001, "configured t6 model loses base 12.0, got %s" % lost)
	# Contrast: an unconfigured (tier-1) model loses 8.
	var m2 := CHMentalStateSystem.new()
	_expect(absf(m2.on_mistake() - 8.0) < 0.001, "unconfigured model loses historical 8.0")


# --- 4. Insane amplifier ---
func _check_insane_amplifier() -> void:
	var m := CHMentalStateSystem.new()
	m.configure(CHMentalConfig.for_tier(4))  # base 10, esc 0.6, amp 1.3, insane < 22
	m.stability = m._insane_threshold - 1.0   # 21.0 -> is_insane() true
	_expect(m.is_insane(), "model is insane just below the threshold")
	var lost: float = m.on_mistake()  # 10 * (1 + 0.6*0) * 1.3 = 13.0
	_expect(absf(lost - 13.0) < 0.001, "insane amplifier: mistake costs base*amp = 13.0, got %s" % lost)
	# No-op amplifier on a teaching tier.
	var t1 := CHMentalStateSystem.new()
	t1.stability = t1._insane_threshold - 1.0
	_expect(absf(t1.on_mistake() - 8.0) < 0.001, "t1 amplifier is a no-op (costs base 8.0)")


# --- 5. min_stability ---
func _check_min_stability() -> void:
	var m := CHMentalStateSystem.new()
	m.on_mistake()  # 100 -> 92
	m.on_mistake()  # 92 -> ~80.4
	m.on_success()  # recovers a little
	_expect(m.min_stability <= m.stability, "min_stability <= current stability")
	_expect(m.min_stability < CHMentalStateSystem.MAX_MENTAL, "min_stability recorded a drop, got %s" % m.min_stability)
	var lowest: float = m.stability
	for i in 6:
		m.on_mistake()
	_expect(absf(m.min_stability - lowest) < 1e-6 or m.min_stability <= lowest,
		"min_stability tracks the lowest value reached, got min %s last %s" % [m.min_stability, lowest])


# --- 6. depth() / misread_probability() ---
func _check_depth_and_misread() -> void:
	var m := CHMentalStateSystem.new()
	var d_calm: float = m.depth()  # stability 100
	m.stability = 30.0
	var d_fraying: float = m.depth()
	m.stability = 5.0
	var d_insane: float = m.depth()
	_expect(d_insane > d_fraying, "depth: deeper is larger (%s > %s)" % [d_insane, d_fraying])
	_expect(d_fraying > d_calm, "depth: fraying > calm (%s > %s)" % [d_fraying, d_calm])
	_expect(m.misread_probability() > 0.0, "deep insane: misread probability > 0, got %s" % m.misread_probability())
	# Above the fraying band there is no misread.
	m.stability = 100.0
	_expect(m.misread_probability() == 0.0, "calm: misread probability 0, got %s" % m.misread_probability())


# --- 7. Heat link (loop wiring) ---
func _check_heat_link() -> void:
	var loop := _make_loop(4)
	# Calm: the multiplier is 1.0 regardless of the profile.
	loop.get_mental_system().stability = 100.0
	_expect(absf(loop._tell_multiplier() - 1.0) < 0.001, "calm: tell multiplier 1.0, got %s" % loop._tell_multiplier())
	# Insane: the multiplier is the tier-4 heat link (1.1).
	loop.get_mental_system().stability = loop.get_mental_system()._insane_threshold - 1.0
	_expect(loop.is_mental_insane(), "loop is insane")
	var want: float = loop.get_mental_system().heat_link()
	_expect(absf(loop._tell_multiplier() - want) < 0.001,
		"insane: tell multiplier == heat_link (%s), got %s" % [want, loop._tell_multiplier()])
	_expect(want > 1.0, "t4 heat_link > 1.0 (link is on), got %s" % want)
	# Tilt: loss-chasing multiplies tells regardless of composure.
	loop.get_mental_system().stability = 100.0
	var d: CHDisciplineSystem = loop.discipline
	d.bet_history.clear()
	d.bet_history.append({"bet_units": 2, "after_loss": true})
	d.bet_history.append({"bet_units": 3, "after_loss": true})
	d.bet_history.append({"bet_units": 4, "after_loss": false})
	_expect(d.check_tilt(), "tilt pattern detected")
	_expect(absf(loop._tell_multiplier() - CHGameLoop.TILT_TELL_MULTIPLIER) < 0.001,
		"tilt: tell multiplier == TILT_TELL_MULTIPLIER, got %s" % loop._tell_multiplier())
	# Stacked: insane + tilt multiplies both terms.
	loop.get_mental_system().stability = loop.get_mental_system()._insane_threshold - 1.0
	_expect(absf(loop._tell_multiplier() - want * CHGameLoop.TILT_TELL_MULTIPLIER) < 0.001,
		"stacked: tell multiplier == heat_link * tilt, got %s" % loop._tell_multiplier())


# --- 8. Bet-sizing feeds composure ---
func _check_bet_feeds_composure() -> void:
	var loop := _make_loop(1)
	_expect(loop.begin_hand(), "bet feed: begin_hand returned true")
	var optimal: int = loop.optimal_bet_units()  # fresh shoe, TC 0 -> 2
	_expect(optimal >= 1, "bet feed: optimal bet is sane, got %d" % optimal)
	var m: CHMentalStateSystem = loop.get_mental_system()
	var before: float = m.stability
	# Overbet (non-cover): a composure lapse, streak increments.
	loop.place_bet(optimal + 3)
	_expect(m.mistake_streak == 1, "overbet: mistake streak is 1, got %d" % m.mistake_streak)
	_expect(m.stability < before, "overbet: stability dropped (%s < %s)" % [m.stability, before])

	var loop2 := _make_loop(1)
	loop2.begin_hand()
	var m2: CHMentalStateSystem = loop2.get_mental_system()
	# Optimal bet: composure-neutral, streak stays 0.
	loop2.place_bet(loop2.optimal_bet_units())
	_expect(m2.mistake_streak == 0, "optimal bet: streak stays 0, got %d" % m2.mistake_streak)
	_expect(m2.mental_state() == CHMentalStateSystem.STATE_CALM, "optimal bet: stays calm, got %s" % m2.mental_state())

	# A declared cover play that is suboptimal never erodes (intentional lay-low).
	var loop3 := _make_loop(1)
	loop3.begin_hand()
	var m3: CHMentalStateSystem = loop3.get_mental_system()
	var opt3: int = loop3.optimal_bet_units()
	loop3.place_bet(opt3 + 2, true)  # overbet but declared cover
	_expect(m3.mistake_streak == 0, "cover bet: no composure erosion, streak 0, got %d" % m3.mistake_streak)


# --- 9. Count miss feeds composure ---
func _check_count_miss_feeds_composure() -> void:
	var loop := _make_loop(1)
	var m: CHMentalStateSystem = loop.get_mental_system()
	# A clean report steadies (abs_error 0 -> success).
	loop._count_check_due = true
	loop._last_shoe_rc = 5
	var r: Dictionary = loop.report_count(5)
	_expect(int(r.abs_error) == 0, "count feed: clean report abs_error 0, got %s" % r.abs_error)
	_expect(m.mistake_streak == 0, "count feed: clean report keeps streak 0")

	var loop2 := _make_loop(1)
	var m2: CHMentalStateSystem = loop2.get_mental_system()
	var before2: float = m2.stability
	# A big miscount (abs_error 6) erodes composure.
	loop2._count_check_due = true
	loop2._last_shoe_rc = 5
	var r2: Dictionary = loop2.report_count(11)
	_expect(int(r2.abs_error) == 6, "count feed: miscount abs_error 6, got %s" % r2.abs_error)
	_expect(m2.mistake_streak == 1, "count feed: miscount increments streak, got %d" % m2.mistake_streak)
	_expect(m2.stability < before2, "count feed: miscount dropped stability (%s < %s)" % [m2.stability, before2])


# --- 10. Ground recovery (ACT_GROUND) ---
func _check_ground_recovery() -> void:
	var loop := _make_loop(1)
	# Fresh loop is IDLE with the full per-shoe ground budget.
	_expect(loop.is_idle(), "ground: fresh loop is idle")
	_expect(loop.ground_uses_left() == CHGameLoop.GROUND_USES_PER_SHOE,
		"ground: fresh budget == %d, got %d" % [CHGameLoop.GROUND_USES_PER_SHOE, loop.ground_uses_left()])
	var m: CHMentalStateSystem = loop.get_mental_system()
	m.stability = 60.0
	m.mistake_streak = 2
	var uses_before: int = loop.ground_uses_left()
	loop.apply_action(CHGameLoop.ACT_GROUND)
	_expect(m.stability > 60.0, "ground: stability recovered (%s > 60)" % m.stability)
	_expect(m.mistake_streak == 0, "ground: streak reset, got %d" % m.mistake_streak)
	_expect(loop.ground_uses_left() == uses_before - 1, "ground: budget decremented")
	# Exhaust the budget; further grounds are no-ops.
	var guard: int = 0
	while loop.ground_uses_left() > 0 and guard < 10:
		m.stability = 50.0
		loop.apply_action(CHGameLoop.ACT_GROUND)
		guard += 1
	_expect(loop.ground_uses_left() == 0, "ground: budget exhausted")
	m.stability = 50.0
	var frozen: float = m.stability
	loop.apply_action(CHGameLoop.ACT_GROUND)
	_expect(absf(m.stability - frozen) < 0.001, "ground: no-op when budget exhausted, stability unchanged")


# --- 11. Ground band-crossing signals ---
func _check_ground_band_signals() -> void:
	var loop := _make_loop(1)
	var m: CHMentalStateSystem = loop.get_mental_system()
	# Insane (t1: <25). Ground (+15) -> 12+15=27 -> fraying. Crosses insane -> fraying.
	m.stability = 12.0
	m.mistake_streak = 1
	var sigs := {"recovered": 0, "band": 0, "changed": 0}
	loop.mental_recovered.connect(func(): sigs["recovered"] += 1)
	loop.mental_band_changed.connect(func(_o, _n): sigs["band"] += 1)
	loop.mental_changed.connect(func(_s): sigs["changed"] += 1)
	_expect(loop.is_mental_insane(), "ground-band: loop is insane before")
	loop.apply_action(CHGameLoop.ACT_GROUND)
	_expect(m.mental_state() == CHMentalStateSystem.STATE_FRAYING,
		"ground-band: banded out to fraying, got %s" % m.mental_state())
	_expect(sigs["recovered"] == 1, "ground-band: mental_recovered fired, got %d" % sigs["recovered"])
	_expect(sigs["band"] == 1, "ground-band: mental_band_changed fired, got %d" % sigs["band"])
	_expect(sigs["changed"] == 1, "ground-band: mental_changed fired, got %d" % sigs["changed"])


# --- 12. Auto-play (engine) does not feed composure ---
# On the count-only teaching table the engine plays every hand (the player's only
# agency is the count report). Engine "correct" plays must not call on_success():
# if they did, they would constantly recover composure and reset the mistake
# streak, structurally neutralizing the count-miss spiral that report_count() is
# meant to drive. _engine_play (set by auto_play_round) gates the composure feeds.
func _check_auto_play_composure_neutral() -> void:
	var c := CHTableConfig.for_tier(1)
	c.count_only = true
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_PRACTICE)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var m: CHMentalStateSystem = loop.get_mental_system()
	# The teaching table auto-plays the hand; the player's only input is the count.
	loop.begin_hand()
	loop.auto_play_round()
	# A miscount erodes composure + sets the streak (player agency via report_count).
	loop._count_check_due = true
	loop._last_shoe_rc = 0
	var before: float = m.stability
	var r: Dictionary = loop.report_count(5)
	_expect(int(r.abs_error) == 5, "auto-play-neutral: miscount abs_error 5, got %s" % r.abs_error)
	_expect(m.mistake_streak == 1, "auto-play-neutral: miscount set streak 1, got %d" % m.mistake_streak)
	_expect(m.stability < before, "auto-play-neutral: miscount dropped stability")
	# Auto-play the next hand: engine "correct" plays must NOT reset the streak or
	# recover stability. Before the _engine_play gate, on_success() ran per optimal
	# play and reset the streak to 0 here.
	loop.begin_hand()
	var before_play: float = m.stability
	loop.auto_play_round()
	_expect(m.mistake_streak == 1, "auto-play-neutral: streak NOT reset by engine play, got %d" % m.mistake_streak)
	_expect(absf(m.stability - before_play) < 1e-6,
		"auto-play-neutral: stability NOT recovered by engine play, got %s vs %s" % [m.stability, before_play])


# A fresh practice-session loop at the given tier (insurance off so the opening
# hand goes straight to play; non-count-only so the player places bets manually).
func _make_loop(tier: int) -> CHGameLoop:
	var c := CHTableConfig.for_tier(tier)
	c.allows_insurance = false
	c.count_only = false
	var state := CHGameState.new()
	state.start_session(tier, CHGameState.MODE_PRACTICE)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(c, state, disc, SEED)


func _finish() -> void:
	if _failures.is_empty():
		print("mental_config_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("mental_config_check: %d failure(s)" % _failures.size())
		quit(1)
