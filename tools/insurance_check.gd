extends SceneTree
# Headless structural tests for the insurance side-bet (M5).
#
#   1. should_take_insurance threshold: taken at/above the threshold, declined
#      below it (and never at very negative counts).
#   2. Payout math: dealer shows Ace, player takes insurance.
#        - dealer has a 10 in the hole (BJ): insurance pays 2:1 (net +2*bet).
#        - dealer's hole is not a 10: insurance is lost (-bet), hand plays on.
#   3. Insurance is only offered on an Ace upcard (no side bet otherwise).
#   4. Insurance is never offered when the table disallows it.
#
# Card order is rigged directly on the shoe so results are deterministic.
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.


const THRESHOLD: int = 3  # must match CHStrategyEngine.INSURANCE_TC_THRESHOLD


var _failures: Array[String] = []


func _init() -> void:
	_check_threshold()
	_check_payout_dealer_bj()
	_check_payout_no_bj()
	_check_no_insurance_on_non_ace()
	_check_disabled_config()
	_check_loop_honors_insurance_payout()

	if _failures.is_empty():
		print("insurance_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("insurance_check: %d failure(s)" % _failures.size())
		quit(1)


func _make_config(allows_insurance: bool = true) -> CHTableConfig:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.dealer_hits_soft_17 = false
	c.blackjack_payout = 1.5
	c.allows_double = true
	c.allows_split = false
	c.allows_insurance = allows_insurance
	return c


# --- 1. Decision threshold ---
func _check_threshold() -> void:
	var engine := CHStrategyEngine.new()
	var cases: Array[Dictionary] = [
		{"tc": -2, "expect": false},
		{"tc": 0, "expect": false},
		{"tc": 2, "expect": false},   # just below
		{"tc": 3, "expect": true},    # at threshold
		{"tc": 5, "expect": true},    # above
	]
	var ok := true
	for c in cases:
		var got: bool = engine.should_take_insurance(int(c.tc))
		if got != c.expect:
			ok = false
			_failures.append("threshold: TC=%d expected take=%s got %s" % [int(c.tc), str(c.expect), str(got)])
	if ok:
		print("PASS  decision threshold: take at TC>=%d, decline below" % THRESHOLD)


# Resolves a single insurance hand the same way the sim does, and returns the
# combined {profit, wagered} (main hand + insurance side-bet) plus the bet size.
func _play_insurance_hand(shoe_ranks: Array, config: CHTableConfig, tc: int) -> Dictionary:
	var engine := CHStrategyEngine.new()
	var shoe := CHShoeManager.new()
	shoe.config = config
	shoe.deck.clear()
	var suits := ["S", "H", "D", "C"]
	for i in range(shoe_ranks.size()):
		shoe.deck.append(CHCard.new(suits[i % 4], int(shoe_ranks[i])))
	shoe.deal_index = 0

	var upcard: CHCard = shoe.deal()
	var hole: CHCard = shoe.deal()
	var p1: CHCard = shoe.deal()
	var p2: CHCard = shoe.deal()

	var player := CHHand.new()
	player.add_card(p1)
	player.add_card(p2)
	var base_bet := 1

	# Insurance decision (mirrors sim_validate).
	var insurance_bet := 0
	if config.allows_insurance and upcard.rank == 14:
		if engine.should_take_insurance(tc):
			insurance_bet = maxi(1, int(base_bet / 2))

	var dealer_tmp := CHHand.new()
	dealer_tmp.add_card(upcard)
	dealer_tmp.add_card(hole)
	var player_bj: bool = player.is_blackjack()
	var dealer_bj: bool = dealer_tmp.is_blackjack()

	var ins_profit: float = 0.0
	var profit: float
	var wagered: float = float(base_bet) + float(insurance_bet)

	if player_bj or dealer_bj:
		# Settle the insurance side-bet against the revealed hole.
		if insurance_bet > 0:
			ins_profit = 2.0 * float(insurance_bet) if dealer_bj else -float(insurance_bet)
		if player_bj and dealer_bj:
			profit = 0.0
		elif player_bj:
			profit = float(base_bet) * config.blackjack_payout
		else:
			profit = -float(base_bet)
		profit += ins_profit
		return {"profit": profit, "wagered": wagered, "insurance_bet": insurance_bet}

	# No natural: for this structural test the main-hand outcome is a fixed
	# placeholder (-1); the assertion focuses on the insurance component.
	# Insurance taken with no dealer BJ is lost.
	profit = -1.0
	if insurance_bet > 0:
		ins_profit = -float(insurance_bet)
	profit += ins_profit
	return {"profit": profit, "wagered": wagered, "insurance_bet": insurance_bet}


# --- 2. Payout: dealer has a 10 in the hole (BJ) ---
func _check_payout_dealer_bj() -> void:
	var cfg := _make_config()
	# up=Ace(14), hole=10(10), p1=2, p2=7. Dealer = AJ (BJ). Player not BJ.
	var res := _play_insurance_hand([14, 10, 2, 7], cfg, THRESHOLD)
	# main: -1 (lose to BJ). insurance bet = 1 (base 1 div 2 -> max(1,0)=1), won 2:1 -> +2.
	var expected_main := -1.0
	var expected_ins := 2.0
	var expected_total := expected_main + expected_ins
	if res.insurance_bet != 1:
		_failures.append("payout BJ: insurance_bet expected 1, got %d" % res.insurance_bet)
	if absf(res.profit - expected_total) > 0.001:
		_failures.append("payout BJ: profit expected %.1f got %.1f" % [expected_total, res.profit])
	else:
		print("PASS  payout: dealer BJ + insurance -> main -1, insurance +2, total %.1f" % res.profit)


# --- 3. Payout: dealer's hole is not a 10 (no BJ) ---
func _check_payout_no_bj() -> void:
	var cfg := _make_config()
	# up=Ace(14), hole=5(5), p1=2, p2=7. No dealer BJ.
	var res := _play_insurance_hand([14, 5, 2, 7], cfg, THRESHOLD)
	# main rigged to -1 (stands, loses). insurance taken, lost -> -1.
	var expected_total := -1.0 + (-1.0)
	if res.insurance_bet != 1:
		_failures.append("payout no-BJ: insurance_bet expected 1, got %d" % res.insurance_bet)
	if absf(res.profit - expected_total) > 0.001:
		_failures.append("payout no-BJ: profit expected %.1f got %.1f" % [expected_total, res.profit])
	else:
		print("PASS  payout: no dealer BJ + insurance -> insurance lost (-1)")


# --- 4. No insurance on a non-Ace upcard ---
func _check_no_insurance_on_non_ace() -> void:
	var cfg := _make_config()
	# up=10, hole=10, p1=2, p2=7. Upcard is not an Ace -> no insurance offered.
	var res := _play_insurance_hand([10, 10, 2, 7], cfg, THRESHOLD)
	if res.insurance_bet != 0:
		_failures.append("non-Ace: insurance bet expected 0, got %d" % res.insurance_bet)
	else:
		print("PASS  no insurance offered when upcard is not an Ace")


# --- 5. Insurance disabled by config ---
func _check_disabled_config() -> void:
	var cfg := _make_config(false)
	# up=Ace, hole=10 (BJ) but insurance disabled -> no side bet even at high TC.
	var res := _play_insurance_hand([14, 10, 2, 7], cfg, THRESHOLD)
	if res.insurance_bet != 0:
		_failures.append("disabled: insurance bet expected 0, got %d" % res.insurance_bet)
	else:
		print("PASS  no insurance when allows_insurance is false")


# --- 6. The loop reads config.insurance_payout (not a hardcoded 2.0) ---
# Two identical dealer-BJ insurance hands differ only by the payout ratio. If
# the loop still hardcoded 2.0, both would settle to the same net P&L.
func _check_loop_honors_insurance_payout() -> void:
	var net_default: float = _drive_insurance_settle(2.0)
	var net_one_to_one: float = _drive_insurance_settle(1.0)
	if absf(net_default - 1.0) < 0.001:
		print("PASS  loop insurance payout at 2:1 -> net +1.0")
	else:
		_failures.append("loop insurance payout 2.0: expected net +1.0, got %.2f" % net_default)
	if absf(net_one_to_one - 0.0) < 0.001:
		print("PASS  loop insurance payout at 1:1 -> net 0.0 (config honored)")
	else:
		_failures.append("loop insurance payout 1.0: expected net 0.0, got %.2f (hardcoded 2.0?)" % net_one_to_one)


# Drives one fresh loop through a rigged Ace/10 dealer-BJ with a 12 player hand
# and insurance taken, at the given insurance_payout. Returns the settled net P&L.
func _drive_insurance_settle(payout: float) -> float:
	var c := CHTableConfig.new()
	c.deck_count = 1
	c.allows_insurance = true
	c.insurance_payout = payout
	c.player_hand_count = 1
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_TARGET, 999999)
	var loop := CHGameLoop.new(c, state, CHDisciplineSystem.new(), 1)

	# Rig the shoe: up=Ace, hole=10 (dealer BJ), player 5,7 (total 12, no natural).
	var shoe := loop.get_shoe()
	var total := shoe.deck.size()
	shoe.deck.clear()
	for card in [["S", 14], ["H", 10], ["S", 5], ["H", 7]]:
		shoe.deck.append(CHCard.new(card[0], int(card[1])))
	for i in range(total - 4):
		shoe.deck.append(CHCard.new("S", 2))
	shoe.deal_index = 0

	if not loop.begin_hand():
		_failures.append("insurance-settle: begin_hand failed")
		return -999.0
	loop.place_bet(1, false)
	if loop.phase() != CHGameLoop.PHASE_INSURANCE:
		_failures.append("insurance-settle: expected INSURANCE phase, got %s" % loop.phase())
		return -999.0
	loop.apply_action(CHGameLoop.ACT_INS_TAKE)
	return loop.last_net()
