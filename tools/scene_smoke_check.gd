extends SceneTree
# Headless smoke test: instantiate the playable scene, run its _ready() to build
# the UI + start a session, then drive a practice session to completion and
# verify the debrief + New Session button appear (the bug M15 fixes).
#
# _ready() is invoked manually (not via the scene tree) so the test does not
# depend on headless frame timing; it only builds local UI and starts a session.

var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	print("scene_smoke_check: starting")
	var scene := load("res://scenes/Main.tscn")
	_expect(scene != null, "Main.tscn loaded")
	if scene == null:
		_finish()
		return
	var main: Control = scene.instantiate()
	# Build the UI and start the default (target) session manually.
	main._ready()

	# _ready ran _build_ui + _start_session(1, target, 150, 3).
	_expect(main._loop != null, "loop created on ready")
	_expect(main._mode_selector != null, "mode selector exists")
	_expect(main._shoes_spin != null, "shoes spinbox exists")

	# M78: keyboard shortcuts are discoverable via button labels.
	_expect(main._action_buttons[CHGameLoop.ACT_HIT].text == "Hit (H)", "hit button shows key hint")
	_expect(main._action_buttons[CHGameLoop.ACT_INS_TAKE].text == "Take Insurance (T)", "insurance button shows key hint")
	_expect(main._deal_button.text == "Deal Next Hand (Space)", "deal button shows key hint")
	_expect(main._cover_toggle.text == "Cover (C)", "cover toggle shows key hint")

	# M19: count-check feedback must surface in the always-visible status label
	# (the prompt panel hides on answer, so the score can't live only inside it).
	_check_count_check_feedback(main)
	_check_count_check_stale_reset(main)
	_check_count_check_empty_submit(main)

	# M64: mode-selector restarts must not leak a bankroll goal into survival /
	# practice (a stale target_bankroll would end a survival session early as
	# "target_reached"), and the tier selector must actually reseat at the
	# chosen tier's table.
	_check_mode_switching(main)
	_check_tier_switching(main)

	# M65: UI rendering contracts that had no pin — the insurance prompt shows
	# only the insurance buttons, the tilt indicator renders when loss-chasing,
	# and the heat label surfaces the "BACKED OFF" state.
	_check_insurance_prompt_rendering(main)
	_check_insurance_shows_player_hand(main)
	_check_tilt_indicator_rendering(main)
	_check_heat_backoff_rendering(main)
	_check_heat_lay_low_rendering(main)
	_check_mistake_run_rendering(main)
	_check_debrief_full_line_rendering(main)
	_check_skill_label(main)
	_check_presplit_multi_spot_rendering(main)
	_check_help_panel(main)
	_check_count_check_keyboard_gate(main)
	_check_pnl_rounding(main)
	_check_card_back(main)
	_check_bet_feedback_text(main)
	_check_action_feedback_text(main)
	_check_active_hand_index(main)
	_check_hand_total_label(main)
	_check_heat_color(main)
	_check_stats_panel(main)
	_check_tutorial_mode(main)
	_check_count_only_teaching_table(main)
	_check_t1_teaching_hud_clean(main)
	_check_npc_player_rows(main)
	_check_venue_banner(main)
	_check_opponent_row(main)
	_check_t1_no_opponent(main)
	_check_dealer_drawn_cards_rendered(main)

	# Switch to a 1-shoe practice session and drive it to completion. T1 is the
	# count-only teaching table, but this drive exercises the *normal* bet/play +
	# Decisions debrief path, so run it with count_only disabled.
	main._start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	main._loop.config.count_only = false
	_expect(main._state.session_mode == CHGameState.MODE_PRACTICE, "mode is practice")
	_expect(main._shoes_spin.visible, "shoe count visible in practice mode")

	var hands := 0
	var guard_total := 0
	while main._state.is_session_active() and hands < 500 and guard_total < 4000:
		if not main._loop.begin_hand():
			break
		hands += 1
		if main._loop.phase() == CHGameLoop.PHASE_BET:
			main._loop.place_bet(main._loop.optimal_bet_units())
		var guard := 0
		while not main._loop.is_idle() and guard < 60:
			main._loop.apply_action(main._loop.optimal_action())
			guard += 1
			guard_total += 1

	_expect(not main._state.is_session_active(), "practice session completed")
	_expect(main._state.last_end_reason == "practice_complete", "reason practice_complete, got '%s'" % main._state.last_end_reason)

	# The M15 fix: session-end UI must have been driven by the session_ended
	# signal (not hand_settled), so the debrief + New Session button appear even
	# though the terminating event was a shoe cut, not a hand settlement.
	_expect(main._debrief_panel.visible, "debrief panel visible after practice completion")
	_expect(main._new_session_button.visible, "New Session button visible after practice completion")
	_expect(main._status_label.text.begins_with("Session ended"), "status shows session end, got '%s'" % main._status_label.text)

	# M29: the debrief surfaces the session decision record even though the T1
	# teaching table has decision grading off (recording is independent).
	var debrief_text := ""
	for l in main._debrief_lines:
		debrief_text += l.text + "\n"
	_expect(debrief_text.contains("Decisions:"), "debrief shows decision record, got: " + debrief_text)

	# M78: a practice-mode debrief must not claim a bankroll figure (practice has
	# no economy stakes; the bankroll never moved), so the P&L line reads
	# "practice — no stakes" rather than "(bankroll N)".
	_expect(debrief_text.contains("practice — no stakes"),
		"practice debrief P&L shows 'no stakes', got: " + debrief_text)
	_expect(not debrief_text.contains("(bankroll"),
		"practice debrief must not show a bankroll figure, got: " + debrief_text)

	# M86: the debrief surfaces the persistent career counters (otherwise tracked
	# in lifetime_stats but never shown) and the line must match the state.
	var ch: int = int(main._state.lifetime_stats.get("hands_played", 0))
	var cs: int = int(main._state.lifetime_stats.get("sessions_played", 0))
	var expected_career := "Career:  %d hand%s over %d session%s" % [
		ch, "" if ch == 1 else "s", cs, "" if cs == 1 else "s"]
	_expect(debrief_text.contains(expected_career),
		"debrief career line matches lifetime_stats, got: " + debrief_text)

	# M30: the live HUD decision-accuracy label reflects the same record, so the
	# teaching table (grading off) still sees how well it is playing in real time.
	_expect(main._discipline.session_decisions > 0, "decisions recorded during practice session, got %d" % main._discipline.session_decisions)
	_expect(main._discipline.session_optimal == main._discipline.session_decisions, "optimal play records all-optimal, got %d/%d" % [main._discipline.session_optimal, main._discipline.session_decisions])
	_expect(main._decision_acc_label.visible, "decision-accuracy label visible after decisions")
	_expect(main._decision_acc_label.text == "Decisions: %d/%d" % [main._discipline.session_optimal, main._discipline.session_decisions], "decision-accuracy label text, got '%s'" % main._decision_acc_label.text)

	# M22: the Cash Out button lets the player voluntarily end a running session.
	_check_cash_out_button(main)

	# M76: keyboard shortcuts drive the same paths as the buttons.
	_check_keyboard_shortcuts(main)

	# M76: an unreadable save is backed up and the player is warned.
	_check_save_loss_warning(main)

	_cleanup_save()
	_finish()


# M19: submitting/skipping a count check must surface the result in the always-
# visible status label (the prompt panel hides on answer, so the feedback can't
# live only inside the panel). Runs on the active default (target) session.
func _check_count_check_feedback(main: Control) -> void:
	# Submit path: report off-by-1 against a captured true count of 5.
	main._loop._count_check_due = true
	main._loop._last_shoe_rc = 5
	main._count_check_input.text = "4"
	main._on_count_check_submit()
	_expect(main._status_label.text.contains("actual was"), "count feedback in status on submit, got '%s'" % main._status_label.text)
	_expect(not main._count_check_panel.visible, "count-check panel hidden after submit")
	_expect(main._loop.is_count_check_due() == false, "count check cleared after submit")

	# Skip path: clearing the check + surfacing the skip notice.
	main._loop._count_check_due = true
	main._loop._last_shoe_rc = 3
	main._count_check_input.text = "9"
	main._on_count_check_skip()
	_expect(not main._count_check_panel.visible, "count-check panel hidden after skip")
	_expect(main._loop.is_count_check_due() == false, "count check cleared after skip")
	_expect(main._status_label.text == "Count check skipped.", "skip notice in status, got '%s'" % main._status_label.text)


# M19: a shoe-cut count-check prompt from a prior session must not leak into a
# restarted session (the panel is a scene-level node that outlives the loop).
func _check_count_check_stale_reset(main: Control) -> void:
	# Simulate a stale, visible prompt, then restart the session.
	main._count_check_panel.visible = true
	main._count_check_input.text = "42"
	main._start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	_expect(not main._count_check_panel.visible, "count-check panel hidden after session restart")
	_expect(main._count_check_input.text == "", "count-check input cleared after session restart")


