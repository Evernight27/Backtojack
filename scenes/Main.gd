extends Control
# Playable blackjack trainer UI. Drives a CHGameLoop and renders the table,
# HUD, and context-sensitive action buttons. All game logic lives in
# CHGameLoop; this node is presentation only.

var _loop: CHGameLoop
var _state: CHGameState
var _discipline: CHDisciplineSystem

# --- UI refs ---
var _bankroll_label: Label
var _tc_label: Label
var _discipline_label: Label
var _tier_label: Label
var _mode_label: Label
var _status_label: Label
var _dealer_cards: HBoxContainer
var _dealer_row: HBoxContainer
var _player_area: VBoxContainer
var _action_buttons: Dictionary = {}  # action String -> Button
var _bet_buttons: Dictionary = {}     # unit int -> Button (BET phase)
var _cover_toggle: CheckButton
var _cover_label: Label
var _heat_label: Label
var _count_system_label: Label
var _tilt_label: Label
var _opponent_label: Label
var _opponent_busted: bool = false
var _tier_selector: OptionButton
var _mode_selector: OptionButton
var _shoes_spin: SpinBox
var _deal_button: Button
var _ground_button: Button
var _cash_out_button: Button
var _new_session_button: Button
# Session parameters the scene applies when it (re)starts a session.
var _mode: String = CHGameState.MODE_TARGET
var _shoes: int = 3
var _debrief_panel: PanelContainer
var _debrief_title: Label
var _debrief_lines: Array[Label] = []
var _debrief_lines_box: VBoxContainer
var _skill_before_session: float = 0.0
var _unlocked_before_session: int = 1
var _session_net: float = 0.0
# Set by _on_save_failed when the loop's session-end save reports a write
# failure; read (and cleared) by _on_session_ended to warn the player.
var _save_failed_this_session: bool = false
# Count-accuracy check UI (M16). Per-check feedback is surfaced in the
# always-visible _status_label (the prompt panel hides once answered).
var _count_acc_label: Label
# Live decision accuracy (M30): how often the player matched the optimal play
# this session. Recorded unconditionally (independent of the grade_decisions
# tier lever), so the T1 teaching table gets live accuracy feedback too.
var _decision_acc_label: Label
# Live mistake run (leading indicator of the composure spiral). Shown only while
# a run is in progress (resets to 0 on the next correct play) — a discrete
# play-quality streak, not a composure meter, so it does not break the "mental
# state is hidden" rule. Mirrors the debrief's "worst run ×N" vocabulary.
var _run_label: Label
var _skill_label: Label
var _count_check_panel: PanelContainer
var _count_check_title: Label
var _count_check_input: LineEdit
var _count_check_submit: Button
var _count_check_skip: Button
# Onboarding (M84/M130): a full-rect help/intro overlay reachable any time via
# the Help button / F1. No longer auto-shown on first launch (M130).
var _help_panel: PanelContainer
var _help_button: Button
# Career & stats (M92): a full-rect overlay surfacing persistent progression —
# skill rating + next-tier threshold, lifetime hands/sessions, unlocked tiers,
# and per-tier heat floors — data that is otherwise only visible at session end.
var _stats_panel: PanelContainer
var _stats_content: VBoxContainer
var _stats_button: Button
var _thought_label: Label
var _thought_tween: Tween
var _last_thought_ts: int = 0
# Previous mental stability (for detecting a drop on mental_changed) and the
# red vignette that fades in as the player's composure degrades (fraying/insane).
var _last_mental_stability: float = -1.0
var _vignette: TextureRect
var _vignette_tween: Tween
var _audio: CHAudioSystem
# Tutorial (M116): guided on-ramp. A single "Next" control that auto-plays what
# the current stage has not taught yet, plus a stage indicator label.
var _tutorial_next_button: Button
var _tutorial_stage_label: Label
var _tutorial_banner: Label
var _tutorial_banner_tween: Tween
var _last_tutorial_stage: int = 0
# M120: per-shoe count-check scores for the tutorial debrief (one entry per
# reported check, in shoe order). Empty until a check is reported.
var _tutorial_count_results: Array = []
# M120: which tutorial stage the currently-pending count check belongs to.
# Set in _on_count_check_due (after the shoe boundary has already advanced
# shoes_this_session, so the stage that just ended is current-1).
var _pending_count_check_stage: int = 1
# Intrusive-thought cooldown (seconds), continuous rather than fixed: the deeper
# the player is in the mental spiral, the more frequent the thoughts. The value
# is lerped between these bounds by the model's depth() each time a fraying/
# insane band-change fires, so escalation tracks the per-tier mental profile.
const THOUGHT_COOLDOWN_MAX_SEC := 12.0
const THOUGHT_COOLDOWN_MIN_SEC := 2.0
const THOUGHTS := [
	"You're miscounting. You've been miscounting the whole time.",
	"The floor is watching you.",
	"Stop. Stop counting. Just stop.",
	"They know. They always know.",
	"You missed the seven. Now everything's off.",
	"What if you've been playing the wrong system this whole time?",
	"The cards don't care about your count.",
	"Everyone else at this table is counting better than you.",
	"That last call was the mistake. It was always going to be.",
	"You're not good enough for this table.",
]

# Bankroll goal for a target-mode session. Must sit above the starting stake
# (SESSION_START_BANKROLL = 100) or the session ends on the first hand.
const START_TARGET := 150


func _ready() -> void:
	_build_ui()
	_start_session(1, _mode, START_TARGET, _shoes)


# --- Session lifecycle ---

func _start_session(tier: int, mode: String, target: int, shoes: int) -> void:
	_state = CHGameState.new()
	# A missing save is a normal first run. An EXISTING save that fails to load
	# means the player's real progress could not be restored — without handling,
	# the next session end would overwrite it and the progression would be lost.
	var save_existed: bool = FileAccess.file_exists(CHGameState.DEFAULT_SAVE_PATH)
	var save_loaded: bool = _state.load_game()  # restore skill rating / tier unlocks / heat floors
	var save_lost: bool = save_existed and not save_loaded
	_discipline = CHDisciplineSystem.new()
	_discipline.reset_for_new_session()
	var config := CHTableConfig.for_tier(tier)
	if mode == CHGameState.MODE_TUTORIAL:
		# The guided on-ramp runs on the teaching table with heat off (no backoff
		# pressure while learning) and the count display off — the player must
		# track the running count themselves, and the shoe-cut count check grades
		# it. (for_tier returns a fresh resource, so these overrides are safe.)
		# The on-ramp also teaches betting (stage 2) and play decisions (stage 3),
		# so it disables the count-only mode that the Tier 1 teaching table runs
		# by default — otherwise the guided stages would have nothing to teach.
		config.heat_active = false
		config.show_count_display = false
		config.count_only = false
	_loop = CHGameLoop.new(config, _state, _discipline, -1)
	_state.start_session(tier, mode, target, shoes)
	_mode = mode
	_shoes = shoes
	_skill_before_session = _state.get_skill_rating()
	_unlocked_before_session = _state.highest_unlocked_tier()
	_session_net = 0.0
	_save_failed_this_session = false
	_opponent_busted = false
	_debrief_panel.visible = false
	_new_session_button.visible = false
	_status_label.text = ""
	if save_lost:
		_backup_unreadable_save()
		_status_label.text = "Warning: saved progress could not be loaded; starting fresh. A copy of the old save was kept as counting_house_save.json.corrupt.bak."
	# Reset the count-check prompt so a shoe-cut prompt from a prior session does
	# not leak into the new one (the panel is a scene-level node that outlives the
	# loop it belongs to).
	_count_check_panel.visible = false
	_count_check_input.text = ""
	# Kill any in-flight ambient thought fade so the previous session's overlay
	# does not leak into the new one.
	if _thought_tween != null:
		_thought_tween.kill()
		_thought_tween = null
	_thought_label.visible = false
	_thought_label.modulate.a = 1.0
	# Reset mental composure tracking + vignette for the new session.
	_last_mental_stability = -1.0
	if _vignette_tween != null:
		_vignette_tween.kill()
		_vignette_tween = null
	if _vignette != null:
		_vignette.modulate.a = 0.0
	# Same for the tutorial stage-unlock banner (M117); the stage tracker resets
	# so the new session's first advance re-announces cleanly.
	if _tutorial_banner_tween != null:
		_tutorial_banner_tween.kill()
		_tutorial_banner_tween = null
	_tutorial_banner.visible = false
	_tutorial_banner.modulate.a = 1.0
	_last_tutorial_stage = 0
	_tutorial_count_results.clear()
	_pending_count_check_stage = 1
	_populate_tier_selector()
	_populate_mode_selector()
	_loop.shoe_reshuffled.connect(func(): _refresh_all())
	_loop.hand_settled.connect(_on_hand_settled)
	_loop.card_dealt.connect(func(_card, _is_dealer): _audio.play_deal())
	_loop.decision_graded.connect(func(_delta: float, _v: float): _refresh_hud())
	_loop.session_ended.connect(_on_session_ended)
	_loop.heat_backoff.connect(_on_heat_backoff)
	_loop.count_check_due.connect(_on_count_check_due)
	_loop.save_failed.connect(_on_save_failed)
	_loop.mental_band_changed.connect(_on_mental_band_changed)
	_loop.mental_changed.connect(_on_mental_changed)
	_loop.opponent_settled.connect(_on_opponent_settled)
	_loop.opponent_busted.connect(_on_opponent_busted)
	# Venue-arc framing (M122): announce the place you are sitting at when a
	# session starts — the "vs a friend -> vs a casino" journey. Venue name plus
	# its narrative hook; both empty in headless/test configs, so nothing shows.
	if _loop.config.venue_name != "":
		var venue_line: String = _loop.config.venue_name
		if _loop.config.venue_hook != "":
			venue_line += " — " + _loop.config.venue_hook
		_show_session_banner(venue_line)
	_refresh_all()


func _populate_mode_selector() -> void:
	_mode_selector.clear()
	_mode_selector.add_item("Target")
	_mode_selector.add_item("Practice")
	_mode_selector.add_item("Survival")
	_mode_selector.add_item("Tutorial")
	_mode_selector.select(_mode_index())
	# The shoe-count control only applies to practice / survival. The tutorial's
	# three shoes are fixed by its stage structure, so hide it there too.
	var applies: bool = _mode == CHGameState.MODE_PRACTICE or _mode == CHGameState.MODE_SURVIVAL
	# SpinBox has no `disabled` property in Godot 4 (extends Control, not Button);
	# show/hide is enough to toggle it out for target mode.
	_shoes_spin.visible = applies
	# The tutorial runs on the tier-1 teaching table; disable the tier selector so
	# the guided on-ramp cannot be interrupted by a table change.
	_tier_selector.disabled = _mode == CHGameState.MODE_TUTORIAL


