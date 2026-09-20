extends SceneTree
# Headless validation for the counting-deviation tell (M18).
#
# `CHStrategyEngine.is_counting_deviation` must report exactly when the I18
# deviation layer changes the play on top of the *full non-deviation pipeline*
# (basic + surrender + H17). A surrender is a basic-strategy play, not a
# counting tell, so a hand whose non-deviation play is "surrender" must NOT be
# reported as a deviation. Diffing against raw basic play mis-reported the
# two-card 16/15 vs 9/10 surrender hands as deviations at a high count.
#
# Checks:
#   1. Two-card 16 vs 9 (surrender on, high TC): best_play == "surrender" and
#      is_counting_deviation == false. No spurious tell.
#   2. Two-card 15 vs 10 (surrender on, high TC): best_play == "surrender" and
#      is_counting_deviation == false.
#   3. 13 vs 10 (no surrender, high TC): is_counting_deviation == true and
#      best_play == "stand" (genuine I18 stand deviation).
#   4. Soft 19 vs 9 (high TC): is_counting_deviation == true, best_play "stand".
#   5. 17 vs 5 (high TC): is_counting_deviation == false (no dev applies).
#   6. The loop's dev-tell gate (`optimal == action AND is_counting_deviation`)
#      fires on the genuine deviation hand and stays silent on the surrender
#      hand, so an optimal surrender no longer adds heat.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

const TC_HIGH := 3


var _failures: Array[String] = []


func _init() -> void:
	var engine := CHStrategyEngine.new()
	var surr_cfg := _surrender_config()
	var plain_cfg := _plain_config()
	var h17_cfg := _h17_config()

	_check_surrender_is_not_deviation(engine, surr_cfg, [9, 7], 9, "16v9")
	_check_surrender_is_not_deviation(engine, surr_cfg, [8, 7], 10, "15v10")
	_check_genuine_deviation(engine, plain_cfg, [8, 5], 10, "13v10")
	_check_soft19_deviation(engine, plain_cfg, [14, 8], 9, "S19v9")
	_check_no_deviation(engine, plain_cfg, [12, 5], 5, "17v5")
	_check_loop_dev_tell_gate(engine, surr_cfg)
	_check_h17_gate_suppresses_deviation(engine, plain_cfg, h17_cfg, [8, 5], 10, "H17 13v10")
	_check_h17_gate_suppresses_deviation(engine, plain_cfg, h17_cfg, [14, 8], 9, "H17 S19v9")

	if _failures.is_empty():
		print("deviation_check: ALL PASS (surrender not a dev tell; I18 tells intact; H17 gate suppresses I18)")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("deviation_check: %d failure(s)" % _failures.size())
		quit(1)


func _surrender_config() -> CHTableConfig:
	var c := CHTableConfig.new()
	c.allows_surrender = true
	c.late_surrender_only = true
	return c


func _plain_config() -> CHTableConfig:
	var c := CHTableConfig.new()
	c.allows_surrender = false
	return c


func _h17_config() -> CHTableConfig:
	var c := CHTableConfig.new()
	c.allows_surrender = false
	c.dealer_hits_soft_17 = true
	return c


func _make_hand(ranks: Array) -> CHHand:
	var h := CHHand.new()
	var i := 0
	for r in ranks:
		var suit: String = CHCard.SUITS[i % CHCard.SUITS.size()]
		h.add_card(CHCard.new(suit, int(r)))
		i += 1
	return h


# The regression: a two-card surrender hand must play "surrender" and must NOT
# be reported as a counting deviation (a surrender is basic strategy, not a tell).
func _check_surrender_is_not_deviation(
	engine: CHStrategyEngine, cfg: CHTableConfig, ranks: Array, dk: int, label: String
) -> void:
	var hand := _make_hand(ranks)
	var play: String = engine.best_play(hand, dk, cfg, TC_HIGH)
	var is_dev: bool = engine.is_counting_deviation(hand, dk, cfg, TC_HIGH)
	if play != "surrender":
		_failures.append("%s: best_play expected surrender got %s" % [label, play])
	if is_dev:
		_failures.append("%s: is_counting_deviation true for a surrender hand" % label)
	if play == "surrender" and not is_dev:
		print("PASS  %s -> surrender, not a counting deviation" % label)


# A hand with no legal surrender whose optimal play is an I18 stand deviation
# MUST be reported as a deviation (the tell is still alive).
func _check_genuine_deviation(
	engine: CHStrategyEngine, cfg: CHTableConfig, ranks: Array, dk: int, label: String
) -> void:
	var hand := _make_hand(ranks)
	var play: String = engine.best_play(hand, dk, cfg, TC_HIGH)
	var is_dev: bool = engine.is_counting_deviation(hand, dk, cfg, TC_HIGH)
	if play != "stand":
		_failures.append("%s: best_play expected stand got %s" % [label, play])
	if not is_dev:
		_failures.append("%s: is_counting_deviation false for a genuine I18 deviation" % label)
	if play == "stand" and is_dev:
		print("PASS  %s -> stand via I18, counted as deviation" % label)


