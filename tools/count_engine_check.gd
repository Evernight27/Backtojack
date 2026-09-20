extends SceneTree
# Headless validation for CHCountEngine — the counting primitive every other
# system builds on but no dedicated tool pinned directly. `count_check` covers
# the accuracy-grading system and `tables_check` covers per-card count values;
# this pins the engine's own math:
#
#   1. reset(): fresh engine starts at RC 0, 1.0 deck, hi_lo, TC 0.
#   2. record_card(): accumulates running_count by the card's count value and
#      returns that value; a card already seen is a no-op (returns 0).
#   3. true_count_value(): RC / decks_remaining, for positive and negative RC.
#   4. true_count_floor(): the canonical floor() must round toward -infinity.
#      This is load-bearing: the low-TC "hit" deviations (tc <= -1 / -2) and
#      the insurance threshold only fire correctly when -1.5 reads as -2, not
#      the -1 a truncation toward zero would give.
#   5. set_decks_remaining(): clamps the estimate to a 0.1 floor so a drained
#      shoe still divides safely and reads as a large count.
#   6. true_count_value(): the decks_remaining <= 0 guard returns the raw RC.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

var _failures: Array[String] = []


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _init() -> void:
	_check_reset_defaults()
	_check_record_accumulates()
	_check_record_idempotent()
	_check_true_count_division()
	_check_floor_toward_negative_infinity()
	_check_decks_clamp()
	_check_zero_decks_guard()
	_finish()


# --- 1. reset(): a fresh engine has a zero count and one full deck. ---
func _check_reset_defaults() -> void:
	var e := CHCountEngine.new()
	_expect(e.running_count == 0, "fresh running_count is 0, got %d" % e.running_count)
	_expect(absf(e.decks_remaining - 1.0) < 1e-9, "fresh decks_remaining is 1.0, got %f" % e.decks_remaining)
	_expect(e.count_system == "hi_lo", "default system is hi_lo, got %s" % e.count_system)
	_expect(absf(e.true_count_value()) < 1e-9, "fresh true_count_value is 0.0, got %f" % e.true_count_value())
	_expect(e.true_count_floor() == 0, "fresh true_count_floor is 0, got %d" % e.true_count_floor())
	# reset() restores the same state even after mutation.
	e.running_count = 7
	e.set_decks_remaining(0.5)
	e.reset()
	_expect(e.running_count == 0 and absf(e.decks_remaining - 1.0) < 1e-9, "reset() restores RC 0 / 1.0 deck")


# --- 2. record_card(): accumulates the count and returns the value applied. ---
func _check_record_accumulates() -> void:
	var e := CHCountEngine.new()
	# hi_lo: 2-6 = +1, 7-9 = 0, 10-14 = -1.
	var c2 := CHCard.new("S", 2)
	var r2 := e.record_card(c2)
	_expect(r2 == 1, "recording a 2 applies +1, got %d" % r2)
	_expect(e.running_count == 1, "RC after a 2 is 1, got %d" % e.running_count)
	e.record_card(CHCard.new("H", 3))
	e.record_card(CHCard.new("D", 9))   # 0
	_expect(e.running_count == 2, "RC after 2,3,9 is 2 (9 is 0), got %d" % e.running_count)
	e.record_card(CHCard.new("C", 10))  # -1
	_expect(e.running_count == 1, "RC after a 10 is 1, got %d" % e.running_count)
	e.record_card(CHCard.new("S", 14))  # ace -1
	_expect(e.running_count == 0, "RC after an ace is 0, got %d" % e.running_count)
	# record_card returns the value actually applied.
	var c5 := CHCard.new("S", 5)
	var r5 := e.record_card(c5)
	_expect(r5 == 1, "record_card returns the applied value (+1 for a 5), got %d" % r5)


# --- 3. record_card(): a card already seen is not counted twice. ---
func _check_record_idempotent() -> void:
	var e := CHCountEngine.new()
	var c := CHCard.new("S", 2)
	e.record_card(c)
	var before: int = e.running_count
	var again := e.record_card(c)
	_expect(again == 0, "re-recording a seen card returns 0, got %d" % again)
	_expect(e.running_count == before, "re-recording a seen card does not change RC")