func _mode_index() -> int:
	match _mode:
		CHGameState.MODE_PRACTICE:
			return 1
		CHGameState.MODE_SURVIVAL:
			return 2
		CHGameState.MODE_TUTORIAL:
			return 3
		_:
			return 0


func _on_mode_selected(index: int) -> void:
	var mode: String = _mode_from_index(index)
	if mode != _mode:
		# Only target mode takes a bankroll goal. Passing START_TARGET to
		# survival/practice would let apply_hand_result's `target_bankroll > 0`
		# check end a survival session early as "target_reached" instead of
		# "survival_complete" — the tier/mode/new-session paths all pass 0 here.
		var target: int = START_TARGET if mode == CHGameState.MODE_TARGET else 0
		# The tutorial is anchored to the tier-1 teaching table regardless of the
		# tier the player was sitting at; the guided on-ramp assumes the simplest
		# ruleset so each newly-introduced mechanic isolates one skill.
		var tier: int = 1 if mode == CHGameState.MODE_TUTORIAL else _state.current_tier
		_start_session(tier, mode, target, _shoes)


func _on_shoes_value_changed(value: int) -> void:
	_shoes = value


func _mode_from_index(index: int) -> String:
	match index:
		1:
			return CHGameState.MODE_PRACTICE
		2:
			return CHGameState.MODE_SURVIVAL
		3:
			return CHGameState.MODE_TUTORIAL
		_:
			return CHGameState.MODE_TARGET


# Copies an unreadable save aside so a later session end (which overwrites the
# default save path) cannot destroy the player's original data.
func _backup_unreadable_save() -> void:
	var save_path := ProjectSettings.globalize_path(CHGameState.DEFAULT_SAVE_PATH)
	var backup := save_path + ".corrupt.bak"
	if FileAccess.file_exists(save_path):
		DirAccess.copy_absolute(save_path, backup)


func _populate_tier_selector() -> void:
	# List every unlocked tier; the current one is selected. Tiers are
	# skill-gated (see CHGameState.is_tier_unlocked).
	var unlocked := _state.highest_unlocked_tier()
	_tier_selector.clear()
	for t in 7:
		var tier := t + 1
		if tier <= unlocked:
			var vc: CHTableConfig = CHTableConfig.for_tier(tier)
			var display: String = vc.venue_name if vc.venue_name != "" else vc.name
			_tier_selector.add_item("Tier %d — %s" % [tier, display])
	# Clamp to the actual item count: if current_tier somehow exceeds the number
	# of unlocked tiers (e.g. a stale value after a save reload), select() would
	# throw "index out of bounds". Fall back to the top available tier.
	var idx := _state.current_tier - 1
	if idx >= _tier_selector.item_count:
		idx = _tier_selector.item_count - 1
	_tier_selector.select(maxi(idx, 0))


func _on_tier_selected(index: int) -> void:
	var tier := index + 1
	if tier != _state.current_tier:
		var target: int = START_TARGET if _mode == CHGameState.MODE_TARGET else 0
		_start_session(tier, _mode, target, _shoes)


func _on_hand_settled(net: float, _wagered: float) -> void:
	if net > 0.0:
		_audio.play_win()
	elif net < 0.0:
		_audio.play_loss()
	# Accumulate the per-hand integer exactly the way the bankroll does
	# (apply_hand_result rounds each hand's net to an int). Rounding the raw
	# floats and summing them at the end would diverge from the real bankroll
	# after any half-unit hand (e.g. a 1u surrender nets -0.5 -> -1).
	_session_net += roundf(net)
	_refresh_all()
	# Session-end UI is driven by the loop's session_ended signal (covers every
	# end path: target/bust via this hand, and practice/survival via shoe
	# completion), so no duplicate handling here.
	# Count-only teaching table: the hand auto-played, so P&L is not the point —
	# the status line reinforces that the player's job is the running count.
	if _loop.config.count_only:
		_status_label.text = "Auto-played hand — report your running count."
		return
	var status_msg: String = "Hand settled: %+d" % int(roundf(net))
	# In the guided tutorial stages the player advances by pressing Next; nudge
	# them so they know the hand is done and they can continue.
	if _state.is_session_active() and _loop.tutorial_stage() in [1, 2]:
		status_msg += " — press Next to continue"
	_status_label.text = status_msg


func _on_session_ended() -> void:
	# The session's counting system is recorded by CHGameState.end_session (before
	# its save), so it persists in the same write as the session stats.
	var reason := _state.last_end_reason
	var msg := "Session ended: %s" % _reason_text(reason)
	if reason == "bust":
		msg += " — you ran out of bankroll."
	# The save_failed signal fires before session_ended, so a failed session-end
	# save is still pending here when the debrief appears.
	if _save_failed_this_session:
		msg += " — WARNING: save failed, progress may not have been persisted."
	_status_label.text = msg
	_new_session_button.visible = true
	_show_debrief(reason)
	_refresh_all()
	# Skill rating / lifetime stats change at session end (end_session EMA update);
	# refresh an open stats overlay so it doesn't show the pre-session values.
	if _stats_panel.visible:
		_populate_stats()


# The loop's session-end save could not be written. Remember it so the
# session-end status (which fires immediately after) can warn the player.
func _on_save_failed() -> void:
	_save_failed_this_session = true


func _on_heat_backoff() -> void:
	# The player was flagged as backed off; heat resets to the tier floor and
	# they're re-seated. This hand is a "backoff hand": the bet is forced to the
	# minimum (optimal_bet_units returns 1) so the pit sees them laying low.
	_status_label.text = "Backed off — minimum bet this hand, heat reset to the tier floor."
	_refresh_all()


func _on_opponent_settled(_net: float) -> void:
	_refresh_hud()


func _on_opponent_busted() -> void:
	_opponent_busted = true
	_refresh_hud()


# --- Count-check prompt (M16) ---

func _on_count_check_due(_rc: int) -> void:
	# Ask the player for the running count they tracked. On the Tier 1 count-only
	# drill this fires after every hand; on every other tier it fires at a shoe
	# cut (the shoe boundary has already advanced shoes_this_session).
	# In a tutorial, tag which stage this check belongs to so the debrief can
	# break counting accuracy down per stage; the stage that just ended is current-1.
	if _state.session_mode == CHGameState.MODE_TUTORIAL:
		_pending_count_check_stage = maxi(_loop.tutorial_stage() - 1, 1)
	# Count-only teaching table (Tier 1) quizzes after every hand, not only at a
	# shoe cut, so phrase the prompt for the hand; every other tier quizzes at a
	# shoe cut.
	_count_check_title.text = (
		"What's your running count? (Enter to submit)"
		if _loop.config.count_only
		else "Shoe cut — what's your running count? (Enter to submit)"
	)
	_count_check_input.text = ""
	_count_check_input.placeholder_text = "running count (e.g. +3, -2)"
	_count_check_panel.visible = true
	_count_check_input.grab_focus()
	_refresh_all()


func _on_count_check_submit() -> void:
	var raw: String = _count_check_input.text.strip_edges()
	# Reject empty or non-integer input: "abc" would silently coerce to 0 via
	# to_int(), and "4.5" would truncate to 4.
	if raw.is_empty() or not raw.is_valid_int():
		_status_label.text = "Enter a running count (an integer), or Skip."
		return
	var parsed: int = raw.to_int()
	var r: Dictionary = _loop.report_count(parsed)
	if r.is_empty() and _loop.is_count_check_due():
		# A check is still pending, so this value was rejected as implausible
		# (out of physical range for a running count). Keep the panel open and
		# let the player retry or skip — do not swallow their typed input.
		_status_label.text = "That count looks off — try again, or Skip."
		_refresh_all()
		return
	_dismiss_count_check_panel()
	_refresh_all()
	if r.is_empty():
		# Nothing was pending (stale panel) — nothing to report.
		_status_label.text = "No count check pending."
		return
	# Surface the result in the status line so the player always sees their score,
	# even though the prompt panel is now closed.
	if int(r.get("abs_error", -1)) == 0:
		_status_label.text = "Count: correct (you said %d). Score: %.0f/100." % [
			int(r.get("reported", 0)), float(r.get("score", 0.0))]
	else:
		_status_label.text = "Count: you said %d, actual was %d (off by %d). Score: %.0f/100." % [
			int(r.get("reported", 0)), int(r.get("actual", 0)),
			int(r.get("abs_error", 0)), float(r.get("score", 0.0))]
	# Record per-stage count results for the tutorial debrief (M120).
	if _state.session_mode == CHGameState.MODE_TUTORIAL:
		_tutorial_count_results.append({
			"stage": _pending_count_check_stage,
			"reported": int(r.get("reported", 0)),
			"actual": int(r.get("actual", 0)),
			"score": float(r.get("score", 0.0)),
		})


func _on_count_check_skip() -> void:
	_loop.skip_count_check()
	_dismiss_count_check_panel()
	_status_label.text = "Count check skipped."
	_refresh_all()


# Hides the count-check prompt and releases the input's keyboard focus. A hidden
# Control does not reliably surrender focus in Godot 4, so without the explicit
# release the (now hidden) LineEdit keeps grabbing typed keys and the
# _unhandled_input LineEdit-guard swallows every gameplay shortcut until the
# player clicks a control. No-op when the input never held focus.
func _dismiss_count_check_panel() -> void:
	_count_check_input.text = ""
	_count_check_panel.visible = false
	_count_check_input.release_focus()


func _reason_text(reason: String) -> String:
	match reason:
		"bust":
			return "Bankroll gone"
		"target_reached":
			return "Target reached"
		"cash_out":
			return "Cashed out"
		"practice_complete":
			return "Practice shoes complete"
		"survival_complete":
			return "Survived the target"
		"tutorial_complete":
			return "Tutorial complete"
		_:
			return reason


