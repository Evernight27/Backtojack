class_name CHGameLoop
extends RefCounted
# Interactive, player-driven table loop for one session.
#
# This is the game-side counterpart of sim_validate._play_hand: instead of the
# engine auto-playing every decision, the loop exposes the current situation
# (phase(), available_actions()) and the optimal play (optimal_action()), and
# applies whatever the player chooses via apply_action(). Every decision is
# graded against the optimal play through the supplied CHDisciplineSystem, the
# running count is maintained through CHCountEngine, and the per-hand net P&L is
# pushed to CHGameState at hand end.
#
# It is a pure RefCounted with its OWN local signals so it stays fully
# testable headlessly; Main.gd binds these signals to the UI.
#
# Split model: when the player chooses "split" on the opening pair, the full
# split *structure* is expanded up front by CHSplitResolver (the same
# structure-only resolver the sim uses); the loop then plays each terminal
# hand in turn. Re-splits follow the engine's optimal structure rather than
# further player prompts (documented simplification, see DECISIONS.md M6).

# Safety backstop: never let the shoe drop below this many undealt cards, so a
# hand can never exhaust it mid-play (mirrors sim_validate.SHOE_RESERVE). The
# tier's `penetration` is the primary cut point; this reserve only backstops the
# pathological case where a hand outdraws the penetration.
const SHOE_RESERVE: int = 20

# --- Phases ---
const PHASE_IDLE := "idle"
const PHASE_BET := "bet"        # player chooses a bet unit before cards are dealt
const PHASE_INSURANCE := "insurance"
const PHASE_PRESPLIT := "presplit"
const PHASE_HAND := "hand"
const PHASE_SETTLED := "settled"

# --- Actions ---
const ACT_HIT := "hit"
const ACT_STAND := "stand"
const ACT_DOUBLE := "double"
const ACT_SPLIT := "split"
const ACT_SURRENDER := "surrender"
const ACT_PLAY := "play"        # presplit: do not split, play the pair normally
const ACT_INS_TAKE := "take"    # insurance: take the side bet
const ACT_INS_DECLINE := "decline"  # insurance: decline
# Autopilot sentinel for the BET phase: places the count-optimal (ramp) bet.
const ACT_BET := "bet"
# Player recovery action, available only between hands (IDLE/SETTLED): a
# deliberate "ground yourself" that tops up composure and breaks the mistake
# streak. Budgeted per shoe so it cannot make the spiral free.
const ACT_GROUND := "ground"
const GROUND_USES_PER_SHOE: int = 3
# Bet units the player may choose. The ramp's optimal value always lives in
# this range, so a correct play is never forced out of range.
const MAX_BET_UNITS: int = 6
# Weight of running-count accuracy in the session process score (the rest is
# decision discipline). 0.5 == "trust the count as much as the decisions"; the
# complement (1 - weight) is discipline's share. Only meaningful when the tier
# ran at least one count check — otherwise the score falls back to discipline.
const PROCESS_BLEND_COUNT_WEIGHT: float = 0.5

var config: CHTableConfig
var state: CHGameState
var discipline: CHDisciplineSystem
var engine: CHStrategyEngine
var resolver: CHSplitResolver
var shoe: CHShoeManager
var count: CHCountEngine

var _seed: int = -1
var _reshuffle_count: int = 0
var _phase: String = PHASE_IDLE
var _heat: CHHeatSystem
var _heat_initialized: bool = false
var _mental: CHMentalStateSystem

# Current hand group.
var _hands: Array[CHHand] = []
var _bets: Array[float] = []
var _surrendered: Array[bool] = []
var _idx: int = 0
var _up_key: int = 0
var _tc: int = 0
var _insurance_bet: float = 0.0
var _insurance_offered: bool = false
var _last_net: float = 0.0
var _last_wagered: float = 0.0

# Root (spot) hands dealt at the start of a round: one per `config.player_hand_count`.
# Each root is independently splittable and becomes part of the terminal `_hands`
# group once processed. `_root_idx` tracks which root the presplit phase is on.
var _roots: Array[CHHand] = []
var _root_idx: int = 0
# NPC players (config.npc_players): auto-played hands that sit at the table,
# consume cards from the same shoe, and are visible for the counting drill.
# Their P&L is never tracked; they only affect the card stream and the display.
var _npc_hands: Array[CHHand] = []
# The named social opponent (config.opponent): one NPC seat whose bankroll and
# P&L ARE tracked, so the "friend → casino" arc has a real rival. Its hand is
# kept apart from _npc_hands so the UI can show it distinctly. Null on tables
# with no opponent (tier 1). _opponent_bet is frozen at deal time (the rival
# commits before seeing the outcome). _opponent_settled guards against settling
# it more than once per round.
var opponent: CHOpponent = null
var _opponent_hand: CHHand = null
var _opponent_bet: int = 1
var _opponent_settled: bool = false
# Live dealer hand (upcard; hole appended on reveal).
var _dealer: CHHand = null
var _hole: CHCard = null
var _hole_revealed: bool = false
var _base_bet: int = 1
var _last_bet_cover: bool = false
# True while a two-card root faces a dealer natural and early surrender is
# available: the player can surrender (-0.5) instead of losing the full bet.
var _early_surrender_phase: bool = false
# P&L for spots that settled early as naturals before the rest of the round
# played out (multi-hand: one spot a natural, dealer not a natural). Folded into
# _play_dealer_and_settle so those wins count toward the hand result.
var _pre_settled_profit: float = 0.0
var _pre_settled_wagered: float = 0.0
# True while the current hand is a "backoff hand": the player was flagged at the
# end of the previous hand and must lay low (minimum bet) for this hand. The
# optimal bet is forced to 1 so the discipline system does not penalize the
# player for a bet they cannot choose. Cleared at the end of the hand.
var _backoff_hand: bool = false
# True only while auto_play_round() is driving the hand (the count-only teaching
# table plays itself). Engine-made play calls are not player agency, so they must
# not feed the composure model: without this, the engine's "correct" auto-plays
# would call on_success() on every hit/stand, constantly recovering composure and
# resetting the mistake streak, structurally neutralizing the count-miss spiral
# that report_count() is meant to drive on the teaching table.
var _engine_play: bool = false

# Count-accuracy check (M16). At each shoe cut the loop captures the true
# running count and asks the player to report theirs; report_count() grades it
# and records the result into the CHCountAccuracySystem.
var _count_accuracy: CHCountAccuracySystem
# True running count at the most recent shoe cut (what the player should have
# reported). Captured before count.reset() wipes it.
var _last_shoe_rc: int = 0
# True while a captured shoe count is awaiting the player's report.
var _count_check_due: bool = false
# True while a mid-hand shoe runout already completed the session internally
# (on_shoe_finished -> end_session) but the session_ended signal must be deferred
# to _finalize so the debrief is not shown over a live hand.
var _shoe_end_deferred: bool = false
# Per-shoe budget for the ACT_GROUND recovery action (mirrors the cover-play
# budget: a deliberate, limited player choice rather than an open valve).
var _ground_uses_left: int = GROUND_USES_PER_SHOE


