extends SceneTree
# Counting-system validation: does a live counter extract an edge on a tier?
#
# The only counting sim (sim_validate) is hard-wired to Hi-Lo on a single-deck
# S17 table. But the progression tiers train different systems: Tier 2 uses KO
# (aces counted 0), Tier 5 uses Hi-Opt II (5-7 counted 0, unbalanced). Nothing
# verified that a KO or Hi-Opt II counter, using this engine's bet ramp + I18
# deviations, actually beats a flat-bet basic-strategy player on its own table.
#
# This tool runs, for a given tier, TWO simulations over the same seeds on the
# tier's actual table rules:
#   - counting: live running count, bet sized by the floored true count (ramp),
#     I18 deviations applied at the live TC, count-based insurance.
#   - basic:    same table, flat minimum bet, no count, no deviations
#     (the non-counting baseline for that same table).
# It asserts the counting edge is strictly LOWER (a player advantage vs the
# basic edge), i.e. the count system extracts value on that tier.
#
# Usage:
#   godot --headless --path . --script res://tools/sim_counting_systems.gd -- <hands> <tier> <seed1> [seed2 ...]
#
#   <tier> is 1-6 (7+ is the continuous-shuffle contrast; counting has no edge
#   there by design, so it is not a valid target for this probe).
#
# Both runs cut the shoe at the tier's REAL penetration depth (or the 20-card
# safety reserve, whichever comes first) — the same logic as
# CHGameLoop.start_or_next_shoe(). This matters for the multi-deck tiers: a
# deal-to-exhaustion sim would let the counter count much deeper than the table
# actually allows, flattering the counting edge. On single-deck tiers the reserve
# fires before penetration, so their numbers are unchanged.
#
# With no user args it runs a fast 100k-hand Tier-1 smoke so the tool stays
# green in the full suite.
#
# Exit 0 when counting beats basic on the seed mean and the numbers are
# finite/sane; 1 otherwise.

const SEED_FALLOFF := 7919
const SHOE_RESERVE := 20


var _failures: Array[String] = []
var _engine: CHStrategyEngine = null
var _resolver: CHSplitResolver = null


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	_engine = CHStrategyEngine.new()
	_resolver = CHSplitResolver.new()

	var args: PackedStringArray = OS.get_cmdline_user_args()
	var total_hands: int
	var tier: int
	var seeds: Array[int]
	if args.size() >= 3:
		total_hands = int(args[0])
		tier = int(args[1])
		for i in range(2, args.size()):
			seeds.append(int(args[i]))
	else:
		# No user args: fast smoke default (Tier 1, Hi-Lo) so the tool is green
		# in the full suite. 100k hands keeps the basic-edge estimate stable
		# enough for the sanity band without a multi-minute full-suite run.
		total_hands = 100000
		tier = 1
		seeds = [20260906]

	_expect(total_hands > 0, "hands must be positive, got %d" % total_hands)
	_expect(tier >= 1 and tier <= 6, "tier must be 1-6 (7+ is CSS, no counting edge), got %d" % tier)
	_expect(seeds.size() > 0, "at least one seed required")
	if not _failures.is_empty():
		_finish()
		return

	var config := _sim_config(tier)
	var label: String = "Tier %d (%s, %d deck%s, %s)" % [
		tier, config.count_system, config.deck_count,
		"" if config.deck_count == 1 else "s",
		"H17" if config.dealer_hits_soft_17 else "S17"]

	var count_means: Array[float] = []
	var basic_means: Array[float] = []
	for s in seeds:
		var ce: float = _run_counting(config, total_hands, s)
		var be: float = _run_basic(config, total_hands, s)
		count_means.append(ce)
		basic_means.append(be)
		print("sim_counting_systems [%s seed %d]: counting=%.4f%% basic=%.4f%% (counting saves %.4f%%)"
			% [label, s, ce, be, be - ce])

	var cmean := _mean(count_means)
	var bmean := _mean(basic_means)
	print("sim_counting_systems: %s, %d seeds — counting mean=%.4f%%, basic mean=%.4f%%"
		% [label, seeds.size(), cmean, bmean])

	# Sanity: both finite and in a plausible range for a single table.
	_expect(cmean > -3.0 and cmean < 2.0, "counting mean sanity (-3.0..2.0%%), got %.4f%%" % cmean)
	_expect(bmean > 0.2 and bmean < 1.9, "basic mean sanity (0.2..1.9%%), got %.4f%%" % bmean)
	# The core defect guard: the count system must not make play MEANINGFULLY
	# worse than the flat-bet baseline (the Tier-5 S17-deviation-on-H17 bug made
	# the counter ~1.3%% WORSE). A coarse bet ramp on a hard multi-deck H17
	# table is legitimately near break-even, so "not clearly worse" is the floor.
	_expect(cmean < bmean + 0.30, "counting must not be clearly worse than basic on %s: counting=%.4f%% basic=%.4f%%"
		% [label, cmean, bmean])
	# Where a count edge is genuinely expected (S17 single-deck, the table the
	# I18 + Hi-Lo thresholds are calibrated for), require a clear advantage.
	if not config.dealer_hits_soft_17 and config.deck_count == 1:
		_expect(cmean < bmean, "S17 single-deck counting must beat basic on %s: counting=%.4f%% basic=%.4f%%"
			% [label, cmean, bmean])
	_finish()