func _show_debrief(reason: String) -> void:
	var final_bankroll: int = int(roundf(_session_net)) + CHGameState.SESSION_START_BANKROLL
	var highest_now: int = _state.highest_unlocked_tier()
	# Practice mode has no economy stakes (bankroll is frozen at the starting
	# stake all session), so the P&L line must not claim a bankroll figure that
	# never moved — it would contradict the HUD "Bankroll: 100" readout.
	var pnl_suffix: String
	if _state.session_mode == CHGameState.MODE_PRACTICE:
		pnl_suffix = "practice — no stakes"
	elif _state.session_mode == CHGameState.MODE_TUTORIAL:
		pnl_suffix = "tutorial — no stakes"
	else:
		pnl_suffix = "bankroll %d" % final_bankroll
	var career_hands: int = int(_state.lifetime_stats.get("hands_played", 0))
	var career_sessions: int = int(_state.lifetime_stats.get("sessions_played", 0))
	var table_cfg: CHTableConfig = CHTableConfig.for_tier(_state.current_tier)
	var table_display: String = table_cfg.venue_name if table_cfg.venue_name != "" else table_cfg.name
	var lines: Array[String] = [
		"Table:  Tier %d — %s" % [_state.current_tier, table_display],
		"Hands:  %d    Shoes:  %d" % [_state.hands_this_session, _state.shoes_this_session],
		"Discipline:  %.0f / 100" % _discipline.discipline,
		"P&L:  %+.1f units  (%s)" % [_session_net, pnl_suffix],
		"Skill rating:  %.1f → %.1f" % [_skill_before_session, _state.get_skill_rating()],
		"Career:  %d hand%s over %d session%s" % [
			career_hands, "" if career_hands == 1 else "s",
			career_sessions, "" if career_sessions == 1 else "s"],
	]
	if not _loop.config.count_only and _discipline.session_decisions > 0:
		lines.append("Decisions:  %d / %d optimal" % [
			_discipline.session_optimal, _discipline.session_decisions])
	var acc: CHCountAccuracySystem = _loop.get_count_accuracy()
	# Composure read-out (the "going insane" spiral). Shown whenever the player
	# actually drove composure: real play decisions, or the count-only teaching
	# drill (where miscounts are what erode it). Lowest composure reached + the
	# longest mistake run this session.
	if _discipline.session_decisions > 0 or acc.checks > 0:
		var _m: CHMentalStateSystem = _loop.get_mental_system()
		lines.append("Composure:  lowest %.0f%%  ·  worst run ×%d" % [
			_m.min_stability, _m.max_mistake_streak])
	if _loop.config.count_check_active and acc.checks > 0:
		if _state.session_mode == CHGameState.MODE_TUTORIAL:
			# M120: break counting down per stage in the on-ramp debrief, and
			# keep the overall accuracy alongside it — the per-stage numbers alone
			# hide the aggregate score the skill rating actually feeds from.
			var summary: String = _tutorial_counting_summary()
			if summary != "":
				lines.append(summary + "  |  overall %.0f%% over %d check%s" % [acc.accuracy, acc.checks, "" if acc.checks == 1 else "s"])
			else:
				lines.append("Counting:  %.0f / 100  (%d checks)" % [acc.accuracy, acc.checks])
		else:
			lines.append("Counting:  %.0f / 100  (%d check%s)" % [acc.accuracy, acc.checks, "" if acc.checks == 1 else "s"])
	if highest_now > _unlocked_before_session:
		var unlock_cfg: CHTableConfig = CHTableConfig.for_tier(highest_now)
		var unlock_display: String = unlock_cfg.venue_name if unlock_cfg.venue_name != "" else unlock_cfg.name
		lines.append("Unlocked:  Tier %d — %s" % [highest_now, unlock_display])
	else:
		var top_cfg: CHTableConfig = CHTableConfig.for_tier(highest_now)
		var top_display: String = top_cfg.venue_name if top_cfg.venue_name != "" else top_cfg.name
		lines.append("Highest unlocked tier:  %d — %s" % [highest_now, top_display])
	_debrief_title.text = "Session ended — %s" % _reason_text(reason)
	# Match the label pool to the exact line count so every line renders. The
	# count varies with the session (optional decisions/composure/counting
	# lines), so a fixed pool would silently clip the trailing lines — notably
	# the "Unlocked / Highest unlocked tier" progression line on tier 2+.
	while _debrief_lines.size() > lines.size():
		_debrief_lines.pop_back().free()
	while _debrief_lines.size() < lines.size():
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 15)
		_debrief_lines_box.add_child(l)
		_debrief_lines.append(l)
	for i in _debrief_lines.size():
		_debrief_lines[i].text = lines[i]
	_debrief_panel.visible = true


# M120: per-stage counting breakdown for the tutorial debrief. Groups the
# recorded per-check scores by the stage they belonged to and shows the
# average per stage — the on-ramp is about learning to count, so the player
# sees how well they tracked in each stage. Returns "" when no check was
# reported (e.g. every count check was skipped).
func _tutorial_counting_summary() -> String:
	if _tutorial_count_results.is_empty():
		return ""
	var per_stage: Dictionary = {}
	for r in _tutorial_count_results:
		var s: int = int(r.get("stage", 1))
		if not per_stage.has(s):
			per_stage[s] = {"sum": 0.0, "n": 0}
		per_stage[s]["sum"] += float(r.get("score", 0.0))
		per_stage[s]["n"] += 1
	var parts: Array[String] = []
	for s in per_stage.keys():
		var entry: Dictionary = per_stage[s]
		parts.append("S%d %.0f%%" % [s, float(entry["sum"]) / float(entry["n"])])
	parts.sort()
	return "Counting:  " + "  |  ".join(parts)


func _new_session() -> void:
	_new_session_button.visible = false
	_status_label.text = ""
	var target: int = START_TARGET if _mode == CHGameState.MODE_TARGET else 0
	_start_session(_state.current_tier, _mode, target, _shoes)


# --- UI construction ---

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	vbox.offset_left = 16
	vbox.offset_top = 16
	vbox.offset_right = -16
	vbox.offset_bottom = -16
	add_child(vbox)

	# HUD — a flowing container so the readout labels wrap to a second line at
	# narrow widths instead of clipping the interactive tier/mode controls.
	var hud := HFlowContainer.new()
	hud.add_theme_constant_override("separation", 24)
	hud.add_theme_constant_override("h_separation", 24)
	hud.add_theme_constant_override("v_separation", 6)
	vbox.add_child(hud)
	_bankroll_label = _hud_label(hud, "Bankroll: ")
	_tc_label = _hud_label(hud, "True count: ")
	_discipline_label = _hud_label(hud, "Discipline: ")
	_tier_label = _hud_label(hud, "Tier: ")
	_mode_label = _hud_label(hud, "Mode: ")
	_skill_label = _hud_label(hud, "Skill: ")
	_cover_label = _hud_label(hud, "Cover: ")
	_heat_label = _hud_label(hud, "Heat: ")
	# Count accuracy (M16): running mean of RC-report scores. Shown only when the
	# tier runs count checks.
	_count_acc_label = _hud_label(hud, "Count acc: ")
	# Decision accuracy (M30): how often the player matched the optimal play this
	# session. Shown on every tier — the record is unconditional, so even the
	# teaching table (grading off) gets live accuracy feedback.
	_decision_acc_label = _hud_label(hud, "Decisions: ")
	# Live mistake run (leading indicator of the composure spiral). Hidden while the
	# player is clean; a discrete play-quality streak, not a composure meter.
	_run_label = _hud_label(hud, "")
	# Note: the mental-stability layer (CHMentalStateSystem) is intentionally not
	# surfaced in the HUD. It is a hidden, process-consistency signal intended to
	# drive ambient effects (see mental_band_changed) rather than a visible meter.
	# Live count details (shown only when the tier's count display is on).
	_count_system_label = _hud_label(hud, "")
	_opponent_label = _hud_label(hud, "")
	_opponent_label.visible = false
	# Tier selector: lets you sit at any unlocked tier's table.
	_tier_selector = OptionButton.new()
	_tier_selector.add_theme_font_size_override("font_size", 16)
	# item_selected fires only on a real user click (NOT on programmatic
	# select()), so the pre-select in _populate_tier_selector is display-only.
	_tier_selector.item_selected.connect(_on_tier_selected)
	hud.add_child(_tier_selector)

	# Mode selector: target (bankroll goal) / practice (no stakes, N shoes) /
	# survival (survive N shoes). Restart the session with the chosen mode.
	_mode_selector = OptionButton.new()
	_mode_selector.add_theme_font_size_override("font_size", 16)
	_mode_selector.item_selected.connect(_on_mode_selected)
	hud.add_child(_mode_selector)

	# Shoe count for practice/survival sessions. Hidden/disabled for target.
	_shoes_spin = SpinBox.new()
	_shoes_spin.min_value = 1
	_shoes_spin.max_value = 50
	_shoes_spin.step = 1
	_shoes_spin.value = _shoes
	_shoes_spin.add_theme_font_size_override("font_size", 16)
	_shoes_spin.value_changed.connect(_on_shoes_value_changed)
	hud.add_child(_shoes_spin)

	# Cards area
	_player_area = VBoxContainer.new()
	_player_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_player_area.add_theme_constant_override("separation", 12)
	_dealer_row = HBoxContainer.new()
	_dealer_row.add_theme_constant_override("separation", 8)
	var dl := Label.new()
	dl.text = "Dealer"
	_dealer_row.add_child(dl)
	_dealer_cards = HBoxContainer.new()
	_dealer_cards.add_theme_constant_override("separation", 6)
	_dealer_row.add_child(_dealer_cards)
	_player_area.add_child(_dealer_row)
	vbox.add_child(_player_area)

	# Debrief (session-end summary). Hidden until a session ends.
	_debrief_panel = PanelContainer.new()
	_debrief_panel.visible = false
	_debrief_panel.add_theme_constant_override("custom_margin_left", 12)
	_debrief_panel.add_theme_constant_override("custom_margin_right", 12)
	_debrief_panel.add_theme_constant_override("custom_margin_top", 8)
	_debrief_panel.add_theme_constant_override("custom_margin_bottom", 8)
	vbox.add_child(_debrief_panel)
	var debrief_vbox := VBoxContainer.new()
	debrief_vbox.add_theme_constant_override("separation", 4)
	_debrief_panel.add_child(debrief_vbox)
	_debrief_lines_box = debrief_vbox
	_debrief_title = Label.new()
	_debrief_title.add_theme_font_size_override("font_size", 20)
	debrief_vbox.add_child(_debrief_title)
	# Debrief line labels are created on demand by _show_debrief to match the
	# actual line count, so a varying number of lines can never clip the last.

	# Status
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(_status_label)

	# Tutorial stage indicator (M116): only shown while a tutorial session is
	# running; names the current stage and what the player is practicing.
	_tutorial_stage_label = Label.new()
	_tutorial_stage_label.add_theme_font_size_override("font_size", 15)
	_tutorial_stage_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.55))
	_tutorial_stage_label.visible = false
	vbox.add_child(_tutorial_stage_label)

	# Actions
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	vbox.add_child(actions)
	for a in [
		CHGameLoop.ACT_HIT, CHGameLoop.ACT_STAND, CHGameLoop.ACT_DOUBLE,
		CHGameLoop.ACT_SPLIT, CHGameLoop.ACT_SURRENDER,
		CHGameLoop.ACT_PLAY, CHGameLoop.ACT_INS_TAKE, CHGameLoop.ACT_INS_DECLINE,
	]:
		var b := Button.new()
		b.text = _action_title(a)
		b.disabled = true
		b.pressed.connect(_on_action.bind(a))
		actions.add_child(b)
		_action_buttons[a] = b

	_deal_button = Button.new()
	_deal_button.text = "Deal Next Hand (Space)"
	_deal_button.pressed.connect(_on_deal)
	actions.add_child(_deal_button)

	# Ground (composure recovery): a between-hands action, shown only when idle
	# and uses remain. Kept out of _action_buttons so the per-hand action gating
	# (show_actions) does not hide it during play; its own gate lives in
	# _refresh_actions.
	_ground_button = Button.new()
	_ground_button.text = "Ground (G)"
	_ground_button.pressed.connect(_on_ground)
	actions.add_child(_ground_button)

	# Tutorial (M116): single advance control for the guided on-ramp. In stage 1
	# it starts the hand and auto-plays it so the player only counts; in stage 2
	# it auto-plays the strategy after the player has bet. Hidden outside the
	# tutorial and in stage 3 (full manual play).
	_tutorial_next_button = Button.new()
	_tutorial_next_button.text = "Next (Space)"
	_tutorial_next_button.visible = false
	_tutorial_next_button.pressed.connect(_on_tutorial_next)
	actions.add_child(_tutorial_next_button)

	_cash_out_button = Button.new()
	_cash_out_button.text = "Cash Out"
	_cash_out_button.pressed.connect(_on_cash_out)
	actions.add_child(_cash_out_button)

	_new_session_button = Button.new()
	_new_session_button.text = "New Session"
	_new_session_button.visible = false
	_new_session_button.pressed.connect(_new_session)
	actions.add_child(_new_session_button)

	_help_button = Button.new()
	_help_button.text = "Help (F1)"
	_help_button.pressed.connect(_on_help_pressed)
	actions.add_child(_help_button)

	_stats_button = Button.new()
	_stats_button.text = "Stats (Tab)"
	_stats_button.pressed.connect(_on_stats_pressed)
	actions.add_child(_stats_button)

	# Bet unit buttons (shown during PHASE_BET)
	_bet_buttons.clear()
	for u in CHGameLoop.MAX_BET_UNITS:
		var b := Button.new()
		b.text = str(u + 1) + "u"
		b.pressed.connect(_on_bet_units.bind(u + 1))
		actions.add_child(b)
		_bet_buttons[u + 1] = b

	_cover_toggle = CheckButton.new()
	_cover_toggle.text = "Cover (C)"
	_cover_toggle.toggled.connect(func(_on): _refresh_actions())
	actions.add_child(_cover_toggle)

	# Tilt indicator
	_tilt_label = Label.new()
	_tilt_label.text = ""
	_tilt_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_tilt_label)

	# Count-check prompt (M16). Shown when a shoe cut happens and the tier runs
	# count checks; the player reports the running count they tracked.
	_count_check_panel = PanelContainer.new()
	_count_check_panel.visible = false
	_count_check_panel.add_theme_constant_override("custom_margin_left", 12)
	_count_check_panel.add_theme_constant_override("custom_margin_right", 12)
	_count_check_panel.add_theme_constant_override("custom_margin_top", 8)
	_count_check_panel.add_theme_constant_override("custom_margin_bottom", 8)
	vbox.add_child(_count_check_panel)
	var cc_vbox := VBoxContainer.new()
	cc_vbox.add_theme_constant_override("separation", 6)
	_count_check_panel.add_child(cc_vbox)
	_count_check_title = Label.new()
	_count_check_title.add_theme_font_size_override("font_size", 16)
	cc_vbox.add_child(_count_check_title)
	_count_check_input = LineEdit.new()
	_count_check_input.placeholder_text = "running count (e.g. 4, -2)"
	_count_check_input.add_theme_font_size_override("font_size", 16)
	_count_check_input.text_submitted.connect(func(_t: String) -> void: _on_count_check_submit())
	cc_vbox.add_child(_count_check_input)
	var cc_btns := HBoxContainer.new()
	cc_btns.add_theme_constant_override("separation", 8)
	_count_check_submit = Button.new()
	_count_check_submit.text = "Submit count"
	_count_check_submit.pressed.connect(_on_count_check_submit)
	cc_btns.add_child(_count_check_submit)
	_count_check_skip = Button.new()
	_count_check_skip.text = "Skip"
	_count_check_skip.pressed.connect(_on_count_check_skip)
	cc_btns.add_child(_count_check_skip)
	cc_vbox.add_child(cc_btns)

	# Help / intro overlay (M84). Added last so it draws above the table.
	_build_help_panel()
	# Career & stats overlay (M92). Added after help so it stacks above it.
	_build_stats_panel()
	# Intrusive-thought overlay (M114). Added last so it draws above every panel.
	_build_thought_label()
	_build_tutorial_banner()
	# Red composure vignette: topmost overlay, faded in/out by the mental band.
	_build_vignette()
	# Procedural SFX (deal/win/loss) + ambient mood. Headless-safe (no-op in the
	# test suite), so always safe to instantiate.
	_audio = CHAudioSystem.new()
	add_child(_audio)


