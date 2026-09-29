extends SceneTree
# Headless validation for CHOpponent — the social opponent model (M122 venue arc).
#
#   1. Construction + reset: fields set correctly, reset restores initial state.
#   2. is_busted: returns true when bankroll <= 0.
#   3. choose_bet: each policy behaves correctly (flat, ramp, count, tilts).
#   4. choose_bet clamping: never exceeds bankroll.
#   5. choose_play: skill=1.0 always returns optimal; skill=0.0 never returns
#      optimal (when a suboptimal alternative exists).
#   6. apply_result: bankroll, counters, consecutive_losses update correctly.
#   7. Determinism: same seed produces same sequence of decisions.

const SEED := 20260923


var _failures: Array[String] = []


func _init() -> void:
	_check_construction_and_reset()
	_check_is_busted()
	_check_choose_bet_flat()
	_check_choose_bet_ramp()
	_check_choose_bet_count()
	_check_choose_bet_tilts()
	_check_choose_bet_clamped_to_bankroll()
	_check_choose_play_skill_one()
	_check_choose_play_skill_zero()
	_check_choose_play_single_option()
	_check_apply_result()
	_check_determinism()
	_check_summary()
	_check_loop_integration()
	_check_loop_integration_determinism()
	_check_busted_seat_ends()

	if _failures.is_empty():
		print("opponent_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("opponent_check: %d failure(s)" % _failures.size())
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


# --- 1. Construction + reset ---
func _check_construction_and_reset() -> void:
	var opp := CHOpponent.new("Alice", "shark", 0.8, 100, CHOpponent.POLICY_RAMP, 2, SEED)
	_expect(opp.name == "Alice", "name set, got '%s'" % opp.name)
	_expect(opp.archetype == "shark", "archetype set, got '%s'" % opp.archetype)
	_expect(absf(opp.skill - 0.8) < 0.001, "skill = 0.8, got %s" % opp.skill)
	_expect(opp.starting_bankroll == 100, "starting_bankroll = 100, got %d" % opp.starting_bankroll)
	_expect(opp.bankroll == 100, "initial bankroll = 100, got %d" % opp.bankroll)
	_expect(opp.bet_policy == CHOpponent.POLICY_RAMP, "policy set, got '%s'" % opp.bet_policy)
	_expect(opp.tilt_factor == 2, "tilt_factor = 2, got %d" % opp.tilt_factor)

	# Simulate some action, then reset.
	opp.apply_result(5.0)
	opp.apply_result(-3.0)
	opp.apply_result(-2.0)
	opp.reset()
	_expect(opp.bankroll == 100, "reset restores bankroll, got %d" % opp.bankroll)
	_expect(opp.hands_played == 0, "reset clears hands_played, got %d" % opp.hands_played)
	_expect(opp.net_pnl == 0.0, "reset clears net_pnl, got %s" % opp.net_pnl)
	_expect(opp.consecutive_losses == 0, "reset clears consecutive_losses, got %d" % opp.consecutive_losses)


# --- 2. is_busted ---
func _check_is_busted() -> void:
	var opp := CHOpponent.new("Bob", "friend", 0.5, 10, CHOpponent.POLICY_FLAT, 1, SEED)
	_expect(not opp.is_busted(), "not busted at bankroll=10")
	opp.apply_result(-10.0)
	_expect(opp.bankroll == 0, "bankroll = 0 after losing all, got %d" % opp.bankroll)
	_expect(opp.is_busted(), "busted at bankroll=0")
	opp.apply_result(-1.0)
	_expect(opp.bankroll == -1, "bankroll can go negative, got %d" % opp.bankroll)
	_expect(opp.is_busted(), "still busted at bankroll=-1")


# --- 3. choose_bet: flat ---
func _check_choose_bet_flat() -> void:
	var opp := CHOpponent.new("Flat", "friend", 0.5, 50, CHOpponent.POLICY_FLAT, 1, SEED)
	_expect(opp.choose_bet({"tc": 5}) == 1, "flat: always 1 unit, got %d" % opp.choose_bet({"tc": 5}))
	_expect(opp.choose_bet({"tc": -3}) == 1, "flat: always 1 unit (neg TC), got %d" % opp.choose_bet({"tc": -3}))


# --- 4. choose_bet: ramp ---
func _check_choose_bet_ramp() -> void:
	var opp := CHOpponent.new("Ramp", "regular", 0.5, 50, CHOpponent.POLICY_RAMP, 1, SEED)
	_expect(opp.choose_bet({"tc": 0}) == 1, "ramp: TC 0 -> 1 unit, got %d" % opp.choose_bet({"tc": 0}))
	_expect(opp.choose_bet({"tc": 2}) == 2, "ramp: TC 2 -> 2 units, got %d" % opp.choose_bet({"tc": 2}))
	_expect(opp.choose_bet({"tc": 4}) == 3, "ramp: TC 4 -> 3 units, got %d" % opp.choose_bet({"tc": 4}))
	_expect(opp.choose_bet({"tc": 6}) == 4, "ramp: TC 6 -> 4 units, got %d" % opp.choose_bet({"tc": 6}))
	_expect(opp.choose_bet({"tc": -2}) == 1, "ramp: neg TC -> 1 unit, got %d" % opp.choose_bet({"tc": -2}))


# --- 5. choose_bet: count ---
func _check_choose_bet_count() -> void:
	var opp := CHOpponent.new("Count", "shark", 0.5, 50, CHOpponent.POLICY_COUNT, 1, SEED)
	_expect(opp.choose_bet({"tc": 0}) == 1, "count: TC 0 -> 1 unit, got %d" % opp.choose_bet({"tc": 0}))
	_expect(opp.choose_bet({"tc": 3}) == 4, "count: TC 3 -> 4 units, got %d" % opp.choose_bet({"tc": 3}))
	_expect(opp.choose_bet({"tc": 5}) == 6, "count: TC 5 -> 6 units, got %d" % opp.choose_bet({"tc": 5}))
	_expect(opp.choose_bet({"tc": -1}) == 1, "count: neg TC -> 1 unit, got %d" % opp.choose_bet({"tc": -1}))


# --- 6. choose_bet: tilts ---
func _check_choose_bet_tilts() -> void:
	var opp := CHOpponent.new("Tilt", "shark", 0.5, 50, CHOpponent.POLICY_TILTS, 2, SEED)
	_expect(opp.choose_bet({"tc": 0}) == 1, "tilts: no losses -> 1 unit, got %d" % opp.choose_bet({"tc": 0}))
	opp.apply_result(-1.0)
	_expect(opp.choose_bet({"tc": 0}) == 3, "tilts: 1 loss -> 1+2=3 units, got %d" % opp.choose_bet({"tc": 0}))
	opp.apply_result(-1.0)
	_expect(opp.choose_bet({"tc": 0}) == 5, "tilts: 2 losses -> 1+4=5 units, got %d" % opp.choose_bet({"tc": 0}))
	# A win resets the tilt.
	opp.apply_result(5.0)
	_expect(opp.choose_bet({"tc": 0}) == 1, "tilts: after win -> back to 1 unit, got %d" % opp.choose_bet({"tc": 0}))


# --- 7. choose_bet clamped to bankroll ---
func _check_choose_bet_clamped_to_bankroll() -> void:
	var opp := CHOpponent.new("Low", "friend", 0.5, 3, CHOpponent.POLICY_COUNT, 1, SEED)
	# TC 10 would want 11 units, but bankroll is only 3.
	var bet: int = opp.choose_bet({"tc": 10})
	_expect(bet <= 3, "bet clamped to bankroll (3), got %d" % bet)
	_expect(bet >= 1, "bet at least 1, got %d" % bet)


# --- 8. choose_play: skill=1.0 always optimal ---
func _check_choose_play_skill_one() -> void:
	var opp := CHOpponent.new("Perfect", "pro", 1.0, 50, CHOpponent.POLICY_FLAT, 1, SEED)
	for i in 100:
		var action: String = opp.choose_play("stand", ["hit", "stand", "double"])
		_expect(action == "stand", "skill=1: expected 'stand', got '%s' (iter %d)" % [action, i])


# --- 9. choose_play: skill=0.0 never optimal (when suboptimal exists) ---
func _check_choose_play_skill_zero() -> void:
	var opp := CHOpponent.new("Rookie", "friend", 0.0, 50, CHOpponent.POLICY_FLAT, 1, SEED)
	for i in 100:
		var action: String = opp.choose_play("stand", ["hit", "stand", "double"])
		_expect(action != "stand", "skill=0: expected non-optimal, got '%s' (iter %d)" % [action, i])


# --- 10. choose_play: single option forces optimal ---
func _check_choose_play_single_option() -> void:
	var opp := CHOpponent.new("Stuck", "friend", 0.0, 50, CHOpponent.POLICY_FLAT, 1, SEED)
	for i in 50:
		var action: String = opp.choose_play("stand", ["stand"])
		_expect(action == "stand", "single option: must return 'stand', got '%s'" % action)


# --- 11. apply_result: counters and P&L ---
func _check_apply_result() -> void:
	var opp := CHOpponent.new("Test", "friend", 0.5, 100, CHOpponent.POLICY_FLAT, 1, SEED)
	opp.apply_result(5.0)
	_expect(opp.bankroll == 105, "win: bankroll 100+5=105, got %d" % opp.bankroll)
	_expect(opp.hands_won == 1, "win: hands_won=1, got %d" % opp.hands_won)
	_expect(absf(opp.net_pnl - 5.0) < 0.001, "win: net_pnl=5, got %s" % opp.net_pnl)
	_expect(opp.consecutive_losses == 0, "win: consecutive_losses reset, got %d" % opp.consecutive_losses)

	opp.apply_result(-3.0)
	_expect(opp.bankroll == 102, "loss: bankroll 105-3=102, got %d" % opp.bankroll)
	_expect(opp.hands_lost == 1, "loss: hands_lost=1, got %d" % opp.hands_lost)
	_expect(opp.consecutive_losses == 1, "loss: consecutive_losses=1, got %d" % opp.consecutive_losses)

	opp.apply_result(0.0)
	_expect(opp.hands_pushed == 1, "push: hands_pushed=1, got %d" % opp.hands_pushed)
	_expect(opp.hands_played == 3, "hands_played=3, got %d" % opp.hands_played)
	_expect(absf(opp.net_pnl - 2.0) < 0.001, "net_pnl=5-3+0=2, got %s" % opp.net_pnl)


# --- 12. Determinism: same seed -> same decisions ---
func _check_determinism() -> void:
	var opp_a := CHOpponent.new("A", "shark", 0.5, 50, CHOpponent.POLICY_TILTS, 2, SEED)
	var opp_b := CHOpponent.new("B", "shark", 0.5, 50, CHOpponent.POLICY_TILTS, 2, SEED)
	var results_a: Array[String] = []
	var results_b: Array[String] = []
	for i in 20:
		var action_a: String = opp_a.choose_play("stand", ["hit", "stand", "double"])
		var action_b: String = opp_b.choose_play("stand", ["hit", "stand", "double"])
		results_a.append(action_a)
		results_b.append(action_b)
		opp_a.apply_result(1.0 if action_a == "stand" else -1.0)
		opp_b.apply_result(1.0 if action_b == "stand" else -1.0)
	for i in 20:
		_expect(results_a[i] == results_b[i], "determinism: iter %d differs: %s vs %s" % [i, results_a[i], results_b[i]])


# --- 13. summary format ---
func _check_summary() -> void:
	var opp := CHOpponent.new("Dana", "regular", 0.6, 50, CHOpponent.POLICY_FLAT, 1, SEED)
	opp.apply_result(3.0)
	opp.apply_result(-1.0)
	var s: String = opp.summary()
	_expect(s.contains("Dana"), "summary includes name, got '%s'" % s)
	_expect(s.contains("52"), "summary includes bankroll (50+3-1=52), got '%s'" % s)
	_expect(s.contains("1W"), "summary includes wins, got '%s'" % s)
	_expect(s.contains("1L"), "summary includes losses, got '%s'" % s)


# Builds a practice-mode loop with a tracked opponent (not count-only, so the
# player drives the hand and the opponent plays its own seat).
func _make_loop_with_opponent(opp: CHOpponent) -> CHGameLoop:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.allows_split = true
	c.max_split_hands = 4
	c.split_aces_one_card_only = true
	c.allows_double_after_split = true
	c.opponent = opp
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_PRACTICE, 0, 5)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(c, state, disc, SEED)


