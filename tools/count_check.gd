extends SceneTree
# Headless validation for M16 (counting-accuracy check):
#
#   1. Grading curve — a reported RC is scored by |error| (off-by-N costs
#      N * PENALTY_PER_ERROR, clamped to [0,100]).
#   2. Running mean — accuracy is the exact mean of per-check scores.
#   3. No-check neutrality — with zero checks, the process score is neutral 100
#      so a session with no count checks does not dilute the skill rating.
#   4. Blend pulls the skill rating down — a real loop that records a bad count
#      ends with a LOWER skill rating than an identical control loop (optimal
#      play, same seed) that has no count check.
#   5. Cut signal + report idempotency — the count_check_due signal fires on a
#      shoe cut with the true RC, report_count() grades it exactly once, and a
#      second report is a no-op.
#   6. Skip — skip_count_check() declines the prompt: clears the due flag and
#      records no check, so a declining player is not penalized.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906
const MAX_HANDS: int = 60

var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	_check_grading_curve()
	_check_running_mean()
	_check_no_check_neutral()
	_check_blend_pulls_rating_down()
	_check_cut_signal_and_idempotency()
	_check_skip_clears_check()
	_check_rejects_implausible_report()
	_finish()


# --- 1. Grading curve ---
func _check_grading_curve() -> void:
	var sys := CHCountAccuracySystem.new()
	sys.reset_for_new_session()
	# Perfect.
	var a: Dictionary = sys.record(5, 5)
	_expect(int(a.error) == 0 and absf(float(a.score) - 100.0) < 0.001, "off-by-0 -> 100, got %s" % a.score)
	# Off by 1.
	var b: Dictionary = sys.record(6, 5)
	_expect(int(b.abs_error) == 1 and absf(float(b.score) - 95.0) < 0.001, "off-by-1 -> 95, got %s" % b.score)
	# Off by 5.
	var c: Dictionary = sys.record(5, 10)
	_expect(int(c.abs_error) == 5 and absf(float(c.score) - 75.0) < 0.001, "off-by-5 -> 75, got %s" % c.score)
	# Off by 20 floors to 0 (clamped).
	var d: Dictionary = sys.record(0, 20)
	_expect(int(d.abs_error) == 20 and absf(float(d.score) - 0.0) < 0.001, "off-by-20 -> 0 (clamped), got %s" % d.score)
	# Negative error (reported below actual) is symmetric.
	var e: Dictionary = sys.record(-3, 0)
	_expect(int(e.error) == -3 and int(e.abs_error) == 3 and absf(float(e.score) - 85.0) < 0.001, "negative error symmetric, got err=%s score=%s" % [e.error, e.score])


# --- 2. Running mean ---
func _check_running_mean() -> void:
	var sys := CHCountAccuracySystem.new()
	sys.reset_for_new_session()
	sys.record(0, 0)   # 100
	sys.record(0, 10)  # 50
	_expect(int(sys.checks) == 2, "two checks recorded, got %d" % sys.checks)
	_expect(absf(sys.accuracy - 75.0) < 0.001, "mean(100,50)=75, got %.1f" % sys.accuracy)
	# Third check off-by-8 -> 60; mean(100,50,60)=70.
	sys.record(0, 8)   # 60
	_expect(int(sys.checks) == 3 and absf(sys.accuracy - 70.0) < 0.001, "mean(100,50,60)=70, got %.1f" % sys.accuracy)


# --- 3. No-check neutrality ---
func _check_no_check_neutral() -> void:
	var sys := CHCountAccuracySystem.new()
	sys.reset_for_new_session()
	_expect(int(sys.checks) == 0, "fresh system has 0 checks")
	_expect(absf(sys.accuracy - 100.0) < 0.001, "accuracy neutral (100) with no checks, got %s" % sys.accuracy)