func _build_help_panel() -> void:
	_help_panel = PanelContainer.new()
	_help_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_help_panel.offset_left = 32
	_help_panel.offset_top = 32
	_help_panel.offset_right = -32
	_help_panel.offset_bottom = -32
	_help_panel.visible = false
	add_child(_help_panel)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.12, 0.15, 0.97)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	_help_panel.add_theme_stylebox_override("panel", sb)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_help_panel.add_child(vbox)
	var title := Label.new()
	title.text = "Counting House — how it works"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)
	for section in _help_sections():
		var l := Label.new()
		l.text = section
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", 15)
		content.add_child(l)
	var close_btn := Button.new()
	close_btn.text = "Got it — start playing"
	close_btn.pressed.connect(_hide_help)
	vbox.add_child(close_btn)


# Career & stats overlay (M92). Same full-rect structure as the help panel but
# repopulated on every open, since the persistent data changes between sessions.
func _build_stats_panel() -> void:
	_stats_panel = PanelContainer.new()
	_stats_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stats_panel.offset_left = 32
	_stats_panel.offset_top = 32
	_stats_panel.offset_right = -32
	_stats_panel.offset_bottom = -32
	_stats_panel.visible = false
	add_child(_stats_panel)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.12, 0.15, 0.97)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	_stats_panel.add_theme_stylebox_override("panel", sb)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_stats_panel.add_child(vbox)
	var title := Label.new()
	title.text = "Career & stats"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_stats_content = VBoxContainer.new()
	_stats_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats_content.add_theme_constant_override("separation", 8)
	scroll.add_child(_stats_content)
	var close_btn := Button.new()
	close_btn.text = "Close (Esc)"
	close_btn.pressed.connect(_hide_stats)
	vbox.add_child(close_btn)


# Ambient intrusive-thought label (M114). A single line that fades in when the
# hidden sanity band degrades, then fades out — a subtle cue that the player is
# slipping, not a meter they read or manage. Hidden until triggered.
func _build_thought_label() -> void:
	_thought_label = Label.new()
	_thought_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_thought_label.add_theme_font_size_override("font_size", 15)
	_thought_label.add_theme_color_override("font_color", Color(0.72, 0.58, 0.52))
	_thought_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_thought_label.add_theme_constant_override("shadow_offset_x", 1)
	_thought_label.add_theme_constant_override("shadow_offset_y", 1)
	_thought_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_thought_label.offset_top = -20
	_thought_label.offset_bottom = 10
	_thought_label.visible = false
	add_child(_thought_label)


# Tutorial stage-transition banner (M117). A prominent one-line cue that fades in
# when a new stage unlocks (stage 2, stage 3) — the on-ramp's pivotal moments.
# Vertically centered on screen (M131) so it never overlaps the top HUD readouts.
# Hidden until a transition fires.
func _build_tutorial_banner() -> void:
	_tutorial_banner = Label.new()
	_tutorial_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tutorial_banner.add_theme_font_size_override("font_size", 18)
	_tutorial_banner.add_theme_color_override("font_color", Color(0.55, 0.82, 0.62))
	_tutorial_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	_tutorial_banner.add_theme_constant_override("shadow_offset_x", 1)
	_tutorial_banner.add_theme_constant_override("shadow_offset_y", 1)
	# Full-rect region: the label spans the whole screen (with side margins) and
	# vertically centers its text within that region, so it never overlaps the
	# top HUD readouts.
	_tutorial_banner.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tutorial_banner.offset_left = 80
	_tutorial_banner.offset_right = -80
	_tutorial_banner.offset_top = 0
	_tutorial_banner.offset_bottom = 0
	_tutorial_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_tutorial_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_banner.visible = false
	add_child(_tutorial_banner)


# Shows a session banner with a fade-in / hold / fade-out. Used for the
# stage-unlock announcements and the session-start venue framing. Never blocks
# input.
func _show_session_banner(text: String) -> void:
	_tutorial_banner.text = text
	_tutorial_banner.modulate.a = 0.0
	_tutorial_banner.visible = true
	if _tutorial_banner_tween:
		_tutorial_banner_tween.kill()
	# create_tween() requires the node to be in the tree; headless tests build the
	# UI without a root, so only fade when actually in a live scene.
	if not is_inside_tree():
		return
	_tutorial_banner_tween = create_tween()
	_tutorial_banner_tween.tween_property(_tutorial_banner, "modulate:a", 1.0, 0.4)
	_tutorial_banner_tween.tween_interval(4.0)
	_tutorial_banner_tween.tween_property(_tutorial_banner, "modulate:a", 0.0, 0.8)
	_tutorial_banner_tween.tween_callback(func():
		_tutorial_banner.visible = false)


# Shows the current thought with a fade-in / hold / fade-out. Ambient, so it
# never blocks input — purely a transient visual cue.
func _show_thought(text: String) -> void:
	_thought_label.text = text
	_thought_label.modulate.a = 0.0
	_thought_label.visible = true
	if _thought_tween:
		_thought_tween.kill()
	if not is_inside_tree():
		return
	_thought_tween = create_tween()
	_thought_tween.tween_property(_thought_label, "modulate:a", 0.9, 0.6)
	_thought_tween.tween_interval(3.0)
	_thought_tween.tween_property(_thought_label, "modulate:a", 0.0, 0.8)
	_thought_tween.tween_callback(func():
		_thought_label.visible = false)


# Fires when the hidden sanity band changes (M114). Drives the red vignette:
# it fades in as composure degrades to fraying/insane and fades out as the
# player recovers to calm/strained. No player-facing meter — just the world
# reddening around the edges as the spiral takes hold.
func _on_mental_band_changed(_old_band: String, new_band: String) -> void:
	_update_vignette(new_band)
	if _audio:
		_audio.set_band(new_band)


