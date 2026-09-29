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
# Fixed composure restored by a deliberate "ground yourself" action (a player
# agency lever against the spiral). Unlike on_success it does not scale with
# current stability: a deep hole still gets the full top-up, which is the point
# of an intentional reset.
const GROUND_RECOVERY: float = 15.0
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
# The lowest stability the player hit this session — the debrief's "how far they
# fell" read-out. Starts at the ceiling and only ever drops.
var min_stability: float = MAX_MENTAL

# Effective parameters. Default to the historical constants above so a system
# constructed without configure() behaves exactly as before; CHGameLoop calls
# configure() with the per-tier profile (CHMentalConfig.for_tier) so the spiral
# tightens up the tier ladder.
var _mistake_base: float = BASE_MISTAKE
var _streak_escalation: float = STREAK_ESCALATION
var _recovery_base: float = BASE_RECOVERY
var _fraying_threshold: float = FRAYING_THRESHOLD
var _insane_threshold: float = INSANE_THRESHOLD
var _insane_amplifier: float = 1.0
var _heat_link: float = 1.0


# Applies a per-tier profile (CHMentalConfig). Called once at loop init. Without
# a call the system keeps the historical (tier-1) constants, so existing tests
# and behaviour are unchanged.
func configure(profile: CHMentalConfig) -> void:
	if profile == null:
		return
	_mistake_base = profile.mistake_base
	_streak_escalation = profile.streak_escalation
	_recovery_base = profile.recovery_base
	_fraying_threshold = profile.fraying_threshold
	_insane_threshold = profile.insane_threshold
	_insane_amplifier = profile.insane_amplifier
	_heat_link = profile.heat_link


# (Re)starts composure at the ceiling and clears the mistake run.
func reset() -> void:
	stability = MAX_MENTAL
	mistake_streak = 0
	max_mistake_streak = 0
	min_stability = MAX_MENTAL


# A non-optimal play. Returns the stability lost. The penalty escalates with the
# current mistake run, so consecutive misses cost more and more. `scale` lets
# callers weight the lapse (e.g. a 1-off bet is a nudge, a 4+ off is a full
# lapse); it defaults to 1.0 for a plain play decision.
func on_mistake(scale: float = 1.0) -> float:
	var before := stability
	var penalty := _mistake_base * (1.0 + _streak_escalation * float(mistake_streak))
	# The spiral: a mistake made while already insane costs extra — the player is
	# rattled enough that errors compound. The MIN_RECOVERY floor in on_success
	# guarantees a run of correct plays always climbs out, so this is a pressure
	# term, never a hard fail. No-op at the default amplifier (1.0).
	if is_insane():
		penalty *= _insane_amplifier
	penalty *= scale
	stability = maxf(stability - penalty, MIN_MENTAL)
	if stability < min_stability:
		min_stability = stability
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
	var recovery: float = _recovery_base * rate
	stability = minf(stability + recovery, MAX_MENTAL)
	mistake_streak = 0
	return stability - before


# True when the player has fully spiralled (below the insanity threshold).
func is_insane() -> bool:
	return stability < _insane_threshold


# The coarse stability state (one of the STATE_* strings).
func mental_state() -> String:
	if stability < _insane_threshold:
		return STATE_INSANE
	if stability < _fraying_threshold:
		return STATE_FRAYING
	if stability < STRAINED_THRESHOLD:
		return STATE_STRAINED
	return STATE_CALM


# The per-tier profile multiplier applied to a mistake while already insane
# (the spiral's mechanical consequence). 1.0 == no amplification.
func insane_amplifier() -> float:
	return _insane_amplifier


# A deliberate "ground yourself" action: a fixed composure top-up that also
# breaks the mistake streak. This is the player's agency lever against the
# spiral — spending it is a choice, so it is budgeted per shoe by the loop.
# Returns the composure regained (0 when already at the ceiling).
func ground() -> float:
	var before := stability
	stability = minf(stability + GROUND_RECOVERY, MAX_MENTAL)
	mistake_streak = 0
	return stability - before


# The per-tier heat-link multiplier (1.0 == off). The GameLoop applies it to tell
# heat gains while the player is insane so a rattled counter is more suspicious.
func heat_link() -> float:
	return _heat_link


# How deep the player is in the fray/insane region: 0 (calm/full) .. 1 (well
# below the insanity threshold). Used by the scene to scale continuous effects
# (thought frequency, misread, hesitation) so degradation feels gradual rather
# than a single stepped jump.
func depth() -> float:
	var span: float = MAX_MENTAL - _insane_threshold
	if span <= 0.0:
		return 1.0
	return clampf((MAX_MENTAL - stability) / span, 0.0, 1.0)


# Probability that the visible running-count flickers to a wrong value for one
# frame. 0 above the fraying band, ramps 0->0.1 across the fraying band, flat
# 0.2 once fully insane. Purely a visual lever — it never changes game logic.
func misread_probability() -> float:
	if stability >= _fraying_threshold:
		return 0.0
	if stability < _insane_threshold:
		return 0.2
	var span: float = _fraying_threshold - _insane_threshold
	if span <= 0.0:
		return 0.05
	return lerp(0.0, 0.1, clampf((_fraying_threshold - stability) / span, 0.0, 1.0))
