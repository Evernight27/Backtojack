class_name CHHeatSystem
extends RefCounted
# Models "heat": how much suspicion the pit has of the player as a counter.
#
# Heat is session-scoped. It starts at the tier's reputation floor, builds from
# "tells" (counting-revealing behavior — betting big on a high true count,
# taking insurance at a high count, making a counting deviation), and decays as
# the player lays low (a fixed amount each settled hand). When it reaches the
# backoff threshold a backoff is latched: the player must cool down, and the
# next hand resets heat to the tier floor (residual suspicion, not zero).
#
# Pure RefCounted model — no autoload/signal dependencies, fully testable
# headless. The CHGameLoop owns an instance and feeds it from player actions.

const MAX_HEAT: float = 100.0
const BACKOFF_THRESHOLD: float = 100.0

# Base heat gained per tell type, before the tier sensitivity multiplier.
const BET_TELL_GAIN: float = 6.0        # betting up on a high true count
const INSURANCE_TELL_GAIN: float = 4.0  # taking insurance on a high count (a tell)
const DEV_TELL_GAIN: float = 2.0        # making a counting (I18) deviation

# Heat shed each settled hand when the player lays low (no new tell that hand).
const DECAY_PER_HAND: float = 3.0

# A bet "reads as counting" when the true count is at/above this and the stake
# is at/least this many units (the classic big-bet-on-high-count tell).
const BET_TELL_TC: int = 2
const BET_TELL_MIN_UNITS: int = 4

var heat: float = 0.0
var sensitivity: float = 1.0
var pending_backoff: bool = false


# (Re)starts heat at the tier floor. Clears any latched backoff.
func reset(floor_value: float) -> void:
	heat = clampf(floor_value, 0.0, MAX_HEAT)
	pending_backoff = false


func apply_sensitivity(mult: float) -> void:
	sensitivity = mult


# Records a tell. `gain_base` is the tell's base gain (one of the *_TELL_GAIN
# constants). Returns the heat actually added (0 when already at the ceiling).
func on_tell(gain_base: float) -> float:
	var gain := gain_base * sensitivity
	var before := heat
	heat = clampf(heat + gain, 0.0, MAX_HEAT)
	if heat >= BACKOFF_THRESHOLD:
		pending_backoff = true
	return heat - before


# Laying low: shed a fixed amount of heat per hand. Returns the heat removed.
# Decay does not clear a latched backoff (once you're flagged, cooling down is
# the player's explicit next step, not a quiet fade-out).
func on_hand() -> float:
	if heat <= 0.0:
		return 0.0
	var before := heat
	heat = maxf(0.0, heat - DECAY_PER_HAND)
	return before - heat


func has_pending_backoff() -> bool:
	return pending_backoff