# Continuous thought pacing: fires on every mental_changed (i.e. every
# composure change from a mistake, bet, or count miss). A thought surfaces only
# when stability just DROPPED (a lapse, not a recovery), the player is in the
# fraying/insane band, and the depth-scaled cooldown has elapsed. This is what
# makes the spiral feel continuous — a player sinking deep gets thoughts on
# nearly every miss, while one barely frayed gets them rarely.
func _on_mental_changed(stability: float) -> void:
	# Keep the live mistake-run tag in sync on every composure change (a bet
	# lapse changes the streak *before* any hand event would otherwise refresh).
	_refresh_run_label()
	var decreased: bool = _last_mental_stability >= 0.0 and stability < _last_mental_stability
	_last_mental_stability = stability
	if not decreased:
		return
	var band: String = _loop.get_mental_system().mental_state()
	if band != CHMentalStateSystem.STATE_FRAYING and band != CHMentalStateSystem.STATE_INSANE:
		return
	var now: int = int(Time.get_ticks_msec() / 1000.0)
	var cooldown: int = int(_thought_cooldown_sec())
	if now - _last_thought_ts < cooldown:
		return
	_last_thought_ts = now
	_show_thought(THOUGHTS.pick_random())


# Deeper in the spiral -> shorter cooldown -> more frequent intrusive thoughts.
# Reads the model's depth() (0 calm .. 1 deep insane) so the pacing follows the
# per-tier profile instead of a hard-coded 8s.
func _thought_cooldown_sec() -> float:
	return lerp(THOUGHT_COOLDOWN_MAX_SEC, THOUGHT_COOLDOWN_MIN_SEC, _loop.get_mental_system().depth())


# Tints the screen edges red in proportion to how far the player has fallen.
# calm/strained -> no tint, fraying -> light, insane -> strong.
func _update_vignette(new_band: String) -> void:
	var target: float = 0.0
	if new_band == CHMentalStateSystem.STATE_INSANE:
		target = 0.9
	elif new_band == CHMentalStateSystem.STATE_FRAYING:
		target = 0.5
	if _vignette == null:
		return
	if _vignette_tween != null:
		_vignette_tween.kill()
	_vignette_tween = create_tween()
	_vignette_tween.tween_property(_vignette, "modulate:a", target, 0.8)


# Builds the red vignette (a radial gradient texture, transparent at the centre
# darkening red toward the edges) as a full-rect overlay that fades in/out via
# modulate alpha. Built last so it sits above the table; modulate alpha is 0
# until composure degrades, so it never tints the normal play.
func _build_vignette() -> void:
	_vignette = TextureRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.expand = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.modulate.a = 0.0
	var grad := Gradient.new()
	grad.offsets = [0.0, 0.62, 1.0]
	grad.colors = [Color(0.35, 0.0, 0.0, 0.0), Color(0.35, 0.0, 0.0, 0.05), Color(0.42, 0.0, 0.0, 0.62)]
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 1.0)
	tex.width = 1024
	tex.height = 1024
	_vignette.texture = tex
	add_child(_vignette)


func _show_stats() -> void:
	_populate_stats()
	_stats_panel.visible = true


func _hide_stats() -> void:
	_stats_panel.visible = false


func _on_stats_pressed() -> void:
	if _stats_panel.visible:
		_hide_stats()
	else:
		_show_stats()


# Rebuilds the overlay's content labels from the current persistent state.
func _populate_stats() -> void:
	for c in _stats_content.get_children():
		c.queue_free()
	for line in _stats_lines():
		var l := Label.new()
		l.text = line
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", 16)
		_stats_content.add_child(l)


# The career/stats readout lines, built purely from persistent state so they are
# testable without driving the scene tree. All values come from CHGameState
# (never bankroll), matching the skill-gated progression design.
func _stats_lines() -> Array[String]:
	var lines: Array[String] = []
	var rating: float = _state.get_skill_rating()
	lines.append("Skill rating:  %.1f  —  %s" % [rating, _next_tier_note(rating)])
	var hands: int = int(_state.lifetime_stats.get("hands_played", 0))
	var sessions: int = int(_state.lifetime_stats.get("sessions_played", 0))
	lines.append("Lifetime:  %d hand%s over %d session%s" % [
		hands, "" if hands == 1 else "s", sessions, "" if sessions == 1 else "s"])
	lines.append("Unlocked tiers:  " + _unlocked_tiers_text())
	lines.append("Counting systems:  " + _counting_systems_text())
	lines.append(_heat_floors_text())
	return lines


# Comma-joined list of the counting systems the player has trained on (recorded
# at each session end from the tier's active system). Shown in canonical order
# so the readout is stable regardless of the order systems were first played.
func _counting_systems_text() -> String:
	var names := ["Hi-Lo", "KO", "Hi-Opt II"]
	var ids := ["hi_lo", "ko", "hi_opt_ii"]
	var out: Array[String] = []
	for i in ids.size():
		if _state.is_system_unlocked(ids[i]):
			out.append(names[i])
	return ", ".join(out) if out.size() > 0 else "none yet"


# Human note on how close the rating is to the next tier unlock, named in
# venue terms (the arc: kitchen table -> rec room -> card room -> casino ->
# pro circuit) so the readout matches the session flow.
func _next_tier_note(_rating: float) -> String:
	var h: int = _state.highest_unlocked_tier()
	if h >= CHGameState.TIER_SKILL_THRESHOLDS.size():
		return "max tier reached"
	var next_tier: int = h + 1
	var next_cfg: CHTableConfig = CHTableConfig.for_tier(next_tier)
	var next_name: String = next_cfg.venue_name if next_cfg.venue_name != "" else next_cfg.name
	var next_thr: float = CHGameState.TIER_SKILL_THRESHOLDS[h]
	return "%s (T%d) unlocks at %.0f" % [next_name, next_tier, next_thr]


# Comma-joined list of unlocked venues with their tier numbers, in ladder
# order (e.g. "Kitchen Table (T1), The Rec Room (T2), ..."). Venue names make
# the career screen read as the same arc the session flow shows.
func _unlocked_tiers_text() -> String:
	var out: Array[String] = []
	for t in CHGameState.TIER_SKILL_THRESHOLDS.size():
		var tier := t + 1
		if _state.is_tier_unlocked(tier):
			var c: CHTableConfig = CHTableConfig.for_tier(tier)
			var nm: String = c.venue_name if c.venue_name != "" else c.name
			out.append("%s (T%d)" % [nm, tier])
	return ", ".join(out) if out.size() > 0 else "T1"


# Per-tier persistent heat floors, as a percent of max heat.
func _heat_floors_text() -> String:
	var parts: Array[String] = []
	var floors: Dictionary = _state.reputation_heat_floor
	var entries: Array = []
	for k in floors.keys():
		var tier: int = int(k)
		var pct: int = int(roundf(float(floors[k]) / CHHeatSystem.MAX_HEAT * 100.0))
		if pct > 0:
			entries.append([tier, "T%d %d%%" % [tier, pct]])
	# Sort by tier number (not the label string), so T10 does not file under T1.
	entries.sort_custom(func(a, b): return a[0] < b[0])
	for e in entries:
		parts.append(e[1])
	return ("Heat floors:  " + ", ".join(parts)) if parts.size() > 0 else "Heat floors:  none recorded"


func _help_sections() -> Array[String]:
	return [
		"What this is: a blackjack card-counting trainer. You play hands as a real casino counter would — track the running count, bet up when it is hot, lay low when it is cold.",
		"Progression: seven table tiers, from a friend's kitchen table up to the Tier 7 continuous-shuffle contrast. Each tier is a different place with a different opponent — Kitchen Table, Rec Room, Card Room, City Casino, High Stakes Floor, High Roller Pit, Pro Circuit. Tiers unlock with your skill rating (0-100), which is updated at every session end from your process — decision quality and running-count accuracy — never from bankroll. Luck cannot demote you.",
		"Sal: your recurring rival sits at every table with his own bankroll. His cards and running P&L show in purple. He bets and plays on his own policy — beat him hand to hand, or watch him bust and take the seat.",
		"Tier 1 is a pure counting drill: the hands deal and play themselves, and your only job is to track the running count from the cards you can see, then report it (e.g. +3 or -2). No betting, cover, or play decisions until you advance.",
		"Modes: Target — reach the bankroll goal. Practice — play N shoes with no stakes. Survival — survive N shoes with real stakes on the table.",
		"Heat: the pit watches for counting tells (betting up on a hot count, taking insurance, count-based deviations). Heat builds on each tell, decays while you lay low, and at maximum you are backed off and re-seated — at that tier's heat floor, which persists across sessions.",
		"Cover: up to 3 bets per shoe can be declared as cover — a deliberate lay-low bet that is exempt from the discipline penalty.",
		"Count checks: you report the running count you tracked — after every hand on the Tier 1 drill, at each shoe cut on higher tiers. Count every visible card (yours, the dealer's, and the other players' seats that join the table at higher tiers). Accuracy is graded and feeds your skill rating.",
		"Controls: Space deal · 1-6 bet size · C cover · H hit · S stand · D double · R surrender · T take insurance · N decline insurance · S split · P play (no split) · Enter submit count · Tab stats · F1 help · Esc close panel.",
	]


func _show_help() -> void:
	_help_panel.visible = true


func _hide_help() -> void:
	_help_panel.visible = false


func _on_help_pressed() -> void:
	if _help_panel.visible:
		_hide_help()
	else:
		_show_help()


func _hud_label(parent: Control, prefix: String) -> Label:
	var l := Label.new()
	l.text = prefix
	l.add_theme_font_size_override("font_size", 16)
	parent.add_child(l)
	return l


# Button labels carry the keyboard shortcut in parentheses so the M76 key
# bindings are discoverable without reading docs. S is shared between Stand
# (HAND) and Split (PRESPLIT) — the two are never visible in the same phase.
func _action_title(a: String) -> String:
	match a:
		CHGameLoop.ACT_HIT:
			return "Hit (H)"
		CHGameLoop.ACT_STAND:
			return "Stand (S)"
		CHGameLoop.ACT_DOUBLE:
			return "Double (D)"
		CHGameLoop.ACT_SPLIT:
			return "Split (S)"
		CHGameLoop.ACT_SURRENDER:
			return "Surrender (R)"
		CHGameLoop.ACT_PLAY:
			return "Play (no split) (P)"
		CHGameLoop.ACT_INS_TAKE:
			return "Take Insurance (T)"
		CHGameLoop.ACT_INS_DECLINE:
			return "Decline Insurance (N)"
		_:
			return a


# --- Interaction ---

# The between-hands "ground yourself" action: tops up composure and breaks the
# mistake streak, spent from a per-shoe budget. Only meaningful while idle and
# while uses remain (the loop no-ops otherwise); the button/keyboard gate mirrors
# this so the player sees it only when it can do something.
func _on_ground() -> void:
	if not _loop.is_idle() or _loop.ground_uses_left() <= 0:
		return
	_loop.apply_action(CHGameLoop.ACT_GROUND)
	_refresh_all()


