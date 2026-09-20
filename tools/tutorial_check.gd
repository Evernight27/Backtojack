extends SceneTree
# M116 — tutorial (staged on-ramp) verification.
#
#   1. CHGameLoop.tutorial_stage() is 0 outside a tutorial session.
#   2. Stage progression: 1 -> 2 -> 3 across the three shoes; the session ends
#      with reason "tutorial_complete" after the third.
#   3. No stakes: a catastrophic loss cannot end a tutorial session (the
#      bankroll is decorative, like practice mode).
#
#   The scene-level UI wiring (button visibility, auto-bet / auto-play, and the
#   Space-key gate) is covered by scene_smoke_check's Main.tscn load; this tool
#   exercises the loop / state logic that the UI drives.
#
#   Every session here ends by calling CHGameLoop's internal end_session
#   (persist=true), so the save path is redirected to a throwaway file to keep
#   the real user save untouched.

const SEED := 20260916
const TEST_SAVE := "user://tutorial_check_test_save.json"

var _failures: Array[String] = []


func _init() -> void:
	print("tutorial_check: starting")
	_check_stage_zero_outside_tutorial()
	_check_stage_progression_and_end()
	_check_no_stakes()
	_finish()


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)
		print("  FAIL  " + msg)


# Fresh tutorial loop with the tutorial table config (mirrors Main.gd's
# overrides: heat off, count display off) and a throwaway save path.
func _make_loop(mode: String, tier: int = 1, shoes: int = 3) -> CHGameLoop:
	var c := CHTableConfig.for_tier(tier)
	c.heat_active = false
	c.show_count_display = false
	var state := CHGameState.new()
	state.save_path = TEST_SAVE
	state.start_session(tier, mode, 0, shoes)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(c, state, disc, SEED)


# Advances the loop by one "press": resolves any pending count check (reporting
# the true count) and then takes the next step. From idle it begins a hand and,
# in the bet phase, places the optimal bet; in any decision phase it applies the
# optimal action. Mirrors the scene's auto-play path.
func _advance_one_step(loop: CHGameLoop) -> void:
	if loop.is_count_check_due():
		loop.report_count(loop.last_shoe_rc())
	var phase: String = loop.phase()
	if phase == CHGameLoop.PHASE_IDLE or phase == CHGameLoop.PHASE_SETTLED:
		if not loop.begin_hand():
			return
		if loop.phase() == CHGameLoop.PHASE_BET:
			loop.place_bet(loop.optimal_bet_units())
	elif phase == CHGameLoop.PHASE_BET:
		loop.place_bet(loop.optimal_bet_units())
	else:
		var a: String = loop.optimal_action()
		if a != "":
			loop.apply_action(a)


# Plays hands until the loop's internal shoe counter advances past `target`, or
# the session ends. Bounded so a logic bug cannot loop forever.
func _play_until_shoe(loop: CHGameLoop, target: int) -> void:
	var guard := 0
	while loop.state.shoes_this_session < target and guard < 500:
		guard += 1
		if not loop.state.is_session_active():
			return
		_advance_one_step(loop)


func _check_stage_zero_outside_tutorial() -> void:
	var c := CHTableConfig.for_tier(1)
	var state := CHGameState.new()
	state.save_path = TEST_SAVE
	state.start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	_expect(loop.tutorial_stage() == 0, "tutorial_stage() is 0 in practice mode, got %d" % loop.tutorial_stage())


func _check_stage_progression_and_end() -> void:
	var loop := _make_loop(CHGameState.MODE_TUTORIAL, 1, 3)
	var s: CHGameState = loop.state
	_expect(loop.tutorial_stage() == 1, "stage 1 at start, got %d" % loop.tutorial_stage())

	# Shoe 1 -> shoe 2 boundary.
	_play_until_shoe(loop, 1)
	_expect(s.shoes_this_session == 1, "shoe 1 advanced, got %d" % s.shoes_this_session)
	_expect(loop.tutorial_stage() == 2, "stage 2 after shoe 1, got %d" % loop.tutorial_stage())

	# Shoe 2 -> shoe 3 boundary.
	_play_until_shoe(loop, 2)
	_expect(loop.tutorial_stage() == 3, "stage 3 after shoe 2, got %d" % loop.tutorial_stage())

	# Shoe 3 completes -> session ends as a tutorial, stage resets to 0.
	_expect(s.is_session_active(), "session active during shoe 3")
	_play_until_shoe(loop, 3)
	_expect(s.shoes_this_session == 3, "shoe 3 advanced, got %d" % s.shoes_this_session)
	_expect(not s.is_session_active(), "session ended after shoe 3")
	_expect(s.last_end_reason == "tutorial_complete", "end reason tutorial_complete, got '%s'" % s.last_end_reason)
	_expect(loop.tutorial_stage() == 0, "stage 0 after session end, got %d" % loop.tutorial_stage())


func _check_no_stakes() -> void:
	var loop := _make_loop(CHGameState.MODE_TUTORIAL, 1, 3)
	var s: CHGameState = loop.state
	var bank: int = s.current_bankroll
	# A catastrophic loss must not move the bankroll or end the session.
	s.apply_hand_result(-500, 0.0)
	_expect(s.current_bankroll == bank, "bankroll pinned at %d after -500 loss, got %d" % [bank, s.current_bankroll])
	_expect(s.is_session_active(), "session still active after a huge loss")


func _finish() -> void:
	_cleanup()
	if _failures.is_empty():
		print("tutorial_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("tutorial_check: %d failure(s)" % _failures.size())
		quit(1)


func _cleanup() -> void:
	if FileAccess.file_exists(TEST_SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
