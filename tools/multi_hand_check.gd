extends SceneTree
# Headless validation for M13 — multi-hand (multi-spot) play.
#
# `config.player_hand_count > 1` deals that many independent two-card root
# hands ("spots") against one shared dealer upcard. Each spot is independently
# splittable and played in turn. Checks:
#
#   1. Two spots: a non-pair opening produces exactly 2 terminal hands, and the
#      settled wager equals 2 x the per-spot bet (the bet is per-spot, not a
#      single shared bet).
#   2. Three spots: a non-pair opening produces exactly 3 terminal hands.
#   3. Two splittable spots: driving both splits yields 4 terminal hands
#      (2 per spot), confirming each root is processed in turn.
#   4. Card conservation across a settled multi-spot round: every card dealt is
#      marked seen exactly once.
#   5. Dealer bust pays every spot a win (M59).
#   6. An all-pushing round nets zero.
#   7. Insurance side-bet scales with the spot count on the win path (M59).
#   8. Insurance side-bet is forfeited on a multi-spot hand with no dealer
#      natural (M72).
#   9. One natural + one non-natural spot, no dealer natural: only the natural
#      settles; the other spot still plays (M105).
#
# Openings are rigged on the shoe (first N cards) so the scenarios are
# deterministic. The remaining 52-N cards are rank-2 filler (low, non-pair,
# non-resplit) so follow-up play stays benign.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906
const SUITS: Array[String] = ["S", "H", "D", "C"]

var _failures: Array[String] = []