# M79: submitting an empty count report must be ignored, not graded as zero
# (an accidental Enter/click on the Submit button would otherwise record a
# "0" against the player's count accuracy). Self-contained: it sets its own
# pending check on the current loop.
func _check_count_check_empty_submit(main: Control) -> void:
	main._loop._count_check_due = true
	main._loop._last_shoe_rc = 7
	main._count_check_panel.visible = true
	main._count_check_input.text = ""
	main._on_count_check_submit()
	_expect(main._loop.is_count_check_due(), "M79: check still pending after empty submit")
	_expect(main._count_check_panel.visible, "M79: panel stays visible after empty submit")
	_expect(main._status_label.text.contains("Enter a running count"),
		"M79: empty-submit hint shown, got '%s'" % main._status_label.text)
	# M82: non-integer input must also be rejected, not silently coerced by
	# to_int() ("abc" -> 0, "4.5" -> 4).
	main._loop._count_check_due = true
	main._loop._last_shoe_rc = 7
	main._count_check_panel.visible = true
	main._count_check_input.text = "abc"
	main._on_count_check_submit()
	_expect(main._loop.is_count_check_due(), "M82: check still pending after non-integer submit")
	_expect(main._status_label.text.contains("Enter a running count"),
		"M82: non-integer hint shown, got '%s'" % main._status_label.text)
	# A real report right after the rejected empty one must still work.
	main._count_check_input.text = "7"
	main._on_count_check_submit()
	_expect(not main._loop.is_count_check_due(), "M79: check cleared after a valid report")
	# A correct report (reported == actual) now confirms success rather than
	# reading as an error; only a nonzero abs_error shows the "off by N" form.
	_expect(main._status_label.text.contains("correct (you said 7)"),
		"M79: correct report surfaces 'correct' feedback, got '%s'" % main._status_label.text)


# M64: the mode selector restarts a session, but only target mode carries a
# bankroll goal. Before the fix, _on_mode_selected always passed START_TARGET,
# so switching to survival/practice leaked target_bankroll=150 — and
# apply_hand_result's `target_bankroll > 0` check (which runs in every mode but
# practice) would end a survival session early as "target_reached" instead of
# "survival_complete". Pin that survival/practice get target_bankroll 0 and
# target keeps its goal, plus the shoes spinbox shows/hides correctly.
func _check_mode_switching(main: Control) -> void:
	main._on_mode_selected(2)  # survival
	_expect(main._state.session_mode == CHGameState.MODE_SURVIVAL, "mode is survival, got '%s'" % main._state.session_mode)
	_expect(main._state.target_bankroll == 0, "survival has no bankroll goal, got %d" % main._state.target_bankroll)
	_expect(main._shoes_spin.visible, "shoe count visible in survival mode")

	main._on_mode_selected(1)  # practice
	_expect(main._state.session_mode == CHGameState.MODE_PRACTICE, "mode is practice, got '%s'" % main._state.session_mode)
	_expect(main._state.target_bankroll == 0, "practice has no bankroll goal, got %d" % main._state.target_bankroll)

	main._on_mode_selected(0)  # target
	_expect(main._state.session_mode == CHGameState.MODE_TARGET, "mode is target, got '%s'" % main._state.session_mode)
	_expect(main._state.target_bankroll == 150, "target keeps the bankroll goal (START_TARGET=150), got %d" % main._state.target_bankroll)
	_expect(not main._shoes_spin.visible, "shoe count hidden in target mode")


# M64: the tier ladder must actually reseat the player at the chosen tier's
# table (not just highlight it). Bump the skill rating so the full ladder is
# unlocked, repopulate, then reseat at tier 4 and confirm the loop was rebuilt
# on tier-4's real table config (4-deck, H17) rather than the stale tier-1
# table. Reseating is done via _start_session directly (the same call the
# selector makes) so the test doesn't fight load_game's save reload.
func _check_tier_switching(main: Control) -> void:
	main._state.lifetime_stats["skill_rating"] = 100.0
	main._populate_tier_selector()
	_expect(main._tier_selector.item_count == 7, "all 7 tiers listed when fully unlocked, got %d" % main._tier_selector.item_count)
	# The selector select() must not crash even if current_tier outruns the
	# (clamped) item count — exercise the clamp path.
	main._populate_tier_selector()
	_expect(true, "tier selector repopulated without an out-of-bounds select")
	# Reseat at tier 4: the loop must be rebuilt on tier-4's table config.
	main._start_session(4, CHGameState.MODE_TARGET, 150, 3)
	_expect(main._state.current_tier == 4, "reseat to tier 4, got %d" % main._state.current_tier)
	_expect(main._loop.config.deck_count == 4, "tier-4 table is 4-deck, got %d" % main._loop.config.deck_count)
	_expect(main._loop.config.dealer_hits_soft_17, "tier-4 table is H17 (dealer hits soft 17)")
	_expect(main._loop.config.max_split_hands >= 0, "tier-4 table config is a valid CHTableConfig")


# M65: when the loop is in the insurance phase, _refresh_actions must show ONLY
# the two insurance buttons and hide the hand / bet / deal controls. Driving the
# loop into PHASE_INSURANCE directly (the upcard would need to be an Ace) keeps
# this a pure rendering-contract test, matching how _count_check_due is faked
# above. Uses a T1 session because T1 is the tier where allows_insurance=true.
func _check_insurance_prompt_rendering(main: Control) -> void:
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	# T1 is now the count-only teaching table (bet/cover/play controls hidden).
	# This check is a pure insurance-prompt *rendering* contract, so test it with
	# the count-only mode off, the same way _phase is faked below.
	main._loop.config.count_only = false
	main._loop._phase = CHGameLoop.PHASE_INSURANCE
	main._refresh_actions()
	_expect(main._action_buttons[CHGameLoop.ACT_INS_TAKE].visible, "insurance-take button visible in insurance phase")
	_expect(main._action_buttons[CHGameLoop.ACT_INS_TAKE].disabled == false, "insurance-take button enabled")
	_expect(main._action_buttons[CHGameLoop.ACT_INS_DECLINE].visible, "insurance-decline button visible in insurance phase")
	_expect(not main._action_buttons[CHGameLoop.ACT_HIT].visible, "hit button hidden in insurance phase")
	_expect(not main._action_buttons[CHGameLoop.ACT_STAND].visible, "stand button hidden in insurance phase")
	_expect(not main._bet_buttons[1].visible, "bet-unit buttons hidden in insurance phase")
	_expect(not main._deal_button.visible, "deal button hidden in insurance phase")


# M93: the player's opening cards must be visible during the insurance prompt.
# _hands_to_render() used to return [] in PHASE_INSURANCE (terminal hands are
# only built after the insurance decision), so the player decided on insurance
# with no cards on the table. Rigs a deterministic shoe (up=A, hole=10,
# player 7+4) on the T1 tier (the one where allows_insurance=true), deals to
# the insurance phase, and asserts the opening hand is rendered.
func _check_insurance_shows_player_hand(main: Control) -> void:
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	var shoe: CHShoeManager = main._loop.get_shoe()
	var suits := ["S", "H", "D", "C"]
	var open_ranks := [14, 10, 7, 4]  # up=A, hole=10, player 7,4
	var deck: Array[CHCard] = []
	for i in range(open_ranks.size()):
		deck.append(CHCard.new(suits[i % 4], int(open_ranks[i])))
	for i in range(open_ranks.size(), shoe.total_cards()):
		deck.append(CHCard.new(suits[i % 4], 2))
	shoe.deck = deck
	shoe.deal_index = 0
	_expect(main._loop.begin_hand(), "ins-render: begin_hand")
	main._loop.place_bet(1)
	_expect(main._loop.phase() == CHGameLoop.PHASE_INSURANCE,
		"ins-render: in insurance phase after Ace upcard, got %s" % main._loop.phase())
	var rendered: Array[CHHand] = main._hands_to_render()
	_expect(rendered.size() == 1,
		"ins-render: player's opening hand renders, got %d" % rendered.size())
	if rendered.size() == 1:
		_expect(rendered[0].card_count() == 2,
			"ins-render: rendered hand has both opening cards")


