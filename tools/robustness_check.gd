extends SceneTree
# Headless robustness checks for the GameLoop card-deal path (runout handling).
#
# A pathological hand (e.g. a 4-way split where every hand is hit to 20) can
# outdraw the begin_hand() reserve, exhausting the shoe mid-hand. The guarded
# _deal_card() must never return null: on exhaustion it reshuffles, resets the
# count, emits shoe_reshuffled, and deals from the fresh shoe.
#
#   1. _deal_card() returns a valid card on every call, including the one that
#      triggers a runout (reshuffle + count reset + signal).
#   2. The runout path resets the running count and rebuilds the shoe.
#   3. A full hand that exhausts the shoe still settles to an idle state
#      without error (integration: the guard is reachable from real play).
#   4. Penetration is the primary cut point for multi-deck tiers (the shoe cut
#      fires at the tier's penetration fraction, ahead of the safety reserve).
#   5. Mid-hand runout does NOT trigger a count-check prompt, but still advances
#      the shoe counter (the _on_new_shoe() side effect). Pins the asymmetry
#      between start_of_shoe cut (which DOES trigger a count check) and the
#      emergency reshuffle (which does not).
#   6. Mid-hand runout re-syncs the deck estimate on a multi-deck shoe (a fresh
#      4-deck runout must read ~4.0 decks, not count.reset()'s 1.0 default).
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906

var _failures: Array[String] = []


func _init() -> void:
	_check_runout_deals_valid_card()
	_check_runout_resets_count_and_shoe()
	_check_hand_settles_across_runout()
	_check_penetration_cut()
	_check_runout_no_count_check()
	_check_runout_multideck_estimate()

	if _failures.is_empty():
		print("robustness_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("robustness_check: %d failure(s)" % _failures.size())
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _make_loop() -> CHGameLoop:
	var c := CHTableConfig.for_tier(1)
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_PRACTICE)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(c, state, disc, SEED)


# --- 1. Every deal returns a valid card, even across a forced runout ---
func _check_runout_deals_valid_card() -> void:
	var loop := _make_loop()
	var shoe := loop.get_shoe()
	# Leave exactly 3 cards in the wall.
	shoe.deal_index = shoe.deck.size() - 3
	var emitted := {"n": 0}
	loop.shoe_reshuffled.connect(func(): emitted.n += 1)
	for i in 5:
		var c: CHCard = loop._deal_card()
		_expect(c != null, "deal #%d returned null" % (i + 1))
		# The 4th and 5th deals come from a reshuffled shoe (runout occurred).
	_expect(emitted.n >= 1, "a runout reshuffle was emitted, got %d" % emitted.n)


# --- 2. The runout path resets the count, re-syncs the cached TC, and rebuilds the shoe ---
func _check_runout_resets_count_and_shoe() -> void:
	var loop := _make_loop()
	var count: CHCountEngine = loop.get_count()
	var shoe := loop.get_shoe()
	# Establish a nonzero cached true count the way begin_hand() does (fresh shoe,
	# so start_or_next_shoe() does not reshuffle). This is the pre-cut value M98
	# must refresh: without the fix it would survive the runout unchanged.
	count.running_count = 7
	_expect(loop.begin_hand(), "runout: begin_hand to establish _tc")
	var tc_before: int = loop.current_tc()
	_expect(tc_before > 0, "runout: established nonzero _tc before runout, got %d" % tc_before)
	# Seed a sub-1.0 deck estimate, then force an immediate runout.
	count.decks_remaining = 0.5
	shoe.deal_index = shoe.deck.size()  # fully exhausted
	var c: CHCard = loop._deal_card()
	_expect(c != null, "runout deal returned null")
	_expect(count.running_count == 0, "count reset to 0 after runout, got %d" % count.running_count)
	_expect(absf(count.decks_remaining - 1.0) < 0.001, "decks_remaining reset to 1.0, got %s" % count.decks_remaining)
	_expect(shoe.cards_dealt() == 1, "fresh shoe has dealt exactly 1 card, got %d" % shoe.cards_dealt())
	_expect(shoe.cards_remaining() == shoe.deck.size() - 1, "shoe rebuilt after runout")
	# M98: the cached floored true count must be re-synced to the fresh (zero)
	# count, not the stale pre-cut value (tc_before).
	_expect(loop.current_tc() == 0, "M98: _tc refreshed to 0 after runout, got %d (was %d)" % [loop.current_tc(), tc_before])
	_expect(loop.current_tc() == count.true_count_floor(), "M98: _tc consistent with fresh count, got %d vs %d" % [loop.current_tc(), count.true_count_floor()])


