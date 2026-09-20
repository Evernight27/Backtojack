extends SceneTree
# Headless validation for M13-lifecycle: the loop now drives the session
# lifecycle end-to-end, which it previously did not.
#
#   1. Practice mode completes: after `practice_shoes_required` shoes the loop
#      ends the session (reason "practice_complete") and begin_hand() stops
#      returning true. (on_shoe_finished is now wired into _on_new_shoe.)
#   2. Survival mode completes: same on_shoe_finished path, different reason
#      ("survival_complete"); with the 100-unit start stake a 2-shoe run cannot
#      bust.
#   3. Heat floor write-back: when a session ends, its ending heat is persisted
#      as the tier's reputation floor, so the next session starts from residual
#      suspicion.
#   4. Cash out: the player voluntarily ends the session (reason "cash_out");
#      a second cash_out is a no-op and does not re-emit session_ended.
#   5. Discipline feeds the skill rating: on a tier where decision grading is
#      on, a loop that inverts every hit/stand decision ends with a LOWER skill
#      rating than an identical optimal-play control (count checks off, so the
#      process score is pure discipline).
#   6. Save-failure surfacing: when the session-end save cannot be written the
#      loop emits save_failed (and the session still ends normally); a healthy
#      save does not emit it.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906

var _failures: Array[String] = []