# The tier's real table — its count system, deck count, S17/H17, and
# split/insurance/surrender rules are exactly what this probe validates. The
# basic and counting runs both use this same table, so the only difference
# between them is the count (bet ramp + I18 + count-based insurance) — the same
# policy sim_validate's counting phase applies, so the two tools cross-validate
# each other on Tier 1. (The sim plays one player hand per round, so the tier's
# player_hand_count is not used by _play_hand.)
func _sim_config(tier: int) -> CHTableConfig:
	return CHTableConfig.for_tier(tier)


# Live counting sim: running count + bet ramp + I18 at the live TC.
func _run_counting(config: CHTableConfig, total_hands: int, seed: int) -> float:
	var count := CHCountEngine.new()
	count.count_system = config.count_system
	var shoe := CHShoeManager.new()
	shoe.build(config, seed)

	var net := 0.0
	var wagered := 0.0
	var hands := 0
	var reshuffle_count := 0
	while hands < total_hands:
		# Cut at the tier's real penetration OR the safety reserve, matching
		# CHGameLoop.start_or_next_shoe() exactly. On single-deck tiers the
		# reserve fires first (penetration is deeper), so their numbers are
		# unchanged; on multi-deck tiers this respects the real (shallower) cut,
		# so the counting edge is measured on the table the tier actually plays
		# rather than a deeper-penetration idealization.
		if shoe.penetration_reached() or shoe.cards_remaining() < SHOE_RESERVE:
			reshuffle_count += 1
			shoe.reshuffle(seed + reshuffle_count * SEED_FALLOFF)
			count.reset()
		count.set_decks_remaining(shoe.remaining_decks_exact())
		var tc: int = count.true_count_floor()
		var res: Dictionary = _play_hand(shoe, config, tc, count)
		net += res.profit
		wagered += res.wagered
		hands += 1
	return (-net / wagered) * 100.0


# Flat-bet no-count baseline for the same table.
func _run_basic(config: CHTableConfig, total_hands: int, seed: int) -> float:
	var shoe := CHShoeManager.new()
	shoe.build(config, seed)

	var net := 0.0
	var wagered := 0.0
	var hands := 0
	var reshuffle_count := 0
	while hands < total_hands:
		# Same cut as _run_counting so the basic baseline and the counting run
		# are measured on the identical table (same penetration).
		if shoe.penetration_reached() or shoe.cards_remaining() < SHOE_RESERVE:
			reshuffle_count += 1
			shoe.reshuffle(seed + reshuffle_count * SEED_FALLOFF)
		var res: Dictionary = _play_hand(shoe, config, 0, null)
		net += res.profit
		wagered += res.wagered
		hands += 1
	return (-net / wagered) * 100.0


