class_name CHStrategyEngine
extends RefCounted
# Blackjack basic strategy + rule-variant diffs + a subset of Illustrious 18
# deviation plays. Rule-variant behavior lives here, keyed off CHTableConfig
# flags, so there is a single home for strategy logic.

# --- Tunable deviation thresholds (exported for future tuning) ---
# Full Illustrious 18 (S17, 3:2, DAS).
# High-TC stands: basic says hit, deviate to stand when TC is high.
const DEV_16V10_STAND_TC: int = 3
const DEV_15V10_STAND_TC: int = 2
const DEV_14V10_STAND_TC: int = 3
const DEV_13V10_STAND_TC: int = 3
const DEV_15V9_STAND_TC: int = 2
const DEV_16V9_STAND_TC: int = 2
const DEV_14V9_STAND_TC: int = 2
const DEV_13V9_STAND_TC: int = 2
# Low-TC: stand instead of double.
const DEV_11V10_STAND_TC: int = -1
# Low-TC hits: basic says stand, deviate to hit when TC is low.
const DEV_12V4_HIT_TC: int = -1
const DEV_13V4_HIT_TC: int = -2
const DEV_14V4_HIT_TC: int = -2
const DEV_12V5_HIT_TC: int = -1
const DEV_13V5_HIT_TC: int = -2
const DEV_14V5_HIT_TC: int = -2
const DEV_12V6_HIT_TC: int = -2
# Soft hand: stand instead of hit at high TC.
const DEV_S19V9_STAND_TC: int = 2
const DEV_S19V10_STAND_TC: int = 2
const INSURANCE_TC_THRESHOLD: int = 3


# Returns the best basic-strategy play for the given hand against the dealer upcard.
# `tc_floor` is the canonical floored true count (0 when not counting).
func best_play(hand: CHHand, dealer_key: int, config: CHTableConfig, tc_floor: int = 0) -> String:
	var play := _basic_play(hand, dealer_key, config)
	play = _apply_surrender(play, hand, dealer_key, config)
	play = _apply_h17(play, hand, dealer_key, config)
	play = _apply_deviation(play, hand, dealer_key, tc_floor, config)
	return _enforce_double_legality(play, hand, config)


func best_play_no_split(hand: CHHand, dealer_key: int, config: CHTableConfig, tc_floor: int = 0) -> String:
	var play: String
	if hand.is_soft():
		play = _soft_play(hand.total(), dealer_key, config)
	else:
		play = _hard_play(hand.total(), dealer_key, config)
	play = _apply_surrender(play, hand, dealer_key, config)
	play = _apply_h17(play, hand, dealer_key, config)
	play = _apply_deviation(play, hand, dealer_key, tc_floor, config)
	return _enforce_double_legality(play, hand, config)


# A double is only legal on a fresh two-card hand, and only when the table
# allows it. Doubles on a split hand additionally require DAS (double after
# split). Any other "double" from the basic tables degrades to a hit so the
# engine is safe to call regardless of caller-side guards.
func _enforce_double_legality(play: String, hand: CHHand, config: CHTableConfig) -> String:
	if play != "double":
		return play
	if not config.allows_double:
		return "hit"
	if hand.card_count() != 2:
		return "hit"
	if hand.is_split_hand and not config.allows_double_after_split:
		return "hit"
	return play


func _basic_play(hand: CHHand, dk: int, config: CHTableConfig) -> String:
	if hand.is_pair():
		return _pair_play(hand, dk, config)
	if hand.is_soft():
		return _soft_play(hand.total(), dk, config)
	return _hard_play(hand.total(), dk, config)


func _hard_play(total: int, dk: int, _config: CHTableConfig) -> String:
	match total:
		17, 18, 19, 20, 21:
			return "stand"
		16:
			if dk >= 2 and dk <= 6:
				return "stand"
			return "hit"
		15:
			if dk >= 4 and dk <= 6:
				return "stand"
			return "hit"
		14:
			if dk >= 2 and dk <= 6:
				return "stand"
			return "hit"
		13:
			if dk >= 2 and dk <= 6:
				return "stand"
			return "hit"
		12:
			if dk >= 4 and dk <= 6:
				return "stand"
			return "hit"
		11:
			if dk <= 10:
				return "double"
			return "hit"
		10:
			if dk >= 2 and dk <= 9:
				return "double"
			return "hit"
		9:
			if dk >= 3 and dk <= 6:
				return "double"
			return "hit"
		_:
			return "hit"


