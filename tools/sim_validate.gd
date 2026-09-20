extends SceneTree
# Headless house-edge validation for the blackjack engine.
#
#   A. Count invariants: per-card Hi-Lo values + a full 52-card deck nets to a
#      running count of 0 (validates CHCountEngine against CHCard.count_value).
#   B. No-split baseline: player plays best_play_no_split (a pair is played as
#      a normal hand by its hard/soft total). Single deck, S17, 3:2, seed
#      20260906, 500k hands. Documented baseline: 0.954% (post-M60).
#   C. Split-enabled: full split resolution via CHSplitResolver (split aces
#      one-card, resplit capped at max_split_hands, DAS). Edge should drop
#      below the no-split baseline.
#   D. Counting: player maintains a live Hi-Lo running count, sizes bets by the
#      floored true count (bet ramp), and applies I18 deviations at the live TC.
#      Expect a player advantage (negative house edge) — the core thesis of
#      card counting.
#
# Every reshuffle is seeded (SEED + n*7919) so numbers are stable across runs.
#
# PASS == count invariants hold AND all three edges are within their documented
# bands. Exit 0 on pass.

const SEED := 20260906
const TOTAL_HANDS := 500000
# Minimum cards to keep in the wall so a hand can never exhaust the shoe
# mid-play. For a non-counting basic-strategy player the edge is
# penetration-invariant, so cutting the shoe early does not bias the result.
const SHOE_RESERVE := 20
# No-split baseline band for the reconstructed single-deck S17 3:2 policy
# (pairs played as normal hands). Reproduces the documented 0.954% (post-M60).
const EDGE_BAND_MIN: float = 0.40
const EDGE_BAND_MAX: float = 1.40
# Split-enabled band: full split resolution (CHSplitResolver) should push the
# edge below the no-split baseline. Calibrated in M2 (see DECISIONS.md).
const SPLIT_EDGE_BAND_MIN: float = 0.30
const SPLIT_EDGE_BAND_MAX: float = 0.85
# Counting band: a Hi-Lo counter with a bet ramp + I18 deviations should flip
# the edge to a player advantage (negative house edge). Calibrated in M4
# (see DECISIONS.md). Negative == player edge.
const COUNT_EDGE_BAND_MIN: float = -1.20
const COUNT_EDGE_BAND_MAX: float = -0.20

var _engine: CHStrategyEngine
var _resolver: CHSplitResolver
var _count_failures: Array[String] = []


func _init() -> void:
	_engine = CHStrategyEngine.new()
	_resolver = CHSplitResolver.new()
	_check_count_invariants()

	# Phase A: no-split baseline. Pairs are played as normal hands (the M0/M1
	# reconstruction). Reproduces the documented 0.954% (post-M60) for this ruleset/seed.
	var no_split_edge: float = _run_simulation(_base_config(), TOTAL_HANDS)
	var no_split_ok := no_split_edge >= EDGE_BAND_MIN and no_split_edge <= EDGE_BAND_MAX
	if not no_split_ok:
		_count_failures.append("no-split baseline %.3f%% outside band %.2f-%.2f%%" % [no_split_edge, EDGE_BAND_MIN, EDGE_BAND_MAX])

	# Phase B: split-enabled. Full split resolution via CHSplitResolver. The
	# edge should drop below the no-split baseline (splits are +EV).
	var split_cfg := _base_config()
	split_cfg.allows_split = true
	split_cfg.max_split_hands = 4
	split_cfg.split_aces_one_card_only = true
	split_cfg.allows_double_after_split = true
	var split_edge: float = _run_simulation(split_cfg, TOTAL_HANDS)
	var split_ok := split_edge >= SPLIT_EDGE_BAND_MIN and split_edge <= SPLIT_EDGE_BAND_MAX
	if not split_ok:
		_count_failures.append("split edge %.3f%% outside band %.2f-%.2f%%" % [split_edge, SPLIT_EDGE_BAND_MIN, SPLIT_EDGE_BAND_MAX])

	# Phase C: Counting player (Hi-Lo, bet ramp, I18 deviations, insurance at TC).
	var count_cfg := _base_config()
	count_cfg.allows_split = true
	count_cfg.max_split_hands = 4
	count_cfg.split_aces_one_card_only = true
	count_cfg.allows_double_after_split = true
	count_cfg.allows_insurance = true
	var count_edge: float = _run_counting_simulation(count_cfg, TOTAL_HANDS)
	var count_ok := count_edge >= COUNT_EDGE_BAND_MIN and count_edge <= COUNT_EDGE_BAND_MAX
	if not count_ok:
		_count_failures.append("counting edge %.3f%% outside band %.2f-%.2f%%" % [count_edge, COUNT_EDGE_BAND_MIN, COUNT_EDGE_BAND_MAX])

	if _count_failures.is_empty():
		print("sim_validate: PASS (no-split %.3f%%, split %.3f%%, counting %.3f%%)" % [no_split_edge, split_edge, count_edge])
		quit(0)
	else:
		for f in _count_failures:
			print("FAIL  ", f)
		quit(1)


