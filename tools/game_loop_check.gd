extends SceneTree
# Headless validation for CHGameLoop (the interactive table loop, M6).
#
#   1. Determinism: two fresh loops, same seed, same (optimal) policy ->
#      identical per-hand net sequence (driving stops when the session ends).
#   2. Bankroll consistency: while the session is active, bankroll equals the
#      starting stake plus the rounded sum of every hand's net P&L. A bust ends
#      as "bust" and resets the stake; and optimal play keeps the Discipline
#      meter pinned at its ceiling (recovery only, no penalty).
#   3. Card conservation: at the end of every settled hand, the number of cards
#      marked `seen` equals the number dealt from the shoe (no card is counted
#      twice or left uncounted).
#   4. A deliberately suboptimal decision costs Discipline.
#   5. Grading is config-gated: with grade_decisions off, suboptimal play does
#      not move the Discipline meter (the teaching table is penalty-free).
#   6. Bet ramp: optimal_bet_units() maps the true count to the 1/2/4/6 steps.
#   7. Surrender settles as a half-loss (-0.5x the bet).
#   8. Session decision record: optimal play records all-optimal; a forced
#      suboptimal hit drops the ratio.
#   9. Insurance loss on the normal (non-BJ) path: the side-bet is forfeited and
#      counted in wagered.
#   10. H17 dealer soft-17: the same rigged hand under S17 vs H17 flips the
#       outcome.
#   11. Natural win payout flows through config (3:2 and 6:5).
#   12. Split-ace settlement: two one-card aces, wagered = 2x base bet.
#   13. Push settlement: equal totals net zero, wagered = base bet.
#   14. Late-surrender timing: offered on a two-card 16v10, withdrawn after a hit.
#   15. Early surrender: 15v9 surrenders for a half-loss; the late-mode control
#       takes the full loss instead.
#   16. Early-surrender optimal consistency: a non-chart hand vs a natural offers
#       [surrender, stand]; the optimal is surrender, settling at -0.5.
#   17. DAS loop gate: a split-hand 11 on a no-DAS table offers no double, the
#       optimal degrades to hit, and no double is applied (wagered stays 2x base).
#   18. place_bet clamping: out-of-range bets clamp to [1, MAX_BET_UNITS] and the
#       clamped value is what is committed and graded.
#   19. Heat tell triggers: a big bet on a hot count and taking insurance on a hot
#       count add heat; the controls (small bet / cold count / decline) add none.
#   20. Deviation tell: making an I18 deviation at a hot count adds the deviation
#       tell; making no deviation leaves no residue.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906
const HANDS := 1000


var _failures: Array[String] = []


func _init() -> void:
	_check_determinism()
	_check_bankroll_and_optimal_discipline()
	_check_card_conservation()
	_check_suboptimal_costs_discipline()
	_check_grading_gated_by_config()
	_check_bet_ramp()
	_check_surrender_settlement()
	_check_session_decision_record()
	_check_insurance_loss_normal_path()
	_check_h17_dealer_soft17()
	_check_natural_win_payout()
	_check_dealer_natural_hand_completeness()
	_check_split_ace_settlement()
	_check_push_settlement()
	_check_late_surrender_timing()
	_check_early_surrender()
	_check_early_surrender_optimal_consistency()
	_check_das_loop_gate()
	_check_place_bet_clamping()
	_check_heat_tell_triggers()
	_check_deviation_tell()
	_check_count_only_heat_suppressed()
	_check_npc_players()
	_cleanup_save()

	if _failures.is_empty():
		print("game_loop_check: ALL PASS (%d hands x optimal + invariants)" % HANDS)
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("game_loop_check: %d failure(s)" % _failures.size())
		quit(1)


func _make_config() -> CHTableConfig:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.blackjack_payout = 1.5
	c.allows_split = true
	c.max_split_hands = 4
	c.split_aces_one_card_only = true
	c.allows_double_after_split = true
	c.allows_insurance = true
	c.allows_surrender = false
	# This test exercises Discipline behavior, so opt into grading (the tier
	# ladder leaves these off for the T1 teaching table).
	c.grade_decisions = true
	c.grade_bet_ramp = true
	return c


# Drives hands with the optimal-action policy until N hands are played or the
# session ends (bust). Appends only the nets of hands that actually ran.
func _drive_optimal(n: int, out_nets: Array[float]) -> CHGameState:
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var discipline := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(_make_config(), state, discipline, SEED)
	for i in n:
		if not loop.begin_hand():
			break
		while not loop.is_idle():
			loop.apply_action(loop.optimal_action())
		out_nets.append(loop.last_net())
	return state


func _check_determinism() -> void:
	var a: Array[float] = []
	_drive_optimal(HANDS, a)
	var b: Array[float] = []
	_drive_optimal(HANDS, b)
	if a.size() != b.size():
		_failures.append("determinism: net count %d vs %d" % [a.size(), b.size()])
		return
	var same := true
	for i in a.size():
		if a[i] != b[i]:
			same = false
			break
	if not same:
		_failures.append("determinism: net sequences diverged")
	else:
		print("PASS  determinism: %d hands, identical net sequence" % a.size())


# Bankroll invariant checked hand-by-hand; bust case handled explicitly.
func _check_bankroll_and_optimal_discipline() -> void:
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var discipline := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(_make_config(), state, discipline, SEED)
	var expected_bankroll: int = CHGameState.SESSION_START_BANKROLL
	var hands_played := 0
	for i in HANDS:
		if not loop.begin_hand():
			break
		while not loop.is_idle():
			loop.apply_action(loop.optimal_action())
		hands_played += 1
		if not state.is_session_active():
			# Session just ended (bust — target is unreachable at 999999).
			var bust_ok: bool = state.last_end_reason == "bust" and state.current_bankroll == CHGameState.SESSION_START_BANKROLL
			if not bust_ok:
				_failures.append("bust: reason=%s bankroll=%d (expected reset to %d)" % [state.last_end_reason, state.current_bankroll, CHGameState.SESSION_START_BANKROLL])
			break
		expected_bankroll += int(roundf(loop.last_net()))
		if state.current_bankroll != expected_bankroll:
			_failures.append("bankroll: hand=%d state=%d expected=%d" % [hands_played, state.current_bankroll, expected_bankroll])
			break
	if absf(discipline.discipline - 100.0) < 0.001:
		print("PASS  bankroll + discipline: %d hands, discipline pinned at 100" % hands_played)
	else:
		_failures.append("optimal-penalty: discipline=%.3f expected 100.0" % discipline.discipline)


func _check_card_conservation() -> void:
	# Target mode (huge goal): the session never auto-completes on shoe count,
	# so the full 200-hand conservation sweep runs. (Practice mode would end the
	# session after practice_shoes_required shoes now that on_shoe_finished is
	# wired into the loop.)
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var discipline := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(_make_config(), state, discipline, SEED)
	var worst_violation := 0
	for i in 200:
		if not loop.begin_hand():
			break
		while not loop.is_idle():
			loop.apply_action(loop.optimal_action())
		# At rest, every card dealt this far must be revealed exactly once.
		var dealt: int = loop.get_shoe().cards_dealt()
		var dealt_seen := 0
		for j in dealt:
			if loop.get_shoe().deck[j].seen:
				dealt_seen += 1
		if dealt_seen != dealt:
			worst_violation = max(worst_violation, dealt - dealt_seen)
	if worst_violation == 0:
		print("PASS  card conservation: every dealt card counted exactly once")
	else:
		_failures.append("card conservation: %d dealt card(s) left uncounted" % worst_violation)