# Local signals (bound to the UI by Main.gd), kept local so this class is
# headless-testable without a running scene tree.
signal phase_changed(phase: String)
signal card_dealt(card: CHCard, is_dealer: bool)
signal decision_graded(delta: float, new_discipline: float)
signal hand_settled(net: float, wagered: float)
signal shoe_reshuffled()
signal heat_changed(new_value: float)
signal heat_backoff()
signal session_ended()
signal count_check_due(rc: int)
# Emitted when the session-end save fails (the only moment progression persists).
# The scene surfaces a warning so a failed write is not silently lost.
signal save_failed()
# Mental state (CHMentalStateSystem): fires on every stability change.
signal mental_changed(stability: float)
# Fires once when the player crosses into the "insane" band.
signal mental_insane()
# Fires once when the player crosses back out of the "insane" band (recovery).
signal mental_recovered()
# Fires on every transition between the four stability bands (calm/strained/
# fraying/insane). The subscription point for ambient effect systems — music
# crossfades, intrusive-thought triggers, audio distortion — that key off the
# coarse band rather than the raw stability value.
signal mental_band_changed(old_band: String, new_band: String)
# The named social opponent (venue arc) — a tracked NPC with its own bankroll
# who plays this table. opponent_settled fires after every resolved hand with
# the opponent's net P&L; opponent_busted fires the (rare) moment its bankroll
# hits zero, ending its seat for the session.
signal opponent_settled(net: float)
signal opponent_busted()


func _init(
	p_config: CHTableConfig,
	p_state: CHGameState,
	p_discipline: CHDisciplineSystem,
	p_seed: int = -1
) -> void:
	config = p_config
	state = p_state
	discipline = p_discipline
	_seed = p_seed
	engine = CHStrategyEngine.new()
	resolver = CHSplitResolver.new()
	shoe = CHShoeManager.new()
	count = CHCountEngine.new()
	count.count_system = config.count_system
	_count_accuracy = CHCountAccuracySystem.new()
	_heat = CHHeatSystem.new()
	_heat.apply_sensitivity(config.heat_sensitivity_multiplier)
	_heat.reset(state.get_heat_floor(state.current_tier))
	_mental = CHMentalStateSystem.new()
	# The "going insane" spiral is a difficulty lever keyed to the tier ladder:
	# harder tables erode stability faster, recover slower, and (from T4) amplify
	# mistakes made while already insane. Tier 1 keeps the historical profile so
	# the teaching table stays calm (see CHMentalConfig.for_tier).
	_mental.configure(CHMentalConfig.for_tier(config.tier))
	opponent = config.opponent
	_opponent_hand = null
	_opponent_bet = 1
	_opponent_settled = false
	shoe.build(config, _seed)


# --- Convenience accessors for the UI ---

func get_shoe() -> CHShoeManager:
	return shoe


func get_count() -> CHCountEngine:
	return count


# --- Count-accuracy check (M16) ---

# The player's running-count accuracy meter for this session.
func get_count_accuracy() -> CHCountAccuracySystem:
	return _count_accuracy


# The social opponent for this session (null on tables without one).
func get_opponent() -> CHOpponent:
	return opponent


# The opponent's live hand (populated during a round, null after settlement).
func opponent_hand() -> CHHand:
	return _opponent_hand


# The opponent's current bet in units (frozen at deal time for the active round).
func opponent_bet() -> int:
	return _opponent_bet


# True while a shoe's captured running count is awaiting the player's report.
func is_count_check_due() -> bool:
	return _count_check_due


# The true running count at the most recent count check — the shoe cut on
# normal tables, or the end of the last settled hand on the count-only teaching
# table (where the check fires per-hand, not at the cut). What the player should
# have reported. Only meaningful while count_check_due() is true.
func last_shoe_rc() -> int:
	return _last_shoe_rc


# The current tutorial stage (1-3) when this session is a tutorial, else 0.
# Derived from how many shoes have completed: stage 1 during the first shoe,
# stage 2 the second, stage 3 the last. Each stage unlocks one more mechanic
# for the player (stage 1 = count only; +2 betting; +3 strategy decisions).
func tutorial_stage() -> int:
	if not state.is_session_active() or state.session_mode != CHGameState.MODE_TUTORIAL:
		return 0
	return clampi(state.shoes_this_session + 1, 1, CHGameState.TUTORIAL_TOTAL_SHOES)


# Grades the player's reported running count against the captured true value at
# the last shoe cut. No-op (returns an empty result) if no check is due — e.g.
# the table has count checking disabled, the session has ended, or the reported
# value exceeds a physically possible running count (rejected, check still due).
func report_count(reported_rc: int) -> Dictionary:
	if not _count_check_due or not state.is_session_active():
		return {}
	# A running count can never exceed the total cards in the shoe (every card
	# the same sign). A report beyond that magnitude is a mistyped / nonsense
	# input; reject it and keep the check pending so the player retries or
	# skips, rather than letting a bogus value zero the accuracy meter.
	var max_magnitude: int = config.deck_count * 52
	if absi(reported_rc) > max_magnitude:
		return {}
	var r: Dictionary = _count_accuracy.record(reported_rc, _last_shoe_rc)
	_count_check_due = false
	# Composure: a miscount erodes composure ("You missed the seven"), a clean
	# report steadies it. Scale by the error magnitude so a 1-off is a nudge.
	# This is what drives the spiral on the count-only teaching table, where the
	# hand auto-plays and no play-decision mistakes exist.
	var abs_err: int = int(r.abs_error)
	if abs_err <= 1:
		_feed_mental(true)
	else:
		_feed_mental(false, 0.5 if abs_err <= 3 else 1.0)
	return r


# Records that the player chose to skip the count check (no grade, no penalty).
func skip_count_check() -> void:
	_count_check_due = false


# Voluntarily end the active session so the player can review the debrief. This
# is the "cash out" path: the session ends by player choice rather than by
# bust/target/shoe-completion. An in-progress hand is abandoned. Returns true if
# the session was active and is now ended. Mirrors the other end paths by
# persisting the session's ending heat as the tier floor when heat is active.
func cash_out() -> bool:
	if not state.is_session_active():
		return false
	if config.heat_active:
		state.set_heat_floor(state.current_tier, _heat.heat)
	state.end_session("cash_out", _session_process_score())
	if not state.last_save_ok:
		push_error("CHGameLoop: session-end save failed on cash_out; progression may not have been persisted")
		save_failed.emit()
	_count_check_due = false
	# Settle into the terminal phase so begin_hand()/apply_action() no-op until a
	# new session is started.
	_set_phase(PHASE_SETTLED)
	session_ended.emit()
	return true


# The session's process score (0-100) that feeds the skill-rating EMA. Blends
# decision discipline with running-count accuracy. When no count checks have
# been recorded this session it falls back to discipline alone so a session
# without count checks does not dilute the rating.
func _session_process_score() -> float:
	# Count-only teaching table: the player made no play decisions, so discipline
	# is pinned near 100 and is not a skill signal. Blending it in (as on real
	# tables) would let a poor counter still clear higher tiers — the whole point
	# of this table is to gate progression on counting, so the process score IS
	# the count accuracy. (With no recorded checks the accuracy is neutral 100,
	# which matches the old behaviour for a skipped check.)
	if config.count_only:
		return _count_accuracy.accuracy
	if _count_accuracy.checks <= 0:
		return discipline.discipline
	return lerpf(discipline.discipline, _count_accuracy.accuracy, PROCESS_BLEND_COUNT_WEIGHT)


func phase() -> String:
	return _phase