func _init() -> void:
	_check_practice_completion()
	_check_survival_completion()
	_check_heat_floor_writeback()
	_check_cash_out()
	_check_discipline_lowering_rating()
	_check_save_failed_signal()
	_cleanup_save()

	if _failures.is_empty():
		print("lifecycle_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("lifecycle_check: %d failure(s)" % _failures.size())
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


# --- 1. Practice mode completes after N shoes ---
func _check_practice_completion() -> void:
	var c := CHTableConfig.for_tier(1)
	var state := CHGameState.new()
	# Only 2 shoes required so the test is fast.
	state.start_session(1, CHGameState.MODE_PRACTICE, 0, 2)
	var disc := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(c, state, disc, SEED)
	# Capture the session_ended signal (the scene drives its session-end UI off
	# this). Lambdas capture by value, so use a Dictionary for a ref flag.
	var fires := {"count": 0, "active_after": false}
	loop.session_ended.connect(func():
		fires.count += 1
		fires.active_after = state.is_session_active())

	_expect(state.is_session_active(), "session active at start")
	var hands := 0
	while state.is_session_active() and hands < 400:
		if not loop.begin_hand():
			break
		hands += 1
		if loop.phase() == CHGameLoop.PHASE_BET:
			loop.place_bet(loop.optimal_bet_units())
		var guard := 0
		while not loop.is_idle() and guard < 96:
			loop.apply_action(loop.optimal_action())
			guard += 1

	# The session ends inside begin_hand() on the shoe boundary that consumes the
	# required shoe, so read the counter AFTER the loop, not per-iteration.
	_expect(not state.is_session_active(), "practice session ends after %d shoes" % 2)
	_expect(state.last_end_reason == "practice_complete", "reason == practice_complete, got '%s'" % state.last_end_reason)
	_expect(state.shoes_this_session >= 2, "shoe counter advanced to >= 2, got %d" % state.shoes_this_session)
	# After the session ends, begin_hand must refuse.
	_expect(not loop.begin_hand(), "begin_hand refuses in an inactive session")
	# Skill rating advanced from the process score (discipline as EMA input).
	_expect(state.get_skill_rating() > 0.0, "skill rating advanced (process score fed), got %.2f" % state.get_skill_rating())
	# The session_ended signal must fire exactly once, and only after the session
	# is already inactive. The scene drives its debrief + New Session button off
	# this signal, so getting the count wrong breaks the UI.
	_expect(fires.count == 1, "session_ended fired exactly once, got %d" % fires.count)
	_expect(not fires.active_after, "session_ended fired after session was inactive")


# --- 2. Survival mode completes after N shoes ---
# Structural twin of the practice check: same on_shoe_finished path, different
# reason. Survival differs from practice only in that it has economy stakes
# (bankroll can move); with the 100-unit start stake a 2-shoe run cannot bust,
# so the only terminal reason is survival_complete.
func _check_survival_completion() -> void:
	var c := CHTableConfig.for_tier(1)
	var state := CHGameState.new()
	# Only 2 shoes required so the test is fast.
	state.start_session(1, CHGameState.MODE_SURVIVAL, 0, 2)
	var disc := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(c, state, disc, SEED)
	var fires := {"count": 0, "active_after": false}
	loop.session_ended.connect(func():
		fires.count += 1
		fires.active_after = state.is_session_active())

	_expect(state.is_session_active(), "survival session active at start")
	var hands := 0
	while state.is_session_active() and hands < 400:
		if not loop.begin_hand():
			break
		hands += 1
		if loop.phase() == CHGameLoop.PHASE_BET:
			loop.place_bet(loop.optimal_bet_units())
		var guard := 0
		while not loop.is_idle() and guard < 96:
			loop.apply_action(loop.optimal_action())
			guard += 1

	_expect(not state.is_session_active(), "survival session ends after %d shoes" % 2)
	_expect(state.last_end_reason == "survival_complete", "reason == survival_complete, got '%s'" % state.last_end_reason)
	_expect(state.shoes_this_session >= 2, "survival shoe counter advanced to >= 2, got %d" % state.shoes_this_session)
	# After the session ends, begin_hand must refuse.
	_expect(not loop.begin_hand(), "begin_hand refuses in an inactive survival session")
	# The session_ended signal must fire exactly once, and only after the session
	# is already inactive (the scene drives its debrief off this signal).
	_expect(fires.count == 1, "survival session_ended fired exactly once, got %d" % fires.count)
	_expect(not fires.active_after, "survival session_ended fired after session was inactive")
	if not state.is_session_active() and state.last_end_reason == "survival_complete" and fires.count == 1:
		print("PASS  survival mode completes after %d shoes (reason survival_complete, single session_ended)" % 2)


# --- 3. Heat floor written back on session end ---
func _check_heat_floor_writeback() -> void:
	var c := CHTableConfig.for_tier(1)
	c.heat_active = true
	c.heat_sensitivity_multiplier = 1.0
	var state := CHGameState.new()
	# Target 1 unit above the 100 starting stake: the session ends within a few
	# hands (first net-positive P&L), well before the seeded heat decays to zero.
	state.start_session(1, CHGameState.MODE_TARGET, 101)
	var disc := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(c, state, disc, SEED)

	# begin_hand() initializes the heat system (reset to the tier floor, which
	# is 0 here). Seed the heat AFTER that init so the value actually survives
	# into play; 90 is below the 100 backoff threshold so no latch interferes.
	if not loop.begin_hand():
		_failures.append("first hand did not start")
		return
	var h: CHHeatSystem = loop.get_heat_system()
	h.on_tell(90.0)  # heat = 90
	_expect(absf(h.heat - 90.0) < 0.001, "seeded heat = 90, got %s" % h.heat)

	# Play the seeded hand, then drive subsequent hands until the session ends.
	# Heat decays 3/hand, so it stays > 0 for ~30 hands — far longer than a
	# target-101 session needs.
	var hands := 1
	while state.is_session_active() and hands < 400:
		if loop.phase() == CHGameLoop.PHASE_BET:
			# A small flat bet: below the big-bet tell, so heat only decays.
			loop.place_bet(1)
		var guard := 0
		while not loop.is_idle() and guard < 96:
			loop.apply_action(loop.optimal_action())
			guard += 1
		if state.is_session_active():
			if not loop.begin_hand():
				break
			hands += 1

	_expect(not state.is_session_active(), "target session ended")
	# The loop's final heat must have been persisted as this tier's floor.
	var ending_heat: float = loop.heat()
	var floor: float = state.get_heat_floor(1)
	_expect(absf(ending_heat - floor) < 0.001, "heat floor written back: floor=%.2f heat=%.2f" % [floor, ending_heat])
	# floor > 0 proves the write-back actually moved the floor from its initial
	# 0.0 (not a trivial no-op), i.e. the session ended while heat was still up.
	_expect(floor > 0.0, "ending heat non-zero (write-back is real), got %.2f" % floor)
	# And a fresh state that loads the save starts at that floor (residual
	# suspicion) rather than 0.
	var reloaded := CHGameState.new()
	var reloaded_ok: bool = reloaded.deserialize(state.serialize())
	_expect(reloaded_ok, "save/load round-trip deserialized")
	_expect(absf(reloaded.get_heat_floor(1) - floor) < 0.001, "floor survives a save/load round-trip, got %.2f" % reloaded.get_heat_floor(1))


# --- 3. Cash out: player voluntarily ends the session ---
func _check_cash_out() -> void:
	var c := CHTableConfig.for_tier(1)
	var state := CHGameState.new()
	# Target mode with an unreachable goal so the session only ends via cash_out.
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var disc := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(c, state, disc, SEED)
	var fires := {"count": 0, "active_after": true}
	loop.session_ended.connect(func():
		fires.count += 1
		fires.active_after = state.is_session_active())

	_expect(state.is_session_active(), "session active before cash out")
	# Start a hand so the loop is mid-session when the player cashes out.
	_expect(loop.begin_hand(), "begin_hand before cash out")
	if loop.phase() == CHGameLoop.PHASE_BET:
		loop.place_bet(loop.optimal_bet_units())
	var before_rating: float = state.get_skill_rating()
	var ended: bool = loop.cash_out()
	_expect(ended, "cash_out returned true for an active session")
	_expect(not state.is_session_active(), "session inactive after cash out")
	_expect(state.last_end_reason == "cash_out", "reason == cash_out, got '%s'" % state.last_end_reason)
	_expect(fires.count == 1, "session_ended fired exactly once on cash out, got %d" % fires.count)
	_expect(not fires.active_after, "session_ended fired after session was inactive")
	_expect(not loop.begin_hand(), "begin_hand refuses after cash out")
	# A second cash_out is a no-op and must not re-emit session_ended.
	_expect(not loop.cash_out(), "second cash_out is a no-op on an inactive session")
	_expect(fires.count == 1, "second cash_out did not re-emit session_ended, got %d" % fires.count)
	# Skill rating still advances from the process score (not decreased by ending).
	_expect(state.get_skill_rating() >= before_rating, "skill rating not decreased by cash out (%.2f vs %.2f)" % [state.get_skill_rating(), before_rating])
	if fires.count == 1 and state.last_end_reason == "cash_out":
		print("PASS  cash_out: voluntary end, single session_ended, begin_hand refuses")


# --- 6. A session-end save that cannot be written must surface, not vanish ---
# end_session is the only moment progression persists; a failed write there would
# otherwise silently lose the skill rating / tier unlocks / heat floor. The loop
# must emit save_failed exactly once, while the session still ends normally.
# Uses state.save_path (added for this) pointed at a nonexistent directory so
# save() fails deterministically without touching the real user save.
func _check_save_failed_signal() -> void:
	var c := CHTableConfig.for_tier(1)
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)  # unreachable -> cash_out ends it
	var disc := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(c, state, disc, SEED)
	var fired := {"count": 0}
	loop.save_failed.connect(func():
		fired.count += 1)
	# Point the session-end save at a directory that does not exist -> save() fails.
	state.save_path = "user://no_such_dir_for_save_failed_check/x.json"
	var ended: bool = loop.cash_out()
	_expect(ended, "save-failed: cash_out still ends the session when the save fails")
	_expect(not state.is_session_active(), "save-failed: session inactive after cash out")
	_expect(state.last_save_ok == false, "save-failed: last_save_ok is false after a failed write")
	_expect(fired.count == 1, "save-failed: save_failed emitted exactly once, got %d" % fired.count)
	# Control: a healthy save must NOT emit save_failed.
	var c2 := CHTableConfig.for_tier(1)
	var state2 := CHGameState.new()
	state2.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop2 := CHGameLoop.new(c2, state2, CHDisciplineSystem.new(), SEED)
	var fired2 := {"count": 0}
	loop2.save_failed.connect(func():
		fired2.count += 1)
	state2.save_path = "user://counting_house_check_save.json"
	_expect(loop2.cash_out(), "save-failed control: cash_out ends the session")
	_expect(state2.last_save_ok, "save-failed control: last_save_ok true on a healthy write")
	_expect(fired2.count == 0, "save-failed control: no signal on a healthy save, got %d" % fired2.count)
	# Remove the control's save so the tool leaves no residue.
	var cp := ProjectSettings.globalize_path("user://counting_house_check_save.json")
	if FileAccess.file_exists(cp):
		DirAccess.remove_absolute(cp)