# M65: the tilt indicator must render exactly when the discipline system has
# detected a loss-chasing pattern (3 rising bets, the last two after a loss).
func _check_tilt_indicator_rendering(main: Control) -> void:
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	var d: CHDisciplineSystem = main._discipline
	# No tilt: empty history.
	d.bet_history.clear()
	main._refresh_hud()
	_expect(not main._tilt_label.visible, "tilt label hidden with no history")
	# Chasing pattern: 2->3->4, the first two after a loss.
	d.bet_history.append({"bet_units": 2, "after_loss": true})
	d.bet_history.append({"bet_units": 3, "after_loss": true})
	d.bet_history.append({"bet_units": 4, "after_loss": false})
	main._refresh_hud()
	_expect(main._tilt_label.visible, "tilt label visible on loss-chasing pattern")
	_expect(main._tilt_label.text.contains("Tilt"), "tilt label text names tilt, got '%s'" % main._tilt_label.text)
	# Control: not chasing (the middle bet was not after a loss) -> no tilt.
	d.bet_history.clear()
	d.bet_history.append({"bet_units": 2, "after_loss": true})
	d.bet_history.append({"bet_units": 3, "after_loss": false})
	d.bet_history.append({"bet_units": 4, "after_loss": false})
	main._refresh_hud()
	_expect(not main._tilt_label.visible, "tilt label hidden when not loss-chasing")


# M65: when the heat system has latched a backoff, the HUD heat label must
# surface the "BACKED OFF" state. Latches the backoff directly on the loop's
# heat system and checks the rendering, independent of how the backoff was
# earned. Uses tier 2 (not the tier-1 counting drill) because the heat readout
# is hidden on the count-only teaching table, where heat can never build.
func _check_heat_backoff_rendering(main: Control) -> void:
	main._start_session(2, CHGameState.MODE_TARGET, 150, 3)
	var heat: CHHeatSystem = main._loop.get_heat_system()
	heat.reset(0.0)
	heat.pending_backoff = false
	main._refresh_hud()
	_expect(not main._heat_label.text.contains("BACKED OFF"), "heat label has no BACKED OFF when idle")
	heat.pending_backoff = true
	main._refresh_hud()
	_expect(main._heat_label.visible, "heat label visible while backoff latched")
	_expect(main._heat_label.text.contains("BACKED OFF"), "heat label surfaces BACKED OFF, got '%s'" % main._heat_label.text)


# M126: the lay-low hand itself (after begin_hand resolves the latch) must stay
# legible — the pending latch clears on reset, so only is_backoff_hand() tells us
# the current hand is the "lay low" one. Drives the internal flag directly, as
# the BACKED OFF check drives pending_backoff, and checks the HUD rendering.
# Tier 2 (not the tier-1 counting drill) because the heat readout is hidden on
# the count-only teaching table, where heat can never build.
func _check_heat_lay_low_rendering(main: Control) -> void:
	main._start_session(2, CHGameState.MODE_TARGET, 150, 3)
	var heat: CHHeatSystem = main._loop.get_heat_system()
	heat.reset(0.0)
	heat.pending_backoff = false
	main._loop._backoff_hand = true
	main._refresh_hud()
	_expect(main._heat_label.visible, "heat label visible on lay-low hand")
	_expect(main._heat_label.text.contains("LAY LOW"), "heat label surfaces LAY LOW, got '%s'" % main._heat_label.text)
	_expect(not main._heat_label.text.contains("BACKED OFF"),
		"lay-low hand is not labeled BACKED OFF, got '%s'" % main._heat_label.text)
	# When both the pending latch and the lay-low flag are set, BACKED OFF wins.
	main._loop._backoff_hand = false
	heat.pending_backoff = true
	main._refresh_hud()
	_expect(main._heat_label.text.contains("BACKED OFF"),
		"pending latch still surfaces BACKED OFF, got '%s'" % main._heat_label.text)


# M127: the live mistake-run tag must surface "Run: ×N" while a run is in
# progress and hide it once the run clears. The stability band is intentionally
# hidden (no meter); the run is the *early* play-quality cue that a composure
# spiral is building. Drives the streak directly, as the lay-low check drives
# _backoff_hand, and checks the HUD rendering contract.
func _check_mistake_run_rendering(main: Control) -> void:
	main._start_session(2, CHGameState.MODE_TARGET, 150, 3)
	var m: CHMentalStateSystem = main._loop.get_mental_system()
	m.mistake_streak = 0
	main._refresh_hud()
	_expect(not main._run_label.visible, "run tag hidden when no run is in progress")
	_expect(main._run_label.text == "", "run tag empty when clean, got '%s'" % main._run_label.text)
	m.mistake_streak = 3
	main._refresh_hud()
	_expect(main._run_label.visible, "run tag visible while a mistake run is in progress")
	_expect(main._run_label.text.contains("×3"), "run tag surfaces the live run, got '%s'" % main._run_label.text)
	m.mistake_streak = 0
	main._refresh_hud()
	_expect(not main._run_label.visible, "run tag hidden again once the run clears")
	# Signal-driven update (M128): a bet-driven lapse mutates the streak *before*
	# the decision_graded -> _refresh_hud ordering completes the render, so the
	# mental_changed signal (emitted after the mutation) must refresh the tag on
	# its own — no full HUD pass required.
	m.mistake_streak = 0
	main._refresh_hud()
	m.mistake_streak = 2
	main._loop.mental_changed.emit(40.0)
	_expect(main._run_label.visible, "run tag refreshed via mental_changed signal alone")
	_expect(main._run_label.text.contains("×2"), "run tag shows ×2 after signal refresh, got '%s'" % main._run_label.text)


# M129: the debrief label pool must resize to the actual line count. A tier-2
# session that makes play decisions AND reports a count check generates 10 lines
# (base 6 + Decisions + Composure + Counting + Unlocked). The pool was fixed at
# 9, silently clipping the trailing "Unlocked / Highest unlocked tier" line.
# Drives a 2-shoe tier-2 practice session, reporting counts at shoe cuts, then
# asserts the full line set renders with no empty labels.
func _check_debrief_full_line_rendering(main: Control) -> void:
	main._start_session(2, CHGameState.MODE_PRACTICE, 0, 2)
	var hands := 0
	var guard_total := 0
	while main._state.is_session_active() and hands < 500 and guard_total < 4000:
		if not main._loop.begin_hand():
			break
		hands += 1
		if main._loop.phase() == CHGameLoop.PHASE_BET:
			main._loop.place_bet(main._loop.optimal_bet_units())
		var guard := 0
		while not main._loop.is_idle() and guard < 60:
			main._loop.apply_action(main._loop.optimal_action())
			guard += 1
			guard_total += 1
		if main._loop.is_count_check_due():
			main._loop.report_count(main._loop.last_shoe_rc())
	_expect(not main._state.is_session_active(), "debrief-clip: session completed")
	_expect(main._debrief_panel.visible, "debrief-clip: debrief panel visible")
	# Preconditions: all three conditional lines present (10 total).
	_expect(main._discipline.session_decisions > 0,
		"debrief-clip: decisions recorded, got %d" % main._discipline.session_decisions)
	_expect(main._loop.get_count_accuracy().checks > 0,
		"debrief-clip: count check reported, got %d" % main._loop.get_count_accuracy().checks)
	var debrief_text := ""
	var empty_lines := 0
	for l in main._debrief_lines:
		debrief_text += l.text + "\n"
		if l.text.strip_edges().is_empty():
			empty_lines += 1
	# The trailing progression line (previously clipped at 9 labels) must render.
	_expect(debrief_text.contains("Unlocked") or debrief_text.contains("Highest unlocked tier"),
		"debrief-clip: progression line renders, got:\n" + debrief_text)
	_expect(empty_lines == 0, "debrief-clip: no empty debrief lines, got %d" % empty_lines)
	_expect(main._debrief_lines.size() == 10,
		"debrief-clip: pool sized to 10, got %d" % main._debrief_lines.size())


# M22: the Cash Out button ends the active session and surfaces the debrief.
# Starts its own fresh session so it is independent of the checks above.
func _check_cash_out_button(main: Control) -> void:
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	_expect(main._cash_out_button != null, "cash out button exists")
	_expect(main._state.is_session_active(), "session active before cash out")
	_expect(main._cash_out_button.visible, "cash out button visible while session active")
	# Start a hand so the loop is mid-session when the player cashes out.
	main._loop.begin_hand()
	if main._loop.phase() == CHGameLoop.PHASE_BET:
		main._loop.place_bet(main._loop.optimal_bet_units())
	main._on_cash_out()
	_expect(not main._state.is_session_active(), "session ended after cash out")
	_expect(main._state.last_end_reason == "cash_out", "reason is cash_out, got '%s'" % main._state.last_end_reason)
	_expect(not main._cash_out_button.visible, "cash out button hidden after session ends")
	_expect(main._new_session_button.visible, "New Session button shown after cash out")
	_expect(main._debrief_panel.visible, "debrief panel shown after cash out")