func _check_suboptimal_costs_discipline() -> void:
	# Target mode (huge goal): avoids the practice-mode shoe-completion end
	# (now wired into the loop) and keeps the suboptimal-play sweep self-contained.
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var discipline := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(_make_config(), state, discipline, SEED)
	# Always hit, even when the optimal play is stand/double/surrender.
	for i in 20:
		if not loop.begin_hand():
			break
		var guard := 0
		while not loop.is_idle() and guard < 32:
			var act: String = "hit"
			if not loop.available_actions().has("hit"):
				act = loop.available_actions()[0]
			loop.apply_action(act)
			guard += 1
	var dropped: bool = discipline.discipline < 100.0
	if dropped:
		print("PASS  suboptimal play costs discipline (%.1f < 100)" % discipline.discipline)
	else:
		_failures.append("suboptimal: discipline stayed 100 despite forced hits")


# M21: grading is a tier-ladder lever. With grade_decisions/grade_bet_ramp OFF
# (the T1 teaching table default) suboptimal play must NOT move Discipline;
# with them ON it must. This pins the gate so a future config default flip
# is caught.
func _check_grading_gated_by_config() -> void:
	var on_cfg := _make_config()  # grade flags enabled
	var off_cfg := _make_config()
	off_cfg.grade_decisions = false
	off_cfg.grade_bet_ramp = false

	var disc_on := CHDisciplineSystem.new()
	var state_on := CHGameState.new()
	state_on.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop_on := CHGameLoop.new(on_cfg, state_on, disc_on, SEED)

	var disc_off := CHDisciplineSystem.new()
	var state_off := CHGameState.new()
	state_off.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop_off := CHGameLoop.new(off_cfg, state_off, disc_off, SEED)

	# Always hit (suboptimal when optimal is stand/double/surrender) on both loops.
	for lp in [loop_on, loop_off]:
		var hands := 0
		while hands < 20:
			if not lp.begin_hand():
				break
			hands += 1
			var guard := 0
			while not lp.is_idle() and guard < 32:
				var act: String = "hit"
				if not lp.available_actions().has("hit"):
					act = lp.available_actions()[0]
				lp.apply_action(act)
				guard += 1

	var on_ok: bool = disc_on.discipline < 100.0
	var off_ok: bool = disc_off.discipline == 100.0
	if on_ok:
		print("PASS  grading ON: suboptimal play drops discipline (%.1f < 100)" % disc_on.discipline)
	else:
		_failures.append("grading ON: discipline stayed 100 despite forced hits (expected < 100)")
	if off_ok:
		print("PASS  grading OFF: suboptimal play keeps discipline at 100 (%.1f)" % disc_off.discipline)
	else:
		_failures.append("grading OFF: discipline dropped to %.1f despite grade flags off" % disc_off.discipline)


# M28: surrender P&L — the one settlement path no tool exercised. The sim runs
# with allows_surrender=false, so the loop's `profit -= 0.5 * b` half-loss was
# never driven. Rig a two-card 16 vs 10 (surrenderable, no natural, no split)
# and confirm surrender settles as exactly a half-loss and that the engine's
# optimal play is itself "surrender".
func _check_surrender_settlement() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.allows_surrender = true
	c.late_surrender_only = true
	c.allows_insurance = false
	c.allows_split = true
	c.allows_double = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)

	# Rig the opening deal: upcard 10, hole 2 (dealer 12, no BJ), player 9+7 = 16 hard.
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	shoe.deck.append(CHCard.new("H", 10))  # upcard
	shoe.deck.append(CHCard.new("S", 2))   # hole
	shoe.deck.append(CHCard.new("S", 9))   # p1
	shoe.deck.append(CHCard.new("H", 7))   # p2
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("S", 2))
	shoe.deal_index = 0

	if not loop.begin_hand():
		_failures.append("surrender: begin_hand failed")
		return
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("surrender: expected HAND phase, got %s" % loop.phase())
		return
	if not loop.available_actions().has(CHGameLoop.ACT_SURRENDER):
		_failures.append("surrender not offered on a two-card 16 vs 10")
		return
	var opt := loop.optimal_action()
	if opt != CHGameLoop.ACT_SURRENDER:
		_failures.append("surrender: optimal expected surrender, got %s" % opt)
		return
	loop.apply_action(CHGameLoop.ACT_SURRENDER)
	if not loop.is_idle():
		_failures.append("surrender: not idle after settle, phase=%s" % loop.phase())
		return
	var expected := -0.5 * 1.0  # half-loss on a 1-unit bet
	if absf(loop.last_net() - expected) < 1e-6:
		print("PASS  surrender settles as a half-loss (net %.1f)" % loop.last_net())
	else:
		_failures.append("surrender P&L: expected %.1f, got %.2f" % [expected, loop.last_net()])