func _on_deal() -> void:
	if not _loop.begin_hand():
		# If the session is still active, begin_hand() failed for a transient
		# reason. If it is inactive, the session just ended (target/bust on the
		# prior hand, or practice/survival at this shoe cut) and the
		# session_ended handler already surfaced the debrief + New Session
		# button, so do not clobber that status.
		if _state.is_session_active():
			_status_label.text = "Cannot start hand."
		return
	# Count-only teaching table (Tier 1): deal and play the hand automatically;
	# the player's only interaction is the running-count report at each shoe cut.
	if _loop.config.count_only:
		_loop.auto_play_round()
	_refresh_all()


func _on_action(a: String) -> void:
	# Capture the optimal call (and whether it was a count-driven deviation)
	# before the phase leaves the current decision, so the feedback names the
	# target. Engine auto-play (auto_play_round, tutorial stages 1-2) applies
	# actions directly and never reaches this handler, so this is always a
	# genuine player decision — no mode gate needed.
	var optimal: String = _loop.optimal_action()
	var is_dev: bool = _loop.is_deviation_play()
	_loop.apply_action(a)
	_refresh_all()
	if optimal != "":
		_status_label.text = _action_status_text(a, optimal, is_dev)


func _on_bet_units(u: int) -> void:
	var cover: bool = _cover_toggle.button_pressed
	# Capture the count-optimal ramp bet before the phase leaves BET. Shown on
	# tiers that grade the bet ramp and in tutorial mode (stage 2-3), so a
	# correct bet is reinforced and a short/long bet names the target.
	var optimal: int = _loop.optimal_bet_units()
	var cover_before: int = _discipline.cover_plays_left()
	_loop.place_bet(u, cover)
	_cover_toggle.button_pressed = false
	_refresh_all()
	# The teaching table (tier 1) does not grade bet ramps in normal play, but the
	# tutorial needs that feedback: stage 2 is where betting on the true count is
	# taught, and without the post-bet hint the player cannot tell if the bet size
	# matched the count. Only shown when the player actually places the bet
	# (stages 2-3); stage 1 auto-bets through the loop, never this handler.
	if _loop.config.grade_bet_ramp or _state.session_mode == CHGameState.MODE_TUTORIAL:
		var cover_granted: bool = cover and _discipline.cover_plays_left() < cover_before
		_status_label.text = _bet_status_text(u, optimal, cover_granted)


# Post-decision bet-sizing feedback (shown only on tiers that grade the ramp).
# Pure string builder so it is directly testable without driving a deal.
func _bet_status_text(u: int, optimal: int, cover_granted: bool) -> String:
	if cover_granted:
		return "Bet: %du (cover)" % u
	if u == optimal:
		return "Bet: %du (optimal)" % u
	return "Bet: %du — optimal was %du" % [u, optimal]


# Post-decision play-call feedback, mirroring the bet feedback: names the
# optimal call so a short/long (or off-basic) decision is reinforced. The
# "(count deviation)" tag marks the hands where the live count changed the right
# play from basic strategy — the central skill this trainer teaches.
func _action_status_text(a: String, optimal: String, is_dev: bool) -> String:
	var tag: String = " (count deviation)" if is_dev else ""
	if a == optimal:
		return "%s (optimal)%s" % [_pretty_action(a), tag]
	return "%s — optimal was %s%s" % [_pretty_action(a), _pretty_action(optimal), tag]


# Keyless, human-readable form of an action constant for status text (the
# on-screen buttons use _action_title, which also carries the hotkey).
func _pretty_action(a: String) -> String:
	match a:
		CHGameLoop.ACT_HIT:
			return "Hit"
		CHGameLoop.ACT_STAND:
			return "Stand"
		CHGameLoop.ACT_DOUBLE:
			return "Double"
		CHGameLoop.ACT_SURRENDER:
			return "Surrender"
		CHGameLoop.ACT_SPLIT:
			return "Split"
		CHGameLoop.ACT_PLAY:
			return "No split"
		CHGameLoop.ACT_INS_TAKE:
			return "Take insurance"
		CHGameLoop.ACT_INS_DECLINE:
			return "Decline insurance"
	return a


func _on_cash_out() -> void:
	_dismiss_count_check_panel()
	_loop.cash_out()


# --- Keyboard shortcuts ---
# Per-phase key bindings. Letters match the on-screen action labels (H hit,
# S stand, D double, R surrender); digits 1-6 place a bet in the BET phase;
# C toggles the cover checkbox; Space deals. The count-check LineEdit owns its
# own typed input (and Enter submits via text_submitted), so this handler only
# sees keys when no text field has focus.
func _unhandled_input(event: InputEvent) -> void:
	var k: InputEventKey = event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_F1:
		_on_help_pressed()
		return
	if k.keycode == KEY_TAB:
		_on_stats_pressed()
		return
	# An open overlay gates gameplay input (the panel sits above the table).
	if _help_panel.visible or _stats_panel.visible:
		if k.keycode == KEY_ESCAPE:
			if _help_panel.visible:
				_hide_help()
			if _stats_panel.visible:
				_hide_stats()
		return
	if not _state.is_session_active():
		return
	var vp := get_viewport()
	if vp != null and vp.gui_get_focus_owner() is LineEdit:
		return
	# Tutorial (M116): stages 1-2 are auto-advanced — Space is the only gameplay
	# key (it drives _on_tutorial_next, which also honours the count-check gate).
	# Enter still submits a pending count report. Other keys are ignored so a
	# stray H/S/D or 1-6 cannot slip a manual decision/bet into the guided flow.
	var tut_stage: int = _loop.tutorial_stage()
	if tut_stage in [1, 2]:
		if _loop.is_count_check_due() and k.keycode == KEY_ENTER:
			_on_count_check_submit()
			return
		if k.keycode == KEY_SPACE:
			_on_tutorial_next()
			return
		# Stage 2 bets manually, so the normal bet keys (1-6, C) must work here
		# even though the guided flow otherwise blocks stray keys.
		if tut_stage == 2 and _loop.phase() == CHGameLoop.PHASE_BET:
			if k.keycode >= KEY_1 and k.keycode <= KEY_6:
				_on_bet_units(k.keycode - KEY_1 + 1)
			elif k.keycode == KEY_C:
				_cover_toggle.button_pressed = not _cover_toggle.button_pressed
				_refresh_actions()
		return
	var phase: String = _loop.phase()
	match phase:
		CHGameLoop.PHASE_IDLE, CHGameLoop.PHASE_SETTLED:
			# Count-only teaching table (Tier 1): a shoe-cut count report, if
			# pending, must be answered before the next hand is dealt — Enter
			# submits it, Space waits. Mirrors the deal-button gate.
			if _loop.config.count_only and _loop.is_count_check_due():
				if k.keycode == KEY_ENTER:
					_on_count_check_submit()
				return
			if k.keycode == KEY_G and _loop.ground_uses_left() > 0:
				_on_ground()
			elif k.keycode == KEY_SPACE or k.keycode == KEY_ENTER:
				_on_deal()
		CHGameLoop.PHASE_BET:
			# Shoe-cut count check gates the bet: the bet buttons are disabled
			# while it is pending, so the keyboard path must honour the same gate
			# or 1-6 would bypass the forcing function. Enter submits the report
			# when focus has left the input (the LineEdit handles it itself when
			# focused, so there is no double-submit).
			if _loop.is_count_check_due():
				if k.keycode == KEY_ENTER:
					_on_count_check_submit()
				return
			var unit: int = -1
			if k.keycode >= KEY_1 and k.keycode <= KEY_6:
				unit = k.keycode - KEY_1 + 1
			if unit > 0:
				_on_bet_units(unit)
			elif k.keycode == KEY_C:
				_cover_toggle.button_pressed = not _cover_toggle.button_pressed
				_refresh_actions()
		CHGameLoop.PHASE_INSURANCE:
			var avail: Array[String] = _loop.available_actions()
			if k.keycode == KEY_T and avail.has(CHGameLoop.ACT_INS_TAKE):
				_on_action(CHGameLoop.ACT_INS_TAKE)
			elif k.keycode == KEY_N and avail.has(CHGameLoop.ACT_INS_DECLINE):
				_on_action(CHGameLoop.ACT_INS_DECLINE)
		CHGameLoop.PHASE_PRESPLIT:
			var avail: Array[String] = _loop.available_actions()
			if k.keycode == KEY_S and avail.has(CHGameLoop.ACT_SPLIT):
				_on_action(CHGameLoop.ACT_SPLIT)
			elif k.keycode == KEY_P and avail.has(CHGameLoop.ACT_PLAY):
				_on_action(CHGameLoop.ACT_PLAY)
		CHGameLoop.PHASE_HAND:
			var avail: Array[String] = _loop.available_actions()
			if k.keycode == KEY_H and avail.has(CHGameLoop.ACT_HIT):
				_on_action(CHGameLoop.ACT_HIT)
			elif k.keycode == KEY_S and avail.has(CHGameLoop.ACT_STAND):
				_on_action(CHGameLoop.ACT_STAND)
			elif k.keycode == KEY_D and avail.has(CHGameLoop.ACT_DOUBLE):
				_on_action(CHGameLoop.ACT_DOUBLE)
			elif k.keycode == KEY_R and avail.has(CHGameLoop.ACT_SURRENDER):
				_on_action(CHGameLoop.ACT_SURRENDER)


# --- Rendering ---

func _refresh_all() -> void:
	_refresh_hud()
	_refresh_cards()
	_refresh_actions()