# M76: keyboard shortcuts must drive the same handlers the buttons do.
# Space in IDLE starts a hand (-> BET); a digit in BET places a bet (-> a
# decision phase). Uses InputEventKey + direct _unhandled_input call so the
# test is independent of the live input system.
func _check_keyboard_shortcuts(main: Control) -> void:
	# A first-run intro panel may be up; it gates gameplay input by design.
	main._hide_help()
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	# T1 is the count-only teaching table (Space deals AND auto-plays, never
	# resting in BET). This check exercises the *normal* keyboard model
	# (Space -> BET, digit -> bet), so test it with count-only off.
	main._loop.config.count_only = false
	_expect(main._loop.phase() == CHGameLoop.PHASE_IDLE, "kb: idle before deal")
	_key(main, KEY_SPACE)
	_expect(main._loop.phase() == CHGameLoop.PHASE_BET, "kb: Space deals -> BET, got %s" % main._loop.phase())
	_key(main, KEY_2)
	_expect(main._loop.phase() != CHGameLoop.PHASE_BET, "kb: '2' places a bet, leaves BET, got %s" % main._loop.phase())
	# A key that is not mapped for the current phase must be a no-op.
	var phase_before: String = main._loop.phase()
	_key(main, KEY_X)
	_expect(main._loop.phase() == phase_before, "kb: unmapped key is a no-op, got %s" % main._loop.phase())
	# M82: the deal shortcut must also work in PHASE_SETTLED, where the loop
	# rests between hands — the deal button is visible there and is labeled
	# "(Space)", but the key binding only covered the initial IDLE phase.
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	main._loop.config.count_only = false
	main._loop._phase = CHGameLoop.PHASE_SETTLED
	_key(main, KEY_SPACE)
	_expect(main._loop.phase() == CHGameLoop.PHASE_BET,
		"kb: Space deals from SETTLED, got %s" % main._loop.phase())


func _key(main: Control, keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	ev.echo = false
	main._unhandled_input(ev)


# M76: when a save file exists but fails to load (corrupt / future schema), the
# scene must warn the player and keep a backup copy so the next session end
# does not clobber the original.
func _check_save_loss_warning(main: Control) -> void:
	var p := ProjectSettings.globalize_path(CHGameState.DEFAULT_SAVE_PATH)
	# Write a save with a future schema version -> load_game() refuses it.
	var future: Dictionary = {
		"save_schema_version": CHGameState.SAVE_SCHEMA_VERSION + 1,
		"unlocked_tiers": [1, 2, 3],
		"lifetime_stats": {"skill_rating": 80.0},
	}
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(JSON.stringify(future))
	f.close()
	var backup := p + ".corrupt.bak"
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	_expect(main._state.get_skill_rating() == CHGameState.DEFAULT_SKILL_RATING, "save-loss: rating reset to default, got %.1f" % main._state.get_skill_rating())
	_expect(main._status_label.text.contains("could not be loaded"), "save-loss: warning shown, got '%s'" % main._status_label.text)
	_expect(FileAccess.file_exists(backup), "save-loss: backup file created")
	# Restore state: remove both the (still-bad) save and the backup so later
	# checks run on a clean default save.
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(backup)


# M77: the persistent skill rating (tier-unlock currency) is shown live in the
# HUD with the next tier's threshold. Set an explicit rating so the check is
# independent of whatever sessions the tool has driven so far.
func _check_skill_label(main: Control) -> void:
	main._state.lifetime_stats["skill_rating"] = 55.0
	main._refresh_hud()
	_expect(main._skill_label.visible, "skill label visible")
	_expect(main._skill_label.text == "Skill: 55.0 (T3 at 60)",
		"skill label shows rating + next threshold, got '%s'" % main._skill_label.text)
	main._state.lifetime_stats["skill_rating"] = 95.0
	main._refresh_hud()
	_expect(main._skill_label.text == "Skill: 95.0 (max tier)",
		"skill label at max tier, got '%s'" % main._skill_label.text)


# M81: on a multi-spot table, a multi-root presplit must render BOTH the
# already-resolved split hands and the current root awaiting its split decision.
# Rigs a deterministic two-spot shoe (up=5, hole=10, s1=7,7, s2=7,7; 7,7 vs 5 is
# a split) on the tier-4 2-spot config, splits spot 1, then asserts
# _hands_to_render() returns 3 hands (2 resolved + the current root) and that the
# current root is among them. Pinned at the helper level (not by counting scene
# rows) so it is immune to queue_free() timing in a headless run.
func _check_presplit_multi_spot_rendering(main: Control) -> void:
	main._start_session(4, CHGameState.MODE_TARGET, 150, 3)
	var shoe: CHShoeManager = main._loop.get_shoe()
	var suits := ["S", "H", "D", "C"]
	var open_ranks := [5, 10, 7, 7, 7, 7]
	var deck: Array[CHCard] = []
	for i in range(open_ranks.size()):
		deck.append(CHCard.new(suits[i % 4], int(open_ranks[i])))
	for i in range(open_ranks.size(), shoe.total_cards()):
		deck.append(CHCard.new(suits[i % 4], 2))
	shoe.deck = deck
	shoe.deal_index = 0
	_expect(main._loop.begin_hand(), "presplit-render: begin_hand")
	main._loop.place_bet(1)
	_expect(main._loop.phase() == CHGameLoop.PHASE_PRESPLIT,
		"presplit-render: spot 1 is a split decision, got %s" % main._loop.phase())
	main._loop.apply_action(main._loop.optimal_action())  # split spot 1
	_expect(main._loop.phase() == CHGameLoop.PHASE_PRESPLIT,
		"presplit-render: spot 2 is a split decision, got %s" % main._loop.phase())
	_expect(main._loop.all_hands().size() == 2,
		"presplit-render: spot 1 resolved to 2 hands, got %d" % main._loop.all_hands().size())
	var rendered: Array[CHHand] = main._hands_to_render()
	_expect(rendered.size() == 3,
		"presplit-render: 3 hands to render (2 resolved + current root), got %d" % rendered.size())
	_expect(rendered.has(main._loop.current_hand()),
		"presplit-render: current root included in the rendered hands")
	# Single-spot presplit control: behavior must be unchanged (only the current
	# root renders). _hands_to_render() reads main._loop, so swap the loop in,
	# read, and restore immediately.
	var single := CHTableConfig.for_tier(1)
	var sstate := CHGameState.new()
	sstate.start_session(1, CHGameState.MODE_TARGET, 150, 3)
	var sloop := CHGameLoop.new(single, sstate, CHDisciplineSystem.new(), 20260906)
	var sopen := [5, 10, 7, 7]
	var sdeck: Array[CHCard] = []
	for i in range(sopen.size()):
		sdeck.append(CHCard.new(suits[i % 4], int(sopen[i])))
	for i in range(sopen.size(), sloop.get_shoe().total_cards()):
		sdeck.append(CHCard.new(suits[i % 4], 2))
	sloop.get_shoe().deck = sdeck
	sloop.get_shoe().deal_index = 0
	_expect(sloop.begin_hand(), "presplit-render-single: begin_hand")
	sloop.place_bet(1)
	_expect(sloop.phase() == CHGameLoop.PHASE_PRESPLIT,
		"presplit-render-single: single spot is a split decision, got %s" % sloop.phase())
	var saved_loop: CHGameLoop = main._loop
	main._loop = sloop
	var single_rendered: Array[CHHand] = main._hands_to_render()
	main._loop = saved_loop
	_expect(single_rendered.size() == 1,
		"presplit-render-single: only the current root renders, got %d" % single_rendered.size())


# M84/M130: the help panel must exist and stay hidden by default (no auto
# intro on first launch — M130); it only appears when the player opens it via
# F1, Esc-close, or the Help button.
func _check_help_panel(main: Control) -> void:
	_expect(main._help_panel != null, "help: panel exists")
	_expect(main._help_button != null, "help: button exists")
	# First run: no save file, and the panel must not pop up on its own (M130).
	var p := ProjectSettings.globalize_path(CHGameState.DEFAULT_SAVE_PATH)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	main._hide_help()
	_expect(not main._help_panel.visible, "help: no auto intro on first run")
	# F1 opens it, then F1 closes it.
	_key(main, KEY_F1)
	_expect(main._help_panel.visible, "help: F1 opens the panel")
	_key(main, KEY_F1)
	_expect(not main._help_panel.visible, "help: F1 closes the panel")
	# Esc closes it.
	_key(main, KEY_F1)
	_key(main, KEY_ESCAPE)
	_expect(not main._help_panel.visible, "help: Esc closes the panel")
	# The Help button toggles it.
	main._on_help_pressed()
	_expect(main._help_panel.visible, "help: button opens the panel")
	main._on_help_pressed()
	_expect(not main._help_panel.visible, "help: button closes the panel")


# Driving the practice session to completion ends it (end_session -> save()),
# which writes the user save. Remove that artifact so the tool leaves no residue.
func _cleanup_save() -> void:
	var p := ProjectSettings.globalize_path("user://counting_house_save.json")
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	# M83: atomic saves write a sibling .tmp before renaming; remove any residue.
	if FileAccess.file_exists(p + ".tmp"):
		DirAccess.remove_absolute(p + ".tmp")


# M86: the shoe-cut count check must gate keyboard input the same way it gates
# the bet buttons — pressing a bet digit while the check is pending must NOT
# place a bet; Enter should submit the pending report.
func _check_count_check_keyboard_gate(main: Control) -> void:
	main._hide_help()
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	main._loop.begin_hand()
	_expect(main._loop.phase() == CHGameLoop.PHASE_BET, "kb-gate: in BET phase")
	main._loop._count_check_due = true
	var phase_before: String = main._loop.phase()
	_key(main, KEY_3)
	_expect(main._loop.phase() == phase_before,
		"kb-gate: bet key while check pending does not place a bet, got %s" % main._loop.phase())
	main._count_check_input.text = "0"
	_key(main, KEY_ENTER)
	_expect(main._loop.is_count_check_due() == false, "kb-gate: Enter submits pending check")
	# After the check is cleared, a bet key should now work.
	_key(main, KEY_3)
	_expect(main._loop.phase() != CHGameLoop.PHASE_BET,
		"kb-gate: bet key works after check cleared, got %s" % main._loop.phase())
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)