# True when there is no live hand and the loop is waiting for the player to
# start the next hand (or the session ended).
func is_idle() -> bool:
	return _phase == PHASE_IDLE or _phase == PHASE_SETTLED


# Starts (or continues) the current session's shoe. Builds a fresh shoe on the
# first call and reshuffles deterministically whenever the shoe must be cut.
# Returns false if the session is not active (nothing to play).
func start_or_next_shoe() -> bool:
	if not state.is_session_active():
		return false
	# Cut the shoe when the tier's penetration is reached (the difficulty lever)
	# or when we are down to the safety reserve (a hand must never exhaust the
	# shoe mid-play). Whichever comes first.
	if shoe.should_reshuffle() or shoe.cards_remaining() < SHOE_RESERVE:
		var cut_rc: int = count.running_count
		_reshuffle_count += 1
		var s: int = _seed if _seed >= 0 else _reshuffle_count
		shoe.reshuffle(s + _reshuffle_count * 7919)
		count.reset()
		_on_new_shoe()
		shoe_reshuffled.emit()
		_last_shoe_rc = cut_rc
		# Count-only teaching table (Tier 1): the per-hand check in _finalize()
		# already quizzed the player on this shoe's running count, so skip the
		# shoe-cut prompt here to avoid asking the same count twice.
		if config.count_check_active and not config.count_only and state.is_session_active():
			_count_check_due = true
			count_check_due.emit(cut_rc)
	return true


# New-shoe bookkeeping: drain the per-shoe decision log, reset the cover-play
# budget, advance the shoe counter, and (unless deferred) persist the heat floor
# and surface session_ended if the shoe completion ended the session
# (practice/survival/tutorial). Called on every shoe boundary (start-of-hand cut
# and mid-hand runout). `mid_hand` is true when the shoe ran out during an
# in-progress hand (a cut-change runout); in that case a session-end is deferred
# to _finalize so the debrief is not shown over a live hand (_shoe_end_deferred).
func _on_new_shoe(mid_hand: bool = false) -> void:
	discipline.get_and_clear_shoe_decisions()
	discipline.reset_for_new_shoe()
	_ground_uses_left = GROUND_USES_PER_SHOE
	var ended: bool = state.on_shoe_finished(_session_process_score())
	if ended and mid_hand:
		# A mid-hand cut-change can complete the FINAL shoe of a
		# practice/survival/tutorial session. The session is already ended
		# internally (on_shoe_finished -> end_session -> save), but we must not
		# surface session_ended until the hand that triggered the runout settles —
		# otherwise the debrief would appear over a live hand and that hand's
		# apply_hand_result would no-op. Defer the signal to _finalize.
		_shoe_end_deferred = true
		return
	if ended:
		_complete_ended_shoe()


# Surfaces a shoe-completion session end: flags a save failure, persists the
# ending heat as the tier's reputation floor, suppresses any pending count check,
# and emits session_ended. Called from _on_new_shoe (start-of-hand cut) and, when
# a mid-hand cut-change completed the final shoe, from _finalize.
func _complete_ended_shoe() -> void:
	# The session-end save ran inside on_shoe_finished; surface a failure
	# before the (separate) heat-floor write below can mask it.
	if not state.last_save_ok:
		push_error("CHGameLoop: session-end save failed on shoe completion; progression may not have been persisted")
		save_failed.emit()
	if config.heat_active:
		state.set_heat_floor(state.current_tier, _heat.heat)
		if not state.save():
			push_error("CHGameLoop: failed to persist tier-%d heat floor (shoe completion)" % state.current_tier)
	_count_check_due = false
	session_ended.emit()


# Starts a new hand: enters the BET phase. The player must then call
# place_bet() to commit a bet size before cards are dealt.
func begin_hand() -> bool:
	if not is_idle():
		return false
	if not start_or_next_shoe():
		return false
	# start_or_next_shoe() may have ended the session (practice/survival shoe
	# completion); don't open a hand in an inactive session.
	if not state.is_session_active():
		return false
	# Feed the player-facing deck estimate (rounded to the tier's coarseness
	# step) rather than the exact card count — that is what the count engine
	# divides for true count, and it is what deck_estimation_rounding controls.
	# At a fresh shoe the estimate equals the exact deck count, so behavior at
	# the default values is unchanged.
	count.set_decks_remaining(shoe.decks_remaining_estimate())
	_tc = count.true_count_floor()
	_last_bet_cover = false
	_early_surrender_phase = false
	_pre_settled_profit = 0.0
	_pre_settled_wagered = 0.0
	if config.heat_active:
		if not _heat_initialized:
			_heat.reset(state.get_heat_floor(state.current_tier))
			_heat_initialized = true
		elif _heat.has_pending_backoff():
			heat_backoff.emit()
			_heat.reset(state.get_heat_floor(state.current_tier))
			# The player was just flagged: the current hand is a "backoff hand"
			# where they must lay low. optimal_bet_units() returns 1 so the
			# discipline system does not penalize a bet the player cannot choose.
			_backoff_hand = true
	_set_phase(PHASE_BET)
	return true


# The count-optimal bet size for the current true count (the ramp value). Under
# a continuous-shuffle machine there is no count-based edge, so the optimal is
# a flat minimum bet — counting stops helping.
func optimal_bet_units() -> int:
	if config.continuous_shuffle:
		return 1
	if _backoff_hand:
		return 1
	return _bet_for_tc(_tc)


# Commits the player's bet and deals the opening cards. `units` is clamped to
# [1, MAX_BET_UNITS]. `is_cover` exempts the bet from discipline penalty if
# cover plays remain this shoe. Returns false if not in BET phase.
func place_bet(units: int, is_cover: bool = false) -> bool:
	if _phase != PHASE_BET:
		return false
	var clamped: int = clampi(units, 1, MAX_BET_UNITS)
	var optimal: int = optimal_bet_units()
	var cover_granted: bool = false
	if is_cover:
		cover_granted = discipline.declare_cover_play()
	_last_bet_cover = cover_granted
	var after_loss: bool = _last_net < 0.0
	var r: Dictionary
	if config.grade_bet_ramp:
		r = discipline.grade_bet(clamped, optimal, after_loss, cover_granted)
	else:
		# No bet-ramp grading on this tier (teaching table): the bet still
		# commits, it just moves no Discipline and is not recorded for tilt.
		r = {"delta": 0.0, "discipline": discipline.discipline}
	decision_graded.emit(float(r.delta), float(r.discipline))
	_base_bet = clamped
	# Composure: a mis-sized bet (that isn't a declared cover play) is a lapse
	# the same way a wrong play is — overbetting a cold count reads as tilt,
	# underbetting a hot count as fear. A correct (optimal) bet steadies. Skipped
	# for engine-driven auto-bets (auto_play_round): no player agency to read.
	if not _engine_play:
		_feed_bet_composure(clamped, optimal, cover_granted)
	# Heat tell: betting big on a hot count reads as counting. A granted cover
	# bet is a deliberate lay-low play and suppresses the tell. No count exists on
	# a continuous-shuffle table, so a big bet there is not a count tell. On a
	# count-only teaching table the player never places the bet (the engine
	# auto-plays it), so there is no player agency to reveal — suppress the tell
	# and keep the drill pressure-free.
	if config.heat_active and not config.continuous_shuffle and not config.count_only and _tc >= CHHeatSystem.BET_TELL_TC and clamped >= CHHeatSystem.BET_TELL_MIN_UNITS and not cover_granted:
		var hd: float = _heat.on_tell(CHHeatSystem.BET_TELL_GAIN * _tell_multiplier())
		if hd > 0.0:
			heat_changed.emit(_heat.heat)
	_deal_opening()
	return true