func _refresh_hud() -> void:
	_bankroll_label.text = "Bankroll: %d" % _state.current_bankroll
	_discipline_label.text = "Discipline: %.0f" % _discipline.discipline
	# Decision grading is a T2+ feature; on the Tier-1 counting drill no
	# decisions are graded, so the readout stays hidden to keep the on-ramp
	# HUD limited to what the player is actually doing (tracking the count).
	_discipline_label.visible = _loop.config.grade_decisions
	_tier_label.text = "Tier: %d" % _state.current_tier
	_mode_label.text = "Mode: %s" % _state.session_mode
	var stage: int = _loop.tutorial_stage()
	if stage > 0:
		_tutorial_stage_label.text = _tutorial_stage_text(stage)
		_tutorial_stage_label.visible = true
		_maybe_announce_tutorial_stage(stage)
	else:
		_tutorial_stage_label.visible = false
		_last_tutorial_stage = 0
	_skill_label.text = _skill_label_text()
	_cover_label.text = "Cover: %d left" % _loop.cover_plays_left()
	# Cover is only usable once the table leaves the count-only teaching drill
	# (its toggle is hidden there), so the readout follows the same gate rather
	# than printing an orphaned "Cover: 3 left" on the counting drill.
	_cover_label.visible = not _loop.config.count_only
	_tilt_label.text = "Tilt: loss-chasing detected" if _loop.is_tilted() else ""
	_tilt_label.visible = _loop.is_tilted()
	# Count display. The count *system* shows (which system to count with); on a
	# continuous-shuffle table the count has no edge, so it reads as inert. The
	# numeric RC/TC/decks only show when the tier's count display is on (training
	# wheels); when off, the player must track the count themselves.
	var count: CHCountEngine = _loop.get_count()
	if _loop.config.continuous_shuffle:
		_count_system_label.text = "Count: — (shuffled, no edge)"
	else:
		_count_system_label.text = "Count: %s" % count.count_system
	_count_system_label.visible = true
	if _loop.config.count_only:
		# Count-only teaching table: the player tracks the running count
		# themselves, so don't hand them the number. They report it at the
		# per-hand prompt; this just reminds them what to keep an eye on.
		_tc_label.text = "Running count: track it (report +N / -N)"
		_tc_label.visible = true
	elif _loop.config.show_count_display:
		var rc: int = count.running_count
		# Intrusive "misread": while fraying/insane the player sometimes reads the
		# count wrong. Purely visual — the stored count is untouched, and the next
		# refresh reverts it. Gated by misread_probability (0 while calm), so the
		# teaching tiers never flicker.
		var mp: float = _loop.get_mental_system().misread_probability()
		if mp > 0.0 and randf() < mp:
			rc += 1 if randf() < 0.5 else -1
		_tc_label.text = "TC: %d (RC %+d, %.2f decks)" % [
			_loop.current_tc(), rc, count.decks_remaining]
		_tc_label.visible = true
	else:
		_tc_label.text = ""
		_tc_label.visible = false
	# Heat (suspicion) only shows when the table's heat system is active AND can
	# actually build: on the count-only teaching drill every tell is gated off
	# (the player never bets or deviates), so heat stays at the floor forever and
	# a live "Heat: 0%" meter would be noise — hide the readout there too.
	# "flagged" covers both the pending backoff latch (between hands) and the
	# lay-low hand itself: begin_hand clears the latch when it resets heat, so on
	# the backoff hand the pending indicator alone would make "BACKED OFF" vanish
	# — is_backoff_hand() keeps the pit's attention legible for that whole hand.
	if _loop.config.heat_active and not _loop.config.count_only:
		var pending: bool = _loop.needs_backoff()
		var laying_low: bool = _loop.is_backoff_hand()
		var flagged: bool = pending or laying_low
		var hp: float = _loop.heat_percent()
		var suffix: String = " — BACKED OFF" if pending else (" — LAY LOW" if laying_low else "")
		_heat_label.text = "Heat: %d%%%s" % [int(roundf(hp * 100.0)), suffix]
		var hc: Color = _heat_color(hp, flagged)
		if hc != Color(1, 1, 1):
			_heat_label.add_theme_color_override("font_color", hc)
		else:
			_heat_label.remove_theme_color_override("font_color")
		_heat_label.visible = true
	else:
		_heat_label.text = ""
		_heat_label.visible = false
	# Count accuracy (M16) only shows when the tier runs count checks.
	if _loop.config.count_check_active:
		var acc: CHCountAccuracySystem = _loop.get_count_accuracy()
		_count_acc_label.text = "Count acc: %.0f%% (%d)" % [acc.accuracy, acc.checks]
		_count_acc_label.visible = true
	else:
		_count_acc_label.text = ""
		_count_acc_label.visible = false
	# Decision accuracy (M30): how often the player matched the optimal play this
	# session. Recorded unconditionally (independent of grade_decisions), so the
	# teaching table shows it even with scoring off. Hidden until a decision is
	# made, so a fresh sit doesn't read "0 / 0".
	# Count-only teaching table: the player made no play decisions (the engine
	# auto-played), so the "Decisions: M/N" read-out would be a misleading
	# self-grade. Hide it there; keep it on every real table.
	if not _loop.config.count_only and _discipline.session_decisions > 0:
		_decision_acc_label.text = "Decisions: %d/%d" % [
			_discipline.session_optimal, _discipline.session_decisions]
		_decision_acc_label.visible = true
	else:
		_decision_acc_label.text = ""
		_decision_acc_label.visible = false
	_refresh_run_label()
	# Opponent (Sal) P&L readout — shown whenever the table seats a named rival.
	var opp: CHOpponent = _loop.get_opponent()
	if opp != null:
		if _opponent_busted:
			_opponent_label.text = "%s: busted" % opp.name
			_opponent_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
		else:
			_opponent_label.text = opp.summary()
			_opponent_label.remove_theme_color_override("font_color")
		_opponent_label.visible = true
	else:
		_opponent_label.text = ""
		_opponent_label.visible = false


# Live mistake-run tag (leading indicator of the composure spiral). The stability
# band is hidden (no meter); this is the *early* cue that a spiral is building,
# shown only while a run is in progress (resets to 0 on the next correct play).
# It is driven from mental_changed (which fires *after* the streak mutates) as
# well as _refresh_hud, so a bet-driven lapse updates the tag immediately rather
# than waiting for the next unrelated refresh.
func _refresh_run_label() -> void:
	var run: int = _loop.mental_mistake_streak()
	if run > 0:
		_run_label.text = "Run: ×%d" % run
		_run_label.add_theme_color_override("font_color", Color(0.95, 0.6, 0.3))
		_run_label.visible = true
	else:
		_run_label.text = ""
		_run_label.remove_theme_color_override("font_color")
		_run_label.visible = false


# Heat severity colour. Pure so it is testable without a live loop. White
# sentinel means "no override, use the default label colour". Backoff wins:
# a latched backoff reads hot regardless of the decayed percentage.
func _heat_color(hp: float, backed_off: bool) -> Color:
	if backed_off:
		return Color(0.9, 0.2, 0.2)
	if hp >= 0.75:
		return Color(0.85, 0.45, 0.2)
	if hp >= 0.5:
		return Color(0.95, 0.75, 0.2)
	return Color(1, 1, 1)


# Skill rating is the persistent tier-unlock currency (EMA of the process score,
# never bankroll). Showing it live lets the player see how close they are to the
# next tier without waiting for the session-end debrief.
func _skill_label_text() -> String:
	var r: float = _state.get_skill_rating()
	var h: int = _state.highest_unlocked_tier()
	if h >= CHGameState.TIER_SKILL_THRESHOLDS.size():
		return "Skill: %.1f (max tier)" % r
	# Next tier up is h+1; its threshold is at index h (tier n -> index n-1).
	var next_thr: float = CHGameState.TIER_SKILL_THRESHOLDS[h]
	return "Skill: %.1f (T%d at %.0f)" % [r, h + 1, next_thr]


# The hands to render right now. Terminal hands always show; in the presplit
# phase the current root awaiting its split decision is appended, so on a
# multi-spot table (tier 4+) earlier already-resolved splits stay visible while
# the player decides the next root. Single-spot presplit is unchanged
# (all_hands() is empty, so only the current root shows).
func _hands_to_render() -> Array[CHHand]:
	var hands: Array[CHHand] = _loop.all_hands().duplicate()
	match _loop.phase():
		CHGameLoop.PHASE_INSURANCE:
			# Opening cards are face up when the insurance decision is made, so
			# the player sees their own hand (terminal hands are not built yet).
			hands.append_array(_loop.opening_roots())
		CHGameLoop.PHASE_PRESPLIT:
			var pre: CHHand = _loop.current_hand()
			if pre != null:
				hands.append(pre)
	return hands


func _refresh_cards() -> void:
	# Player hand rows: free every HBox row except the persistent dealer row.
	for c in _player_area.get_children():
		if c is HBoxContainer and c != _dealer_row:
			c.queue_free()

	# Dealer: upcard always; hole + drawn cards only once the hole is revealed.
	# Before reveal the dealer reads as two cards (upcard + face-down back);
	# after reveal the whole hand renders, so the player can count the cards the
	# dealer drew (they feed the running count even though the dealer's total
	# is not shown until settle).
	for c in _dealer_cards.get_children():
		c.queue_free()
	var dhand: CHHand = _loop.dealer_hand()
	if dhand != null and not dhand.cards.is_empty():
		var revealed: bool = _loop.dealer_hole() != null
		for i in dhand.cards.size():
			if revealed or i == 0:
				_dealer_cards.add_child(_card_label(dhand.cards[i]))
			else:
				_dealer_cards.add_child(_card_back())
		# Hole not yet revealed: the second card lives in _hole (not yet in
		# _dealer), so render an explicit face-down back for it.
		if not revealed:
			_dealer_cards.add_child(_card_back())
		# Once the dealer's hand is fully revealed (upcard + hole + any draws
		# all face-up), show the hand total next to the cards — the same readout
		# the player rows get — so the player can verify every card the dealer
		# played is actually rendered (the total must equal the sum of the
		# visible cards). Added to _dealer_cards so it is freed and rebuilt
		# with the cards each refresh rather than accumulating on _dealer_row.
		if revealed:
			_dealer_cards.add_child(_hand_total_label(dhand))

	# Player: the hands to show right now (see _hands_to_render). The hand the
	# player is acting on is marked so a split/multi-spot table never reads as a
	# wall of identical rows.
	var hands: Array[CHHand] = _hands_to_render()
	var active: int = _active_hand_index(hands)
	for i in hands.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var lbl := Label.new()
		var is_active: bool = i == active
		lbl.text = ("◀ Hand %d   " if is_active else "Hand %d   ") % (i + 1)
		lbl.add_theme_font_size_override("font_size", 16)
		if is_active:
			lbl.add_theme_color_override("font_color", Color(0.95, 0.85, 0.35))
		row.add_child(lbl)
		var h: CHHand = hands[i]
		for c in h.cards:
			row.add_child(_card_label(c))
		row.add_child(_hand_total_label(h))
		_player_area.add_child(row)

	# NPC players (higher-tier tables): render each NPC's hand as its own row so
	# the player sees the full visible card stream (their own cards + every NPC
	# seat + the dealer) and can practice counting all of it. Labels number the
	# seats (the trainee is seat 1); NPCs are auto-played so none is active.
	var npcs: Array[CHHand] = _loop.npc_hands()
	for i in npcs.size():
		var nrow := HBoxContainer.new()
		nrow.add_theme_constant_override("separation", 6)
		var nlbl := Label.new()
		nlbl.text = "Player %d   " % (i + 2)
		nlbl.add_theme_font_size_override("font_size", 16)
		nlbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		nrow.add_child(nlbl)
		var nh: CHHand = npcs[i]
		for c in nh.cards:
			nrow.add_child(_card_label(c))
		nrow.add_child(_hand_total_label(nh))
		_player_area.add_child(nrow)

	# Named opponent (Sal): distinct from filler NPCs, shown with name + bet.
	var opp: CHOpponent = _loop.get_opponent()
	if opp != null:
		var orow := HBoxContainer.new()
		orow.add_theme_constant_override("separation", 6)
		var oh: CHHand = _loop.opponent_hand()
		var olbl := Label.new()
		olbl.text = ("%s (%du)   " % [opp.name, _loop.opponent_bet()]) if oh != null else ("%s   " % opp.name)
		olbl.add_theme_font_size_override("font_size", 16)
		olbl.add_theme_color_override("font_color", Color(0.7, 0.5, 0.9))
		orow.add_child(olbl)
		if oh != null:
			for c in oh.cards:
				orow.add_child(_card_label(c))
			orow.add_child(_hand_total_label(oh))
		elif _opponent_busted:
			var busted_lbl := Label.new()
			busted_lbl.text = "BUSTED"
			busted_lbl.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
			busted_lbl.add_theme_font_size_override("font_size", 14)
			orow.add_child(busted_lbl)
		_player_area.add_child(orow)


