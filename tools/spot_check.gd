extends SceneTree
# Validates CHStrategyEngine against known-correct cells for the default Tier-1
# ruleset: single deck, S17, 3:2, no surrender, no H17.
#   Phase A: basic-strategy cells at true count 0 (non-counting baseline):
#            hard/soft total boundaries, double/stand ranges, and the full
#            pair decision table (split/double/hit boundaries per rank).
#   Phase B: Illustrious 18 deviation cells at their trigger true counts,
#            verifying each deviation fires at its threshold and not one below.
#
# PASS == all cells match. Exit 0 on pass, 1 on any fail.

var _engine: CHStrategyEngine
var _config: CHTableConfig


func _init() -> void:
	_engine = CHStrategyEngine.new()
	_config = CHTableConfig.new()  # single deck, S17, 3:2 defaults

	var cases: Array[Dictionary] = [
		{"ranks": [9, 7],  "dk": 6,  "expect": "stand",   "note": "hard 16 vs 6"},
		{"ranks": [9, 7],  "dk": 7,  "expect": "hit",     "note": "hard 16 vs 7"},
		{"ranks": [10, 2], "dk": 4,  "expect": "stand",   "note": "hard 12 vs 4"},
		{"ranks": [10, 2], "dk": 8,  "expect": "hit",     "note": "hard 12 vs 8"},
		{"ranks": [6, 5],  "dk": 10, "expect": "double",  "note": "hard 11 vs 10"},
		{"ranks": [2, 8],  "dk": 3,  "expect": "double",  "note": "hard 10 vs 3"},
		{"ranks": [4, 5],  "dk": 5,  "expect": "double",  "note": "hard 9 vs 5"},
		# --- Hard-table double/stand/hit boundaries (S17, M56) ---
		# 13-16: 15 stands vs 4-6, hits vs 2-3 and 7-A; 13/14/16 stand vs 2-6.
		{"ranks": [8, 7],  "dk": 2,  "expect": "hit",     "note": "hard 15 vs 2 (hit)"},
		{"ranks": [8, 7],  "dk": 3,  "expect": "hit",     "note": "hard 15 vs 3 (hit)"},
		{"ranks": [8, 7],  "dk": 4,  "expect": "stand",   "note": "hard 15 vs 4 (stand)"},
		{"ranks": [8, 7],  "dk": 6,  "expect": "stand",   "note": "hard 15 vs 6"},
		{"ranks": [8, 7],  "dk": 7,  "expect": "hit",     "note": "hard 15 vs 7"},
		{"ranks": [9, 5],  "dk": 6,  "expect": "stand",   "note": "hard 14 vs 6"},
		{"ranks": [9, 5],  "dk": 7,  "expect": "hit",     "note": "hard 14 vs 7"},
		{"ranks": [8, 5],  "dk": 6,  "expect": "stand",   "note": "hard 13 vs 6"},
		{"ranks": [8, 5],  "dk": 7,  "expect": "hit",     "note": "hard 13 vs 7"},
		# 12: stand vs 4-6 only; hit vs 2-3 and 7-A.
		{"ranks": [10, 2], "dk": 3,  "expect": "hit",     "note": "hard 12 vs 3"},
		{"ranks": [10, 2], "dk": 7,  "expect": "hit",     "note": "hard 12 vs 7"},
		# 11: double vs 2-10, hit vs Ace (Ace is upcard key 14, not collapsed to 10).
		{"ranks": [6, 5],  "dk": 14, "expect": "hit",     "note": "hard 11 vs A"},
		# 10: double vs 2-9, hit vs 10-A.
		{"ranks": [2, 8],  "dk": 10, "expect": "hit",     "note": "hard 10 vs 10"},
		{"ranks": [2, 8],  "dk": 14, "expect": "hit",     "note": "hard 10 vs A"},
		# 9: double vs 3-6, hit vs 2 and 7-A.
		{"ranks": [4, 5],  "dk": 3,  "expect": "double",  "note": "hard 9 vs 3"},
		{"ranks": [4, 5],  "dk": 2,  "expect": "hit",     "note": "hard 9 vs 2"},
		{"ranks": [4, 5],  "dk": 7,  "expect": "hit",     "note": "hard 9 vs 7"},
		# Sub-9 totals always hit; 17-21 always stand.
		{"ranks": [3, 5],  "dk": 5,  "expect": "hit",     "note": "hard 8 vs 5"},
		{"ranks": [10, 7], "dk": 14, "expect": "stand",   "note": "hard 17 vs A"},
		{"ranks": [14, 7], "dk": 3,  "expect": "double",  "note": "soft 18 vs 3"},
		{"ranks": [14, 7], "dk": 2,  "expect": "stand",   "note": "soft 18 vs 2"},
		{"ranks": [14, 7], "dk": 7,  "expect": "stand",   "note": "soft 18 vs 7 (S17)"},
		{"ranks": [14, 7], "dk": 8,  "expect": "stand",   "note": "soft 18 vs 8 (S17)"},
		{"ranks": [14, 7], "dk": 9,  "expect": "hit",     "note": "soft 18 vs 9"},
		{"ranks": [14, 8], "dk": 7,  "expect": "hit",     "note": "soft 19 vs 7"},
		# --- Full soft-table double-down boundaries (S17) ---
		# Soft 15 (A4): double 4-6, hit 2-3/7-10-A. (M55: a "double 4-9" candidate
		# was tested and REJECTED — sim edge worsened 0.972 -> 1.037% vs the 4-6 range.)
		{"ranks": [14, 4], "dk": 4,  "expect": "double",  "note": "soft 15 vs 4"},
		{"ranks": [14, 4], "dk": 6,  "expect": "double",  "note": "soft 15 vs 6"},
		{"ranks": [14, 4], "dk": 7,  "expect": "hit",     "note": "soft 15 vs 7 (not double)"},
		{"ranks": [14, 4], "dk": 3,  "expect": "hit",     "note": "soft 15 vs 3"},
		{"ranks": [14, 4], "dk": 10, "expect": "hit",     "note": "soft 15 vs 10"},
		# Soft 16 (A5): double 3-6, hit 2/7-A.
		{"ranks": [14, 5], "dk": 3,  "expect": "double",  "note": "soft 16 vs 3"},
		{"ranks": [14, 5], "dk": 7,  "expect": "hit",     "note": "soft 16 vs 7"},
		# Soft 17 (A6): double 3-7, hit 2/8-A.
		{"ranks": [14, 6], "dk": 2,  "expect": "hit",    "note": "soft 17 vs 2 (not double)"},
		{"ranks": [14, 6], "dk": 3,  "expect": "double", "note": "soft 17 vs 3 (low edge)"},
		{"ranks": [14, 6], "dk": 6,  "expect": "double", "note": "soft 17 vs 6"},
		{"ranks": [14, 6], "dk": 7,  "expect": "double", "note": "soft 17 vs 7 (high edge)"},
		{"ranks": [14, 6], "dk": 8,  "expect": "hit",    "note": "soft 17 vs 8 (not double)"},
		# Soft 18 (A7): double 3-6, stand 2/7/8, hit 9/10.
		{"ranks": [14, 7], "dk": 6,  "expect": "double",  "note": "soft 18 vs 6"},
		{"ranks": [14, 7], "dk": 8,  "expect": "stand",   "note": "soft 18 vs 8"},
		# Soft 19 (A8): stand 2-6, hit 7-A.
		{"ranks": [14, 8], "dk": 6,  "expect": "stand",   "note": "soft 19 vs 6"},
		{"ranks": [14, 8], "dk": 10, "expect": "hit",     "note": "soft 19 vs 10"},
		# --- Ace upcard (dk=14) soft-table pins: all soft 15-19 vs A hit ---
		{"ranks": [14, 4], "dk": 14, "expect": "hit",     "note": "soft 15 vs A"},
		{"ranks": [14, 5], "dk": 14, "expect": "hit",     "note": "soft 16 vs A"},
		{"ranks": [14, 6], "dk": 14, "expect": "hit",     "note": "soft 17 vs A"},
		{"ranks": [14, 7], "dk": 14, "expect": "hit",     "note": "soft 18 vs A"},
		{"ranks": [14, 8], "dk": 14, "expect": "hit",     "note": "soft 19 vs A"},
		# --- Full pair decision table: split/double/hit range boundaries (M57) ---
		# Aces: split against every upcard.
		{"ranks": [14, 14], "dk": 2,   "expect": "split",  "note": "pair AA vs 2"},
		{"ranks": [14, 14], "dk": 10,  "expect": "split",  "note": "pair AA vs 10"},
		{"ranks": [14, 14], "dk": 14,  "expect": "split",  "note": "pair AA vs A"},
		# 9s: split vs 2-9; hit vs 10/A.
		{"ranks": [9, 9], "dk": 2,   "expect": "split",  "note": "pair 9s vs 2"},
		{"ranks": [9, 9], "dk": 9,   "expect": "split",  "note": "pair 9s vs 9 (high edge)"},
		{"ranks": [9, 9], "dk": 10,  "expect": "hit",    "note": "pair 9s vs 10 (not split)"},
		{"ranks": [9, 9], "dk": 14,  "expect": "hit",    "note": "pair 9s vs A"},
		# 8s: split against every upcard (including 10 and A).
		{"ranks": [8, 8], "dk": 5,   "expect": "split",  "note": "pair 8s vs 5"},
		{"ranks": [8, 8], "dk": 2,   "expect": "split",  "note": "pair 8s vs 2"},
		{"ranks": [8, 8], "dk": 14,  "expect": "split",  "note": "pair 8s vs A (split all)"},
		# 7s: split vs 2-7; hit vs 8-A.
		{"ranks": [7, 7], "dk": 2,   "expect": "split",  "note": "pair 7s vs 2"},
		{"ranks": [7, 7], "dk": 7,   "expect": "split",  "note": "pair 7s vs 7 (high edge)"},
		{"ranks": [7, 7], "dk": 8,   "expect": "hit",    "note": "pair 7s vs 8 (not split)"},
		# 6s: S17/DAS split vs 2-7; hit vs 8-A.
		{"ranks": [6, 6], "dk": 2,   "expect": "split",  "note": "pair 6s vs 2 (S17 split)"},
		{"ranks": [6, 6], "dk": 3,   "expect": "split",  "note": "pair 6s vs 3 (S17 split)"},
		{"ranks": [6, 6], "dk": 4,   "expect": "split",  "note": "pair 6s vs 4 (low edge)"},
		{"ranks": [6, 6], "dk": 7,   "expect": "split",  "note": "pair 6s vs 7 (high edge)"},
		{"ranks": [6, 6], "dk": 8,   "expect": "hit",    "note": "pair 6s vs 8 (above range)"},
		# 5s: double vs 4-9; hit vs 2-3 and 10-A.
		{"ranks": [5, 5], "dk": 3,   "expect": "hit",    "note": "pair 5s vs 3 (below range)"},
		{"ranks": [5, 5], "dk": 4,   "expect": "double", "note": "pair 5s vs 4 (low edge)"},
		{"ranks": [5, 5], "dk": 9,   "expect": "double", "note": "pair 5s vs 9 (high edge)"},
		{"ranks": [5, 5], "dk": 10,  "expect": "hit",    "note": "pair 5s vs 10 (above range)"},
		# 4s: double vs 5-6 only; hit vs everything else.
		{"ranks": [4, 4], "dk": 4,   "expect": "hit",    "note": "pair 4s vs 4 (below range)"},
		{"ranks": [4, 4], "dk": 5,   "expect": "double", "note": "pair 4s vs 5 (low edge)"},
		{"ranks": [4, 4], "dk": 6,   "expect": "double", "note": "pair 4s vs 6 (high edge)"},
		{"ranks": [4, 4], "dk": 7,   "expect": "hit",    "note": "pair 4s vs 7 (above range)"},
		# 3s and 2s: split vs 2-7; hit vs 8-A.
		{"ranks": [3, 3], "dk": 2,   "expect": "split",  "note": "pair 3s vs 2"},
		{"ranks": [3, 3], "dk": 7,   "expect": "split",  "note": "pair 3s vs 7 (high edge)"},
		{"ranks": [3, 3], "dk": 8,   "expect": "hit",    "note": "pair 3s vs 8 (not split)"},
		{"ranks": [2, 2], "dk": 2,   "expect": "split",  "note": "pair 2s vs 2"},
		{"ranks": [2, 2], "dk": 7,   "expect": "split",  "note": "pair 2s vs 7 (high edge)"},
		{"ranks": [2, 2], "dk": 8,   "expect": "hit",    "note": "pair 2s vs 8 (not split)"},
	]

	var passed := 0
	var failed := 0
	for c in cases:
		var hand := _make_hand(c.ranks)
		var got := _engine.best_play(hand, CHHand.dealer_upcard_key(int(c.dk)), _config, 0)
		if got == c.expect:
			passed += 1
			print("PASS  %-16s -> %s" % [c.note, got])
		else:
			failed += 1
			print("FAIL  %-16s expected %s got %s" % [c.note, c.expect, got])

	print("spot_check: %d/%d basic-strategy cells" % [passed, cases.size()])

	# --- I18 deviation spot-checks (non-zero TC) ---
	var dev_passed := 0
	var dev_failed := 0
	var dev_cases: Array[Dictionary] = [
		# High-TC stands (basic says hit)
		{"ranks": [9, 7], "dk": 10, "tc": 3, "expect": "stand", "note": "dev: 16v10 TC>=3"},
		{"ranks": [9, 7], "dk": 10, "tc": 2, "expect": "hit",   "note": "dev: 16v10 TC=2 (no dev)"},
		{"ranks": [8, 7], "dk": 9,  "tc": 2, "expect": "stand", "note": "dev: 15v9 TC>=2"},
		{"ranks": [8, 7], "dk": 9,  "tc": 1, "expect": "hit",   "note": "dev: 15v9 TC=1 (no dev)"},
		# Low-TC: stand instead of double
		{"ranks": [6, 5], "dk": 10, "tc": -1, "expect": "stand", "note": "dev: 11v10 TC<=-1"},
		{"ranks": [6, 5], "dk": 10, "tc": 0,  "expect": "double","note": "dev: 11v10 TC=0 (no dev)"},
		# Low-TC hits (basic says stand)
		{"ranks": [10, 2], "dk": 4, "tc": -1, "expect": "hit",   "note": "dev: 12v4 TC<=-1"},
		{"ranks": [10, 2], "dk": 4, "tc": 0,  "expect": "stand", "note": "dev: 12v4 TC=0 (no dev)"},
		# Soft 19 (A+8) vs 9/10 at high TC: basic says hit, deviate to stand.
		{"ranks": [14, 8], "dk": 9,  "tc": 2,  "expect": "stand", "note": "dev: S19v9 TC>=2"},
		{"ranks": [14, 8], "dk": 9,  "tc": 1,  "expect": "hit",   "note": "dev: S19v9 TC=1 (no dev)"},
		{"ranks": [14, 8], "dk": 10, "tc": 2,  "expect": "stand", "note": "dev: S19v10 TC>=2"},
		{"ranks": [14, 8], "dk": 10, "tc": 1,  "expect": "hit",   "note": "dev: S19v10 TC=1 (no dev)"},
	]
	for c in dev_cases:
		var hand := _make_hand(c.ranks)
		var got := _engine.best_play(hand, CHHand.dealer_upcard_key(int(c.dk)), _config, int(c.tc))
		if got == c.expect:
			dev_passed += 1
			print("PASS  %-28s -> %s" % [c.note, got])
		else:
			dev_failed += 1
			print("FAIL  %-28s expected %s got %s" % [c.note, c.expect, got])

	var total_pass := passed + dev_passed
	var total_fail := failed + dev_failed

	# --- Surrender decision table (M58) ---
	var surr_passed := 0
	var surr_failed := 0
	var late_cfg := CHTableConfig.new()
	late_cfg.allows_surrender = true
	late_cfg.late_surrender_only = true
	var early_cfg := CHTableConfig.new()
	early_cfg.allows_surrender = true
	early_cfg.late_surrender_only = false
	var late_cases: Array[Dictionary] = [
		# Late: 16 vs 9/10/A, 15 vs 10
		{"ranks": [9, 7], "dk": 9,  "expect": "surrender", "note": "late: 16v9"},
		{"ranks": [9, 7], "dk": 10, "expect": "surrender", "note": "late: 16v10"},
		{"ranks": [9, 7], "dk": 14, "expect": "surrender", "note": "late: 16vA"},
		{"ranks": [8, 7], "dk": 10, "expect": "surrender", "note": "late: 15v10"},
		# Negative: not in late set
		{"ranks": [9, 7], "dk": 8,  "expect": "hit", "note": "late: 16v8 (no surrender)"},
		{"ranks": [8, 7], "dk": 9,  "expect": "hit", "note": "late: 15v9 (no surrender)"},
		{"ranks": [9, 5], "dk": 10, "expect": "hit", "note": "late: 14v10 (no surrender)"},
		{"ranks": [8, 5], "dk": 10, "expect": "hit", "note": "late: 13v10 (no surrender)"},
	]
	for c in late_cases:
		var hand := _make_hand(c.ranks)
		var got := _engine.best_play(hand, CHHand.dealer_upcard_key(int(c.dk)), late_cfg, 0)
		if got == c.expect:
			surr_passed += 1
			print("PASS  %-28s -> %s" % [c.note, got])
		else:
			surr_failed += 1
			print("FAIL  %-28s expected %s got %s" % [c.note, c.expect, got])
	var early_cases: Array[Dictionary] = [
		# Early: 16 vs 9/10/A, 15 vs 9/10, 14 vs 10, 13 vs 10
		{"ranks": [9, 7], "dk": 9,  "expect": "surrender", "note": "early: 16v9"},
		{"ranks": [9, 7], "dk": 10, "expect": "surrender", "note": "early: 16v10"},
		{"ranks": [9, 7], "dk": 14, "expect": "surrender", "note": "early: 16vA"},
		{"ranks": [8, 7], "dk": 9,  "expect": "surrender", "note": "early: 15v9"},
		{"ranks": [8, 7], "dk": 10, "expect": "surrender", "note": "early: 15v10"},
		{"ranks": [9, 5], "dk": 10, "expect": "surrender", "note": "early: 14v10"},
		{"ranks": [8, 5], "dk": 10, "expect": "surrender", "note": "early: 13v10"},
		# Negative: not in early set
		{"ranks": [9, 7], "dk": 8,  "expect": "hit", "note": "early: 16v8 (no surrender)"},
		{"ranks": [9, 5], "dk": 9,  "expect": "hit", "note": "early: 14v9 (no surrender)"},
		{"ranks": [8, 5], "dk": 9,  "expect": "hit", "note": "early: 13v9 (no surrender)"},
		{"ranks": [8, 7], "dk": 8,  "expect": "hit", "note": "early: 15v8 (no surrender)"},
	]
	for c in early_cases:
		var hand := _make_hand(c.ranks)
		var got := _engine.best_play(hand, CHHand.dealer_upcard_key(int(c.dk)), early_cfg, 0)
		if got == c.expect:
			surr_passed += 1
			print("PASS  %-28s -> %s" % [c.note, got])
		else:
			surr_failed += 1
			print("FAIL  %-28s expected %s got %s" % [c.note, c.expect, got])
	# Gate: soft hands never surrender (A+5 = soft 16 vs 10)
	var soft16 := _make_hand([14, 5])
	var got_soft := _engine.best_play(soft16, 10, late_cfg, 0)
	if got_soft == "hit":
		surr_passed += 1
		print("PASS  %-28s -> %s" % ["gate: soft 16v10 no surrender", got_soft])
	else:
		surr_failed += 1
		print("FAIL  gate: soft 16v10 expected hit got %s" % got_soft)
	# Gate: pairs never surrender (8,8 vs 10 splits instead)
	var pair88 := _make_hand([8, 8])
	var got_pair := _engine.best_play(pair88, 10, late_cfg, 0)
	if got_pair == "split":
		surr_passed += 1
		print("PASS  %-28s -> %s" % ["gate: pair 8s v10 no surrender", got_pair])
	else:
		surr_failed += 1
		print("FAIL  gate: pair 8s v10 expected split got %s" % got_pair)

	total_pass += surr_passed
	total_fail += surr_failed

	# --- Legality / priority checks (engine self-consistency, not strategy cells) ---
	var leg_passed := 0
	var leg_failed := 0
	# A 3-card hard 11 must not double (double is only legal on a fresh 2-card hand).
	var hand11_3 := CHHand.new()
	hand11_3.add_card(CHCard.new("S", 5))
	hand11_3.add_card(CHCard.new("H", 2))
	hand11_3.add_card(CHCard.new("D", 4))
	var got11_3 := _engine.best_play(hand11_3, 9, _config, 0)
	if got11_3 == "hit":
		leg_passed += 1
		print("PASS  legal: 3-card 11 -> hit (no double on 3 cards)")
	else:
		leg_failed += 1
		print("FAIL  legal: 3-card 11 expected hit got %s" % got11_3)
	# Surrender must never be overridden by a high-TC deviation.
	var surrender_cfg := CHTableConfig.new()
	surrender_cfg.allows_surrender = true
	var hand16 := CHHand.new()
	hand16.add_card(CHCard.new("S", 9))
	hand16.add_card(CHCard.new("H", 7))
	var got16_surr := _engine.best_play(hand16, 10, surrender_cfg, 3)
	if got16_surr == "surrender":
		leg_passed += 1
		print("PASS  legal: 16v10 TC3 stays surrender (deviation must not override)")
	else:
		leg_failed += 1
		print("FAIL  legal: 16v10 TC3 expected surrender got %s" % got16_surr)
	# Surrender is only legal on a fresh two-card hand. A three-card 16 vs 10
	# (surrender enabled) must fall through to the basic play "hit" — never to
	# "surrender" and never to the degraded "stand".
	var hand16_3 := _make_hand([9, 4, 3])  # 9+4+3 = 16, hard, not a pair
	var got16_3_surr := _engine.best_play(hand16_3, 10, surrender_cfg, 0)
	if got16_3_surr == "hit":
		leg_passed += 1
		print("PASS  legal: 3-card 16v10 -> hit (surrender only on 2 cards)")
	else:
		leg_failed += 1
		print("FAIL  legal: 3-card 16v10 expected hit got %s" % got16_3_surr)
	# Ten-value pairs (10/J/Q/K) are never split — stand on 20. All four ranks.
	var ten_names := {10: "10", 11: "J", 12: "Q", 13: "K"}
	for tr in [10, 11, 12, 13]:
		var tpair := _make_hand([tr, tr])
		var got_t := _engine.best_play(tpair, 5, _config, 0)
		if got_t == "stand":
			leg_passed += 1
			print("PASS  legal: pair %s%s -> stand (never split tens)" % [ten_names[tr], ten_names[tr]])
		else:
			leg_failed += 1
			print("FAIL  legal: pair %s%s expected stand got %s" % [ten_names[tr], ten_names[tr], got_t])
	# Double-after-split (DAS) gate: a split sub-hand that is a two-card 11
	# (basic strategy says double) may only double when the table allows
	# doubling after a split. This pins _enforce_double_legality's split-hand
	# branch — a config lever set on every tier but never behaviourally
	# exercised. 5+6 = 11 (hard, not a pair) vs a 7 upcard.
	var split11 := CHHand.new()
	split11.add_card(CHCard.new("S", 5))
	split11.add_card(CHCard.new("H", 6))
	split11.is_split_hand = true
	var das_on := _engine.best_play_no_split(split11, 7, _config, 0)  # default DAS on
	if das_on == "double":
		leg_passed += 1
		print("PASS  legal: DAS on - split-hand 11 vs 7 doubles")
	else:
		leg_failed += 1
		print("FAIL  legal: DAS on expected double, got %s" % das_on)
	var nodas := CHTableConfig.new()
	nodas.allows_double_after_split = false
	var das_off := _engine.best_play_no_split(split11, 7, nodas, 0)
	if das_off == "hit":
		leg_passed += 1
		print("PASS  legal: DAS off - split-hand 11 vs 7 hits (no double after split)")
	else:
		leg_failed += 1
		print("FAIL  legal: DAS off expected hit, got %s" % das_off)
	# H17 player-strategy adjustment: on a dealer-hits-soft-17 table the optimal
	# play for soft 18 vs 7/8 flips from stand to hit. The basic table (S17)
	# stands here; _apply_h17 must override to hit. This pins that the H17 layer
	# is load-bearing (not a no-op) on top of the corrected S17 base.
	var h17_cfg := CHTableConfig.new()
	h17_cfg.dealer_hits_soft_17 = true
	for hd in [7, 8]:
		var s18 := _make_hand([14, 7])
		var got_h17 := _engine.best_play(s18, hd, h17_cfg, 0)
		if got_h17 == "hit":
			leg_passed += 1
			print("PASS  legal: H17 soft 18 vs %d -> hit (layer overrides S17 stand)" % hd)
		else:
			leg_failed += 1
			print("FAIL  legal: H17 soft 18 vs %d expected hit, got %s" % [hd, got_h17])

	total_pass += leg_passed
	total_fail += leg_failed
	print("spot_check: %d/%d total cells (basic + I18 dev + legality)" % [total_pass, total_pass + total_fail])
	quit(0 if total_fail == 0 else 1)


func _make_hand(ranks: Array) -> CHHand:
	var h := CHHand.new()
	var i := 0
	for r in ranks:
		var suit: String = CHCard.SUITS[i % CHCard.SUITS.size()]
		h.add_card(CHCard.new(suit, int(r)))
		i += 1
	return h