# Count-only teaching table (config.count_only): the player's only job is to
# track the running count, so the scene calls this right after begin_hand() to
# deal and play the whole round with the engine's optimal actions. The player
# never bets, covers, or makes a play call — the hand resolves on its own and the
# loop returns to PHASE_SETTLED, leaving the shoe-cut count report as the sole
# interaction. No-op unless the loop is in the BET phase (safe to call blindly).
func auto_play_round() -> void:
	if _phase != PHASE_BET:
		return
	# The engine is making every call this round, not the player — gate the
	# composure feeds (see _engine_play) so the auto-played "correct" plays do not
	# steady composure or reset the mistake streak.
	_engine_play = true
	place_bet(optimal_bet_units(), false)
	var guard: int = 0
	while not is_idle() and guard < 64:
		var a: String = optimal_action()
		if a == "":
			break
		apply_action(a)
		guard += 1
	_engine_play = false


# Deals the opening cards: one dealer upcard + hole, then a two-card root hand
# for each spot (config.player_hand_count). All spots face the same upcard.
# Transitions to the next decision phase (insurance, presplit, or hand).
func _deal_opening() -> void:
	var upcard: CHCard = shoe.deal()
	var hole: CHCard = shoe.deal()

	_dealer = CHHand.new()
	_dealer.add_card(upcard)
	_hole = hole
	_hole_revealed = false
	_up_key = CHHand.dealer_upcard_key(upcard.rank)

	_roots.clear()
	var spots := maxi(1, config.player_hand_count)
	for i in spots:
		var p1: CHCard = shoe.deal()
		var p2: CHCard = shoe.deal()
		var root := CHHand.new()
		root.add_card(p1)
		root.add_card(p2)
		_roots.append(root)
		_reveal(p1, false)
		_reveal(p2, false)
	_reveal(upcard, true)

	# NPC players (higher-tier tables): deal each NPC's two-card hand and reveal
	# it so it enters the counting stream. NPCs play flat basic strategy (no
	# count, no split/double/surrender) and their P&L is never tracked — they are
	# there to fill the table and give the player a richer visible card stream.
	_npc_hands.clear()
	for i in config.npc_players:
		var n1: CHCard = shoe.deal()
		var n2: CHCard = shoe.deal()
		var nh := CHHand.new()
		nh.add_card(n1)
		nh.add_card(n2)
		_reveal(n1, false)
		_reveal(n2, false)
		_npc_hands.append(nh)

	# The named social opponent (venue arc): a tracked NPC seat dealt alongside
	# the filler NPCs. Its bet is frozen now (before the outcome is known) and its
	# hand is settled at round end in _finalize. Absent on tables without one.
	# A busted rival keeps its seat for the rest of the session (no more dealing,
	# no more settling) — the opponent_busted signal's "seat ends" contract.
	_opponent_hand = null
	_opponent_settled = false
	if opponent != null and not opponent.is_busted():
		var o1: CHCard = shoe.deal()
		var o2: CHCard = shoe.deal()
		_opponent_hand = CHHand.new()
		_opponent_hand.add_card(o1)
		_opponent_hand.add_card(o2)
		_reveal(o1, false)
		_reveal(o2, false)
		_opponent_bet = opponent.choose_bet({"tc": effective_tc()})

	_insurance_offered = config.allows_insurance and upcard.rank == 14
	_insurance_bet = 0.0
	if _insurance_offered:
		_set_phase(PHASE_INSURANCE)
		return
	_after_insurance()


# The actions the player may take right now. In the BET phase the only generic
# action is ACT_BET (an autopilot sentinel that places the optimal ramp bet);
# the scene renders the concrete 1..MAX_BET_UNITS buttons directly.
func available_actions() -> Array[String]:
	match _phase:
		PHASE_BET:
			return [ACT_BET]
		PHASE_INSURANCE:
			return [ACT_INS_TAKE, ACT_INS_DECLINE]
		PHASE_PRESPLIT:
			return [ACT_SPLIT, ACT_PLAY]
		PHASE_HAND:
			return _hand_actions()
		_:
			# Between hands (IDLE/SETTLED): the only player action is the
			# budgeted "ground yourself" composure recovery.
			if is_idle() and _ground_uses_left > 0:
				return [ACT_GROUND]
			return []


func _hand_actions() -> Array[String]:
	if _idx < 0 or _idx >= _hands.size():
		return []
	var h: CHHand = _hands[_idx]
	if _early_surrender_phase:
		return [ACT_SURRENDER, ACT_STAND]
	if h.is_bust() or h.split_ace:
		return [ACT_STAND]
	var out: Array[String] = [ACT_HIT, ACT_STAND]
	if _can_double(h):
		out.append(ACT_DOUBLE)
	if _can_surrender(h):
		out.append(ACT_SURRENDER)
	return out


func _can_double(h: CHHand) -> bool:
	if not config.allows_double:
		return false
	if h.card_count() != 2:
		return false
	if h.is_split_hand and not config.allows_double_after_split:
		return false
	return true


func _can_surrender(h: CHHand) -> bool:
	if not config.allows_surrender:
		return false
	if h.card_count() != 2:
		return false
	if h.is_soft() or h.is_pair():
		return false
	return true


# Early-surrender gate: the table allows surrender, it is not late-surrender-only,
# and there is a single two-card hard root the player can surrender.
func _can_enter_early_surrender() -> bool:
	if not config.allows_surrender or config.late_surrender_only:
		return false
	if _roots.size() != 1:
		return false
	return _can_surrender(_roots[0])


# The optimal play for the current state (used for discipline grading and to
# drive an "autopilot" perfect player in tests).
func optimal_action() -> String:
	match _phase:
		PHASE_BET:
			return ACT_BET
		PHASE_INSURANCE:
			if engine.should_take_insurance(effective_tc()):
				return ACT_INS_TAKE
			return ACT_INS_DECLINE
		PHASE_PRESPLIT:
			if _root_idx >= 0 and _root_idx < _roots.size() and _would_split_root(_roots[_root_idx]):
				return ACT_SPLIT
			return ACT_PLAY
		PHASE_HAND:
			if _idx < 0 or _idx >= _hands.size():
				return ""
			if _early_surrender_phase:
				# Against a known dealer natural the half-loss strictly dominates
				# standing or hitting (both lose the full bet), so the optimal is
				# always surrender. Keeping this here also guarantees the optimal
				# stays inside the sub-phase's restricted [surrender, stand] set
				# rather than leaking an engine "hit"/"double" the UI never offers.
				return ACT_SURRENDER
			var h: CHHand = _hands[_idx]
			if h.split_ace:
				return ACT_STAND
			var p: String = engine.best_play_no_split(h, _up_key, config, effective_tc())
			if p == "double" and not _can_double(h):
				p = ACT_HIT
			if p == "surrender" and not _can_surrender(h):
				p = ACT_STAND
			return p
		_:
			return ""


