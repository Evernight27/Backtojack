class_name CHGameState
extends RefCounted
# Session / table-sit / shoe hierarchy plus the persistent progression save.
#
# Design constraints honoured (brief Sections 3-item-6 and 5):
#   - Bankroll is SESSION-scoped and always resets to the starting stake each
#     session. Hitting zero ends the session early (reason "bust") and is
#     handled IDENTICALLY to a normal end — no demotion mechanic, because
#     progression is skill-gated, not money-gated.
#   - The persistent tier-unlock currency is a skill rating (process-based,
#     derived from Discipline, never from bankroll), EMA-updated at session
#     end. This keeps "don't punish luck" intact.
#   - reputation_heat_floor is persistent per tier; a session's Heat starts at
#     that tier's floor so quitting is not a clean escape from suspicion.
#
# Pure RefCounted: no autoload/signal dependencies, so it is fully testable
# headless. CHGameLoop owns instances of these systems and wires its own
# signals to the UI (see scenes/Main.gd).

const SAVE_SCHEMA_VERSION: int = 1
const SESSION_START_BANKROLL: int = 100
# EMA smoothing factor for the persistent skill rating at session end.
const SKILL_EMA_ALPHA: float = 0.2
# Starting skill rating for a brand-new save. 0.0 means "no demonstrated skill
# yet" — only tier 1 is available. The rating climbs via EMA as the player
# completes sessions well, gradually unlocking higher tiers.
const DEFAULT_SKILL_RATING: float = 0.0
# Session-goal modes (brief item 6): the two load-bearing framings plus an
# easy survival variant.
const MODE_TARGET := "target"
const MODE_PRACTICE := "practice"
const MODE_SURVIVAL := "survival"
# A guided on-ramp: the player's first job is to track the running count while
# the hand plays itself; each subsequent shoe adds one more mechanic (betting,
# then strategy). See GameLoop.tutorial_stage().
const MODE_TUTORIAL := "tutorial"
# How many shoes a tutorial session spans (one per stage, see above).
const TUTORIAL_TOTAL_SHOES: int = 3
# Per-tier skill-rating unlock thresholds. Index 0 == tier 1 (always unlocked).
# Defensible defaults; needs playtest tuning (see DECISIONS.md).
const TIER_SKILL_THRESHOLDS: Array[float] = [0.0, 50.0, 60.0, 70.0, 80.0, 85.0, 90.0]
const DEFAULT_SAVE_PATH := "user://counting_house_save.json"

# --- Persistent save data ---
var save_schema_version: int = SAVE_SCHEMA_VERSION
var unlocked_tiers: Array[int] = [1]
var lifetime_stats: Dictionary = {}
# tier id (int) -> float. Persistent cross-session Heat floor.
var reputation_heat_floor: Dictionary = {}
var unlocked_systems: Array[String] = []
var cosmetic_unlocks: Array[String] = []
# Path the session-end save (end_session -> _save_default) writes to. Defaults
# to the user save; overridable in tests to force a failure and exercise the
# save-failure path without touching the real save.
var save_path: String = DEFAULT_SAVE_PATH
# Result of the most recent save() call. Callers ending a session read this to
# surface a failed persist (the only moment progression is written).
var last_save_ok: bool = true

# --- In-memory session state (never persisted mid-session) ---
var session_active: bool = false
var current_bankroll: int = SESSION_START_BANKROLL
var current_tier: int = 1
var session_mode: String = MODE_TARGET
var target_bankroll: int = 0
var hands_this_session: int = 0
var shoes_this_session: int = 0
var practice_shoes_required: int = 3
# Last session end reason (for the Debrief / meta UI).
var last_end_reason: String = ""


func _init() -> void:
	_reinit_lifetime()


func _reinit_lifetime() -> void:
	lifetime_stats = {"skill_rating": DEFAULT_SKILL_RATING, "hands_played": 0, "sessions_played": 0}


# --- Session lifecycle ---

# Starts a fresh session at the given tier. `mode` is one of MODE_TARGET /
# MODE_PRACTICE / MODE_SURVIVAL. In practice mode there are no economy stakes,
# so the bankroll is decorative and bankruptcy can never end the session.
func start_session(tier: int, mode: String, p_target_bankroll: int = 0, p_practice_shoes: int = 3) -> void:
	current_tier = tier
	session_mode = mode
	target_bankroll = p_target_bankroll
	practice_shoes_required = p_practice_shoes
	current_bankroll = SESSION_START_BANKROLL
	hands_this_session = 0
	shoes_this_session = 0
	session_active = true
	last_end_reason = ""


func is_session_active() -> bool:
	return session_active


