extends SceneTree
# Headless validation for the mental-stability layer (M103).
#
# CHMentalStateSystem models the player's composure: a run of non-optimal plays
# erodes stability (with escalating penalty), and a correct play steadies it back
# out (recovery floored so a player at 0 can always climb). This tool pins both
# the unit math and the CHGameLoop wiring (a wrong play erodes + increments the
# mistake streak; a correct play resets it and recovers).
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906

var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	print("mental_check: starting")
	_check_fresh()
	_check_mistake_escalation()
	_check_success_recovery()
	_check_recovery_direction()
	_check_floored_recovery()
	_check_state_bands()
	_check_insane_boundary()
	_check_loop_max_streak()
	_check_max_streak()
	_check_reset()
	_check_loop_wiring_mistake()
	_check_loop_wiring_correct()
	_check_loop_live_streak()
	_check_mental_signal_edges()
	_check_band_changed_signal()
	_finish()


# 1. A fresh system is fully composed: max stability, calm, no mistake run.
func _check_fresh() -> void:
	var m := CHMentalStateSystem.new()
	_expect(m.stability == CHMentalStateSystem.MAX_MENTAL, "fresh stability is max, got %s" % m.stability)
	_expect(m.mistake_streak == 0, "fresh streak is 0, got %d" % m.mistake_streak)
	_expect(m.mental_state() == CHMentalStateSystem.STATE_CALM, "fresh state is calm, got %s" % m.mental_state())
	_expect(not m.is_insane(), "fresh is not insane")


# 2. Consecutive mistakes escalate: the 2nd costs more than the 1st.
func _check_mistake_escalation() -> void:
	var m := CHMentalStateSystem.new()
	var first: float = m.on_mistake()  # streak 0 -> BASE_MISTAKE
	var second: float = m.on_mistake()  # streak 1 -> BASE_MISTAKE * 1.5
	_expect(m.mistake_streak == 2, "streak is 2 after two mistakes, got %d" % m.mistake_streak)
	_expect(first == CHMentalStateSystem.BASE_MISTAKE, "1st mistake costs the base amount, got %s" % first)
	_expect(second > first, "escalation: 2nd mistake (%s) costs more than 1st (%s)" % [second, first])
	_expect(m.stability < CHMentalStateSystem.MAX_MENTAL, "stability dropped after mistakes, got %s" % m.stability)


# 3. A correct play recovers stability and resets the mistake run.
func _check_success_recovery() -> void:
	var m := CHMentalStateSystem.new()
	m.on_mistake()
	m.on_mistake()
	var before: float = m.stability
	var gained: float = m.on_success()
	_expect(m.mistake_streak == 0, "streak resets to 0 on a correct play, got %d" % m.mistake_streak)
	_expect(gained > 0.0, "a correct play recovers stability, got %s" % gained)
	_expect(m.stability > before, "stability rises after a correct play, got %s" % m.stability)


# 3b. Recovery direction (M108): a correct play steadies LESS when the player is
#     deep in the hole and MORE when already composed (rate scales with current
#     stability, matching Discipline). Pins the M108 flip so a re-inversion is
#     caught.
func _check_recovery_direction() -> void:
	var shaken := CHMentalStateSystem.new()
	shaken.stability = 30.0
	var composed := CHMentalStateSystem.new()
	composed.stability = 70.0
	var shaken_gain: float = shaken.on_success()
	var composed_gain: float = composed.on_success()
	_expect(composed_gain > shaken_gain, "recovery scales with stability: composed (%s) gains more than shaken (%s)" % [composed_gain, shaken_gain])
	# on_success returns stability - before (add-then-subtract), so it is not
	# bit-identical to BASE_RECOVERY * rate; compare within a tiny epsilon.
	_expect(absf(shaken_gain - CHMentalStateSystem.BASE_RECOVERY * (30.0 / CHMentalStateSystem.MAX_MENTAL)) < 0.001, "shaken recovery equals the scaled rate, got %s" % shaken_gain)


