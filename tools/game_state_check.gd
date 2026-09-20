extends SceneTree
# Validates CHGameState invariants:
#   1. Skill-rating EMA is computed from the process score, not bankroll.
#   2. Bankruptcy ends the session early (reason "bust") and resets bankroll
#      to the starting stake — identical handling to a normal session end.
#   3. Practice mode has no economy stakes (negative P&L never ends it).
#   4. Target mode ends with "target_reached" when the bankroll goal is met.
#   5. Tier unlock is skill-gated, not money-gated.
#   6. reputation_heat_floor persists through a save/load round-trip.
#   7. Real file round-trip (save/load_game) + tier auto-unlock via end_session
#      EMA + cosmetic round-trip + malformed-JSON handling.
#   8. Lifetime counters: hands_played and sessions_played accumulate correctly
#      across sessions.
#   9. highest_unlocked_tier() correctly merges persisted unlocks with
#      threshold-qualified-but-not-yet-persisted tiers, and stays sticky when
#      the rating decays below a previously-unlocked threshold.
#   10. Schema-version guard: a save written by a newer schema version is
#      refused; the current version loads and is preserved; an older version
#      loads forward-compatibly with defaults filling missing fields.
#
# PASS == all checks succeed. Exit 0 on pass, 1 on any fail.

var _failures: Array[String] = []