# --- 3. Integration: a hand played across a reshuffle conserves every card ---
func _check_hand_settles_across_runout() -> void:
	var loop := _make_loop()
	# Leave fewer than the reserve in the wall so begin_hand() triggers a fresh
	# shoe, then play the hand to rest and verify no card is double-counted or
	# lost across the reshuffle boundary.
	var shoe := loop.get_shoe()
	shoe.deal_index = shoe.deck.size() - 6  # 6 < SHOE_RESERVE -> reshuffle at start
	var ok := loop.begin_hand()
	_expect(ok, "begin_hand succeeded")
	if not ok:
		return
	loop.place_bet(loop.optimal_bet_units())
	var guard := 0
	while not loop.is_idle() and guard < 96:
		loop.apply_action(loop.optimal_action())
		guard += 1
	_expect(loop.is_idle(), "hand settled to idle despite runout, phase=%s" % loop.phase())
	# Card conservation: every card the loop dealt this shoe is marked seen.
	var dealt: int = loop.get_shoe().cards_dealt()
	var seen := 0
	for j in dealt:
		if loop.get_shoe().deck[j].seen:
			seen += 1
	_expect(seen == dealt, "card conservation across runout: %d/%d seen" % [seen, dealt])


# --- 4. Penetration is the primary cut point for multi-deck tiers ---
func _check_penetration_cut() -> void:
	var c := CHTableConfig.for_tier(4)  # 4 decks, penetration 0.50
	var total := c.deck_count * 52
	var pen_dealt := int(total * c.penetration)
	var reserve_dealt := total - CHGameLoop.SHOE_RESERVE
	_expect(pen_dealt < reserve_dealt, "T4 premise: penetration cut (%d) precedes reserve cut (%d)" % [pen_dealt, reserve_dealt])

	var state := CHGameState.new()
	state.start_session(4, CHGameState.MODE_PRACTICE, 0, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var shoe := loop.get_shoe()
	shoe.deal_index = pen_dealt + 1
	var before := shoe.cards_dealt()
	loop.begin_hand()
	var after := loop.get_shoe().cards_dealt()
	_expect(after < before, "penetration respected: shoe cut at %.0f%% (before=%d, after=%d)" % [c.penetration * 100.0, before, after])


# --- 5. Mid-hand runout: no count-check prompt, but the shoe counter advances ---
# The emergency reshuffle in _deal_card() (GameLoop.gd) is NOT a quiz-able shoe
# cut: it must not set _count_check_due or emit count_check_due. But it DOES
# run _on_new_shoe(), so shoes_this_session advances. This pins the asymmetry
# vs. the start-of-hand cut (start_or_next_shoe), which triggers the prompt.
func _check_runout_no_count_check() -> void:
	var loop := _make_loop()  # T1: count_check_active = true
	_expect(not loop.is_count_check_due(), "runout asymmetry: no check due before the runout")
	var fired := {"n": 0}
	loop.count_check_due.connect(func(_rc: int): fired.n += 1)
	var shoes_before: int = loop.state.shoes_this_session
	var shoe := loop.get_shoe()
	shoe.deal_index = shoe.deck.size() - 1  # exactly 1 card left
	var c1: CHCard = loop._deal_card()  # the last card of the old shoe
	var c2: CHCard = loop._deal_card()  # triggers the runout reshuffle
	_expect(c1 != null and c2 != null, "runout asymmetry: both deals valid")
	_expect(int(fired.n) == 0, "runout asymmetry: count_check_due must NOT fire on a mid-hand runout, got %d" % fired.n)
	_expect(not loop.is_count_check_due(), "runout asymmetry: runout is not a quiz-able shoe cut")
	_expect(loop.state.shoes_this_session > shoes_before, "runout asymmetry: shoe counter advanced (%d -> %d)" % [shoes_before, loop.state.shoes_this_session])


# --- 6. Mid-hand runout re-syncs the deck estimate on multi-deck shoes ---
# count.reset() defaults decks_remaining to 1.0; on a multi-deck shoe the
# runout path must re-sync it to the reshuffled shoe's estimate (full deck
# count), or the true count is inflated N-fold for the rest of the hand.
func _check_runout_multideck_estimate() -> void:
	var c := CHTableConfig.for_tier(4)  # 4 decks, estimation step 0.5
	var state := CHGameState.new()
	state.start_session(4, CHGameState.MODE_PRACTICE, 0, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), SEED)
	var count: CHCountEngine = loop.get_count()
	var shoe := loop.get_shoe()
	count.running_count = 5
	count.decks_remaining = 2.0
	shoe.deal_index = shoe.deck.size()  # fully exhausted -> forced runout
	# After the runout reshuffle, deal_index=0 and 208/52 = 4.0 decks remain.
	# At the 0.5 estimation step this rounds to 4.0.
	var expected: float = 4.0
	var cc: CHCard = loop._deal_card()
	_expect(cc != null, "multideck: runout deal returned null")
	_expect(count.running_count == 0, "multideck: RC reset, got %d" % count.running_count)
	_expect(absf(count.decks_remaining - expected) < 0.001,
		"multideck: decks_remaining re-synced to full estimate after runout, got %s" % count.decks_remaining)