# M29: session decision record. record_decision() counts every play decision
# regardless of the grade_decisions tier flag (recording is a process
# read-out, not a scoring lever), so the debrief's "Decisions" line works on
# the T1 teaching table too. Optimal play must score M == N; a forced
# suboptimal hit must score M < N.
func _check_session_decision_record() -> void:
	# Part 1: optimal play with grading off -> every decision is optimal.
	var c_off := _make_config()
	c_off.grade_decisions = false
	c_off.grade_bet_ramp = false
	var disc_off := CHDisciplineSystem.new()
	var state_off := CHGameState.new()
	state_off.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop_off := CHGameLoop.new(c_off, state_off, disc_off, SEED)
	var played := 0
	for i in 5:
		if not loop_off.begin_hand():
			break
		played += 1
		var guard := 0
		while not loop_off.is_idle() and guard < 64:
			loop_off.apply_action(loop_off.optimal_action())
			guard += 1
	if disc_off.session_decisions <= 0:
		_failures.append("decision-record: no decisions recorded with grading off, got %d" % disc_off.session_decisions)
	if disc_off.session_optimal != disc_off.session_decisions:
		_failures.append("decision-record: optimal play should record all-optimal, got %d/%d" % [disc_off.session_optimal, disc_off.session_decisions])
	if played > 0 and disc_off.session_decisions > 0 and disc_off.session_optimal == disc_off.session_decisions:
		print("PASS  session decision record: optimal play %d/%d, grading off" % [disc_off.session_optimal, disc_off.session_decisions])

	# Part 2: force a suboptimal hit (20 vs K: optimal is stand) -> M < N.
	var c := _make_config()
	c.grade_decisions = false
	c.grade_bet_ramp = false
	c.allows_double = false
	var disc := CHDisciplineSystem.new()
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, disc, SEED)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	shoe.deck.append(CHCard.new("H", 13))  # upcard K
	shoe.deck.append(CHCard.new("S", 2))   # hole -> dealer 15, no BJ
	shoe.deck.append(CHCard.new("S", 9))   # p1
	shoe.deck.append(CHCard.new("H", 11))  # p2 J -> 20 hard, not a pair
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("S", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("decision-record: begin_hand failed")
		return
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("decision-record: expected HAND phase, got %s" % loop.phase())
		return
	if loop.optimal_action() != CHGameLoop.ACT_STAND:
		_failures.append("decision-record: expected optimal stand on 20 vs K, got %s" % loop.optimal_action())
		return
	loop.apply_action(CHGameLoop.ACT_HIT)  # suboptimal
	if disc.session_optimal < disc.session_decisions:
		print("PASS  session decision record: forced suboptimal hit drops ratio to %d/%d" % [disc.session_optimal, disc.session_decisions])
	else:
		_failures.append("decision-record: suboptimal hit should reduce optimal ratio, got %d/%d" % [disc.session_optimal, disc.session_decisions])


# M31: insurance forfeited in a normal (non-natural) hand. The M24 loop test
# drives only the dealer-BJ branch (insurance wins via _settle_natural). This
# pins the other side: insurance taken on an Ace upcard where the dealer does
# NOT hold a natural, so the round plays out to _play_dealer_and_settle and the
# insurance side-bet is forfeited there (GameLoop.gd: profit -= _insurance_bet,
# wagered += _insurance_bet). The main hand is played identically in both runs
# (same seed, same optimal policy), so the ONLY P&L difference is the side-bet.
func _check_insurance_loss_normal_path() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.allows_insurance = true
	c.allows_surrender = false
	c.allows_double = false  # keep the main bet at base so wagered is exact
	c.grade_decisions = false
	c.grade_bet_ramp = false

	# upcard Ace, hole 7 -> dealer 18, no natural. player 9+8 = 17 hard, stands.
	var take_net: float = _drive_insurance_normal(c, true, SEED)
	var take_wagered: float = _take_wagered
	var decline_net: float = _drive_insurance_normal(c, false, SEED)
	var decline_wagered: float = _take_wagered

	if absf(take_wagered - 2.0) < 1e-6:
		print("PASS  insurance normal path: wagered counts the side-bet (%.1f)" % take_wagered)
	else:
		_failures.append("insurance normal path: take-wagered expected 2.0, got %.2f" % take_wagered)
	if absf(decline_wagered - 1.0) < 1e-6:
		print("PASS  insurance normal path: no side-bet when declined (%.1f)" % decline_wagered)
	else:
		_failures.append("insurance normal path: decline-wagered expected 1.0, got %.2f" % decline_wagered)
	# The main hand is identical in both runs, so the net difference is exactly
	# the forfeited insurance stake.
	if absf((take_net - decline_net) - (-1.0)) < 1e-6:
		print("PASS  insurance normal path: side-bet forfeited when no dealer BJ (delta %.1f)" % (take_net - decline_net))
	else:
		_failures.append("insurance normal path: take-decline delta expected -1.0, got %.2f (take=%.2f decline=%.2f)" % [take_net - decline_net, take_net, decline_net])


# Drives one loop through a rigged Ace-upcard / no-dealer-BJ hand, optionally
# taking insurance, and returns the settled net. _take_wagered holds the
# matching last_wagered() so the caller can assert on the stake too.
var _take_wagered: float = 0.0


func _drive_insurance_normal(c: CHTableConfig, take_insurance: bool, seed: int) -> float:
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), seed)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	shoe.deck.append(CHCard.new("H", 14))  # upcard Ace (insurance offered)
	shoe.deck.append(CHCard.new("S", 7))   # hole -> dealer 18, no natural
	shoe.deck.append(CHCard.new("S", 9))   # p1
	shoe.deck.append(CHCard.new("H", 8))   # p2 -> 17 hard, not a pair
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("S", 2))
	shoe.deal_index = 0

	if not loop.begin_hand():
		_failures.append("insurance normal path: begin_hand failed")
		return -999.0
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_INSURANCE:
		_failures.append("insurance normal path: expected INSURANCE phase, got %s" % loop.phase())
		return -999.0
	if take_insurance:
		loop.apply_action(CHGameLoop.ACT_INS_TAKE)
	else:
		loop.apply_action(CHGameLoop.ACT_INS_DECLINE)
	var guard := 0
	while not loop.is_idle() and guard < 32:
		loop.apply_action(loop.optimal_action())
		guard += 1
	if not loop.is_idle():
		_failures.append("insurance normal path: hand did not settle, phase=%s" % loop.phase())
		return -999.0
	_take_wagered = loop.last_wagered()
	return loop.last_net()


# M32: H17 dealer soft-17 loop coverage. `GameLoop._dealer_should_hit`
# (GameLoop.gd:739-745) hits a soft 17 only when `dealer_hits_soft_17` is true,
# but no tool ever drove the loop with that flag on (every other config and the
# sim use S17). The strategy side (the player's H17 basic-strategy adjustment)
# is covered by `deviation_check`; this pins the dealer-side play.
#
# Same rigged hand under both rules: upcard 6 + hole Ace = soft 17, player hard
# 18 (stand; not an I18 deviation target). Under S17 the dealer stands at 17
# and the player's 18 wins (+1). Under H17 the dealer draws (rigged 3) to 20
# and the player loses (-1). The exact net in each run proves the dealer did
# (or did not) hit.
func _check_h17_dealer_soft17() -> void:
	var net_s17: float = _drive_soft17_dealer(false, SEED)
	var net_h17: float = _drive_soft17_dealer(true, SEED)
	if absf(net_s17 - 1.0) < 1e-6:
		print("PASS  H17: S17 dealer stands on soft 17, player 18 wins (net +%.1f)" % net_s17)
	else:
		_failures.append("H17 S17: expected +1.0 (dealer stands soft 17, 18 wins), got %.2f" % net_s17)
	if absf(net_h17 - (-1.0)) < 1e-6:
		print("PASS  H17: H17 dealer hits soft 17 to 20, player 18 loses (net %.1f)" % net_h17)
	else:
		_failures.append("H17 H17: expected -1.0 (dealer hits to 20, beats 18), got %.2f" % net_h17)


# Drives one loop through the rigged soft-17-dealer hand and returns the settled
# net P&L. `h17` selects the dealer rule; everything else is held fixed so the
# only variable is whether the dealer hits its soft 17.
func _drive_soft17_dealer(h17: bool, seed: int) -> float:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = h17
	c.allows_surrender = false
	c.allows_split = false
	c.allows_double = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), seed)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	# [0] up 6, [1] hole Ace -> soft 17; [2] p1 10, [3] p2 8 -> hard 18 (stand).
	# [4] the dealer's H17 hit card: 3 -> dealer 20.
	shoe.deck.append(CHCard.new("H", 6))
	shoe.deck.append(CHCard.new("S", 14))
	shoe.deck.append(CHCard.new("S", 10))
	shoe.deck.append(CHCard.new("H", 8))
	shoe.deck.append(CHCard.new("S", 3))
	for i in range(total - 5):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("H17: begin_hand failed")
		return -999.0
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("H17: expected HAND phase, got %s" % loop.phase())
		return -999.0
	var guard := 0
	while not loop.is_idle() and guard < 32:
		loop.apply_action(loop.optimal_action())
		guard += 1
	if not loop.is_idle():
		_failures.append("H17: hand did not settle, phase=%s" % loop.phase())
		return -999.0
	return loop.last_net()


# M34: player natural (blackjack) win + blackjack_payout config flow. M24 pinned
# the dealer-BJ / insurance side of `_settle_natural`; this pins the win side —
# `main += bet * blackjack_payout` — the branch no dedicated loop test asserted.
# A two-card player natural vs a non-Ace, non-10 upcard (no insurance, no dealer
# natural) settles in `_settle_natural` immediately after the bet. The same rigged
# hand is settled at two payout ratios to prove the config value flows through.
func _check_natural_win_payout() -> void:
	var net_32: float = _drive_natural_win(1.5, SEED)
	var net_65: float = _drive_natural_win(1.2, SEED)
	if absf(net_32 - 1.5) < 1e-6:
		print("PASS  natural win: 3:2 payout pays +%.1f on a winning blackjack" % net_32)
	else:
		_failures.append("natural win 3:2: expected +1.5, got %.2f" % net_32)
	if absf(net_65 - 1.2) < 1e-6:
		print("PASS  natural win: 6:5 payout pays +%.1f (config flows through)" % net_65)
	else:
		_failures.append("natural win 6:5: expected +1.2, got %.2f (blackjack_payout not read?)" % net_65)