# 4. Recovery is floored: even at 0 stability a correct play still steadies a
#    little (the player can always climb back out — never stuck at the floor).
func _check_floored_recovery() -> void:
	var m := CHMentalStateSystem.new()
	m.stability = CHMentalStateSystem.MIN_MENTAL
	var gained: float = m.on_success()
	_expect(gained > 0.0, "floored recovery still positive at 0, got %s" % gained)
	_expect(m.stability > CHMentalStateSystem.MIN_MENTAL, "climbed off the floor, got %s" % m.stability)


# 5. The coarse state bands map stability to the four named states.
func _check_state_bands() -> void:
	var m := CHMentalStateSystem.new()
	m.stability = 80.0
	_expect(m.mental_state() == CHMentalStateSystem.STATE_CALM, "80 -> calm, got %s" % m.mental_state())
	m.stability = 60.0
	_expect(m.mental_state() == CHMentalStateSystem.STATE_STRAINED, "60 -> strained, got %s" % m.mental_state())
	m.stability = 40.0
	_expect(m.mental_state() == CHMentalStateSystem.STATE_FRAYING, "40 -> fraying, got %s" % m.mental_state())
	m.stability = 10.0
	_expect(m.mental_state() == CHMentalStateSystem.STATE_INSANE, "10 -> insane, got %s" % m.mental_state())


# 6. The insanity boundary: exactly at the threshold the player is NOT insane;
#    just below it they are (stability < threshold).
func _check_insane_boundary() -> void:
	var m := CHMentalStateSystem.new()
	m.stability = CHMentalStateSystem.INSANE_THRESHOLD
	_expect(not m.is_insane(), "at the threshold exactly the player is not insane")
	m.stability = CHMentalStateSystem.INSANE_THRESHOLD - 0.1
	_expect(m.is_insane(), "just below the threshold the player is insane")


# 6b. Loop accessor: max_mental_mistake_streak() reflects the system's record.
func _check_loop_max_streak() -> void:
	var loop := _make_loop()
	_expect(loop.max_mental_mistake_streak() == 0, "fresh loop max streak is 0")
	_rig_hand(loop, 5, 2, 9, 7)
	loop.apply_action(CHGameLoop.ACT_HIT)
	_expect(loop.max_mental_mistake_streak() == 1, "loop max streak is 1 after one miss, got %d" % loop.max_mental_mistake_streak())


# 6c. Loop accessor: mental_mistake_streak() reflects the LIVE run — 0 when fresh,
#     increments on a wrong play, and resets to 0 on a correct play. This is the
#     value the HUD shows as the "×N run" tag (M112).
func _check_loop_live_streak() -> void:
	var loop := _make_loop()
	_expect(loop.mental_mistake_streak() == 0, "fresh loop live streak is 0, got %d" % loop.mental_mistake_streak())
	_rig_hand(loop, 5, 2, 9, 7)  # 16 hard vs 5 -> optimal is stand
	loop.apply_action(CHGameLoop.ACT_HIT)  # wrong
	_expect(loop.mental_mistake_streak() == 1, "live streak is 1 after a wrong play, got %d" % loop.mental_mistake_streak())
	# The accessor must mirror the model's live run exactly (the reset-on-correct
	# behaviour is pinned at the model level in check 3; the accessor just reads it).
	var m: CHMentalStateSystem = loop.get_mental_system()
	_expect(loop.mental_mistake_streak() == m.mistake_streak, "accessor mirrors the model's live streak")


# 7. max_mistake_streak tracks the longest consecutive-miss run, persists across
#    an intervening correct play, and survives on_success (it is the session
#    record, not the live run).
func _check_max_streak() -> void:
	var m := CHMentalStateSystem.new()
	m.on_mistake()
	m.on_mistake()
	_expect(m.max_mistake_streak == 2, "max streak is 2 after a 2-run, got %d" % m.max_mistake_streak)
	m.on_success()  # breaks the run; max must NOT drop back to 0
	_expect(m.max_mistake_streak == 2, "max streak persists after a correct play, got %d" % m.max_mistake_streak)
	m.on_mistake()
	m.on_mistake()
	m.on_mistake()
	_expect(m.max_mistake_streak == 3, "max streak extends to 3 on a longer run, got %d" % m.max_mistake_streak)