# --- 4. true_count_value(): RC divided by decks remaining. ---
func _check_true_count_division() -> void:
	var e := CHCountEngine.new()
	e.running_count = 4
	e.set_decks_remaining(2.0)
	_expect(absf(e.true_count_value() - 2.0) < 1e-6, "4 / 2.0 decks = 2.0, got %f" % e.true_count_value())
	e.running_count = -4
	e.set_decks_remaining(3.0)
	_expect(absf(e.true_count_value() - (-4.0 / 3.0)) < 1e-6, "-4 / 3.0 decks = -1.333, got %f" % e.true_count_value())
	e.running_count = 1
	e.set_decks_remaining(4.0)
	_expect(absf(e.true_count_value() - 0.25) < 1e-6, "1 / 4.0 decks = 0.25, got %f" % e.true_count_value())


# --- 5. true_count_floor(): floors toward -infinity, not toward zero. ---
func _check_floor_toward_negative_infinity() -> void:
	var e := CHCountEngine.new()
	# Positive fraction truncates down.
	e.running_count = 3
	e.set_decks_remaining(2.0)   # 1.5
	_expect(e.true_count_floor() == 1, "floor(1.5) = 1, got %d" % e.true_count_floor())
	# The critical case: a negative fraction must floor to the next LOWER int.
	e.running_count = -3
	e.set_decks_remaining(2.0)   # -1.5
	_expect(e.true_count_floor() == -2, "floor(-1.5) = -2 (not -1), got %d" % e.true_count_floor())
	# Exact negative integer stays put.
	e.running_count = -4
	e.set_decks_remaining(2.0)   # -2.0
	_expect(e.true_count_floor() == -2, "floor(-2.0) = -2, got %d" % e.true_count_floor())
	# -0.5 must read as -1, so a tc <= -1 low-count "hit" deviation fires.
	e.running_count = -1
	e.set_decks_remaining(2.0)   # -0.5
	_expect(e.true_count_floor() == -1, "floor(-0.5) = -1 (not 0), got %d" % e.true_count_floor())
	# Positive sub-1 reads as 0.
	e.running_count = 1
	e.set_decks_remaining(2.0)   # 0.5
	_expect(e.true_count_floor() == 0, "floor(0.5) = 0, got %d" % e.true_count_floor())


# --- 6. set_decks_remaining(): clamps to a 0.1 minimum. ---
func _check_decks_clamp() -> void:
	var e := CHCountEngine.new()
	e.set_decks_remaining(0.0)
	_expect(absf(e.decks_remaining - 0.1) < 1e-9, "set_decks_remaining(0.0) clamps to 0.1, got %f" % e.decks_remaining)
	e.set_decks_remaining(0.04)
	_expect(absf(e.decks_remaining - 0.1) < 1e-9, "set_decks_remaining(0.04) clamps to 0.1, got %f" % e.decks_remaining)
	e.set_decks_remaining(3.2)
	_expect(absf(e.decks_remaining - 3.2) < 1e-9, "set_decks_remaining(3.2) passes through, got %f" % e.decks_remaining)
	# A nearly-drained shoe with a positive RC reads as a large count.
	e.running_count = 1
	e.set_decks_remaining(0.0)   # clamps to 0.1
	_expect(absf(e.true_count_value() - 10.0) < 1e-6, "RC 1 over the 0.1 floor = 10.0, got %f" % e.true_count_value())


# --- 7. true_count_value(): the decks <= 0 guard returns the raw running count. ---
func _check_zero_decks_guard() -> void:
	var e := CHCountEngine.new()
	e.running_count = 5
	e.decks_remaining = 0.0      # bypass the clamp to reach the guard branch
	_expect(absf(e.true_count_value() - 5.0) < 1e-6, "decks <= 0 returns raw RC, got %f" % e.true_count_value())
	_expect(e.true_count_floor() == 5, "decks <= 0 floor is the raw RC, got %d" % e.true_count_floor())


func _finish() -> void:
	# No session/loop is created here, so no save is written; clean defensively.
	var p := ProjectSettings.globalize_path("user://counting_house_save.json")
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

	if _failures.is_empty():
		print("count_engine_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("count_engine_check: %d failure(s)" % _failures.size())
		quit(1)