# M86: _on_hand_settled must accumulate per-hand rounded net (the same integer
# that apply_hand_result adds to bankroll) so the debrief P&L stays consistent.
func _check_pnl_rounding(main: Control) -> void:
	main._session_net = 0.0
	main._on_hand_settled(-0.5, 1.0)
	_expect(main._session_net == -1.0,
		"pnl-rounding: -0.5 hand accrues -1.0, got %f" % main._session_net)
	main._on_hand_settled(-0.5, 1.0)
	_expect(main._session_net == -2.0,
		"pnl-rounding: two -0.5 hands accumulate to -2.0, got %f" % main._session_net)
	main._session_net = 0.0


# M87: bet-sizing feedback must correctly reflect the relationship between
# the player's bet and the count-optimal ramp.
func _check_bet_feedback_text(main: Control) -> void:
	_expect(main._bet_status_text(4, 4, false) == "Bet: 4u (optimal)", "bet-feedback: optimal match")
	_expect(main._bet_status_text(2, 6, false) == "Bet: 2u — optimal was 6u", "bet-feedback: short bet")
	_expect(main._bet_status_text(6, 1, false) == "Bet: 6u — optimal was 1u", "bet-feedback: long bet")
	_expect(main._bet_status_text(1, 4, true) == "Bet: 1u (cover)", "bet-feedback: cover overrides optimal")


# M121: per-action decision feedback mirrors bet feedback and tags count deviations.
func _check_action_feedback_text(main: Control) -> void:
	# _pretty_action
	_expect(main._pretty_action("hit") == "Hit", "pretty: hit")
	_expect(main._pretty_action("stand") == "Stand", "pretty: stand")
	_expect(main._pretty_action("double") == "Double", "pretty: double")
	_expect(main._pretty_action("surrender") == "Surrender", "pretty: surrender")
	_expect(main._pretty_action("split") == "Split", "pretty: split")
	_expect(main._pretty_action("play") == "No split", "pretty: play")
	_expect(main._pretty_action("take") == "Take insurance", "pretty: take")
	_expect(main._pretty_action("decline") == "Decline insurance", "pretty: decline")
	_expect(main._pretty_action("unknown_xyz") == "unknown_xyz", "pretty: fallback passthrough")

	# _action_status_text: optimal match
	_expect(main._action_status_text("stand", "stand", false) == "Stand (optimal)",
		"action-feedback: optimal stand")
	_expect(main._action_status_text("hit", "hit", false) == "Hit (optimal)",
		"action-feedback: optimal hit")

	# _action_status_text: non-optimal
	_expect(main._action_status_text("hit", "stand", false) == "Hit — optimal was Stand",
		"action-feedback: hit vs stand")
	_expect(main._action_status_text("stand", "double", false) == "Stand — optimal was Double",
		"action-feedback: stand vs double")

	# _action_status_text: deviation tag
	_expect(main._action_status_text("hit", "hit", true) == "Hit (optimal) (count deviation)",
		"action-feedback: deviation tag on optimal")
	_expect(main._action_status_text("stand", "hit", true) == "Stand — optimal was Hit (count deviation)",
		"action-feedback: deviation tag on non-optimal")


# M88: the dealer's hidden hole card must render as a face-down card back (not a
# gap) while the player is acting. Pin the card-back control directly: it is a
# PanelContainer with the same 44x60 footprint as a card face and a centred
# glyph, independent of queue_free timing in a headless run.
func _check_card_back(main: Control) -> void:
	var back: Control = main._card_back()
	_expect(back != null and back is PanelContainer, "card-back: is a PanelContainer")
	_expect(back.custom_minimum_size == Vector2(44, 60), "card-back: 44x60 footprint like a face")
	# The back carries a single centred glyph label (the suit-free pattern mark).
	var glyph := back.get_child(0)
	_expect(glyph is Label and glyph.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, "card-back: centred glyph")

	# Wiring: with a live hand and the hole still hidden, _refresh_cards must
	# render TWO 44x60 dealer slots (upcard face + card back). Read the dealer
	# row's PanelContainer children with the card footprint.
	main._hide_help()
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	main._loop.begin_hand()
	if main._loop.phase() == CHGameLoop.PHASE_BET:
		main._loop.place_bet(main._loop.optimal_bet_units())
	main._refresh_cards()
	var slots := 0
	for c in main._dealer_cards.get_children():
		if c is PanelContainer and c.custom_minimum_size == Vector2(44, 60):
			slots += 1
	_expect(slots >= 2, "card-back: dealer shows upcard + back while hole hidden, got %d slots" % slots)


# M89: _active_hand_index must identify the hand the player is acting on.
# Single-hand: index 0 in PHASE_HAND. Presplit multi-spot: index of the
# current root (last rendered hand). No active hand outside decision phases.
func _check_active_hand_index(main: Control) -> void:
	# Single-hand tier-1, drive to PHASE_HAND.
	main._hide_help()
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	main._loop.begin_hand()
	if main._loop.phase() == CHGameLoop.PHASE_BET:
		main._loop.place_bet(main._loop.optimal_bet_units())
	var hands1: Array[CHHand] = main._hands_to_render()
	var idx1: int = main._active_hand_index(hands1)
	if main._loop.phase() == CHGameLoop.PHASE_HAND:
		_expect(idx1 == 0, "active-hand: single hand in HAND phase -> index 0, got %d" % idx1)
	elif main._loop.phase() == CHGameLoop.PHASE_PRESPLIT:
		# Tier 1 allows splits; a dealt pair lands in PRESPLIT where the
		# single current hand is still index 0.
		_expect(idx1 == 0, "active-hand: single hand in PRESPLIT -> index 0, got %d" % idx1)
	else:
		# Insurance or other phase: index should be -1.
		_expect(idx1 == -1, "active-hand: non-HAND/PRESPLIT phase -> -1, got %d" % idx1)

	# Presplit multi-spot: rig tier-4 two-spot shoe, split spot 1, verify
	# the active index points to the current root (last in render list).
	main._start_session(4, CHGameState.MODE_TARGET, 150, 3)
	var shoe: CHShoeManager = main._loop.get_shoe()
	var suits := ["S", "H", "D", "C"]
	var open_ranks := [5, 10, 7, 7, 7, 7]
	var deck: Array[CHCard] = []
	for i in range(open_ranks.size()):
		deck.append(CHCard.new(suits[i % 4], int(open_ranks[i])))
	for i in range(open_ranks.size(), shoe.total_cards()):
		deck.append(CHCard.new(suits[i % 4], 2))
	shoe.deck = deck
	shoe.deal_index = 0
	main._loop.begin_hand()
	main._loop.place_bet(1)
	# Should now be in PHASE_PRESPLIT (spot 1 is a 7,7 vs 5).
	if main._loop.phase() == CHGameLoop.PHASE_PRESPLIT:
		main._loop.apply_action(main._loop.optimal_action())  # split spot 1
		if main._loop.phase() == CHGameLoop.PHASE_PRESPLIT:
			var hands2: Array[CHHand] = main._hands_to_render()
			var idx2: int = main._active_hand_index(hands2)
			# After splitting spot 1, spot 2 (the root) is the last rendered hand.
			_expect(idx2 == hands2.size() - 1,
				"active-hand: presplit current root is last rendered hand, got %d of %d" % [idx2, hands2.size()])