func _base_config() -> CHTableConfig:
	var config := CHTableConfig.new()
	config.deck_count = 1
	config.dealer_hits_soft_17 = false
	config.blackjack_payout = 1.5  # 3:2
	config.allows_surrender = false
	config.allows_insurance = false
	config.allows_double = true
	config.penetration = 1.0
	config.allows_split = false
	return config


# Runs a full deterministic hand loop and returns the measured house edge (%).
func _run_simulation(config: CHTableConfig, total_hands: int) -> float:
	var shoe := CHShoeManager.new()
	shoe.build(config, SEED)

	var net_profit := 0.0
	var units_wagered := 0.0
	var hands := 0
	var reshuffle_count := 0
	while hands < total_hands:
		if shoe.cards_remaining() < SHOE_RESERVE:
			# Deterministic per-reshuffle seed so the baseline is reproducible.
			reshuffle_count += 1
			shoe.reshuffle(SEED + reshuffle_count * 7919)
		var res: Dictionary = _play_hand(shoe, config)
		net_profit += res.profit
		units_wagered += res.wagered
		hands += 1

	var house_edge_pct := (-net_profit / units_wagered) * 100.0
	var label: String = "split" if config.allows_split else "no-split"
	print("sim_validate [%s]: %d hands, net=%.1f, wagered=%.1f, house edge=%.3f%%" % [label, hands, net_profit, units_wagered, house_edge_pct])
	return house_edge_pct


# Runs the counting simulation: the player maintains a Hi-Lo running count across
# the shoe, sizes each bet by the floored true count (bet ramp), and applies I18
# deviations at the live count. Expects a player advantage (negative edge).
#
# Uses the EXACT remaining-decks value (not the coarse tier-1
# decks_remaining_estimate, which for a 1-deck table is pinned at 1.0 so the true
# count never reflects penetration). This measures the textbook true count that a
# competent counter would actually use.
func _run_counting_simulation(config: CHTableConfig, total_hands: int) -> float:
	var count := CHCountEngine.new()
	count.count_system = "hi_lo"
	var shoe := CHShoeManager.new()
	shoe.build(config, SEED)

	var net_profit := 0.0
	var units_wagered := 0.0
	var hands := 0
	var reshuffle_count := 0
	while hands < total_hands:
		if shoe.cards_remaining() < SHOE_RESERVE:
			reshuffle_count += 1
			shoe.reshuffle(SEED + reshuffle_count * 7919)
			count.reset()
		count.set_decks_remaining(shoe.remaining_decks_exact())
		var tc: int = count.true_count_floor()
		var res: Dictionary = _play_hand(shoe, config, tc, count)
		net_profit += res.profit
		units_wagered += res.wagered
		hands += 1

	var house_edge_pct := (-net_profit / units_wagered) * 100.0
	print("sim_validate [counting]: %d hands, net=%.1f, wagered=%.1f, house edge=%.3f%%" % [hands, net_profit, units_wagered, house_edge_pct])
	return house_edge_pct


# --- Count invariants (deterministic, independent of the hand loop) ---
func _check_count_invariants() -> void:
	var cfg := CHTableConfig.new()
	# Per-card Hi-Lo values.
	var checks: Array[Dictionary] = [
		{"rank": 2, "expect": 1, "note": "card 2"},
		{"rank": 6, "expect": 1, "note": "card 6"},
		{"rank": 7, "expect": 0, "note": "card 7"},
		{"rank": 9, "expect": 0, "note": "card 9"},
		{"rank": 10, "expect": -1, "note": "card 10"},
		{"rank": 13, "expect": -1, "note": "card K"},
		{"rank": 14, "expect": -1, "note": "card A"},
	]
	for c in checks:
		var card := CHCard.new("S", int(c.rank))
		var v: int = card.count_value("hi_lo")
		if v != c.expect:
			_count_failures.append("%s: got %d expect %d" % [c.note, v, c.expect])
	# A full 52-card deck must net to a running count of 0.
	var count := CHCountEngine.new()
	count.count_system = "hi_lo"
	var shoe := CHShoeManager.new()
	shoe.build(cfg, SEED)
	while not shoe.is_empty():
		count.record_card(shoe.deal())
	if count.running_count != 0:
		_count_failures.append("full-deck net: running=%d expected 0" % count.running_count)