# Plays a single round to rest (idle), betting 1 unit in the BET phase.
func _play_one_hand(loop: CHGameLoop) -> void:
	if not loop.begin_hand():
		return
	if loop.phase() == CHGameLoop.PHASE_BET:
		loop.place_bet(1)
	var guard := 0
	while not loop.is_idle() and guard < 96:
		loop.apply_action(loop.optimal_action())
		guard += 1


# --- 14. Loop integration: the tracked opponent gets dealt, plays, settles ---
# The opponent consumes its own cards from the same shoe, settles after each
# round, and accumulates a session P&L — while the player's bankroll is
# untouched by the opponent's results.
func _check_loop_integration() -> void:
	var opp := CHOpponent.for_opponent("Sal", "friend", 1.0, 100, CHOpponent.POLICY_FLAT, 1, SEED)
	var loop := _make_loop_with_opponent(opp)
	_expect(loop.get_opponent() == opp, "loop: get_opponent returns the configured rival")
	var settled := {"count": 0, "nets": []}
	var busted := {"count": 0}
	loop.opponent_settled.connect(func(net: float):
		settled.count += 1
		settled.nets.append(net))
	loop.opponent_busted.connect(func():
		busted.count += 1)

	var hands := 0
	while state_active(loop) and hands < 4:
		_play_one_hand(loop)
		hands += 1
	_expect(settled.count == hands, "loop: opponent_settled fired once per hand, got %d for %d hands" % [settled.count, hands])
	_expect(opp.hands_played == hands, "loop: opponent recorded %d hands, got %d" % [hands, opp.hands_played])
	var total_net: float = 0.0
	for n in settled.nets:
		total_net += float(n)
	_expect(absf(opp.net_pnl - total_net) < 0.001, "loop: opponent net_pnl matches emitted signals, got %s vs %s" % [opp.net_pnl, total_net])
	_expect(opp.bankroll == 100 + int(total_net), "loop: opponent bankroll = start + net, got %d" % opp.bankroll)
	# Flat 1-unit bet: every settled net is in {-1, 0, 1, 1.5} (BJ pays 3:2).
	for n in settled.nets:
		var v: float = float(n)
		var ok: bool = absf(v - (-1.0)) < 0.001 or absf(v) < 0.001 or absf(v - 1.0) < 0.001 or absf(v - 1.5) < 0.001
		_expect(ok, "loop: flat-bet opponent net is a valid 1-unit outcome, got %s" % n)
	# The opponent's cards entered the shoe's dealt stream (>= 4 extra cards:
	# 2 per hand, plus any drawn cards).
	_expect(loop.get_shoe().cards_dealt() >= 6 * hands, "loop: shoe dealt >= 6 cards/hand (up/hole/opp2/...), got %d for %d hands" % [loop.get_shoe().cards_dealt(), hands])