# Whether the current optimal play (PHASE_HAND) is an I18 counting deviation
# from flat basic strategy at the live true count — i.e. the count is what makes
# the optimal call differ from basic. False outside the HAND phase and under CSS
# (effective_tc() is 0 there, so no count deviation applies). Used to tag the
# player-facing decision feedback so the trainer shows *when* the count changed
# the right play.
func is_deviation_play() -> bool:
	if _phase != PHASE_HAND or _idx < 0 or _idx >= _hands.size():
		return false
	var h: CHHand = _hands[_idx]
	if h.split_ace:
		return false
	return engine.is_counting_deviation(h, _up_key, config, effective_tc())


# Applies a player action. Must be in a decision phase (bet/insurance/presplit/hand)
# or IDLE/SETTLED (the between-hands "ground yourself" recovery action).
func apply_action(action: String) -> void:
	match _phase:
		PHASE_BET:
			_apply_bet(action)
		PHASE_INSURANCE:
			_apply_insurance(action)
		PHASE_PRESPLIT:
			_apply_presplit(action)
		PHASE_HAND:
			_apply_hand(action)
		PHASE_IDLE, PHASE_SETTLED:
			_apply_ground(action)
		_:
			push_warning("CHGameLoop: apply_action in phase %s" % _phase)


# Autopilot: in the BET phase any action places the count-optimal (ramp) bet.
# A human player instead calls place_bet(units, is_cover) directly.
func _apply_bet(_action: String) -> void:
	place_bet(optimal_bet_units(), false)


# The between-hands recovery action: a deliberate "ground yourself" that tops up
# composure and breaks the mistake streak (the player's agency lever against the
# spiral). Spent from a per-shoe budget (GROUND_USES_PER_SHOE) so it cannot make
# the spiral free; a no-op when already at full composure (nothing to recover)
# or once the shoe's budget is spent.
func _apply_ground(action: String) -> void:
	if action != ACT_GROUND or _ground_uses_left <= 0:
		return
	if _mental.stability >= CHMentalStateSystem.MAX_MENTAL:
		return
	_ground_uses_left -= 1
	var was_insane: bool = _mental.is_insane()
	var old_band: String = _mental.mental_state()
	_mental.ground()
	_emit_mental_transitions(was_insane, old_band)


func _apply_insurance(action: String) -> void:
	if action == ACT_INS_TAKE:
		# Insurance is 1/2 of the main bet, per spot. A single decision covers all
		# spots (same upcard + count), so the stake scales with the spot count.
		_insurance_bet = float(_roots.size()) * maxf(1.0, float(_base_bet) / 2.0)
	var opt := optimal_action()
	_grade(action, opt)
	# Heat tell: taking insurance at a hot count reveals count knowledge. Not a
	# tell on a continuous-shuffle table (no count to reveal) or a count-only
	# teaching table (the engine auto-decides insurance; the player has no agency).
	if action == ACT_INS_TAKE and config.heat_active and not config.continuous_shuffle and not config.count_only and _tc >= engine.INSURANCE_TC_THRESHOLD:
		var hd: float = _heat.on_tell(CHHeatSystem.INSURANCE_TELL_GAIN * _tell_multiplier())
		if hd > 0.0:
			heat_changed.emit(_heat.heat)
	_after_insurance()


func _apply_presplit(action: String) -> void:
	var opt := optimal_action()
	_grade(action, opt)
	var root: CHHand = _roots[_root_idx]
	if action == ACT_SPLIT:
		var expanded: Array[CHHand] = resolver.resolve(
			root, _up_key, shoe, config, engine, effective_tc()
		)
		_mark_seen(expanded)
		for h in expanded:
			_hands.append(h)
			_bets.append(float(_base_bet))
			_surrendered.append(false)
	else:
		_hands.append(root)
		_bets.append(float(_base_bet))
		_surrendered.append(false)
	# Move past this root; keep processing remaining roots, then start play.
	_root_idx += 1
	if _root_idx >= _roots.size():
		_start_hand_play()
	else:
		_process_next_root()


func _apply_hand(action: String) -> void:
	if _idx < 0 or _idx >= _hands.size():
		return
	var h: CHHand = _hands[_idx]
	var bet: float = _bets[_idx]
	var opt := optimal_action()
	_grade(action, opt)
	# Heat tell: making a counting deviation (playing off basic strategy because
	# of the live count) reveals count knowledge to the pit. Under CSS there is
	# no live count, so effective_tc() is 0 and this is naturally never true. On a
	# count-only teaching table the engine auto-plays, so the deviation is not a
	# player reveal — suppress it.
	if action == opt and config.heat_active and not config.count_only and engine.is_counting_deviation(h, _up_key, config, effective_tc()):
		var hd: float = _heat.on_tell(CHHeatSystem.DEV_TELL_GAIN * _tell_multiplier())
		if hd > 0.0:
			heat_changed.emit(_heat.heat)
	match action:
		ACT_HIT:
			var c: CHCard = _deal_card()
			h.add_card(c)
			_reveal(c, false)
			if h.is_bust():
				_advance_to_next_hand()
			else:
				_set_phase(PHASE_HAND)
		ACT_DOUBLE:
			if _can_double(h):
				var dc: CHCard = _deal_card()
				h.add_card(dc)
				_reveal(dc, false)
				_bets[_idx] = bet * 2.0
			_advance_to_next_hand()
		ACT_SURRENDER:
			if _can_surrender(h):
				_surrendered[_idx] = true
			_advance_to_next_hand()
		ACT_STAND:
			_advance_to_next_hand()
		_:
			# Unknown action: treat as stand (safe default).
			_advance_to_next_hand()


func _advance_to_next_hand() -> void:
	_idx += 1
	# Split aces receive one card and auto-stand; skip them (they still settle).
	while _idx < _hands.size() and _hands[_idx].split_ace:
		_idx += 1
	if _idx >= _hands.size():
		_play_dealer_and_settle()
	else:
		_set_phase(PHASE_HAND)


# Begin player play of the CURRENT hand group from the first hand (used right
# after the opening cards are dealt / a split is resolved). Distinct from
# _advance_to_next_hand, which moves PAST a hand that was just played.
func _start_hand_play() -> void:
	_idx = 0
	while _idx < _hands.size() and _hands[_idx].split_ace:
		_idx += 1
	if _idx >= _hands.size():
		_play_dealer_and_settle()
	else:
		_set_phase(PHASE_HAND)


# --- Internal: insurance peek + natural + presplit setup ---