func _init() -> void:
	_check_two_spot_nosplit()
	_check_three_spot_nosplit()
	_check_two_spot_both_split()
	_check_card_conservation_multi()
	_check_dealer_bust_pays_each_hand()
	_check_all_pushes_net_zero()
	_check_insurance_scales_with_spots()
	_check_insurance_forfeit_multi_spot()
	_check_one_natural_other_spot_plays()

	if _failures.is_empty():
		print("multi_hand_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("multi_hand_check: %d failure(s)" % _failures.size())
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


# Builds a single-deck teaching config with the given spot count.
func _make_config(spots: int) -> CHTableConfig:
	var c := CHTableConfig.for_tier(1)
	c.player_hand_count = spots
	return c


# Drives a loop's shoe so that its first `open.size()` deals are the given ranks,
# and every remaining card is rank 2 (benign filler). `open` is in deal order:
# [up, hole, s1a, s1b, (s2a, s2b), ...].
func _rig_opening(loop: CHGameLoop, open: Array) -> void:
	var shoe := loop.get_shoe()
	var deck: Array[CHCard] = []
	for i in range(open.size()):
		deck.append(CHCard.new(SUITS[i % 4], int(open[i])))
	for i in range(open.size(), 52):
		deck.append(CHCard.new(SUITS[i % 4], 2))
	shoe.deck = deck
	shoe.deal_index = 0


# Plays the current round to rest (idle).
func _settle(loop: CHGameLoop) -> void:
	var guard := 0
	while not loop.is_idle() and guard < 128:
		loop.apply_action(loop.optimal_action())
		guard += 1


# --- 1. Two spots, no split -> 2 hands, wagered = 2 x bet ---
func _check_two_spot_nosplit() -> void:
	var loop := CHGameLoop.new(_make_config(2), _fresh_state(), CHDisciplineSystem.new(), SEED)
	# up=5, hole=10; s1 = 8,5 (13), s2 = 9,4 (13). No pairs, no BJ, no double.
	_rig_opening(loop, [5, 10, 8, 5, 9, 4])
	_expect(loop.begin_hand(), "begin_hand")
	loop.place_bet(3)
	_expect(loop.all_hands().size() == 2, "two spots -> 2 terminal hands, got %d" % loop.all_hands().size())
	_settle(loop)
	_expect(loop.is_idle(), "round settled, phase=%s" % loop.phase())
	_expect(loop.last_wagered() == 6.0, "wagered = 2 x 3 = 6, got %s" % loop.last_wagered())


# --- 2. Three spots, no split -> 3 hands ---
func _check_three_spot_nosplit() -> void:
	var loop := CHGameLoop.new(_make_config(3), _fresh_state(), CHDisciplineSystem.new(), SEED)
	# up=5, hole=10; s1 = 8,5 (13), s2 = 9,4 (13), s3 = 7,6 (13).
	_rig_opening(loop, [5, 10, 8, 5, 9, 4, 7, 6])
	_expect(loop.begin_hand(), "begin_hand")
	loop.place_bet(2)
	_expect(loop.all_hands().size() == 3, "three spots -> 3 terminal hands, got %d" % loop.all_hands().size())
	_settle(loop)
	_expect(loop.is_idle(), "round settled, phase=%s" % loop.phase())
	_expect(loop.last_wagered() == 6.0, "wagered = 3 x 2 = 6, got %s" % loop.last_wagered())


# --- 3. Two splittable spots -> 4 terminal hands ---
func _check_two_spot_both_split() -> void:
	var loop := CHGameLoop.new(_make_config(2), _fresh_state(), CHDisciplineSystem.new(), SEED)
	# up=5, hole=10; s1 = 7,7; s2 = 7,7. Follow-ups (idx 6..9) are non-7 so no
	# re-split: 2,3 for s1 and 4,5 for s2.
	_rig_opening(loop, [5, 10, 7, 7, 7, 7, 2, 3, 4, 5])
	_expect(loop.begin_hand(), "begin_hand")
	loop.place_bet(1)
	# Both roots are 7,7 vs 5 -> split. Drive the two presplit decisions.
	if loop.phase() != CHGameLoop.PHASE_PRESPLIT:
		_failures.append("expected PRESPLIT after placing bet, got %s" % loop.phase())
		return
	loop.apply_action(loop.optimal_action())  # split spot 1
	loop.apply_action(loop.optimal_action())  # split spot 2
	_expect(loop.all_hands().size() == 4, "two 7,7 splits -> 4 terminal hands, got %d" % loop.all_hands().size())
	_settle(loop)
	_expect(loop.is_idle(), "round settled, phase=%s" % loop.phase())


# --- 4. Card conservation across a settled multi-spot round ---
func _check_card_conservation_multi() -> void:
	var loop := CHGameLoop.new(_make_config(3), _fresh_state(), CHDisciplineSystem.new(), SEED)
	_rig_opening(loop, [5, 10, 8, 5, 9, 4, 7, 6])
	_expect(loop.begin_hand(), "begin_hand")
	loop.place_bet(2)
	_settle(loop)
	_expect(loop.is_idle(), "round settled, phase=%s" % loop.phase())
	var shoe := loop.get_shoe()
	var dealt: int = shoe.cards_dealt()
	var seen := 0
	for j in dealt:
		if shoe.deck[j].seen:
			seen += 1
	_expect(seen == dealt, "card conservation: %d/%d dealt cards seen" % [seen, dealt])


# --- 5. Dealer bust pays EVERY spot (M59) ---
# 2 spots, both hard 17 (stand vs upcard 7). Dealer 7+7=14 must hit; rig the
# next card to an 8 -> 22 bust. Each 17 beats a busted dealer -> +1 per hand.
func _check_dealer_bust_pays_each_hand() -> void:
	var loop := CHGameLoop.new(_make_config(2), _fresh_state(), CHDisciplineSystem.new(), SEED)
	# up=7, hole=7; s1 = 9,8 (17), s2 = 10,7 (17). Dealer hit card (idx 6) = 8.
	_rig_opening(loop, [7, 7, 9, 8, 10, 7, 8])
	_expect(loop.begin_hand(), "dealer-bust: begin_hand")
	loop.place_bet(3)
	_settle(loop)
	_expect(loop.is_idle(), "dealer-bust: round settled, phase=%s" % loop.phase())
	_expect(loop.last_wagered() == 6.0, "dealer-bust: wagered = 2 x 3 = 6, got %s" % loop.last_wagered())
	_expect(loop.last_net() == 6.0, "dealer-bust: each 17 wins -> net +6, got %s" % loop.last_net())


# --- 6. All-push round nets zero (M59) ---
# 2 spots, both 17. Dealer 7+10 = 17 (hard, S17 stands). Both push.
func _check_all_pushes_net_zero() -> void:
	var loop := CHGameLoop.new(_make_config(2), _fresh_state(), CHDisciplineSystem.new(), SEED)
	# up=7, hole=10; s1 = 9,8 (17), s2 = 10,7 (17).
	_rig_opening(loop, [7, 10, 9, 8, 10, 7])
	_expect(loop.begin_hand(), "push: begin_hand")
	loop.place_bet(2)
	_settle(loop)
	_expect(loop.is_idle(), "push: round settled, phase=%s" % loop.phase())
	_expect(loop.last_wagered() == 4.0, "push: wagered = 2 x 2 = 4, got %s" % loop.last_wagered())
	_expect(loop.last_net() == 0.0, "push: both 17 vs dealer 17 -> net 0, got %s" % loop.last_net())


# --- 7. Insurance scales with spot count (M59) ---
# 2 spots, dealer Ace upcard + 10 hole (BJ). Taking insurance: the side-bet is
# spots * max(1, base/2) = 2 * 2 = 4, NOT one spot's worth. Dealer BJ -> insurance
# pays 2:1 (+8), both spots lose the main (-4 each = -8). Net 0, wagered 12.
func _check_insurance_scales_with_spots() -> void:
	var loop := CHGameLoop.new(_make_config(2), _fresh_state(), CHDisciplineSystem.new(), SEED)
	# up=Ace, hole=10; s1 = 8,8 (16), s2 = 9,4 (13).
	_rig_opening(loop, [14, 10, 8, 8, 9, 4])
	_expect(loop.begin_hand(), "insurance: begin_hand")
	loop.place_bet(4)
	_expect(loop.phase() == CHGameLoop.PHASE_INSURANCE, "insurance: in PHASE_INSURANCE, got %s" % loop.phase())
	loop.apply_action(CHGameLoop.ACT_INS_TAKE)
	_expect(loop.is_idle(), "insurance: settled after natural, phase=%s" % loop.phase())
	_expect(loop.last_wagered() == 12.0, "insurance: wagered = 2 x 4 main + 4 ins = 12, got %s" % loop.last_wagered())
	_expect(loop.last_net() == 0.0, "insurance: -8 main + 8 ins (2:1 on 4) = 0, got %s" % loop.last_net())


# --- 8. Multi-spot insurance is FORFEITED when the dealer has no natural (M72) ---
# 2 spots, base bet 4, Ace upcard with a non-10 hole (no dealer BJ). Taking
# insurance scales the side-bet with the spot count (2 * max(1, 4/2) = 4, not
# one spot's worth). When the dealer shows no natural, _play_dealer_and_settle
# forfeits the FULL scaled side-bet on top of the main-hand P&L. The win path
# (dealer BJ pays the scaled side-bet) is pinned by check 7; this pins the
# symmetric loss path.
func _check_insurance_forfeit_multi_spot() -> void:
	var loop := CHGameLoop.new(_make_config(2), _fresh_state(), CHDisciplineSystem.new(), SEED)
	# up=Ace, hole=5 (dealer 19, no BJ); s1 = 9,8 (17), s2 = 10,7 (17). Both stand
	# and both lose to the dealer's 19.
	_rig_opening(loop, [14, 5, 9, 8, 10, 7])
	_expect(loop.begin_hand(), "ins-forfeit: begin_hand")
	loop.place_bet(4)
	_expect(loop.phase() == CHGameLoop.PHASE_INSURANCE, "ins-forfeit: in PHASE_INSURANCE, got %s" % loop.phase())
	loop.apply_action(CHGameLoop.ACT_INS_TAKE)
	_settle(loop)
	_expect(loop.is_idle(), "ins-forfeit: round settled, phase=%s" % loop.phase())
	# 2 spots x 4 main = 8; insurance side-bet = 2 * max(1, 4/2) = 4.
	_expect(loop.last_wagered() == 12.0, "ins-forfeit: wagered = 8 main + 4 ins = 12, got %s" % loop.last_wagered())
	# No dealer BJ -> full scaled side-bet forfeited; both 17s lose to 19.
	_expect(loop.last_net() == -12.0, "ins-forfeit: -8 main + -4 ins forfeit = -12, got %s" % loop.last_net())


# --- 9. One natural + one non-natural spot, no dealer natural (M105) ---
# 2 spots, base bet 3, dealer up=5 hole=10 (15, no natural). s1 = A,K (natural),
# s2 = 10,8 (18, plays). Before M105 the whole round auto-settled and s2 lost its
# full bet (-3); now only s1 settles (3:2) and s2 plays out. The engine's table
# stands on 18 vs 5, and the dealer (15) hits a 2 to reach 17, so s2 wins.
# Net: s1 +4.5 (natural) + s2 +3.0 (win) = +7.5. Old buggy code gave +1.5.
func _check_one_natural_other_spot_plays() -> void:
	var loop := CHGameLoop.new(_make_config(2), _fresh_state(), CHDisciplineSystem.new(), SEED)
	# up=5, hole=10; s1 = A,K (natural), s2 = 10,8 (18, stands and wins).
	_rig_opening(loop, [5, 10, 14, 13, 10, 8])
	_expect(loop.begin_hand(), "one-nat: begin_hand")
	loop.place_bet(3)
	_settle(loop)
	_expect(loop.is_idle(), "one-nat: round settled, phase=%s" % loop.phase())
	_expect(loop.last_wagered() == 6.0, "one-nat: wagered = 2 x 3 = 6, got %s" % loop.last_wagered())
	# s1 natural wins 3:2 (+4.5); s2 plays and wins (+3). NOT the old auto-loss
	# of s2 (which would have read net +1.5).
	_expect(loop.last_net() == 7.5, "one-nat: s1 pays 3:2 + s2 wins -> net +7.5, got %s" % loop.last_net())


func _fresh_state() -> CHGameState:
	var s := CHGameState.new()
	s.start_session(1, CHGameState.MODE_PRACTICE)
	return s
