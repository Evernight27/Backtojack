class_name CHOpponent
extends RefCounted
# Models a single named NPC opponent at the table with a tracked bankroll,
# a betting policy, and a skill level that determines how often they play
# optimally. Used for the "friend → casino" social arc: the player is no
# longer playing alone against the house but against specific characters
# with personalities and stakes.
#
# Pure RefCounted model — no autoload/signal dependencies, fully testable
# headless. The CHGameLoop owns an instance and drives it per hand.

# --- Bet policies ---
const POLICY_FLAT := "flat"       # always bets the minimum
const POLICY_RAMP := "ramp"       # scales with true count (simple linear)
const POLICY_COUNT := "count"     # scales more aggressively with true count
const POLICY_TILTS := "tilts"     # escalates bet after consecutive losses

var name: String = "Player"
var archetype: String = "friend"  # friend, regular, shark, pro
var skill: float = 0.5            # 0.0..1.0 probability of playing optimally
var starting_bankroll: int = 50
var bet_policy: String = POLICY_FLAT
var tilt_factor: int = 1          # extra units per consecutive loss (POLICY_TILTS)

# --- Session-scoped state ---
var bankroll: int = 50
var hands_played: int = 0
var hands_won: int = 0
var hands_lost: int = 0
var hands_pushed: int = 0
var net_pnl: float = 0.0
var consecutive_losses: int = 0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _seed: int = -1


func _init(
	p_name: String = "",
	p_archetype: String = "friend",
	p_skill: float = 0.5,
	p_starting_bankroll: int = 50,
	p_bet_policy: String = POLICY_FLAT,
	p_tilt_factor: int = 1,
	p_seed: int = -1
) -> void:
	name = p_name
	archetype = p_archetype
	skill = clampf(p_skill, 0.0, 1.0)
	starting_bankroll = p_starting_bankroll
	bankroll = p_starting_bankroll
	bet_policy = p_bet_policy
	tilt_factor = maxi(p_tilt_factor, 1)
	_seed = p_seed
	if p_seed >= 0:
		_rng.seed = p_seed


static func for_opponent(
	p_name: String,
	p_archetype: String = "friend",
	p_skill: float = 0.5,
	p_starting_bankroll: int = 50,
	p_bet_policy: String = POLICY_FLAT,
	p_tilt_factor: int = 1,
	p_seed: int = -1
) -> CHOpponent:
	return CHOpponent.new(p_name, p_archetype, p_skill, p_starting_bankroll, p_bet_policy, p_tilt_factor, p_seed)


# Restores all session-scoped state to initial values.
func reset() -> void:
	bankroll = starting_bankroll
	hands_played = 0
	hands_won = 0
	hands_lost = 0
	hands_pushed = 0
	net_pnl = 0.0
	consecutive_losses = 0


# True when the opponent can no longer cover a minimum bet.
func is_busted() -> bool:
	return bankroll <= 0


# Returns the bet size in units for this hand.
# `context` is a Dictionary that may contain:
#   tc: int  — current true count (0 if not counting or CSS).
# The result is always clamped to [1, bankroll] (they cannot bet what they
# do not have). The caller should check is_busted() before calling this.
func choose_bet(context: Dictionary = {}) -> int:
	var tc: int = int(context.get("tc", 0))
	var base := _base_bet(tc)
	return clampi(base, 1, bankroll)


func _base_bet(tc: int) -> int:
	match bet_policy:
		POLICY_FLAT:
			return 1
		POLICY_RAMP:
			# Simple linear ramp: 1 unit at TC 0, +1 per 2 TC units.
			return 1 + int(maxi(0, tc) / 2.0)
		POLICY_COUNT:
			# Aggressive: 1 unit at TC 0, +1 per TC unit.
			return 1 + maxi(0, tc)
		POLICY_TILTS:
			# Start at 1, escalate by tilt_factor per consecutive loss.
			return 1 + consecutive_losses * tilt_factor
		_:
			return 1


# Decides the play action for a hand.
# `optimal` is the engine's optimal action string for this state.
# `available` is the list of legal actions (e.g. ["hit", "stand", "double"]).
# With probability `skill`, returns `optimal`. Otherwise picks a uniformly
# random action from `available` that is NOT the optimal one. If no
# suboptimal alternative exists (available == [optimal]), always returns
# optimal regardless of skill.
func choose_play(optimal: String, available: Array[String]) -> String:
	if available.is_empty():
		return optimal
	if _rng.randf() <= skill:
		return optimal
	var suboptimal: Array[String] = []
	for a in available:
		if a != optimal:
			suboptimal.append(a)
	if suboptimal.is_empty():
		return optimal
	return suboptimal[_rng.randi_range(0, suboptimal.size() - 1)]


# Applies a hand result to bankroll and session stats.
# `net` is the P&L for this hand (positive = win, negative = loss, 0 = push).
func apply_result(net: float) -> void:
	bankroll += int(net)
	hands_played += 1
	net_pnl += net
	if net > 0.0:
		hands_won += 1
		consecutive_losses = 0
	elif net < 0.0:
		hands_lost += 1
		consecutive_losses += 1
	else:
		hands_pushed += 1


# Human-readable one-line summary for UI display.
func summary() -> String:
	return "%s: %d bankroll, %+.1f P&L (%dW/%dL/%dP)" % [
		name, bankroll, net_pnl, hands_won, hands_lost, hands_pushed
	]