# M90: player hand rows must show a numeric total, red on bust, green on 21.
func _check_hand_total_label(main: Control) -> void:
	var ok := CHHand.new()
	ok.add_card(CHCard.new("S", 10))
	ok.add_card(CHCard.new("H", 5))
	var l_ok: Label = main._hand_total_label(ok)
	_expect(l_ok is Label and l_ok.text == "15", "hand-total: '15' for 10+5, got '%s'" % str(l_ok.text))

	var bust := CHHand.new()
	bust.add_card(CHCard.new("S", 10))
	bust.add_card(CHCard.new("H", 10))
	bust.add_card(CHCard.new("D", 5))
	var l_bust: Label = main._hand_total_label(bust)
	_expect(l_bust.text == "25", "hand-total: '25' for 10+10+5, got '%s'" % str(l_bust.text))
	_expect(l_bust.get_theme_color("font_color") == Color(0.9, 0.2, 0.2),
		"hand-total: bust total is red, got %s" % str(l_bust.get_theme_color("font_color")))

	var bj := CHHand.new()
	bj.add_card(CHCard.new("S", 14))
	bj.add_card(CHCard.new("H", 10))
	var l_bj: Label = main._hand_total_label(bj)
	_expect(l_bj.text == "21", "hand-total: '21' for A+10, got '%s'" % str(l_bj.text))
	_expect(l_bj.get_theme_color("font_color") == Color(0.3, 0.85, 0.4),
		"hand-total: 21 total is green, got %s" % str(l_bj.get_theme_color("font_color")))


# M91: heat label colour must shift with severity — neutral below 0.5, amber
# 0.5-0.75, red-orange 0.75+, and hot red when backed off (backoff wins).
func _check_heat_color(main: Control) -> void:
	_expect(main._heat_color(0.3, false) == Color(1, 1, 1), "heat-color: low heat is neutral (sentinel)")
	_expect(main._heat_color(0.6, false) == Color(0.95, 0.75, 0.2), "heat-color: mid heat is amber")
	_expect(main._heat_color(0.8, false) == Color(0.85, 0.45, 0.2), "heat-color: high heat is red-orange")
	_expect(main._heat_color(0.1, true) == Color(0.9, 0.2, 0.2), "heat-color: backoff is hot red regardless of %")


# M92: the career/stats overlay must surface persistent progression. Pin the
# pure readout builder _stats_lines() against a known state, then the overlay's
# Tab/Esc/button toggle.
func _check_stats_panel(main: Control) -> void:
	var st: CHGameState = main._state
	st.lifetime_stats["skill_rating"] = 72.5
	st.lifetime_stats["hands_played"] = 137
	st.lifetime_stats["sessions_played"] = 9
	st.unlocked_tiers = [1, 2, 3, 4]
	st.unlocked_systems = ["hi_lo", "ko"]
	st.reputation_heat_floor = {2: 40.0, 3: 75.0}
	var lines: Array[String] = main._stats_lines()
	_expect(lines.size() == 5, "stats: 5 lines, got %d" % lines.size())
	_expect(lines[0].begins_with("Skill rating:  72.5"), "stats: rating line, got '%s'" % lines[0])
	_expect(lines[0].contains("High Stakes Floor (T5) unlocks at 80"), "stats: next-tier note names venue, got '%s'" % lines[0])
	_expect(lines[1] == "Lifetime:  137 hands over 9 sessions", "stats: lifetime line, got '%s'" % lines[1])
	_expect(lines[2] == "Unlocked tiers:  Kitchen Table (T1), The Rec Room (T2), Card Room (T3), City Casino (T4)", "stats: unlocked line uses venue names, got '%s'" % lines[2])
	_expect(lines[3] == "Counting systems:  Hi-Lo, KO", "stats: systems line, got '%s'" % lines[3])
	_expect(lines[4] == "Heat floors:  T2 40%, T3 75%", "stats: heat-floors line, got '%s'" % lines[4])
	# Overlay wiring: hidden at rest; Tab opens it (populating 5 lines); Esc closes.
	_expect(main._stats_button != null, "stats: button exists")
	_expect(main._stats_panel != null, "stats: panel exists")
	_expect(not main._stats_panel.visible, "stats: panel hidden at rest")
	_key(main, KEY_TAB)
	_expect(main._stats_panel.visible, "stats: Tab opens the panel")
	_expect(main._stats_content.get_child_count() == 5, "stats: panel shows 5 lines, got %d" % main._stats_content.get_child_count())
	_key(main, KEY_ESCAPE)
	_expect(not main._stats_panel.visible, "stats: Esc closes the panel")
	# The Stats button also toggles it.
	main._on_stats_pressed()
	_expect(main._stats_panel.visible, "stats: button opens the panel")
	main._on_stats_pressed()
	_expect(not main._stats_panel.visible, "stats: button closes the panel")