# Applies a finished hand's net P&L (in units) to the session bankroll and
# advances the hand counter. Returns true if the session just ended as a result
# (bankruptcy or target reached). Practice and tutorial are no-stakes: the
# bankroll is decorative so a bad run can never end the learning session early.
func apply_hand_result(net_pnl: int, session_process_score: float = 0.0) -> bool:
	if not session_active:
		return false
	hands_this_session += 1
	if session_mode != MODE_PRACTICE and session_mode != MODE_TUTORIAL:
		current_bankroll += net_pnl
		if current_bankroll <= 0:
			end_session("bust", session_process_score)
			return true
		if target_bankroll > 0 and current_bankroll >= target_bankroll:
			end_session("target_reached", session_process_score)
			return true
	return false


# Advances the shoe counter and checks the survival / practice completion
# conditions. `session_process_score` is the session's process metric (typically
# the Discipline meter's value) used for the skill-rating EMA.
func on_shoe_finished(session_process_score: float) -> bool:
	if not session_active:
		return false
	shoes_this_session += 1
	if session_mode == MODE_SURVIVAL and shoes_this_session >= practice_shoes_required:
		end_session("survival_complete", session_process_score)
		return true
	if session_mode == MODE_PRACTICE and shoes_this_session >= practice_shoes_required:
		end_session("practice_complete", session_process_score)
		return true
	if session_mode == MODE_TUTORIAL and shoes_this_session >= TUTORIAL_TOTAL_SHOES:
		end_session("tutorial_complete", session_process_score)
		return true
	return false


# Ends the session, updates the persistent save (skill-rating EMA, lifetime
# counters, tier unlocks), and writes the save file. `reason` is one of
# "cash_out" | "bust" | "target_reached" | "practice_complete" |
# "survival_complete". `session_process_score` (0-100) is the process-based
# metric that feeds the skill rating — deliberately NOT the bankroll.
# `persist` can be false in headless tests to avoid writing the user save.
func end_session(reason: String, session_process_score: float = 0.0, persist: bool = true) -> void:
	if not session_active:
		return
	# Skill rating is EMA-updated from the session's process score (Discipline),
	# never from bankroll. This is the persistent, bankable tier-unlock currency.
	var old_rating: float = float(lifetime_stats.get("skill_rating", DEFAULT_SKILL_RATING))
	var new_rating: float = old_rating * (1.0 - SKILL_EMA_ALPHA) + clampf(session_process_score, 0.0, 100.0) * SKILL_EMA_ALPHA
	lifetime_stats["skill_rating"] = new_rating
	lifetime_stats["hands_played"] = int(lifetime_stats.get("hands_played", 0)) + hands_this_session
	lifetime_stats["sessions_played"] = int(lifetime_stats.get("sessions_played", 0)) + 1
	# Auto-unlock any tier whose threshold the new skill rating now meets.
	_unlock_qualified_tiers(new_rating)
	session_active = false
	last_end_reason = reason
	# Bankroll is session-scoped; it does not carry into the next session.
	current_bankroll = SESSION_START_BANKROLL
	if persist:
		_save_default()


func _save_default() -> void:
	save(save_path)


# --- Progression ---

func get_skill_rating() -> float:
	return float(lifetime_stats.get("skill_rating", DEFAULT_SKILL_RATING))


func is_tier_unlocked(tier: int) -> bool:
	if tier <= 1:
		return true
	# Beyond the ladder there is no such tier; _tier_threshold() would return
	# 0.0 out-of-range and make every rating "unlocked" for it.
	if tier > TIER_SKILL_THRESHOLDS.size():
		return false
	if _tier_list_contains(unlocked_tiers, tier):
		return true
	return get_skill_rating() >= _tier_threshold(tier)


func highest_unlocked_tier() -> int:
	var best := 1
	for t in unlocked_tiers:
		if t > best:
			best = t
	# Also account for threshold-qualified tiers not yet persisted.
	for i in range(TIER_SKILL_THRESHOLDS.size()):
		if get_skill_rating() >= TIER_SKILL_THRESHOLDS[i] and (i + 1) > best:
			best = i + 1
	return best


func _unlock_qualified_tiers(rating: float) -> void:
	for i in range(TIER_SKILL_THRESHOLDS.size()):
		var tier := i + 1
		if rating >= TIER_SKILL_THRESHOLDS[i] and not _tier_list_contains(unlocked_tiers, tier):
			unlocked_tiers.append(tier)


func _tier_threshold(tier: int) -> float:
	var idx := tier - 1
	if idx < 0 or idx >= TIER_SKILL_THRESHOLDS.size():
		return 0.0
	return TIER_SKILL_THRESHOLDS[idx]