# --- 4. Blend pulls the skill rating down ---
func _check_blend_pulls_rating_down() -> void:
	# Control: optimal play, count checks OFF. Its process score is discipline
	# alone (near 100).
	var control := _make_loop(false)
	var control_state: CHGameState = control.state
	_drive_hands(control, 0)  # bad_offset 0 unused (no checks fire)
	_expect(not control_state.is_session_active(), "control session ended")
	var control_rating: float = control_state.get_skill_rating()

	# Test: identical optimal play, count checks ON, but the player reports the
	# running count off by 8 at the cut (score 60). Its process score is
	# lerpf(discipline, 60, 0.5) < discipline, so its skill rating must be lower.
	var test := _make_loop(true)
	var test_state: CHGameState = test.state
	_drive_hands(test, -8)
	_expect(not test_state.is_session_active(), "test session ended")
	var test_rating: float = test_state.get_skill_rating()
	var test_checks: int = test.get_count_accuracy().checks

	_expect(test_checks >= 1, "test loop recorded a count check, got %d" % test_checks)
	_expect(test_rating > 0.0, "test rating advanced, got %.2f" % test_rating)
	_expect(control_rating > 0.0, "control rating advanced, got %.2f" % control_rating)
	_expect(test_rating < control_rating, "bad counting lowers skill rating: test=%.2f < control=%.2f" % [test_rating, control_rating])


# Drives a practice-mode loop (needs 2 shoes) to completion, reporting the
# running count `bad_offset` off from the true value at each shoe cut.
func _drive_hands(loop: CHGameLoop, bad_offset: int) -> void:
	var hands := 0
	while loop.state.is_session_active() and hands < MAX_HANDS:
		if not loop.begin_hand():
			break
		hands += 1
		if loop.phase() == CHGameLoop.PHASE_BET:
			# Answer any pending count check before betting (the scene gates the
			# bet buttons on this; the loop does not, so we do it explicitly).
			if loop.is_count_check_due():
				loop.report_count(loop.last_shoe_rc() + bad_offset)
			loop.place_bet(loop.optimal_bet_units())
		var guard := 0
		while not loop.is_idle() and guard < 96:
			loop.apply_action(loop.optimal_action())
			guard += 1


# A deterministic 1-deck practice loop (2 shoes). count_check_active toggles
# the M16 feature.
func _make_loop(count_check: bool) -> CHGameLoop:
	var c := CHTableConfig.for_tier(1)
	c.count_check_active = count_check
	var state := CHGameState.new()
	# 2 shoes: the session survives the first cut (so the check can be reported)
	# and ends at the second.
	state.start_session(1, CHGameState.MODE_PRACTICE, 0, 2)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(c, state, disc, SEED)


# --- 5. Cut signal + report idempotency ---
func _check_cut_signal_and_idempotency() -> void:
	var loop := _make_loop(true)
	# _make_loop uses 2 shoes, so the first cut does not complete the session;
	# we stop at the first cut to probe the pending check.
	var cap := {"fired": false, "rc": 0}
	loop.count_check_due.connect(func(rc: int):
		cap.fired = true
		cap.rc = rc
	)

	var hands := 0
	var reached_cut := false
	while loop.state.is_session_active() and hands < MAX_HANDS:
		if not loop.begin_hand():
			break
		hands += 1
		if loop.is_count_check_due():
			reached_cut = true
			break
		if loop.phase() == CHGameLoop.PHASE_BET:
			loop.place_bet(loop.optimal_bet_units())
		var guard := 0
		while not loop.is_idle() and guard < 96:
			loop.apply_action(loop.optimal_action())
			guard += 1

	_expect(reached_cut, "a shoe cut occurred within %d hands" % MAX_HANDS)
	_expect(cap.fired, "count_check_due signal fired on the cut")
	_expect(int(cap.rc) == loop.last_shoe_rc(), "signal RC matches last_shoe_rc(), got sig=%d last=%d" % [cap.rc, loop.last_shoe_rc()])
	_expect(loop.is_count_check_due(), "check is due after the cut")

	# Report the exact captured RC -> perfect score, check cleared.
	var r: Dictionary = loop.report_count(loop.last_shoe_rc())
	_expect(not r.is_empty(), "report_count returned a result")
	_expect(int(r.get("abs_error", -1)) == 0 and absf(float(r.get("score", 0.0)) - 100.0) < 0.001, "exact RC -> score 100, got %s" % r.get("score"))
	_expect(not loop.is_count_check_due(), "check cleared after reporting")

	# A second report with no pending check is a no-op.
	var r2: Dictionary = loop.report_count(loop.last_shoe_rc())
	_expect(r2.is_empty(), "second report is a no-op (returns empty), got %s" % str(r2))
	_expect(int(loop.get_count_accuracy().checks) == 1, "only one check recorded, got %d" % loop.get_count_accuracy().checks)