# Drives one loop through a rigged player-natural hand (no dealer natural, no
# insurance) at the given blackjack_payout and returns the settled net P&L.
func _drive_natural_win(payout: float, seed: int) -> float:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.blackjack_payout = payout
	c.allows_surrender = false
	c.allows_split = false
	c.allows_double = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), seed)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	# [0] up 7 (no insurance, no dealer BJ), [1] hole 5 (dealer 12),
	# [2] p1 Ace, [3] p2 10 -> two-card player blackjack.
	shoe.deck.append(CHCard.new("H", 7))
	shoe.deck.append(CHCard.new("S", 5))
	shoe.deck.append(CHCard.new("S", 14))
	shoe.deck.append(CHCard.new("H", 10))
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("natural win: begin_hand failed")
		return -999.0
	loop.place_bet(1, false)
	if not loop.is_idle():
		_failures.append("natural win: hand did not settle, phase=%s" % loop.phase())
		return -999.0
	return loop.last_net()


# M106: dealer-natural hand completeness. On the natural-settle path
# (_after_insurance -> _settle_natural) the hole is revealed but historically
# never appended to the live _dealer hand — the append only happened in
# _play_dealer_and_settle, which a natural skips. Result: the UI rendered the
# dealer as a lone "10" (no face-down back, since the hole reads as revealed)
# and _settle_opponent compared the rival against the upcard alone instead of
# the two-card 21. This pins the post-settle dealer hand: a dealer natural must
# present as the full two-card hand totaling 21.
func _check_dealer_natural_hand_completeness() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.blackjack_payout = 1.5
	c.allows_split = false
	c.allows_double = false
	c.allows_surrender = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	# [0] up 10 of diamonds, [1] hole Ace -> dealer natural (21).
	# [2] p1 King of diamonds, [3] p2 8 of diamonds -> 19, not a natural.
	shoe.deck.append(CHCard.new("D", 10))
	shoe.deck.append(CHCard.new("S", 14))
	shoe.deck.append(CHCard.new("D", 13))
	shoe.deck.append(CHCard.new("D", 8))
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("dealer-natural completeness: begin_hand failed")
		return
	loop.place_bet(1, false)
	# A dealer natural settles the round immediately (no insurance on a 10 upcard).
	if not loop.is_idle():
		_failures.append("dealer-natural completeness: hand did not settle, phase=%s" % loop.phase())
		return
	if absf(loop.last_net() - (-1.0)) >= 1e-6:
		_failures.append("dealer-natural completeness: expected the non-natural spot to lose -1.0, got %.2f" % loop.last_net())
	var dhand: CHHand = loop.dealer_hand()
	if dhand.cards.size() != 2:
		_failures.append("dealer-natural completeness: dealer hand should hold the two-card natural, got %d card(s)" % dhand.cards.size())
		return
	if not dhand.is_blackjack():
		_failures.append("dealer-natural completeness: settled dealer hand should be a blackjack (10 + Ace)")
		return
	if dhand.total() != 21:
		_failures.append("dealer-natural completeness: dealer natural total should be 21, got %d" % dhand.total())
		return
	print("PASS  dealer-natural hand completeness: natural settles as a full two-card 21")


# M35: split-ace settlement. `multi_hand_check` asserts split aces produce two
# one-card `split_ace` hands but never settles them through the loop, so the
# P&L of two split-ace hands (each auto-stands after its single card) was not
# pinned. Rig A+A vs 10/8: split aces get exactly one card each (soft 17), both
# auto-stand, and both lose to the dealer's 18. Expected net -2.0, wagered 2.0.
func _check_split_ace_settlement() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.allows_split = true
	c.max_split_hands = 4
	c.split_aces_one_card_only = true
	c.allows_double = false
	c.allows_surrender = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	# [0] up 10, [1] hole 8 -> dealer 18, no BJ.
	# [2] p1 Ace, [3] p2 Ace -> A+A pair (split).
	# [4] one-card for hand A = 6 -> soft 17.
	# [5] one-card for hand B = 6 -> soft 17.
	shoe.deck.append(CHCard.new("H", 10))
	shoe.deck.append(CHCard.new("S", 8))
	shoe.deck.append(CHCard.new("S", 14))
	shoe.deck.append(CHCard.new("H", 14))
	shoe.deck.append(CHCard.new("C", 6))
	shoe.deck.append(CHCard.new("D", 6))
	for i in range(total - 6):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("split-ace: begin_hand failed")
		return
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_PRESPLIT:
		_failures.append("split-ace: expected PRESPLIT phase, got %s" % loop.phase())
		return
	if loop.optimal_action() != CHGameLoop.ACT_SPLIT:
		_failures.append("split-ace: optimal expected split, got %s" % loop.optimal_action())
		return
	loop.apply_action(CHGameLoop.ACT_SPLIT)
	if not loop.is_idle():
		_failures.append("split-ace: not settled after split, phase=%s" % loop.phase())
		return
	# Wagered = 2.0 proves two hands each bet 1.0 (split produced two hands).
	# Net = -2.0 proves both settled as losses (one-card aces at soft 17 lose to 18).
	var expected_net := -2.0
	var expected_wagered := 2.0
	if absf(loop.last_wagered() - expected_wagered) < 1e-6:
		print("PASS  split-ace settlement: wagered %.1f confirms two split hands" % loop.last_wagered())
	else:
		_failures.append("split-ace: wagered expected %.1f, got %.2f" % [expected_wagered, loop.last_wagered()])
	if absf(loop.last_net() - expected_net) < 1e-6:
		print("PASS  split-ace settlement: both one-card aces lose to dealer 18 (net %.1f)" % loop.last_net())
	else:
		_failures.append("split-ace P&L: expected %.1f, got %.2f" % [expected_net, loop.last_net()])


# M36: push settlement. `_play_dealer_and_settle`'s `# else push` branch (no
# profit change) had no dedicated pin. Rig player 18 vs a dealer that draws to
# 18: the round must settle as a push with net 0.0 and the full bet wagered.
func _check_push_settlement() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.allows_split = true
	c.allows_double = true
	c.allows_surrender = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	# [0] up 5, [1] hole 8 -> dealer 13, will hit.
	# [2] p1 10, [3] p2 8 -> player 18 hard (not a pair, stand).
	# [4] dealer draw 5 -> dealer 18.
	shoe.deck.append(CHCard.new("H", 5))
	shoe.deck.append(CHCard.new("S", 8))
	shoe.deck.append(CHCard.new("S", 10))
	shoe.deck.append(CHCard.new("H", 8))
	shoe.deck.append(CHCard.new("C", 5))
	for i in range(total - 5):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("push: begin_hand failed")
		return
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("push: expected HAND phase, got %s" % loop.phase())
		return
	if loop.optimal_action() != CHGameLoop.ACT_STAND:
		_failures.append("push: optimal expected stand on 18 vs 5, got %s" % loop.optimal_action())
		return
	loop.apply_action(CHGameLoop.ACT_STAND)
	if not loop.is_idle():
		_failures.append("push: not settled after stand, phase=%s" % loop.phase())
		return
	if absf(loop.last_net() - 0.0) < 1e-6:
		print("PASS  push settlement: 18 vs 18 settles as a push (net 0.0, wagered %.1f)" % loop.last_wagered())
	else:
		_failures.append("push P&L: expected 0.0 (push), got %.2f" % loop.last_net())