func _soft_play(total: int, dk: int, _config: CHTableConfig) -> String:
	match total:
		21:
			return "stand"
		20:
			return "stand"
		19:
			if dk >= 2 and dk <= 6:
				return "stand"
			return "hit"
		18:
			if dk == 2 or dk == 7 or dk == 8:
				return "stand"
			if dk >= 3 and dk <= 6:
				return "double"
			return "hit"
		17:
			if dk >= 3 and dk <= 7:
				return "double"
			return "hit"
		16:
			if dk >= 3 and dk <= 6:
				return "double"
			return "hit"
		15:
			if dk >= 4 and dk <= 6:
				return "double"
			return "hit"
		_:
			return "hit"


func _pair_play(hand: CHHand, dk: int, config: CHTableConfig) -> String:
	var rank: int = hand.cards[0].rank
	match rank:
		14:  # aces
			return "split"
		10, 11, 12, 13:  # all ten-value pairs: never split
			return "stand"
		9:
			if dk >= 2 and dk <= 9:
				return "split"
			return "hit"
		8:
			return "split"  # 8s: split vs every upcard (standard BS)
		7:
			if dk >= 2 and dk <= 7:
				return "split"
			return "hit"
		6:
			# S17/DAS: split 6s vs 2-7. H17: split only vs 4-7.
			var lo: int = 4 if config.dealer_hits_soft_17 else 2
			if dk >= lo and dk <= 7:
				return "split"
			return "hit"
		5:
			if dk >= 4 and dk <= 9:
				return "double"
			return "hit"
		4:
			if dk == 5 or dk == 6:
				return "double"
			return "hit"
		3, 2:
			if dk >= 2 and dk <= 7:
				return "split"
			return "hit"
		_:
			return "hit"


# --- Rule-variant diffs ---

# When the dealer hits soft 17, the optimal play for soft 18 changes:
# S17: stand on 7 and 8; H17: hit on 7-8 (the dealer will hit to 18/19/20/21).
func _apply_h17(play: String, hand: CHHand, dk: int, config: CHTableConfig) -> String:
	if not config.dealer_hits_soft_17:
		return play
	if not hand.is_soft():
		return play
	if hand.total() == 18 and (dk == 7 or dk == 8):
		return "hit"
	return play


# Late surrender: give up on hopeless hands to halve the loss. Only a fresh
# two-card hand may be surrendered (it is not available once the hand has
# grown), which mirrors the loop's `_can_surrender` gate. Without this guard a
# three-card 15/16 would be recommended as "surrender" and then degraded to
# "stand" downstream, instead of the correct "hit".
func _apply_surrender(play: String, hand: CHHand, dk: int, config: CHTableConfig) -> String:
	if not config.allows_surrender:
		return play
	if hand.card_count() != 2:
		return play
	if hand.is_soft() or hand.is_pair():
		return play
	var t: int = hand.total()
	# Late-surrender chart (also the baseline for early): surrender the classic
	# marginal hands. Applies to both modes.
	if t == 16 and dk >= 9:
		return "surrender"
	if t == 15 and dk == 10:
		return "surrender"
	# Early surrender (`late_surrender_only == false`): the player surrenders
	# before the dealer peeks, so they are not at risk of a hidden natural
	# voiding the surrender — the +EV set widens to these hands.
	if not config.late_surrender_only:
		if t == 15 and dk == 9:
			return "surrender"
		if t == 14 and dk == 10:
			return "surrender"
		if t == 13 and dk == 10:
			return "surrender"
	return play


