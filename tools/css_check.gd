extends SceneTree
# Headless validation for M11 — continuous-shuffle (CSS) behavior.
#
# A continuous-shuffle machine has no exploitable count, so the loop must treat
# every decision as true-count 0: flat minimum bet, no I18 deviations, no
# count-based insurance, and no "counting reveal" heat tells. The raw count is
# still tracked internally (so the training display could show it), it is just
# never used for decisions.
#
# Checks:
#   1. CSS: effective_tc() is 0 even when the raw count is hot, while
#      current_tc() still reports the raw value.
#   2. CSS: optimal_bet_units() is a flat 1 regardless of the raw count.
#   3. Control (non-CSS): effective_tc() and optimal_bet_units() follow the raw
#      count (the ramp is live) — proves CSS is what flattens them.
#   4. CSS: insurance is declined even on a hot count; control takes it.
#   5. CSS: playing optimally across many hands never raises heat (no tells),
#      while the control's optimal bet still varies (ramp active).
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const SEED := 20260906
# A hot raw running count to prove the CSS loop ignores it.
const HOT_RUNNING_COUNT := 24

var _failures: Array[String] = []


func _init() -> void:
	_check_effective_tc_flat_under_css()
	_check_flat_bet_under_css()
	_check_control_uses_ramp()
	_check_insurance_under_css()
	_check_no_heat_builds_under_css()

	if _failures.is_empty():
		print("css_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("css_check: %d failure(s)" % _failures.size())
		quit(1)


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


# Builds a tier-1 teaching loop with the continuous_shuffle flag toggled.
func _make_loop(css: bool) -> CHGameLoop:
	var c := CHTableConfig.for_tier(1)
	c.continuous_shuffle = css
	c.allows_insurance = true
	var state := CHGameState.new()
	state.start_session(1, CHGameState.MODE_PRACTICE)
	var disc := CHDisciplineSystem.new()
	return CHGameLoop.new(c, state, disc, SEED)


# Makes the loop's current hand start on a hot raw count: set the running count
# high and start a fresh hand so _tc is recomputed from that state.
func _hot_hand(loop: CHGameLoop) -> void:
	var count: CHCountEngine = loop.get_count()
	count.running_count = HOT_RUNNING_COUNT
	count.decks_remaining = 1.0
	loop.begin_hand()


# --- 1. effective_tc flat under CSS, raw still tracked ---
func _check_effective_tc_flat_under_css() -> void:
	var css := _make_loop(true)
	_hot_hand(css)
	_expect(css.effective_tc() == 0, "CSS effective_tc() == 0 on hot count, got %d" % css.effective_tc())
	_expect(css.current_tc() == HOT_RUNNING_COUNT, "CSS current_tc() still reports raw %d, got %d" % [HOT_RUNNING_COUNT, css.current_tc()])


# --- 2. flat minimum bet under CSS ---
func _check_flat_bet_under_css() -> void:
	var css := _make_loop(true)
	_hot_hand(css)
	_expect(css.optimal_bet_units() == 1, "CSS optimal bet is flat 1, got %d" % css.optimal_bet_units())


# --- 3. control table still uses the count ramp ---
func _check_control_uses_ramp() -> void:
	var ctrl := _make_loop(false)
	_hot_hand(ctrl)
	_expect(ctrl.effective_tc() == HOT_RUNNING_COUNT, "control effective_tc() follows raw count, got %d" % ctrl.effective_tc())
	_expect(ctrl.optimal_bet_units() == 6, "control optimal bet ramps to 6 on hot count, got %d" % ctrl.optimal_bet_units())


# --- 4. insurance: CSS declines on hot count, control takes it ---
func _check_insurance_under_css() -> void:
	# Force the upcard to be an Ace so insurance is offered.
	var css := _make_loop(true)
	css.get_shoe().deck[0] = CHCard.new("S", 14)
	css.get_count().running_count = HOT_RUNNING_COUNT
	css.get_count().decks_remaining = 1.0
	_expect(css.begin_hand(), "css begin_hand")
	css.place_bet(1)
	_expect(css.phase() == CHGameLoop.PHASE_INSURANCE, "css in insurance phase after Ace upcard, got %s" % css.phase())
	_expect(css.optimal_action() == CHGameLoop.ACT_INS_DECLINE, "CSS declines insurance on hot count")

	var ctrl := _make_loop(false)
	ctrl.get_shoe().deck[0] = CHCard.new("S", 14)
	ctrl.get_count().running_count = HOT_RUNNING_COUNT
	ctrl.get_count().decks_remaining = 1.0
	ctrl.begin_hand()
	ctrl.place_bet(1)
	_expect(ctrl.phase() == CHGameLoop.PHASE_INSURANCE, "control in insurance phase")
	_expect(ctrl.optimal_action() == CHGameLoop.ACT_INS_TAKE, "control takes insurance on hot count")


# --- 5. CSS optimal play never builds heat; control ramp still varies ---
func _check_no_heat_builds_under_css() -> void:
	var css := _make_loop(true)
	var bets_seen: Array[int] = []
	for i in 12:
		if not css.is_idle():
			break
		css.begin_hand()
		var units: int = css.optimal_bet_units()
		bets_seen.append(units)
		css.place_bet(units)
		var guard := 0
		while not css.is_idle() and guard < 64:
			css.apply_action(css.optimal_action())
			guard += 1
	_expect(css.heat() == 0.0, "CSS heat stays at floor after optimal play, got %.1f" % css.heat())
	_expect(bets_seen.size() > 0 and bets_seen[0] == 1, "CSS first optimal bet is 1, got %s" % str(bets_seen))
	# Control: the ramp actually varies across a shoe (some hands bet more than 1).
	var ctrl := _make_loop(false)
	var ctrl_bets: Array[int] = []
	for i in 12:
		if not ctrl.is_idle():
			break
		ctrl.begin_hand()
		var units: int = ctrl.optimal_bet_units()
		ctrl_bets.append(units)
		ctrl.place_bet(units)
		var guard := 0
		while not ctrl.is_idle() and guard < 64:
			ctrl.apply_action(ctrl.optimal_action())
			guard += 1
	var varies := false
	for u in ctrl_bets:
		if u != 1:
			varies = true
			break
	_expect(varies, "control optimal bet varies across hands (ramp live), got %s" % str(ctrl_bets))
