class_name CHShoeManager
extends RefCounted
# Builds, shuffles, and deals a multi-deck shoe. Owns penetration tracking and
# reshuffle timing. The player-facing deck estimate uses the table's
# deck_estimation_rounding (coarser-to-finer across tiers is a difficulty lever).

var config: CHTableConfig
var deck: Array[CHCard] = []
var deal_index: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func build(p_config: CHTableConfig, p_seed: int = -1) -> void:
	config = p_config
	_rebuild(p_seed)


func _rebuild(p_seed: int) -> void:
	deck.clear()
	for _d in range(config.deck_count):
		for s in CHCard.SUITS:
			for r in range(2, 15):
				deck.append(CHCard.new(s, r))
	deal_index = 0
	if p_seed >= 0:
		_rng.seed = p_seed
	else:
		_rng.randomize()
	_fisher_yates()


func _fisher_yates() -> void:
	for i in range(deck.size() - 1, 0, -1):
		var j := int(_rng.randf_range(0.0, float(i)))
		var tmp = deck[i]
		deck[i] = deck[j]
		deck[j] = tmp


func total_cards() -> int:
	return deck.size()


func cards_remaining() -> int:
	return deck.size() - deal_index


func cards_dealt() -> int:
	return deal_index


func is_empty() -> bool:
	return cards_remaining() <= 0


# Penetration is a fraction of the shoe that must be dealt before reshuffle.
func penetration_reached() -> bool:
	if config == null:
		return true
	return float(cards_dealt()) >= float(total_cards()) * config.penetration


func should_reshuffle() -> bool:
	return is_empty() or penetration_reached()


# Deals the next card without marking it seen. Returns null when exhausted;
# callers must check should_reshuffle() and reshuffle() as appropriate.
func deal() -> CHCard:
	if is_empty():
		return null
	var c: CHCard = deck[deal_index]
	deal_index += 1
	return c


func reshuffle(p_seed: int = -1) -> void:
	_rebuild(p_seed)


func remaining_decks_exact() -> float:
	return float(cards_remaining()) / 52.0


# The player's deck estimate, rounded to the table's coarseness step.
# Minimum one step so true-count division never divides by zero.
func decks_remaining_estimate() -> float:
	var step := config.deck_estimation_rounding if config != null else 1.0
	if step <= 0.0:
		step = 1.0
	var est := remaining_decks_exact()
	var stepped := roundf(est / step) * step
	if stepped < step:
		stepped = step
	return stepped