# --- Illustrious 18 (full set) ---
# The 18 highest-EV Hi-Lo deviations for S17 / 3:2 / DAS, ranked by EV impact.
# Direction rules:
#   - High TC (few 10s left): dealer less likely to bust, so the player stands
#     more on marginal hard totals and on soft 19 vs 9/10.
#   - Low TC (many 10s left): dealer more likely to bust, so the player hits
#     more on 12-14 vs 4-6 and stands instead of doubling 11 vs 10.
# Pair decisions are left to basic strategy in this subset (pair deviations
# are lower-EV and out of scope for I18).
func _apply_deviation(play: String, hand: CHHand, dk: int, tc: int, config: CHTableConfig) -> String:
	if play == "surrender":
		return play
	if hand.is_pair():
		return play
	# The I18 deviation indices are calibrated for S17 / 3:2 / DAS (see the
	# block comment above). On a dealer-hits-soft-17 table the marginal stands
	# and hits these encode are no longer optimal and, applied to a different
	# counting system's true-count scale, actively make the count a net loss
	# (validated in sim_counting_systems on Tier 5: 6-deck H17 Hi-Opt II). So
	# the deviation layer only applies on S17 tables; H17 tiers fall back to
	# pure basic strategy + bet-sizing, which is at worst neutral.
	if config.dealer_hits_soft_17:
		return play
	var t: int = hand.total()

	# Soft hand: stand instead of hit at high TC.
	if hand.is_soft():
		if t == 19 and dk == 9 and tc >= DEV_S19V9_STAND_TC:
			return "stand"
		if t == 19 and dk == 10 and tc >= DEV_S19V10_STAND_TC:
			return "stand"
		return play

	# --- High TC: stand instead of hit on hard 13-16 vs 9-10 ---
	if t == 16 and dk == 10 and tc >= DEV_16V10_STAND_TC:
		return "stand"
	if t == 15 and dk == 10 and tc >= DEV_15V10_STAND_TC:
		return "stand"
	if t == 14 and dk == 10 and tc >= DEV_14V10_STAND_TC:
		return "stand"
	if t == 13 and dk == 10 and tc >= DEV_13V10_STAND_TC:
		return "stand"
	if t == 16 and dk == 9 and tc >= DEV_16V9_STAND_TC:
		return "stand"
	if t == 15 and dk == 9 and tc >= DEV_15V9_STAND_TC:
		return "stand"
	if t == 14 and dk == 9 and tc >= DEV_14V9_STAND_TC:
		return "stand"
	if t == 13 and dk == 9 and tc >= DEV_13V9_STAND_TC:
		return "stand"

	# --- Low TC: hit instead of stand on hard 12-14 vs 4-6 ---
	if t == 12 and dk == 4 and tc <= DEV_12V4_HIT_TC:
		return "hit"
	if t == 13 and dk == 4 and tc <= DEV_13V4_HIT_TC:
		return "hit"
	if t == 14 and dk == 4 and tc <= DEV_14V4_HIT_TC:
		return "hit"
	if t == 12 and dk == 5 and tc <= DEV_12V5_HIT_TC:
		return "hit"
	if t == 13 and dk == 5 and tc <= DEV_13V5_HIT_TC:
		return "hit"
	if t == 14 and dk == 5 and tc <= DEV_14V5_HIT_TC:
		return "hit"
	if t == 12 and dk == 6 and tc <= DEV_12V6_HIT_TC:
		return "hit"

	# --- Low TC: stand instead of double on 11 vs 10 ---
	if t == 11 and dk == 10 and tc <= DEV_11V10_STAND_TC:
		return "stand"

	return play


# Insurance: take when the floored true count reaches the threshold. Used by the
# loop's optimal_action() (PHASE_INSURANCE) and by sim_validate for the counting
# phase; CHGameLoop drives the PHASE_INSURANCE prompt from this result.
func should_take_insurance(tc_floor: int) -> bool:
	return tc_floor >= INSURANCE_TC_THRESHOLD


# True when the I18 deviation layer changes the basic-strategy play for this
# hand at the given true count. Used by the heat system: making a counting
# deviation is a tell (a player is playing differently from basic strategy in
# a way only a counter would). Compares the basic play against the deviation-
# layer-applied play — the exact I18 delta. Pairs never deviate (the deviation
# layer early-returns for them), so this is naturally false for pairs.
func is_counting_deviation(hand: CHHand, dealer_key: int, config: CHTableConfig, tc_floor: int) -> bool:
	# Measure the I18 delta on top of the full non-deviation pipeline (basic +
	# surrender + H17), mirroring best_play's layer order exactly. Diffing the
	# deviation layer against raw _basic_play only would mis-report a counting
	# deviation on hands whose non-deviation play is "surrender" (a basic-
	# strategy play, not a counting tell) — e.g. a two-card 16/15 vs 9/10 at a
	# high count: the engine correctly surrenders, _apply_deviation returns
	# "surrender" unchanged, so no tell should fire.
	var base := _basic_play(hand, dealer_key, config)
	base = _apply_surrender(base, hand, dealer_key, config)
	base = _apply_h17(base, hand, dealer_key, config)
	var with_dev := _apply_deviation(base, hand, dealer_key, tc_floor, config)
	return with_dev != base
