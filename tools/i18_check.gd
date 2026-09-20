extends SceneTree
# Headless validation for the full Illustrious-18 (I18) deviation table
# (M53). CHStrategyEngine encodes 18 count-dependent deviation thresholds as
# magic numbers. Prior tools only pinned a subset: spot_check exercises 6 of
# them and deviation_check focuses on the surrender-is-not-a-deviation
# distinction. This tool pins EVERY I18 threshold at its exact boundary:
#
#   - At the threshold TC the deviation must fire: is_counting_deviation()
#     returns true (the I18 layer changes the play on top of the full
#     non-deviation pipeline: basic + surrender + H17).
#   - One step just outside the threshold the deviation must NOT fire:
#     is_counting_deviation() returns false.
#
# "High" deviations (stand instead of hit on 13-16 vs 9/10, soft 19 vs 9/10)
# fire when tc >= threshold, so the just-outside probe is tc-1.
# "Low" deviations (hit instead of stand on 12-14 vs 4-6, stand instead of
# double on 11 vs 10) fire when tc <= threshold, so the just-outside probe is
# tc+1.
#
# A plain no-surrender, S17 config is used so the non-deviation base play is
# plain basic strategy and no surrender/H17 rule can interfere with the probe.
#
# PASS == all 18 boundary checks succeed. Exit 0 on pass, 1 on any fail.

# Plain config: no surrender, dealer stands soft 17 (default), so the base
# play under test is exactly basic strategy.
func _plain_cfg() -> CHTableConfig:
	var c := CHTableConfig.new()
	c.allows_surrender = false
	return c


func _make_hand(ranks: Array) -> CHHand:
	var h := CHHand.new()
	var i := 0
	for r in ranks:
		var suit: String = CHCard.SUITS[i % CHCard.SUITS.size()]
		h.add_card(CHCard.new(suit, int(r)))
		i += 1
	return h


# One I18 deviation row: ranks of the two-card hand, dealer upcard key, the
# threshold TC, and the direction ("high" == fire when tc >= threshold,
# "low" == fire when tc <= threshold).
var _cases: Array[Dictionary] = [
	# --- High-TC stands (stand instead of hit) ---
	{"ranks": [9, 7], "dk": 10, "tc": 3, "dir": "high", "label": "16v10"},
	{"ranks": [8, 7], "dk": 10, "tc": 2, "dir": "high", "label": "15v10"},
	{"ranks": [9, 5], "dk": 10, "tc": 3, "dir": "high", "label": "14v10"},
	{"ranks": [8, 5], "dk": 10, "tc": 3, "dir": "high", "label": "13v10"},
	{"ranks": [9, 7], "dk": 9, "tc": 2, "dir": "high", "label": "16v9"},
	{"ranks": [8, 7], "dk": 9, "tc": 2, "dir": "high", "label": "15v9"},
	{"ranks": [9, 5], "dk": 9, "tc": 2, "dir": "high", "label": "14v9"},
	{"ranks": [8, 5], "dk": 9, "tc": 2, "dir": "high", "label": "13v9"},
	{"ranks": [14, 8], "dk": 9, "tc": 2, "dir": "high", "label": "S19v9"},
	{"ranks": [14, 8], "dk": 10, "tc": 2, "dir": "high", "label": "S19v10"},
	# --- Low-TC hits (hit instead of stand) ---
	{"ranks": [10, 2], "dk": 4, "tc": -1, "dir": "low", "label": "12v4"},
	{"ranks": [8, 5], "dk": 4, "tc": -2, "dir": "low", "label": "13v4"},
	{"ranks": [9, 5], "dk": 4, "tc": -2, "dir": "low", "label": "14v4"},
	{"ranks": [10, 2], "dk": 5, "tc": -1, "dir": "low", "label": "12v5"},
	{"ranks": [8, 5], "dk": 5, "tc": -2, "dir": "low", "label": "13v5"},
	{"ranks": [9, 5], "dk": 5, "tc": -2, "dir": "low", "label": "14v5"},
	{"ranks": [10, 2], "dk": 6, "tc": -2, "dir": "low", "label": "12v6"},
	# --- Low-TC: stand instead of double on 11 vs 10 ---
	{"ranks": [6, 5], "dk": 10, "tc": -1, "dir": "low", "label": "11v10"},
]


var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	var engine := CHStrategyEngine.new()
	var cfg := _plain_cfg()

	for c in _cases:
		var hand := _make_hand(c.ranks)
		var dk: int = c.dk
		var tc: int = c.tc
		var label: String = c.label

		# At the threshold the I18 layer must change the play.
		var at_tc: bool = engine.is_counting_deviation(hand, dk, cfg, tc)
		_expect(at_tc, "%s: deviation should FIRE at tc=%d" % [label, tc])

		# Just outside the threshold it must not fire.
		var outside_tc: int = tc - 1 if c.dir == "high" else tc + 1
		var outside: bool = engine.is_counting_deviation(hand, dk, cfg, outside_tc)
		_expect(not outside, "%s: deviation should NOT fire at tc=%d (just outside)" % [label, outside_tc])

		if at_tc and not outside:
			print("PASS  %-8s fires at tc=%d, silent at tc=%d" % [label, tc, outside_tc])

	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("i18_check: ALL PASS (%d/18 I18 thresholds pinned)" % _cases.size())
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("i18_check: %d failure(s)" % _failures.size())
		quit(1)
