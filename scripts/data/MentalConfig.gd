class_name CHMentalConfig
extends RefCounted
# Per-tier mental-stability profile (the "going insane" spiral, CHMentalStateSystem).
#
# The spiral is a difficulty lever that tightens up the tier ladder, mirroring how
# the heat system scales with heat_sensitivity_multiplier. Harder tables erode
# stability faster (bigger mistake base + more streak escalation), recover more
# slowly (smaller recovery base), sit closer to the fraying/insane bands, and —
# from tier 4 — amplify a mistake made while the player is already insane. Tier 1
# keeps the historical defaults (8 / 0.5 / 6, bands 50 / 25) so the teaching table
# stays calm and the existing mental_check pins are unchanged.
#
# Pure data: the CHGameLoop applies it via CHMentalStateSystem.configure() at init.

# Base stability lost per non-optimal play.
var mistake_base: float = 8.0
# Each consecutive mistake in the run scales the penalty up by this fraction.
var streak_escalation: float = 0.5
# Base stability regained per correct play (scaled by current stability in the model).
var recovery_base: float = 6.0
# Stability below this reads as "fraying".
var fraying_threshold: float = 50.0
# Stability below this reads as "insane" (the full spiral).
var insane_threshold: float = 25.0
# Multiplier applied to a mistake's penalty while the player is already insane.
# 1.0 == no amplification (the historical behaviour; the teaching tiers).
var insane_amplifier: float = 1.0
# While insane, heat tells register at this multiple of normal gain (rattled =
# sloppier = more suspicious). 1.0 == off. Kept small so it is a pressure term,
# never a wall.
var heat_link: float = 1.0


# Builds the per-tier profile. The single source of truth for the mental-stability
# tier ladder (mirrors CHTableConfig.for_tier). Values are starting defaults meant
# to be tuned by playtest, not exact.
static func for_tier(tier: int) -> CHMentalConfig:
	var m := CHMentalConfig.new()
	match tier:
		1, 2:
			# Teaching / first real table: historical defaults (calm, ambient only).
			pass
		3:
			m.mistake_base = 9.0
			m.streak_escalation = 0.55
			m.recovery_base = 5.5
			m.fraying_threshold = 48.0
			m.insane_threshold = 24.0
			m.insane_amplifier = 1.15
		4:
			m.mistake_base = 10.0
			m.streak_escalation = 0.6
			m.recovery_base = 5.0
			m.fraying_threshold = 46.0
			m.insane_threshold = 22.0
			m.insane_amplifier = 1.3
			m.heat_link = 1.1
		5:
			m.mistake_base = 11.0
			m.streak_escalation = 0.65
			m.recovery_base = 4.5
			m.fraying_threshold = 44.0
			m.insane_threshold = 20.0
			m.insane_amplifier = 1.5
			m.heat_link = 1.2
		6:
			m.mistake_base = 12.0
			m.streak_escalation = 0.7
			m.recovery_base = 4.0
			m.fraying_threshold = 42.0
			m.insane_threshold = 18.0
			m.insane_amplifier = 1.75
			m.heat_link = 1.25
		_:
			# 7+: continuous-shuffle contrast. The count is meaningless here, so the
			# spiral's theme is "counting is futility" — a hard table that still
			# recovers (process, not punishment).
			m.mistake_base = 11.0
			m.streak_escalation = 0.65
			m.recovery_base = 4.5
			m.fraying_threshold = 44.0
			m.insane_threshold = 20.0
			m.insane_amplifier = 1.5
			m.heat_link = 1.2
	return m