# --- 6. skip_count_check() clears the pending check without recording a score ---
# The player can decline the count prompt instead of answering. The only branch
# nobody else drives: it must clear the due flag and NOT add a check (so the
# declining player is not penalized in the accuracy mean).
func _check_skip_clears_check() -> void:
	var loop := _make_loop(true)
	var hands := 0
	var reached_cut := false
	while loop.state.is_session_active() and hands < MAX_HANDS:
		if not loop.begin_hand():
			break
		hands += 1
		if loop.is_count_check_due():
			reached_cut = true
			break
		if loop.phase() == CHGameLoop.PHASE_BET:
			loop.place_bet(loop.optimal_bet_units())
		var guard := 0
		while not loop.is_idle() and guard < 96:
			loop.apply_action(loop.optimal_action())
			guard += 1

	_expect(reached_cut, "skip: a shoe cut occurred within %d hands" % MAX_HANDS)
	if not reached_cut:
		return
	_expect(loop.is_count_check_due(), "skip: check is due after the cut")
	# Decline the prompt.
	loop.skip_count_check()
	_expect(not loop.is_count_check_due(), "skip: check cleared after skip_count_check()")
	_expect(int(loop.get_count_accuracy().checks) == 0,
		"skip: declining records no check, got %d" % loop.get_count_accuracy().checks)


# --- 7. An implausible reported magnitude is rejected (check stays due) ---
# A running count can never exceed the shoe's card count (deck_count * 52). A
# mistyped value beyond that must be rejected: report_count returns empty AND
# leaves the check pending so the player can retry or skip, instead of recording
# a 0-score that drags the accuracy mean.
func _check_rejects_implausible_report() -> void:
	var loop := _make_loop(true)  # Tier 1: 1 deck -> magnitude bound 52
	var hands := 0
	var reached_cut := false
	while loop.state.is_session_active() and hands < MAX_HANDS:
		if not loop.begin_hand():
			break
		hands += 1
		if loop.is_count_check_due():
			reached_cut = true
			break
		if loop.phase() == CHGameLoop.PHASE_BET:
			loop.place_bet(loop.optimal_bet_units())
		var guard := 0
		while not loop.is_idle() and guard < 96:
			loop.apply_action(loop.optimal_action())
			guard += 1
	_expect(reached_cut, "implausible: a shoe cut occurred within %d hands" % MAX_HANDS)
	if not reached_cut:
		return
	var checks_before: int = int(loop.get_count_accuracy().checks)
	# 99999 is far beyond the 52-card single-deck bound -> rejected.
	var r: Dictionary = loop.report_count(99999)
	_expect(r.is_empty(), "implausible: oversized report rejected (empty result)")
	_expect(loop.is_count_check_due(), "implausible: check still pending after rejection")
	_expect(int(loop.get_count_accuracy().checks) == checks_before,
		"implausible: rejection records no check, got %d" % loop.get_count_accuracy().checks)
	# A plausible value still reports and clears.
	var ok: Dictionary = loop.report_count(loop.last_shoe_rc())
	_expect(not ok.is_empty(), "implausible: a valid report still succeeds")
	_expect(not loop.is_count_check_due(), "implausible: check cleared after valid report")


func _finish() -> void:
	# Remove any save artifact from the session-ending loops.
	var p := ProjectSettings.globalize_path("user://counting_house_save.json")
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

	if _failures.is_empty():
		print("count_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("count_check: %d failure(s)" % _failures.size())
		quit(1)
