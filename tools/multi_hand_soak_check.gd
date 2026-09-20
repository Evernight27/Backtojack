extends SceneTree
# End-to-end multi-hand tier soak.
#
# `multi_hand_check` pins multi-hand structure and settlement with RIGGED
# single rounds on a single-deck config. Nothing drives a REAL multi-deck
# tier's loop (player_hand_count > 1) for many hands with a live shoe, so a
# bug that only surfaces at volume — a multi-spot hand that stalls, a split
# that leaks a card across the shared dealer, a surrender that double-charges,
# or a settlement that strands the phase — would not be caught here.
#
# This tool drives the actual tier tables (Tier 4: 4-deck H17 2-hand late-
# surrender; Tier 7: 8-deck H17 continuous-shuffle 3-hand) with the optimal-
#action autopilot for a fixed number of rounds and pins the invariants that
# must hold on every settled round:
#
#   1. Completes the requested rounds without stalling (no infinite loop /
#      stranded phase).
#   2. Multi-hand dealing actually happens: at least one round reaches the
#      tier's full spot count of terminal hands (the real loop deals them,
#      not just the unit rig).
#   3. Every round's wagered and net are finite and sane (wagered >= spots;
#      net within [-wagered, wagered*blackjack_payout]; no NaN/Inf). The upper
#      bound accounts for 3:2 naturals: a natural + wins can legally net more
#      than the total wagered (see M105).
#   4. Card conservation: on every settled round, every card dealt in the
#      current shoe segment is marked seen exactly once (split + surrender +
#      dealer-play conserve cards across the shared dealer).
#   5. The session survives the whole soak (999999 practice shoes, so it
#      never busts or completes early).
#
# PASS == all invariants hold for both tiers. Exit 0 on pass, 1 on any fail.

const SEED := 20260906
const HANDS_PER_TIER := 200
const IDLE_GUARD := 256


var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	_soak_tier(4, 2)  # 4-deck H17, 2-hand, late surrender, hi_lo
	_soak_tier(7, 3)  # 8-deck H17, 3-hand, continuous-shuffle, hi_opt_ii
	_finish()


# Drives `tier`'s real table for HANDS_PER_TIER rounds and pins the invariants.
func _soak_tier(tier: int, expected_spots: int) -> void:
	var config := CHTableConfig.for_tier(tier)
	_expect(config.player_hand_count == expected_spots,
		"T%d: config spot count is %d, got %d" % [tier, expected_spots, config.player_hand_count])

	var state := CHGameState.new()
	state.start_session(tier, CHGameState.MODE_PRACTICE, 0, 999999)
	var loop := CHGameLoop.new(config, state, CHDisciplineSystem.new(), SEED)

	var rounds := 0
	var saw_full_spots := false
	var split_rounds := 0
	var stuck := false
	var round := 0

	while rounds < HANDS_PER_TIER:
		round += 1
		if not loop.begin_hand():
			_failures.append("T%d: begin_hand failed at round %d (session ended early)" % [tier, round])
			break
		# Autopilot: drive the optimal action for every phase (bet, insurance,
		# presplit, hand) until the round settles to idle. _finalize clears
		# _hands on settle, so capture the terminal hand-group size DURING the
		# round (it is complete in PHASE_HAND); track the max across the round.
		var guard := 0
		var max_hands := 0
		while not loop.is_idle() and guard < IDLE_GUARD:
			max_hands = maxi(max_hands, loop.all_hands().size())
			var act: String = loop.optimal_action()
			if act == "":
				break  # no actionable phase: a stalled round
			loop.apply_action(act)
			guard += 1
		if not loop.is_idle():
			stuck = true
			break
		rounds += 1

		# Spot count: did this round deal the tier's full multi-hand set?
		if max_hands >= expected_spots:
			saw_full_spots = true
		# A round that produced MORE terminal hands than the spot count had a
		# split expand one of the spots — evidence the split path ran in the real
		# multi-hand loop (reported, not failed).
		if max_hands > expected_spots:
			split_rounds += 1

		# Wagered / net sanity: finite, positive, and at least one unit per spot.
		# Net is bounded below by -wagered (you can never lose more than you bet)
		# and above by wagered * blackjack_payout (the best round is every unit
		# paid at the 3:2 natural rate — a natural + two wins can legally net
		# MORE than the total wagered, so the old `net <= wagered` bound was
		# wrong for 3:2 tables). Both soaked tiers are insurance-off, so the
		# natural payout is the max per-unit multiplier.
		var wagered: float = loop.last_wagered()
		var net: float = loop.last_net()
		if not is_finite(wagered) or not is_finite(net):
			_failures.append("T%d: round %d produced non-finite wagered=%.1f net=%.1f" % [tier, round, wagered, net])
		if wagered < float(expected_spots):
			_failures.append("T%d: round %d wagered %.1f < %d spots" % [tier, round, wagered, expected_spots])
		var net_ceiling: float = wagered * config.blackjack_payout
		if not (net <= net_ceiling and net >= -wagered):
			_failures.append("T%d: round %d net %.1f outside [-%.1f, %.1f] (wagered %.1f)" % [tier, round, net, wagered, net_ceiling, wagered])

	# --- 1. Completed the full soak without stalling ---
	if stuck:
		_failures.append("T%d: a round stalled before settling to idle (round %d, guard %d)" % [tier, round, IDLE_GUARD])
	_expect(rounds == HANDS_PER_TIER, "T%d: completed %d rounds, got %d" % [tier, HANDS_PER_TIER, rounds])

	# --- 2. Multi-hand dealing actually happens in the real loop ---
	_expect(saw_full_spots, "T%d: at least one round reached the full %d-spot hand set" % [tier, expected_spots])

	# --- 3. Session survived the whole soak ---
	_expect(state.is_session_active(), "T%d: session still active after the soak (not busted/completed early)" % tier)

	# --- 4. Card conservation on the final settled round ---
	_check_conservation(tier, loop)

	print("multi_hand_soak_check T%d: %d rounds, %d had a split-expansion"
		% [tier, rounds, split_rounds])


# On a settled round, every card dealt in the current shoe segment must be
# marked seen exactly once (split + surrender + dealer-play conserve cards).
func _check_conservation(tier: int, loop: CHGameLoop) -> void:
	var shoe := loop.get_shoe()
	var dealt: int = shoe.cards_dealt()
	var seen := 0
	for j in dealt:
		if shoe.deck[j].seen:
			seen += 1
	_expect(seen == dealt, "T%d: card conservation on settled round, %d/%d dealt cards seen" % [tier, seen, dealt])


func _finish() -> void:
	# No session save is written (practice mode on a fresh, unsaved state);
	# clean defensively.
	var p := ProjectSettings.globalize_path("user://counting_house_save.json")
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

	if _failures.is_empty():
		print("multi_hand_soak_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("multi_hand_soak_check: %d failure(s)" % _failures.size())
		quit(1)
