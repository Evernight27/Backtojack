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
var _tier_selector: OptionButton
var _mode_selector: OptionButton
var _shoes_spin: SpinBox
var _deal_button: Button
var _cash_out_button: Button
var _new_session_button: Button
# Session parameters the scene applies when it (re)starts a session.
var _mode: String = CHGameState.MODE_TARGET
var _shoes: int = 3
var _debrief_panel: PanelContainer
var _debrief_title: Label
var _debrief_lines: Array[Label] = []
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
var _skill_label: Label
var _count_check_panel: PanelContainer
var _count_check_title: Label
var _count_check_input: LineEdit
var _count_check_submit: Button
var _count_check_skip: Button
# Onboarding (M84): a full-rect help/intro overlay shown on first launch and
# reachable any time via the Help button / F1.
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
const THOUGHT_COOLDOWN_SEC := 8
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
	# First launch (no save file on disk): surface the intro so the player
	# learns the trainer's goals before the first hand.
	_maybe_show_intro()


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
		config.heat_active = false
		config.show_count_display = false
	_loop = CHGameLoop.new(config, _state, _discipline, -1)
	_state.start_session(tier, mode, target, shoes)
	_mode = mode
	_shoes = shoes
	_skill_before_session = _state.get_skill_rating()
	_unlocked_before_session = _state.highest_unlocked_tier()
	_session_net = 0.0
	_save_failed_this_session = false
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
	_loop.decision_graded.connect(func(_delta: float, _v: float): _refresh_hud())
	_loop.session_ended.connect(_on_session_ended)
	_loop.heat_backoff.connect(_on_heat_backoff)
	_loop.count_check_due.connect(_on_count_check_due)
	_loop.save_failed.connect(_on_save_failed)
	_loop.mental_band_changed.connect(_on_mental_band_changed)
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
			_tier_selector.add_item("Tier %d — %s" % [tier, CHTableConfig.for_tier(tier).name])
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
	# Accumulate the per-hand integer exactly the way the bankroll does
	# (apply_hand_result rounds each hand's net to an int). Rounding the raw
	# floats and summing them at the end would diverge from the real bankroll
	# after any half-unit hand (e.g. a 1u surrender nets -0.5 -> -1).
	_session_net += roundf(net)
	_refresh_all()
	# Session-end UI is driven by the loop's session_ended signal (covers every
	# end path: target/bust via this hand, and practice/survival via shoe
	# completion), so no duplicate handling here.
	var status_msg: String = "Hand settled: %+d" % int(roundf(net))
	# In the guided tutorial stages the player advances by pressing Next; nudge
	# them so they know the hand is done and they can continue.
	if _state.is_session_active() and _loop.tutorial_stage() in [1, 2]:
		status_msg += " — press Next to continue"
	_status_label.text = status_msg


func _on_session_ended() -> void:
	# Record that the player has trained on this tier's counting system so the
	# career screen can list which systems they've played (progression record,
	# not a selector — the tier still dictates the active system).
	_state.unlock_system(_loop.config.count_system)
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


# The loop's session-end save could not be written. Remember it so the
# session-end status (which fires immediately after) can warn the player.
func _on_save_failed() -> void:
	_save_failed_this_session = true


func _on_heat_backoff() -> void:
	# The player was flagged as backed off; heat resets to the tier floor and they
	# are re-seated. Surface a transient notice (overwritten by the next settle).
	_status_label.text = "Backed off — heat reset to the tier floor."
	_refresh_all()


# --- Count-check prompt (M16) ---

