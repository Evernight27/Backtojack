class_name CHSplitResolver
extends RefCounted
# Resolves the *structure* of split hands for one initial two-card player hand.
# It returns the list of terminal hands in play order, dealing the follow-up
# split cards from the supplied shoe.
#
# It deliberately does NOT make hit/stand/double decisions: those are made
# per-hand by the strategy engine (via best_play_no_split) during the actual
# play. That keeps the split rules (split aces get one card only, resplit cap,
# no resplit of aces, DAS-gated doubling) in a single home that both the
# headless sim and the future game loop share.
#
# Wager/betting is also out of scope here; the caller assigns a base bet to
# each returned hand and doubles it per-hand as the engine dictates.

# Running total of how many hands the current resolve() call has produced.
# Reset at the start of every resolve(); a split increments it by one (a node
# becomes two hands). The resplit cap is "total hands <= max_split_hands".
var _total_hands: int = 1


# Resolves `starting` (the player's first two cards) against dealer upcard
# key `up_key`. If splitting is disabled, `starting` is not a pair, or the
# engine would not split it, returns [starting] unchanged.
func resolve(
	starting: CHHand,
	up_key: int,
	shoe: CHShoeManager,
	config: CHTableConfig,
	engine: CHStrategyEngine,
	tc_floor: int = 0
) -> Array[CHHand]:
	_total_hands = 1
	if not config.allows_split or not starting.is_pair():
		return [starting]
	return _expand(starting, up_key, shoe, config, engine, tc_floor)


# Decides whether `hand` should be split: the engine must say "split" and, if
# this is a re-split of an already-split hand, re-splits must be allowed.
func _would_split(
	hand: CHHand,
	up_key: int,
	config: CHTableConfig,
	engine: CHStrategyEngine,
	tc_floor: int
) -> bool:
	if hand.is_split_hand and not _resplit_allowed(hand, config):
		return false
	var play := engine.best_play(hand, up_key, config, tc_floor)
	return play == "split"


# Aces are never re-split. All other ranks may re-split up to the cap.
func _resplit_allowed(hand: CHHand, _config: CHTableConfig) -> bool:
	return hand.cards[0].rank != 14


# Recursively expands `hand` into its terminal sub-hands.
func _expand(
	hand: CHHand,
	up_key: int,
	shoe: CHShoeManager,
	config: CHTableConfig,
	engine: CHStrategyEngine,
	tc_floor: int
) -> Array[CHHand]:
	if not _would_split(hand, up_key, config, engine, tc_floor):
		return [hand]
	# Resplit cap: splitting this node would push total hands over the limit.
	if _total_hands + 1 > config.max_split_hands:
		return [hand]
	_total_hands += 1

	var c1: CHCard = hand.cards[0]
	var c2: CHCard = hand.cards[1]
	var a := CHHand.new()
	a.add_card(c1)
	a.is_split_hand = true
	var b := CHHand.new()
	b.add_card(c2)
	b.is_split_hand = true

	var is_ace := c1.rank == 14
	if is_ace and config.split_aces_one_card_only:
		# Split aces: exactly one card each, then they stand. No re-split.
		a.add_card(shoe.deal())
		b.add_card(shoe.deal())
		a.split_ace = true
		b.split_ace = true
		return [a, b]

	# Normal split: one card to each, then allow each sub-hand to be a resplit
	# candidate in turn.
	a.add_card(shoe.deal())
	b.add_card(shoe.deal())
	var out: Array[CHHand] = []
	out.append_array(_expand(a, up_key, shoe, config, engine, tc_floor))
	out.append_array(_expand(b, up_key, shoe, config, engine, tc_floor))
	return out
