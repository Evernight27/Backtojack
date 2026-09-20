class_name CHCard
extends RefCounted

const SUITS: Array[String] = ["S", "H", "D", "C"]

var suit: String
var rank: int  # 2..14, 14 == Ace
var seen: bool = false


func _init(p_suit: String = "S", p_rank: int = 2) -> void:
	suit = p_suit
	rank = p_rank


func is_ace() -> bool:
	return rank == 14


func is_ten_value() -> bool:
	return rank >= 10 and rank <= 13


# Rank-only label for the card face corner (no suit), e.g. "A", "10", "J".
func rank_text() -> String:
	match rank:
		11:
			return "J"
		12:
			return "Q"
		13:
			return "K"
		14:
			return "A"
	return str(rank)


# Returns the unicode suit symbol for display.
func suit_symbol() -> String:
	match suit:
		"S":
			return "\u2660"
		"H":
			return "\u2665"
		"D":
			return "\u2666"
		"C":
			return "\u2663"
	return "?"


# Red suits (hearts, diamonds) vs black suits (spades, clubs).
func is_red() -> bool:
	return suit == "H" or suit == "D"


# Per-system card count value. The default ("hi_lo") is the canonical teaching
# system. KO and Hi-Opt II follow the same per-card pattern so the shoe can be
# counted with any unlocked system without a second card class.
func count_value(system: String = "hi_lo") -> int:
	match system:
		"ko":
			if rank >= 2 and rank <= 6:
				return 1
			if rank >= 7 and rank <= 9:
				return 0
			if rank == 14:
				return 0
			return -1
		"hi_opt_ii":
			# Hi-Opt II: +1 on 2-4, 0 on 5-7 and the Ace, -1 on 8-10.
			if rank >= 2 and rank <= 4:
				return 1
			if rank >= 5 and rank <= 7:
				return 0
			if rank == 14:
				return 0
			return -1
		_:
			if rank >= 2 and rank <= 6:
				return 1
			if rank >= 7 and rank <= 9:
				return 0
			return -1
