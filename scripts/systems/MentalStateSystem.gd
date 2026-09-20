class_name CHMentalStateSystem
extends RefCounted
# Models the player's mental stability across a session.
#
# It is a process-consistency layer, distinct from Discipline (bet/decision
# grading) and Heat (pit suspicion): it tracks how "in their head" the counter
# is. Every non-optimal play erodes stability, and — critically — a RUN of
# mistakes erodes it faster than isolated ones, so a player who keeps messing
# up spirals toward "insanity" while a player who gets things right steadies
# back out. It is session-scoped and purely presentational: it never distorts
# the controls or gates the table, matching the trainer's "process, not
# punishment" philosophy. A correct play is the only way to recover.
#
# Pure RefCounted model — no autoload/signal dependencies, fully testable
# headless. The CHGameLoop owns an instance and feeds it from every graded
# play decision.

# Stability ceiling/floor. Starts at the ceiling (composure) at session start.
const MAX_MENTAL: float = 100.0
const MIN_MENTAL: float = 0.0

# Base stability lost per non-optimal play.
const BASE_MISTAKE: float = 8.0
# Each consecutive mistake in the current run scales the penalty up by this
# fraction: the 1st mistake costs BASE_MISTAKE, the 2nd costs
# BASE_MISTAKE*(1+ESCALATION), the 3rd BASE_MISTAKE*(1+2*ESCALATION), etc. A
# correct play resets the run, so "keep messing up" is what drives the spiral.
const STREAK_ESCALATION: float = 0.5

# Base stability regained per correct play. The actual recovery is scaled by
# current stability (see on_success): the more composed the player already is,
# the quicker the top-up, so a deeper hole takes more correct plays to climb
# out — consistent with the Discipline meter's "deep holes recover slowly"
# principle (M97).
const BASE_RECOVERY: float = 6.0
# Floor on the recovery rate so a player at the floor still steadies a little
# per correct play and can always climb out — never stuck at 0.
const MIN_RECOVERY_RATE: float = 0.05

# Stability below this reads as "insane" (the full spiral). The higher bands
# (fraying / strained) sit above it.
const INSANE_THRESHOLD: float = 25.0
const FRAYING_THRESHOLD: float = 50.0
const STRAINED_THRESHOLD: float = 75.0

# The four stability states, low to high composure.
const STATE_INSANE := "insane"
const STATE_FRAYING := "fraying"
const STATE_STRAINED := "strained"
const STATE_CALM := "calm"

var stability: float = MAX_MENTAL
# How many non-optimal plays the player has made in a row without a correct one.
var mistake_streak: int = 0
# The longest mistake run this session — a session-level read-out for the
# debrief (how badly the player spiralled at their worst).
var max_mistake_streak: int = 0


# (Re)starts composure at the ceiling and clears the mistake run.
func reset() -> void:
	stability = MAX_MENTAL
	mistake_streak = 0
	max_mistake_streak = 0


# A non-optimal play. Returns the stability lost. The penalty escalates with the
# current mistake run, so consecutive misses cost more and more.
func on_mistake() -> float:
	var before := stability
	var penalty := BASE_MISTAKE * (1.0 + STREAK_ESCALATION * float(mistake_streak))
	stability = maxf(stability - penalty, MIN_MENTAL)
	mistake_streak += 1
	if mistake_streak > max_mistake_streak:
		max_mistake_streak = mistake_streak
	return before - stability


# A correct play. Returns the stability regained. Recovery scales with the
# player's current stability (the more composed, the quicker the top-up), so a
# deeper hole recovers more slowly — matching the Discipline meter's "deep holes
# recover slowly" principle (M97). The rate is floored so a correct play still
# steadies a little even at the floor and the player can always climb out. Resets
# the mistake run.
func on_success() -> float:
	var before := stability
	var rate: float = clampf(stability / MAX_MENTAL, MIN_RECOVERY_RATE, 1.0)
	var recovery: float = BASE_RECOVERY * rate
	stability = minf(stability + recovery, MAX_MENTAL)
	mistake_streak = 0
	return stability - before


# True when the player has fully spiralled (below the insanity threshold).
func is_insane() -> bool:
	return stability < INSANE_THRESHOLD


# The coarse stability state (one of the STATE_* strings).
func mental_state() -> String:
	if stability < INSANE_THRESHOLD:
		return STATE_INSANE
	if stability < FRAYING_THRESHOLD:
		return STATE_FRAYING
	if stability < STRAINED_THRESHOLD:
		return STATE_STRAINED
	return STATE_CALM
