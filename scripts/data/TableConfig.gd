class_name CHTableConfig
extends Resource
# Full rule-variant flags for a table. A single Resource covers every tier;
# M6 will author the tier 1-6 resources from these fields.
#
# Defaults here describe the Tier-1 teaching table: single deck, dealer stands
# on soft 17, 3:2 payout, doubles allowed on any two, splits up to 4, no
# surrender, no insurance prompt in the default sim.

var tier: int = 1
var name: String = "table"
# The place you're sitting at (the social-arc identity: friend's kitchen ->
# rec room -> card room -> casino -> pro circuit). Displayed in the tier
# selector and the session-start banner. `name` stays the rule-set descriptor.
var venue_name: String = ""
# One-line narrative hook shown as a banner at session start. Empty when there
# is no venue framing (e.g. headless tests).
var venue_hook: String = ""

# --- Shoe ---
var deck_count: int = 1
# Fraction of the shoe dealt before a forced reshuffle (0.70 = reshuffle at 70%).
var penetration: float = 0.70
# Coarseness of the player's decks-remaining estimate. Smaller == finer == harder.
var deck_estimation_rounding: float = 1.0
# Optional continuous-shuffle contrast mode (Tier 7+). Disables count-based edge.
var continuous_shuffle: bool = false
# Card-counting system the table is trained against. One of "hi_lo" (balanced,
# the canonical teaching system, matches the I18 deviations), "ko" (single-deck
# variant — no aces counted, unbalanced +8/deck), or "hi_opt_ii" (balanced,
# net 0/deck, counts 5-9 and J/Q as 0).
var count_system: String = "hi_lo"

# --- Dealer / payout ---
# Dealer hits soft 17 (H17). false == stands on soft 17 (S17).
var dealer_hits_soft_17: bool = false
# Net profit per unit bet on a blackjack: 3:2 == 1.5, 6:5 == 1.2.
var blackjack_payout: float = 1.5

# --- Player actions ---
var allows_double: bool = true
var allows_double_after_split: bool = true
var allows_split: bool = true
# Max number of hands a single initial hand may be split into (0 == no splits).
var max_split_hands: int = 4
# Split aces receive exactly one card each (no further action).
var split_aces_one_card_only: bool = true
var allows_surrender: bool = false
var late_surrender_only: bool = false  # true when allows_surrender (no early surrender)
var allows_insurance: bool = false
var insurance_payout: float = 2.0  # 2:1

# --- Play structure ---
# Multi-hand play (Tier 4+). Hands in play per spot.
var player_hand_count: int = 1
# NPC players seated at the table (0 = just you). Higher tiers add NPC seats
# to simulate a busier table and increase the visible card stream for counting.
var npc_players: int = 0
# The social opponent (venue arc): a named NPC with a tracked bankroll, a
# betting policy, and a skill level. When set, the opponent occupies the first
# NPC seat (if npc_players == 0 it adds one seat). Their P&L is session-scoped
# and never folds into the player's bankroll. null == anonymous filler only.
var opponent: CHOpponent = null

# --- Heat ---
# Scales the entire heat-gain formula for this table tier (not a 4th additive term).
var heat_sensitivity_multiplier: float = 1.0
# Tier where the Heat system is active (backoff possible).
var heat_active: bool = false

# --- Teaching / grading toggles ---
# Count-only teaching table (Tier 1): the player never bets, covers, or makes a
# play decision — the hand deals and plays itself and the player's only task is
# to report the running count (a number like +3 or -2) at each shoe cut.
var count_only: bool = false
# Training-wheels count display (Tier 1).
var show_count_display: bool = true
# Run a running-count accuracy check at each shoe cut (every tier except the
# continuous-shuffle tier, where counting has no edge).
var count_check_active: bool = false
# Discipline grading of decisions (Tier 2+).
var grade_decisions: bool = false
# Discipline grading of bet ramp adherence (Tier 3+).
var grade_bet_ramp: bool = false


