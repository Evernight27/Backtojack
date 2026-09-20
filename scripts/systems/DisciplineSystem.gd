class_name CHDisciplineSystem
extends RefCounted
# Grades process (bet sizing vs count, decisions vs strategy) — never hand
# outcome. Losing on a correct play costs no Discipline; winning on an
# incorrect play gains none.
#
# Tilt detection is the deliberate exception: it reads `bet_history`, which
# is the only place hand outcome (after_loss) is permitted to feed. `after_loss`
# must never be used to compute the Discipline severity/penalty inside
# `grade_bet` — that is derived purely from abs(bet_units - optimal_units).

const SESSION_START_DISCIPLINE: float = 100.0
const MAX_DISCIPLINE: float = 100.0
const MIN_DISCIPLINE: float = 0.0
const MAX_COVER_PLAYS_PER_SHOE: int = 3
# Base recovery granted for a correct bet/decision. The actual recovery scales
# with current discipline (near-full recovers fast; deep holes recover slowly).
const BASE_RECOVERY: float = 2.0
# Floor on the recovery rate (discipline / MAX_DISCIPLINE) so a player who has
# fallen all the way to 0 can still climb out with correct play. Without it the
# rate hits exactly 0 and the meter is stuck at the floor for the rest of the
# session — contradicting "deep holes recover slowly" (which implies they DO
# recover, just slowly).
const MIN_RECOVERY_RATE: float = 0.05
const DECISION_PENALTY: float = 4.0
# Bet-sizing severity steps by absolute unit deviation from the optimal bet.
const BET_SEVERITY_STEP_1: float = 1.0
const BET_SEVERITY_STEP_2: float = 2.0
const BET_SEVERITY_STEP_3: float = 4.0

var discipline: float = SESSION_START_DISCIPLINE
# Bet history is the sole feed for check_tilt(); outcome (after_loss) is allowed
# here and nowhere else in the scoring path.
var bet_history: Array[Dictionary] = []
# Decision records for the current shoe. The Debrief screen MUST call
# get_and_clear_shoe_decisions() before reset_for_new_shoe(); an unconsumed
# log grows unbounded across a session (regression: session_length_check.gd).
var decision_log: Array[Dictionary] = []
var cover_plays_remaining: int = MAX_COVER_PLAYS_PER_SHOE
# --- Session decision record (process metric, independent of grading) ---
# How many play decisions the player made this session and how many matched
# the optimal play. Recorded unconditionally (regardless of the
# grade_decisions tier flag) because the debrief's "Decisions" line is a
# process read-out, not a scoring lever. Reset per session, not per shoe.
var session_decisions: int = 0
var session_optimal: int = 0


func reset_for_new_session() -> void:
	discipline = SESSION_START_DISCIPLINE
	bet_history.clear()
	decision_log.clear()
	cover_plays_remaining = MAX_COVER_PLAYS_PER_SHOE
	session_decisions = 0
	session_optimal = 0


# Records one play decision for the session process score. No scoring side
# effects: does not touch discipline, bet_history, or decision_log.
func record_decision(actual: String, optimal: String) -> void:
	session_decisions += 1
	if actual == optimal:
		session_optimal += 1


func reset_for_new_shoe() -> void:
	if decision_log.size() > 0:
		var msg := "CHDisciplineSystem: reset_for_new_shoe() called with %d unconsumed decisions; call get_and_clear_shoe_decisions() first" % decision_log.size()
		push_warning(msg)
	cover_plays_remaining = MAX_COVER_PLAYS_PER_SHOE


func get_and_clear_shoe_decisions() -> Array[Dictionary]:
	var out: Array[Dictionary] = decision_log.duplicate()
	decision_log.clear()
	return out


# Recovery scales WITH current discipline: a small dip near full recovers fast,
# a deep hole needs a sustained run to climb out. This is the corrected direction
# (previously implemented backwards). The rate is floored at MIN_RECOVERY_RATE so
# a player at the 0 floor still recovers a little per correct play — they cannot
# get stuck there, matching the "deep holes recover slowly" intent.
func _recovery_amount() -> float:
	var rate: float = maxf(discipline / MAX_DISCIPLINE, MIN_RECOVERY_RATE)
	return BASE_RECOVERY * rate


func _bet_severity(bet_units: int, optimal_units: int) -> float:
	var diff := absi(bet_units - optimal_units)
	if diff == 0:
		return 0.0
	if diff <= 1:
		return BET_SEVERITY_STEP_1
	if diff <= 2:
		return BET_SEVERITY_STEP_2
	return BET_SEVERITY_STEP_3


# Grades a bet against the count-optimal bet size.
# - `after_loss` feeds ONLY bet_history (tilt); it never affects the penalty.
# - `is_cover` exempts the bet from Discipline penalty (cover-play release valve).
# Returns {delta, severity, discipline}.
func grade_bet(bet_units: int, optimal_units: int, after_loss: bool, is_cover: bool = false) -> Dictionary:
	bet_history.append({"bet_units": bet_units, "after_loss": after_loss})
	var severity := _bet_severity(bet_units, optimal_units)
	var delta: float = 0.0
	if not is_cover:
		if severity > 0.0:
			delta = -severity
		else:
			delta = _recovery_amount()
		discipline = clampf(discipline + delta, MIN_DISCIPLINE, MAX_DISCIPLINE)
	decision_log.append(
		{"type": "bet", "bet_units": bet_units, "optimal_units": optimal_units,
		 "after_loss": after_loss, "is_cover": is_cover, "delta": delta}
	)
	return {"delta": delta, "severity": severity, "discipline": discipline}


# Grades a decision against strategy. No outcome parameter by construction.
# A correct decision grants the (discipline-scaled) recovery; an incorrect one
# pays a fixed penalty.
func grade_decision(actual: String, optimal: String) -> Dictionary:
	var delta: float
	if actual == optimal:
		delta = _recovery_amount()
	else:
		delta = -DECISION_PENALTY
	discipline = clampf(discipline + delta, MIN_DISCIPLINE, MAX_DISCIPLINE)
	decision_log.append(
		{"type": "decision", "actual": actual, "optimal": optimal, "delta": delta}
	)
	return {"delta": delta, "optimal": optimal, "discipline": discipline}


# Declares a bet as intentional cover. Returns true if cover was granted
# (within the per-shoe cap) and false once exhausted. The UI uses this to gate
# the cover declaration and to drive the "cover plays remaining" indicator.
func declare_cover_play() -> bool:
	if cover_plays_remaining <= 0:
		return false
	cover_plays_remaining -= 1
	return true


func cover_plays_left() -> int:
	return cover_plays_remaining


# Tilt: loss-chasing. Reads bet_history only — the one place hand outcome may
# influence a read. Flag when a loss is followed by a strictly larger bet, in a
# 3-step pattern (loss->bigger->loss->bigger).
func check_tilt() -> bool:
	var n := bet_history.size()
	if n < 3:
		return false
	var a: Dictionary = bet_history[n - 3]
	var b: Dictionary = bet_history[n - 2]
	var c: Dictionary = bet_history[n - 1]
	var chasing := bool(a.get("after_loss", false)) and bool(b.get("after_loss", false))
	var rising := int(b.get("bet_units", 0)) > int(a.get("bet_units", 0)) and int(c.get("bet_units", 0)) > int(b.get("bet_units", 0))
	return chasing and rising