func _after_insurance() -> void:
	# Build a full two-card dealer hand for the natural check.
	var full_dealer := CHHand.new()
	full_dealer.add_card(_dealer.cards[0])
	full_dealer.add_card(_hole)
	var any_player_bj := false
	for r in _roots:
		if r.is_blackjack():
			any_player_bj = true
	var dealer_bj: bool = full_dealer.is_blackjack()

	# Dealer holds a natural: the whole round settles against it. A natural spot
	# pushes, every non-natural spot loses. Early-surrender tables let a lone
	# non-natural spot surrender for a half-loss before settling.
	if dealer_bj:
		if not any_player_bj and _can_enter_early_surrender():
			_hands.clear()
			_bets.clear()
			_surrendered.clear()
			_hands.append(_roots[0])
			_bets.append(float(_base_bet))
			_surrendered.append(false)
			_idx = 0
			_early_surrender_phase = true
			_set_phase(PHASE_HAND)
			return
		_reveal_hole()
		_settle_natural(dealer_bj)
		return

	# NPCs act before the dealer, real-blackjack order. A dealer natural settles
	# the round immediately (handled above), so NPCs only draw when it is absent.
	_play_npcs()

	# A natural on one or more player spots, no dealer natural (M105): those
	# spots win 3:2 now, but the remaining spots keep playing through the normal
	# presplit/hand flow. Previously the whole round settled here and every
	# non-natural spot auto-lost.
	if any_player_bj:
		_reveal_hole()
		var remaining: Array[CHHand] = []
		for r in _roots:
			if r.is_blackjack():
				_pre_settled_profit += float(_base_bet) * config.blackjack_payout
				_pre_settled_wagered += float(_base_bet)
			else:
				remaining.append(r)
		# Insurance (if taken) loses here: the dealer has no natural.
		if _insurance_bet > 0.0:
			_pre_settled_profit -= _insurance_bet
			_pre_settled_wagered += _insurance_bet
			_insurance_bet = 0.0
		_roots = remaining
		if _roots.is_empty():
			# Every spot was a natural; nothing left to play.
			_finalize(_pre_settled_profit, _pre_settled_wagered)
			return
		# Fall through: play the non-natural spots.

	# Process each root in turn: splittable pairs go through the presplit phase;
	# everything else becomes a terminal hand directly.
	_hands.clear()
	_bets.clear()
	_surrendered.clear()
	_root_idx = 0
	_process_next_root()


# Auto-plays every NPC hand to completion with flat basic strategy (tc 0). Called
# once per round from _after_insurance when the dealer has no natural. NPCs never
# split/double/surrender: a single hand played to 17+ keeps the card stream simple
# and the shoe bookkeeping exact. Their P&L is never tracked.
func _play_npcs() -> void:
	# The tracked opponent plays with basic strategy using its own effective TC
	# (which may differ from the player's due to the misread mechanic).
	if opponent != null and _opponent_hand != null:
		var guard_o: int = 0
		while not _opponent_hand.is_bust() and guard_o < 12:
			# Sal plays basic strategy keyed to the running count (effective TC),
			# so at higher tiers the rival counts too and is harder to beat.
			var p: String = engine.best_play_no_split(_opponent_hand, _up_key, config, effective_tc())
			if p != "hit":
				break
			var c: CHCard = _deal_card()
			_opponent_hand.add_card(c)
			_reveal(c, false)
			guard_o += 1

	for nh in _npc_hands:
		var guard: int = 0
		while not nh.is_bust() and guard < 12:
			var p: String = engine.best_play_no_split(nh, _up_key, config, 0)
			if p != "hit":
				break
			var c: CHCard = _deal_card()
			nh.add_card(c)
			_reveal(c, false)
			guard += 1


# Settles the tracked opponent's hand against the dealer. Called once per round
# from _finalize (guarded by _opponent_settled). The result is applied to the
# opponent's bankroll and signals are emitted for the UI.
func _settle_opponent() -> void:
	if _opponent_hand == null or _opponent_hand.cards.size() < 2:
		return
	var bet: float = float(_opponent_bet)
	var opp_total: int = _opponent_hand.total()
	var dealer_bj: bool = _dealer.is_blackjack()
	var opp_bj: bool = _opponent_hand.is_blackjack()
	var opp_net: float = 0.0
	if opp_bj and dealer_bj:
		opp_net = 0.0  # push
	elif opp_bj:
		opp_net = bet * config.blackjack_payout
	elif dealer_bj:
		opp_net = -bet
	elif _opponent_hand.is_bust():
		opp_net = -bet
	elif _dealer.is_bust():
		opp_net = bet
	elif opp_total > _dealer.total():
		opp_net = bet
	elif opp_total < _dealer.total():
		opp_net = -bet
	# push: opp_net stays 0.0
	opponent.apply_result(opp_net)
	opponent_settled.emit(opp_net)
	if opponent.is_busted():
		opponent_busted.emit()
	_opponent_hand = null
	_opponent_bet = 1


# Advances to the next root. Roots that are a splittable pair (and the engine
# would split them) enter PHASE_PRESPLIT so the player decides; all others are
# appended to the terminal hand group immediately and we keep advancing.
func _process_next_root() -> void:
	if _root_idx >= _roots.size():
		_start_hand_play()
		return
	var root: CHHand = _roots[_root_idx]
	if root.is_pair() and config.allows_split and _would_split_root(root):
		_set_phase(PHASE_PRESPLIT)
		return
	_append_root_unsplit(root)


# Appends a non-split root to the terminal hand group and moves on.
func _append_root_unsplit(root: CHHand) -> void:
	_hands.append(root)
	_bets.append(float(_base_bet))
	_surrendered.append(false)
	_root_idx += 1
	_process_next_root()


func _would_split_root(root: CHHand) -> bool:
	if not root.is_pair() or not config.allows_split:
		return false
	var play := engine.best_play(root, _up_key, config, effective_tc())
	return play == "split"


# Natural settlement: the hole is revealed and each spot resolves against the
# dealer by its own two cards. A spot with a blackjack pushes if the dealer also
# has one, wins 3:2 (payout) otherwise; a non-blackjack spot loses to a dealer
# blackjack. (A round where any spot is a natural settles the whole round here.)
func _settle_natural(dealer_bj: bool) -> void:
	var main := 0.0
	for r in _roots:
		if r.is_blackjack() and dealer_bj:
			main += 0.0  # push
		elif r.is_blackjack():
			main += float(_base_bet) * config.blackjack_payout
		else:
			main -= float(_base_bet)
	var ins := 0.0
	if _insurance_bet > 0.0:
		# Payout is the table's insurance ratio (net profit on a dealer BJ, per
		# unit staked), read from config the same way blackjack_payout is. The
		# loss side just forfeits the stake.
		ins = config.insurance_payout * _insurance_bet if dealer_bj else -_insurance_bet
	var wagered := float(_roots.size()) * float(_base_bet) + _insurance_bet
	_finalize(main + ins, wagered)


func _play_dealer_and_settle() -> void:
	_reveal_hole()
	var any_standing := false
	for i in _hands.size():
		if not _surrendered[i] and not _hands[i].is_bust():
			any_standing = true
			break
	# A real table keeps the dealer playing while any seat stands — including
	# NPC seats — so a trainee bust doesn't short-circuit the dealer's cards
	# (the rest of the count stream would be hidden from the player).
	if not any_standing:
		for nh in _npc_hands:
			if not nh.is_bust():
				any_standing = true
				break
	if any_standing:
		while _dealer_should_hit(_dealer):
			var dc: CHCard = _deal_card()
			_dealer.add_card(dc)
			_reveal(dc, true)

	var profit := 0.0
	var wagered := 0.0
	for i in _hands.size():
		var h: CHHand = _hands[i]
		var b: float = _bets[i]
		wagered += b
		if _surrendered[i]:
			profit -= 0.5 * b
		elif h.is_bust():
			profit -= b
		elif _dealer.is_bust():
			profit += b
		elif _dealer.total() > h.total():
			profit -= b
		elif h.total() > _dealer.total():
			profit += b
		# else push
	if _insurance_bet > 0.0:
		# The side-bet wins 2:1 on a dealer natural, loses otherwise. This
		# covers the early-surrender-against-a-known-natural path: the dealer's
		# hole is revealed and on the table here, so a taken insurance pays out
		# instead of being silently forfeited.
		var ins: float = config.insurance_payout * _insurance_bet if _dealer.is_blackjack() else -_insurance_bet
		profit += ins
		wagered += _insurance_bet
	# Fold in any spots that settled early as naturals before this round played
	# out (M105). _insurance_bet is 0 here when those were already folded in
	# _after_insurance, so nothing is double-counted.
	profit += _pre_settled_profit
	wagered += _pre_settled_wagered
	_finalize(profit, wagered)


