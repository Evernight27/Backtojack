extends SceneTree
# Headless validation for CHShoeManager — the one system with no dedicated
# tool of its own. Pins the three invariants every other tool assumes but
# never checks directly:
#
#   1. Composition: build(config) holds exactly deck_count*52 cards, each
#      (suit, rank) appearing exactly deck_count times — a shuffle must never
#      duplicate or drop a card.
#   2. Penetration boundary: penetration_reached() flips at exactly
#      ceil(total * penetration) dealt cards, and should_reshuffle() /
#      is_empty() agree at the boundaries.
#   3. Determinism + reset: two shoes built with the same seed are
#      order-identical; reshuffle(seed) with the same seed reproduces that
#      order and resets the deal index; a different seed changes the order.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906

var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	_check_composition()
	_check_penetration_boundary()
	_check_determinism_and_reset()
	_check_deck_estimate()
	_finish()


# A (suit, rank) -> count tally helper over a shoe's deck.
func _tally(deck: Array[CHCard]) -> Dictionary:
	var tally := {}
	for c in deck:
		var key := c.suit + "-" + str(c.rank)
		tally[key] = int(tally.get(key, 0)) + 1
	return tally


# --- 1. Composition: a 2-deck shoe holds exactly two of every card. ---
func _check_composition() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 2
	var shoe := CHShoeManager.new()
	shoe.build(c, SEED)
	_expect(shoe.total_cards() == 104, "2-deck shoe holds 104 cards, got %d" % shoe.total_cards())
	var tally := _tally(shoe.deck)
	_expect(tally.size() == 52, "52 distinct cards present, got %d" % tally.size())
	var per_card_ok := true
	for k in tally:
		if int(tally[k]) != 2:
			per_card_ok = false
	_expect(per_card_ok, "each of the 52 cards appears exactly twice in a 2-deck shoe")
	# A single deck is exactly one full set.
	var one := CHTableConfig.new()
	one.deck_count = 1
	var s1 := CHShoeManager.new()
	s1.build(one, SEED)
	var t1 := _tally(s1.deck)
	var one_ok := t1.size() == 52
	for k in t1:
		if int(t1[k]) != 1:
			one_ok = false
	_expect(one_ok, "1-deck shoe holds exactly one of each of the 52 cards")


# --- 2. Penetration boundary flips at ceil(total * penetration). ---
func _check_penetration_boundary() -> void:
	# 52-card shoe, 0.70 penetration -> 36.4 cards: 36 dealt is not yet, 37 is.
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.penetration = 0.70
	var shoe := CHShoeManager.new()
	shoe.build(c, SEED)
	var dealt := 0
	while dealt < 36:
		_expect(shoe.deal() != null, "deal %d returned a card" % (dealt + 1))
		dealt += 1
	_expect(not shoe.penetration_reached(), "36 dealt (<36.4) should not reach penetration")
	_expect(not shoe.should_reshuffle(), "36 dealt should not trigger reshuffle")
	shoe.deal()
	dealt += 1
	_expect(shoe.penetration_reached(), "37 dealt (>=36.4) reaches penetration")
	_expect(shoe.should_reshuffle(), "should_reshuffle true at 37 dealt")
	# is_empty stays false until the whole shoe is dealt.
	_expect(not shoe.is_empty(), "shoe not empty at 37 dealt")
	# Deal to exhaustion: is_empty flips exactly at 52.
	while not shoe.is_empty():
		_expect(shoe.deal() != null, "deal within exhaustion")
	_expect(shoe.is_empty(), "is_empty true once the shoe is fully dealt")
	_expect(shoe.cards_remaining() == 0, "cards_remaining is 0 when empty, got %d" % shoe.cards_remaining())


# --- 3. Determinism + reset: same seed -> same order; reshuffle resets. ---
func _check_determinism_and_reset() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1

	var a := CHShoeManager.new()
	a.build(c, SEED)
	var b := CHShoeManager.new()
	b.build(c, SEED)

	var same := a.total_cards() == b.total_cards()
	for i in a.total_cards():
		if a.deck[i].suit != b.deck[i].suit or a.deck[i].rank != b.deck[i].rank:
			same = false
	_expect(same, "two shoes built with the same seed are order-identical")

	# Deal some cards, then reshuffle with the same seed: must reproduce the
	# original order exactly and reset the deal index.
	var order_before := a.deck.duplicate()
	a.deal()
	a.deal()
	a.deal()
	a.reshuffle(SEED)
	_expect(a.cards_dealt() == 0, "reshuffle resets deal_index to 0, got %d" % a.cards_dealt())
	_expect(a.cards_remaining() == a.total_cards(), "reshuffle restores full card count")
	var restored := true
	for i in a.total_cards():
		if a.deck[i].suit != order_before[i].suit or a.deck[i].rank != order_before[i].rank:
			restored = false
	_expect(restored, "reshuffle(same seed) reproduces the exact prior order")

	# A different seed yields a different full order (a full-permutation match
	# across distinct seeds is effectively impossible; safe to pin).
	var d := CHShoeManager.new()
	d.build(c, SEED + 1)
	var different := false
	for i in d.total_cards():
		if d.deck[i].suit != a.deck[i].suit or d.deck[i].rank != a.deck[i].rank:
			different = true
			break
	_expect(different, "distinct seeds produce different full deck orders")


# --- 4. decks_remaining_estimate honours coarseness and the min-one-step floor. ---
func _check_deck_estimate() -> void:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.deck_estimation_rounding = 0.5
	var shoe := CHShoeManager.new()
	shoe.build(c, SEED)
	# Fresh 52/52 = 1.0 exact deck -> estimate 1.0.
	_expect(absf(shoe.decks_remaining_estimate() - 1.0) < 1e-6,
		"fresh 1-deck estimate is 1.0, got %f" % shoe.decks_remaining_estimate())
	# Deal 26 -> 26/52 = 0.5 decks; on a 0.5 step that rounds to exactly 0.5.
	for i in 26:
		shoe.deal()
	_expect(absf(shoe.decks_remaining_estimate() - 0.5) < 1e-6,
		"26 cards left on a 0.5 step -> 0.5, got %f" % shoe.decks_remaining_estimate())
	# A nearly-drained shoe must never estimate 0 decks (min-one-step floor).
	for i in range(1, 52):
		shoe.deal()
	var est_low: float = shoe.decks_remaining_estimate()
	_expect(est_low >= 0.5 and est_low <= 1.0,
		"1 card left floors to at least one step (0.5), got %f" % est_low)


func _finish() -> void:
	if _failures.is_empty():
		print("shoe_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("shoe_check: %d failure(s)" % _failures.size())
		quit(1)