# 8. reset() restores composure and clears both the live run and the record.
func _check_reset() -> void:
	var m := CHMentalStateSystem.new()
	m.on_mistake()
	m.on_mistake()
	m.reset()
	_expect(m.stability == CHMentalStateSystem.MAX_MENTAL, "reset restores max stability, got %s" % m.stability)
	_expect(m.mistake_streak == 0, "reset clears the streak, got %d" % m.mistake_streak)
	_expect(m.max_mistake_streak == 0, "reset clears the max-streak record, got %d" % m.max_mistake_streak)


# 8. Loop wiring: a non-optimal play erodes stability and increments the streak.
func _check_loop_wiring_mistake() -> void:
	var loop := _make_loop()
	_rig_hand(loop, 5, 2, 9, 7)  # upcard 5, hole 2, player 9+7 = 16 hard
	_expect(loop.phase() == CHGameLoop.PHASE_HAND, "in PHASE_HAND, got %s" % loop.phase())
	var opt: String = loop.optimal_action()
	_expect(opt == CHGameLoop.ACT_STAND, "16 vs 5 optimal is stand, got %s" % opt)
	var before: float = loop.mental_stability()
	loop.apply_action(CHGameLoop.ACT_HIT)  # wrong — optimal is stand
	var m: CHMentalStateSystem = loop.get_mental_system()
	_expect(m.mistake_streak == 1, "loop wiring: streak is 1 after a wrong play, got %d" % m.mistake_streak)
	_expect(loop.mental_stability() < before, "loop wiring: stability dropped after a wrong play, got %s" % loop.mental_stability())


# 9. Loop wiring: a correct play keeps the streak at 0 and stays calm.
func _check_loop_wiring_correct() -> void:
	var loop := _make_loop()
	_rig_hand(loop, 5, 2, 9, 7)
	_expect(loop.phase() == CHGameLoop.PHASE_HAND, "in PHASE_HAND, got %s" % loop.phase())
	loop.apply_action(CHGameLoop.ACT_STAND)  # correct — optimal is stand
	var m: CHMentalStateSystem = loop.get_mental_system()
	_expect(m.mistake_streak == 0, "loop wiring: streak stays 0 after a correct play, got %d" % m.mistake_streak)
	_expect(loop.mental_state() == CHMentalStateSystem.STATE_CALM, "loop wiring: calm after a correct play, got %s" % loop.mental_state())


# 10. Signal edges: mental_insane fires on the not-insane -> insane crossing, and
# mental_recovered fires on the insane -> not-insane crossing (the inverse). Each
# crossing fires exactly one of the two, never both. (Counters are Dictionaries
# so the lambdas mutate the shared object, not a by-value capture.)
func _check_mental_signal_edges() -> void:
	# Crossing IN: set stability just above the threshold, then force one wrong
	# play so on_mistake() drops it below the threshold in a single feed.
	var in_signals := {"insane": 0, "recovered": 0}
	var in_loop := _make_loop()
	in_loop.mental_insane.connect(func(): in_signals["insane"] += 1)
	in_loop.mental_recovered.connect(func(): in_signals["recovered"] += 1)
	in_loop.get_mental_system().stability = CHMentalStateSystem.INSANE_THRESHOLD + 1.0
	_rig_hand(in_loop, 5, 2, 9, 7)  # 16 hard vs 5 -> optimal is stand
	in_loop.apply_action(CHGameLoop.ACT_HIT)  # wrong -> on_mistake: 26 -> 18
	_expect(in_signals["insane"] == 1, "mental_insane fires exactly once on crossing in, got %d" % in_signals["insane"])
	_expect(in_signals["recovered"] == 0, "mental_recovered must NOT fire on crossing in, got %d" % in_signals["recovered"])
	_expect(in_loop.is_mental_insane(), "loop is insane after crossing in")

	# Crossing OUT: set stability just below the threshold (insane), then force
	# one correct play so on_success() lifts it above the threshold in one feed.
	var out_signals := {"insane": 0, "recovered": 0}
	var out_loop := _make_loop()
	out_loop.mental_insane.connect(func(): out_signals["insane"] += 1)
	out_loop.mental_recovered.connect(func(): out_signals["recovered"] += 1)
	out_loop.get_mental_system().stability = CHMentalStateSystem.INSANE_THRESHOLD - 0.5
	_rig_hand(out_loop, 5, 2, 9, 7)  # 16 hard vs 5 -> optimal is stand
	out_loop.apply_action(CHGameLoop.ACT_STAND)  # correct -> on_success: 24.5 -> ~25.97
	_expect(out_signals["recovered"] == 1, "mental_recovered fires exactly once on crossing out, got %d" % out_signals["recovered"])
	_expect(out_signals["insane"] == 0, "mental_insane must NOT fire on crossing out, got %d" % out_signals["insane"])
	_expect(not out_loop.is_mental_insane(), "loop is recovered after crossing out")