# --- 5. Discipline (decision quality) lowers the skill rating end-to-end ---
# count_check._check_blend_pulls_rating_down isolates the COUNT-ACCURACY half of
# the process score (both loops play optimally; only the reported RC differs).
# This isolates the DECISION half: on a tier where grade_decisions is on, a
# player who makes suboptimal hand decisions ends with a LOWER skill rating than
# an identical control that plays optimally. count_check_active is off so the
# process score is pure discipline (GameLoop._session_process_score returns
# discipline.discipline when no count checks were recorded).
func _check_discipline_lowering_rating() -> void:
	var control_rating: float = _run_rating_session(true)
	var test_rating: float = _run_rating_session(false)
	_expect(control_rating > 0.0, "control rating advanced, got %.2f" % control_rating)
	_expect(test_rating > 0.0, "test rating advanced, got %.2f" % test_rating)
	_expect(
		test_rating < control_rating,
		"suboptimal decisions lower skill rating: test=%.2f < control=%.2f" % [test_rating, control_rating]
	)


# Drives a T2 session (grade_decisions on, count checks off) for `hands_count`
# hands then cashes out. If `play_optimal` is false, each hand decision is the
# opposite of the engine's optimal (hit<->stand) when that opposite is a legal
# action, guaranteeing a graded suboptimal decision per hand. Bets stay optimal
# in both arms so only hand-decision quality differs. Returns the end-session
# skill rating (a single EMA update from the 0.0 default, so rating == alpha *
# process_score == 0.2 * discipline).
func _run_rating_session(play_optimal: bool, hands_count: int = 20) -> float:
	var c := CHTableConfig.for_tier(2)
	c.count_check_active = false  # process score = pure discipline
	var state := CHGameState.new()
	state.start_session(2, CHGameState.MODE_TARGET, 999999)  # unreachable -> only cash_out ends it
	var disc := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(c, state, disc, SEED)
	var hands := 0
	while hands < hands_count:
		if not loop.begin_hand():
			break
		hands += 1
		if loop.phase() == CHGameLoop.PHASE_BET:
			loop.place_bet(loop.optimal_bet_units())
		var guard := 0
		while not loop.is_idle() and guard < 96:
			var act: String = loop.optimal_action()
			if not play_optimal:
				var bad: String = "stand" if act == "hit" else "hit"
				if bad in loop.available_actions():
					act = bad
			loop.apply_action(act)
			guard += 1
	# Guard: neither arm should have ended early (bust/target), so the rating
	# reflects a controlled cash_out rather than a terminal hand.
	_expect(state.is_session_active(), "rating session still active at cash-out (no early end)")
	var ended: bool = loop.cash_out()
	_expect(ended, "cash_out ended the rating session")
	_expect(state.last_end_reason == "cash_out", "rating session ended via cash_out, got '%s'" % state.last_end_reason)
	return state.get_skill_rating()


# The heat-floor write-back test ends a session (target/bust), which triggers
# end_session -> save(). Remove that artifact so the tool leaves no residue.
func _cleanup_save() -> void:
	var p := ProjectSettings.globalize_path("user://counting_house_save.json")
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	var cp := ProjectSettings.globalize_path("user://counting_house_check_save.json")
	if FileAccess.file_exists(cp):
		DirAccess.remove_absolute(cp)
	# M83: atomic saves write a sibling .tmp before renaming; remove any residue.
	if FileAccess.file_exists(p + ".tmp"):
		DirAccess.remove_absolute(p + ".tmp")
	if FileAccess.file_exists(cp + ".tmp"):
		DirAccess.remove_absolute(cp + ".tmp")
