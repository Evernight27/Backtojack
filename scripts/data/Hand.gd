class_name CHHand
extends RefCounted

var cards: Array[CHCard] = []
# True once this hand was created from a split. Drives the "split aces get one
# card only" and re-split-limit rules. Not set on the original (pre-split) hand.
var is_split_hand: bool = false
# True when this hand came from a split of aces and (per
# CHTableConfig.split_aces_one_card_only) must stop after its single dealt card.
var split_ace: bool = false


func card_count() -> int:
	return cards.size()


func add_card(card: CHCard) -> void:
	cards.append(card)


func total() -> int:
	var t := 0
	var aces := 0
	for c in cards:
		if c.is_ace():
			aces += 1
			t += 11
		elif c.rank >= 10:
			t += 10
		else:
			t += c.rank
	while t > 21 and aces > 0:
		t -= 10
		aces -= 1
	return t


func is_soft() -> bool:
	var t := 0
	var aces := 0
	for c in cards:
		if c.is_ace():
			aces += 1
			t += 11
		elif c.rank >= 10:
			t += 10
		else:
			t += c.rank
	while t > 21 and aces > 0:
		t -= 10
		aces -= 1
	return aces > 0


func is_bust() -> bool:
	return total() > 21


func is_pair() -> bool:
	if cards.size() != 2:
		return false
	return cards[0].rank == cards[1].rank


func is_blackjack() -> bool:
	if cards.size() != 2:
		return false
	var a: CHCard = cards[0]
	var b: CHCard = cards[1]
	if total() != 21:
		return false
	return (a.is_ace() and b.is_ten_value()) or (b.is_ace() and a.is_ten_value())


static func dealer_upcard_key(rank: int) -> int:
	if rank >= 10 and rank <= 13:
		return 10
	return rank
