extends SceneTree
# Headless validation for CHHand — the value/predicate primitives every other
# tool and the strategy engine assume but none checks in isolation. Pins:
#
#   1. total() — ace-down (11->1) resolution, 10-value bucketing, bust totals.
#   2. is_soft() — a live 11-ace remains (incl. multi-ace soft totals).
#   3. is_bust() — total() > 21.
#   4. is_pair() — exactly two cards of equal rank.
#   5. is_blackjack() — two-card 21 from an ace + a ten-value card.
#   6. dealer_upcard_key() — ten-value ranks collapse to 10.
#   7. CHCard display helpers — rank_text(), suit_symbol(), is_red() (the
#      card-face primitives the scene's card rendering is built from).
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


# Builds a CHHand from a list of ranks (14 == Ace, 10-13 are the ten-values).
func _hand(ranks: Array) -> CHHand:
	var h := CHHand.new()
	for r in ranks:
		h.add_card(CHCard.new("S", int(r)))
	return h


func _init() -> void:
	_check_totals()
	_check_soft()
	_check_bust()
	_check_pair()
	_check_blackjack()
	_check_upcard_key()
	_check_card_display()
	_finish()


# --- 1. total(): ace-down + 10-value bucketing + bust. ---
func _check_totals() -> void:
	# Two-card and three-card totals, with the ace dropped to 1 when needed.
	_expect(_hand([14, 13]).total() == 21, "A+K = 21, got %d" % _hand([14, 13]).total())
	_expect(_hand([10, 10]).total() == 20, "10+10 = 20, got %d" % _hand([10, 10]).total())
	_expect(_hand([14, 9]).total() == 20, "A+9 = 20, got %d" % _hand([14, 9]).total())
	_expect(_hand([5, 5, 5]).total() == 15, "5+5+5 = 15, got %d" % _hand([5, 5, 5]).total())
	# Ace down: A+9+8 = 28 -> 18 hard.
	_expect(_hand([14, 9, 8]).total() == 18, "A+9+8 = 18, got %d" % _hand([14, 9, 8]).total())
	# Two aces: A+A+9 = 31 -> 21 (one ace stays 11, one drops to 1).
	_expect(_hand([14, 14, 9]).total() == 21, "A+A+9 = 21, got %d" % _hand([14, 14, 9]).total())
	# Ten-value bucketing: J+Q+K = 30 (bust; no aces to drop).
	_expect(_hand([11, 12, 13]).total() == 30, "J+Q+K = 30, got %d" % _hand([11, 12, 13]).total())
	# Soft 17: A+6 = 11+6 = 17, stays soft.
	_expect(_hand([14, 6]).total() == 17, "A+6 = 17 soft, got %d" % _hand([14, 6]).total())
	# Six aces + 5 collapses to a soft 21 (never bust).
	_expect(_hand([14, 14, 14, 14, 14, 14, 5]).total() == 21,
		"AxA6 + 5 = 21, got %d" % _hand([14, 14, 14, 14, 14, 14, 5]).total())


# --- 2. is_soft(): a live 11-ace remains. ---
func _check_soft() -> void:
	_expect(_hand([14, 10]).is_soft(), "A+K is soft")
	_expect(_hand([14, 9]).is_soft(), "A+9 is soft 20")
	_expect(not _hand([10, 10]).is_soft(), "10+10 is hard")
	_expect(not _hand([5, 5, 10]).is_soft(), "5+5+K is hard 20")
	# A+A+9: one ace stays 11 -> soft 21.
	_expect(_hand([14, 14, 9]).is_soft(), "A+A+9 is soft 21")
	# A+K+K drops the ace to 1 (21) -> hard.
	_expect(not _hand([14, 10, 10]).is_soft(), "A+K+K is hard 21")
	# No aces at all can never be soft.
	_expect(not _hand([3, 4, 5]).is_soft(), "3+4+5 is hard")