# M37: late-surrender timing. `CHTableConfig.late_surrender_only` is set on T4-T6
# and previously read as a no-op because the loop already only permits surrender
# on a fresh two-card hand. This pins that invariant explicitly: a surrenderable
# two-card 16 vs 10 offers surrender and optimal play is surrender; after the
# player draws a third card the hand is no longer surrenderable, which is exactly
# the late-surrender (first-action-only) timing the flag claims to describe.
func _check_late_surrender_timing() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.allows_surrender = true
	c.late_surrender_only = true
	c.allows_split = false
	c.allows_double = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	# [0] up 10, [1] hole 8 -> dealer 18. [2] p1 9, [3] p2 7 -> 16 hard.
	# [4] hit card 2 -> 18 (three cards, not bust).
	shoe.deck.append(CHCard.new("H", 10))
	shoe.deck.append(CHCard.new("S", 8))
	shoe.deck.append(CHCard.new("S", 9))
	shoe.deck.append(CHCard.new("H", 7))
	shoe.deck.append(CHCard.new("C", 2))
	for i in range(total - 5):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("late-surrender: begin_hand failed")
		return
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("late-surrender: expected HAND phase, got %s" % loop.phase())
		return
	# Fresh two-card hand: surrender must be offered and optimal.
	var fresh_actions: Array[String] = loop.available_actions()
	if not fresh_actions.has(CHGameLoop.ACT_SURRENDER):
		_failures.append("late-surrender: two-card 16 vs 10 should offer surrender, got %s" % fresh_actions)
		return
	if loop.optimal_action() != CHGameLoop.ACT_SURRENDER:
		_failures.append("late-surrender: optimal expected surrender on fresh 16 vs 10, got %s" % loop.optimal_action())
		return
	# Draw a third card: hand is no longer a fresh two-card hand -> no surrender.
	loop.apply_action(CHGameLoop.ACT_HIT)
	var post_actions: Array[String] = loop.available_actions()
	if post_actions.has(CHGameLoop.ACT_SURRENDER):
		_failures.append("late-surrender: three-card hand should not offer surrender, got %s" % post_actions)
		return
	if loop.phase() == CHGameLoop.PHASE_HAND and not post_actions.has(CHGameLoop.ACT_SURRENDER):
		print("PASS  late-surrender timing: offered on two-card 16v10, withdrawn after a hit")
	else:
		_failures.append("late-surrender: unexpected phase after hit, phase=%s actions=%s" % [loop.phase(), post_actions])


# M42: early/late surrender. With `late_surrender_only` false (early surrender)
# the engine's +EV chart widens (15v9, 14v10, 13v10 become surrenders) and the
# loop offers a surrender decision against a dealer natural — the player gives
# up before the dealer peeks and loses only half, instead of the full loss a
# late-surrender table takes on a natural. Pin both:
#   (1) the chart difference on a natural-free hand (15v9: surrender early, not
#       late), and
#   (2) the sub-phase settlement against a natural (14v10, dealer A+10: early
#       offers [surrender, stand] and settles at -0.5; late auto-settles the
#       natural at -1.0 with no surrender offered).
func _check_early_surrender() -> void:
	# (1) Chart differential on a natural-free hand: 15 hard vs up 9.
	var e1 := _surrender_loop(true, 9, 8, 8, 7)   # early; dealer 9+8=17, no natural
	if e1.phase() != CHGameLoop.PHASE_HAND or e1.optimal_action() != CHGameLoop.ACT_SURRENDER:
		_failures.append("early-surrender chart: 15v9 should be a surrender in early mode (phase=%s opt=%s)" % [e1.phase(), e1.optimal_action()])
	var l1 := _surrender_loop(false, 9, 8, 8, 7)  # late; same hand
	if l1.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("early-surrender chart: late 15v9 should be in HAND phase, got %s" % l1.phase())
	elif l1.optimal_action() == CHGameLoop.ACT_SURRENDER:
		_failures.append("early-surrender chart: 15v9 must NOT be a surrender in late mode")
	else:
		print("PASS  early-surrender chart: 15v9 surrenders early, not late")

	# Settle the early case: surrender is offered and yields a half-loss.
	if e1.phase() == CHGameLoop.PHASE_HAND and e1.optimal_action() == CHGameLoop.ACT_SURRENDER:
		e1.apply_action(CHGameLoop.ACT_SURRENDER)
		if not e1.is_idle() or absf(e1.last_net() - (-0.5)) >= 1e-6:
			_failures.append("early-surrender chart: 15v9 early surrender should settle at -0.5, got net=%.2f idle=%s" % [e1.last_net(), e1.is_idle()])
		else:
			print("PASS  early-surrender chart: 15v9 early surrender settles at -0.5")

	# (2) Sub-phase against a dealer natural: 14 hard vs up 10, hole Ace.
	var e2 := _surrender_loop(true, 10, 14, 8, 6)  # early; dealer A+10 = natural
	if e2.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("early-surrender natural: expected HAND sub-phase, got %s" % e2.phase())
		return
	var e2_actions: Array[String] = e2.available_actions()
	if e2_actions.size() != 2 or not e2_actions.has(CHGameLoop.ACT_SURRENDER) or not e2_actions.has(CHGameLoop.ACT_STAND):
		_failures.append("early-surrender natural: expected [surrender, stand], got %s" % e2_actions)
		return
	if e2.optimal_action() != CHGameLoop.ACT_SURRENDER:
		_failures.append("early-surrender natural: 14v10 vs a natural should be a surrender, got %s" % e2.optimal_action())
		return
	e2.apply_action(CHGameLoop.ACT_SURRENDER)
	if not e2.is_idle() or absf(e2.last_net() - (-0.5)) >= 1e-6:
		_failures.append("early-surrender natural: surrender should settle at -0.5, got net=%.2f idle=%s" % [e2.last_net(), e2.is_idle()])
	else:
		print("PASS  early-surrender natural: 14v10 vs A surrenders for a half-loss (-0.5)")

	# Control: the same natural on a late-surrender table auto-settles the
	# natural at a full loss with no surrender decision offered.
	var l2 := _surrender_loop(false, 10, 14, 8, 6)  # late; dealer A+10 = natural
	if not l2.is_idle() or absf(l2.last_net() - (-1.0)) >= 1e-6:
		_failures.append("early-surrender natural control: late 14v10 vs A should auto-settle the natural at -1.0 (idle=%s net=%.2f)" % [l2.is_idle(), l2.last_net()])
	else:
		print("PASS  early-surrender natural control: late mode takes the full -1.0 loss, no surrender offered")


# M49: the early-surrender sub-phase must keep optimal_action() inside its
# restricted [surrender, stand] action set. A hand the surrender chart does NOT
# recommend (here 12 hard vs a 10 upcard) still faces a dealer natural; against
# a known natural the half-loss strictly dominates standing or hitting (both
# lose the full bet), so the optimal must be "surrender" — never the "hit"
# (or "double") that the raw engine would return and the sub-phase does not
# offer.
func _check_early_surrender_optimal_consistency() -> void:
	# up 10, hole Ace (dealer natural), player 7+5 = 12 (not a surrender-chart
	# hand, so the engine's raw best play is "hit").
	var e := _surrender_loop(true, 10, 14, 7, 5)
	if e.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("early-surrender consistency: expected HAND sub-phase, got %s" % e.phase())
		return
	var actions: Array[String] = e.available_actions()
	if actions.size() != 2 or not actions.has(CHGameLoop.ACT_SURRENDER) or not actions.has(CHGameLoop.ACT_STAND):
		_failures.append("early-surrender consistency: expected [surrender, stand], got %s" % actions)
		return
	var opt := e.optimal_action()
	if opt != CHGameLoop.ACT_SURRENDER:
		_failures.append("early-surrender consistency: optimal must be 'surrender' in the sub-phase, got '%s' (leaks an unoffered action)" % opt)
		return
	e.apply_action(CHGameLoop.ACT_SURRENDER)
	if not e.is_idle() or absf(e.last_net() - (-0.5)) >= 1e-6:
		_failures.append("early-surrender consistency: 12 vs natural surrender should settle -0.5, got net=%.2f idle=%s" % [e.last_net(), e.is_idle()])
	else:
		print("PASS  early-surrender consistency: non-chart 12 vs natural -> [surrender, stand], optimal surrender, settles -0.5")


