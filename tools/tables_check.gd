extends SceneTree
# Headless validation for M9 — tier config factory + count-system wiring.
#
#   1. for_tier(t) for t=1..6 returns a sane config (deck_count>0,
#      penetration in (0,1], valid count_system, name+tier set).
#   2. for_tier(1) reproduces the teaching-table defaults the sim relies on
#      (the sim path must stay unchanged).
#   3. Count systems: per-card values for hi_lo / ko / hi_opt_ii and the
#      deterministic full-deck net for each (hi_lo=0, ko=+4, hi_opt_ii=-12).
#   4. Loop wiring: a CHGameLoop built from a tier config picks up that
#      config's count_system, and a multi-deck tier actually builds a
#      multi-deck shoe.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906

# Full-deck running-count net for each system (52 cards, all seen).
const DECK_NET := {"hi_lo": 0, "ko": 4, "hi_opt_ii": -12}

var _failures: Array[String] = []


func _init() -> void:
	_check_for_tier_sanity()
	_check_tier1_defaults()
	_check_count_systems()
	_check_loop_wiring()
	_check_deck_estimation()
	_check_six_five_tier()

	if _failures.is_empty():
		print("tables_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("tables_check: %d failure(s)" % _failures.size())
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


# --- 1. for_tier sanity ---
func _check_for_tier_sanity() -> void:
	var valid_systems := ["hi_lo", "ko", "hi_opt_ii"]
	for t in [1, 2, 3, 4, 5, 6, 7]:
		var c := CHTableConfig.for_tier(t)
		_expect(c.tier == t, "for_tier(%d).tier == %d, got %d" % [t, t, c.tier])
		_expect(c.deck_count > 0, "for_tier(%d) deck_count>0, got %d" % [t, c.deck_count])
		_expect(c.penetration > 0.0 and c.penetration <= 1.0, "for_tier(%d) penetration in (0,1], got %s" % [t, c.penetration])
		_expect(valid_systems.has(c.count_system), "for_tier(%d) count_system valid, got '%s'" % [t, c.count_system])
		_expect(c.name != "", "for_tier(%d) name non-empty" % t)
		_expect(c.max_split_hands >= 0, "for_tier(%d) max_split_hands>=0" % t)


# --- 2. tier 1 reproduces teaching-table / sim-relevant defaults ---
func _check_tier1_defaults() -> void:
	var c := CHTableConfig.for_tier(1)
	_expect(c.deck_count == 1, "T1 single deck, got %d" % c.deck_count)
	_expect(not c.dealer_hits_soft_17, "T1 S17 (dealer does not hit soft 17)")
	_expect(absf(c.blackjack_payout - 1.5) < 1e-6, "T1 3:2 payout, got %s" % c.blackjack_payout)
	_expect(c.allows_insurance, "T1 insurance allowed")
	_expect(c.allows_split, "T1 splits allowed")
	_expect(c.max_split_hands == 4, "T1 max_split_hands 4, got %d" % c.max_split_hands)
	_expect(c.split_aces_one_card_only, "T1 split aces one-card-only")
	_expect(c.allows_double_after_split, "T1 DAS")
	_expect(not c.allows_surrender, "T1 no surrender")
	_expect(absf(c.penetration - 0.70) < 1e-6, "T1 penetration 0.70, got %s" % c.penetration)
	_expect(absf(c.deck_estimation_rounding - 1.0) < 1e-6, "T1 est rounding 1.0, got %s" % c.deck_estimation_rounding)
	_expect(c.heat_active, "T1 heat_active")
	_expect(c.show_count_display, "T1 show_count_display")
	_expect(c.count_system == "hi_lo", "T1 hi_lo, got %s" % c.count_system)


# --- 3. Count systems: per-card + full-deck net ---
func _check_count_systems() -> void:
	# Representative per-card values.
	_expect(CHCard.new("S", 2).count_value("hi_lo") == 1, "hi_lo 2 = +1")
	_expect(CHCard.new("S", 7).count_value("hi_lo") == 0, "hi_lo 7 = 0")
	_expect(CHCard.new("S", 10).count_value("hi_lo") == -1, "hi_lo 10 = -1")
	_expect(CHCard.new("S", 14).count_value("hi_lo") == -1, "hi_lo A = -1")
	_expect(CHCard.new("S", 14).count_value("ko") == 0, "ko A = 0")
	_expect(CHCard.new("S", 10).count_value("ko") == -1, "ko 10 = -1")
	_expect(CHCard.new("S", 4).count_value("hi_opt_ii") == 1, "hi_opt_ii 4 = +1")
	_expect(CHCard.new("S", 5).count_value("hi_opt_ii") == 0, "hi_opt_ii 5 = 0")
	_expect(CHCard.new("S", 8).count_value("hi_opt_ii") == -1, "hi_opt_ii 8 = -1")
	_expect(CHCard.new("S", 10).count_value("hi_opt_ii") == -1, "hi_opt_ii 10 = -1")
	_expect(CHCard.new("S", 14).count_value("hi_opt_ii") == 0, "hi_opt_ii A = 0")

	# Full-deck net for each system (deterministic; documents each system's bias).
	for sys in DECK_NET.keys():
		var net := 0
		for s in CHCard.SUITS:
			for r in range(2, 15):
				net += CHCard.new(s, r).count_value(sys)
		_expect(net == DECK_NET[sys], "deck net for %s == %d, got %d" % [sys, DECK_NET[sys], net])


# --- 4. Loop wiring ---
func _check_loop_wiring() -> void:
	# Tier 2 (ko) and Tier 5 (hi_opt_ii, 6 decks) pick up the right system.
	var c2 := CHTableConfig.for_tier(2)
	var loop2 := _make_loop(c2)
	_expect(loop2.get_count().count_system == "ko", "T2 loop count_system ko, got %s" % loop2.get_count().count_system)

	var c5 := CHTableConfig.for_tier(5)
	var loop5 := _make_loop(c5)
	_expect(loop5.get_count().count_system == "hi_opt_ii", "T5 loop count_system hi_opt_ii, got %s" % loop5.get_count().count_system)
	# 6 decks * 52 cards built.
	_expect(loop5.get_shoe().total_cards() == 6 * 52, "T5 shoe has 312 cards, got %d" % loop5.get_shoe().total_cards())

	# A multi-deck loop can play a hand to a settled state without error.
	if not loop5.begin_hand():
		_failures.append("T5 begin_hand returned false on a fresh session")
		return
	loop5.place_bet(loop5.optimal_bet_units())
	var guard := 0
	while not loop5.is_idle() and guard < 64:
		loop5.apply_action(loop5.optimal_action())
		guard += 1
	_expect(loop5.is_idle(), "T5 hand reached an idle/settled state")


func _make_loop(config: CHTableConfig) -> CHGameLoop:
	var state := CHGameState.new()
	state.start_session(config.tier, CHGameState.MODE_PRACTICE)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(config, state, disc, SEED)


# --- 5. deck_estimation_rounding is a live difficulty lever ---
# The loop feeds decks_remaining_estimate() into the count engine at the start
# of every shoe. Verify the estimate rounds to the tier's step and that the
# loop actually uses it (not exact).
func _check_deck_estimation() -> void:
	# Tier 5: 6 decks, step 0.25
	var c5 := CHTableConfig.for_tier(5)
	var shoe5 := CHShoeManager.new()
	shoe5.build(c5, SEED)

	# Fresh shoe: estimate == exact (both = 6.0).
	var est_fresh: float = shoe5.decks_remaining_estimate()
	var exact_fresh: float = shoe5.remaining_decks_exact()
	_expect(absf(est_fresh - exact_fresh) < 1e-6,
		"T5 fresh shoe: estimate %.4f == exact %.4f" % [est_fresh, exact_fresh])
	_expect(absf(est_fresh - 6.0) < 1e-6,
		"T5 fresh estimate == 6.0, got %.4f" % est_fresh)

	# Deal 10 cards → remaining = 302 → exact = 302/52 ≈ 5.8077
	# estimate = roundf(5.8077/0.25)*0.25 = roundf(23.23)*0.25 = 23*0.25 = 5.75
	for _i in range(10):
		shoe5.deal()
	var est_mid: float = shoe5.decks_remaining_estimate()
	var exact_mid: float = shoe5.remaining_decks_exact()
	_expect(est_mid == 5.75,
		"T5 mid-shoe estimate == 5.75, got %.4f" % est_mid)
	_expect(est_mid != exact_mid,
		"T5 mid-shoe: estimate %.4f differs from exact %.4f (lever active)" % [est_mid, exact_mid])
	# Estimate must always be a multiple of the tier's step.
	var step5 := c5.deck_estimation_rounding
	var remainder: float = fmod(est_mid, step5)
	_expect(remainder < 1e-6 or absf(remainder - step5) < 1e-6,
		"T5 estimate %.4f is a multiple of step %.2f" % [est_mid, step5])

	# Tier 3: 2 decks, step 0.5
	var c3 := CHTableConfig.for_tier(3)
	var shoe3 := CHShoeManager.new()
	shoe3.build(c3, SEED)
	var est3_fresh: float = shoe3.decks_remaining_estimate()
	_expect(absf(est3_fresh - 2.0) < 1e-6,
		"T3 fresh estimate == 2.0, got %.4f" % est3_fresh)
	# Deal 3 cards → remaining = 101 → exact = 101/52 ≈ 1.9423
	# estimate = roundf(1.9423/0.5)*0.5 = roundf(3.88)*0.5 = 4*0.5 = 2.0
	for _i in range(3):
		shoe3.deal()
	var est3_mid: float = shoe3.decks_remaining_estimate()
	_expect(est3_mid == 2.0,
		"T3 mid-shoe estimate == 2.0, got %.4f" % est3_mid)

	# Loop wiring: after begin_hand, count.decks_remaining must equal the
	# estimate (proves the loop calls decks_remaining_estimate, not exact).
	var c_t5 := CHTableConfig.for_tier(5)
	var state5 := CHGameState.new()
	state5.start_session(5, CHGameState.MODE_PRACTICE)
	var loop5 := CHGameLoop.new(c_t5, state5, CHDisciplineSystem.new(), SEED)
	if not loop5.begin_hand():
		_failures.append("T5 loop: begin_hand failed")
		return
	var loop_decks: float = loop5.get_count().decks_remaining
	var loop_est: float = loop5.get_shoe().decks_remaining_estimate()
	_expect(absf(loop_decks - loop_est) < 1e-6,
		"Loop feeds estimate (%.4f) into count engine, got %.4f" % [loop_est, loop_decks])
	_expect(absf(loop_decks - 6.0) < 1e-6,
		"Loop count.decks_remaining == 6.0 on fresh T5 shoe, got %.4f" % loop_decks)


# --- 6. T6 is the 6:5 "tough real table" (M100); CSS renumbered to T7+ ---
func _check_six_five_tier() -> void:
	var c6 := CHTableConfig.for_tier(6)
	_expect(c6.tier == 6, "T6.tier == 6, got %d" % c6.tier)
	_expect(absf(c6.blackjack_payout - 1.2) < 1e-6, "T6 6:5 payout 1.2, got %s" % c6.blackjack_payout)
	_expect(c6.dealer_hits_soft_17, "T6 H17")
	_expect(c6.deck_count == 4, "T6 4 decks, got %d" % c6.deck_count)
	_expect(c6.allows_surrender and c6.late_surrender_only, "T6 late surrender")
	_expect(c6.count_system == "hi_lo", "T6 hi_lo, got %s" % c6.count_system)
	_expect(not c6.continuous_shuffle, "T6 is not CSS")
	# CSS moved to the T7+ catch-all.
	var c7 := CHTableConfig.for_tier(7)
	_expect(c7.continuous_shuffle, "T7 is CSS (catch-all)")
	_expect(c7.deck_count == 8, "T7 CSS 8 decks, got %d" % c7.deck_count)