# M116: the staged tutorial on-ramp. Verifies the scene-level wiring that
# tutorial_check (loop/state logic) cannot reach: the stage label, the
# Deal/Next button swap, the auto-bet/auto-play advance path, and the config
# overrides that make the teaching table safe for a learning session.
func _check_tutorial_mode(main: Control) -> void:
	main._start_session(1, CHGameState.MODE_TUTORIAL, 0, 3)
	# Session start now shows the venue banner (M122). Reset it so the assertions
	# below test the stage-transition banner's rest state, not the venue banner.
	main._tutorial_banner.visible = false
	main._tutorial_banner.modulate.a = 1.0
	var st: CHGameState = main._state
	_expect(st.session_mode == CHGameState.MODE_TUTORIAL, "tut: mode is tutorial")
	_expect(st.current_tier == 1, "tut: anchored to tier 1, got %d" % st.current_tier)
	# Config overrides applied by _start_session (mirrors the no-stakes, no-heat
	# teaching table the on-ramp needs).
	_expect(main._loop.config.heat_active == false, "tut: heat is off")
	_expect(main._loop.config.show_count_display == false, "tut: count display is off")
	_expect(main._loop.config.count_check_active == true, "tut: count checks stay on")

	# Stage 1: the player only counts. Deal is hidden, "Next" is the sole advance
	# control, and no bet / action / cover controls are shown.
	_expect(main._loop.tutorial_stage() == 1, "tut: stage 1 at start")
	_expect(main._tutorial_stage_label.visible, "tut: stage label visible")
	_expect(main._tutorial_stage_label.text.contains("1/3"), "tut: stage label shows 1/3 progress, got '%s'" % main._tutorial_stage_label.text)
	_expect(not main._deal_button.visible, "tut: deal button hidden in stage 1")
	_expect(main._tutorial_next_button.visible, "tut: next button visible in stage 1")
	_expect(not main._cover_toggle.visible, "tut: cover toggle hidden in stage 1")
	for u in main._bet_buttons.keys():
		_expect(not main._bet_buttons[u].visible, "tut: bet button %s hidden in stage 1" % u)
	for a in main._action_buttons.keys():
		_expect(not main._action_buttons[a].visible, "tut: action %s hidden in stage 1" % a)

	# One "Next" press: begins the hand AND auto-bets it (stage 1), so a hand is
	# now live and the player is in a decision phase (or settled if a natural was
	# dealt — a valid outcome of the auto-bet path). No bet control was touched.
	main._on_tutorial_next()
	var ph: String = main._loop.phase()
	_expect(ph != CHGameLoop.PHASE_BET and ph != CHGameLoop.PHASE_IDLE,
		"tut: auto-bet advanced past BET, got '%s'" % ph)
	if ph != CHGameLoop.PHASE_SETTLED:
		_expect(not main._deal_button.visible, "tut: deal button stays hidden mid-hand")
		_expect(main._tutorial_next_button.visible, "tut: next button stays visible mid-hand")
	# The opening cards were dealt and rendered.
	_expect(main._loop.dealer_upcard() != null, "tut: dealer upcard dealt")

	# The stage label tracks the live stage; it is driven by _refresh_hud.
	_expect(main._loop.tutorial_stage() == 1, "tut: still stage 1 within shoe 1")

	# M117: keyboard gate in stage 1 — digit keys and action keys are ignored
	# (only Space/Enter work), preventing stray inputs from altering the guided flow.
	var phase_before_key: String = main._loop.phase()
	_key(main, KEY_1)
	_expect(main._loop.phase() == phase_before_key,
		"tut: digit key ignored in stage 1 (no bet), got %s" % main._loop.phase())
	_key(main, KEY_H)
	_expect(main._loop.phase() == phase_before_key,
		"tut: H key ignored in stage 1 (no hit), got %s" % main._loop.phase())

	# M117: the stage-unlock banner. Hidden at rest; a stage rise into 2/3 fires
	# it (text set synchronously, label shown), re-firing the same stage is
	# silent, and the stage-2 text names the count accuracy when cuts are graded.
	_expect(main._tutorial_banner != null, "tut: stage banner exists")
	_expect(not main._tutorial_banner.visible, "tut: banner hidden at rest")
	_expect(main._stage_transition_text(2).begins_with("Stage 2 unlocked"), "tut: stage-2 transition text, got '%s'" % main._stage_transition_text(2))
	_expect(main._stage_transition_text(3).begins_with("Stage 3 unlocked"), "tut: stage-3 transition text, got '%s'" % main._stage_transition_text(3))
	main._last_tutorial_stage = 1
	main._maybe_announce_tutorial_stage(2)
	_expect(main._tutorial_banner.visible, "tut: 1->2 advance shows the banner")
	_expect(main._tutorial_banner.text.begins_with("Stage 2 unlocked"), "tut: banner names stage 2, got '%s'" % main._tutorial_banner.text)
	var banner_text: String = main._tutorial_banner.text
	main._maybe_announce_tutorial_stage(2)
	_expect(main._tutorial_banner.text == banner_text, "tut: re-announcing the same stage is silent")
	main._maybe_announce_tutorial_stage(3)
	_expect(main._tutorial_banner.text.begins_with("Stage 3 unlocked"), "tut: 2->3 advance shows the stage-3 banner, got '%s'" % main._tutorial_banner.text)
	# A lower live-stage read must not re-fire the banner (tracker is monotonic
	# within a session; only a new session resets it to 0 via _refresh_hud's
	# else-branch / _start_session).
	var stage3_text: String = main._tutorial_banner.text
	main._refresh_hud()
	_expect(main._tutorial_banner.text == stage3_text, "tut: live stage 1 does not re-fire the banner after a stage-3 advance")
	_expect(main._last_tutorial_stage == 3, "tut: tracker stays monotonic, got %d" % main._last_tutorial_stage)

	# M119: stage-2 manual betting gets count-ramp feedback even though the
	# teaching table does not grade bet ramps in normal play (stage 2 is where
	# betting on the true count is taught). Negative control: practice mode on
	# the same table stays silent.
	main._start_session(1, CHGameState.MODE_TUTORIAL, 0, 3)
	main._state.shoes_this_session = 1
	main._refresh_all()
	_expect(main._loop.tutorial_stage() == 2, "tut: forced to stage 2 for bet feedback, got %d" % main._loop.tutorial_stage())
	main._on_deal()
	_expect(main._loop.phase() == CHGameLoop.PHASE_BET, "tut: stage-2 deal lands in BET, got %s" % main._loop.phase())
	main._on_bet_units(2)
	_expect(main._status_label.text.begins_with("Bet: "), "tut: stage-2 bet shows ramp feedback, got '%s'" % main._status_label.text)
	# Negative control: practice on the same T1 table (grade_bet_ramp off, not
	# tutorial) must NOT show ramp feedback. T1 practice is now count-only (the
	# hand auto-plays, so there is no BET phase to bet in); this check exercises
	# the bet-feedback text path, so test it with count-only off.
	main._start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	main._loop.config.count_only = false
	main._on_deal()
	_expect(main._loop.phase() == CHGameLoop.PHASE_BET, "tut: practice deal lands in BET, got %s" % main._loop.phase())
	main._on_bet_units(1)
	_expect(not main._status_label.text.begins_with("Bet: "), "tut: practice T1 bet shows no ramp feedback, got '%s'" % main._status_label.text)

	# M120: stage-2 unified deal flow — Deal button hidden, Next visible when idle,
	# so the player has one advance button throughout the on-ramp.
	main._start_session(1, CHGameState.MODE_TUTORIAL, 0, 3)
	main._state.shoes_this_session = 1
	main._refresh_all()
	_expect(main._loop.tutorial_stage() == 2, "tut: stage 2 for unified deal check, got %d" % main._loop.tutorial_stage())
	_expect(main._loop.is_idle(), "tut: stage 2 starts idle")
	_expect(not main._deal_button.visible, "tut: Deal hidden in stage 2 idle")
	_expect(main._tutorial_next_button.visible, "tut: Next visible in stage 2 idle")
	# Next deals the hand in stage 2 (same path as stage 1).
	main._on_tutorial_next()
	_expect(not main._loop.is_idle(), "tut: Next dealt the hand in stage 2")
	_expect(main._loop.phase() == CHGameLoop.PHASE_BET, "tut: stage-2 Next deal lands in BET, got %s" % main._loop.phase())
	_expect(not main._tutorial_next_button.visible, "tut: Next hidden in stage 2 BET (player must bet)")
	_expect(main._bet_buttons[1].visible, "tut: bet buttons visible in stage 2 BET")

	# M120: per-stage counting summary — groups recorded scores by stage.
	main._tutorial_count_results = []
	_expect(main._tutorial_counting_summary() == "", "tut: empty results produce empty summary")
	main._tutorial_count_results = [
		{"stage": 1, "reported": 3, "actual": 3, "score": 100.0},
		{"stage": 1, "reported": -1, "actual": 1, "score": 90.0},
		{"stage": 2, "reported": 2, "actual": 2, "score": 100.0},
	]
	var summary: String = main._tutorial_counting_summary()
	_expect(summary.begins_with("Counting:"), "tut: summary starts with Counting:, got '%s'" % summary)
	_expect(summary.contains("S1"), "tut: summary contains S1, got '%s'" % summary)
	_expect(summary.contains("S2"), "tut: summary contains S2, got '%s'" % summary)
	# S1 avg = (100+90)/2 = 95, S2 avg = 100
	_expect(summary.contains("95"), "tut: summary shows S1 avg 95, got '%s'" % summary)
	_expect(summary.contains("100"), "tut: summary shows S2 avg 100, got '%s'" % summary)


# M121: the Tier 1 teaching table is count-only. Verify the scene (a) hides
# every bet / cover / play control, (b) auto-plays the hand so the player never
# sits in BET, and (c) gates the deal button on the pending running-count report
# so the count is the player's sole interaction.
func _check_count_only_teaching_table(main: Control) -> void:
	main._hide_help()
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	_expect(main._loop.config.count_only == true, "count-only: T1 teaching table is count-only")
	# Fresh session: no count check pending, so the deal button is available.
	_expect(main._loop.is_count_check_due() == false, "count-only: no check pending at session start")
	_expect(main._deal_button.visible, "count-only: deal button visible when idle")
	_expect(main._deal_button.disabled == false, "count-only: deal enabled with no check pending")
	# Deal: the hand auto-bets and auto-plays straight to settle; the player
	# never rests in the BET phase.
	main._on_deal()
	_expect(main._loop.phase() == CHGameLoop.PHASE_SETTLED,
		"count-only: auto-play settles the hand, got %s" % main._loop.phase())
	_expect(main._status_label.text.contains("running count"),
		"count-only: status reinforces the count report, got '%s'" % main._status_label.text)
	# The player's own cards must be visible (not just the dealer's): the
	# auto-played hand stays on the table so the player can see and count the
	# cards that were played. Without this the teaching table is just a dealer
	# card stream and the player cannot track the running count.
	var player_rows := 0
	for c in main._player_area.get_children():
		if c is HBoxContainer and c != main._dealer_row:
			player_rows += 1
	_expect(player_rows >= 1,
		"count-only: player's own hand cards are shown (not just the dealer's), got %d player row(s)" % player_rows)
	# No bet / cover / play controls are offered on the teaching table.
	for u in main._bet_buttons.keys():
		_expect(not main._bet_buttons[u].visible, "count-only: bet button %s hidden" % u)
	_expect(not main._cover_toggle.visible, "count-only: cover toggle hidden")
	for a in main._action_buttons.keys():
		_expect(not main._action_buttons[a].visible, "count-only: action %s hidden" % a)
	# The live running count is hidden so the player must track it themselves;
	# the HUD shows a tracking nudge instead of the numeric TC readout.
	_expect(not main._tc_label.text.begins_with("TC:"),
		"count-only: numeric TC readout hidden, got '%s'" % main._tc_label.text)
	_expect(main._tc_label.text.contains("track"),
		"count-only: HUD shows a tracking nudge, got '%s'" % main._tc_label.text)
	# The player made no decisions, so the Decisions read-out is hidden too.
	_expect(not main._decision_acc_label.visible,
		"count-only: decisions label hidden (no player decisions), got visible=%s" % str(main._decision_acc_label.visible))
	# The per-hand count check fired (count_check_active), so the deal button is
	# now gated until the player reports the running count.
	_expect(main._loop.is_count_check_due(),
		"count-only: per-hand count check pending after the auto-played hand")
	_expect(main._deal_button.disabled == true, "count-only: deal gated while the count check is pending")
	# Answering the check re-enables the deal button.
	main._loop._count_check_due = false
	main._refresh_actions()
	_expect(main._deal_button.disabled == false, "count-only: deal re-enabled once the check is answered")
	# Drive a 1-shoe practice session (count_only stays on) to completion and
	# check the debrief: it must surface the Counting line (the point of the
	# table) and NOT a Decisions line (the engine auto-played, so M/N optimal is
	# not the player's skill). Practice ends deterministically at the shoe cut.
	main._start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	var hands := 0
	var guard := 0
	while main._state.is_session_active() and hands < 40 and guard < 400:
		if main._loop.is_count_check_due():
			main._loop.report_count(main._loop.last_shoe_rc())
		if not main._loop.begin_hand():
			break
		hands += 1
		if main._loop.phase() == CHGameLoop.PHASE_BET:
			main._loop.place_bet(main._loop.optimal_bet_units())
		var g2 := 0
		while not main._loop.is_idle() and g2 < 60:
			main._loop.apply_action(main._loop.optimal_action())
			g2 += 1
			guard += 1
	_expect(not main._state.is_session_active(),
		"count-only: practice session completed, active=%s" % str(main._state.is_session_active()))
	var debrief_text := ""
	for l in main._debrief_lines:
		debrief_text += l.text + "\n"
	_expect(debrief_text.contains("Counting:"),
		"count-only: debrief shows Counting line, got: " + debrief_text)
	_expect(not debrief_text.contains("Decisions:"),
		"count-only: debrief omits Decisions line, got: " + debrief_text)
	# Restore the session this check disturbed for any later checks.
	main._start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	main._loop.config.count_only = false