# M52: loop-level double-after-split gate. M51 pinned the engine's
# _enforce_double_legality; this pins the LOOP's own _can_double gate
# (GameLoop.gd:401), which drives available_actions(), optimal_action()
# degradation, and _apply_hand's bet-doubling. A split sub-hand that is a
# two-card "double" candidate (hard 11) must not be offered "double" on a no-DAS
# table, optimal must degrade to "hit", and no double may be applied (wagered
# stays 2 x base bet). This catches a regression in the loop gate that the
# engine-level spot_check would not.
func _check_das_loop_gate() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.allows_split = true
	c.max_split_hands = 4
	c.split_aces_one_card_only = true
	c.allows_double = true
	c.allows_double_after_split = false  # no-DAS table
	c.allows_surrender = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	# up=7, hole=10, s1=7, s2=7 (pair -> split vs up 7), follow1=4 (sub-hand A
	# = [7,4] = hard 11, a double candidate), follow2=2. Filler: rank-2.
	for card in [["S", 7], ["H", 10], ["S", 7], ["H", 7], ["S", 4], ["H", 2]]:
		shoe.deck.append(CHCard.new(card[0], int(card[1])))
	for i in range(total - 6):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0

	if not loop.begin_hand():
		_failures.append("das-gate: begin_hand failed")
		return
	loop.place_bet(1)
	if loop.phase() != CHGameLoop.PHASE_PRESPLIT:
		_failures.append("das-gate: expected PRESPLIT after 7,7 vs 7, got %s" % loop.phase())
		return
	loop.apply_action(CHGameLoop.ACT_SPLIT)
	if loop.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("das-gate: expected HAND after split, got %s" % loop.phase())
		return
	# Sub-hand A ([7,4]=11, a split hand) is now active. On a no-DAS table the
	# loop must not offer double and must degrade the optimal play to hit.
	var actions: Array[String] = loop.available_actions()
	if actions.has(CHGameLoop.ACT_DOUBLE):
		_failures.append("das-gate: loop offered 'double' for a split hand on a no-DAS table: %s" % actions)
	if loop.optimal_action() != CHGameLoop.ACT_HIT:
		_failures.append("das-gate: optimal for split-hand 11 on no-DAS should be 'hit', got '%s'" % loop.optimal_action())
	# Settle the round under the autopilot; no double may have been applied, so
	# the wagered total stays 2 x the 1-unit base bet (the two split hands).
	var guard := 0
	while not loop.is_idle() and guard < 96:
		loop.apply_action(loop.optimal_action())
		guard += 1
	if not loop.is_idle():
		_failures.append("das-gate: round did not settle, phase=%s" % loop.phase())
	elif absf(loop.last_wagered() - 2.0) >= 1e-6:
		_failures.append("das-gate: wagered should be 2 x 1 base bet (no double applied), got %.2f" % loop.last_wagered())
	else:
		print("PASS  das-gate (loop): split-hand 11 on no-DAS -> no double offered, optimal hit, wagered 2x base")


# M72: place_bet() clamps the player's bet to [1, MAX_BET_UNITS] and the
# CLAMPED value is what gets committed and graded (GameLoop.gd:307, 316, 322).
# No tool ever passed a bet outside [1, 6], so a regression that graded or
# committed the raw value would slip through. Rig a dealer-BJ hand with a hot
# count (optimal ramp bet = 6):
#   - place_bet(100) clamps to 6: the single non-BJ spot loses exactly its base
#     bet (net -6), and 6 == optimal so the ramp grades zero deviation
#     (discipline stays 100 via recovery).
#   - place_bet(0) clamps to 1: net -1, and |1-6| = 5 grades the max severity
#     step (-4.0) -> discipline 96.
func _check_place_bet_clamping() -> void:
	var over: Dictionary = _drive_clamp_bj_loss(100)
	var under: Dictionary = _drive_clamp_bj_loss(0)
	if absf(float(over.net) - -6.0) >= 1e-6:
		_failures.append("bet-clamp: place_bet(100) should commit 6 units (net -6), got %.2f" % over.net)
	else:
		print("PASS  bet-clamp: place_bet(100) clamps to MAX_BET_UNITS (net -6)")
	if absf(float(over.discipline) - 100.0) >= 0.001:
		_failures.append("bet-clamp: clamped 6 == optimal 6 -> no deviation, discipline stays 100, got %.2f" % over.discipline)
	if absf(float(under.net) - -1.0) >= 1e-6:
		_failures.append("bet-clamp: place_bet(0) should commit 1 unit (net -1), got %.2f" % under.net)
	else:
		print("PASS  bet-clamp: place_bet(0) clamps to 1 (net -1)")
	if absf(float(under.discipline) - 96.0) >= 0.001:
		_failures.append("bet-clamp: clamped 1 vs optimal 6 -> severity step 3 penalty, discipline 96, got %.2f" % under.discipline)


# Drives one loop through a rigged Ace-up / 10-hole (dealer BJ) hand with the
# running count rigged so optimal_bet_units() == 6, places the raw bet
# `units`, declines insurance, and settles. The single spot is 8,4 (no BJ), so
# it loses exactly its committed base bet. Returns {net, discipline}: the net
# proves which base bet was committed (the clamped value, not the raw input);
# the discipline proves which value was graded against the optimal ramp.
func _drive_clamp_bj_loss(units: int) -> Dictionary:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.blackjack_payout = 1.5
	c.allows_split = false
	c.allows_double = false
	c.allows_surrender = false
	c.allows_insurance = true
	c.grade_decisions = false
	c.grade_bet_ramp = true
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var discipline := CHDisciplineSystem.new()
	var loop := CHGameLoop.new(c, state, discipline, SEED)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	shoe.deck.append(CHCard.new("H", 14))  # upcard Ace -> insurance offered
	shoe.deck.append(CHCard.new("S", 10))  # hole -> dealer BJ
	shoe.deck.append(CHCard.new("S", 8))   # p1
	shoe.deck.append(CHCard.new("H", 4))   # p2 -> hard 12, no BJ
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	# Rig a hot count (tc 8 -> ramp optimal = 6) before begin_hand fixes it.
	loop.get_count().running_count = 8
	if not loop.begin_hand():
		_failures.append("bet-clamp: begin_hand failed")
		return {"net": -999.0, "discipline": -999.0}
	if not loop.place_bet(units, false):
		_failures.append("bet-clamp: place_bet failed")
		return {"net": -999.0, "discipline": -999.0}
	if loop.phase() != CHGameLoop.PHASE_INSURANCE:
		_failures.append("bet-clamp: expected INSURANCE phase, got %s" % loop.phase())
		return {"net": -999.0, "discipline": -999.0}
	loop.apply_action(CHGameLoop.ACT_INS_DECLINE)
	var guard := 0
	while not loop.is_idle() and guard < 32:
		loop.apply_action(loop.optimal_action())
		guard += 1
	if not loop.is_idle():
		_failures.append("bet-clamp: hand did not settle, phase=%s" % loop.phase())
		return {"net": -999.0, "discipline": -999.0}
	return {"net": loop.last_net(), "discipline": discipline.discipline}


# Fresh single-deck surrender loop (no split/double/insurance, no grading) with
# a rigged opening: upcard, hole, then a two-card player hand. `early` selects
# late_surrender_only (false == early). The hand is dealt and bet is committed;
# the caller then inspects phase / actions / optimal.
func _surrender_loop(early: bool, up_rank: int, hole_rank: int, p1_rank: int, p2_rank: int) -> CHGameLoop:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.allows_surrender = true
	c.late_surrender_only = not early
	c.allows_split = false
	c.allows_double = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	shoe.deck.append(CHCard.new("H", up_rank))
	shoe.deck.append(CHCard.new("S", hole_rank))
	shoe.deck.append(CHCard.new("S", p1_rank))
	shoe.deck.append(CHCard.new("H", p2_rank))
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	loop.begin_hand()
	loop.place_bet(1, false)
	return loop