# --- 3. is_bust(). ---
func _check_bust() -> void:
	_expect(_hand([10, 10, 5]).is_bust(), "10+10+5 = 25 is bust")
	_expect(not _hand([10, 10]).is_bust(), "20 is not bust")
	_expect(not _hand([14, 14, 14, 14, 14, 14, 5]).is_bust(),
		"six aces + 5 is a soft 21, not a bust")
	_expect(not _hand([14, 10]).is_bust(), "21 is not bust")


# --- 4. is_pair(): exactly two equal-rank cards. ---
func _check_pair() -> void:
	_expect(_hand([9, 9]).is_pair(), "9+9 is a pair")
	_expect(_hand([14, 14]).is_pair(), "A+A is a pair")
	_expect(not _hand([9, 10]).is_pair(), "9+10 is not a pair")
	_expect(not _hand([10, 13]).is_pair(), "10+K is not a pair (different ranks)")
	_expect(not _hand([9, 9, 9]).is_pair(), "three 9s is not a two-card pair")
	_expect(not _hand([9]).is_pair(), "a single card is not a pair")


# --- 5. is_blackjack(): two-card ace + ten-value 21. ---
func _check_blackjack() -> void:
	_expect(_hand([14, 10]).is_blackjack(), "A+K is a blackjack")
	_expect(_hand([10, 14]).is_blackjack(), "K+A is a blackjack")
	_expect(_hand([14, 13]).is_blackjack(), "A+K(rank13) is a blackjack")
	_expect(not _hand([14, 9]).is_blackjack(), "A+9 (20) is not a blackjack")
	_expect(not _hand([10, 10]).is_blackjack(), "10+10 (20) is not a blackjack")
	_expect(not _hand([10, 10, 1]).is_blackjack(), "10+10+A (three cards) is not a blackjack")


# --- 6. dealer_upcard_key(): ten-values collapse to 10. ---
func _check_upcard_key() -> void:
	_expect(CHHand.dealer_upcard_key(10) == 10, "10 -> 10")
	_expect(CHHand.dealer_upcard_key(11) == 10, "J -> 10")
	_expect(CHHand.dealer_upcard_key(12) == 10, "Q -> 10")
	_expect(CHHand.dealer_upcard_key(13) == 10, "K -> 10")
	_expect(CHHand.dealer_upcard_key(9) == 9, "9 -> 9")
	_expect(CHHand.dealer_upcard_key(2) == 2, "2 -> 2")


# --- 7. CHCard display helpers: the card-face primitives. ---
func _check_card_display() -> void:
	# rank_text(): numeric ranks stay numeric; face ranks use letters.
	_expect(CHCard.new("S", 2).rank_text() == "2", "rank_text 2")
	_expect(CHCard.new("S", 10).rank_text() == "10", "rank_text 10")
	_expect(CHCard.new("S", 11).rank_text() == "J", "rank_text J")
	_expect(CHCard.new("S", 12).rank_text() == "Q", "rank_text Q")
	_expect(CHCard.new("S", 13).rank_text() == "K", "rank_text K")
	_expect(CHCard.new("S", 14).rank_text() == "A", "rank_text A")
	# suit_symbol(): unicode suit pips for all four suits.
	_expect(CHCard.new("S", 5).suit_symbol() == "\u2660", "spade symbol")
	_expect(CHCard.new("H", 5).suit_symbol() == "\u2665", "heart symbol")
	_expect(CHCard.new("D", 5).suit_symbol() == "\u2666", "diamond symbol")
	_expect(CHCard.new("C", 5).suit_symbol() == "\u2663", "club symbol")
	# is_red(): hearts and diamonds are red; spades and clubs are black.
	_expect(CHCard.new("H", 5).is_red(), "hearts are red")
	_expect(CHCard.new("D", 5).is_red(), "diamonds are red")
	_expect(not CHCard.new("S", 5).is_red(), "spades are black")
	_expect(not CHCard.new("C", 5).is_red(), "clubs are black")


func _finish() -> void:
	if _failures.is_empty():
		print("hand_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("hand_check: %d failure(s)" % _failures.size())
		quit(1)
