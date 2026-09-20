class_name CHCountAccuracySystem
extends RefCounted
# Grades the player's running-count (RC) accuracy against the true count.
#
# A card-counting trainer's core skill is *tracking the running count*. At each
# shoe cut the loop asks the player to report the running count they believe
# they have; this system compares it to the engine's true value, scores the
# error, and maintains a session-level "accuracy" meter (running mean of per-
# check scores, 0-100) that blends into the skill-rating process score.
#
# Pure RefCounted: no autoload/signal dependencies, fully testable headless.
#
# Only the running count is checked here (the fundamental tracking skill). The
# true count (RC / decks-remaining) is a derived skill layered on top of deck
# estimation and is deliberately out of scope for this system.

# Per-check score curve: score = clamp(100 - PENALTY_PER_ERROR * |error|, 0, 100).
# Off-by-1 costs 5 points, off-by-5 costs 25, off-by-10+ floors toward 0. A
# shallow curve: a competent counter is off by 0-2 on a real shoe, so small
# errors stay high while a miscount (off-by-8+) collapses the check.
const PENALTY_PER_ERROR: float = 5.0
const MAX_ACCURACY: float = 100.0
const MIN_ACCURACY: float = 0.0

# Running-mean per-check score (0-100). 100 when no checks recorded yet (neutral).
var accuracy: float = MAX_ACCURACY
# Number of count checks recorded this session.
var checks: int = 0
# Most-recent check details (for the HUD / debrief feedback line).
var last_error: int = 0
var last_reported: int = 0
var last_actual: int = 0
var last_score: float = 0.0

# Accumulators for the running mean (kept so accuracy is an exact mean, not a
# drift-prone incremental lerp).
var _score_sum: float = 0.0


func reset_for_new_session() -> void:
	accuracy = MAX_ACCURACY
	checks = 0
	last_error = 0
	last_reported = 0
	last_actual = 0
	last_score = 0.0
	_score_sum = 0.0


# Records one count check. `reported_rc` is the player's reported running count,
# `actual_rc` is the engine's true running count at the cut. Returns a result
# Dictionary: {error, abs_error, score, reported, actual, accuracy, checks}.
func record(reported_rc: int, actual_rc: int) -> Dictionary:
	var error := reported_rc - actual_rc
	var abs_error := absi(error)
	var score: float = clampf(MAX_ACCURACY - PENALTY_PER_ERROR * float(abs_error), MIN_ACCURACY, MAX_ACCURACY)
	_score_sum += score
	checks += 1
	# Exact running mean (no floating drift from incremental averaging).
	accuracy = _score_sum / float(checks)
	last_error = error
	last_reported = reported_rc
	last_actual = actual_rc
	last_score = score
	return {
		"error": error,
		"abs_error": abs_error,
		"score": score,
		"reported": reported_rc,
		"actual": actual_rc,
		"accuracy": accuracy,
		"checks": checks,
	}