# --- 15. Loop integration determinism: same seed -> same opponent arc ---
func _check_loop_integration_determinism() -> void:
	var opp_a := CHOpponent.for_opponent("SalA", "friend", 0.7, 100, CHOpponent.POLICY_RAMP, 1, SEED)
	var opp_b := CHOpponent.for_opponent("SalB", "friend", 0.7, 100, CHOpponent.POLICY_RAMP, 1, SEED)
	var loop_a := _make_loop_with_opponent(opp_a)
	var loop_b := _make_loop_with_opponent(opp_b)
	var hands := 0
	while state_active(loop_a) and state_active(loop_b) and hands < 4:
		_play_one_hand(loop_a)
		_play_one_hand(loop_b)
		hands += 1
	_expect(opp_a.hands_played == opp_b.hands_played, "loop det: same hand count, got %d vs %d" % [opp_a.hands_played, opp_b.hands_played])
	_expect(absf(opp_a.net_pnl - opp_b.net_pnl) < 0.001, "loop det: same net P&L, got %s vs %s" % [opp_a.net_pnl, opp_b.net_pnl])
	_expect(opp_a.bankroll == opp_b.bankroll, "loop det: same bankroll, got %d vs %d" % [opp_a.bankroll, opp_b.bankroll])


# --- 16. Busted seat ends: once the rival busts, the loop stops dealing it
# cards and settles it (the opponent_busted "seat ends" contract). A busted
# seat no longer consumes the shoe, so the count stream is unaffected.
func _check_busted_seat_ends() -> void:
	var opp := CHOpponent.for_opponent("Tiny", "friend", 1.0, 2, CHOpponent.POLICY_FLAT, 1, SEED)
	var loop := _make_loop_with_opponent(opp)
	var settled := {"count": 0}
	loop.opponent_settled.connect(func(_net: float): settled.count += 1)
	# Bust the rival before the first deal (deterministic: 2u bankroll, -2u).
	opp.apply_result(-2.0)
	_expect(opp.is_busted(), "busted-seat: rival busted at bankroll 0")
	var hands := 0
	while state_active(loop) and hands < 3:
		_play_one_hand(loop)
		hands += 1
	_expect(hands == 3, "busted-seat: 3 hands played, got %d" % hands)
	_expect(settled.count == 0, "busted-seat: no opponent_settled after bust, got %d" % settled.count)
	_expect(opp.hands_played == 1, "busted-seat: model untouched by loop, got %d" % opp.hands_played)
	_expect(loop.opponent_hand() == null, "busted-seat: no live opponent hand after bust")


func state_active(loop: CHGameLoop) -> bool:
	return loop.state.is_session_active()