func _on_count_check_due(_rc: int) -> void:
	# A shoe just cut; ask the player for the running count they tracked.
	# In a tutorial, tag which stage this check belongs to so the debrief can
	# break counting accuracy down per stage. The shoe boundary has already
	# advanced shoes_this_session, so the stage that just ended is current-1.
	if _state.session_mode == CHGameState.MODE_TUTORIAL:
		_pending_count_check_stage = maxi(_loop.tutorial_stage() - 1, 1)
	_count_check_title.text = "Shoe cut — what's your running count? (Enter to submit)"
	_count_check_input.text = ""
	_count_check_input.placeholder_text = "running count (e.g. 4, -2)"
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
	var lines: Array[String] = [
		"Table:  Tier %d — %s" % [_state.current_tier, CHTableConfig.for_tier(_state.current_tier).name],
		"Hands:  %d    Shoes:  %d" % [_state.hands_this_session, _state.shoes_this_session],
		"Discipline:  %.0f / 100" % _discipline.discipline,
		"P&L:  %+.1f units  (%s)" % [_session_net, pnl_suffix],
		"Skill rating:  %.1f → %.1f" % [_skill_before_session, _state.get_skill_rating()],
		"Career:  %d hand%s over %d session%s" % [
			career_hands, "" if career_hands == 1 else "s",
			career_sessions, "" if career_sessions == 1 else "s"],
	]
	if _discipline.session_decisions > 0:
		lines.append("Decisions:  %d / %d optimal" % [
			_discipline.session_optimal, _discipline.session_decisions])
	var acc: CHCountAccuracySystem = _loop.get_count_accuracy()
	if _loop.config.count_check_active and acc.checks > 0:
		if _state.session_mode == CHGameState.MODE_TUTORIAL:
			# M120: break counting down per stage in the on-ramp debrief.
			var summary: String = _tutorial_counting_summary()
			lines.append(summary if summary != "" else "Counting:  %.0f / 100  (%d checks)" % [acc.accuracy, acc.checks])
		else:
			lines.append("Counting:  %.0f / 100  (%d check%s)" % [acc.accuracy, acc.checks, "" if acc.checks == 1 else "s"])
	if highest_now > _unlocked_before_session:
		lines.append("Unlocked:  Tier %d — %s" % [highest_now, CHTableConfig.for_tier(highest_now).name])
	else:
		lines.append("Highest unlocked tier:  %d" % highest_now)
	_debrief_title.text = "Session ended — %s" % _reason_text(reason)
	for i in _debrief_lines.size():
		_debrief_lines[i].text = lines[i] if i < lines.size() else ""
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
	# Note: the mental-stability layer (CHMentalStateSystem) is intentionally not
	# surfaced in the HUD. It is a hidden, process-consistency signal intended to
	# drive ambient effects (see mental_band_changed) rather than a visible meter.
	# Live count details (shown only when the tier's count display is on).
	_count_system_label = _hud_label(hud, "")
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
	_debrief_title = Label.new()
	_debrief_title.add_theme_font_size_override("font_size", 20)
	debrief_vbox.add_child(_debrief_title)
	# 9 lines: table, hands, discipline, P&L, skill, career, decisions
	# (optional), counting (optional), unlock.
	for i in 9:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 15)
		debrief_vbox.add_child(l)
		_debrief_lines.append(l)

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
# Sits just below the intrusive-thought label so the two never overlap. Hidden
# until a transition fires.
func _build_tutorial_banner() -> void:
	_tutorial_banner = Label.new()
	_tutorial_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tutorial_banner.add_theme_font_size_override("font_size", 18)
	_tutorial_banner.add_theme_color_override("font_color", Color(0.55, 0.82, 0.62))
	_tutorial_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	_tutorial_banner.add_theme_constant_override("shadow_offset_x", 1)
	_tutorial_banner.add_theme_constant_override("shadow_offset_y", 1)
	_tutorial_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_tutorial_banner.offset_top = 24
	_tutorial_banner.offset_bottom = 56
	_tutorial_banner.visible = false
	add_child(_tutorial_banner)


# Shows the stage banner with a fade-in / hold / fade-out. Instructional, so it
# holds longer than an ambient thought and never blocks input.
func _show_tutorial_banner(text: String) -> void:
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


# Fires when the hidden sanity band changes (M114). Surfaces an ambient
# intrusive thought when the band degrades; cooldown keeps it from spamming
# if the player flaps between fraying/strained. No player-facing meter.
func _on_mental_band_changed(_old_band: String, new_band: String) -> void:
	if new_band not in [CHMentalStateSystem.STATE_FRAYING, CHMentalStateSystem.STATE_INSANE]:
		return
	var now: int = Time.get_ticks_msec() / 1000
	if now - _last_thought_ts < THOUGHT_COOLDOWN_SEC:
		return
	_last_thought_ts = now
	_show_thought(THOUGHTS.pick_random())


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


# Human note on how close the rating is to the next tier unlock.
func _next_tier_note(_rating: float) -> String:
	var h: int = _state.highest_unlocked_tier()
	if h >= CHGameState.TIER_SKILL_THRESHOLDS.size():
		return "max tier reached"
	var next_thr: float = CHGameState.TIER_SKILL_THRESHOLDS[h]
	return "T%d unlocks at %.0f" % [h + 1, next_thr]