# --- Heat floor (persistent per tier) ---

func get_heat_floor(tier: int) -> float:
	return float(reputation_heat_floor.get(tier, 0.0))


func set_heat_floor(tier: int, value: float) -> void:
	reputation_heat_floor[tier] = value


# --- Systems / cosmetics unlock (brief item 11) ---

func is_system_unlocked(system: String) -> bool:
	return _str_list_contains(unlocked_systems, system)


func unlock_system(system: String) -> void:
	if not _str_list_contains(unlocked_systems, system):
		unlocked_systems.append(system)


func is_cosmetic_unlocked(cosmetic: String) -> bool:
	return _str_list_contains(cosmetic_unlocks, cosmetic)


func unlock_cosmetic(cosmetic: String) -> void:
	if not _str_list_contains(cosmetic_unlocks, cosmetic):
		cosmetic_unlocks.append(cosmetic)


# --- Persistence (JSON) ---

func serialize() -> String:
	var data: Dictionary = {
		"save_schema_version": save_schema_version,
		"unlocked_tiers": unlocked_tiers.duplicate(),
		"lifetime_stats": lifetime_stats.duplicate(),
		"reputation_heat_floor": reputation_heat_floor.duplicate(),
		"unlocked_systems": unlocked_systems.duplicate(),
		"cosmetic_unlocks": cosmetic_unlocks.duplicate(),
	}
	return JSON.stringify(data)


func deserialize(json: String) -> bool:
	var parsed: Variant = JSON.parse_string(json)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = parsed
	var version: int = int(d.get("save_schema_version", SAVE_SCHEMA_VERSION))
	# Refuse saves written by a newer schema we cannot interpret; older saves
	# load forward-compatibly with defaults filling any missing fields.
	if version > SAVE_SCHEMA_VERSION:
		push_warning("CHGameState: refusing save of schema v%d (supports up to v%d)" % [version, SAVE_SCHEMA_VERSION])
		return false
	save_schema_version = version
	unlocked_tiers = _to_int_array(d.get("unlocked_tiers", [1]))
	var ls: Dictionary = d.get("lifetime_stats", {})
	lifetime_stats = {
		"skill_rating": float(ls.get("skill_rating", DEFAULT_SKILL_RATING)),
		"hands_played": int(ls.get("hands_played", 0)),
		"sessions_played": int(ls.get("sessions_played", 0)),
	}
	reputation_heat_floor = {}
	var rhf: Dictionary = d.get("reputation_heat_floor", {})
	for k in rhf.keys():
		reputation_heat_floor[int(k)] = float(rhf[k])
	unlocked_systems = _to_str_array(d.get("unlocked_systems", []))
	cosmetic_unlocks = _to_str_array(d.get("cosmetic_unlocks", []))
	return true


func save(path: String = DEFAULT_SAVE_PATH) -> bool:
	# Atomic write: serialize to a sibling .tmp file, then rename onto the
	# target. A crash mid-write leaves either the old or the complete new save,
	# never a truncated file. (M83)
	var abs_path: String = ProjectSettings.globalize_path(path)
	var tmp_path: String = abs_path + ".tmp"
	if FileAccess.file_exists(tmp_path):
		DirAccess.remove_absolute(tmp_path)
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_warning("CHGameState: cannot open save for write: %s (err=%d)" % [tmp_path, FileAccess.get_open_error()])
		last_save_ok = false
		return false
	f.store_string(serialize())
	f.flush()
	f.close()
	var err: Error = DirAccess.rename_absolute(tmp_path, abs_path)
	if err != OK:
		# Rename can fail (cross-volume, permissions); fall back to a full copy
		# of the completed temp file so the data still lands intact.
		err = DirAccess.copy_absolute(tmp_path, abs_path)
		if err == OK:
			DirAccess.remove_absolute(tmp_path)
	if err != OK:
		push_warning("CHGameState: could not move save into place: %s (err=%d)" % [abs_path, err])
		last_save_ok = false
		return false
	last_save_ok = true
	return true


func load_game(path: String = DEFAULT_SAVE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	return deserialize(text)


# --- helpers ---

static func _tier_list_contains(list: Array[int], tier: int) -> bool:
	for t in list:
		if t == tier:
			return true
	return false


static func _str_list_contains(list: Array[String], s: String) -> bool:
	for x in list:
		if x == s:
			return true
	return false


static func _to_int_array(v: Variant) -> Array[int]:
	var out: Array[int] = []
	if typeof(v) == TYPE_ARRAY:
		for x in (v as Array):
			out.append(int(x))
	return out


static func _to_str_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(v) == TYPE_ARRAY:
		for x in (v as Array):
			out.append(str(x))
	return out
