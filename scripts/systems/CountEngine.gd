class_name CHCountEngine
extends RefCounted
# Tracks the running count and computes the true count.
# The canonical `true_count_floor()` is the single source of truth for
# display, training materials, and every grading/deviation check.

var running_count: int = 0
var decks_remaining: float = 1.0
var count_system: String = "hi_lo"


# A fresh shoe reads TRUE COUNT 0 for every system — balanced (hi_lo, hi_opt_ii)
# or unbalanced (ko net +8/deck). This is the correct
# "neutral fresh shoe" anchor and matches real counting: a counter sits down at
# a fresh shoe with running count 0 regardless of system. The unbalanced net is
# a property of a full shoe's per-card values, NOT a start offset — applying a
# start offset would shift the whole true-count scale and desync the Hi-Lo-
# calibrated I18/insurance thresholds, making play less faithful, not more.
func reset() -> void:
	running_count = 0
	decks_remaining = 1.0


func set_decks_remaining(d: float) -> void:
	# Floor the estimate to a small positive value so true-count division is
	# always defined; a drained shoe reads as a large count, which is correct.
	decks_remaining = maxf(d, 0.1)


# Records a card as seen. Returns the count value applied (0 if already seen).
func record_card(card: CHCard) -> int:
	if card.seen:
		return 0
	card.seen = true
	var v := card.count_value(count_system)
	running_count += v
	return v


func true_count_value() -> float:
	if decks_remaining <= 0.0:
		return float(running_count)
	return float(running_count) / decks_remaining


# Canonical floor(): used identically for HUD display, training materials,
# and every grading/deviation check. Never compute a second "precise" value
# for grading that disagrees with what's displayed.
func true_count_floor() -> int:
	return int(floorf(true_count_value()))