# A small numeric readout of a player hand's total, placed after its cards.
# Red when the hand is bust so the player sees a blown hand at a glance. The
# player's own total is always known to them (unlike the dealer's), so it is
# shown for every rendered player hand — the core decision input alongside the
# dealer upcard.
func _hand_total_label(h: CHHand) -> Label:
	var total: int = h.total()
	var t := Label.new()
	t.text = str(total)
	t.add_theme_font_size_override("font_size", 16)
	if h.is_bust():
		t.add_theme_color_override("font_color", Color(0.9, 0.2, 0.2))
	elif total == 21:
		t.add_theme_color_override("font_color", Color(0.3, 0.85, 0.4))
	else:
		t.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	return t


# Index of the hand the player is currently acting on within a rendered hand
# list, or -1 when no hand is live. In presplit the active hand is the current
# root (the last rendered hand); in the hand phase it is the loop's current
# terminal hand. Objects compare by identity, so the match is exact.
func _active_hand_index(hands: Array[CHHand]) -> int:
	var phase: String = _loop.phase()
	if phase != CHGameLoop.PHASE_PRESPLIT and phase != CHGameLoop.PHASE_HAND:
		return -1
	var cur: CHHand = _loop.current_hand()
	if cur == null:
		return -1
	for i in hands.size():
		if hands[i] == cur:
			return i
	return -1


func _refresh_actions() -> void:
	var in_bet: bool = _loop.phase() == CHGameLoop.PHASE_BET
	var count_gate: bool = _loop.is_count_check_due()
	var bet_ready: bool = in_bet and not count_gate
	var stage: int = _loop.tutorial_stage()
	var count_only: bool = _loop.config.count_only
	# Count-only table: hide every decision control; only the deal button and
	# the count-check input are relevant.
	var show_bets: bool = in_bet and stage != 1 and not count_only
	var show_actions: bool = (not in_bet) and (stage == 0 or stage == 3) and not count_only
	for u in _bet_buttons.keys():
		var b: Button = _bet_buttons[u]
		b.visible = show_bets
		b.disabled = not bet_ready
	_cover_toggle.visible = show_bets
	_cover_toggle.disabled = not bet_ready
	var available: Array[String] = []
	if not in_bet:
		available = _loop.available_actions()
	for a in _action_buttons.keys():
		var b: Button = _action_buttons[a]
		var on: bool = show_actions and available.has(a)
		b.visible = on
		b.disabled = not on
	# Deal button: visible when idle; disabled while a count check is pending
	# (count-only mode) so the player must report the count before dealing.
	_deal_button.visible = _loop.is_idle() and (stage == 0 or stage == 3)
	_deal_button.disabled = not _state.is_session_active() or (count_only and count_gate)
	# Ground (composure recovery): shown between hands while a use remains and the
	# session is active. Gated to normal/stage-3 play (not the guided tutorial
	# flow) so it does not clutter the on-ramp. Available even on the count-only
	# teaching table — it is the player's only way to recover composure there.
	var g_on: bool = _loop.is_idle() and _loop.ground_uses_left() > 0 and _state.is_session_active() and (stage == 0 or stage == 3)
	_ground_button.visible = g_on
	_ground_button.disabled = not g_on
	# Composure is hidden (no meter), so the only cues the player has that they are
	# rattled are the intrusive thoughts + vignette. Make the recovery lever salient
	# when it is actually valuable: while fraying/insane the button warms and is
	# tagged "shaken" so it reads as a "use it now" prompt, not a corner button.
	var mental_band: String = _loop.mental_state()
	var shaken: bool = mental_band == CHMentalStateSystem.STATE_FRAYING or mental_band == CHMentalStateSystem.STATE_INSANE
	_ground_button.text = "Ground (G) · %d left%s" % [_loop.ground_uses_left(), " — shaken" if shaken else ""]
	if g_on and shaken:
		_ground_button.add_theme_color_override("font_color", Color(0.95, 0.6, 0.3))
	else:
		_ground_button.remove_theme_color_override("font_color")
	# The tutorial "Next" control, gated by the count check so a shoe-cut report
	# is always answered before the hand advances. Stage 1 shows it whenever a
	# step exists (idle = deal + auto-bet, BET = auto-bet, decision = auto-play);
	# stage 2 shows it whenever the player is not choosing a bet (idle = deal,
	# decision = auto-play) — the bet itself stays manual via the bet controls.
	var next_visible: bool = false
	if _state.is_session_active() and not count_gate:
		if stage == 1:
			next_visible = true
		elif stage == 2:
			next_visible = not in_bet
	_tutorial_next_button.visible = next_visible
	_tutorial_next_button.disabled = not next_visible
	_cash_out_button.visible = _state.is_session_active()
	_cash_out_button.disabled = not _state.is_session_active()


# Tutorial advance control (M116). One press takes exactly one step:
# idle -> begin hand (stage 1 also auto-bets), decision phase -> apply the
# optimal action for the current phase. Stages 3+ never reach here.
func _on_tutorial_next() -> void:
	var stage: int = _loop.tutorial_stage()
	# Only the guided stages (1-2) auto-advance; stage 3 and normal mode use the
	# manual controls. A pending count check always gates the next step.
	if stage < 1 or _loop.is_count_check_due():
		return
	# Step 1: start a hand if we are between hands.
	if _loop.is_idle():
		if not _loop.begin_hand():
			return
		# begin_hand may have cut the shoe; the player must report the running
		# count before the new hand is dealt, so stop here (Next is gated off).
		if _loop.is_count_check_due():
			_refresh_all()
			return
	# Step 2: commit the bet. Stage 1 auto-bets (dealing the opening cards); in
	# stage 2 the player already placed the bet, so Next is never pressed while
	# in the BET phase there.
	if _loop.phase() == CHGameLoop.PHASE_BET:
		if stage == 1:
			_loop.place_bet(_loop.optimal_bet_units())
		_refresh_all()
		return  # opening cards just dealt; the next press advances the play
	# Step 3: auto-play one optimal action (stages 1-2). Stage 3 drives its own
	# decisions through the action buttons, so it never reaches this path.
	var action: String = _loop.optimal_action()
	if action != "":
		_loop.apply_action(action)
	_refresh_all()


# Text for the tutorial stage indicator (M116). Shows the 1/3 progress marker
# (M117) so the player can see how many shoes remain in the on-ramp.
func _tutorial_stage_text(stage: int) -> String:
	match stage:
		1:
			return "Tutorial 1/3 — just count the cards. Press Next to deal; report your running count at each shoe cut."
		2:
			return "Tutorial 2/3 — place your bet on the true count, then Next plays the hand for you."
		3:
			return "Tutorial 3/3 — you're in full control. Bet and play every call yourself."
		_:
			return ""


# Transient banner text for a stage unlock (M117). The on-ramp's pivotal moments
# — the point where a mechanic is added — deserve an explicit announcement rather
# than a silently-changing label. The 1→2 unlock also quotes the player's
# running count accuracy (if any cuts have been graded) so they know how well
# they tracked before being asked to act on the count.
func _stage_transition_text(stage: int) -> String:
	match stage:
		2:
			var acc: CHCountAccuracySystem = _loop.get_count_accuracy()
			var note: String = ""
			if acc.checks > 0:
				note = " Your count so far: %.0f%% over %d cut%s." % [
					acc.accuracy, acc.checks, "" if acc.checks == 1 else "s"]
			return "Stage 2 unlocked — you now place your own bet. The engine still plays the hand.%s" % note
		3:
			return "Stage 3 unlocked — full control. You bet and play every call."
		_:
			return ""


# Fires the stage-unlock banner once per advance (M117). Called from _refresh_hud
# whenever the live stage is read; only acts when the stage has risen past the
# last announced one, so a repeated HUD refresh at the same stage is silent.
func _maybe_announce_tutorial_stage(stage: int) -> void:
	if stage <= _last_tutorial_stage:
		return
	if stage >= 2:
		_show_session_banner(_stage_transition_text(stage))
	_last_tutorial_stage = stage


# Builds a card-face control: white rounded panel with the rank in the top-left
# corner and a large centred suit symbol, colour-coded red/black by suit.
func _card_label(c: CHCard) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(44, 60)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.96, 0.96, 0.94)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.25, 0.25, 0.25)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 3
	sb.content_margin_right = 3
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	card.add_theme_stylebox_override("panel", sb)

	var body := Control.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_child(body)

	var color: Color = Color(0.82, 0.1, 0.1) if c.is_red() else Color(0.1, 0.1, 0.1)

	var rank_lbl := Label.new()
	rank_lbl.text = c.rank_text() + c.suit_symbol()
	rank_lbl.add_theme_color_override("font_color", color)
	rank_lbl.add_theme_font_size_override("font_size", 14)
	rank_lbl.set_anchors_preset(Control.PRESET_TOP_LEFT)
	rank_lbl.offset_left = 2
	rank_lbl.offset_top = 1
	body.add_child(rank_lbl)

	var suit_lbl := Label.new()
	suit_lbl.text = c.suit_symbol()
	suit_lbl.add_theme_color_override("font_color", color)
	suit_lbl.add_theme_font_size_override("font_size", 28)
	suit_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	suit_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	suit_lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.add_child(suit_lbl)

	return card


# Builds a face-down card back: same 44x60 footprint as a card face but with a
# dark patterned panel, used for the dealer's hidden hole card.
func _card_back() -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(44, 60)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.22, 0.34)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.6, 0.65, 0.75)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 3
	sb.content_margin_right = 3
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	card.add_theme_stylebox_override("panel", sb)

	var glyph := Label.new()
	glyph.text = "\u25C6"
	glyph.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9, 0.55))
	glyph.add_theme_font_size_override("font_size", 22)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_child(glyph)
	return card
