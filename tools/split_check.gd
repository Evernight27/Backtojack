extends SceneTree
# Headless structural tests for CHSplitResolver (M2).
#
# These verify the *split structure* the resolver produces, independent of the
# hit/stand/double decisions the engine makes later:
#   1. Split aces receive exactly one card each and are never re-split, even if
#      the dealt cards form a pair of aces.
#   2. With max_split_hands = 2, a 7,7 that would re-split is capped at 2 hands.
#   3. With max_split_hands = 4, a 7,7 that keeps re-splitting fills to 4 hands.
#   4. Tens are never split (K,K stays one hand).
#   5. With allows_split = false, a pair is returned unsplit.
#   6. A non-pair is returned unsplit.
#
# Card order is rigged directly on the shoe so results are deterministic.
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.


var _failures: Array[String] = []


func _init() -> void:
	_check_split_aces_one_card()
	_check_resplit_cap_two()
	_check_resplit_cap_four()
	_check_no_split_tens()
	_check_no_split_disabled()
	_check_non_pair()

	if _failures.is_empty():
		print("split_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("split_check: %d failure(s)" % _failures.size())
		quit(1)


func _make_config() -> CHTableConfig:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.blackjack_payout = 1.5
	c.allows_double = true
	c.allows_split = true
	c.max_split_hands = 4
	c.split_aces_one_card_only = true
	c.allows_double_after_split = true
	return c


func _pair_hand(rank: int) -> CHHand:
	var h := CHHand.new()
	h.add_card(CHCard.new("S", rank))
	h.add_card(CHCard.new("H", rank))
	return h


# Builds a shoe whose deal order is exactly the given rank sequence.
func _rigged_shoe(config: CHTableConfig, ranks: Array) -> CHShoeManager:
	var shoe := CHShoeManager.new()
	shoe.config = config
	shoe.deck.clear()
	var suits := ["S", "H", "D", "C"]
	for i in range(ranks.size()):
		shoe.deck.append(CHCard.new(suits[i % 4], int(ranks[i])))
	shoe.deal_index = 0
	return shoe


func _check_split_aces_one_card() -> void:
	var cfg := _make_config()
	var engine := CHStrategyEngine.new()
	var resolver := CHSplitResolver.new()
	# Four aces in the deal stream: even though each ace hand lands as a pair of
	# aces, the one-card-only rule must stop it after a single card.
	var shoe := _rigged_shoe(cfg, [14, 14, 14, 14])
	var hands := resolver.resolve(_pair_hand(14), 5, shoe, cfg, engine, 0)
	var ok := hands.size() == 2
	if ok:
		for h in hands:
			if h.card_count() != 2 or not h.split_ace or not h.is_split_hand:
				ok = false
	if ok:
		print("PASS  split aces: 2 hands, one card each, no re-split")
	else:
		_failures.append("aces: expected 2 one-card split_ace hands, got %d" % hands.size())


func _check_resplit_cap_two() -> void:
	var cfg := _make_config()
	cfg.max_split_hands = 2
	var engine := CHStrategyEngine.new()
	var resolver := CHSplitResolver.new()
	# Six 7s: the split children would each re-split, but the cap must stop at 2.
	var shoe := _rigged_shoe(cfg, [7, 7, 7, 7, 7, 7])
	var hands := resolver.resolve(_pair_hand(7), 5, shoe, cfg, engine, 0)
	var ok := hands.size() == 2
	if ok:
		for h in hands:
			if not h.is_pair() or not h.is_split_hand:
				ok = false
	if ok:
		print("PASS  resplit cap=2: 7,7 capped at 2 terminal hands")
	else:
		_failures.append("cap=2: expected 2 hands, got %d" % hands.size())


func _check_resplit_cap_four() -> void:
	var cfg := _make_config()  # max_split_hands = 4
	var engine := CHStrategyEngine.new()
	var resolver := CHSplitResolver.new()
	var shoe := _rigged_shoe(cfg, [7, 7, 7, 7, 7, 7])
	var hands := resolver.resolve(_pair_hand(7), 5, shoe, cfg, engine, 0)
	var ok := hands.size() == 4
	if ok:
		for h in hands:
			if not h.is_pair() or not h.is_split_hand:
				ok = false
	if ok:
		print("PASS  resplit cap=4: 7,7 fills to 4 terminal hands")
	else:
		_failures.append("cap=4: expected 4 hands, got %d" % hands.size())


func _check_no_split_tens() -> void:
	var cfg := _make_config()
	var engine := CHStrategyEngine.new()
	var resolver := CHSplitResolver.new()
	var shoe := _rigged_shoe(cfg, [7, 7, 7, 7])
	var hands := resolver.resolve(_pair_hand(13), 5, shoe, cfg, engine, 0)
	var ok := hands.size() == 1 and not hands[0].is_split_hand
	if ok:
		print("PASS  tens not split: K,K stays a single hand")
	else:
		_failures.append("tens: expected 1 unsplit hand, got %d" % hands.size())


func _check_no_split_disabled() -> void:
	var cfg := _make_config()
	cfg.allows_split = false
	var engine := CHStrategyEngine.new()
	var resolver := CHSplitResolver.new()
	var shoe := _rigged_shoe(cfg, [7, 7, 7, 7])
	var hands := resolver.resolve(_pair_hand(7), 5, shoe, cfg, engine, 0)
	var ok := hands.size() == 1 and not hands[0].is_split_hand
	if ok:
		print("PASS  splitting disabled: 7,7 returned unsplit")
	else:
		_failures.append("disabled: expected 1 unsplit hand, got %d" % hands.size())


func _check_non_pair() -> void:
	var cfg := _make_config()
	var engine := CHStrategyEngine.new()
	var resolver := CHSplitResolver.new()
	var shoe := _rigged_shoe(cfg, [7, 7, 7, 7])
	var h := CHHand.new()
	h.add_card(CHCard.new("S", 7))
	h.add_card(CHCard.new("H", 13))  # 7,K
	var hands := resolver.resolve(h, 5, shoe, cfg, engine, 0)
	var ok := hands.size() == 1 and not h.is_split_hand
	if ok:
		print("PASS  non-pair: 7,K returned unsplit")
	else:
		_failures.append("non-pair: expected 1 unsplit hand, got %d" % hands.size())