func _init() -> void:
	_check_ema()
	_check_bust_resets_stake()
	_check_practice_no_economy()
	_check_target_reached()
	_check_tier_gating()
	_check_heat_floor_roundtrip()
	_check_save_load_file_roundtrip()
	_check_lifetime_counters()
	_check_highest_unlocked_tier()
	_check_schema_version_guard()
	_cleanup_save()

	if _failures.is_empty():
		print("game_state_check: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("FAIL  ", f)
		print("game_state_check: %d failure(s)" % _failures.size())
		quit(1)


# 1. EMA: manually set rating to 50, session score 100 -> 60, then score 0 -> 48.
func _check_ema() -> void:
	var gs := CHGameState.new()
	gs.lifetime_stats["skill_rating"] = 50.0
	gs.start_session(1, CHGameState.MODE_TARGET, 0)
	gs.end_session("cash_out", 100.0, false)
	var r1: float = gs.get_skill_rating()
	if absf(r1 - 60.0) > 0.001:
		_failures.append("EMA first: got %.4f expect 60.0" % r1)

	gs.start_session(1, CHGameState.MODE_TARGET, 0)
	gs.end_session("cash_out", 0.0, false)
	var r2: float = gs.get_skill_rating()
	if absf(r2 - 48.0) > 0.001:
		_failures.append("EMA second: got %.4f expect 48.0" % r2)

	if absf(r1 - 60.0) <= 0.001 and absf(r2 - 48.0) <= 0.001:
		print("PASS  skill-rating EMA: 50 -> 60 -> 48")


# 2. Bust: bankroll hits 0, session ends as "bust", bankroll resets to start.
func _check_bust_resets_stake() -> void:
	var gs := CHGameState.new()
	gs.start_session(1, CHGameState.MODE_TARGET, 0)
	var ended := false
	for i in range(101):
		ended = gs.apply_hand_result(-1)
		if not gs.is_session_active():
			break
	if gs.is_session_active():
		_failures.append("bust: session still active after 100 losses")
		return
	if gs.last_end_reason != "bust":
		_failures.append("bust: end reason was '%s', expected 'bust'" % gs.last_end_reason)
		return
	if gs.current_bankroll != CHGameState.SESSION_START_BANKROLL:
		_failures.append("bust: bankroll after end = %d, expected %d" % [gs.current_bankroll, CHGameState.SESSION_START_BANKROLL])
	else:
		print("PASS  bust ends session as 'bust', bankroll resets to starting stake")


# 3. Practice mode: negative P&L never ends the session via bankruptcy.
func _check_practice_no_economy() -> void:
	var gs := CHGameState.new()
	gs.start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	for i in range(200):
		gs.apply_hand_result(-10)
	if not gs.is_session_active():
		_failures.append("practice: session ended on negative P&L (reason=%s)" % gs.last_end_reason)
		return
	# Completes by surviving N shoes instead.
	var ended := gs.on_shoe_finished(80.0)
	if not ended:
		_failures.append("practice: first shoe did not complete the session")
		return
	if gs.last_end_reason != "practice_complete":
		_failures.append("practice: end reason was '%s', expected 'practice_complete'" % gs.last_end_reason)
		return
	print("PASS  practice mode: no economy stakes, ends on shoe completion")


# 4. Target mode: ends with "target_reached" when the bankroll goal is met.
func _check_target_reached() -> void:
	var gs := CHGameState.new()
	gs.start_session(2, CHGameState.MODE_TARGET, 130)
	if not gs.apply_hand_result(30):
		_failures.append("target: apply_hand_result did not end session at goal")
		return
	if gs.last_end_reason != "target_reached":
		_failures.append("target: end reason was '%s', expected 'target_reached'" % gs.last_end_reason)
		return
	if gs.is_session_active():
		_failures.append("target: session still active after reaching target")
		return
	print("PASS  target mode: ends 'target_reached' at goal")


# 5. Tier unlock is skill-gated, not money-gated.
func _check_tier_gating() -> void:
	var gs := CHGameState.new()
	# Fresh save: rating 0, tier 2 (threshold 50) must NOT be unlocked.
	if gs.is_tier_unlocked(2):
		_failures.append("gating: tier 2 unlocked at default rating 0 — should not be")
		return
	# Simulate a session that pushes rating to 60 (>= tier-3 threshold).
	gs.lifetime_stats["skill_rating"] = 60.0
	if not gs.is_tier_unlocked(3):
		_failures.append("gating: tier 3 not unlocked at rating 60 (threshold 60)")
		return
	if gs.is_tier_unlocked(4):
		_failures.append("gating: tier 4 unlocked at rating 60 (threshold 70) — should not be")
		return
	# Money alone must not unlock: fresh save (rating 0), win big, rating stays 0.
	var gs_money := CHGameState.new()
	gs_money.start_session(1, CHGameState.MODE_TARGET, 0)
	for i in range(50):
		if not gs_money.is_session_active():
			break
		gs_money.apply_hand_result(10)
	if gs_money.is_tier_unlocked(2):
		_failures.append("gating: tier 2 unlocked by bankroll alone — must be skill-gated")
	else:
		print("PASS  tier unlock is skill-gated, not money-gated")


# 6. Heat floor persists across a save/load round-trip.
func _check_heat_floor_roundtrip() -> void:
	var gs := CHGameState.new()
	gs.set_heat_floor(5, 0.42)
	gs.unlock_system("ko")
	var json := gs.serialize()
	var gs2 := CHGameState.new()
	if not gs2.deserialize(json):
		_failures.append("roundtrip: deserialize failed")
		return
	if absf(gs2.get_heat_floor(5) - 0.42) > 0.0001:
		_failures.append("roundtrip: heat floor tier 5 = %.4f, expected 0.42" % gs2.get_heat_floor(5))
		return
	if not gs2.is_system_unlocked("ko"):
		_failures.append("roundtrip: unlocked_systems lost 'ko'")
		return
	if gs2.get_skill_rating() != gs.get_skill_rating():
		_failures.append("roundtrip: skill rating mismatch")
		return
	print("PASS  save/load round-trip preserves heat floor, systems, skill rating")


# 7. Real file round-trip (save/load_game) + tier auto-unlock via end_session
# EMA + cosmetic round-trip + malformed-JSON handling. Unlike the in-memory
# round-trip above, this exercises the actual FileAccess write/read path that
# the game uses, and pins that _unlock_qualified_tiers() appends tiers as the
# EMA climbs past thresholds (a path no other check drives).
func _check_save_load_file_roundtrip() -> void:
	var p := ProjectSettings.globalize_path("user://counting_house_check_save.json")
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

	# Drive the skill rating up through real end_session EMA updates so tiers are
	# auto-unlocked by the engine (not hand-set). 6 sessions at process score 100:
	# rating -> 0,20,36,48.8,59.04,67.232,73.7856 (alpha 0.2).
	var gs := CHGameState.new()
	for i in range(6):
		gs.start_session(1, CHGameState.MODE_TARGET, 0)
		gs.end_session("cash_out", 100.0, false)
	var rating: float = gs.get_skill_rating()
	if absf(rating - 73.7856) > 0.01:
		_failures.append("save-file: rating after 6 sessions = %.4f, expected ~73.7856" % rating)
	# At ~73.8, tiers 2/3/4 (50/60/70) auto-unlock; tier 5 (80) must not.
	for t in [2, 3, 4]:
		if not gs.unlocked_tiers.has(t):
			_failures.append("save-file: tier %d not auto-unlocked at rating %.2f (tiers=%s)" % [t, rating, str(gs.unlocked_tiers)])
	if gs.is_tier_unlocked(5):
		_failures.append("save-file: tier 5 unlocked at rating %.2f — should not be" % rating)

	# Set extra persistent state, write to a REAL file, read back into a fresh
	# instance via load_game().
	gs.set_heat_floor(3, 0.33)
	gs.unlock_system("hi_lo")
	gs.unlock_cosmetic("theme_neon")
	if not gs.save(p):
		_failures.append("save-file: save() returned false")
		return
	if not FileAccess.file_exists(p):
		_failures.append("save-file: save() did not create the file")
		return
	var gs2 := CHGameState.new()
	if not gs2.load_game(p):
		_failures.append("save-file: load_game() returned false")
		return
	if absf(gs2.get_skill_rating() - rating) > 0.0001:
		_failures.append("save-file: skill rating mismatch after file round-trip (got %.4f expect %.4f)" % [gs2.get_skill_rating(), rating])
	if absf(gs2.get_heat_floor(3) - 0.33) > 0.0001:
		_failures.append("save-file: heat floor tier 3 lost in file round-trip, got %.4f" % gs2.get_heat_floor(3))
	if not gs2.is_system_unlocked("hi_lo"):
		_failures.append("save-file: unlocked_systems lost 'hi_lo'")
	if not gs2.is_cosmetic_unlocked("theme_neon"):
		_failures.append("save-file: cosmetic_unlocks lost 'theme_neon'")
	for t in [2, 3, 4]:
		if not gs2.unlocked_tiers.has(t):
			_failures.append("save-file: unlocked_tiers lost auto-unlocked tier %d after round-trip (tiers=%s)" % [t, str(gs2.unlocked_tiers)])
	# M80: last_save_ok tracks the result of the most recent save().
	if not gs.last_save_ok:
		_failures.append("save-file: last_save_ok should be true after successful save()")
	gs.save("user://no_such_dir_for_save_check/x.json")
	if gs.last_save_ok:
		_failures.append("save-file: last_save_ok should be false after failed save()")
	# M83: the write is atomic (tmp + rename). A successful save must leave no
	# .tmp residue behind the target.
	if FileAccess.file_exists(p + ".tmp"):
		_failures.append("atomic: .tmp residue left behind after successful save")
	# M83: a second save to the SAME path must atomically replace the first
	# (rename onto an existing file — the case that fails on Windows MoveFile),
	# and the replaced file must read back as the new state, not the old one.
	gs.set_heat_floor(3, 0.77)
	if not gs.save(p):
		_failures.append("atomic: second save to the same path returned false")
	else:
		var gs5 := CHGameState.new()
		if not gs5.load_game(p):
			_failures.append("atomic: load after second save failed")
		elif absf(gs5.get_heat_floor(3) - 0.77) > 0.0001:
			_failures.append("atomic: second save did not replace the first (heat floor %.4f, expected 0.77)" % gs5.get_heat_floor(3))
		if FileAccess.file_exists(p + ".tmp"):
			_failures.append("atomic: .tmp residue left behind after second save")
	# M83: a stale .tmp from an interrupted earlier save must be cleaned up by
	# the next save so it never accumulates.
	var stale := ProjectSettings.globalize_path("user://counting_house_stale_save.json")
	var stale_tmp := stale + ".tmp"
	if FileAccess.file_exists(stale_tmp):
		DirAccess.remove_absolute(stale_tmp)
	var sf := FileAccess.open(stale_tmp, FileAccess.WRITE)
	sf.store_string("{\"save_schema_version\":1}")
	sf.close()
	var gstale := CHGameState.new()
	gstale.set_heat_floor(1, 0.11)
	if not gstale.save(stale):
		_failures.append("atomic: save with a pre-existing stale .tmp returned false")
	elif not FileAccess.file_exists(stale):
		_failures.append("atomic: target missing after save with stale .tmp")
	elif FileAccess.file_exists(stale_tmp):
		_failures.append("atomic: stale .tmp not cleaned up by save()")
	# Clean up the stale-save artifacts.
	if FileAccess.file_exists(stale):
		DirAccess.remove_absolute(stale)
	if FileAccess.file_exists(stale_tmp):
		DirAccess.remove_absolute(stale_tmp)
	if _failures.is_empty():
		print("PASS  save/load file round-trip preserves rating, tiers, heat floor, systems, cosmetics")

	# Malformed JSON -> deserialize returns false (no crash, no partial state).
	var gs3 := CHGameState.new()
	if gs3.deserialize("this is not json {"):
		_failures.append("save-file: deserialize of malformed JSON should return false")
	# Empty object -> defaults applied, returns true.
	var gs4 := CHGameState.new()
	if not gs4.deserialize("{}"):
		_failures.append("save-file: deserialize of {} should return true (defaults)")
	elif gs4.get_skill_rating() != CHGameState.DEFAULT_SKILL_RATING or not gs4.unlocked_tiers.has(1):
		_failures.append("save-file: {} round-trip should default rating to 0 and tiers to [1]")
	else:
		print("PASS  deserialize: malformed -> false, {} -> defaults")


# 8. Lifetime counters accumulate across sessions: hands_played sums the
# hands played this session, sessions_played increments by 1 per end_session.
# These feed the Debrief readout; neither is verified by the EMA/gating checks.
func _check_lifetime_counters() -> void:
	var gs := CHGameState.new()
	var hs0: int = int(gs.lifetime_stats.get("hands_played", 0))
	var ss0: int = int(gs.lifetime_stats.get("sessions_played", 0))
	gs.start_session(1, CHGameState.MODE_PRACTICE, 0, 1)
	# Practice mode has no economy: apply_hand_result only counts hands, never
	# ends the session. 5 hands -> hands_this_session = 5.
	for i in range(5):
		gs.apply_hand_result(-1)
	if gs.hands_this_session != 5:
		_failures.append("lifetime: hands_this_session=%d, expected 5" % gs.hands_this_session)
		return
	gs.end_session("practice_complete", 0.0, false)
	var hs1: int = int(gs.lifetime_stats.get("hands_played", 0))
	var ss1: int = int(gs.lifetime_stats.get("sessions_played", 0))
	if hs1 == hs0 + 5 and ss1 == ss0 + 1:
		print("PASS  lifetime counters: hands_played +%d, sessions_played +%d after end_session" % [hs1 - hs0, ss1 - ss0])
	else:
		_failures.append("lifetime: hands_played %d->%d (want +%d), sessions_played %d->%d (want +1)" % [hs0, hs1, 5, ss0, ss1])


# 9. highest_unlocked_tier() correctly merges persisted unlocks with
# threshold-qualified-but-not-yet-persisted tiers.
func _check_highest_unlocked_tier() -> void:
	# Fresh: rating 0, only tier 1 unlocked -> 1
	var g := CHGameState.new()
	_expect_eq(g.highest_unlocked_tier(), 1, "fresh state -> tier 1")

	# Threshold-qualified but NOT persisted (unlocked_tiers still [1]).
	# Only the second loop (threshold scan) can produce the answer.
	g.lifetime_stats["skill_rating"] = 60.0
	_expect_eq(g.highest_unlocked_tier(), 3, "rating 60, unpersisted -> tier 3")

	# Just below tier-3 threshold (60.0): only tier 2 qualifies.
	g.lifetime_stats["skill_rating"] = 59.9
	_expect_eq(g.highest_unlocked_tier(), 2, "rating 59.9 -> tier 2 (just below 60)")

	# Exactly at tier-7 threshold (90.0).
	g.lifetime_stats["skill_rating"] = 90.0
	_expect_eq(g.highest_unlocked_tier(), 7, "rating 90 (== threshold) -> tier 7")

	# Above all thresholds.
	g.lifetime_stats["skill_rating"] = 95.0
	_expect_eq(g.highest_unlocked_tier(), 7, "rating 95 -> tier 7 (capped at max)")

	# Sticky: rating decays below a threshold, but persisted unlock remains.
	# Simulate: rating 90 -> end_session(0.0) -> 72.0, unlocks up to tier 4.
	# Then end_session(0.0) again -> 57.6 (below tier-4 threshold of 70).
	var g2 := CHGameState.new()
	g2.start_session(1, CHGameState.MODE_TARGET, 0)
	g2.lifetime_stats["skill_rating"] = 90.0
	g2.end_session("cash_out", 0.0, false)
	# After first end: rating = 90*0.8 = ~72.0, unlocked_tiers should include 4.
	_expect_close(g2.get_skill_rating(), 72.0, "sticky: rating after decay = 72.0")
	_expect(g2.unlocked_tiers.has(4), "sticky: tier 4 in unlocked_tiers after unlock")
	g2.start_session(1, CHGameState.MODE_TARGET, 0)
	g2.end_session("cash_out", 0.0, false)
	# After second end: rating = ~72*0.8 = ~57.6, below tier-4 threshold (70).
	_expect_close(g2.get_skill_rating(), 57.6, "sticky: rating after 2nd decay = 57.6")
	_expect(g2.unlocked_tiers.has(4), "sticky: tier 4 still in unlocked_tiers (never removed)")
	_expect_eq(g2.highest_unlocked_tier(), 4, "sticky: highest_unlocked_tier still 4 (persisted wins)")

	# Out-of-range tier (beyond the ladder) must not report as unlocked, even
	# at a max skill rating — _tier_threshold() returns 0.0 out-of-range.
	g.lifetime_stats["skill_rating"] = 100.0
	_expect(not g.is_tier_unlocked(CHGameState.TIER_SKILL_THRESHOLDS.size() + 1),
		"is_tier_unlocked out-of-range tier reports locked, got unlocked")


# 10. Schema-version guard: a save written by a newer schema version is refused;
# the current version loads and is preserved; an older version loads
# forward-compatibly with defaults filling missing fields.
func _check_schema_version_guard() -> void:
	var base := CHGameState.new()
	base.set_heat_floor(3, 0.5)
	var base_data: Dictionary = JSON.parse_string(base.serialize())

	# Future schema version -> refused; an unknown-newer save must not load.
	var future: Dictionary = base_data.duplicate()
	future["save_schema_version"] = CHGameState.SAVE_SCHEMA_VERSION + 1
	if CHGameState.new().deserialize(JSON.stringify(future)):
		_failures.append("schema-guard: save with a future schema version should be refused")

	# Current schema version -> accepted and the version is preserved.
	var cur: Dictionary = base_data.duplicate()
	cur["save_schema_version"] = CHGameState.SAVE_SCHEMA_VERSION
	var gs_cur := CHGameState.new()
	if not gs_cur.deserialize(JSON.stringify(cur)):
		_failures.append("schema-guard: current-schema save should load")
	elif gs_cur.save_schema_version != CHGameState.SAVE_SCHEMA_VERSION:
		_failures.append("schema-guard: current version not preserved (got %d)" % gs_cur.save_schema_version)
	elif absf(gs_cur.get_heat_floor(3) - 0.5) > 0.0001:
		_failures.append("schema-guard: current-schema save lost heat floor")
	else:
		print("PASS  schema guard: future version refused, current version preserved")

	# Older schema version -> loads forward-compatibly (defaults fill gaps).
	var older: Dictionary = base_data.duplicate()
	older["save_schema_version"] = 0
	var gs_old := CHGameState.new()
	if not gs_old.deserialize(JSON.stringify(older)):
		_failures.append("schema-guard: older-schema save should load forward-compatibly")
	elif absf(gs_old.get_heat_floor(3) - 0.5) > 0.0001:
		_failures.append("schema-guard: older-schema save lost heat floor")
	else:
		print("PASS  schema guard: older version loads forward-compatibly")


func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _expect_eq(a: Variant, b: Variant, msg: String) -> void:
	if a != b:
		_failures.append("%s: got %s, expected %s" % [msg, str(a), str(b)])


func _expect_close(a: float, b: float, msg: String) -> void:
	if absf(a - b) > 0.001:
		_failures.append("%s: got %.4f, expected %.4f" % [msg, a, b])


# Some checks end sessions through apply_hand_result / on_shoe_finished, which
# persist to the default user:// save. Remove that artifact so the tool leaves no
# residue in the user data directory.
func _cleanup_save() -> void:
	var p := ProjectSettings.globalize_path("user://counting_house_save.json")
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	var cp := ProjectSettings.globalize_path("user://counting_house_check_save.json")
	if FileAccess.file_exists(cp):
		DirAccess.remove_absolute(cp)
	# M83: atomic saves write a sibling .tmp before renaming; remove any residue.
	if FileAccess.file_exists(p + ".tmp"):
		DirAccess.remove_absolute(p + ".tmp")
	if FileAccess.file_exists(cp + ".tmp"):
		DirAccess.remove_absolute(cp + ".tmp")