# Soft 19 vs 9 at high TC is an I18 stand deviation.
func _check_soft19_deviation(
	engine: CHStrategyEngine, cfg: CHTableConfig, ranks: Array, dk: int, label: String
) -> void:
	var hand := _make_hand(ranks)
	var play: String = engine.best_play(hand, dk, cfg, TC_HIGH)
	var is_dev: bool = engine.is_counting_deviation(hand, dk, cfg, TC_HIGH)
	if play != "stand":
		_failures.append("%s: best_play expected stand got %s" % [label, play])
	if not is_dev:
		_failures.append("%s: is_counting_deviation false for soft 19 deviation" % label)
	if play == "stand" and is_dev:
		print("PASS  %s -> stand via I18, counted as deviation" % label)


# A plain high hand with no applicable I18 rule is not a deviation.
func _check_no_deviation(
	engine: CHStrategyEngine, cfg: CHTableConfig, ranks: Array, dk: int, label: String
) -> void:
	var hand := _make_hand(ranks)
	var is_dev: bool = engine.is_counting_deviation(hand, dk, cfg, TC_HIGH)
	if is_dev:
		_failures.append("%s: is_counting_deviation true but no I18 rule applies" % label)
	if not is_dev:
		print("PASS  %s -> no deviation (no I18 rule applies)" % label)


# The I18 layer is calibrated for S17 (see StrategyEngine._apply_deviation). On a
# dealer-hits-soft-17 table it is gated off entirely, so the *same* hand that is a
# genuine I18 stand deviation on S17 must fall back to basic play on H17 and be
# reported as NO deviation. This pins that the gate actually suppresses the tell
# on H17 tiers (T3-T6), where applying S17 deviations made the count a net loss.
# The S17 control confirms the hand still fires where it should.
func _check_h17_gate_suppresses_deviation(
	engine: CHStrategyEngine, s17_cfg: CHTableConfig, h17_cfg: CHTableConfig, ranks: Array, dk: int, label: String
) -> void:
	var hand := _make_hand(ranks)
	# Control: on S17 this hand must be a live I18 stand deviation.
	var s17_play: String = engine.best_play(hand, dk, s17_cfg, TC_HIGH)
	var s17_dev: bool = engine.is_counting_deviation(hand, dk, s17_cfg, TC_HIGH)
	if s17_play != "stand" or not s17_dev:
		_failures.append("%s control: expected S17 I18 stand deviation, got play=%s dev=%s" % [label, s17_play, s17_dev])
	# Gate: on H17 the same hand must NOT deviate — fall back to basic play.
	var h17_play: String = engine.best_play(hand, dk, h17_cfg, TC_HIGH)
	var h17_dev: bool = engine.is_counting_deviation(hand, dk, h17_cfg, TC_HIGH)
	if h17_dev:
		_failures.append("%s: H17 gate failed to suppress the I18 deviation (is_counting_deviation=true)" % label)
	if h17_play == s17_play:
		_failures.append("%s: H17 play %s still matches the S17 deviation; gate is a no-op" % [label, h17_play])
	if not h17_dev and h17_play != s17_play:
		print("PASS  %s: S17->stand(dev) vs H17->%s(no dev), gate suppresses I18 on H17" % [label, h17_play])


# Emulates the loop's dev-tell gate (`action == optimal AND is_counting_deviation`)
# for both a surrender hand and a genuine deviation hand: the gate must fire only
# on the deviation, never on an optimal surrender.
func _check_loop_dev_tell_gate(engine: CHStrategyEngine, cfg: CHTableConfig) -> void:
	var surr_hand := _make_hand([9, 7])
	var surr_opt: String = engine.best_play(surr_hand, 9, cfg, TC_HIGH)
	var surr_tell: bool = surr_opt != "" and engine.is_counting_deviation(surr_hand, 9, cfg, TC_HIGH)
	if surr_tell:
		_failures.append("gate: dev-tell fired on an optimal surrender")

	var dev_hand := _make_hand([8, 5])
	var dev_opt: String = engine.best_play(dev_hand, 10, cfg, TC_HIGH)
	var dev_tell: bool = dev_opt != "" and engine.is_counting_deviation(dev_hand, 10, cfg, TC_HIGH)
	if not dev_tell:
		_failures.append("gate: dev-tell did not fire on a genuine I18 deviation")

	if not surr_tell and dev_tell:
		print("PASS  gate: tell fires on deviation, silent on optimal surrender")