func _reveal_hole() -> void:
	if not _hole_revealed:
		_reveal(_hole, true)
		_hole_revealed = true
		# Append the hole the moment it is revealed, on every settle path. The
		# natural-settle path (_after_insurance -> _settle_natural) never calls
		# _play_dealer_and_settle, so without this the revealed hole stays out of
		# _dealer: the UI renders a one-card "10" and _settle_opponent compares
		# the rival against a lone upcard instead of the two-card 21. Guarded by
		# _hole_revealed so the normal settle path (which no longer re-adds it)
		# still appends it exactly once.
		_dealer.add_card(_hole)


func _finalize(net: float, wagered: float) -> void:
	_last_net = net
	_last_wagered = wagered
	# A backoff hand (forced min bet) is over; the next hand resumes normal play.
	_backoff_hand = false
	# Heat decays a fixed amount per settled hand (laying low). The backoff latch
	# is NOT cleared by decay — only by an explicit new-shoe reset.
	if config.heat_active:
		var decayed: float = _heat.on_hand()
		if decayed > 0.0:
			heat_changed.emit(_heat.heat)
	# Settle the tracked opponent's hand against the dealer (venue arc).
	if opponent != null and _opponent_hand != null and not _opponent_settled:
		_opponent_settled = true
		_settle_opponent()
	# Bankroll update (session-scoped economy). practice mode is no-stake.
	# Pass the blended session process score (discipline + count accuracy) so the
	# skill-rating EMA reflects actual session performance (only used on the
	# terminal hand).
	var ended: bool = state.apply_hand_result(int(roundf(net)), _session_process_score())
	# The session-end save ran inside apply_hand_result; surface a failure before
	# the (separate) heat-floor write below can mask it.
	if ended and not state.last_save_ok:
		push_error("CHGameLoop: session-end save failed on terminal hand; progression may not have been persisted")
		save_failed.emit()
	# If this hand ended the session (target/bust), persist the session's ending
	# heat as the tier's reputation floor so the next session starts from residual
	# suspicion. (Practice/survival ends are handled in _on_new_shoe instead.)
	if ended and config.heat_active:
		state.set_heat_floor(state.current_tier, _heat.heat)
		if not state.save():
			push_error("CHGameLoop: failed to persist tier-%d heat floor (session end)" % state.current_tier)
	# Count-only teaching table (Tier 1): after every hand, quiz the player on the
	# running count they just tracked. The hand dealt and played itself, so the
	# count is the only thing the player is responsible for — this is the core
	# "what to look for" drill. The shoe-cut check is suppressed in this mode
	# (see start_or_next_shoe) so the player isn't asked twice at the boundary.
	if config.count_only and config.count_check_active and not ended:
		_last_shoe_rc = count.running_count
		_count_check_due = true
		count_check_due.emit(count.running_count)
	# Count-only teaching table: the hand dealt and played itself, so keep the
	# terminal hands AND any NPC hands around for the UI to render — the player
	# needs to SEE every card (dealer + their own + other seats) to track the
	# running count. On every other table the hands clear at settle (existing
	# behaviour). The next round's _deal_opening()/_after_insurance() clear and
	# rebuild these, so nothing goes stale.
	_bets = []
	_surrendered = []
	_roots = []
	_root_idx = 0
	if not config.count_only:
		_hands = []
		_npc_hands = []
	_set_phase(PHASE_SETTLED)
	hand_settled.emit(net, wagered)
	if ended:
		_count_check_due = false
		session_ended.emit()
	# A mid-hand cut-change may have completed the FINAL shoe of the session
	# (on_shoe_finished -> end_session ran mid-hand in _deal_card). Surface
	# session_ended only now that the hand has settled, so the debrief is not
	# shown over a live hand.
	if _shoe_end_deferred:
		_shoe_end_deferred = false
		_complete_ended_shoe()


func _dealer_should_hit(dealer: CHHand) -> bool:
	var t: int = dealer.total()
	if t >= 18:
		return false
	if t >= 17:
		return config.dealer_hits_soft_17 and dealer.is_soft()
	return true


# Heat-tell multiplier: stacking pressure terms. While the player is fully
# insane their tells register a little more readily (rattled = sloppier); and
# while they are tilt-detected (loss-chasing) the pit notices (chasing is a
# classic tell). Each term is 1.0 when inactive, so a calm, non-tilted player
# always gets exactly the base tell gain.
const TILT_TELL_MULTIPLIER: float = 1.5


func _tell_multiplier() -> float:
	var mult: float = _mental.heat_link() if _mental.is_insane() else 1.0
	if discipline.check_tilt():
		mult *= TILT_TELL_MULTIPLIER
	return mult


# Feeds the mental-stability layer from a bet decision (the bet-ramp half of
# "process"). Only a mis-sized bet erodes composure — overbetting a cold count
# reads as tilt, underbetting a hot count as fear — scaled by the deviation
# severity (1..4 units off -> 0.5 / 0.75 / 1.0) so a 1-off is a nudge and a 4+
# off is a full lapse. An optimal bet neither erodes nor steadies: composure
# recovers from correct play calls (the model's contract), so auto-betting an
# optimal size stays composure-neutral. A declared cover play is an intentional
# low bet, not a lapse, so it never erodes either. Unconditional (not gated on
# grade_bet_ramp) — composure is a process read-out, like play calls.
func _feed_bet_composure(units: int, optimal: int, cover: bool) -> void:
	if units == optimal or cover:
		return
	var diff := absi(units - optimal)
	var scale: float = 0.5 if diff <= 1 else (0.75 if diff <= 2 else 1.0)
	_feed_mental(false, scale)


# Feeds the mental-stability layer from a graded play decision. A non-optimal
# play erodes stability (escalating on a streak); a correct play steadies it and
# resets the streak. Runs unconditionally, like record_decision — it is a
# presentational read-out, not a scoring lever, so it is not gated on the
# tier's grade_decisions flag.
func _feed_mental(correct: bool, scale: float = 1.0) -> void:
	var was_insane: bool = _mental.is_insane()
	var old_band: String = _mental.mental_state()
	if correct:
		_mental.on_success()
	else:
		_mental.on_mistake(scale)
	_emit_mental_transitions(was_insane, old_band)


# Emits the mental-transition signals shared by every path that mutates the
# mental model (mistake, success, ground). Centralized so grounding — which
# previously emitted only mental_changed — also fires the band-crossing signals
# when a recovery crosses out of a band, keeping consumers (vignette, ambient
# pacing) in sync no matter which path moved the stability.
func _emit_mental_transitions(was_insane: bool, old_band: String) -> void:
	if not was_insane and _mental.is_insane():
		mental_insane.emit()
	elif was_insane and not _mental.is_insane():
		mental_recovered.emit()
	var new_band: String = _mental.mental_state()
	if new_band != old_band:
		mental_band_changed.emit(old_band, new_band)
	mental_changed.emit(_mental.stability)