func _play_hand(shoe: CHShoeManager, config: CHTableConfig, tc_floor: int = 0, count: CHCountEngine = null) -> Dictionary:
	var upcard: CHCard = shoe.deal()
	var hole: CHCard = shoe.deal()
	var p1: CHCard = shoe.deal()
	var p2: CHCard = shoe.deal()

	var player := CHHand.new()
	player.add_card(p1)
	player.add_card(p2)

	var dealer := CHHand.new()
	dealer.add_card(upcard)

	var up_key: int = CHHand.dealer_upcard_key(upcard.rank)
	var base_bet := 1
	if count != null:
		base_bet = max(1, _bet_for_tc(tc_floor))

	# Count the three immediately-revealed cards. The hole card is counted
	# exactly once, on the path that reveals it.
	_reveal(p1, count)
	_reveal(p2, count)
	_reveal(upcard, count)
	var hole_counted := false

	# Insurance: offered when dealer shows Ace and the table allows it.
	# The player takes it based on the current true count (>= threshold).
	var insurance_bet := 0
	if config.allows_insurance and upcard.rank == 14:
		if _engine.should_take_insurance(tc_floor):
			insurance_bet = maxi(1, int(base_bet / 2))

	# Blackjack resolution (with peek). A natural is settled before any split,
	# so a pair held against a dealer blackjack just loses the single bet.
	var dealer_tmp := CHHand.new()
	dealer_tmp.add_card(upcard)
	dealer_tmp.add_card(hole)
	var player_bj: bool = player.is_blackjack()
	var dealer_bj: bool = dealer_tmp.is_blackjack()
	if player_bj or dealer_bj:
		_reveal(hole, count)
		hole_counted = true
		var main_profit: float = 0.0
		if player_bj and dealer_bj:
			main_profit = 0.0
		elif player_bj:
			main_profit = float(base_bet) * config.blackjack_payout
		else:
			main_profit = -float(base_bet)
		var ins_profit: float = 0.0
		if insurance_bet > 0:
			# Mirror the loop: net profit per unit staked comes from the table
			# config, not a hardcoded 2:1, so any non-2:1 insurance table stays
			# consistent between sim and game loop.
			ins_profit = config.insurance_payout * float(insurance_bet) if dealer_bj else -float(insurance_bet)
		return {"profit": main_profit + ins_profit, "wagered": float(base_bet) + float(insurance_bet)}

	# Resolve split structure. CHSplitResolver deals the follow-up cards; with
	# splitting disabled it returns the single starting hand unchanged, so the
	# no-split baseline path stays identical to the M0/M1 reconstruction.
	var hands := _resolver.resolve(player, up_key, shoe, config, _engine, tc_floor)

	# Mark all cards now in every hand as seen. The resolver deals follow-up
	# cards via shoe.deal() without marking them; this ensures the invariant
	# that every card the player has looked at is counted exactly once.
	for h in hands:
		for c in h.cards:
			_reveal(c, count)

	# Play each terminal hand in turn.
	var profit := 0.0
	var wagered := 0.0
	var played: Array[Dictionary] = []
	for hand in hands:
		var bet := base_bet
		while not hand.is_bust() and not hand.split_ace:
			var play := _engine.best_play_no_split(hand, up_key, config, tc_floor)
			if play == "stand":
				break
			if play == "double" and _can_double(hand, config):
				var dc: CHCard = shoe.deal()
				hand.add_card(dc)
				_reveal(dc, count)
				bet *= 2
				break
			var c: CHCard = shoe.deal()
			hand.add_card(c)
			_reveal(c, count)
		played.append({"hand": hand, "bet": bet})
		wagered += float(bet)

	# Reveal the hole and let the dealer play out (once, shared across hands).
	if not hole_counted:
		_reveal(hole, count)
		hole_counted = true
		dealer.add_card(hole)
	var any_standing := false
	for e in played:
		if not e.hand.is_bust():
			any_standing = true
			break
	if any_standing:
		while _dealer_should_hit(dealer, config):
			var dc: CHCard = shoe.deal()
			dealer.add_card(dc)
			_reveal(dc, count)

	# Settle each hand against the dealer total.
	for e in played:
		var h: CHHand = e.hand
		var b: int = e.bet
		if h.is_bust():
			profit -= float(b)
		elif dealer.is_bust():
			profit += float(b)
		elif dealer.total() > h.total():
			profit -= float(b)
		elif h.total() > dealer.total():
			profit += float(b)
		# else tie: push (0.0)

	# Settle insurance: if taken and dealer did not have BJ, the side bet is lost.
	if insurance_bet > 0:
		profit -= float(insurance_bet)
		wagered += float(insurance_bet)

	return {"profit": profit, "wagered": wagered}


func _can_double(hand: CHHand, config: CHTableConfig) -> bool:
	if not config.allows_double:
		return false
	if hand.card_count() != 2:
		return false
	if hand.is_split_hand and not config.allows_double_after_split:
		return false
	return true


# Reveals a card to the player. With a live count engine (the counting
# simulation) the card's count value is recorded exactly once (CHCountEngine
# guards against double-counting via the `seen` flag). For the no-split /
# split baselines (count == null) only the `seen` flag is set, matching the
# original non-counting behavior.
func _reveal(card: CHCard, count: CHCountEngine) -> void:
	if count != null:
		count.record_card(card)
	else:
		card.seen = true


# Bet ramp for the counting simulation: stake scales up as the floored true
# count turns favorable. A 4-step ramp keeps the test deterministic and
# readable; the exact step sizes are a tunable, not a correctness, choice.
func _bet_for_tc(tc: int) -> int:
	if tc <= -1:
		return 1
	if tc <= 1:
		return 2
	if tc <= 3:
		return 4
	return 6


func _dealer_should_hit(dealer: CHHand, config: CHTableConfig) -> bool:
	var t: int = dealer.total()
	if t >= 18:
		return false
	if t >= 17:
		return config.dealer_hits_soft_17 and dealer.is_soft()
	return true