# The Tier-1 counting drill must not surface later-tier readouts. Heat (the pit's
# suspicion meter), discipline (T2+ decision grading), and cover (only usable once
# betting starts) are all hidden on the count-only teaching table, keeping the
# on-ramp HUD limited to what the player is actually doing (tracking the count).
# Each reappears at the tier that introduces its feature.
func _check_t1_teaching_hud_clean(main: Control) -> void:
	main._hide_help()
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	_expect(main._loop.config.count_only == true, "t1-hud: teaching table is count-only")
	main._refresh_hud()
	_expect(not main._heat_label.visible, "t1-hud: heat readout hidden on T1, got visible")
	_expect(not main._discipline_label.visible, "t1-hud: discipline readout hidden on T1, got visible")
	_expect(not main._cover_label.visible, "t1-hud: cover readout hidden on T1, got visible")
	# Core on-ramp readouts stay: bankroll, tier, mode, and the count nudge.
	_expect(main._bankroll_label.visible, "t1-hud: bankroll stays visible on T1")
	_expect(main._tier_label.visible, "t1-hud: tier stays visible on T1")
	_expect(main._mode_label.visible, "t1-hud: mode stays visible on T1")
	_expect(main._tc_label.visible, "t1-hud: running-count nudge stays visible on T1")
	# And they reappear at the tier that introduces the feature (T2 grades
	# decisions and leaves the count-only drill, so cover + heat apply again).
	main._start_session(2, CHGameState.MODE_TARGET, 150, 3)
	main._refresh_hud()
	_expect(main._discipline_label.visible, "t1-hud: discipline reappears at T2")
	_expect(main._cover_label.visible, "t1-hud: cover reappears at T2")
	_expect(main._heat_label.visible, "t1-hud: heat reappears at T2")
	# Restore a clean session for any later checks.
	main._start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	main._loop.config.count_only = false


func _check_npc_player_rows(main: Control) -> void:
	var old_loop: CHGameLoop = main._loop
	var config := CHTableConfig.new()
	config.npc_players = 1
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 150, 3)
	var new_loop := CHGameLoop.new(config, state, CHDisciplineSystem.new(), 20260906)

	main._loop = new_loop
	if not new_loop.begin_hand():
		_failures.append("npc-rows: begin_hand failed")
		main._loop = old_loop
		return
	new_loop.place_bet(1)
	main._refresh_cards()

	var found_npc_label := false
	for c in main._player_area.get_children():
		if c is HBoxContainer:
			for child in c.get_children():
				if child is Label and child.text.begins_with("Player 2"):
					found_npc_label = true
					break
		if found_npc_label:
			break

	_expect(found_npc_label, "npc-rows: NPC row label 'Player 2' not found in player area")

	main._loop = old_loop
	main._refresh_cards()


# The named opponent (Sal) must render its own row distinct from filler NPCs,
# showing its name, bet size, and cards. The session-start loop always seats an
# opponent (CHTableConfig._opponent_for_tier), so this is valid for any tier.
func _check_opponent_row(main: Control) -> void:
	var old_loop: CHGameLoop = main._loop
	main._start_session(2, CHGameState.MODE_PRACTICE, 0, 1)
	if not main._loop.begin_hand():
		_failures.append("opp-row: begin_hand failed")
		main._loop = old_loop
		return
	if main._loop.phase() == CHGameLoop.PHASE_BET:
		main._loop.place_bet(1)
	main._refresh_cards()
	var found_opp := false
	for c in main._player_area.get_children():
		if c is HBoxContainer:
			for child in c.get_children():
				if child is Label and child.text.begins_with("Sal"):
					found_opp = true
					break
		if found_opp:
			break
	_expect(found_opp, "opp-row: opponent row labeled with rival name not found")
	main._loop = old_loop
	main._refresh_cards()


# Tier 1 is the count-only teaching table: the player counts alone, so there is
# no named rival and no filler NPCs to add unseen cards to the count stream.
func _check_t1_no_opponent(_main: Control) -> void:
	var cfg: CHTableConfig = CHTableConfig.for_tier(1)
	_expect(cfg.opponent == null, "t1-no-opp: T1 config has no opponent, got '%s'" % str(cfg.opponent))
	_expect(cfg.npc_players == 0, "t1-no-opp: T1 has 0 NPC players, got %d" % cfg.npc_players)
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 150, 3)
	var loop := CHGameLoop.new(cfg, state, CHDisciplineSystem.new(), 20260906)
	_expect(loop.get_opponent() == null, "t1-no-opp: loop has no opponent, got '%s'" % str(loop.get_opponent()))


# The dealer's drawn cards must render: before the fix, _refresh_cards only
# showed upcard + hole, so dealer hits were counted into the running count but
# invisible to the player (the count looked "wrong"). After the hole is
# revealed every dealer card renders face-up, so the rendered card count must
# equal the dealer hand size.
func _check_dealer_drawn_cards_rendered(main: Control) -> void:
	var old_loop: CHGameLoop = main._loop
	var config := CHTableConfig.new()
	config.deck_count = 1
	config.allows_split = true
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 150, 3)
	var loop := CHGameLoop.new(config, state, CHDisciplineSystem.new(), 20260906)
	main._loop = loop
	var seen_dealer_cards := 0
	for h in 6:
		if not loop.begin_hand():
			break
		if loop.phase() == CHGameLoop.PHASE_BET:
			loop.place_bet(loop.optimal_bet_units())
		var guard := 0
		while not loop.is_idle() and guard < 64:
			loop.apply_action(loop.optimal_action())
			guard += 1
		var before: int = main._dealer_cards.get_child_count()
		main._refresh_cards()
		var after: int = main._dealer_cards.get_child_count()
		var held: int = loop.dealer_hand().cards.size()
		# Once the hole is revealed, _refresh_cards also appends the hand-total
		# label (the verification readout), so the child delta is held + 1.
		var revealed: bool = loop.dealer_hole() != null
		var expected: int = held + (1 if revealed else 0)
		if loop.dealer_hand().cards.size() > 2:
			seen_dealer_cards += 1
		_expect(after - before == expected,
			"dealer-cards: hand %d added %d children, expected %d (dealer holds %d, revealed=%s)" % [h, after - before, expected, held, revealed])
	_expect(seen_dealer_cards > 0, "dealer-cards: at least one dealer hit across 6 hands (got %d)" % seen_dealer_cards)
	main._loop = old_loop
	main._refresh_cards()


func _check_venue_banner(main: Control) -> void:
	# Start a session and confirm the venue banner text is populated from the
	# tier config's venue_name + venue_hook.
	var old_loop: CHGameLoop = main._loop
	main._start_session(1, CHGameState.MODE_TARGET, 150, 3)
	var cfg: CHTableConfig = CHTableConfig.for_tier(1)
	var expected: String = "%s — %s" % [cfg.venue_name, cfg.venue_hook]
	_expect(main._tutorial_banner.text == expected,
		"venue-banner: expected '%s', got '%s'" % [expected, main._tutorial_banner.text])
	main._loop = old_loop


func _finish() -> void:
	if _failures.is_empty():
		print("scene_smoke_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("scene_smoke_check: %d failure(s)" % _failures.size())
		quit(1)