func _grade(actual: String, optimal: String) -> void:
	# Record every play decision for the session process score (the debrief's
	# "Decisions" line) unconditionally — recording is a process read-out, not a
	# scoring lever, so it happens even when the tier does not grade.
	discipline.record_decision(actual, optimal)
	# A correct play steadies composure and a wrong one erodes it — but only for
	# a *player* call. During auto_play_round the engine makes every call; those
	# "correct" plays must not steady composure or reset the mistake streak, or
	# the count-only table's spiral (driven solely by report_count) is masked.
	if not _engine_play:
		_feed_mental(actual == optimal)
	# Decision grading (moving the Discipline meter) is a separate tier-ladder
	# lever: off on the T1 teaching table, on from T2. Without it the teaching
	# table penalizes imperfect play just as hard as the hardest table, so the
	# difficulty curve never engages.
	if not config.grade_decisions:
		return
	var r: Dictionary = discipline.grade_decision(actual, optimal)
	decision_graded.emit(float(r.delta), float(r.discipline))


# Deals the next card, handling a mid-hand runout. A pathological multi-split
# hand (e.g. 4-way split, every hand hit to 20) can outdraw the reserve even
# though begin_hand() guaranteed enough cards for a *normal* hand. On exhaustion
# we reshuffle and reset the count (a real "cut-change" runout) rather than
# dealing null into a hand.
func _deal_card() -> CHCard:
	var c: CHCard = shoe.deal()
	if c == null:
		_reshuffle_count += 1
		var s: int = _seed if _seed >= 0 else _reshuffle_count
		shoe.reshuffle(s + _reshuffle_count * 7919)
		count.reset()
		count.set_decks_remaining(shoe.decks_remaining_estimate())
		# Cut-change: the count just reset to a fresh shoe, so refresh the cached
		# floored true count to match (begin_hand does the same at hand start).
		# Without this the rest of the hand's I18/insurance decisions and heat
		# tells would keep using the pre-cut (stale) count.
		_tc = count.true_count_floor()
		_on_new_shoe(true)
		shoe_reshuffled.emit()
		c = shoe.deal()
	return c


func _reveal(card: CHCard, is_dealer: bool) -> void:
	count.record_card(card)
	# Keep the cached floored true count live: a real counter updates the count
	# as each card is revealed, and the sim feeds the live TC (M4). In-hand
	# decisions (I18 deviations, count-based insurance, heat tells) therefore use
	# the running count, not a stale hand-start snapshot.
	_tc = count.true_count_floor()
	# Every card that becomes visible to the player is a "deal" for SFX/audio:
	# the opening deal, drawn cards, and the hole reveal all flow through here,
	# so this is the single choke point the audio layer hooks (M128).
	card_dealt.emit(card, is_dealer)


func _mark_seen(hands: Array[CHHand]) -> void:
	for h in hands:
		for c in h.cards:
			if not c.seen:
				count.record_card(c)
				# Split-revealed cards are shown to the player, so they are
				# deals for SFX purposes too.
				card_dealt.emit(c, false)
	_tc = count.true_count_floor()


func _set_phase(p: String) -> void:
	_phase = p
	phase_changed.emit(p)


# 4-step bet ramp (mirrors sim_validate._bet_for_tc). A tunable, not a
# correctness choice.
func _bet_for_tc(tc: int) -> int:
	if tc <= -1:
		return 1
	if tc <= 1:
		return 2
	if tc <= 3:
		return 4
	return 6


# --- State for the UI to render the current table ---

func dealer_upcard() -> CHCard:
	if _dealer == null or _dealer.cards.is_empty():
		return null
	return _dealer.cards[0]


func dealer_hole() -> CHCard:
	if _hole_revealed and _hole != null:
		return _hole
	return null


# The dealer's full hand (upcard, hole, and any drawn cards) for rendering.
# Before the hole reveal only the upcard is present; after _reveal_hole the hole
# is appended and drawn cards follow, so the UI shows the whole hand.
func dealer_hand() -> CHHand:
	if _dealer == null:
		return CHHand.new()
	return _dealer


func current_hand() -> CHHand:
	if _phase == PHASE_HAND and _idx >= 0 and _idx < _hands.size():
		return _hands[_idx]
	if _phase == PHASE_PRESPLIT and _root_idx >= 0 and _root_idx < _roots.size():
		return _roots[_root_idx]
	return null


func all_hands() -> Array[CHHand]:
	return _hands


# NPC player hands this round (auto-played, display only — their P&L is not
# tracked). Empty on tiers with no NPC players.
func npc_hands() -> Array[CHHand]:
	return _npc_hands.duplicate()


# The two-card roots dealt at the start of this hand. The scene shows them
# during the insurance prompt: on a real table the player's cards are face up
# before the insurance decision, so the UI must not hide them there.
func opening_roots() -> Array[CHHand]:
	return _roots.duplicate()


func last_net() -> float:
	return _last_net


func last_wagered() -> float:
	return _last_wagered


# The floored true count at hand start (the raw, displayed count).
func current_tc() -> int:
	return _tc


# The true count that DECISIONS are based on. Under a continuous-shuffle
# machine the count has no edge, so every decision uses a flat 0: pure basic
# strategy, no I18 deviations, no count-based insurance. `current_tc()` still
# reports the raw count so the (hidden) training display and any external
# inspection can see that a count was being tracked — it is just ignored.
func effective_tc() -> int:
	return 0 if config.continuous_shuffle else _tc


# Whether the discipline system has detected a tilt pattern (loss-chasing).
func is_tilted() -> bool:
	return discipline.check_tilt()


# Remaining cover-play budget for the current shoe.
func cover_plays_left() -> int:
	return discipline.cover_plays_left()


# Remaining "ground yourself" budget for the current shoe (0..GROUND_USES_PER_SHOE).
func ground_uses_left() -> int:
	return _ground_uses_left


# --- Heat accessors (see CHHeatSystem) ---

func heat() -> float:
	return _heat.heat


func heat_percent() -> float:
	return _heat.heat / CHHeatSystem.MAX_HEAT


func needs_backoff() -> bool:
	return _heat.has_pending_backoff()


# True while the current hand is a backoff (forced min-bet) hand, i.e. the
# player was flagged at the end of the previous hand. Lets the UI show a
# "laying low — minimum bet this hand" indicator and explain the forced bet.
func is_backoff_hand() -> bool:
	return _backoff_hand


func get_heat_system() -> CHHeatSystem:
	return _heat


# --- Mental-state accessors (see CHMentalStateSystem) ---

func mental_stability() -> float:
	return _mental.stability


func mental_state() -> String:
	return _mental.mental_state()


func is_mental_insane() -> bool:
	return _mental.is_insane()


# The longest run of consecutive non-optimal plays this session (0 if the
# player never missed in a row). The debrief's composure line reads this.
func max_mental_mistake_streak() -> int:
	return _mental.max_mistake_streak


# The live mistake run in progress right now (resets to 0 on the next correct
# play). The HUD shows this as a "×N run" tag while it is non-zero, so a spiral
# is visible *before* the player crosses into the insane band, not only after.
func mental_mistake_streak() -> int:
	return _mental.mistake_streak


func get_mental_system() -> CHMentalStateSystem:
	return _mental
