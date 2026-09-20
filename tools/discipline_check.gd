extends SceneTree
# Validates CHDisciplineSystem invariants:
#   1. Recovery formula scales with current discipline (near-full > deep hole).
#   2. Cover-play cap: after MAX_COVER_PLAYS_PER_SHOE declarations, next returns false.
#   3. Outcome independence: grade_bet with same bet/optimal but different
#      after_loss produces identical discipline delta.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

func _init() -> void:
	var failures: Array[String] = []

	# --- Check 1: Recovery scales with current discipline ---
	var high := CHDisciplineSystem.new()
	high.discipline = CHDisciplineSystem.MAX_DISCIPLINE  # 100.0
	var rec_high: Dictionary = high.grade_decision("stand", "stand")

	var low := CHDisciplineSystem.new()
	low.discipline = CHDisciplineSystem.MAX_DISCIPLINE * 0.5  # 50.0
	var rec_low: Dictionary = low.grade_decision("stand", "stand")

	var delta_high: float = rec_high.delta
	var delta_low: float = rec_low.delta
	if delta_high > 0.0 and delta_low > 0.0 and delta_high > delta_low:
		print("PASS  recovery scales with discipline: high=%.2f > low=%.2f" % [delta_high, delta_low])
	else:
		failures.append("recovery scaling: high=%.2f low=%.2f" % [delta_high, delta_low])

	# --- Check 2: Cover-play cap ---
	var sys := CHDisciplineSystem.new()
	var granted := 0
	var cap := CHDisciplineSystem.MAX_COVER_PLAYS_PER_SHOE
	for i in range(cap + 1):
		if sys.declare_cover_play():
			granted += 1
	if granted == cap:
		print("PASS  cover-play cap: %d granted, %dth rejected" % [granted, cap + 1])
	else:
		failures.append("cover-play cap: granted %d, expected %d" % [granted, cap])

	# --- Check 3: Outcome independence of grade_bet ---
	var a := CHDisciplineSystem.new()
	var b := CHDisciplineSystem.new()
	var ra: Dictionary = a.grade_bet(5, 10, false)  # after_loss=false
	var rb: Dictionary = b.grade_bet(5, 10, true)   # after_loss=true
	if absf(ra.delta - rb.delta) < 0.001:
		print("PASS  outcome independence: delta_same=%.2f (after_loss does not affect penalty)" % ra.delta)
	else:
		failures.append("outcome independence: delta differs: %s vs %s" % [str(ra.delta), str(rb.delta)])

	# --- Check 4: Tilt detection (loss-chasing pattern) ---
	# check_tilt() reads bet_history and flags a 3-step pattern: two consecutive
	# losses whose bet sizes strictly rise into the third entry.

	# 4a. Fewer than 3 bets -> no tilt.
	var t0 := CHDisciplineSystem.new()
	t0.grade_bet(1, 1, true)
	t0.grade_bet(2, 2, true)
	if t0.check_tilt():
		failures.append("tilt: 2 entries should not be tilt")
	else:
		print("PASS  tilt: fewer than 3 bets -> no tilt")

	# 4b. Canonical positive: loss->loss with strictly rising bets -> tilt.
	var t1 := CHDisciplineSystem.new()
	t1.grade_bet(2, 2, true)   # a: loss, bet 2
	t1.grade_bet(3, 3, true)   # b: loss, bet 3 (rising)
	t1.grade_bet(4, 4, false)  # c: bet 4 (rising)
	if not t1.check_tilt():
		failures.append("tilt: loss->bigger->bigger should be tilt")
	else:
		print("PASS  tilt: loss->bigger->bigger flags tilt")

	# 4c. Two consecutive losses but flat bet on the 2nd -> no tilt.
	var t2 := CHDisciplineSystem.new()
	t2.grade_bet(3, 3, true)   # a: loss, bet 3
	t2.grade_bet(3, 3, true)   # b: loss, bet 3 (not rising)
	t2.grade_bet(4, 4, false)  # c: bet 4
	if t2.check_tilt():
		failures.append("tilt: two losses without rising bets should not be tilt")
	else:
		print("PASS  tilt: two losses without rising bets -> no tilt")

	# 4d. Rising bets but a win between the two losses -> no tilt.
	var t3 := CHDisciplineSystem.new()
	t3.grade_bet(2, 2, true)   # a: loss
	t3.grade_bet(3, 3, false)  # b: win (breaks the consecutive-loss run)
	t3.grade_bet(4, 4, true)   # c: loss
	if t3.check_tilt():
		failures.append("tilt: rising bets without two consecutive losses should not be tilt")
	else:
		print("PASS  tilt: rising bets without two consecutive losses -> no tilt")

	# 4e. An older bet before the pattern must not interfere (last 3 only).
	var t4 := CHDisciplineSystem.new()
	t4.grade_bet(1, 1, false)  # older entry, outside the last 3
	t4.grade_bet(2, 2, true)   # a: loss, bet 2
	t4.grade_bet(3, 3, true)   # b: loss, bet 3
	t4.grade_bet(4, 4, false)  # c: bet 4
	if not t4.check_tilt():
		failures.append("tilt: pattern in the last 3 of a longer history should still be tilt")
	else:
		print("PASS  tilt: pattern detected in last 3 of a longer history")

	# --- Check 5: Discipline clamps to [0, 100] ---
	# A wrong decision from a low discipline must floor at 0, not go negative.
	var c_low := CHDisciplineSystem.new()
	c_low.discipline = 3.0
	var cl: Dictionary = c_low.grade_decision("hit", "stand")  # wrong -> -4.0
	if absf(float(cl.delta) - (-CHDisciplineSystem.DECISION_PENALTY)) < 0.001 \
			and absf(c_low.discipline - 0.0) < 0.001:
		print("PASS  clamp lower: 3.0 + (-4.0) floors to 0.0, not negative")
	else:
		failures.append("clamp lower: delta=%.2f discipline=%.2f (expected -4.0 / 0.0)" % [cl.delta, c_low.discipline])
	# A correct decision at full discipline must cap at 100, not overshoot.
	var c_hi := CHDisciplineSystem.new()
	c_hi.discipline = CHDisciplineSystem.MAX_DISCIPLINE
	var ch: Dictionary = c_hi.grade_decision("stand", "stand")  # correct -> +recovery(2.0)
	if absf(c_hi.discipline - CHDisciplineSystem.MAX_DISCIPLINE) < 0.001:
		print("PASS  clamp upper: 100.0 + recovery caps at 100.0, not above")
	else:
		failures.append("clamp upper: discipline=%.2f (expected 100.0)" % c_hi.discipline)

	# --- Check 6: Exact grade magnitudes (decision + bet severity steps) ---
	# Correct decision at discipline 50 -> recovery = BASE_RECOVERY * 50/100 = 1.0.
	var m_mid := CHDisciplineSystem.new()
	m_mid.discipline = 50.0
	var md: Dictionary = m_mid.grade_decision("stand", "stand")
	if absf(float(md.delta) - 1.0) < 0.001:
		print("PASS  decision recovery magnitude: +1.0 at discipline 50")
	else:
		failures.append("decision recovery magnitude: delta=%.2f (expected +1.0 at discipline 50)" % md.delta)
	# Wrong decision -> always -DECISION_PENALTY regardless of discipline.
	var m_wrong := CHDisciplineSystem.new()
	var mw: Dictionary = m_wrong.grade_decision("hit", "stand")
	if absf(float(mw.delta) - (-CHDisciplineSystem.DECISION_PENALTY)) < 0.001:
		print("PASS  decision penalty magnitude: -%.0f" % CHDisciplineSystem.DECISION_PENALTY)
	else:
		failures.append("decision penalty magnitude: delta=%.2f (expected -%.0f)" % [mw.delta, CHDisciplineSystem.DECISION_PENALTY])
	# Bet severity steps by |diff|: 1 -> 1.0, 2 -> 2.0, 3+ -> 4.0 (all fresh, not cover).
	var bs1: Dictionary = CHDisciplineSystem.new().grade_bet(5, 4, false)  # diff 1
	var bs2: Dictionary = CHDisciplineSystem.new().grade_bet(6, 4, false)  # diff 2
	var bs3: Dictionary = CHDisciplineSystem.new().grade_bet(7, 4, false)  # diff 3
	if absf(float(bs1.delta) - (-CHDisciplineSystem.BET_SEVERITY_STEP_1)) < 0.001 \
			and absf(float(bs2.delta) - (-CHDisciplineSystem.BET_SEVERITY_STEP_2)) < 0.001 \
			and absf(float(bs3.delta) - (-CHDisciplineSystem.BET_SEVERITY_STEP_3)) < 0.001:
		print("PASS  bet severity steps: diff1->-%.0f, diff2->-%.0f, diff3->-%.0f"
			% [CHDisciplineSystem.BET_SEVERITY_STEP_1, CHDisciplineSystem.BET_SEVERITY_STEP_2, CHDisciplineSystem.BET_SEVERITY_STEP_3])
	else:
		failures.append("bet severity steps: diff1=%.2f diff2=%.2f diff3=%.2f" % [bs1.delta, bs2.delta, bs3.delta])

	# --- Check 6b: Recovery floor — discipline must be able to climb out of 0 ---
	# The rate is floored at MIN_RECOVERY_RATE, so a player who has fallen all the
	# way to 0 still recovers a little per correct play instead of staying stuck.
	var m_floor := CHDisciplineSystem.new()
	m_floor.discipline = CHDisciplineSystem.MIN_DISCIPLINE
	var md_floor: Dictionary = m_floor.grade_decision("stand", "stand")
	var floor_rate: float = CHDisciplineSystem.MIN_RECOVERY_RATE
	var expected_floor_recovery: float = CHDisciplineSystem.BASE_RECOVERY * floor_rate
	if absf(float(md_floor.delta) - expected_floor_recovery) < 0.001 \
			and absf(m_floor.discipline - expected_floor_recovery) < 0.001 \
			and float(md_floor.delta) > 0.0:
		print("PASS  recovery floor: at discipline 0 a correct play recovers +%.2f (climbs out of 0)" % expected_floor_recovery)
	else:
		failures.append("recovery floor: delta=%.2f discipline=%.2f (expected +%.2f off the 0 floor)" % [md_floor.delta, m_floor.discipline, expected_floor_recovery])
	# The floor must not change the scaled recovery above it (near-full stays fast).
	if absf(delta_high - CHDisciplineSystem.BASE_RECOVERY) < 0.001 \
			and absf(delta_low - CHDisciplineSystem.BASE_RECOVERY * 0.5) < 0.001:
		print("PASS  recovery floor: does not affect near-full/mid scaling")
	else:
		failures.append("recovery floor leaked into scaled rates: high=%.2f low=%.2f" % [delta_high, delta_low])

	# --- Check 7: Cover budget refills on reset_for_new_shoe ---
	var cv := CHDisciplineSystem.new()
	var cap2 := CHDisciplineSystem.MAX_COVER_PLAYS_PER_SHOE
	for i in range(cap2):
		if not cv.declare_cover_play():
			failures.append("cover refill: declare %d should be granted" % (i + 1))
	if cv.declare_cover_play():
		failures.append("cover refill: %dth declare should be rejected" % (cap2 + 1))
	elif cv.cover_plays_left() != 0:
		failures.append("cover refill: cover_plays_left()=%d, expected 0 after cap" % cv.cover_plays_left())
	else:
		cv.reset_for_new_shoe()
		if cv.cover_plays_left() == cap2:
			var refill_ok := true
			for i in range(cap2):
				if not cv.declare_cover_play():
					refill_ok = false
					break
			if refill_ok:
				print("PASS  cover budget: %d granted, then refilled to %d after reset_for_new_shoe" % [cap2, cap2])
			else:
				failures.append("cover refill: refilled budget not grantable again")
		else:
			failures.append("cover refill: after reset cover_plays_left()=%d, expected %d" % [cv.cover_plays_left(), cap2])

	# --- Summary ---
	if failures.is_empty():
		print("discipline_check: ALL PASS")
		quit(0)
	else:
		for f in failures:
			print("FAIL  ", f)
		print("discipline_check: %d failure(s)" % failures.size())
		quit(1)
