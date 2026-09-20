extends SceneTree
# Multi-seed no-split house-edge probe for A/B-testing strategy variants.
#
# A single 500k-hand seed (sim_validate's baseline) has a standard error of
# roughly ~0.15-0.20% on the no-split edge, so a strategy tweak that moves the
# edge by only ~0.02% can look like seed noise. This tool runs the SAME
# deterministic no-split simulation over several seeds so a variant can be
# judged by (a) the sign of each per-seed difference and (b) the mean, removing
# seed-level variance by pairing.
#
# Usage:
#   godot --headless --path . --script res://tools/sim_multiseed.gd -- <hands> <ruleset> <seed1> [seed2 ...]
#
#   <ruleset> is "s17" (dealer stands on soft 17) or "h17" (dealer hits soft 17).
#
# Prints one line per seed and a summary (mean edge). The engine's current
# strategy table is what gets measured; to A/B a variant, edit the engine, run
# over the seed set for BOTH rulesets, revert, and run the same seed set again.
#
# With no user args it runs a fast 50k-hand S17 smoke default so the tool stays
# green in the full suite.
#
# Exit 0 on success (regardless of edge value) — this is a probe, not a gate,
# except for a sanity band that catches a broken sim core.

const SEED_FALLOFF := 7919
const SHOE_RESERVE := 20


var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var total_hands: int
	var ruleset: String = "s17"
	var seeds: Array[int]
	if args.size() >= 3:
		total_hands = int(args[0])
		ruleset = args[1]
		for i in range(2, args.size()):
			seeds.append(int(args[i]))
	elif args.size() >= 1:
		# One arg: treat it as the hand count, S17, single baseline seed.
		total_hands = int(args[0])
		seeds = [20260906]
	else:
		# No user args: fast smoke default so the tool runs green in the suite.
		total_hands = 50000
		seeds = [20260906]

	_expect(total_hands > 0, "hands must be positive, got %d" % total_hands)
	_expect(ruleset == "s17" or ruleset == "h17", "ruleset must be s17 or h17, got '%s'" % ruleset)
	_expect(seeds.size() > 0, "at least one seed required")
	if not _failures.is_empty():
		_finish()
		return

	var config := _base_config(ruleset)
	var edges: Array[float] = []
	for s in seeds:
		var edge: float = _run_simulation(config, total_hands, s)
		edges.append(edge)
		print("sim_multiseed [%s seed %d]: %d hands, house edge=%.4f%%" % [ruleset, s, total_hands, edge])

	var mean := 0.0
	for e in edges:
		mean += e
	mean /= float(edges.size())
	# The probe must produce a finite, sane edge (single-deck S17/H17 3:2
	# no-split is ~0.7-1.1% house edge). A NaN or wildly off value means the
	# sim core broke.
	_expect(mean > 0.2 and mean < 1.9, "mean edge sanity band (0.2-1.9%%), got %.4f%%" % mean)
	print("sim_multiseed: %s, %d seeds, mean edge=%.4f%%" % [ruleset, edges.size(), mean])
	_finish()


func _base_config(ruleset: String) -> CHTableConfig:
	var config := CHTableConfig.new()
	config.deck_count = 1
	config.dealer_hits_soft_17 = (ruleset == "h17")
	config.blackjack_payout = 1.5  # 3:2
	config.allows_surrender = false
	config.allows_insurance = false
	config.allows_double = true
	config.penetration = 1.0
	config.allows_split = false
	return config


func _run_simulation(config: CHTableConfig, total_hands: int, seed: int) -> float:
	var engine := CHStrategyEngine.new()
	var resolver := CHSplitResolver.new()
	var shoe := CHShoeManager.new()
	shoe.build(config, seed)

	var net_profit := 0.0
	var units_wagered := 0.0
	var hands := 0
	var reshuffle_count := 0
	while hands < total_hands:
		if shoe.cards_remaining() < SHOE_RESERVE:
			reshuffle_count += 1
			shoe.reshuffle(seed + reshuffle_count * SEED_FALLOFF)
		var res: Dictionary = _play_hand(shoe, config, engine, resolver)
		net_profit += res.profit
		units_wagered += res.wagered
		hands += 1

	return (-net_profit / units_wagered) * 100.0


func _play_hand(shoe: CHShoeManager, config: CHTableConfig, engine: CHStrategyEngine, resolver: CHSplitResolver) -> Dictionary:
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

	var dealer_tmp := CHHand.new()
	dealer_tmp.add_card(upcard)
	dealer_tmp.add_card(hole)
	var player_bj: bool = player.is_blackjack()
	var dealer_bj: bool = dealer_tmp.is_blackjack()
	if player_bj or dealer_bj:
		var main_profit: float
		if player_bj and dealer_bj:
			main_profit = 0.0
		elif player_bj:
			main_profit = float(base_bet) * config.blackjack_payout
		else:
			main_profit = -float(base_bet)
		return {"profit": main_profit, "wagered": float(base_bet)}

	var hands_out := resolver.resolve(player, up_key, shoe, config, engine, 0)
	var profit := 0.0
	var wagered := 0.0
	var played: Array[Dictionary] = []
	for hand in hands_out:
		var bet := base_bet
		while not hand.is_bust() and not hand.split_ace:
			var play := engine.best_play_no_split(hand, up_key, config, 0)
			if play == "stand":
				break
			if play == "double" and _can_double(hand, config):
				var dc: CHCard = shoe.deal()
				hand.add_card(dc)
				bet *= 2
				break
			var c: CHCard = shoe.deal()
			hand.add_card(c)
		played.append({"hand": hand, "bet": bet})
		wagered += float(bet)

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

	return {"profit": profit, "wagered": wagered}


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


func _finish() -> void:
	if _failures.is_empty():
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		quit(1)