# M44: pin the full 4-step bet ramp. optimal_bet_units() -> _bet_for_tc(_tc).
# css_check pins only the hot end (6) and the CSS floor (1); the middle steps
# (2 at tc 0-1, 4 at tc 2-3) were unpinned, so a regression that flattens or
# re-steps the ramp would not have been caught.
func _check_bet_ramp() -> void:
	var cases: Array = [
		[-2, 1],  # tc <= -1 -> min bet
		[0, 2],   # -1 < tc <= 1
		[1, 2],
		[2, 4],   # 1 < tc <= 3
		[3, 4],
		[4, 6],   # tc >= 4 -> max bet
	]
	var ok := true
	for c in cases:
		var tc: int = int(c[0])
		var want: int = int(c[1])
		var got: int = _rig_tc_loop(tc).optimal_bet_units()
		if got != want:
			ok = false
			_failures.append("bet-ramp: tc %d should bet %d, got %d" % [tc, want, got])
	if ok:
		print("PASS  bet ramp: tc -2/0/1/2/3/4 -> 1/2/2/4/4/6 (all 4 steps pinned)")


# Fresh single-deck non-CSS loop rigged so its floored true count equals `tc`
# when the hand starts (mirrors css_check._hot_hand). No grading, no count
# check, so no shoe-cut prompt can interfere.
func _rig_tc_loop(tc: int) -> CHGameLoop:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.count_check_active = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var count: CHCountEngine = loop.get_count()
	count.running_count = tc
	count.decks_remaining = 1.0
	loop.begin_hand()
	return loop


# M38: heat-tell wiring. CHHeatSystem's model is tested in heat_check, but
# nothing verified that the loop actually records tells when the player makes
# them. Pin the two cleanly-observable triggers: a big bet on a hot count
# (BET_TELL) and taking insurance on a hot count (INSURANCE_TELL). Each is
# paired with a control that must NOT fire. The deviation tell settles the
# hand, so decay masks it; it is covered indirectly and left unpinned here.
func _check_heat_tell_triggers() -> void:
	# Big bet on a hot count must fire the bet tell.
	var hot_big := _heat_delta(_rig_hot_loop(), 4)
	if absf(hot_big - CHHeatSystem.BET_TELL_GAIN) < 1e-6:
		print("PASS  heat bet-tell: big bet on hot count adds %.1f heat" % hot_big)
	else:
		_failures.append("heat bet-tell: expected +%.1f, got %.2f" % [CHHeatSystem.BET_TELL_GAIN, hot_big])
	# Control: same hot count, small bet -> no bet tell.
	var hot_small := _heat_delta(_rig_hot_loop(), 1)
	if absf(hot_small) < 1e-6:
		print("PASS  heat bet-tell control: small bet on hot count adds no heat")
	else:
		_failures.append("heat bet-tell control: expected 0 gain, got %.2f" % hot_small)
	# Control: cold count, big bet -> no bet tell.
	var cold_big := _heat_delta(_rig_cold_loop(), 4)
	if absf(cold_big) < 1e-6:
		print("PASS  heat bet-tell control: big bet on cold count adds no heat")
	else:
		_failures.append("heat bet-tell control: expected 0 gain, got %.2f" % cold_big)
	# Insurance on a hot count must fire the insurance tell; declining must not.
	var ins_take := _heat_delta_insurance(true)
	if absf(ins_take - CHHeatSystem.INSURANCE_TELL_GAIN) < 1e-6:
		print("PASS  heat insurance-tell: taking insurance on hot count adds %.1f heat" % ins_take)
	else:
		_failures.append("heat insurance-tell: expected +%.1f, got %.2f" % [CHHeatSystem.INSURANCE_TELL_GAIN, ins_take])
	var ins_decline := _heat_delta_insurance(false)
	if absf(ins_decline) < 1e-6:
		print("PASS  heat insurance-tell control: declining on hot count adds no heat")
	else:
		_failures.append("heat insurance-tell control: expected 0 gain, got %.2f" % ins_decline)


# Fresh heat-active loop with the running count rigged hot (TC 5 on 1 deck).
func _rig_hot_loop() -> CHGameLoop:
	return _rig_heat_loop(5)


func _rig_cold_loop() -> CHGameLoop:
	return _rig_heat_loop(0)


func _rig_heat_loop(running_count: int) -> CHGameLoop:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.heat_active = true
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	loop.get_count().running_count = running_count
	loop.begin_hand()
	return loop


# Places `units` on the rigged loop and returns the heat delta across the bet.
func _heat_delta(loop: CHGameLoop, units: int) -> float:
	var before: float = loop.get_heat_system().heat
	loop.place_bet(units, false)
	return loop.get_heat_system().heat - before


# Rigs an Ace upcard (insurance offered) on a hot count, takes or declines
# insurance, and returns the heat delta across that decision.
func _heat_delta_insurance(take: bool) -> float:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.heat_active = true
	c.allows_insurance = true
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	loop.get_count().running_count = 5  # hot count so the insurance tell can fire
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	shoe.deck.append(CHCard.new("H", 14))  # upcard Ace -> insurance offered
	shoe.deck.append(CHCard.new("S", 7))   # hole -> dealer 19, no natural
	shoe.deck.append(CHCard.new("S", 9))   # p1
	shoe.deck.append(CHCard.new("H", 8))   # p2 -> 17 hard, no natural
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("heat insurance-tell: begin_hand failed")
		return -999.0
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_INSURANCE:
		_failures.append("heat insurance-tell: expected INSURANCE phase, got %s" % loop.phase())
		return -999.0
	var before: float = loop.get_heat_system().heat
	if take:
		loop.apply_action(CHGameLoop.ACT_INS_TAKE)
	else:
		loop.apply_action(CHGameLoop.ACT_INS_DECLINE)
	return loop.get_heat_system().heat - before


# M39: deviation-tell loop wiring. M38 pinned the bet + insurance tells but left
# the deviation tell (GameLoop.gd:525) unpinned because, at the default tier
# sensitivity (1.0), the tell gain (DEV_TELL_GAIN 2.0) is fully masked by the
# per-hand decay (DECAY_PER_HAND 3.0) at settle, so the net heat delta is 0.
# This pins it by rigging a sensitivity of 3.0, so the tell gain (6.0) exceeds
# decay and leaves a positive, measurable residue. A two-card hard 13 vs upcard
# 10 at TC 4 is a clean I18 stand deviation; the control uses the same hand vs
# upcard 5 (no I18 rule) so the only heat difference is the deviation tell.
func _check_deviation_tell() -> void:
	var dev_heat: float = _drive_dev_tell(10, 8)   # up 10, hole 8 -> dealer 18 stands
	var ctrl_heat: float = _drive_dev_tell(5, 12)  # up 5,  hole 12 -> dealer 17 stands
	# tell gain 2.0 * sensitivity 3.0 = 6.0; decay 3.0 at settle -> net 3.0.
	if absf(dev_heat - 3.0) < 1e-6:
		print("PASS  heat dev-tell: I18 deviation on hot count leaves %.1f heat residue" % dev_heat)
	else:
		_failures.append("heat dev-tell: expected residue 3.0, got %.2f" % dev_heat)
	if absf(ctrl_heat) < 1e-6:
		print("PASS  heat dev-tell control: no deviation leaves 0.0 heat residue")
	else:
		_failures.append("heat dev-tell control: expected 0.0, got %.2f" % ctrl_heat)