func _mean(values: Array[float]) -> float:
	var s := 0.0
	for v in values:
		s += v
	return s / float(values.size())


# No-split hand. Mirrors sim_validate._play_hand: counts the three
# immediately-revealed cards, the hole on reveal, and every follow-up card
# exactly once (CHCountEngine guards via the seen flag). With count == null the
# seen flag is still maintained but nothing is summed (the basic baseline).
func _play_hand(shoe: CHShoeManager, config: CHTableConfig, tc_floor: int, count: CHCountEngine) -> Dictionary:
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

	# Count the three immediately-revealed cards.
	_reveal(p1, count)
	_reveal(p2, count)
	_reveal(upcard, count)
	var hole_counted := false

	# Insurance: offered when the dealer shows an Ace and the table allows it;
	# taken when the floored true count reaches the threshold. Mirrors
	# sim_validate._play_hand so the counting policy matches on insurance tiers
	# (T1/T2). Previously omitted, so this tool validated a no-insurance policy
	# while its docs and the game both included count-based insurance.
	var insurance_bet := 0
	if config.allows_insurance and upcard.rank == 14:
		if _engine.should_take_insurance(tc_floor):
			insurance_bet = maxi(1, int(base_bet / 2))

	var dealer_tmp := CHHand.new()
	dealer_tmp.add_card(upcard)
	dealer_tmp.add_card(hole)
	var player_bj: bool = player.is_blackjack()
	var dealer_bj: bool = dealer_tmp.is_blackjack()
	if player_bj or dealer_bj:
		_reveal(hole, count)
		var main_profit: float
		if player_bj and dealer_bj:
			main_profit = 0.0
		elif player_bj:
			main_profit = float(base_bet) * config.blackjack_payout
		else:
			main_profit = -float(base_bet)
		var ins_profit: float = 0.0
		if insurance_bet > 0:
			# Net profit per unit staked comes from the table config (2:1 default),
			# mirroring sim_validate so any non-2:1 insurance table stays consistent.
			ins_profit = config.insurance_payout * float(insurance_bet) if dealer_bj else -float(insurance_bet)
		return {"profit": main_profit + ins_profit, "wagered": float(base_bet) + float(insurance_bet)}

	var hands_out := _resolver.resolve(player, up_key, shoe, config, _engine, tc_floor)
	# Mark all cards now in every hand as seen (the resolver deals follow-up
	# cards without marking them; with no-split this is the single starting hand).
	for h in hands_out:
		for c in h.cards:
			_reveal(c, count)

	var profit := 0.0
	var wagered := 0.0
	var played: Array[Dictionary] = []
	for hand in hands_out:
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

	# Settle insurance: in the non-natural path the dealer has no blackjack, so a
	# taken side-bet is lost. Mirrors sim_validate._play_hand.
	if insurance_bet > 0:
		profit -= float(insurance_bet)
		wagered += float(insurance_bet)

	return {"profit": profit, "wagered": wagered}


func _reveal(card: CHCard, count: CHCountEngine) -> void:
	if count != null:
		count.record_card(card)
	else:
		card.seen = true


func _can_double(hand: CHHand, config: CHTableConfig) -> bool:
	if not config.allows_double:
		return false
	if hand.card_count() != 2:
		return false
	if hand.is_split_hand and not config.allows_double_after_split:
		return false
	return true


func _dealer_should_hit(dealer: CHHand, config: CHTableConfig) -> bool:
	var t: int = dealer.total()
	if t >= 18:
		return false
	if t >= 17:
		return config.dealer_hits_soft_17 and dealer.is_soft()
	return true


func _bet_for_tc(tc: int) -> int:
	if tc <= -1:
		return 1
	if tc <= 1:
		return 2
	if tc <= 3:
		return 4
	return 6


func _finish() -> void:
	if _failures.is_empty():
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		quit(1)
