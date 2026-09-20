extends SceneTree
# Regression test: CHDisciplineSystem.decision_log must stay bounded across a
# long session when consumed properly. The original bug let it grow to 6000+
# entries over 50 shoes because nothing called get_and_clear_shoe_decisions().
#
# This check simulates 50 shoes of decisions, consuming the log each shoe via
# get_and_clear_shoe_decisions() before reset_for_new_shoe().
#
# PASS == the log is fully drained each shoe and the per-shoe peak stays far
# below an un-consumed session's worth. Exit 0 on pass, 1 on fail.

const SHOES := 50
const HANDS_PER_SHOE := 40
# 4 log entries per simulated hand (2 decisions + 2 bets).
const ENTRIES_PER_HAND := 4


func _init() -> void:
	var sys := CHDisciplineSystem.new()
	var peak := 0
	var final := 0
	var expected_per_shoe := ENTRIES_PER_HAND * HANDS_PER_SHOE

	for s in range(SHOES):
		for h in range(HANDS_PER_SHOE):
			sys.grade_decision("stand", "stand")
			sys.grade_decision("hit", "stand")
			sys.grade_bet(3, 3, false)
			sys.grade_bet(5, 3, true)
			if h % 7 == 0:
				sys.declare_cover_play()
		peak = maxi(peak, sys.decision_log.size())
		var drained: Array[Dictionary] = sys.get_and_clear_shoe_decisions()
		final = drained.size()
		sys.reset_for_new_shoe()
		if sys.decision_log.size() != 0:
			print("FAIL  log not empty after consume+reset in shoe %d: %d" % [s, sys.decision_log.size()])
			quit(1)

	var peak_ok := peak <= expected_per_shoe + 1
	var drained_ok := final == expected_per_shoe

	print("session_length: peak=%d (~%d/shoe expected), drained_last=%d (expect %d)" % [peak, expected_per_shoe, final, expected_per_shoe])
	if peak_ok and drained_ok:
		print("session_length_check: ALL PASS (log stays bounded, fully drained each shoe)")
		quit(0)
	else:
		if not peak_ok:
			print("FAIL  peak log %d exceeds per-shoe expectation %d" % [peak, expected_per_shoe])
		if not drained_ok:
			print("FAIL  last drain %d != expected %d" % [final, expected_per_shoe])
		quit(1)