# 11. Band-change signal: mental_band_changed fires on every transition between
#     the four bands, carrying the old and new band strings.
func _check_band_changed_signal() -> void:
	var captured := {"count": 0, "old": "", "new": ""}
	var loop := _make_loop()
	loop.mental_band_changed.connect(func(o: String, n: String):
		captured["count"] += 1
		captured["old"] = o
		captured["new"] = n)
	# Start at 100 (calm), force enough mistakes to cross into strained, then
	# fraying, then insane — three band crossings expected.
	loop.get_mental_system().stability = 100.0
	# 1st wrong play: 100 -> 92 (still calm, no crossing)
	_rig_hand(loop, 5, 2, 9, 7)
	loop.apply_action(CHGameLoop.ACT_HIT)  # wrong: 100 -> 92
	_expect(captured["count"] == 0, "no band change at 92 (still calm), got count %d" % captured["count"])
	# 2nd wrong play: 92 -> 80 (still calm, no crossing)
	_rig_hand(loop, 5, 2, 9, 7)
	loop.apply_action(CHGameLoop.ACT_HIT)  # wrong: 92 -> 80
	_expect(captured["count"] == 0, "no band change at 80 (still calm), got count %d" % captured["count"])
	# 3rd wrong play: 80 -> 64 (crosses into strained at 75)
	_rig_hand(loop, 5, 2, 9, 7)
	loop.apply_action(CHGameLoop.ACT_HIT)  # wrong: 80 -> 64
	_expect(captured["count"] == 1, "band changed once (calm->strained), got count %d" % captured["count"])
	_expect(captured["old"] == CHMentalStateSystem.STATE_CALM, "old band is calm, got %s" % captured["old"])
	_expect(captured["new"] == CHMentalStateSystem.STATE_STRAINED, "new band is strained, got %s" % captured["new"])


# A single-spot T1 loop, insurance off so the rigged hand goes straight to play.
func _make_loop() -> CHGameLoop:
	var c := CHTableConfig.for_tier(1)
	c.allows_insurance = false
	c.opponent = null  # isolate composure mechanics from the social opponent
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_PRACTICE)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(c, state, disc, SEED)


# Rigs the opening four cards (upcard, hole, player p1, p2) and deals the hand
# so the loop is sitting in PHASE_HAND on a deterministic two-card hand.
func _rig_hand(loop: CHGameLoop, up: int, hole: int, p1: int, p2: int) -> void:
	var shoe := loop.get_shoe()
	shoe.deck[0] = CHCard.new("S", up)
	shoe.deck[1] = CHCard.new("S", hole)
	shoe.deck[2] = CHCard.new("S", p1)
	shoe.deck[3] = CHCard.new("S", p2)
	shoe.deal_index = 0
	_expect(loop.begin_hand(), "rig: begin_hand returned true")
	loop.place_bet(loop.optimal_bet_units())


func _finish() -> void:
	if _failures.is_empty():
		print("mental_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("mental_check: %d failure(s)" % _failures.size())
		quit(1)