# Per-tier social rival ("Sal"): the recurring friend/regular/shark who follows
# you up the venue ladder, getting sharper and better capitalized each tier.
# Fixed per-tier seed keeps the character deterministic on every visit. Inert
# for the sims (they build their own configs), so it never moves baselines.
static func _opponent_for_tier(p_tier: int):
	match p_tier:
		1:
			return CHOpponent.for_opponent("Sal", "friend", 0.35, 25, CHOpponent.POLICY_FLAT, 1, 701)
		2:
			return CHOpponent.for_opponent("Sal", "regular", 0.5, 50, CHOpponent.POLICY_FLAT, 1, 702)
		3:
			return CHOpponent.for_opponent("Sal", "regular", 0.6, 75, CHOpponent.POLICY_RAMP, 1, 703)
		4:
			return CHOpponent.for_opponent("Sal", "shark", 0.7, 100, CHOpponent.POLICY_RAMP, 1, 704)
		5:
			return CHOpponent.for_opponent("Sal", "shark", 0.8, 150, CHOpponent.POLICY_COUNT, 1, 705)
		6:
			return CHOpponent.for_opponent("Sal", "pro", 0.85, 200, CHOpponent.POLICY_COUNT, 1, 706)
		_:
			return CHOpponent.for_opponent("Sal", "pro", 0.9, 300, CHOpponent.POLICY_COUNT, 1, 707)