# Comma-joined list of unlocked tier numbers (e.g. "T1, T2, T3").
func _unlocked_tiers_text() -> String:
	var out: Array[String] = []
	for t in CHGameState.TIER_SKILL_THRESHOLDS.size():
		var tier := t + 1
		if _state.is_tier_unlocked(tier):
			out.append("T%d" % tier)
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
		"Progression: seven table tiers, from the Tier 1 teaching table up to the Tier 7 continuous-shuffle contrast. Tiers unlock with your skill rating (0-100), which is updated at every session end from your process — decision quality and running-count accuracy — never from bankroll. Luck cannot demote you.",
		"Modes: Target — reach the bankroll goal. Practice — play N shoes with no stakes. Survival — survive N shoes with real stakes on the table.",
		"Heat: the pit watches for counting tells (betting up on a hot count, taking insurance, count-based deviations). Heat builds on each tell, decays while you lay low, and at maximum you are backed off and re-seated — at that tier's heat floor, which persists across sessions.",
		"Cover: up to 3 bets per shoe can be declared as cover — a deliberate lay-low bet that is exempt from the discipline penalty.",
		"Count checks: at each shoe cut you report the running count you tracked. Accuracy here is graded and feeds your skill rating.",
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


# First launch (no save file on disk): show the intro so the player learns the
# trainer's goals before the first hand. Re-openable any time via Help/F1.
func _maybe_show_intro() -> void:
	if not FileAccess.file_exists(CHGameState.DEFAULT_SAVE_PATH):
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
	_refresh_all()


func _on_action(a: String) -> void:
	_loop.apply_action(a)
	_refresh_all()


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
			if k.keycode == KEY_SPACE or k.keycode == KEY_ENTER:
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
	if _loop.config.show_count_display:
		_tc_label.text = "TC: %d (RC %+d, %.2f decks)" % [
			_loop.current_tc(), count.running_count, count.decks_remaining]
		_tc_label.visible = true
	else:
		_tc_label.text = ""
		_tc_label.visible = false
	# Heat (suspicion) only shows when the table's heat system is active.
	if _loop.config.heat_active:
		var backoff: bool = _loop.needs_backoff()
		var hp: float = _loop.heat_percent()
		_heat_label.text = "Heat: %d%%%s" % [int(roundf(hp * 100.0)), " — BACKED OFF" if backoff else ""]
		var hc: Color = _heat_color(hp, backoff)
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
	if _discipline.session_decisions > 0:
		_decision_acc_label.text = "Decisions: %d/%d" % [
			_discipline.session_optimal, _discipline.session_decisions]
		_decision_acc_label.visible = true
	else:
		_decision_acc_label.text = ""
		_decision_acc_label.visible = false


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

	# Dealer: upcard always; hole only once revealed.
	for c in _dealer_cards.get_children():
		c.queue_free()
	var up: CHCard = _loop.dealer_upcard()
	if up != null:
		_dealer_cards.add_child(_card_label(up))
	var hole: CHCard = _loop.dealer_hole()
	if hole != null:
		_dealer_cards.add_child(_card_label(hole))
	elif up != null:
		# Hole not yet revealed (player still acting): show a face-down card
		# back so the dealer's hand reads as two cards, not a lone upcard.
		_dealer_cards.add_child(_card_back())

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
	# M16: a shoe-cut count check must be answered (or skipped) before the player
	# may place a bet — the forcing function that makes the check engaging.
	var count_gate: bool = _loop.is_count_check_due()
	var bet_ready: bool = in_bet and not count_gate
	# Tutorial (M116): stage 1 hides betting entirely (the engine auto-bets and
	# auto-plays, the player just counts); stage 2 keeps betting manual and
	# auto-plays the decisions; stage 3 is full manual play.
	var stage: int = _loop.tutorial_stage()
	# Stage 1 auto-bets (hide the bet controls); stages 0/2/3 bet manually.
	var show_bets: bool = in_bet and stage != 1
	# Stages 1-2 auto-play the strategy (hide the action controls); stages 0
	# (normal) and 3 (full manual) show them.
	var show_actions: bool = (not in_bet) and (stage == 0 or stage == 3)
	for u in _bet_buttons.keys():
		var b: Button = _bet_buttons[u]
		b.visible = show_bets
		b.disabled = not bet_ready
	_cover_toggle.visible = show_bets
	_cover_toggle.disabled = not bet_ready
	# Hand/insurance/split buttons: hidden during the BET phase and in the
	# guided tutorial stages. (Plain [] in a ternary is an untyped Array, which
	# fails the typed-array assignment at runtime — so build it in a branch.)
	var available: Array[String] = []
	if not in_bet:
		available = _loop.available_actions()
	for a in _action_buttons.keys():
		var b: Button = _action_buttons[a]
		var on: bool = show_actions and available.has(a)
		b.visible = on
		b.disabled = not on
	# Deal starts a hand in normal mode and stage 3 (full manual). In stages 1-2
	# the guided "Next" control deals instead, so the player has one advance
	# button throughout the on-ramp and the M118 "press Next" hint stays true.
	_deal_button.visible = _loop.is_idle() and (stage == 0 or stage == 3)
	_deal_button.disabled = not _state.is_session_active()
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
		_show_tutorial_banner(_stage_transition_text(stage))
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