# Rigs a hot-count hand (TC 4) with sensitivity 3.0, plays the optimal action to
# settle, and returns the final heat. `up_rank` selects the upcard; `hole_rank`
# the hole so the dealer stands. The deviation run uses up=10 (I18 stand dev on
# 13v10); the control uses up=5 (no I18 rule on 13v5).
func _drive_dev_tell(up_rank: int, hole_rank: int) -> float:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.heat_active = true
	c.heat_sensitivity_multiplier = 3.0
	c.allows_surrender = false
	c.allows_split = false
	c.allows_double = false
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	loop.get_count().running_count = 4  # hot: TC floor(4/1.0)=4 on a fresh 1-deck shoe
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	shoe.deck.append(CHCard.new("H", up_rank))   # upcard
	shoe.deck.append(CHCard.new("S", hole_rank)) # hole (dealer stands)
	shoe.deck.append(CHCard.new("S", 8))         # p1
	shoe.deck.append(CHCard.new("H", 5))         # p2 -> hard 13, not a pair
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("dev-tell: begin_hand failed")
		return -999.0
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_HAND:
		_failures.append("dev-tell: expected HAND phase, got %s" % loop.phase())
		return -999.0
	# Optimal play stands on hard 13 (deviation vs up 10; basic stand vs up 5).
	loop.apply_action(CHGameLoop.ACT_STAND)
	if not loop.is_idle():
		_failures.append("dev-tell: not idle after stand, phase=%s" % loop.phase())
		return -999.0
	return loop.get_heat_system().heat


# M121: count-only teaching tables suppress the player-agency heat tells. The
# hand is auto-played by the engine, so betting/insurance/deviation would build
# heat the player never chose — the drill is pressure-free. The only difference
# between the two loops below is count_only (same seed/shoe), so the heat-delta
# difference isolates the bet tell: present in the control, suppressed on the
# count-only table. No hand settles (the loop is left in HAND), so no decay
# muddies the measurement.
func _check_count_only_heat_suppressed() -> void:
	var co: float = _count_only_heat_delta(true)
	var ctrl: float = _count_only_heat_delta(false)
	if absf(co) < 1e-6:
		print("PASS  count-only heat: hot auto-bet adds no heat (no player agency)")
	else:
		_failures.append("count-only heat: expected 0 heat from auto-bet, got %.2f" % co)
	if absf(ctrl - CHHeatSystem.BET_TELL_GAIN) < 1e-6:
		print("PASS  count-only heat control: non-count-only hot bet adds %.1f (tell live)" % ctrl)
	else:
		_failures.append("count-only heat control: expected +%.1f, got %.2f" % [CHHeatSystem.BET_TELL_GAIN, ctrl])


# Fresh heat-active 1-deck loop, hot count (TC 5), upcard 5 (no insurance) so the
# hand rests in HAND after the bet (no settle, no decay). Returns the heat delta
# across a 4-unit bet. `count_only` toggles the teaching-table flag.
func _count_only_heat_delta(count_only: bool) -> float:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.heat_active = true
	c.count_only = count_only
	c.allows_insurance = false
	c.grade_decisions = false
	c.grade_bet_ramp = false
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	loop.get_count().running_count = 5
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	shoe.deck.append(CHCard.new("H", 5))   # upcard (not an Ace: no insurance)
	shoe.deck.append(CHCard.new("S", 2))   # hole (dealer 7, stands)
	shoe.deck.append(CHCard.new("S", 8))   # p1
	shoe.deck.append(CHCard.new("H", 5))   # p2 -> hard 13
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("C", 2))
	shoe.deal_index = 0
	if not loop.begin_hand():
		_failures.append("count-only heat: begin_hand failed")
		return -999.0
	var before: float = loop.get_heat_system().heat
	loop.place_bet(4, false)
	return loop.get_heat_system().heat - before


# --- NPC players (config.npc_players) ---
# A higher-tier table fills the seats with auto-played NPC hands. Verify: (a) the
# NPC is dealt and auto-played to a terminal state (17+ or bust), (b) its cards are
# revealed (counted) and shoe conservation still holds, (c) the trainee's P&L is
# unaffected (the NPC has no stake), and (d) the run stays deterministic.
func _check_npc_players() -> void:
	var nets: Array[float] = []
	for run in 2:
		var c := CHTableConfig.new()
		c.deck_count = 1
		c.npc_players = 1
		c.allows_insurance = false  # isolate the NPC path (no side-bet branch)
		c.grade_decisions = false
		c.grade_bet_ramp = false
		var state := CHGameState.new()
		state.start_session(1, CHGameState.MODE_TARGET, 999999)
		var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
		var hands := 0
		var conservation_bad := 0
		var saw_npc := false
		while hands < 50 and state.is_session_active():
			if not loop.begin_hand():
				break
			hands += 1
			# NPC is dealt + auto-played once the round passes the BET phase
			# (place_bet -> _deal_opening -> _after_insurance -> _play_npcs). Probe
			# it mid-round, before the hand settles and clears _npc_hands.
			while not loop.is_idle():
				if not saw_npc and loop.npc_hands().size() == 1:
					saw_npc = true
					var nh: CHHand = loop.npc_hands()[0]
					if nh.cards.size() < 2:
						_failures.append("npc: hand has %d cards (<2)" % nh.cards.size())
					if nh.cards.size() > 12:
						_failures.append("npc: hand grew past guard (%d cards)" % nh.cards.size())
					# Terminal per basic strategy: the engine no longer wants to hit.
					var up: CHCard = loop.dealer_upcard()
					var p: String = loop.engine.best_play_no_split(
						nh, CHHand.dealer_upcard_key(up.rank), loop.config, 0)
					if not nh.is_bust() and p == "hit":
						_failures.append("npc: engine still wants to hit NPC hand (total %d)" % nh.total())
					# Bust-stops-on-first-bust: a bust must be caused by the LAST
					# card (prefix <= 21). Catches an over-drawn bust (e.g. hard 16
					# hit into 22, then kept drawing because _hard_play(22) falls
					# through to the default "hit").
					if nh.is_bust():
						var pre := 0
						var aces_pre := 0
						for k in nh.cards.size() - 1:
							var cc: CHCard = nh.cards[k]
							if cc.is_ace():
								aces_pre += 1
								pre += 11
							elif cc.rank >= 10:
								pre += 10
							else:
								pre += cc.rank
						while pre > 21 and aces_pre > 0:
							pre -= 10
							aces_pre -= 1
						if pre > 21:
							_failures.append("npc: over-drew a bust hand (%d cards, prefix %d > 21)" % [nh.cards.size(), pre])
				loop.apply_action(loop.optimal_action())
			# P&L isolation: the trainee's wagered is its own bet only, never the NPC's.
			var wagered: float = loop.last_wagered()
			if wagered < 1.0:
				_failures.append("npc: trainee wagered %.1f < 1 (NPC leaked into P&L)" % wagered)
			nets.append(loop.last_net())
			# Conservation: every card dealt (incl. NPC) is revealed exactly once.
			var dealt: int = loop.get_shoe().cards_dealt()
			var seen := 0
			for j in dealt:
				if loop.get_shoe().deck[j].seen:
					seen += 1
			if seen != dealt:
				conservation_bad += 1
		if not saw_npc:
			_failures.append("npc: never observed an NPC hand across the soak")
		if conservation_bad > 0:
			_failures.append("npc: card conservation violated in %d hand(s)" % conservation_bad)
		if hands < 1:
			_failures.append("npc: no hands driven")
	# Determinism: the NPC consumes cards, but the trainee sequence must still be
	# identical across two runs with the same seed.
	if nets.size() >= 2:
		var half: int = nets.size() / 2
		for i in half:
			if absf(nets[i] - nets[half + i]) > 1e-6:
				_failures.append("npc: determinism broken across runs")


# A target-mode check can end the session as "bust" (bankroll -> 0), which
# triggers end_session -> save(). Remove that artifact so the tool leaves no
# residue in the user data directory.
func _cleanup_save() -> void:
	var p := ProjectSettings.globalize_path("user://counting_house_save.json")
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	# M83: atomic saves write a sibling .tmp before renaming; remove any residue.
	if FileAccess.file_exists(p + ".tmp"):
		DirAccess.remove_absolute(p + ".tmp")