# Builds the rule variant for a given tier. This is the single source of truth
# for the tier ladder so the scene and any future menu pull from one place.
# The values are starting defaults (like TIER_SKILL_THRESHOLDS) and are meant
# to be tuned by playtest, not to be exact.
static func for_tier(_tier: int) -> CHTableConfig:
	var c := CHTableConfig.new()
	c.tier = _tier
	match c.tier:
		1:
			# Teaching table: single deck, S17, 3:2, full teaching aids on.
			# Count-only — the player just tracks the running count (the first
			# "what to look for" drill) with no betting / cover / play controls.
			c.name = "Teaching Table"
			c.venue_name = "Kitchen Table"
			c.venue_hook = "A friend dares you to count his single deck. Nobody is watching. Yet."
			c.deck_count = 1
			c.penetration = 0.70
			c.deck_estimation_rounding = 1.0
			c.dealer_hits_soft_17 = false
			c.blackjack_payout = 1.5
			c.allows_insurance = true
			c.allows_split = true
			c.max_split_hands = 4
			c.heat_active = true
			c.heat_sensitivity_multiplier = 1.0
			c.show_count_display = true
			c.count_check_active = true
			c.count_only = true
			c.count_system = "hi_lo"
		2:
			# Single deck, switch to the KO count, tighter grading.
			c.name = "Single-Deck"
			c.venue_name = "The Rec Room"
			c.venue_hook = "A regular at the rec room noticed you counting. Wants to see if it is real."
			c.npc_players = 1
			c.deck_count = 1
			c.penetration = 0.70
			c.deck_estimation_rounding = 1.0
			c.dealer_hits_soft_17 = false
			c.blackjack_payout = 1.5
			c.allows_insurance = true
			c.allows_split = true
			c.max_split_hands = 4
			c.heat_active = true
			c.heat_sensitivity_multiplier = 1.0
			c.show_count_display = true
			c.grade_decisions = true
			c.grade_bet_ramp = true
			c.count_check_active = true
			c.count_system = "ko"
		3:
			# Two decks, H17, insurance off — count for yourself.
			c.name = "Two-Deck"
			c.venue_name = "Card Room"
			c.venue_hook = "The card room lets you sit in. The dealer is not suspicious yet."
			c.npc_players = 1
			c.deck_count = 2
			c.penetration = 0.60
			c.deck_estimation_rounding = 0.5
			c.dealer_hits_soft_17 = true
			c.blackjack_payout = 1.5
			c.allows_insurance = false
			c.allows_split = true
			c.max_split_hands = 4
			c.heat_active = true
			c.heat_sensitivity_multiplier = 1.5
			c.show_count_display = false
			c.count_check_active = true
			c.grade_decisions = true
			c.grade_bet_ramp = true
			c.count_system = "hi_lo"
		4:
			# Four decks, two hands, surrender introduced (early — the forgiving
			# form) so the player learns the action before the pit tightens it to
			# late on the harder 6-deck / CSS tables. Finer estimation.
			c.name = "Four-Deck Multi-Hand"
			c.venue_name = "City Casino"
			c.venue_hook = "Your first real casino floor. Two hands per round, and the pit is watching."
			c.npc_players = 2
			c.deck_count = 4
			c.penetration = 0.50
			c.deck_estimation_rounding = 0.5
			c.dealer_hits_soft_17 = true
			c.blackjack_payout = 1.5
			c.allows_insurance = false
			c.allows_split = true
			c.max_split_hands = 4
			c.allows_surrender = true
			c.late_surrender_only = false
			c.player_hand_count = 2
			c.heat_active = true
			c.heat_sensitivity_multiplier = 2.0
			c.show_count_display = false
			c.count_check_active = true
			c.grade_decisions = true
			c.grade_bet_ramp = true
			c.count_system = "hi_lo"
		5:
			# Six decks, Hi-Opt II, the hardest "real" table.
			c.name = "Six-Deck Hi-Opt"
			c.venue_name = "High Stakes Floor"
			c.venue_hook = "They moved you to the tight table. Hi-Opt II, finer estimation, no slack."
			c.npc_players = 2
			c.deck_count = 6
			c.penetration = 0.50
			c.deck_estimation_rounding = 0.25
			c.dealer_hits_soft_17 = true
			c.blackjack_payout = 1.5
			c.allows_insurance = false
			c.allows_split = true
			c.max_split_hands = 4
			c.allows_surrender = true
			c.late_surrender_only = true
			c.player_hand_count = 2
			c.heat_active = true
			c.heat_sensitivity_multiplier = 2.5
			c.show_count_display = false
			c.count_check_active = true
			c.grade_decisions = true
			c.grade_bet_ramp = true
			c.count_system = "hi_opt_ii"
		6:
			# 6:5 payout "tough real table": the pit has tightened the blackjack
			# payout from 3:2 to 6:5 (net 1.2 instead of 1.5). 4-deck H17 with
			# late surrender and multi-hand, still Hi-Lo — isolates the payout
			# handicap as the new lesson before the CSS contrast tier.
			c.name = "Six-Five Payout"
			c.venue_name = "High Roller Pit"
			c.venue_hook = "6:5 payout. The house knows you are here and is squeezing."
			c.npc_players = 3
			c.deck_count = 4
			c.penetration = 0.50
			c.deck_estimation_rounding = 0.5
			c.dealer_hits_soft_17 = true
			c.blackjack_payout = 1.2
			c.allows_insurance = false
			c.allows_split = true
			c.max_split_hands = 4
			c.allows_surrender = true
			c.late_surrender_only = true
			c.player_hand_count = 2
			c.heat_active = true
			c.heat_sensitivity_multiplier = 2.5
			c.show_count_display = false
			c.count_check_active = true
			c.grade_decisions = true
			c.grade_bet_ramp = true
			c.count_system = "hi_lo"
		_:
			# 7+: continuous-shuffle contrast mode. The count is meaningless
			# here; the lesson is recognizing when counting stops helping.
			c.name = "Continuous Shuffle"
			c.venue_name = "Pro Circuit"
			c.venue_hook = "Continuous shuffle. The count is gone. Can you still play the table?"
			c.npc_players = 3
			c.deck_count = 8
			c.penetration = 1.0
			c.deck_estimation_rounding = 0.25
			c.dealer_hits_soft_17 = true
			c.blackjack_payout = 1.5
			c.allows_insurance = false
			c.allows_split = true
			c.max_split_hands = 4
			c.allows_surrender = true
			c.late_surrender_only = true
			c.player_hand_count = 3
			c.heat_active = true
			c.heat_sensitivity_multiplier = 3.0
			c.show_count_display = false
			c.grade_decisions = true
			c.grade_bet_ramp = true
			c.count_system = "hi_opt_ii"
			c.continuous_shuffle = true
	# Every table seats a named rival (the "friend → casino" arc). Tier 7 has no
	# count edge to exploit, so the rival is a high-skill flat-bet opponent.
	# Tier 1 (teaching/count-only) has no rival — the player counts alone.
	c.opponent = _opponent_for_tier(c.tier) if c.tier > 1 else null
	return c
