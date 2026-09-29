# Counting House — DECISIONS.md

Running log of design/reconstruction decisions, following the format in Section 6
of the brief. Newest entries at the bottom.

## 2026-09-06 / M0 — Foundation reconstructed from prose (blocking condition)

Found: The Section 2 source files (`godot-scripts/` containing `scripts/` +
`tools/`) were **not present anywhere on this machine**. A full recursive
search of `C:`, `D:`, `E:` found no `sim_validate.gd`, `CountEngine.gd`,
`DisciplineSystem.gd`, `TableConfig.gd`, or any other foundation file — only
unrelated projects (FallenShadows, Scarim, etc.). A Godot 4.7 binary exists
at `E:\` but no source.

Cause: The foundation was not transferred into this environment alongside the
brief.

Fix: Per the user's explicit authorization ("Build foundation from prose"), the
seven `CH*` classes and four `tools/*.gd` validation scripts were
re-implemented from the brief's Section 2 descriptions and Section 3 gap
notes, then re-validated against their own correctness checks.

Verified: All four tools pass headlessly:
- `spot_check.gd` — 12/12 strategy cells
- `discipline_check.gd` — recovery scaling, cover cap, outcome-independence
- `session_length_check.gd` — decision_log bounded, fully drained each shoe
- `sim_validate.gd` — house edge in band, count invariants hold

## 2026-09-06 / M0 — "pairs → hit" interpreted as "no split resolution"

Found: First `sim_validate` run with a literal `if pair: play = "hit"`
fallback produced a 3.4% house edge — far above the 0.905% baseline. Hitting a
10,10 (total 20) guarantees a bust, which alone destroys the edge.

Cause: The brief's phrase "falls back pairs to 'hit'" was initially read as
"hit every pair." But the stated baseline (0.905%) and the note that enabling
splits only *lowers* the edge by ~0.3–0.5% are inconsistent with
"hit every pair" (which is a ~3% policy). The correct reading is that the
*split action* is unavailable, so a pair is played as a normal hand by its
hard/soft total (10s still stand, 5s still double, etc.).

Fix: Added `CHStrategyEngine.best_play_no_split()` — plays a pair by its
hard/soft total with rule-diff and deviation layers still applied. The sim now
uses this. Result: 3.4% → ~0.9% (matches the baseline band).

Verified: `sim_validate.gd` now reports ~0.9–1.0% and PASSes.

## 2026-09-06 / M0 — Deterministic sim (seeded reshuffles)

Found: `sim_validate` was non-deterministic — consecutive runs reported
0.854%, 0.901%, 0.945%, 0.955%. A validation baseline must be reproducible.

Cause: `CHShoeManager.reshuffle()` with no seed argument calls
`_rng.randomize()`, so only the *first* shoe was seeded; every subsequent
reshuffle re-seeded from the system clock.

Fix: The sim now tracks a `reshuffle_count` and calls
`shoe.reshuffle(SEED + reshuffle_count * 7919)`, making every shoe
deterministic.

Verified: Two consecutive runs both report 1.009%
(net=-5511.5, wagered=546424.0). Deterministic.

## 2026-09-06 / M0 — blackjack_payout convention

Found: `CHTableConfig.blackjack_payout` was initialized to `2.0` with the
comment "3:2 == 2.0 (net 3 for 2)." That is arithmetically wrong: a 3:2 payout
on a 1-unit bet nets **1.5** units (3 profit per 2 staked). 6:5 nets 1.2.

Cause: Misread of the "net 3 for 2" phrasing — the multiplier is 3/2 = 1.5,
not 2.0.

Fix: `CHTableConfig.blackjack_payout` default set to `1.5` (3:2). The sim uses
this directly, so a wrong value would have skewed the measured edge.

Verified: `sim_validate.gd` measured edge is consistent (1.009%) with the
corrected payout.

## 2026-09-06 / M0 — Engine version note

Found: The project `project.godot` declares `config/features=PackedStringArray("4.7", ...)`.
A Godot 4.7 binary is available
(`E:\Godot_v4.7-stable_win64_console.exe`), and the validation suite runs against it.

Cause: The environment now ships a 4.7 binary matching the declared feature flag.

Fix: Running on 4.7. The foundation uses no 4.7-specific APIs (all
standard RefCounted / Resource / SceneTree / RandomNumberGenerator), and every
tool in the suite is validated against the 4.7 binary.

## 2026-09-06 / M0 — Autoloads + EventBus

Found: The `CH*` classes need thin un-prefixed autoload wrappers so the global
identifier doesn't collide with the `class_name` (Section 2/4).

Cause: Design requirement, not a bug.

Fix: Added `autoload/EventBus.gd` (signals only) and thin Node wrappers
`autoload/{CountEngine,StrategyEngine,DisciplineSystem,ShoeManager}.gd`. All
five registered in `project.godot` under `[autoload]` (EventBus first). The
headless `tools/*.gd` instantiate the `CH*` classes directly, so they do not
depend on the autoloads and run standalone.

Verified: Tools pass with the autoloads registered (no parse errors, no
collisions).

## 2026-09-06 / M0 — ShoeManager autoload caveat (forward flag)

Found: `ShoeManager` is per-table state. If a future feature needs two live
shoes (multi-table / lobby), a second instance would silently shadow the
autoload.

Cause: Design note from Section 4.

Fix: Noted here; not actioned yet. If multi-table play is added, revisit
whether `ShoeManager` should be an autoload at all.

## 2026-09-06 / M1 — CHGameState (session / progression / save)

Found: No session or progression layer existed. Section 3 item 6 requires a
`GameState` managing session-scoped bankroll, a persistent skill rating that
gates tier unlocks, a persistent per-tier `reputation_heat_floor`, and two
session-goal framings (bankroll target + practice).

Cause: Not yet built (M1 scope).

Fix: Added `CHGameState` (RefCounted, headlessly testable) + a `GameState`
autoload wrapper that forwards `session_started` / `session_ended` to the
EventBus. Design decisions:
- Bankroll is session-scoped, always resets to `SESSION_START_BANKROLL` (100).
  Hitting 0 ends the session as `"bust"` **identically** to a normal end — no
  demotion mechanic (progression is skill-gated, not money-gated; Section 5).
- The persistent tier-unlock currency is a **skill rating** EMA-updated from the
  session's *process* score (the Discipline meter), never from bankroll. This
  keeps "don't punish luck" intact.
- `reputation_heat_floor` is persistent per tier; a session's Heat starts at
  that tier's floor (Section 3 item 1).
- Three session modes: `target` (bankroll goal), `practice` (no economy stakes,
  complete N shoes), `survival` (survive N shoes).

Verified: `tools/game_state_check.gd` — 6/6 (EMA, bust-resets-stake, practice
no-economy, target-reached, skill-gated tier unlock, heat-floor save round-trip).

## 2026-09-06 / M1 — Default skill rating 0.0 (not 50.0)

Found: A default skill rating of 50.0 with a tier-2 unlock threshold of 50.0
meant `is_tier_unlocked(2)` was true for a brand-new save — a new player would
start with tier 2 already unlocked.

Cause: A "neutral 50" default conflicts with a 50 threshold under a `>=` gate.

Fix: `CHGameState.DEFAULT_SKILL_RATING = 0.0`. A new player demonstrates no
skill yet, so only tier 1 is available; the rating climbs via EMA toward 100 as
sessions are played well. Documented threshold defaults:
`[0.0, 50, 60, 70, 80, 90]` for tiers 1-6 (needs playtest tuning).

Verified: `game_state_check.gd` "gating" check — tier 2 not unlocked at rating 0;
tier 3 unlocked at rating 60; tier 4 not unlocked at rating 60; bankroll alone never
unlocks a tier.

## 2026-09-06 / M2 — CHSplitResolver: end-to-end split-hand resolution

Found: M0/M1 sim used `best_play_no_split` (pairs played as hard/soft totals),
yielding 1.009% house edge — well above the target ~0.5% for a 1-deck S17 3:2
table with splits enabled.

Cause: Split resolution was explicitly deferred from the foundation sim.

Fix:
- `CHSplitResolver` (RefCounted, `scripts/systems/SplitResolver.gd`) — pure
  structure-only resolver. Given a starting hand, upcard key, shoe, config, and
  engine, returns the list of terminal `CHHand` objects. Deals split follow-up
  cards from the supplied shoe. Handles: one-card-only aces, resplit cap
  (`max_split_hands`), no-resplit-of-aces. Does NOT make hit/stand/double
  decisions (those stay in `CHStrategyEngine.best_play_no_split`).
- `CHHand` gains `split_ace: bool` flag for the one-card-only rule.
- `sim_validate` now runs two phases: (A) no-split baseline (reproduces 1.009%),
  (B) split-enabled (measured 0.507%, band 0.30–0.85%).
- `tools/split_check.gd` — 6 structural assertions (aces one-card, resplit cap
  =2 and =4, tens not split, split disabled, non-pair passthrough). All pass.

Results (seed 20260906, 500k hands each):
- No-split baseline: 1.009% (unchanged, confirms regression-safe refactor).
- Split-enabled: 0.507% (net=-2835.0, wagered=559199.0).
- Wagered increased ~2.3% vs no-split, consistent with split doubles adding
  per-hand bets.

## 2026-09-06 / M1 — end_session persist flag (side-effect-free tests)

Found: `CHGameState.end_session()` always wrote the save file. A headless
validation tool that exercises session endings would therefore overwrite the
user's `user://` save with test state.

Cause: No way to end a session without persisting.

Fix: Added `persist: bool = true` to `end_session()`. Production callers use the
default (true); tests pass `false` for direct `end_session` calls. The
`game_state_check` tool additionally removes the save artifact at the end
(`_cleanup_save()`) because some checks end sessions via `apply_hand_result` /
`on_shoe_finished`, whose internal `end_session` uses the default.

Verified: `game_state_check.gd` leaves no `counting_house_save.json` residue;
all 6 checks pass.

## 2026-09-06 / M3 — Full Illustrious 18 deviations

Found: The strategy engine had only 6 of the 18 deviations, and 2 of those 6
(#4 "Hit 13 vs 10 at TC ≤ -1" and #5 "Hit 14 vs 10 at TC ≤ -2") were no-ops:
the basic strategy already says "hit" for 13/14 vs 10, so the "deviation" never
changed the play. The sim was unaffected (tc=0 in the baseline), but the
deviations were inert in any counting scenario.

Cause: The M0 reconstruction used a partial list and the direction of the
13/14 vs 10 deviations was inverted (should be "stand at high TC," not "hit at
low TC," since basic already says hit).

Fix:
- Removed the two no-op constants (`DEV_13V10_HIT_TC`, `DEV_14V10_HIT_TC`).
- Added the correct high-TC stands: `DEV_13V10_STAND_TC = 3`, `DEV_14V10_STAND_TC = 3`.
- Added 12 new deviations to complete the full 18:
  - High-TC stands (hard 13-16 vs 9-10): 16v9, 14v9, 13v9.
  - Low-TC hits (hard 12-14 vs 4-6): 12v4, 13v4, 14v4, 12v5, 13v5, 14v5, 12v6.
  - Low-TC stand-instead-of-double: 11v10 (retained from original 6).
  - Soft 19 vs 9 and 10 at high TC: stand instead of hit.
- Rewrote `_apply_deviation` with clear high-TC / low-TC sections.
- Updated `spot_check.gd`: 12 basic cells + 13 I18 deviation cells = 25 total.
  Each deviation is tested at its trigger TC and one below (to confirm it does
  not fire below threshold).

Verified:
- `spot_check`: 26/26 (12 basic + 12 deviation + 2 legality cells, all passing).
- `sim_validate`: no-split 1.009% (unchanged), split 0.507% (unchanged). The
  I18 changes do not affect the sim because the sim uses tc_floor=0, which is
  below every positive threshold and above every negative threshold.
- All other tools: no regression.

## 2026-09-06 / M3 — Engine hardening: double-legality + surrender priority

Found: Two latent correctness bugs surfaced during a full review pass:
1. `_hard_play`/`_soft_play` could return "double" for hands with 3+ cards
   (e.g. hit to 11). Only the sim guarded on `card_count()==2`; a future game
   loop would need to re-derive that guard.
2. A high-TC deviation (e.g. stand 16 vs 10 at TC≥3) could override
   "surrender" emitted by `_apply_surrender`, which is never correct —
   surrender is always the better choice when the dealer shows 9-10 on a 16.

Cause: Defensive invariants lived at the call site instead of the engine.

Fix:
- Added `CHStrategyEngine._enforce_double_legality(play, hand, config)`:
  degrades "double" to "hit" when the hand has more than 2 cards or the
  config disables doubling. Wired into both `best_play` and
  `best_play_no_split`.
- Added an early `if play == "surrender": return play` guard at the top of
  `_apply_deviation` so no deviation can ever cancel a surrender.

Verified: `spot_check` now includes 2 legality cells (3-card 11 → hit;
16v10 TC=3 with surrender enabled stays "surrender"). 26/26 pass.
`sim_validate` unchanged (no-split 1.009%, split 0.507%).

## 2026-09-06 / M4 — Counting simulation: prove the player advantage

Found: The two sim phases (no-split 1.009%, split 0.507%) only measured a
NON-counting player (tc_floor=0, flat 1-unit bet). The core thesis of a
card-counting trainer — that maintaining the count, sizing bets by true count,
and applying I18 deviations at the live count yields a *player* advantage — was
unvalidated.

Cause: The sim had no running-count loop, no bet ramp, and passed tc_floor=0
to every engine call (so no deviation ever fired).

Fix:
- `sim_validate._play_hand` now takes `tc_floor: int = 0` and
  `count: CHCountEngine = null`. When `count` is supplied: the bet is sized by
  a 4-step ramp (`_bet_for_tc`: TC≤-1→1, 0..1→2, 2..3→4, ≥4→6); all reveals route
  through `_reveal(card, count)` which calls `count.record_card(card)` (the
  `seen` guard makes double-counting impossible); the resolver and per-hand play
  receive the live `tc_floor` so I18 deviations fire at the real count. When
  `count == null` the path is byte-identical to the M0/M1 reconstruction
  (bet=1, seen-only, tc=0) — the two baselines are preserved.
- Added `_run_counting_simulation`: maintains a Hi-Lo running count across the
  shoe, resets the count on each deterministic reshuffle, and passes
  `count.true_count_floor()` as the live TC.
- Phase D wired into `_init`; counting band `[-1.20%, -0.20%]` (negative ==
  player edge; the upper bound rejects "no longer an advantage", the lower bound
  catches an over-aggressive ramp or a double-count bug).

Deck-estimate choice (review finding): `shoe.decks_remaining_estimate()` is the
coarse **tier-1 player estimate** (`deck_estimation_rounding = 1.0`), which for a
single-deck table is pinned at 1.0 the whole shoe — so the "true count" would
collapse to the raw running count and ignore penetration. That measures a
handicapped tier-1 counter, not textbook counting. The sim now feeds
`shoe.remaining_decks_exact()` into `CHCountEngine`, giving the textbook
true count (running count / decks remaining) that a competent counter actually
uses. The coarse estimate remains the correct *gameplay* difficulty lever; it is
not the right model for a house-edge validation.

Results (seed 20260906, 500k hands):
- No-split: 1.009% (unchanged — regression-safe).
- Split: 0.507% (unchanged — regression-safe).
- Counting: **-0.429%** house edge (net=+5643.5, wagered=1314274.0) — a
  reproducible player advantage, ~0.9pp better than the non-counting split
  baseline. Wagered is ~2.4x the flat-bet phases, consistent with the bet ramp
  staking 2-6 units plus correctly-credited blackjack payouts.

Note: initial draft of this phase had `wagered` hardcoded to 1.0 in the BJ
early-return path, which understated the denominator by ~81k units. Fixed to
use `float(base_bet)` so the wagered total reflects actual staked units.

Verified: `sim_validate` PASSes all three phases; counting edge is deterministic
(identical across runs) and in-band.

Note: This sim does NOT stand down at very negative counts (a real counter
would). Standing down would widen the player edge further; it is deferred as a
refinement because it changes hand-count semantics.

## M5 — Insurance wiring (sim side)

When the dealer upcard is an Ace and the table allows insurance, the counter
takes the side bet iff the current true count >= `INSURANCE_TC_THRESHOLD`
(3), matching `StrategyEngine.should_take_insurance`. The side bet is
`maxi(1, int(base_bet / 2))` (half the base bet, rounded down, min 1 unit)
and pays 2:1 only on a dealer blackjack; otherwise it is lost.

- `sim_validate._play_hand`: decision block before the BJ early-return;
  BJ path adds `+2 * insurance_bet` when dealer BJs; non-BJ path deducts
  `insurance_bet` and adds it to `wagered` (stake is always wagered).
- `count_cfg.allows_insurance = true` in `_init` so the counting phase
  exercises the side bet; no-split/split baselines leave it off so they
  stay regression-safe.
- `insurance_check.gd`: 5 structural tests (threshold take/decline,
  2:1 payout on BJ, loss on no-BJ, no offer on non-Ace upcard, disabled
  config). All PASS.

Results (seed 20260906, 500k hands, deterministic):
- No-split: 1.009% (unchanged).
- Split: 0.507% (unchanged).
- Counting (insurance on): **-0.561%** house edge (net=+7492.5,
  wagered=1336506.0) — improved from -0.429% pre-insurance, confirming
  taking insurance at high true count is +EV under the 4-step bet ramp.

Note: GDScript does not parse the `div` operator as a direct
function-call argument (`maxi(1, base_bet div 2)` -> parse error).
Use `maxi(1, int(base_bet / 2))` instead.

## M6 — Interactive game loop + playable scene

Found: No interactive play path existed. All prior work was headless validation
tools; there was no scene, no UI, and no way to actually sit at the table and
make decisions.

Cause: M0–M5 focused on the engine, sim, and validation. The interactive loop
was the next missing layer.

Fix:
- `CHGameLoop` (`scripts/systems/GameLoop.gd`, RefCounted, headlessly testable)
  — owns one session's table state. Phases: IDLE → INSURANCE → PRESPLIT →
  HAND → SETTLED. Exposes `phase()`, `available_actions()`, `optimal_action()`,
  `apply_action()`, `begin_hand()`, and card/hand accessors. Emits local signals
  (`phase_changed`, `card_dealt`, `decision_graded`, `hand_settled`,
  `shoe_reshuffled`) for UI binding.
- Split model: when the player chooses "split", the full split structure is
  expanded up front via CHSplitResolver (same as the sim). Re-splits follow the
  engine's optimal structure rather than further player prompts. Documented
  simplification.
- `SHOE_RESERVE = 20`: reshuffle threshold mirrors sim_validate to prevent
  mid-hand shoe exhaustion.
- `scenes/Main.gd` + `scenes/Main.tscn`: Control-based UI (HUD labels for
  bankroll/TC/discipline/tier/mode, card display, context-sensitive action
  buttons, deal/new-session buttons). UI is presentation-only; all game logic
  lives in CHGameLoop.
- `project.godot`: `run/main_scene` set to `res://scenes/Main.tscn`.
- `tools/game_loop_check.gd` — 4 structural checks: determinism (identical net
  sequence across two runs), bankroll consistency (bankroll tracks sum of
  per-hand nets; bust resets to start value), card conservation (every dealt
  card counted exactly once), and suboptimal-play penalty (forced "hit" drops
  Discipline below 100). All PASS.

Key bug found and fixed during development:
`_advance_to_next_hand()` was called when *starting* the first hand (from
`_after_insurance` and `_apply_presplit`), which incremented `_idx` past the
first hand and skipped directly to the dealer/settle phase. The hand was never
played. Fixed by adding `_start_hand_play()` which begins at index 0, while
`_advance_to_next_hand()` retains the `+1` increment for post-hand progression.

Results:
- `game_loop_check`: ALL PASS (532 hands driven to bust, 4 invariants verified).
- `sim_validate`: unchanged (no-split 1.009%, split 0.507%, counting -0.561%).
- All 6 prior tools: no regression.

## M7 — Discipline surface wiring (bet grading, cover, tilt)

Found: The game loop only graded *decisions* (`grade_decision`). The full
discipline system also grades *bet sizing* (`grade_bet`), tracks cover-play
budget (`declare_cover_play`), and detects loss-chasing tilt (`check_tilt`) —
none of which were reachable from the interactive loop. A player could sit at
the table and never exercise the bet-sizing or tilt subsystems.

Cause: M6 built the hand-resolution loop; bet sizing was auto-computed from
the TC ramp with no player choice, and the discipline calls for bet/cover/tilt
were not yet wired into the loop's state machine.

Fix:
- **BET phase**: `begin_hand()` now enters `PHASE_BET` instead of dealing
  immediately. The player commits a bet via `place_bet(units, is_cover)` which
  calls `discipline.grade_bet(units, optimal, after_loss, is_cover)` and then
  deals the opening cards. The optimal (autopilot) bet is the 4-step TC ramp
  value via `optimal_bet_units()`. `MAX_BET_UNITS = 6` bounds the UI.
- **Cover**: `place_bet(u, is_cover=true)` calls
  `discipline.declare_cover_play()`; if granted, the bet is exempt from
  discipline penalty. `cover_plays_left()` accessor added to
  `CHDisciplineSystem` + `CHGameLoop` for the HUD indicator.
- **Tilt**: `is_tilted()` passthrough to `discipline.check_tilt()` — the
  scene can surface a tilt warning.
- **`Main.gd`**: BET-phase UI with 1u–6u bet buttons + "Cover" check-button;
  cover-remaining and tilt indicators in HUD/actions.

Results:
- `game_loop_check`: ALL PASS (532 hands, discipline pinned at 100 when
  playing optimally — bet grading adds no penalty for correct bets).
- `sim_validate`: unchanged (no-split 1.009%, split 0.507%, counting -0.561%).
- Scene smoke test: `begin_hand()` → BET → `place_bet(2)` → HAND → settle.
- All 8 tools pass with no regression.

## M8 — Heat system (suspicion + backoff)

Found: The model had a dormant heat concept (`GameState.get_heat_floor`,
`EventBus.heat_changed`/`backoff_triggered`) but no system to build, decay, or
react to heat. A counter who bet big on a high true count, took insurance, or
made counting deviations could do so indefinitely without consequence — the
single biggest missing feedback loop for a counting trainer.

Cause: No `CHHeatSystem` existed, and the loop never fed player actions to any
suspicion model. The floor-persistence hooks in `GameState` were unwired.

Fix:
- **`CHHeatSystem`** (`scripts/systems/HeatSystem.gd`), pure RefCounted model:
  heat starts at the tier's reputation floor (`reset(floor)`), builds from
  tells via `on_tell(gain_base * sensitivity)`, decays a fixed
  `DECAY_PER_HAND = 3` per settled hand via `on_hand()`, and latches
  `pending_backoff` once heat reaches `BACKOFF_THRESHOLD = 100`. `sensitivity`
  is the tier multiplier. Decay deliberately does NOT clear the backoff latch —
  cooling down is the player's explicit next step.
- **Tells** (base gains, scaled by sensitivity): `BET_TELL_GAIN = 6` (bet
  ≥ `BET_TELL_MIN_UNITS = 4` at `BET_TELL_TC = 2`+, non-cover),
  `INSURANCE_TELL_GAIN = 4` (taking/declining insurance at a high count),
  `DEV_TELL_GAIN = 2` (making an I18 counting deviation).
- **`CHStrategyEngine.is_counting_deviation(hand, dealer_key, config, tc_floor)`**:
  returns whether `_apply_deviation(_basic_play(...))` differs from
  `_basic_play(...)` — the exact I18 delta, false for pairs. This is what makes
  the deviation tell precise instead of heuristic.
- **`CHGameLoop` wiring**: owns a `CHHeatSystem`, applies
  `config.heat_sensitivity_multiplier`, resets to `state.get_heat_floor(tier)`
  on first hand. Big-bet tell in `place_bet`, insurance tell in
  `_apply_insurance`, deviation tell in `_apply_hand`, decay in `_finalize`
  (does not clear the latch). `begin_hand()` resolves a pending backoff: emits
  `heat_backoff` and re-seats heat at the floor. Accessors: `heat()`,
  `heat_percent()`, `needs_backoff()`, `get_heat_system()`.
- **Gate**: everything is gated by `config.heat_active` (default `false`), so
  every existing tool and the sim are unaffected until a table opts in.
- **`Main.gd`**: teaching table now sets `heat_active = true`; HUD shows a heat
  bar (`Heat: N%`, `— BACKED OFF` when latched), hidden when the table's heat
  is off.

Results:
- `heat_check` (new): ALL PASS — tell/decay math, sensitivity scaling, backoff
  latch + no-decay-clear, inactive gate, and loop-level backoff resolution.
- `sim_validate`: unchanged (no-split 1.009%, split 0.507%, counting -0.561%) —
  heat is off in the sim by default.
- Scene smoke: heat active, tells build heat, backoff accessor correct.
- All 9 tools pass with no regression.

Gotcha (GDScript): lambdas capture variables **by value**, so a
`func(): flag = true` closure does not mutate the outer `flag`. Use a
Dictionary (`var flag := {...}; func(): flag.k = true`) for a reference-passed
flag. Hit in `heat_check`'s signal-emit assertion.

## M9 — Table config: tier ladder, count-system selection, live count display

Found: `CHTableConfig` carried all the per-tier difficulty levers
(deck_count, penetration, deck_estimation_rounding, dealer_hits_soft_17,
surrender, insurance, heat, show_count_display, …) but nothing actually
*used* them per tier. The scene hard-coded one Tier-1 config in
`_default_config()` and ignored the tier argument. There was also no way to
train a different card-counting system — `CHGameLoop` pinned
`count.count_system = "hi_lo"` even though `CHCard.count_value` already
supported `ko` and `hi_opt_ii`. And the "true count" HUD always displayed, so
the `show_count_display` training-wheels toggle was dead.

Cause: No tier→config mapping existed, and the count-system / count-display
wiring was never connected from config into the loop and scene.

Fix:
- **`CHTableConfig.count_system`** field (default `"hi_lo"`) +
  **`CHTableConfig.for_tier(tier)`** static factory — the single source of
  truth for the 6-tier ladder:
  - **T1 Teaching**: 1 deck, S17, 3:2, split+insurance, heat on, count
    display on, `hi_lo`.
  - **T2 Single-Deck**: 1 deck, S17, switch to the **KO** count, grading on.
  - **T3 Two-Deck**: 2 decks, H17, insurance off, finer deck estimate
    (0.5), count display **off** (count it yourself), `hi_lo`.
  - **T4 Four-Deck Multi-Hand**: 4 decks, H17, late surrender, two hands,
    0.5 estimate, heat ×2.0.
  - **T5 Six-Deck Hi-Opt**: 6 decks, H17, late surrender, two hands, 0.25
    estimate, **Hi-Opt II** count, heat ×2.5.
  - **T6 Continuous Shuffle** (`_`): 8 decks, everything on, `continuous_
    shuffle=true` — the "counting stops helping" contrast tier.
  Values are starting defaults (like `TIER_SKILL_THRESHOLDS`), meant for
  playtest tuning.
- **`CHGameLoop`**: `count.count_system = config.count_system` (was pinned to
  `"hi_lo"`), so a tier's counting system is now live.
- **`Main.gd`**: `_start_session(tier)` now pulls `CHTableConfig.for_tier(tier)`
  (dead `_default_config()` removed); added a **tier selector** (OptionButton,
  lists unlocked tiers via `CHGameState.highest_unlocked_tier`, switches via
  the `item_selected` signal); **live count display** now honors
  `show_count_display` — the count *system* always shows ("Count: hi_lo"), the
  numeric `TC (RC, decks)` shows only when the tier's display is on.

Results:
- `tables_check` (new): ALL PASS — for_tier sanity (t=1..6), T1 reproduces the
  teaching-table / sim-relevant defaults, per-card count values for all three
  systems, full-deck nets (hi_lo=0, ko=+4, hi_opt_ii=-16), and loop wiring
  (a T5 loop picks up hi_opt_ii and a 312-card shoe, plays a hand to idle).
- `sim_validate`: unchanged (no-split 1.009%, split 0.507%, counting -0.561%)
  — the sim uses the default `CHTableConfig` + explicit `hi_lo`, untouched.
- Scene smoke: tier selector + count HUD build, T1 shows `TC: 0 (RC +0,
  1.00 decks)` with `Count: hi_lo`; RC updates as cards are recorded.
- All 10 tools pass with no regression.

Note (deferred): the *behavioral* effect of `continuous_shuffle` (disabling
the count-based edge / bet ramp) and multi-hand play (`player_hand_count > 1`)
are tier-configured but not yet enforced by the loop — those are future
milestones. The tiers are selectable and the rules/shoe/count are correct;
those two levers are dormant until wired.

Gotcha (GDScript): `OptionButton.select()` (programmatic) emits **neither**
`pressed` nor `item_selected` — only a real user click fires `item_selected`
(verified with a headless probe on 4.7). `_populate_tier_selector` uses
`select()` to pre-highlight the current tier in the dropdown *without*
triggering `_on_tier_selected`, so the pre-select is display-only; only a
user click switches tiers. Headless scene tests must call the handler
(`_on_tier_selected(index)`) directly to simulate a click.

## M10 — Session-end debrief + skill-rating wiring

Found: When a session ended (bust / target reached / practice complete) the
scene only set a status line. The whole "Debrief" concept from the brief —
show the player what just happened and how their skill rating moved — was
unwired. Worse, two latent bugs:
1. `CHGameLoop._finalize` called `state.apply_hand_result(int(roundf(net)))`
   with the default process score `0.0`, so the skill-rating EMA was ALWAYS
   pulled toward 0 — the persistent tier-unlock currency could only ever go
   down. The tier ladder was effectively unplayable.
2. `Main.gd` used `START_TARGET = 50` with `SESSION_START_BANKROLL = 100`, so
   a target-mode session ended on the first hand as "target_reached"
   (100 >= 50 already true... actually it triggers on the first `apply_
   hand_result` since `current_bankroll >= target_bankroll` is checked after
   adding P&L — but the goal is trivially met the moment any hand settles).

Cause: The session-end path (`end_session`, EMA, tier unlocks) was built in
M1 and tested headlessly, but never connected to a visible surface, and the
loop never forwarded the session's process metric.

Fix:
- **`CHGameLoop._finalize`**: `state.apply_hand_result(int(roundf(net)),
  discipline.discipline)` — the current Discipline meter is the process score
  that feeds the skill-rating EMA (matching the brief's "process-based, never
  from bankroll" rule). Safe: the score is only consumed on the terminal hand.
- **`Main.gd` debrief panel**: a `PanelContainer` with a title + 6 stat lines
  (table, hands/shoes, discipline, P&L/bankroll, skill-rating delta, tier
  unlock). Hidden until a session ends; `_on_hand_settled` accumulates
  `_session_net` and calls `_show_debrief(reason)` when the session closes.
- **Latent bug fixed**: `START_TARGET` 50 → 150 (must sit above the 100
  starting stake or target-mode is meaningless).

Results:
- Scene smoke: debrief panel builds (6 lines), hidden at session start, shown
  on session end with correct stats; skill-rating line shows a real delta
  (20.0 → 32.0 after a session with process score 80, EMA α=0.2:
  20·0.8 + 80·0.2 = 32).
- All 10 tools pass with no regression; `sim_validate` baselines unchanged
  (1.009% / 0.507% / -0.561%) — the loop change only affects the process score
  argument, which no sim/tool asserts on.

Remaining unwired layers after M10: none blocking. Deferred levers (documented
in M9): `continuous_shuffle` behavioral effect and multi-hand play
(`player_hand_count > 1`) are tier-configured but not yet loop-enforced.

## M11 — Continuous-shuffle (CSS) behavior: "counting stops helping"

Found: `CHTableConfig.continuous_shuffle` was a Tier-6 flag that nothing
honored. The loop still sized bets off the live count, applied I18 deviations,
and took count-based insurance — exactly the behaviors a continuous-shuffle
machine makes worthless. A Tier-6 "contrast table" behaved identically to a
countable one, defeating its entire pedagogical purpose (recognize when
counting no longer helps).

Cause: The rule flag existed but the loop had no notion of "the count has no
edge here," so every count-driven decision path ran unmodified.

Fix:
- **`CHGameLoop.effective_tc()`**: the true count that *decisions* use. Returns
  `0` when `config.continuous_shuffle` is set, else the raw floored count.
  `current_tc()` still returns the raw count so the (hidden) training display
  and any external inspection can see a count was tracked — it is just ignored.
- **Decisions routed through `effective_tc()`**: optimal insurance
  (`should_take_insurance`), optimal play (`best_play_no_split`), presplit
  check (`_would_split_pre` → `best_play`), the split resolver call, and the
  I18 deviation tell (`is_counting_deviation`). Under CSS these all see TC 0,
  so: no deviations, no count-based insurance.
- **Flat bet under CSS**: `optimal_bet_units()` returns 1 (table minimum) when
  `continuous_shuffle` is on, instead of the 4-step TC ramp. Betting up on a
  count is the whole point of the CSS lesson, so the "optimal" play is to stay
  flat.
- **Count-knowledge heat tells gated off**: the big-bet tell
  (`_tc >= BET_TELL_TC`) and the insurance tell now require
  `not config.continuous_shuffle`. There is no count to reveal on a CSS table,
  so neither tell can fire — a player can sit at Tier 6 and build no heat from
  count behavior.
- **`Main.gd`**: the count-system HUD label reads "Count: — (shuffled, no
  edge)" on a CSS table instead of a counting system name, making the contrast
  visible. The numeric TC is already hidden for T6 via `show_count_display`.

Results:
- `css_check` (new): ALL PASS — CSS `effective_tc()` is 0 on a hot raw count
  while `current_tc()` still reports the raw value; CSS optimal bet is a flat 1;
  the non-CSS control ramps to 6 on the same hot count (proving CSS is what
  flattens it); CSS declines insurance on a hot count while the control takes
  it; CSS optimal play builds no heat across a shoe while the control's optimal
  bet still varies (ramp live).
- `sim_validate`: unchanged (no-split 1.009%, split 0.507%, counting -0.561%)
  — the sim is single-deck and non-CSS, so `effective_tc()` is the raw count
  there and all behavior is identical.
- All 11 tools pass with no regression.

Still deferred (documented M9): multi-hand play (`player_hand_count > 1`) —
Tiers 4/5/6 declare multiple hands but the loop still deals and resolves a
single root hand. That is a structural change to the hand-group model and is
its own milestone.

## M12 — Robustness pass: mid-hand runout + per-shoe discipline reset

Found: two latent crash/leak bugs in `CHGameLoop`, plus a verification gap.

1. **Mid-hand runout crash.** `CHShoeManager.deal()` returns `null` when the
   wall is exhausted. `begin_hand()` guarantees `cards_remaining() >= SHOE_RESERVE
   (20)` at hand *start*, but a pathological hand can outdraw 20 mid-play: a
   4-way split where every hand is hit repeatedly (e.g. all 2s) can deal 40+
   cards. The in-hand deal sites called `shoe.deal()` and did `add_card(c)` with
   no null check → `null` appended to a hand → `total()`/`is_bust()` null-deref
   crash.
2. **Per-shoe discipline never reset.** The loop never called
   `discipline.reset_for_new_shoe()` / `get_and_clear_shoe_decisions()` on a
   reshuffle. Consequences: `cover_plays_remaining` was effectively
   *session*-wide (3 cover plays total, not 3 *per shoe* as the
   `MAX_COVER_PLAYS_PER_SHOE` constant and design intend), and
   `discipline.decision_log` grew unbounded for the whole session (the exact
   regression `session_length_check` documents — but only guarded by that tool
   calling the API directly, not by the live loop).

Cause: The deal sites assumed the shoe always had cards; the loop's reshuffle
boundary never forwarded to the discipline system.

Fix:
- **`CHGameLoop._deal_card()`** — guarded deal helper. Returns a card; on a
  mid-hand runout (null) it reshuffles (deterministic seed, same
  `_reshuffle_count * 7919` scheme as the start-of-hand cut), resets the count,
  and deals from the fresh shoe. Replaced the three in-hand `shoe.deal()` sites
  (hit, double, dealer play). Opening deals and the `CHSplitResolver` deals stay
  on raw `shoe.deal()` — both are provably under the reserve (opening 4,
  resolver ≤ 6).
- **`CHGameLoop._on_new_shoe()`** — new-shoe bookkeeping: drains
  `discipline.get_and_clear_shoe_decisions()` (bounds the log) then
  `discipline.reset_for_new_shoe()` (resets the per-shoe cover-play budget).
  Called at **both** shoe boundaries: the start-of-hand cut
  (`start_or_next_shoe`) and the mid-hand runout (`_deal_card`).
- **`tools/robustness_check.gd`** (new) — deterministic coverage: (1) every
  `_deal_card()` returns a valid card including the one that triggers a runout;
  (2) a runout resets the running count to 0, resets `decks_remaining` to 1.0,
  and rebuilds the shoe; (3) a hand played across a reshuffle conserves every
  dealt card (no double-count / loss across the shoe boundary).

Results:
- `robustness_check` (new): ALL PASS.
- All 12 tools pass with no regression; `sim_validate` baselines unchanged
  (no-split 1.009%, split 0.507%, counting -0.561%) — the sim has its own
  `SHOE_RESERVE` and reshuffle seed, and never triggers a mid-hand runout under
  optimal play, so it is unaffected.
- Cover plays now correctly reset to 3 each shoe (was: 3 for the whole
  session); the per-shoe decision log is drained on every reshuffle.

Note: the sim's own `SHOE_RESERVE = 20` is left untouched — it is part of the
locked deterministic baseline and optimal-play hands stay far below the
reserve. Only the interactive loop got the guard, because only a *human* can
drive a pathological multi-split outdraw.

## M13 — Multi-hand (multi-spot) play

Found: `CHTableConfig.player_hand_count` was a Tier-4/5/6 flag that nothing
honored. The loop modeled a single root hand (`_pre` → `_hands`), so the
"multi-hand" tiers behaved identically to a one-spot table. Multi-hand play is
a core difficulty lever (more independent decisions per round, per-spot betting
and insurance).

Cause: The hand-group model assumed one root. No code dealt, bet, or resolved
more than one independent opening hand against the shared upcard.

Fix (single-deal model: one bet size per spot, all spots share the upcard):
- **`_roots: Array[CHHand]` + `_root_idx`** replace the single `_pre`. 
  `_deal_opening()` now deals one two-card root per `config.player_hand_count`
  (min 1) against the shared dealer upcard.
- **Root processing**: `_after_insurance()` (no-natural path) and
  `_process_next_root()` walk the roots in order. A splittable pair (engine
  says split) enters `PHASE_PRESPLIT` for the player to decide; every other
  root is appended straight to the terminal `_hands` group via
  `_append_root_unsplit()` and play advances. `_would_split_root(root)`
  (per-root) replaces `_would_split_pre()`.
- **`_apply_presplit`** now resolves the *current* root (`_roots[_root_idx]`)
  via the `CHSplitResolver`, appends its terminal hands to `_hands`, then
  advances to the next root (or starts play when all roots are done).
- **`optimal_action()`** `PHASE_PRESPLIT` now evaluates the current root.
- **Natural settlement** (`_settle_natural(dealer_bj)`): per-spot — a spot that
  is a blackjack pushes vs dealer BJ, wins 3:2 otherwise; a non-BJ spot loses
  to a dealer BJ. Wagered = `spots x base_bet + insurance`.
- **Insurance** scales with spot count: `_insurance_bet = spots x
  max(1, base_bet/2)` — one decision covers all spots (same upcard + count).
- **`_finalize`** clears `_roots`/`_root_idx`; **`current_hand()`** returns the
  current root in `PHASE_PRESPLIT`.
- The `CHSplitResolver` is unchanged (it already resolves one root's full
  split structure and the loop reuses it per root).

Results:
- `multi_hand_check` (new): ALL PASS — 2-spot non-pair opening yields 2 terminal
  hands with wagered = 2x bet; 3-spot yields 3 hands; two 7,7 vs 5 spots both
  split into 4 terminal hands; card conservation holds across a settled
  multi-spot round.
- `sim_validate`: unchanged (no-split 1.009%, split 0.507%, counting -0.561%)
  — the sim is single-spot and never sets `player_hand_count`, so the refactor
  is a no-op for it.
- All 13 tools pass with no regression.

Note: the scene (`Main.gd`) already renders every hand in `_loop.all_hands()`
and shows the current root during `PHASE_PRESPLIT`, so multi-spot tables are
playable as-is; no scene change was required. The Tier-4/5/6 configs
(`for_tier`) already set `player_hand_count` to 2/2/3, which now take effect.

## M14 — Session-lifecycle completion wiring + heat-floor write-back

Found: `CHGameState` had `on_shoe_finished()` (increments `shoes_this_session`,
ends practice/survival sessions at `practice_shoes_required`) and
`apply_hand_result()` (ends target/bust sessions), but the interactive
`CHGameLoop` never called either end path. A practice or survival session could
never complete through the loop, and the persistent per-tier
`reputation_heat_floor` was read (to seed a new session's heat) but **never
written** — so a counter's ending heat at a tier had no lasting effect on their
next session there. The "residual suspicion" half of the heat model was
dead.

Cause: M8 wired heat *within* a session (tells, decay, backoff) and M1 built
the floor *persistence hooks*, but nothing bridged the two: the loop's shoe
boundary and hand-settlement paths did not forward to `on_shoe_finished` /
consume the `apply_hand_result` "session ended" return, and no code wrote a
session's ending heat back to the tier floor.

Fix:
- **Practice/survival completion**: `CHGameLoop._on_new_shoe()` now calls
  `state.on_shoe_finished(discipline.discipline)` at the shoe boundary, so a
  practice/survival session ends after the configured number of shoes, driven
  entirely by the loop (the scene needs no special case).
- **`begin_hand()` guard**: after `start_or_next_shoe()` (which may have ended
  the session at the shoe boundary), re-check `state.is_session_active()` and
  refuse to open a hand in an inactive session.
- **Heat-floor write-back ("residual suspicion")**: when a session ends, its
  ending heat is persisted as the tier's `reputation_heat_floor` and the save is
  re-written, so the next session at that tier starts from the previous session's
  ending heat. Two end paths, two write-back sites:
  - **Target/bust**: `_finalize` captures `apply_hand_result`'s boolean return;
    on `session_ended and config.heat_active` it calls
    `state.set_heat_floor(state.current_tier, _heat.heat)` + `state.save()`.
    (The floor is set *after* `apply_hand_result` because that call already
    saved inside `end_session` — the floor must be re-persisted on top.)
  - **Practice/survival**: `_on_new_shoe` does the same write-back after
    `on_shoe_finished` returns an ended session.
  - Guarded on `config.heat_active` so non-heat tables (all sim + default
    configs) have no side effects.

Results:
- `lifecycle_check` (new): ALL PASS — (1) a 2-shoe practice session ends with
  reason `practice_complete`, `shoes_this_session >= 2`, `begin_hand()` refuses
  afterwards, and the skill rating advanced from the process score; (2) a
  target session with `heat_active` writes back its ending heat — the tier floor
  equals `loop.heat()` and survives a `serialize()`/`deserialize()` round-trip.
- `game_loop_check`: two long checks (`_check_card_conservation`,
  `_check_suboptimal_costs_discipline`) switched from `MODE_PRACTICE` to
  `MODE_TARGET` + target `999999`, so the new practice-completion path cannot
  truncate their hand sweeps; a `_cleanup_save()` was added because a target
  check can bust and write a save.
- All 14 tools pass with no regression; `sim_validate` baselines unchanged
  (no-split 1.009%, split 0.507%, counting -0.561%) — the sim is non-heat and
  single-shoe per phase, so the lifecycle wiring and floor write-back are no-ops
  for it.

Note: the write-back uses the session's *ending* heat (after the terminal hand's
per-hand decay) as the floor, which is the intended "residual suspicion" — how
much suspicion the pit still holds after you walked away. Because the floor is
per-tier and persisted, a player who plays hot at a tier carries that suspicion
into their next visit to the same tier.

## M15 — Session-lifecycle UI completion: selectable modes + session-end UI for all end paths

Found: M14 made practice/survival sessions *complete* through the loop, but the
playable scene could not use that. Two concrete defects:
1. **No mode selection.** `Main.gd` hard-coded `CHGameState.MODE_TARGET` at
   session start, so practice / survival modes (built in M1, wired in M14) were
   unreachable from the UI.
2. **Practice/survival completion left the player stuck.** When a session ends
   at the *shoe cut* (inside `begin_hand()` → `start_or_next_shoe()` →
   `_on_new_shoe()` → `on_shoe_finished()`), the `hand_settled` signal is never
   emitted — no hand was settled, the hand never started. The scene drove its
   session-end UI (debrief + New Session button) off `hand_settled`, so after a
   practice/survival session the player saw "Session inactive." with no way to
   start a new session. Additionally, `heat_backoff` was emitted by the loop but
   never surfaced in the scene.

Cause: The scene's session-end handling was coupled to a single end path (hand
settlement). M14 added the second end path (shoe completion) to the loop but
there was no scene-side event that fired for it.

Fix:
- **`CHGameLoop`**: new `session_ended` signal, emitted exactly once when the
  session transitions to inactive, from *both* end paths — target/bust in
  `_finalize` (after `apply_hand_result` returns true) and practice/survival in
  `_on_new_shoe` (after `on_shoe_finished` returns true). Because a session ends
  only once (afterwards the state methods return early), the signal fires
  exactly once per session regardless of which path ended it.
- **`Main.gd`**:
  - **Mode selector** (OptionButton: Target / Practice / Survival) + a
    **shoe-count SpinBox** (visible only for practice/survival) in the HUD.
    `_start_session` is parameterized `(tier, mode, target, shoes)`; changing the
    mode (or tier) restarts the session with the chosen framing, matching the
    existing tier-selector behavior.
  - **Session-end UI driven off the signal**: `session_ended` → `_on_session_ended()`
    sets the status line, reveals the New Session button, and shows the debrief.
    `_on_hand_settled` no longer inspects `is_session_active()` for session-end
    handling (that path now runs for *every* end), it only accumulates P&L and
    refreshes.
  - **`_on_deal` no longer clobbers the debrief**: when `begin_hand()` fails, it
    only writes a "Cannot start hand" notice if the session is still active; when
    the session just ended (the debrief is already up), it leaves the status
    intact.
  - **`heat_backoff` surfaced**: `_on_heat_backoff()` shows a transient
    "Backed off — heat reset to the tier floor" notice and refreshes the HUD.
- **`_populate_mode_selector`** shows/hides the shoe-count control per mode.

Results:
- `scene_smoke_check` (new): ALL PASS — loads `Main.tscn`, builds the UI
  (verifies the mode selector + shoe-count controls exist), drives a 1-shoe
  practice session to completion, and asserts the debrief panel + New Session
  button are visible and the status reads "Session ended: …" — i.e. the M15
  "stuck after practice" bug is fixed end-to-end through the real scene.
- `lifecycle_check` (extended): now also asserts `session_ended` fires exactly
  once for a practice completion, and only after the session is inactive.
- All 15 tools pass with no regression; `sim_validate` baselines unchanged
  (no-split 1.009%, split 0.507%, counting -0.561%).

Gotcha (Godot 4): `SpinBox` has **no `disabled` property** (it extends `Control`,
not `Button`) — `_shoes_spin.disabled = …` is a parse/runtime error that aborts
the enclosing function. Show/hide via `.visible` is sufficient to toggle the
control out for target mode. This bug was invisible to the tool suite (which
tests the loop/state headlessly, never the scene) and only surfaced when the
scene was actually instantiated — which is why the new `scene_smoke_check`
exists.

Note: `scene_smoke_check` instantiates the scene and calls `_ready()` manually
(no frame-timing `await`), so it reports harmless RID-leak warnings at exit from
the UI nodes it never adds to the tree. The pass/fail output is printed before
those warnings and they do not affect the result.

## M16 — Counting-accuracy check: the core skill is now actually tested

Found: A card-counting trainer whose core skill is *tracking the running count*
never checked whether the player could actually do it. The count was either
displayed (`show_count_display`, tier 1-2) or hidden (tiers 3-6), but when
hidden there was no feedback on whether the player's count was correct — and
nothing graded it. The skill rating (the persistent tier-unlock currency) was
computed from the Discipline meter alone, so a player who never tracked the
count could still climb tiers by playing correct basic strategy. The defining
skill of the game was unmeasured.

Cause: M0-M5 built the count *engine* (CHCountEngine) and M4 proved the
counting *edge* in simulation, but no component asked the player "what's the
running count?" and compared their answer to the truth. The count was an
internal input to decisions, not a skill the player demonstrated.

Fix:
- **`CHCountAccuracySystem`** (`scripts/systems/CountAccuracySystem.gd`,
  RefCounted, headless-testable) — grades running-count checks. `record(reported,
  actual)` scores by absolute error: `score = clamp(100 - 5 * |error|, 0, 100)`
  (off-by-N costs N*5 points). Maintains a running-mean `accuracy` (0-100, exact
  mean of per-check scores, neutral 100 with no checks) and exposes
  `process_score()` (neutral 100 when no checks recorded, so a session without
  count checks does not dilute the rating).
- **`CHTableConfig.count_check_active`** — per-tier toggle, ON for tiers 1-5,
  OFF for the Tier-6 continuous-shuffle table (where counting has no edge,
  consistent with the CSS lesson that the count is meaningless there).
- **`CHGameLoop`**:
  - Captures the true running count at each *clean* shoe cut — in
    `start_or_next_shoe()` it reads `count.running_count` **before**
    `count.reset()` wipes it, stores it as `_last_shoe_rc`, sets
    `_count_check_due`, and emits the new `count_check_due(rc)` signal. Mid-hand
    runout cuts (`_deal_card`) deliberately do **not** fire the check: a
    pathological outdraw reshuffle is not a clean shoe boundary and quizzing on a
    partial shoe would be unfair.
  - `report_count(reported_rc)` — grades the report against the captured RC,
    clears the pending flag; no-op (returns `{}`) when no check is due, so it is
    safe to call blindly. `skip_count_check()` clears without grading.
    Accessors: `get_count_accuracy()`, `is_count_check_due()`, `last_shoe_rc()`.
  - **Process-score blend**: `_session_process_score()` is now the skill-rating
    feed. With no count checks it returns `discipline` alone (M10 behavior,
    unchanged); with one or more checks it returns
    `lerpf(discipline, accuracy, 0.5)` — counting accuracy and decision
    discipline weighted equally. `_finalize` and `_on_new_shoe` both use this
    when ending the session, so bad counting now demonstrably lowers the
    skill rating (and hence tier progression).
- **`Main.gd` scene**:
  - A count-check **prompt panel** (title + LineEdit + "Submit count"/"Skip" +
    result line) shown when `count_check_due` fires; the LineEdit grabs focus.
    Submitting grades via `report_count`, showing "You said X, actual was Y
    (off by N). Score: S/100."
  - **Forcing function**: while a check is pending (`is_count_check_due()`), the
    bet-unit buttons and cover toggle are disabled — the player must answer or
    skip before betting. This makes the check an engagement beat rather than a
    nag.
  - HUD "Count acc: NN% (N)" line (only on tiers with `count_check_active`), and
    a "Counting: NN / 100 (N checks)" line in the session-end debrief.

Results:
- `count_check` (new): ALL PASS — (1) grading curve (off-by-0→100, off-by-1→95,
  off-by-5→75, off-by-20→0 clamped, negative-error symmetric); (2) running mean
  (mean of per-check scores is exact); (3) no-check neutrality (process score
  and accuracy are 100 with zero checks); (4) **end-to-end blend** — a real
  loop that reports the count off-by-8 at each cut ends with a *lower* skill
  rating than an identical control loop (same seed, optimal play, no checks),
  proving the count now gates progression; (5) the `count_check_due` signal
  fires on a shoe cut with the true RC, `report_count` records exactly one check
  and a second report is a no-op.
- All 16 tools pass with no regression; `sim_validate` baselines unchanged
  (no-split 1.009%, split 0.507%, counting -0.561%) — the sim is unaffected
  (single-deck, non-CSS, `count_check_active` defaults to false on its config,
  and the sim drives its own count loop rather than CHGameLoop).

Note: the blend weight (0.5 / 0.5) and the per-error penalty (5 pts) are
starting defaults for playtest tuning, mirroring `TIER_SKILL_THRESHOLDS`. The
RC (not TC) is the skill checked: tracking the running count is the
fundamental skill; the true count is a derived skill layered on deck
estimation, which the HUD's `deck_estimation_rounding` already trains and is
out of scope for this check.

## M17 — Surrender-legality fix + dead-code / stale-comment cleanup

Gap analysis surfaced three issues; the first is a real latent defect, the
other two are maintenance. All three are addressed in this pass.

**1. Surrender recommended on hands that can no longer be surrendered (DEFECT).**
`StrategyEngine._apply_surrender` fired on *any* 15/16 hard hand vs 9/10, with
no check that the hand was still a fresh two-card hand. The loop's
`_can_surrender` (GameLoop.gd:378) *does* require `card_count()==2`. The two
gates disagreed: on a **three-card** 15/16 (e.g. hit up to 16 vs 10) the
engine returned `"surrender"`, the loop couldn't honor it, and `optimal_action()`
degraded it to `"stand"` — the *wrong* basic play (correct is `"hit"`). This
corrupted both the autopilot test player and player-discipline grading on every
3-card 15/16. Fix: `_apply_surrender` now returns early unless
`hand.card_count()==2`, exactly mirroring `_can_surrender`. Regression cell
added to `spot_check.gd` (3-card 16v10 with surrender enabled → `"hit"`).
`spot_check` now reports **27/27**. Sim baselines unchanged (surrender is off in
the sim config; the new guard only tightens a path the sim never took).

**2. `should_take_insurance` stale comment (MAINTENANCE).** Its doc block claimed
the method "is not yet wired into a UI prompt or hand-resolution loop". It *is*
wired (M5; driven from `optimal_action()` PHASE_INSURANCE and `sim_validate`
counting). Comment corrected to describe the live wiring.

**3. `late_surrender_only` flag still set-but-unread (DEFERRED, not built).**
`TableConfig.late_surrender_only` is set true on T4/T5/T6 but honored nowhere.
In this trainer "surrender" *is* always late surrender (there is no early
surrender in a single-actor card-counting drill), so the flag is redundant
rather than a missing behavior. Rather than invent a fake early-surrender mode
that no gameplay uses, the flag is left as a documented no-op. Not changed this
pass.

- `current_heat` in `GameState.gd` and the `unlocked_systems` /
  `is_system_unlocked` / `unlock_system` / `is_cosmetic_unlocked` /
  `unlock_cosmetic` block were also examined and are **intentionally inert
  persistence hooks**, not defects: heat actually lives in `CHHeatSystem` + the
  persistent `reputation_heat_floor`, and count systems are tier-selected rather
  than individually unlocked. They round-trip through `serialize`/`deserialize`
  for forward compatibility. Left as-is; removing them would shrink the save
  schema for zero behavioral gain.

**Tooling / verification.** `spot_check` extended with the 3-card-16 surrender
cell. Full 16-tool suite re-run: all pass; `sim_validate` baselines byte-identical
(no-split 1.009%, split 0.507%, counting -0.561%); no save residue.

## M18 — Counting-deviation tell baseline fix (no spurious heat on surrenders)

**Defect.** `CHStrategyEngine.is_counting_deviation` (the predicate that gates the
heat *dev-tell*, GameLoop.gd:490) measured the I18 deviation layer's delta against
`_basic_play` — the raw pair/soft/hard table with **no surrender or H17 layer**.
But the engine's actual pipeline is `basic → surrender → h17 → deviation`
(`best_play`). The mismatch mattered for the two-card 16/15 vs 9/10 hands that are
late-surrender candidates: at a high count the engine's *correct* optimal play is
`"surrender"` (a basic-strategy play), yet `is_counting_deviation` diffed basic
`"hit"` against the deviation layer's `"stand"` and reported a **counting
deviation** — firing a spurious `DEV_TELL_GAIN` (+2 heat) every time the player
played the optimal surrender. A surrender is not a counting tell; the heat model
was over-crediting suspicion on correct play.

**Fix.** `is_counting_deviation` now builds the baseline through the full
non-deviation prefix (`_basic_play → _apply_surrender → _apply_h17`) and diffs the
deviation layer against *that* — exactly isolating the I18 layer's contribution,
mirroring `best_play`'s layer order. A surrender hand now reads
`base == with_dev == "surrender"` → no tell. Genuine I18 stands/hits (e.g. 13v10
high-TC → stand, S19v9 high-TC → stand) still report true. Single caller
(GameLoop dev-tell gate), so the blast radius is contained to the heat path.

**Secondary cleanup (same file).** `_pair_play`'s 8s branch had a no-op
`if dk != 7: return "split" / return "split"` (both arms identical); simplified to
a single `return "split"` with a standard-BS comment. Behavior-identical.

**Tooling / verification.** New `tools/deviation_check.gd` (extends SceneTree,
engine-level, deterministic) pins the regression:
1. two-card 16v9 (surrender on, TC3) → `best_play` "surrender",
   `is_counting_deviation` false (no spurious tell);
2. two-card 15v10 (surrender on, TC3) → "surrender", false;
3. 13v10 (no surrender, TC3) → "stand", true (genuine I18 stand still a tell);
4. soft 19 vs 9 (TC3) → "stand", true;
5. 17v5 (TC3) → false (no I18 rule applies);
6. the loop's dev-tell gate predicate fires on the genuine deviation and stays
   silent on the optimal surrender.

Full 17-tool suite re-run: all pass. `sim_validate` baselines byte-identical
(no-split 1.009%, split 0.507%, counting -0.561%) — the sim drives its own
engine path and never calls `is_counting_deviation`, so it is unaffected. No save
residue.

## M19 — Count-check prompt: visible feedback + no stale prompt across restart

**Defect (UX, M16 fallout).** Two related problems in the playable scene's
count-accuracy prompt:

1. **Per-check feedback was swallowed.** `_on_count_check_submit` wrote
   "you said X, actual was Y, score Z" to a `_count_check_result` label that
   lived *inside* the prompt panel, and then immediately set the panel
   `visible = false`. The player therefore never saw their per-check score —
   only the slow-updating "Count acc" HUD meter changed. For a trainer whose
   whole point is teaching the count, hiding the immediate "you were off by N"
   feedback defeated the purpose.

2. **Stale prompt leaked across a session restart.** The count-check panel is a
   scene-level node that outlives the `CHGameLoop` it belongs to.
   `_start_session()` hid the debrief panel and the New Session button but did
   *not* reset the count-check panel. A shoe-cut prompt that was on screen at
   the moment a session ended (or the player switched tier/mode mid-prompt)
   would stay visible into the new session, with a stale `LineEdit` value,
   even though the fresh loop had no check pending.

**Fix (scenes/Main.gd).** Per-check feedback now routes to the always-visible
`_status_label` (the prompt panel still hides on answer, but the score is now
readable in the status line). Removed the now-unused `_count_check_result`
declaration and its `Label` node creation in `_build_ui()`.
`_on_count_check_skip` also writes "Count check skipped." to the status line
(for consistency). `_start_session()` now hides the count-check panel and
clears the `LineEdit` on every session (re)start, so a prior session's prompt
can never bleed into the next one.

**Tooling / verification.** Extended `tools/scene_smoke_check.gd` with two
checks: (a) `_check_count_check_feedback` — set `_loop._count_check_due` +
`_last_shoe_rc`, call `_on_count_check_submit` and `_on_count_check_skip`,
assert the result/skip text lands in `_status_label`, the panel hides, and
`is_count_check_due()` clears; (b) `_check_count_check_stale_reset` — force
the panel visible with a stale input, call `_start_session`, assert the panel
is hidden and the input cleared.

Full 17-tool suite re-run: all pass. `sim_validate` baselines byte-identical
(no-split 1.009%, split 0.507%, counting -0.561%) — no engine-level change,
so the sim is unaffected. No save residue.

## M20 — Shoe cut respects tier penetration (multi-deck tables were over-penetrating)

**Defect (set-but-unread config).** `CHTableConfig.penetration` is a first-class
tier-ladder value (T1/T2 0.70, T3 0.60, T4/T5 0.50, T6 1.0) and is even
validated by `tables_check`, and `CHShoeManager.should_reshuffle()` reads it
(`is_empty() or penetration_reached()`). But `CHGameLoop.start_or_next_shoe()`
decided to cut the shoe with `shoe.cards_remaining() < SHOE_RESERVE` — a fixed
20-card safety constant — and never consulted penetration. Result: single-deck
tiers cut near the reserve anyway (so they happened to be ~right), but every
multi-deck tier cut far deeper than intended. A 4-deck T4 table (208 cards,
50% penetration → cut at 104 cards left) was instead played down to the last
20 cards (188 dealt), roughly doubling the cards the counter tracks before a
cut. That silently changed the difficulty/heat/counting dynamics the tier ladder
was designed to express, and it meant the `penetration` knob did nothing.

**Fix.** `start_or_next_shoe()` now cuts when
`shoe.should_reshuffle() or shoe.cards_remaining() < SHOE_RESERVE` — the tier's
penetration is the primary cut point, the 20-card reserve remains a backstop so
a hand can never exhaust the shoe mid-play (whichever comes first). The
`SHOE_RESERVE` doc comment was corrected to describe it as a safety backstop,
not the cut rule.

**Regression test.** `robustness_check.gd` gained `_check_penetration_cut()`:
asserts the T4 premise (penetration cut precedes the reserve cut), then
positions a T4 shoe just past 50% and confirms `begin_hand()` cuts the shoe
(fresh shoe → `cards_dealt() == 0`). Under the old code the shoe would not cut
there, so the test pins the new behavior.

**No regression.** Single-deck tiers (T1/T2, 0.70) still cut at the 20-card
reserve (it precedes 0.70-penetration on a 52-card shoe), so their behavior is
unchanged; T3–T5 now cut at their stated penetration; T6 (CSS, penetration 1.0)
still backstops on the 20-card reserve. `sim_validate` is unaffected — it drives
its own shoe logic with `penetration = 1.0` and its own reserve, and never calls
`CHGameLoop`. Full 17-tool suite re-run: all pass; baselines byte-identical
(no-split 1.009%, split 0.507%, counting -0.561%); no save residue.

## M21 — Discipline grading gated on the tier-ladder flags

**Defect (set-but-unread config).** `CHTableConfig.grade_decisions` and
`grade_bet_ramp` are first-class tier-ladder values (off on T1 "Teaching Table",
on from T2–T6) and sit in the "Teaching / grading toggles" block. But the loop
called `discipline.grade_decision()` (in `_grade`) and `discipline.grade_bet()`
(in `place_bet`) *unconditionally*. So the teaching table penalized imperfect
play just as hard as the hardest table, and the difficulty curve those flags
were meant to express never engaged.

**Fix.** Gated both call sites on the config: `place_bet` grades the bet only
when `config.grade_bet_ramp` (else it returns a no-op `{delta:0, discipline}` and
emits the signal so the HUD still updates); `_grade` returns early when
`config.grade_decisions` is off. T1 therefore no longer moves Discipline or
records tilt (tilt reads `bet_history`, which is only populated by `grade_bet`);
from T2 on, grading behaves exactly as before.

**Regression test.** `game_loop_check` gained `_check_grading_gated_by_config()`:
same seed, 20 hands of forced suboptimal hits on two loops — one with the grade
flags on, one off. Asserts the ON loop's discipline drops (<100) while the OFF
loop's stays pinned at exactly 100. Also enabled `grade_decisions`/
`grade_bet_ramp` in that tool's `_make_config()` so its existing
"suboptimal costs discipline" check keeps exercising the graded path.

**No regression.** `sim_validate` drives its own logic and never calls the loop,
so baselines are byte-identical (no-split 1.009%, split 0.507%, counting
-0.561%). Other loop-driving tools use T1/default configs and don't assert
discipline *values* (lifecycle asserts skill-rating >0, which still holds;
count_check's skill-rating comparison holds with or without grading). Full
17-tool suite re-run: all pass; no save residue.

## M22 — Player-facing "Cash Out" (voluntary session end)

**Defect (missing trigger).** `CHGameState.end_session("cash_out", ...)` was a
documented, fully-supported end reason, and the scene's `_reason_text` already
mapped `"cash_out"` → "Cashed out". But **no code path ever called it**. A
player's only ways out of a session were bust, hitting the target, or completing
practice/survival shoes. In a target-mode session (goal 150, easily a long run)
there was no way to voluntarily stop and review the debrief — the session just
kept going until an economy end condition fired.

**Fix.**
- `CHGameLoop.cash_out()` (new, public): if the session is active, persist the
  session's ending heat as the tier floor (mirroring the other end paths when
  heat is active), call `state.end_session("cash_out", _session_process_score())`,
  clear any pending count check, settle into `PHASE_SETTLED` so
  `begin_hand()`/`apply_action()` no-op until a new session starts, emit
  `session_ended`, and return `true`. A no-op (returns `false`) when the session
  is already ended. An in-progress hand is abandoned on cash-out (the player's
  explicit choice to leave the table).
- `scenes/Main.gd`: a new **Cash Out** button in the actions row (visible while
  the session is active, hidden after). `_on_cash_out()` hides any open
  count-check prompt and calls `_loop.cash_out()`; the existing `session_ended`
  handler then surfaces the debrief + New Session button, exactly as it does for
  the other end paths.

**Tooling / verification.**
- `lifecycle_check` gained `_check_cash_out()`: start an active target session,
  begin a hand, call `cash_out()` — assert it returns true, the session ends
  with reason `"cash_out"`, `session_ended` fires exactly once *after* the
  session is inactive, `begin_hand()` refuses, a second `cash_out()` is a no-op,
  and the skill rating is not decreased.
- `scene_smoke_check` gained `_check_cash_out_button()`: start a fresh session,
  assert the Cash Out button exists + is visible while active, start a hand,
  invoke `_on_cash_out()`, and assert the session ends (`"cash_out"`), the
  button hides, and the New Session button + debrief panel appear.

**No regression.** Pure additive path; the economy end conditions are untouched.
`sim_validate` is unaffected (it never drives `CHGameLoop`). Full 17-tool suite
re-run: all pass; baselines byte-identical (no-split 1.009%, split 0.507%,
counting -0.561%); no save residue.

## M23 — Cleanup: remove dead autoloads + redundant `max_active_player_hands`

**What was removed.**
1. **All 6 autoloads** (`EventBus`, `CountEngine`, `StrategyEngine`,
   `DisciplineSystem`, `ShoeManager`, `GameState` + their `.uid` sidecars):
   `Main.gd` and every tool build their own `CH*` instances and use their own
   local signals. No code in `scenes/`, `tools/`, or `scripts/` referenced the
   autoload global names. `EventBus` had 13 signals, none connected. The
   `GameState` autoload was the only one that emitted anything
   (`session_started`/`session_ended` → `EventBus`), but nothing subscribed.
   The `autoload/` directory is now removed and `project.godot` no longer has
   an `[autoload]` section.
2. **`CHTableConfig.max_active_player_hands`** — set on T4/T5/T6 and in
   `multi_hand_check`, but never read. Redundant with `player_hand_count` (the
   field the loop actually uses in `_deal_opening`). Removed the declaration,
   three tier assignments, and the test's setter.
3. **Stale comments** in `GameLoop.gd` (2) and system `GameState.gd` (1) that
   referenced the now-removed autoload `EventBus` / "GameState autoload".

**Verification.** Rebuilt class cache (clean), ran full 17-tool suite: all pass.
`sim_validate` baselines byte-identical (1.009% / 0.507% / -0.561%). No save
residue.

## M24 — `insurance_payout` config now honored in `_settle_natural`

**Defect (set-but-unread config).** `CHTableConfig.insurance_payout` (default 2.0)
was declared but never read. `GameLoop._settle_natural` hardcoded
`2.0 * _insurance_bet` for the dealer-BJ win side, so changing the config value
had no effect — inconsistent with `blackjack_payout`, which *is* read from
config at the same settle path.

**Fix.** `GameLoop._settle_natural` now uses `config.insurance_payout *
_insurance_bet` for the win side (the loss side still just forfeits the stake).
Since no `for_tier` override changes the default (all tiers stay at 2.0), this
is a pure refactor with zero behavioral change at the default value; it makes
the config field live and consistent with `blackjack_payout`.

**Verification.** New check in `insurance_check.gd`
(`_check_loop_honors_insurance_payout` + `_drive_insurance_settle`) drives the
real `CHGameLoop` through a rigged Ace/10 dealer-BJ hand with insurance taken at
two different `insurance_payout` values (2.0 → net +1.0; 1.0 → net 0.0), proving
the config value flows through. Sim baselines unaffected — `sim_validate`
hardcodes its own 2.0 payout independently and never reads the config. Full
17-tool suite re-run: all pass; baselines byte-identical; no save residue.

## M25 — Wire `deck_estimation_rounding` into the count feed

**Defect (dead difficulty lever).** `CHTableConfig.deck_estimation_rounding`
(per tier: T1 1.0, T2 1.0, T3/T4 0.5, T5/T6 0.25) was declared, set per tier,
documented in `ShoeManager` as "a difficulty lever," and asserted in
`tables_check` — but its only consumer, `ShoeManager.decks_remaining_estimate()`,
was never called. `GameLoop.begin_hand()` fed `remaining_decks_exact()` into the
count engine instead, so the coarseness step had no effect anywhere.

**Fix.** `GameLoop.begin_hand()` now calls
`count.set_decks_remaining(shoe.decks_remaining_estimate())` instead of
`shoe.remaining_decks_exact()`. The count engine's `decks_remaining` is the
denominator for `true_count_floor()`, which is "the single source of truth for
display, training materials, and every grading/deviation check." Feeding the
tier-appropriate estimate (not the exact card count) is what a real card
counter does and is what `deck_estimation_rounding` exists to control.

**Why zero behavioral change at the default path.** `set_decks_remaining` is
called exactly once, at `begin_hand()`, immediately after `start_or_next_shoe()`
reshuffles to a full fresh shoe. A fresh shoe has `deck_count × 52` cards, so
`remaining_decks_exact() == deck_count` (an integer). Every tier's
`deck_count` is an exact multiple of its `deck_estimation_rounding` step, so
`decks_remaining_estimate() == deck_count` at that call site. The fed value is
byte-identical to before; the lever would activate only if a shoe were re-fed
mid-life or a tier's rounding didn't divide evenly into `deck_count`.

**Verification.** `tables_check.gd` gained `_check_deck_estimation()`:
- T5 (6 decks, step 0.25): fresh shoe estimate == 6.0; after dealing 10 cards
  (remaining 302) estimate == 5.75 while exact ≈ 5.808 — proving the rounding
  step is live and the estimate differs from exact.
- T3 (2 decks, step 0.5): fresh shoe estimate == 2.0; after 3 cards (remaining
  101) estimate stays 2.0 (rounds up from 1.942) — correct per the step.
- Loop wiring: after `begin_hand()` on a fresh T5 shoe,
  `count.decks_remaining == decks_remaining_estimate() == 6.0`, proving the
  loop feeds the estimate.

`sim_validate` uses `remaining_decks_exact()` directly (its own code path,
never the loop's `start_or_next_shoe`), so sim baselines are byte-identical.
Full 17-tool suite re-run: all pass; no save residue.

## M26 — Dead-code cleanup: unused heat field/method + unused CHHand helpers

**What was removed (all confirmed set-but-unread / never-called via repo-wide
grep; no caller in `scripts/`, `tools/`, or `scenes/`):**

1. **`CHGameState.current_heat`** — a `var` that was written in
   `start_session()` (`current_heat = get_heat_floor(tier)`) but read by
   nothing. The loop tracks live heat in its own `CHHeatSystem` instance and
   persists the floor through `set_heat_floor` / `get_heat_floor`, so this
   in-memory mirror was pure dead weight.
2. **`CHGameState.set_heat(value)`** — the public setter for that field;
   defined but never called from anywhere.
3. **`CHHand.has_cards()`** — defined (`cards.size() > 0`) but never called;
   callers use `card_count()` / `total()` directly.
4. **`CHHand.soft_ace_count()`** — defined (an ace-adjusted total walk) but
   never called; it duplicated the internal logic of `total()` and was dead.

**Rationale.** These were the last four non-intentional dead items. The
mid-hand runout cut in `_deal_card` that *does not* fire the M16 count check
was checked as a candidate but left as-is: DECISIONS.md M16 documents it as
deliberate (a pathological outdraw reshuffle is not a clean shoe boundary, and
quizzing on a partial shoe is unfair), and `robustness_check` pins its current
behavior (count reset to 0 / decks to 1.0).

**Verification.** No behavior change — every removed symbol had zero callers.
Full 17-tool suite re-run: all pass. `sim_validate` baselines byte-identical
(1.009% / 0.507% / -0.561%). No save residue.

## M27 — Dead-code cleanup: unused CHGameState accessors + CHCard helpers

**What was removed (all confirmed zero callers via repo-wide grep):**

1. **`CHGameState.is_broke()`** — duplicated `current_bankroll <= 0` logic
   already inlined in `apply_hand_result`; no caller anywhere.
2. **`CHGameState.get_lifetime_hands()`** — reads `lifetime_stats["hands_played"]`
   but no UI or tool ever calls it. The value is still persisted via
   `serialize()`; this is just a dead accessor.
3. **`CHGameState.get_sessions_played()`** — same as above for
   `lifetime_stats["sessions_played"]`.
4. **`CHCard.is_face()`** — rank 11-13 check; no caller.
5. **`CHCard.is_number()`** — rank 2-9 check; no caller.
6. **`CHCard.face_value()`** — returns 11/10/rank by card type; no caller.
   `CHHand.total()` already handles all value logic internally.
7. **`CHCard.clone()`** — creates a copy with same suit/rank/seen; no caller.

**Rationale.** These were the last remaining dead symbols found in a full
sweep of `scripts/`, `tools/`, and `scenes/`. The M26 pass caught
`current_heat`/`set_heat`/`has_cards`/`soft_ace_count`; this pass catches the
remaining seven. No behavior change — every removed symbol had zero callers.

**Verification.** Full 17-tool suite re-run: all pass. `sim_validate` baselines
byte-identical (1.009% / 0.507% / -0.561%). No save residue.

## M28 — Loop-level surrender P&L coverage

**Gap.** Surrender settlement (`profit -= 0.5 * b` in `CHGameLoop._play_dealer_and_settle`,
the half-loss path) was never exercised by any tool. `sim_validate` runs with
`allows_surrender=false` (the no-split / split / counting baselines all disable
it), and `game_loop_check` drives optimal play on a no-surrender config, so the
loop's surrender branch had no regression coverage. The strategy layer
(`best_play`/`_apply_surrender`) is covered by `spot_check`/`deviation_check`,
but the *settlement* (does surrender actually cost half, not a full loss or a
push?) was unverified.

**Fix (test-only).** `game_loop_check.gd` gained `_check_surrender_settlement()`:
rigs the shoe to a two-card 16 vs 10 (surrenderable, no natural, no split, no
double) on a surrender-enabled table, and asserts:
- `begin_hand` + `place_bet` reach `PHASE_HAND` with surrender offered;
- `optimal_action()` is `surrender` (engine + legality agree end-to-end);
- applying `ACT_SURRENDER` settles idle with `last_net() == -0.5 * bet` — a
  half-loss, not a full loss or a push.

**Verification.** New check passes (net −0.5 on a 1-unit bet). Full 17-tool
suite re-run: all pass; `sim_validate` baselines byte-identical
(1.009% / 0.507% / -0.561%); no save residue. No production code changed.

## M29 — Session decision record: "Decisions: M / N optimal" in the debrief

**Gap.** `CHGameLoop` records every play decision, but only when a tier's
`grade_decisions`/`grade_bet_ramp` flags are on (T2+). The T1 teaching table
grades nothing, so a T1 player got no per-session decision-quality feedback at
all — the loop's per-shoe `decision_log` was cleared and discarded at every
shoe boundary (`_on_new_shoe` → `get_and_clear_shoe_decisions()`), feeding
nothing. A card-counting trainer's core signal is "did you play the optimal
play?", and it should be visible on every tier, not gated behind the scoring
ladder.

**Fix (production + UI).**
- **`CHDisciplineSystem`** gained two session accumulators,
  `session_decisions` and `session_optimal`, plus a side-effect-free
  `record_decision(actual, optimal)` that increments them (no effect on the
  Discipline meter, `bet_history`, or the per-shoe `decision_log`). Reset in
  `reset_for_new_session()`. Recording is intentionally independent of the
  `grade_decisions` tier flag: it is a process read-out, not a scoring lever.
- **`CHGameLoop._grade()`** calls `discipline.record_decision(actual, optimal)`
  unconditionally (before the `grade_decisions` gate), so every
  hit/stand/double/split/surrender/insurance/presplit decision is captured on
  every tier. Scoring (moving the meter) remains gated as before.
- **`Main.gd` debrief** now appends a `"Decisions:  M / N optimal"` line when
  `session_decisions > 0` (so a zero-hand cash-out doesn't print "0 / 0"), and
  the debrief label row was widened from 7 to 8 to fit it.

**Design note.** Only *play* decisions are recorded (not bet sizing): the
Decision stat measures basic-strategy / counting-decision accuracy — the
trainer's core skill — and avoids conflating it with the separate
bet-ramp/Discipline axis and the deliberate "cover" lay-low choice.

**Verification.** `game_loop_check.gd` gained
`_check_session_decision_record()` (two parts: optimal play with grading off
records M == N > 0; a rigged two-card 20 vs K forced suboptimal hit records
M < N). `scene_smoke_check.gd` now asserts the debrief's "Decisions:" line
appears after a completed practice session. Full 17-tool suite re-run: all
pass; `sim_validate` baselines byte-identical (1.009% / 0.507% / -0.561%);
no save residue.

## M30 — Live decision-accuracy HUD label

The M29 "Decisions: M / N optimal" line was only shown in the post-session
debrief. Players wanted it visible while playing, not just after.

**Fix.** `Main.gd` adds a persistent HUD label:
- `var _decision_acc_label: Label` declared alongside the other HUD refs.
- `_build_ui` creates it with `_hud_label(hud, "Decisions: ")`.
- `_refresh_hud` (called every hand) sets its text to
  `"Decisions: %d/%d"` from `discipline.session_optimal` /
  `discipline.session_decisions` when `session_decisions > 0`, and hides it
  (`visible = false`, blank text) while no decisions have been recorded yet.

The backend counters (`record_decision` / `session_decisions` /
`session_optimal`) and the `GameLoop._grade` call already landed in M29; this
milestone is the display surface only, so no loop or discipline behavior
changes.

**Verification.** `scene_smoke_check.gd` now asserts after a completed T1
session that `session_decisions > 0`, `session_optimal == session_decisions`
(optimal autoplay scores 100%), the label is visible, and its text equals
`"Decisions: M/N"`. Full 17-tool suite re-run: all pass; `sim_validate`
baselines byte-identical (1.009% / 0.507% / -0.561%); no save residue.

## M31 — Insurance forfeited in a normal (non-natural) hand

Found: `GameLoop._play_dealer_and_settle` carries a dedicated
insurance-forfeiture branch (GameLoop.gd:694-696: `profit -= _insurance_bet`,
`wagered += _insurance_bet`) that fires when insurance was taken on an Ace
upcard but the dealer does **not** hold a natural, so the round plays out to
normal resolution. This branch had no loop-level coverage: M24's loop test
(`insurance_check._check_loop_honors_insurance_payout`) drives only the
dealer-BJ path through `_settle_natural` (where insurance *wins*), and the
insurance tool's no-BJ case uses a standalone `_play_insurance_hand` helper
rather than the real loop.

Cause: The two settlement paths for insurance (`_settle_natural` win side and
`_play_dealer_and_settle` lose side) were each only half-covered.

Fix: Added `game_loop_check.gd` `_check_insurance_loss_normal_path()` + helper
`_drive_insurance_normal()`. It rigs an Ace upcard / 7 hole (dealer 18, no
natural) with a two-card 17 hard player hand (no split, no double, no
surrender), drives the same hand twice with the same seed — once taking
insurance, once declining — and asserts three things:
1. take-run `last_wagered() == 2.0` (main 1.0 + insurance side-bet 1.0, so the
   side-bet is counted in wagered on the normal path);
2. decline-run `last_wagered() == 1.0` (no side-bet when declined);
3. the net-P&L delta between the two runs is exactly `-1.0` (the forfeited
   insurance stake), isolating the side-bet effect from the identical main
   hand.

No production code changed; test-only. The branch is already correct — this
pins it so a future refactor can't drop the side-bet from the normal-path P&L.

**Verification.** `game_loop_check` now prints three new PASS lines
(`wagered counts the side-bet (2.0)`, `no side-bet when declined (1.0)`,
`side-bet forfeited when no dealer BJ (delta -1.0)`). Full 17-tool suite
re-run: all pass; `sim_validate` baselines byte-identical
(1.009% / 0.507% / -0.561%); no save residue.

## M32 — H17 dealer soft-17 loop coverage

Found: `GameLoop._dealer_should_hit` (GameLoop.gd:739-745) hits a soft 17 only
when `config.dealer_hits_soft_17` is true. No tool ever drove the loop with
that flag on: every tool config and `sim_validate` use S17 (`dealer_hits_soft_17
= false`). The H17 branch was therefore untested at the loop level, even though
the hardest "real" tables (T3 Two-Deck, T4 Four-Deck, T5 Six-Deck) are H17.
The strategy side (the *player's* H17 basic-strategy adjustment,
`StrategyEngine._apply_h17`) was already covered by `deviation_check`; only
the *dealer* play was missing.

Cause: Loop-level tests historically pinned S17 behavior, and the dealer
soft-17 hit was assumed exercised by the strategy tests (it is not — the
strategy tests only assert the player's recommended action, never that the
dealer actually drew).

Fix: Added `game_loop_check.gd` `_check_h17_dealer_soft17()` + helper
`_drive_soft17_dealer()`. Rigs a deterministic hand — upcard 6 + hole Ace =
soft 17, player hard 18 (10+8, stand; not an Illustrious-18 deviation target,
so the player action is identical under both rules) — and settles it twice with
the same seed:
- S17 (`dealer_hits_soft_17 = false`): dealer stands at 17, player's 18 wins →
  net `+1.0`.
- H17 (`dealer_hits_soft_17 = true`): dealer draws (rigged 3) to 20, player's
  18 loses → net `-1.0`.

The exact net P&L in each run proves the dealer did (or did not) hit, using
only `last_net()` — no production code change.

**Verification.** `game_loop_check` now prints two new PASS lines
(`H17: S17 dealer stands on soft 17, player 18 wins (net +1.0)`,
`H17: H17 dealer hits soft 17 to 20, player 18 loses (net -1.0)`). Full
17-tool suite re-run: all pass; `sim_validate` baselines byte-identical
(1.009% / 0.507% / -0.561%); no save residue.

## M33 — Dead-code cleanup: remove `CHGameLoop.dealer_hand()`

Found: `CHGameLoop.dealer_hand()` (returned `_dealer`) had zero callers across
scripts, scenes, and tools. The scene renders the dealer via `dealer_upcard()`
and `dealer_hole()` (both still in use), so this combined accessor was never
wired.

Cause: Leftover from early UI scaffolding; the per-card accessors superseded it.

Fix: Removed `dealer_hand()` from `GameLoop.gd`. No behavior change — the
remaining accessors (`dealer_upcard`, `dealer_hole`, `current_hand`,
`all_hands`) cover every render path.

**Verification.** Full 17-tool suite re-run: all pass; `sim_validate` baselines
byte-identical (1.009% / 0.507% / -0.561%); no save residue.

## M34 — Player natural (blackjack) win settlement + `blackjack_payout` config flow

Found: `GameLoop._settle_natural` has three branches: player BJ push
(`main += 0.0`), player BJ win (`main += bet * blackjack_payout`), and non-BJ
(`main -= bet`). M24's loop test drove the dealer-BJ / insurance side
(`main -= bet` + insurance payout) but no dedicated loop test asserted the
player-natural-win branch or that `blackjack_payout` flows through
`_settle_natural`. The sim covers this indirectly, but a dedicated pin keeps the
config-lever path honest.

Cause: Settlement-branch coverage had only been extended incrementally; the
player-win branch of `_settle_natural` was never isolated in a tool.

Fix: Added `game_loop_check.gd` `_check_natural_win_payout()` +
`_drive_natural_win(payout, seed)`. Rigs a two-card player natural
(Ace+10) vs a 7/5 dealer (no dealer natural, no insurance), settles it at two
payout ratios, and asserts:
- `blackjack_payout = 1.5` (3:2) → net `+1.5` on a 1-unit bet.
- `blackjack_payout = 1.2` (6:5) → net `+1.2`, proving the config value flows
  through `_settle_natural` rather than a hardcoded constant.

No production code change; test-only.

**Verification.** `game_loop_check` now prints two new PASS lines
(`natural win: 3:2 payout pays +1.5 on a winning blackjack`,
`natural win: 6:5 payout pays +1.2 (config flows through)`). Full 17-tool suite
re-run: all pass; `sim_validate` baselines byte-identical
(1.009% / 0.507% / -0.561%); no save residue.

## M35 — Split-ace settlement P&L pin

Found: `multi_hand_check` asserts that split aces produce two one-card
`split_ace` hands but never settles them through the full loop. The P&L path
for split-ace hands (each auto-stands after one card, then settles against the
dealer) was therefore not isolated in any tool.

Cause: Split-ace settlement is exercised implicitly by the bankroll invariant
in the 1000-hand determinism drive, but a dedicated pin makes the expected
net and wagered values explicit and guards against regressions in
`_advance_to_next_hand`'s split-ace skip logic or `_play_dealer_and_settle`.

Fix: Added `game_loop_check.gd` `_check_split_ace_settlement()`. Rigs A+A vs
10/8 dealer (18): split aces each receive a 6 (soft 17), both auto-stand,
both lose to dealer 18. Asserts `wagered == 2.0` (two hands × 1.0 base bet)
and `net == -2.0` (both lost). No production code change; test-only.

**Verification.** `game_loop_check` prints two new PASS lines. Full 17-tool
suite: all pass; `sim_validate` byte-identical; no save residue.

## M36 — Push settlement pin

Found: The push branch in `_play_dealer_and_settle` (`# else push`, no profit
change) had no dedicated pin. A push settles with `profit` unchanged and
`wagered` equal to the staked amount.

Cause: No rig existed that would force a tie between player and dealer totals
at the loop level.

Fix: Added `game_loop_check.gd` `_check_push_settlement()`. Rigs a player hard
18 (10+8) vs a dealer that hits from 13 (5 up, 8 hole) to 18. Player stands
(optimal on 18). Asserts `net == 0.0` and `wagered == 1.0`. No production code
change; test-only.

**Verification.** `game_loop_check` prints one new PASS line. Full 17-tool
suite: all pass; `sim_validate` byte-identical; no save residue.

## M37 — Late-surrender timing invariant pin

Found: `CHTableConfig.late_surrender_only` is set on tiers 4–6 but is never
read by any code path. The loop already only permits surrender on a fresh
two-card hand (`_can_surrender` requires `card_count == 2`), which *is*
late-surrender timing. The flag is therefore redundant by construction, but
the invariant it describes was not pinned by any test.

Cause: The flag was introduced as forward-looking documentation; the
implementation naturally only supports late surrender. No test confirmed
that surrender disappears after the hand grows beyond two cards.

Fix: Added `game_loop_check.gd` `_check_late_surrender_timing()`. Rigs a
two-card hard 16 vs 10 (surrenderable). Asserts:
1. Surrender is offered and is the optimal action on the fresh two-card hand.
2. After the player draws a third card (hitting to 18), surrender is no
   longer offered.

No production code change; test-only. Documents that `late_surrender_only`
is structurally satisfied by the existing `card_count == 2` gate.

**Verification.** `game_loop_check` prints one new PASS line. Full 17-tool
suite: all pass; `sim_validate` byte-identical; no save residue.

## M38 — Heat-tell loop wiring (bet tell + insurance tell)

Found: `heat_check` validates the `CHHeatSystem` model (tell/decay/sensitivity/
backoff latch) and the loop's backoff-resolution path, but nothing verified that
`CHGameLoop` actually *records* a tell the moment the player makes one. The two
cleanly-observable tell triggers in the loop — the big-bet-on-hot-count tell
(`place_bet`, GameLoop.gd:330) and the insurance-on-hot-count tell
(`_apply_insurance`, GameLoop.gd:483) — were unverified.

Cause: The model was tested in isolation (`on_tell` called directly) and the
loop wiring was assumed, never asserted. A regression that stopped the loop
from calling `on_tell` (or gated it on the wrong condition) would pass every
existing tool.

Fix: Added `game_loop_check.gd` `_check_heat_tell_triggers()` + helpers
(`_rig_heat_loop`, `_heat_delta`, `_heat_delta_insurance`). Each tell is paired
with a negative control that must add **zero** heat:
- **Bet tell**: hot count (TC 5) + 4-unit bet → `+BET_TELL_GAIN` (6.0). Controls:
  hot count + 1-unit bet → 0 (below `BET_TELL_MIN_UNITS`); cold count + 4-unit
  bet → 0 (below `BET_TELL_TC`).
- **Insurance tell**: hot count + take insurance → `+INSURANCE_TELL_GAIN` (4.0).
  Control: hot count + decline insurance → 0.

The **deviation tell** (`_apply_hand`, GameLoop.gd:525) is left unpinned: it
fires inside a hand that then settles, so the per-hand decay (`DECAY_PER_HAND`)
and the 0-floor clamp mask its magnitude from an observable heat delta without
substantially more scaffolding (pre-seeding heat past the first `begin_hand`,
which re-seats heat to the tier floor). It remains covered indirectly.

No production code change; test-only.

**Verification.** `game_loop_check` prints five new PASS lines (bet-tell + two
controls, insurance-tell + control). Full 17-tool suite: all pass;
`sim_validate` byte-identical (1.009% / 0.507% / -0.561%); no save residue.

## M39 — Deviation-tell loop wiring (completes the M38 heat-tell set)

Found: M38 pinned the bet and insurance heat tells at the loop level but left
the deviation tell (`GameLoop._apply_hand`, GameLoop.gd:525) unpinned. At the
default tier sensitivity (1.0) that tell is unobservable end-to-end: the gain
(DEV_TELL_GAIN 2.0) is fully absorbed by the per-hand decay (DECAY_PER_HAND
3.0) at settle, so `heat` returns to the floor either way. `deviation_check`
pins `is_counting_deviation` at the engine level but never drives the loop's
`on_tell` call.

Cause: The deviation tell's net heat contribution is negative at default
sensitivity, so no existing loop-level test could distinguish "tell fired"
from "tell never fired".

Fix: Added `game_loop_check.gd` `_check_deviation_tell()` + helper
`_drive_dev_tell(up_rank, hole_rank)`. Rigs a hot count (running_count 4 on a
1-deck shoe, TC floor = 4) and `heat_sensitivity_multiplier = 3.0` so the
tell gain (2.0 * 3.0 = 6.0) out-runs the 3.0 decay and leaves a measurable
residue:
- Deviation run: two-card hard 13 vs upcard 10 -> I18 stand deviation; optimal
  play stands, `action == opt` and `is_counting_deviation` true -> tell fires.
  Final heat 6.0 - 3.0 = 3.0.
- Control run: same hand vs upcard 5 -> no I18 rule, no tell. Final heat 0.0
  (decay is a no-op when heat is 0).

Asserts dev heat == 3.0 and control heat == 0.0. No production code change;
test-only. Completes the loop-level pin for all three heat-tell triggers
(bet, insurance, deviation).

**Verification.** `game_loop_check` prints two new PASS lines
(`heat dev-tell: ... leaves 3.0 heat residue`,
`heat dev-tell control: no deviation leaves 0.0 heat residue`); the tool now
runs 27 checks. Full 17-tool suite: all pass; `sim_validate` byte-identical
(1.009% / 0.507% / -0.561%); no save residue.

## M40 — Tilt detection (`check_tilt`) unit pins

Found: `CHDisciplineSystem.check_tilt()` — the loss-chasing detector that
drives the user-facing "Tilt: loss-chasing detected" HUD warning — had zero
test coverage. It's a non-trivial 3-step pattern detector (two consecutive
losses whose bet sizes strictly rise into the third entry) with multiple
boundary conditions. `discipline_check.gd` already tests the other
DisciplineSystem invariants (recovery scaling, cover cap, outcome
independence) at model level; tilt was simply never added.

Cause: Oversight when the tilt feature was built; the HUD wiring was tested
indirectly (label visibility in scene_smoke_check) but the detection
algorithm itself was not pinned.

Fix: Added five checks to `discipline_check.gd` (Check 4a–4e):
- 4a: fewer than 3 bets → no tilt
- 4b: canonical positive (loss→loss with strictly rising bets) → tilt
- 4c: two consecutive losses but flat bet on the 2nd → no tilt
- 4d: rising bets but a win between the two losses → no tilt
- 4e: pattern in the last 3 of a longer history (older entries don't
  interfere) → tilt

No production code change; test-only.

**Verification.** `discipline_check` prints five new PASS lines. Full
17-tool suite: all pass; `sim_validate` byte-identical
(1.009% / 0.507% / -0.561%); no save residue.

## M41 — Real file save/load round-trip + tier auto-unlock via EMA

Found: `game_state_check` already covered an *in-memory* `serialize()`/
`deserialize()` round-trip, but never exercised the actual `FileAccess`
write/read path that the game uses at runtime (`save(path)` /
`load_game(path)`). Separately, `_unlock_qualified_tiers()` — the function
that appends tiers to `unlocked_tiers` as the EMA rating climbs past
thresholds — had never been pinned: the tier-gating check hand-set
`lifetime_stats["skill_rating"]` and called `is_tier_unlocked()` directly,
bypassing the `end_session` → EMA → auto-unlock path entirely.

Cause: The in-memory round-trip was written first (M9) and the file I/O path
was assumed equivalent. The tier-gating check tested the read side
(`is_tier_unlocked`) without driving the write side (`_unlock_qualified_tiers`
via `end_session`), so a regression that stopped tiers from being *persisted*
would not be caught.

Fix: Added `game_state_check.gd` `_check_save_load_file_roundtrip()`:
- Drives rating up through **six real `end_session("cash_out", 100.0, false)`
  calls** (no hand-set), so the EMA produces ~73.79 and the engine's own
  `_unlock_qualified_tiers` appends tiers 2/3/4 to `unlocked_tiers`.
- Asserts tiers 2/3/4 are in the array and tier 5 is not.
- Sets heat floor (tier 3), unlocks a system (`hi_lo`), unlocks a cosmetic
  (`theme_neon`), then writes to a **real file** via `save(p)`.
- Reads the file back with `load_game(p)` into a fresh `CHGameState` and
  asserts all of the above survive: rating, heat floor, system, cosmetic,
  and the auto-unlocked tiers.
- Verifies `deserialize("this is not json {")` returns `false` (no crash).
- Verifies `deserialize("{}")` returns `true` with defaults (rating 0,
  tiers `[1]`).
- `_cleanup_save()` now also removes the check-save temp file.

No production code change; test-only.

**Verification.** `game_state_check` now prints two new PASS lines
(`save/load file round-trip preserves rating, tiers, heat floor, systems,
cosmetics`, `deserialize: malformed -> false, {} -> defaults`); the tool
now runs 7 checks. Full 17-tool suite: all pass; `sim_validate`
byte-identical (1.009% / 0.507% / -0.561%); no save residue (both the
default and check-save temp files cleaned up).

## M42 — Early/late surrender path (`late_surrender_only` made live)

Found: `CHTableConfig.late_surrender_only` existed as a field and was set on
the T4/T5/T6 tiers (`true`) and left `false` on the T1 default, but
**nothing read it** — `StrategyEngine._apply_surrender` returned the same
chart in both modes, and `CHGameLoop` settled a dealer natural before the
player could surrender. Early surrender was therefore dead: a
`late_surrender_only = false` table behaved identically to a late-only
table.

Cause: The field was authored in M6 as forward-looking config but the engine
and loop were never taught to branch on it; `spot_check` (default config =
early mode) only pins 16v10 and a 3-card 16, both of which behave the same
in early and late mode, so the gap was invisible to the suite.

Fix:
- `StrategyEngine._apply_surrender`: after the late chart (16 vs >=9,
  15 vs 10 — unchanged, applies to both modes), add the early-only entries
  `15 vs 9`, `14 vs 10`, `13 vs 10` gated on `!config.late_surrender_only`.
- `CHGameLoop`: new `_early_surrender_phase` flag (reset in
  `begin_hand`). In `_after_insurance`, when the dealer holds a natural,
  there is no player natural, and `_can_enter_early_surrender()` holds
  (surrender allowed, not late-only, single two-card hard root), the loop
  enters the hand phase with only `ACT_SURRENDER` / `ACT_STAND` offered
  instead of auto-settling the natural. The hole stays hidden until
  settlement, matching real early surrender. `_play_dealer_and_settle`
  already yields −0.5 on a surrendered hand and −1.0 to a natural when the
  player stands, so no settlement change was needed.

Scope: the sub-phase fires only for the natural case (the only place
early vs late actually differ). Non-natural hands in early mode already
offer surrender through the existing hand-phase path.

**Verification.** `game_loop_check` gains `_check_early_surrender()` with a
`_surrender_loop()` rig helper and four new PASS lines: 15v9 surrenders
early but not late (chart differential); early surrender settles at −0.5;
14v10 vs a dealer natural enters the sub-phase with exactly
`[surrender, stand]` offered, surrenders for −0.5; the late-mode control
auto-settles the same hand at −1.0 with no surrender. Full 17-tool suite:
all pass; `sim_validate` byte-identical (1.009% / 0.507% / −0.561%); no save
residue.

## M43 — Dead-code cleanup: `available_bet_units` + `is_hot`

Found: A whole-project caller audit found two public methods with **zero
callers** in `scripts/`, `scenes/`, or `tools/`:
- `CHGameLoop.available_bet_units()` — redundant with the `MAX_BET_UNITS`
  constant the scene already iterates (`Main.gd` builds the bet-unit buttons
  from the constant, not the method).
- `CHHeatSystem.is_hot()` — returned `heat >= BACKOFF_THRESHOLD`, i.e. the
  same condition that `on_tell()` latches into `pending_backoff`; the loop
  reads that latch via `needs_backoff()` → `has_pending_backoff()`, never
  `is_hot()`.

Cause: Both were authored as convenience/public-interface surface in early
milestones but the loop/scene were built around the underlying state
(`MAX_BET_UNITS`, `pending_backoff`) instead, leaving the wrappers orphaned.
Neither is a defect (behavior was correct); they were simply unused and
`is_hot` additionally duplicated the backoff-latch predicate.

Fix: Removed both methods. No production behavior, config, or sim change.

**Verification.** Both files parse-check clean; a project-wide grep confirms
no remaining references to `is_hot` or `available_bet_units`. Full 17-tool
suite: all pass; `sim_validate` byte-identical (1.009% / 0.507% /
−0.561%); no save residue.

## M44 — Bet-ramp step pin (all four `_bet_for_tc` steps)

Found: `css_check` pins only the two endpoints of the bet ramp — the CSS
floor (flat 1) and the hot end (6 on a hot count). The two middle steps
(2 units at `tc 0–1`, 4 units at `tc 2–3`) were never directly asserted.
The 4-step mapping in `CHGameLoop._bet_for_tc` (and its mirror
`sim_validate._bet_for_tc`) is the single most important counting mechanic
in the trainer: bet sizing off the floored true count is the whole point. A
regression that flattened the ramp to binary (1 vs 6) or re-steps the
boundaries would silently under-teach or over-teach staking, and no tool
would catch it.

Cause: `css_check` was written to prove CSS *flattens* the ramp, so it only
needed one live point (the hot 6) as a control; the intermediate steps were
assumed covered by the 1000-hand `game_loop_check` drive, which exercises
the ramp but never asserts a specific step for a specific TC.

Fix: Added `game_loop_check.gd` `_check_bet_ramp()` + a `_rig_tc_loop(tc)`
helper (mirrors `css_check._hot_hand`: set `running_count`/`decks_remaining`
directly, then `begin_hand()` recomputes `_tc`). Pins all four steps at
their boundary TCs: `-2→1, 0→2, 1→2, 2→4, 3→4, 4→6`.

No production change; test-only.

**Verification.** `game_loop_check` gains a new PASS line (`bet ramp:
tc -2/0/1/2/3/4 -> 1/2/2/4/4/6 (all 4 steps pinned)`); now runs 32 checks.
Full 17-tool suite: all pass; `sim_validate` byte-identical (1.009% /
0.507% / −0.561%); no save residue.

## M45 — Survival-mode end-path pin

Found: `lifecycle_check` pinned `practice_complete` and `cash_out` end paths
but not `survival_complete`. The survival branch (`GameState.on_shoe_finished`
lines 114-116) is a structural twin of practice — same `on_shoe_finished`
path, different `end_session` reason — but had no dedicated pin. A regression
swapping the reason string, or breaking the `shoes_this_session >=
practice_shoes_required` check for survival, would go undetected.

Cause: The practice check was written first (M13) and the survival branch was
added as a sibling without a matching test.

Fix: Added `lifecycle_check.gd` `_check_survival_completion()`:
`start_session(1, MODE_SURVIVAL, 0, 2)`, drives hands until the session ends,
asserts `last_end_reason == "survival_complete"`, `shoes_this_session >= 2`,
`begin_hand` refuses afterward, and `session_ended` fires exactly once after
the session is inactive.

No production change; test-only.

**Verification.** `lifecycle_check` gains a new PASS line (`survival mode
completes after 2 shoes (reason survival_complete, single session_ended)`);
now runs 4 checks. Full 17-tool suite: all pass; `sim_validate`
byte-identical (1.009% / 0.507% / −0.561%); no save residue.

## M46 — Shoe composition, penetration boundary, and reshuffle determinism

Found: `CHShoeManager` had no dedicated tool. Every other tool *assumes* a
correct shoe but none asserted its invariants directly:
- **Composition**: that `build(config)` holds exactly `deck_count*52` cards
  with each of the 52 (suit, rank) combos appearing exactly `deck_count`
  times. A Fisher-Yates or build regression that duplicated/dropped a card
  would only surface indirectly (as drift) in `sim_validate`.
- **Penetration boundary**: that `penetration_reached()` flips at exactly
  `ceil(total * penetration)` dealt cards, and `should_reshuffle()` /
  `is_empty()` agree at the edges.
- **Reshuffle determinism + reset**: that two shoes built with the same seed
  are order-identical, `reshuffle(seed)` reproduces the exact order and
  resets `deal_index`, and a distinct seed yields a different order.

Cause: Shoe mechanics were written early (M1/M2) and exercised only through
the full loop; a dedicated invariant pin was never added.

Fix: Added `tools/shoe_check.gd` (18th tool) with four checks:
- `_check_composition`: a 2-deck shoe holds 104 cards, each of the 52 combos
  exactly twice; a 1-deck shoe is one full set.
- `_check_penetration_boundary`: 52-card shoe @ 0.70 → `penetration_reached`
  false at 36 dealt, true at 37; `should_reshuffle` follows; `is_empty`
  flips only at full exhaustion.
- `_check_determinism_and_reset`: same-seed order identity, `reshuffle`
  reset + order reproduction, distinct-seed divergence, and `decks_
  remaining_estimate` coarseness (0.5 step) + min-one-step floor.

No production change; test-only.

**Verification.** `shoe_check: ALL PASS`. Full 18-tool suite: all pass;
`sim_validate` byte-identical (1.009% / 0.507% / −0.561%); no save residue.

## M47 — CHHand unit invariants (total / soft / bust / pair / blackjack / upcard-key)

Found: `CHHand` — the value/predicate primitives every other tool and the
strategy engine depend on — had no dedicated pin. A regression in ace-down
(11→1) resolution, 10-value bucketing, or any predicate would only surface
as a secondary failure deep in `spot_check` / `sim_validate`, not as a clear
diagnostic. The multi-ace soft-total edge cases (A+A+9 = soft 21, A+K+K = hard
21, six aces + 5 = soft 21 never bust) were especially untested.

Cause: `CHHand` was written early and exercised only through the full loop and
strategy engine; no isolated unit pin was added.

Fix: Added `tools/hand_check.gd` (19th tool) with six checks:
- `_check_totals`: A+K=21, 10+10=20, A+9=20, 5+5+5=15, A+9+8=18 (ace-down),
  A+A+9=21, J+Q+K=30 (bust, no aces to drop), A+6=17 soft, six aces+5=21.
- `_check_soft`: A+K / A+9 / A+A+9 are soft; 10+10, 5+5+K, A+K+K, 3+4+5 hard.
- `_check_bust`: 10+10+5 busts; 20, soft-21 (6 aces+5), 21 don't.
- `_check_pair`: exactly two equal-rank cards; A+A pair; 10+K not a pair;
  three 9s / single card not a pair.
- `_check_blackjack`: A+K / K+A / A+K(13) blackjacks; A+9, 10+10, 10+10+A not.
- `_check_upcard_key`: ranks 10/11/12/13 collapse to 10; 9→9, 2→2.

No production change; test-only.

**Verification.** `hand_check: ALL PASS`. Full 19-tool suite: all pass;
`sim_validate` byte-identical (1.009% / 0.507% / −0.561%); no save residue.

## M48 — Ten-value pairs never split (`_pair_play` rank-match fix)

Found: `StrategyEngine._pair_play` had a real strategy defect. The "never
split tens" arm matched only `10, 13` (10s and Kings). Ranks 11 (Jack) and
12 (Queen) fell through to the `_` default and returned **"hit"** — so `J+J`
and `Q+Q` were played as hits instead of stood, which is wrong for any
blackjack variant (a 20 is never split). Confirmed by probe: 10+10→stand,
J+J→hit, Q+Q→hit, K+K→stand. The inconsistency was isolated to this one
function — `Card.is_ten_value()` and `Hand.is_blackjack()` already treat the
full 10–13 range correctly.

Cause: the match arm was written for the two "edge" ten-value ranks and the
middle face cards were omitted, not the intent to special-case them.

Fix: `StrategyEngine._pair_play` match arm broadened to `10, 11, 12, 13`
(all ten-value pairs → "stand"). No other change; `best_play`,
`best_play_no_split`, and the SplitResolver all inherit the corrected
decision.

Regression pin: `spot_check.gd` adds a legality block that asserts all four
ten-value pairs (10/10, J/J, Q/Q, K/K) return "stand" against a 5. `spot_check`
now runs 31 cells (was 27).

**Verification.** Full 19-tool suite: all pass; `spot_check` 31/31. The sim
baselines stay byte-identical (no-split 1.009%, split 0.507%, counting
−0.561%) — the J/J and Q/Q hands are rare enough that correcting hit→stand
does not move the 3-decimal aggregate edge, which also confirms the fix is
surgical. No save residue.

## M49 — Early-surrender sub-phase: optimal_action stays inside the offered set

Found: M42's early-surrender sub-phase restricts `available_actions()` to
`[surrender, stand]`, but `CHGameLoop.optimal_action()` still ran the general
PHASE_HAND path through `engine.best_play_no_split()`. For a two-card hard
hand the surrender chart does not cover (e.g. 12 hard vs up-10 with an Ace in
the hole), the engine returns `"hit"` — an action the sub-phase never
offers. Consequences: (1) the autopilot test driver would `apply_action("hit")`
against a known dealer natural; (2) `discipline.record_decision` would grade
the player against an unreachable "hit" optimal, skewing the session
"Decisions: X/Y" metric; (3) the invariant `optimal_action() in
available_actions()` was violated in that state.

Cause: M42 restricted the action list but left optimal computation on the
general hand path, which is only valid when the full action set
(hit/stand/double/surrender) is available.

Fix: `CHGameLoop.optimal_action()` PHASE_HAND now short-circuits when
`_early_surrender_phase` is true and returns `ACT_SURRENDER`
unconditionally. This is correct strategy, not just an invariant patch:
against a known dealer natural, the half-loss (−0.5) strictly dominates
standing (−1.0) or hitting (−1.0 or bust), so surrender is optimal for every
hand in the sub-phase. Late-surrender tables are unaffected (no sub-phase),
and the engine's surrender chart still governs the normal hand phase.

Regression pin: `game_loop_check.gd` gains
`_check_early_surrender_optimal_consistency()` — rigs 12 hard vs up-10 with
an Ace hole (dealer natural; hand NOT in the surrender chart, so the raw
engine says "hit"), asserts the sub-phase offers exactly `[surrender, stand]`,
that optimal is surrender, and that surrender settles at −0.5.

**Verification.** `game_loop_check` gains a new PASS line; now runs 33
checks. Full 19-tool suite: all pass; `sim_validate` byte-identical
(1.009% / 0.507% / −0.561% — the sim does not use `optimal_action()`); no
save residue.

## M50 — CHCountEngine unit invariants (true-count floor + deck clamp)

Found: `CHCountEngine` — the counting primitive every other system builds on
— had no dedicated pin. `count_check` covers the *accuracy-grading* system
(`CHCountAccuracySystem`) and `tables_check` covers per-card `count_value`,
but nothing asserted the engine's own math. The load-bearing case: the low-TC
"Illustrious 18" hit deviations (`tc <= -1` / `tc <= -2`) and the insurance
threshold (`tc >= 3`) are all keyed to `true_count_floor()`. If that function
ever truncated toward zero instead of flooring toward −∞, a true count of
−1.5 would read as −1 (so a `<= -2` deviation and the insurance boundary both
mis-fire), and the defect would only surface as subtle drift in `sim_validate`
rather than a clear diagnostic.

Cause: the engine was written early (M1) and exercised only through the loop
and the sim; its division/floor/clamp edge cases were never isolated.

Fix: Added `tools/count_engine_check.gd` (20th tool) with seven checks:
- `_check_reset_defaults`: fresh engine (RC 0, 1.0 deck, hi_lo, TC 0); `reset()`
  restores after mutation.
- `_check_record_accumulates`: `record_card` adds the card's `count_value` to
  the running count and returns that value (hi_lo 2-6/+1, 7-9/0, 10-14/−1).
- `_check_record_idempotent`: a card already `seen` returns 0 and does not
  re-count.
- `_check_true_count_division`: RC / decks_remaining for positive and negative RC.
- `_check_floor_toward_negative_infinity`: the critical pin — `floor(1.5)=1`,
  `floor(-1.5)=-2`, `floor(-2.0)=-2`, `floor(-0.5)=-1`, `floor(0.5)=0`. The
  two negative cases fail under a truncation-toward-zero regression.
- `_check_decks_clamp`: `set_decks_remaining` clamps to a 0.1 minimum
  (0.0→0.1, 0.04→0.1, 3.2→3.2), so a drained shoe reads as a large count.
- `_check_zero_decks_guard`: the `decks_remaining <= 0` branch returns the raw
  running count.

No production change; test-only.

**Verification.** `count_engine_check: ALL PASS`. Full 20-tool suite: all
pass; `sim_validate` byte-identical (1.009% / 0.507% / −0.561%); no save
residue.

## M51 — Double-after-split (DAS) gate pinned

Found: `CHTableConfig.allows_double_after_split` (DAS) is set on every tier and
enforced in two places — `StrategyEngine._enforce_double_legality` (degrades a
"double" to "hit" when a split hand faces a no-DAS table) and the sim's own
`_can_double` — but no tool pinned the *behaviour*. A regression that dropped
the `hand.is_split_hand and not config.allows_double_after_split` check would
let a split hand double on a no-DAS table, and it would surface only as subtle
edge drift in `sim_validate` (DAS hands are a small fraction of play), not as a
clear diagnostic. `tables_check` asserts the config flag is present on T1 but
never exercises the gate.

Cause: the gate was written early alongside the split machinery and verified
only indirectly; no engine-level pin for the split-hand branch was added.

Fix: test-only. `spot_check.gd`'s legality section gains a DAS pair. A
two-card hard 11 that is marked `is_split_hand` (a post-split sub-hand; basic
strategy doubles 11 vs any upcard ≤10) is run through `best_play_no_split`:
- DAS **on** (default `CHTableConfig`): must return "double".
- DAS **off** (`allows_double_after_split = false`): must return "hit".

This pins `_enforce_double_legality`'s split-hand branch directly.

**Verification.** `spot_check` 33/33 (was 31; +2 DAS cells). Full 20-tool
suite: all pass; `sim_validate` byte-identical (1.009% / 0.507% / −0.561%); no
save residue.

## M52 — Loop-level double-after-split gate pinned

Found: M51 pinned the engine's DAS gate (`StrategyEngine._enforce_double_legality`),
but the **loop** carries its own, independent gate: `CHGameLoop._can_double`
(`GameLoop.gd:401`). It is the single source of truth for three loop behaviors —
`available_actions()` (does the table show a "double" button), `optimal_action()`
(degrades an engine "double" to "hit" when illegal), and `_apply_hand`'s ACT_DOUBLE
branch (the only place the bet is actually doubled, `_bets[_idx] = bet * 2.0`).
No test exercised this loop gate. A regression here — e.g. dropping the
`h.is_split_hand and not config.allows_double_after_split` check, or the
`card_count() != 2` check — would let a split (or 3-card) hand show a double
button and double its bet on a no-DAS table, even though the engine and the sim
both say no. That would surface only as wagered/P&L drift, not a clear diagnostic.

Cause: the loop gate mirrors the engine gate but lives in separate code, so the
engine-level M51 pin does not protect it.

Fix: test-only. `game_loop_check.gd` gains `_check_das_loop_gate()`. It rigs a
no-DAS single-deck loop with a 7,7 vs up-7 opening; after the split the active
sub-hand is a two-card hard 11 (a "double" candidate on basic strategy). It
asserts:
- `available_actions()` does **not** include "double" (only `[hit, stand]`).
- `optimal_action()` degrades to "hit" (the engine's "double" is not offered).
- After settling the round under the autopilot, `last_wagered() == 2.0` — the
  two split hands at 1 unit each, confirming no double was applied.

This pins `_can_double`'s split-hand + card-count branches through the actual
loop, complementing M51's engine-level pin.

**Verification.** `game_loop_check` gains a new PASS line (34 checks). Full
20-tool suite: all pass; `sim_validate` byte-identical (1.009% / 0.507% /
−0.561% — the sim uses its own `_can_double`, not the loop's); no save residue.

## M53 — Full Illustrious-18 deviation table pinned at exact thresholds

Found: `CHStrategyEngine` encodes the complete Illustrious 18 (I18) deviation
set as 18 magic-number TC thresholds (`DEV_16V10_STAND_TC`, `DEV_15V10_STAND_TC`,
... `DEV_12V6_HIT_TC`, `DEV_11V10_STAND_TC`). These are the heart of the
counting trainer — a wrong threshold means the tool silently teaches the wrong
play at the wrong count. Prior coverage was partial: `spot_check` pins only 6 of
the 18 (and only in the "fires" direction, via `best_play`), and
`deviation_check` focuses on the surrender-is-not-a-tell distinction. The other
12 thresholds had no direct pin.

Cause: the deviation table was authored in one milestone; only a representative
slice was spot-checked rather than every boundary.

Fix: test-only. Added `tools/i18_check.gd` (21st tool). It pins all 18 I18
thresholds at their exact boundary using `is_counting_deviation()` (true exactly
when the I18 layer changes the play on top of the full non-deviation pipeline):
- High-TC stands (13-16 vs 9/10, soft 19 vs 9/10): fires at `tc == threshold`,
  silent at `tc == threshold - 1`.
- Low-TC hits (12-14 vs 4-6) and stand-instead-of-double (11 vs 10): fires at
  `tc == threshold`, silent at `tc == threshold + 1`.
A plain no-surrender S17 config is used so the base play is pure basic strategy
and no surrender/H17 rule interferes. An off-by-one in any threshold now fails
loudly instead of drifting in `sim_validate`.

**Verification.** `i18_check: ALL PASS (18/18 I18 thresholds pinned)`. Full
21-tool suite: all pass; `sim_validate` byte-identical (1.009% / 0.507% /
−0.561%); no save residue.

## M54 — Soft 18 vs 7/8 basic-strategy fix (S17 stand restored, H17 layer now load-bearing)

Found: `StrategyEngine._soft_play` returned "hit" for a soft 18 (A+7/A+8) against
dealer 7 **and** 8 in every configuration. Standard single-deck/S17 basic
strategy **stands** on soft 18 vs 7 and vs 8 (the dealer stands on 17, so the
player's 18 already has the edge; hitting only risks busting a natural 18). The
defect:

- On S17 tables (T1 Teaching and T2 Single-Deck — the default teaching paths) the
  player was incorrectly hitting soft 18 vs 7/8, losing EV on the exact hands a
  counting trainer should teach correctly.
- `_apply_h17` was supposed to flip soft-18-vs-7/8 from stand to hit for H17
  tables, but since the base already returned "hit" there, the H17 override was a
  **silent no-op**. The H17 layer was therefore not actually load-bearing.

Confirmed by probe: pre-fix `dk=7 S17=hit H17=hit` and `dk=8 S17=hit H17=hit`
(i.e. the H17 branch never changed anything).

Cause: the soft-18 branch was written with only `dk == 2 -> stand`; the 7/8 stand
cases were left to fall through to the `return "hit"` default, which is correct
for H17 but wrong for S17.

Fix: `StrategyEngine._soft_play` soft-18 branch now stands on `dk == 2 or
dk == 7 or dk == 8`. This is correct for S17 (dealer stands on 17). For H17
tables, `_apply_h17` still overrides the stand to "hit" for dk 7/8 (dealer hits
soft 17), so the H17 layer is now actually load-bearing. Double on soft 18 vs
3-6 and hit on vs 9/10 are unchanged.

Regression pins: `spot_check.gd` gains two S17 basic cells (`soft 18 vs 7 ->
stand`, `soft 18 vs 8 -> stand`) and two H17 legality cells asserting
`_apply_h17` overrides to "hit" on an H17 table for both 7 and 8. `spot_check`
is now 37/37 (was 33).

**Verification.** `spot_check` 37/37. Full 21-tool suite: all pass. `sim_validate`
now reads the corrected edge (this is a real strategy change, not byte-identical):
no-split **0.972%** (was 1.009%), split **0.468%** (was 0.507%), counting
**−0.615%** (was −0.561%) — all improved, confirming the corrected stand is
positive-EV. No save residue.

## M55 — Soft-total table fully pinned; soft-15 double range confirmed at 4-6

Found: only three soft cells had direct pins (`soft 18 vs 2/3/9`, `soft 19 vs 7`).
Every other soft-total double-down boundary (S15/S16/S17/S18/S19 across upcards)
was untested, so an off-by-one in a double range would only surface as subtle
drift in `sim_validate` — the same failure class as M48/M54. While auditing the
soft table, the soft-15 range was a live question: the engine doubles S15 vs
4-6, but many published multi-deck charts list S15 double 4-9.

Decision (tested, not assumed): a temporary `dk >= 4 and dk <= 9` change was
applied and measured in the calibrated sim, then reverted:
- S15 double **4-6** (current): no-split 0.972%, split 0.468%, counting −0.615%.
- S15 double **4-9** (candidate): no-split 1.037%, split 0.533%, counting −0.545%.

The candidate made all three edges *worse* by 0.06-0.07% on 500k hands each —
statistically significant, not noise. In this single-deck S17 engine the
narrower 4-6 range is the better play (doubling S15 vs 7/8 commits a single
card that busts on 8/9/10, and the gain vs the hit path does not make it up).
`_soft_play` soft-15 stays `dk >= 4 and dk <= 6`.

Fix: test-only. `spot_check.gd` gains 12 soft-table cells pinning the
double-down and stand/hit boundaries for S15-S19 (both inside and just outside
each double range, plus the S18 stand band 7/8 and S19 stand band vs 6).
`spot_check` is now 50/50 (was 37). No production change.

**Verification.** `spot_check` 50/50. Full 21-tool suite: all pass;
`sim_validate` byte-identical to M54 (0.972% / 0.468% / −0.615%); no save
residue.

## M56 — Hard-total table boundaries pinned in spot_check

Found: the hard-total table (`StrategyEngine._hard_play`, lines ~80-117) had
only four direct pins (`16 vs 6/7`, `12 vs 4/8`, `11 vs 10`, `10 vs 3`,
`9 vs 5`). The stand/hit split at the 6/7 upcard edge for 13/14/15, the
stand-only 4-6 band for 12, and the hit-vs-Ace corners for 10/11 were all
untested. An off-by-one in any of those (e.g. standing 15 vs 7, or a 12 that
stands vs 7) is exactly the defect class M48/M54 caught in the soft/hard
tables — it would not surface in `sim_validate` at 500k hands unless large,
and would silently corrupt the teaching tables.

Decision: test-only. `spot_check.gd` gains 16 hard-table cells pinning the
stand/hit edge at 6/7 for 13/14/15, the 12 stand-only 4-6 band (hit at 3 and
7), 11 vs A → hit (upcard key 14, not collapsed to 10), 10 vs 10/A → hit,
9 double-vs-3 and hit-vs-2/7, 8 → hit, and 17 vs A → stand. `spot_check`
is now 66/66 (was 50). No production change; the engine already returned
the correct action for every pinned cell.

**Verification.** `spot_check` 66/66. Full 21-tool suite: all pass;
`sim_validate` byte-identical to M54/M55 (0.972% / 0.468% / −0.615%);
no save residue.

## M57 — Pair decision table fully pinned in spot_check

Found: the pair decision table (`StrategyEngine._pair_play`, lines 152-186)
was almost entirely unpinned. `spot_check` had a single pair cell
(`pair 8s vs 5`); ten-value pairs were covered only in the legality section.
`split_check` covers resolver structure (ace one-card rule, resplit caps,
DAS-disabled path) but not *which* pairs the engine wants to split, double,
or hold. Every range boundary in `_pair_play` — 9s split 2-9, 7s split 2-7,
6s split 4-7, 5s double 4-9, 4s double 5-6, 3s/2s split 2-7, aces split all,
tens stand all — was therefore a silent off-by-one risk, the same failure
class M54/M55/M56 addressed for the hard/soft tables.

Decision: test-only. `spot_check.gd` basic section gains 30 pair cells
pinning each pair's range edges (just inside and just outside) plus the
always/never cases (aces split vs 2/10/A; 8s split vs 2/A; tens stand).
All 30 pass on the first run — the engine already returned the intended
action for every pinned cell, so no production change. `spot_check` is now
96/96 (was 66). The tool docstring's stale "12 basic-strategy cells"
description was updated to reflect the hard/soft/pair coverage.

**Verification.** `spot_check` 96/96. Full 21-tool suite: all pass;
`sim_validate` byte-identical to M54/M55/M56 (0.972% / 0.468% / −0.615%);
no save residue.

## M58 — Surrender decision table pinned in spot_check (late + early + gates)

Found: the surrender decision table (`StrategyEngine._apply_surrender`,
lines ~208-232) had no direct strategy-table pins. It was only exercised
indirectly: `game_loop_check` drove settlement P&L, late/early timing, and
the natural-dealer path through the full loop; `deviation_check` asserted
that surrender is not a counting tell; `spot_check` had two legality cells
(priority + the 2-card gate). The actual table — which hands surrender at
which upcards, and how the late/early split changes the set — was never
pinned cell-by-cell.

Decision: test-only. `spot_check.gd` gains a surrender section with two
configs (`late_surrender_only` true/false) and 20 cells:
- Late: 16 vs 9/10/A and 15 vs 10 surrender; 16v8, 15v9, 14v10, 13v10 do not.
- Early: the late set plus 15 vs 9, 14 vs 10, 13 vs 10; 16v8, 14v9, 13v9,
  15v8 do not.
- Gates: a soft 16 (A+5) vs 10 does not surrender (soft hands are excluded);
  a pair 8s vs 10 splits instead of surrendering.

All 20 cells pass on the first run. The engine's table matches the standard
S17/3:2/DAS late and early surrender sets exactly — no production change.
`spot_check` is now 117/117 (was 96).

Note: a few "standard" early-surrender cells (13 vs A, 14 vs 9/A, 15 vs A)
are intentionally NOT in the engine's early set; this is a conservative
subset, not a defect, and is left as-is.

**Verification.** `spot_check` 117/117. Full 21-tool suite: all pass;
`sim_validate` byte-identical to M54/M55/M56/M57 (0.972% / 0.468% / −0.615%);
no save residue.

## M59 — Multi-hand settlement outcomes pinned in multi_hand_check

Found: multi-hand settlement (T4-T6 run 2-3 hands against one shared dealer)
was only pinned for structure and wager — `multi_hand_check` confirmed hand
counts and that `wagered = spots × bet`, and `sim_validate` never plays
multi-hand. The actual P&L paths (a dealer bust paying EVERY spot, an all-push
round netting zero, and the insurance side-bet scaling with spot count) were
untested. A settlement bug there (e.g. paying only the first hand on a dealer
bust, or charging one spot's insurance on a multi-spot round) would surface
only in T4+ gameplay, not in any existing tool.

Decision: test-only. `multi_hand_check.gd` gains three outcome probes:
- Dealer bust pays every spot: 2× hard-17 vs up-7; dealer 7+7 draws an 8 → 22
  bust. Each 17 wins. `net = +2 × bet`, `wagered = 2 × bet`.
- All-push round nets zero: 2× hard-17 vs up-7 with a hard-17 dealer (S17
  stands). Both push. `net = 0`, `wagered = 2 × bet`.
- Insurance scales with spot count: 2 spots, dealer Ace/10 (BJ), base bet 4.
  The side-bet is `spots × max(1, base/2) = 4` (not one spot's worth). On a
  dealer BJ the 2:1 insurance (+8) exactly offsets the two lost main bets
  (−8). `net = 0`, `wagered = 12` (= 2×4 main + 4 insurance).

All three pass on the first run — the multi-hand settlement math is correct
(settles each hand against the shared dealer, scales insurance with the spot
count). No production change. `multi_hand_check` now covers outcomes, not just
structure.

**Verification.** `multi_hand_check` ALL PASS. Full 21-tool suite: all pass;
`sim_validate` byte-identical to M54-M58 (0.972% / 0.468% / −0.615%);
no save residue.

## M60 — Soft 17 double range extended to 3-7 (sim-validated)

Found: `StrategyEngine._soft_play` soft-17 (A6) doubled only vs 3-5 and hit
everything else. Standard S17 single-deck basic strategy doubles soft 17 vs
3-7 (dealer hits to 17, so a doubled 17 that improves often wins; vs a dealer
upcard of 6/7 the double is +EV). The range was a silent off-by-N the same
class as M54 — untested, and soft-17 cells were only half-pinned in
`spot_check` (vs 3 double, vs 6 hit).

Decision (tested, not assumed): ran the calibrated sim against candidate
soft-17 policies, 500k hands each, seed 20260906:
- **3-5 (prior)**: no-split 0.972%, split 0.468%, counting −0.615%.
- stand 2 + double 3-7 (full standard): no-split 0.975%, split 0.469%,
  counting −0.598% — all three *worse*. The stand-vs-2 piece is a net loss in
  this single-deck S17 engine (dealer 2 is weak enough that hitting the A6 is
  not worth protecting the 17, and it costs more than it saves).
- **double 3-7, hit 2/8-A (chosen)**: no-split 0.954%, split 0.441%,
  counting −0.627% — all three *better*.
- double 3-8, hit 2/9-A: no-split 0.970%, split 0.456%, counting −0.616% —
  worse again, so 7 is the upper edge.

Fix: `StrategyEngine._soft_play` soft-17 branch now `dk >= 3 and dk <= 7 ->
"double"`, hit otherwise (including vs 2). Sim baselines shift accordingly.

Regression pins: `spot_check.gd` soft-17 block now pins the full boundary —
vs 2 hit, vs 3 double (low edge), vs 6 double, vs 7 double (high edge), vs 8
hit. `spot_check` is now 120/120 (was 117). `sim_validate.gd` docstring
baseline updated to the post-M60 values.

**Verification.** Full 21-tool suite: all pass. `sim_validate` now reads
**0.954%** / **0.441%** / **−0.627%** (was 0.972% / 0.468% / −0.615%) — all
three improved, confirming the wider double range is positive-EV. No save
residue.

## M61 — Multi-seed A/B probe (sim_multiseed) + M60 soft-17 3-7 re-validated

Found: M60's soft-17 3-7 decision rested on a single 500k-hand seed
(20260906). The no-split edge has a standard error of ~0.15-0.20% at that
sample size, so a ~0.02% move can be seed noise. No tool existed to test a
strategy change across multiple seeds and average out that variance.

Fix: new `tools/sim_multiseed.gd` (22nd tool). Runs the same deterministic
no-split simulation over a set of user-supplied seeds (via `--` args) and
prints the per-seed edge plus the mean, with a sanity band (0.2-1.8%) so the
sim core is verified. With no args it runs a fast 50k-hand smoke default so it
stays green in the full suite. This makes future strategy A/B tests reproducible
and statistically sound.

Re-validation of M60 (paired, 6 seeds, 400k hands each):
- soft-17 **3-5 (prior)**: mean no-split edge 0.8217%.
- soft-17 **3-7 (M60, current)**: mean no-split edge 0.8130% — lower.
- Per-seed: 3-7 wins on 5 of 6 seeds (20260906, 1, 7, 42, 20260001); the single
  outlier (seed 12345) favored 3-5 by 0.008%. Consistent sign across seeds
  confirms the 3-7 choice is a real ~0.009% improvement, not seed luck.

No production change this pass (engine already at 3-7 from M60); the tooling
and its verification are the contribution. `spot_check` remains 120/120.

**Verification.** `sim_multiseed` standalone green (smoke default, 1 seed
0.870%); full 22-tool suite: all pass; `sim_validate` byte-identical to M60
(0.954% / 0.441% / −0.627%); no save residue.

## M62 — H17 baseline established + H17 soft-17 vs 7 candidate rejected

Found: T3-T6 tiers all use H17 (dealer hits soft 17), yet `sim_validate` only
exercises S17. The H17 path (`_apply_h17` flipping S18→hit vs 7/8, plus the
dealer-hit-soft-17 settlement logic in `GameLoop._dealer_should_hit`) had no
sim-level validation. Additionally, it was unclear whether the S17-optimal
soft-17 double range (3-7, per M60) remains optimal when the dealer hits soft
17.

Fix: extended `tools/sim_multiseed.gd` with a `ruleset` argument (`s17` or
`h17`). The H17 variant sets `dealer_hits_soft_17 = true`, exercising both the
`_apply_h17` strategy layer and the H17 dealer settlement path.

H17 baseline (6 seeds, 400k hands each, no-split):
- Per-seed edges: 1.1601, 1.1266, 0.9390, 1.0191, 1.1176, 0.9937
- Mean: 1.0601% (range 0.94–1.16)

H17 soft-17 vs 7 candidate (hit instead of double):
- Mean: 1.0594% vs baseline 1.0601% — difference 0.0007%, well within noise.
- 5/6 seeds improved by 0.0007–0.0084%; one seed worsened by 0.0115%.
- **Rejected**: the effect is not statistically meaningful. The engine's
  existing 3-7 double range is retained for H17 (no `_apply_h17` change).

No production change. `spot_check` remains 120/120.

**Verification.** Full 22-tool suite: all pass; `sim_validate` byte-identical
to M60/M61 (0.954% / 0.441% / −0.627%); no save residue.

## M63 — I18 deviation gate on H17 + counting-systems sim tool

Found: two issues, discovered by building a new tool:

1. **I18 deviations applied on H17 tables** — `StrategyEngine._apply_deviation`
   was gated only by `play == "surrender"` and `hand.is_pair()`. The 18
   Illustrious thresholds are calibrated for **S17 / 3:2 / DAS / Hi-Lo**, yet
   the engine applied them to every `CHTableConfig`, including the H17 tiers
   (T3–T6) and to Hi-Opt II / KO counting systems whose true-count scale differs
   from Hi-Lo's. This made the counting strategy a **net loss** on T5
   (6-deck H17 Hi-Opt II): the new sim showed counting at 2.64% vs basic at
   1.29% — the counter was 1.35% *worse* than the flat-bet baseline.

2. **No counting-system sim tool** — `sim_validate` hard-wires Hi-Lo on the
   full (split + insurance) config; there was no tool to verify that counting
   actually beats basic on a tier's *real* table config, or to catch the
   defect in #1.

Fix:
- `StrategyEngine._apply_deviation` now early-returns when
  `config.dealer_hits_soft_17` is true. H17 tiers fall back to pure basic
  strategy + bet-sizing (no S17 deviations). S17 behaviour is unchanged
  (`sim_validate` stays at 0.954 / 0.441 / −0.627).
- New `tools/sim_counting_systems.gd` (23rd tool): runs a live counting sim
  (bet ramp + I18 + count-based insurance) vs a flat-bet basic control on a
  tier's real `CHTableConfig.for_tier(tier)` table. T5 counting dropped from
  2.64% → 1.05% (now ≈ basic 1.05%, within the "not clearly worse" guard).
  Assertions: counting must not be clearly worse than basic (0.30% tolerance)
  on any tier; S17 single-deck tiers must show a clear counting advantage.
  Smoke default: 100k hands, Tier 1, 1 seed.
- `deviation_check.gd` gains two H17 gate pins: the same hands that are I18
  stand deviations on S17 (13 v 10, S19 v 9 at TC 3) must fall back to basic
  "hit" on H17 and report `is_counting_deviation = false`. 8/8 checks pass.

**Verification.** Full 23-tool suite: all pass. `sim_validate` unchanged at
0.954 / 0.441 / −0.627. `sim_counting_systems` T5: counting 1.0505% vs basic
1.0524% (was 2.64% vs 1.29% pre-fix). T1: counting −0.54% vs basic 0.38%
(strict S17 single-deck assertion passes). No save residue.

## M64 — Survival-mode target-bankroll leak + tier/mode navigation pins

Found: two issues in the `Main.gd` UI layer, which had been smoke-tested only
for construction + count-check + practice-completion, leaving the tier/mode
switching paths untested:

1. **Survival-mode bankroll goal leak** — `Main._on_mode_selected` always
   passed `START_TARGET` (150) to `_start_session`, regardless of the selected
   mode. `GameState.start_session` stores that as `target_bankroll`, and
   `apply_hand_result` ends a session with `target_reached` whenever
   `target_bankroll > 0` (in every mode but practice). So a **survival**
   session that reached +50 net would terminate as "target_reached" instead of
   running to its shoe count ("survival_complete"). Practice was unaffected
   (bankroll is frozen in that mode); target mode was correct by coincidence.
   The other two restart paths (`_on_tier_selected`, `_new_session`) already
   passed `0` for non-target modes — only the mode-selector path was wrong.

2. **`_populate_tier_selector` out-of-bounds `select()`** — the function called
   `_tier_selector.select(current_tier - 1)` with no bounds check. The first
   tier-switch test exposed that when `current_tier` exceeds the number of
   unlocked tiers listed (transiently, after a save reload that drops an
   in-memory rating bump), `select()` threw "index out of bounds".

Fix:
- `Main._on_mode_selected`: pass `START_TARGET` only when the selected mode is
  `MODE_TARGET`, else `0`. Survival/practice now start with no bankroll goal.
- `Main._populate_tier_selector`: clamp the selected index to
  `[0, item_count - 1]` before `select()`, falling back to the top available
  tier if `current_tier` outruns the list.

Regression pins (`scene_smoke_check.gd`):
- `_check_mode_switching`: switch survival → assert `target_bankroll == 0` +
  shoes spinbox visible; practice → `target_bankroll == 0`; target →
  `target_bankroll == 150` + spinbox hidden.
- `_check_tier_switching`: unlock the full ladder (skill rating 100), assert
  the selector lists all 6 tiers, reseat at tier 4 via `_start_session`, and
  assert the loop was rebuilt on tier-4's real table (4-deck, H17).

**Verification.** Full 23-tool suite: all pass. `scene_smoke_check` now covers
mode-switching (target-bankroll leak) + tier-switching (reseat + clamp). No
save residue. `sim_validate` unchanged at 0.954 / 0.441 / −0.627.

## M65 — Investigated "unbalanced-system starting offset"; confirmed NOT a defect

Found: M63's summary carried forward an open item — "Unbalanced systems
(KO net +4/deck, Hi-Opt II net −16/deck) have no starting-value offset in the
engine." This was flagged as the last known counting-pipeline gap, worth a
dedicated pass.

Investigation (first principles + empirical):
- For an unbalanced count the running count of a *full* shoe is nonzero
  (KO +4×N, Hi-Opt II −16×N). A possible "fix" would seed the running count
  to that value at shoe start so the shoe reads as "neutral composition."
- **Rejected: that would be wrong, not right.** Real counting systems do NOT
  seed an offset. The running count starts at 0 for every system at the start
  of a fresh shoe — that is exactly the "neutral fresh shoe" anchor. The
  unbalanced net is a property of the per-card values across a full shoe, not
  a start offset. Seeding an offset would shift the entire true-count scale
  and desync the Hi-Lo-calibrated I18 + insurance thresholds (which are
  centered around TC 0), making play *less* faithful, not more.
- Empirical backing: `sim_counting_systems` already shows **T2 (KO, S17,
  1-deck) counting beats basic** (−0.30% vs 0.40% basic). A mis-initialized
  count would not clear that bar. `tables_check` already pins the full-shoe
  net (0 / +4 / −16). `count_engine_check` pins `reset()` → RC 0 and the
  `true_count_floor()` math.

Related miscalibration examined (also no action):
- I18 + insurance thresholds are Hi-Lo-calibrated but applied to KO /
  Hi-Opt II true counts on the S17 tiers. Assessed as acceptable:
  - I18 is already gated off for H17 (M63), so it only reaches KO single-deck
    (T2), where KO ≈ Hi-Lo (aces uncounted) and the aggregate edge is still
    positive (verified by `sim_counting_systems` T2).
  - Insurance (`tc >= 3`) is only *offered* on T1/T2 (single-deck S17), where
    the Hi-Lo threshold is essentially correct. T5/T6 (Hi-Opt II, the
    genuinely-different scale) have `allows_insurance = false`, so the
    miscalibration never fires where it would matter.

Decision: no production behavior change. The "starting offset" is not a
defect; the engine already does the correct real-world thing. To prevent this
from being re-flagged as a gap, `CountEngine.reset()` now carries a comment
documenting the neutral-start design decision for unbalanced systems.

**Verification.** `CountEngine.gd` parse-only change (comment); full 23-tool
suite re-ran green; `sim_validate` unchanged at 0.954 / 0.441 / −0.627; no
save residue.

## M66 — UI rendering-contract pins: insurance prompt, tilt, heat-backoff

Found: `scene_smoke_check` covered scene construction, count-check feedback,
stale-prompt reset, mode/tier switching (M64), and cash-out, but three
user-facing rendering paths had no pin:
1. The **insurance prompt** — when the loop is in `PHASE_INSURANCE`,
   `_refresh_actions` must show only the two insurance buttons and hide the
   hand / bet / deal controls.
2. The **tilt indicator** — `_refresh_hud` must render the "Tilt" label exactly
   when `discipline.check_tilt()` detects a loss-chasing pattern.
3. The **heat "BACKED OFF" notice** — when the heat system latches a backoff,
   the HUD heat label must surface the `— BACKED OFF` suffix.

Cause: these paths are driven by loop/discipline/heat state that the existing
smoke flow never reached, so a rendering regression (e.g. insurance buttons
left visible during a hand, the tilt label stuck on, or the backoff suffix
dropped) would surface only in live play.

Decision: test-only. `scene_smoke_check.gd` gains three checks:
- `_check_insurance_prompt_rendering`: start a T1 session (the tier where
  `allows_insurance = true`), drive the loop into `PHASE_INSURANCE`, and assert
  take/decline are visible+enabled while hit/stand/bet/deal are all hidden.
- `_check_tilt_indicator_rendering`: populate `bet_history` with a 2→3→4
  loss-chasing pattern (first two `after_loss`) and assert the label shows;
  a non-chasing 2→3→4 control asserts it stays hidden; empty history asserts
  hidden.
- `_check_heat_backoff_rendering`: latch `pending_backoff` on the loop's heat
  system via `get_heat_system()` and assert the heat label surfaces
  `BACKED OFF`; a fresh (non-latched) state asserts it does not.

No production change — all three behaviors were already correct; these pins
lock the contracts so the UI can't regress silently.

**Verification.** `scene_smoke_check` ALL PASS (new checks green first run).
Full 23-tool suite: all pass; `sim_validate` unchanged at 0.954 / 0.441 /
−0.627; no save residue.

## M67 — sim_counting_systems now cuts the shoe at the tier's real penetration

Found: `sim_counting_systems` — the only tool that validates a counting system
against a tier's *real* table — cut its shoe on `cards_remaining() <
SHOE_RESERVE` (deal to near-exhaustion) and ignored `config.penetration`. The
multi-deck H17 tiers specify a much shallower cut (T3 0.60, T4/T5 0.50), so the
sim was measuring the counting edge on a *deeper-penetration* shoe than the
tier actually plays. Deep penetration flatters a counter (more of the shoe's
composition is revealed before the cut), so the old numbers overstated the
counting edge on exactly the tiers it was meant to validate. Single-deck tiers
(T1/T2, penetration 0.70) were unaffected: their 20-card reserve fires before
the 0.70 penetration point.

Fix: both `_run_counting` and `_run_basic` now cut on
`shoe.penetration_reached() or shoe.cards_remaining() < SHOE_RESERVE` — the
exact condition `CHGameLoop.start_or_next_shoe()` uses — so the counting and
basic runs are measured on the identical, faithful table. Tool docstring updated
to state the penetration-respecting cut and correct the stale "30k" default
to 100k.

Faithful re-baseline (seed 20260906, 300k hands, penetration-respecting):
- T3 (hi_lo, 2-deck, H17):  counting 0.135% vs basic 0.848% — counting beats basic.
- T4 (hi_lo, 4-deck, H17):  counting 0.549% vs basic 1.103% — counting beats basic.
- T5 (hi_opt_ii, 6-deck, H17): counting 1.427% vs basic 1.444% — break-even,
  within the "not clearly worse" guard.
- T1 (hi_lo, 1-deck, S17):  counting −0.539% vs basic 0.387% — unchanged (reserve
  fires first). T2 (ko, 1-deck, S17): counting −0.341% vs basic 0.387% — unchanged.

All assertions still hold: the S17 single-deck tiers keep their strict
"counting beats basic" requirement; the H17 multi-deck tiers keep the "not
clearly worse" floor. The counting-system thesis survives on the real table
shapes — the earlier deeper-penetration model was simply slightly optimistic.

No production (engine/loop) change; simulation-fidelity only. `sim_validate`
is untouched (it intentionally uses penetration 1.0 + reserve-only for its
single-deck calibration).

**Verification.** Full 23-tool suite: all pass. `sim_validate` unchanged at
0.954 / 0.441 / −0.627. No save residue.

## M68 — Multi-hand tier soak: real T4/T6 loops driven end-to-end

Found: `multi_hand_check` pins multi-hand structure and settlement with rigged
single rounds on a 1-deck config. Nothing drove a *real* multi-deck tier's loop
(`player_hand_count > 1`) for many hands with a live shoe. A bug that only
surfaces at volume — a multi-spot hand that strands the phase, a split that
leaks or double-counts a card across the shared dealer, a surrender that
double-charges, a settlement that leaves the loop stuck — would not be caught
by any existing tool. (The engine's `CHGameLoop` handles T4 = 2-hand H17 late-
surrender and T6 = 3-hand H17 continuous-shuffle.)

Fix: new `tools/multi_hand_soak_check.gd` (24th tool). Drives the real
`CHTableConfig.for_tier(4)` and `for_tier(6)` tables with the optimal-action
autopilot for 200 rounds each, pinning invariants on every settled round:
- No stall: every round reaches `idle` (a round that can't be driven to idle
  is a hard failure — the classic "stranded phase" bug class).
- Full spot count: at least one round reaches the tier's full hand count
  (`all_hands().size() >= player_hand_count`), proving the multi-hand deal
  path runs in the real loop, not just the unit rig.
- Split coverage: rounds that produce more terminal hands than the spot count
  are counted (the split path is exercised in the multi-hand loop).
- Settlement sanity: `last_wagered()` and `last_net()` are finite, `wagered >=
  spots` (every spot stakes at least 1 unit), and `|net| <= wagered`.
- Card conservation: on the final settled round, every card dealt in the
  current shoe segment is marked `seen` exactly once — the strongest
  cross-cutting invariant (split + surrender + dealer-play all conserve cards
  against the shared dealer).
- Session survival: 999999 practice shoes, so the session never busts or
  completes early; the loop stays active for the full soak.

Implementation note: `_finalize()` clears `_hands` on settle, so the spot
count is captured *during* the round (max of `all_hands().size()` across the
round, complete by `PHASE_HAND`), not after.

**Verification.** `multi_hand_soak_check`: T4 = 200 rounds (15 split-expansion
rounds), T6 = 200 rounds (9 split-expansion rounds), ALL PASS. Full 24-tool
suite: all pass; `sim_validate` unchanged at 0.954 / 0.441 / −0.627; no save
residue.

## M69 — Audit-driven test pins: discipline bounds, count-check skip, lifetime counters

Found: a coverage audit across all 24 tools surfaced four untested-but-correct
behaviors that a future refactor could silently break. All are test-only (no
production change):

1. **Discipline clamp bounds** (`CHDisciplineSystem`): `grade_bet`/`grade_decision`
   clamp `discipline` to `[0, 100]`, but no tool ever drove the meter to a
   boundary. Existing checks assert only *direction* and *relative* size, so a
   flipped sign or overshoot recovery would pass. A broken clamp makes the HUD
   meter and the skill-EMA input read out of range.

2. **Exact grade magnitudes** (`CHDisciplineSystem`): the wrong-decision
   penalty (−`DECISION_PENALTY` = −4.0), the correct-decision recovery
   (`BASE_RECOVERY * discipline/100`), and the bet-severity steps (1.0/2.0/4.0 by
   |diff|) were only direction-pinned, never magnitude-pinned. A mis-set
   severity step would silently rescale the whole discipline economy.

3. **Cover budget refill** (`CHDisciplineSystem.reset_for_new_shoe`): only the
   cap was tested; the per-shoe refill and the `cover_plays_left()` accessor
   were not. A regression that forgets to refill only shows up on shoe 2+.

4. **`skip_count_check()`** (`CHGameLoop`): the player can decline the count
   prompt; the due/report/idempotency paths were pinned but the *skip* branch
   (clears the flag, records no check) had zero coverage.

5. **Lifetime counters** (`CHGameState.end_session`): `hands_played` (sums
   `hands_this_session`) and `sessions_played` (+1) feed the Debrief readout but
   were never asserted; only `skill_rating` was checked.

Fix: test-only pins.
- `discipline_check.gd`: Check 5 (lower floor 3.0 + −4.0 → 0.0; upper cap at
  100.0), Check 6 (decision recovery +1.0 at discipline 50; decision penalty
  −4.0; bet severity diff1/2/3 → −1/−2/−4), Check 7 (3 covers granted → 4th
  rejected → `cover_plays_left()==0` → `reset_for_new_shoe` refills to 3).
- `count_check.gd`: Check 6 — reach a cut, call `skip_count_check()`, assert
  `is_count_check_due()==false` and `checks==0` (declining is not penalized).
- `game_state_check.gd`: Check 8 — 5 practice hands then `end_session`, assert
  `hands_played` +5 and `sessions_played` +1.

**Verification.** All three tools green first run: `discipline_check` 14 PASS
lines, `count_check` ALL PASS, `game_state_check` ALL PASS. Full 24-tool suite:
all pass; `sim_validate` unchanged at 0.954 / 0.441 / −0.627; no save residue.

## M70 — Discipline (decision quality) pins the skill rating end-to-end

Found: the skill rating is an EMA fed by the session process score
(`CHGameLoop._session_process_score`), which blends **discipline** and
**count-accuracy**. `count_check._check_blend_pulls_rating_down` isolates only
the count-accuracy half: both its loops play `optimal_action()` and differ only
in the reported RC. No control-vs-test ever pinned the **decision** half — that
a player who makes suboptimal hand decisions ends with a *lower* skill rating
than an identical optimal-play control through a real graded loop. A broken
`grade_decision` sign, a `grade_decisions` gate that leaks off on T2, or a
process-score blend that ignores discipline would all slip past the existing
tools (which only assert the meter moves, never that it moves the *rating*).

Fix: test-only pin in `lifecycle_check.gd` (where session-end rating behavior
lives) — `_check_discipline_lowering_rating()`. Runs two T2 sessions (T2 has
`grade_decisions=true`; `count_check_active` forced off so the process score is
pure discipline, since `_session_process_score` returns `discipline.discipline`
when no count checks were recorded). Both arms share SEED and drive the same 20
hands with optimal bet sizing. The control plays `optimal_action()` everywhere;
the test arm inverts every legal hit↔stand decision (the inverted action is
used only when it is in `available_actions()`, so a bust hand never offers an
illegal "hit"). Bets stay optimal in both arms so *only* hand-decision quality
differs. Both cash out on an unreachable target (999999) so the rating is a
single clean EMA update from the 0.0 default: `rating == 0.2 * discipline`.

Assertions: both ratings advanced (>0), and `test_rating < control_rating`
(suboptimal decisions lower the skill rating). A guard asserts neither arm
ended early (bust/target) so the comparison reflects a controlled cash-out.

Implementation notes:
- T2 is the cheapest tier with `grade_decisions=true`; T1 is off by design
  (teaching table), so it can't demonstrate the lever.
- `optimal_action()` returns the raw strings `"hit"`/`"stand"`/`"double"`/
  `"surrender"` (ACT_* constants), so the inversion matches those literals.
- With SKILL_EMA_ALPHA = 0.2 and a fresh 0.0 default, the control (discipline
  ~100, all-optimal + recovery) lands well above the test arm (discipline
  drained by −4.0 per wrong decision), giving a wide, stable margin.

**Verification.** `lifecycle_check`: ALL PASS (new check green first run). Full
24-tool suite: all 21 check tools pass; sim baselines unaffected (test-only
change, no production touched) — `sim_validate` 0.954 / 0.441 / −0.627; no save
residue.

## M71 — highest_unlocked_tier(): unpersisted + sticky-unlock pin

Found: `CHGameState.highest_unlocked_tier()` merges two sources — (a) the
persisted `unlocked_tiers` array and (b) a live threshold scan over the current
`skill_rating` that surfaces tiers the rating has qualified for but that
`end_session` has not yet persisted (the "not-yet-persisted" branch,
`GameState.gd:173-175`). No tool drove it. A regression that deleted or
reversed the threshold loop would make the scene tier selector show stale tiers
between sessions; one that dropped the persisted loop would let a tier vanish
when the rating decays below its threshold after a bad session.

Fix: test-only pin in `game_state_check.gd` — new `_check_highest_unlocked_tier()`
(check 9) plus `_expect`/`_expect_eq`/`_expect_close` helpers. Sub-cases:
- Fresh state (rating 0, `unlocked_tiers=[1]`) → 1.
- Rating set to 60.0 directly (still `unlocked_tiers=[1]`) → 3: only the
  threshold-scan loop can produce this, so it isolates the unpersisted branch.
- Rating 59.9 → 2 (just below the tier-3 threshold of 60.0).
- Rating 90.0 (== tier-6 threshold) → 6; rating 95.0 → 6 (capped at max).
- Sticky: real EMA decay. rating 90.0 → `end_session` → 72.0 (tier 4 persists,
  since 72 ≥ 70) → `end_session` → 57.6 (below 70, but tier 4 stays in
  `unlocked_tiers`). Assert `highest_unlocked_tier() == 4` — the persisted path
  must win over the now-below-threshold rating.

Float comparisons use a 0.001 tolerance because `1.0 - 0.2` is not exactly
`0.8` in float64 (the EMA ladder `90→72→57.6` is approximate). All `end_session`
calls use `persist=false` so no user save is written.

**Verification.** `game_state_check`: ALL PASS (new check green first run).
Test-only — no production code touched; sim baselines unchanged at
0.954 / 0.441 / −0.627; no save residue.

## M72 — Three settlement/robustness pins: bet clamp, runout asymmetry, multi-spot insurance forfeit

Found: a coverage audit surfaced three untested-but-correct behaviors:

1. **`place_bet` clamping** (`GameLoop.gd:307`): `place_bet(units)` clamps to
   `[1, MAX_BET_UNITS]` (i.e. `[1, 6]`), and the *clamped* value is what gets
   committed as `_base_bet` and graded against the optimal ramp. No tool ever
   passed a bet outside `[1, 6]`, so a regression that committed or graded the
   raw value would slip through.

2. **Mid-hand runout vs. count-check prompt** (`GameLoop.gd:798-808`): the
   emergency reshuffle in `_deal_card()` calls `_on_new_shoe()` (advancing
   `shoes_this_session`) but does NOT set `_count_check_due` or emit
   `count_check_due`. The start-of-hand cut (`start_or_next_shoe`, line 239-241)
   does both. No tool pinned this asymmetry — a regression that made the runout
   path trigger a quiz prompt (or conversely, one that made the start-of-hand
   cut skip it) would be undetected.

3. **Multi-spot insurance forfeit** (`GameLoop.gd:724-726`): when the player
   takes insurance on a multi-spot hand and the dealer has no natural, the full
   scaled side-bet (`spots × max(1, base/2)`) is forfeited in
   `_play_dealer_and_settle`. The win path (dealer BJ pays the scaled side-bet)
   was pinned by `multi_hand_check` check 7 (M59); the symmetric loss path was
   never driven.

Fix: three test-only pins, one in each tool that naturally owns the behavior:

- `game_loop_check.gd` — `_check_place_bet_clamping()`: rigs a dealer-BJ hand
  with TC=8 (optimal=6). `place_bet(100)` → clamped to 6 → net −6, discipline
  stays 100 (zero deviation, recovery). `place_bet(0)` → clamped to 1 → net −1,
  discipline 96 (severity step 3, |1−6|=5 → −4.0).

- `robustness_check.gd` — `_check_runout_no_count_check()`: T1 loop
  (`count_check_active=true`), leaves 1 card in the wall, calls `_deal_card()`
  twice. The second call triggers the runout. Asserts `count_check_due` signal
  did NOT fire, `is_count_check_due()` is still false, but
  `shoes_this_session` advanced.

- `multi_hand_check.gd` — `_check_insurance_forfeit_multi_spot()`: 2-spot T1
  config, Ace upcard + 5 hole (dealer 19, no BJ), both spots 17. Takes
  insurance (side-bet = 2×max(1,4/2) = 4). Settles: both 17s lose to 19 (−8
  main), insurance forfeited (−4). Net = −12, wagered = 12.

**Verification.** All three tools green first run. Full 21-tool check suite:
all pass. Sim baselines unchanged (test-only) — `sim_validate` 0.954 / 0.441 /
−0.627. No save residue.

## M73 — Fix Hi-Opt II Ace card value (production correctness bug)

Found (adversarial audit of the counting path): `CHCard.count_value("hi_opt_ii")`
returned **−1 for the Ace** — the branch fell through to `return -1` with no
Ace special-case. Canonical **Hi-Opt II** is +1 on 2–4, 0 on 5/6/7/**A**, −1 on
8–10, i.e. the **Ace is 0**. The KO branch already special-cased
`rank == 14 → 0`; Hi-Opt II had dropped it.

This was a genuine per-card defect, not a convention: every Ace in the shoe
counted one too low. Over a single 52-card deck that is a −4 running-count bias;
over a 6-deck Tier-5 shoe up to −24. It directly corrupts the true count that
drives T5's bet ramp (`optimal_bet_units` → `true_count_floor`) and the
count-accuracy training feedback.

Compounding factor: `tables_check.gd` had pinned the full-deck net to **−16**
and never asserted the Hi-Opt II Ace value, so the test was self-consistently
locking in the wrong number. The correct full-deck net is **−12**
(+12 from 2–4, 0 from 5–7 and 4 aces, −24 from 8–K).

Fix (production):
- `Card.gd` `"hi_opt_ii"` branch: added `if rank == 14: return 0` before the
  `return -1` fallthrough (mirrors the KO branch). Net per deck now −12.
- `CountEngine.gd` doc comment: `hi_opt_ii net -16/deck` → `net -12/deck`.

Fix (test, to keep the suite honest rather than pin the bug):
- `tables_check.gd`: `DECK_NET["hi_opt_ii"]` −16 → **−12**; header comment
  updated; added per-card pins `hi_opt_ii 4 = +1`, `10 = -1`, `A = 0` so a
  future Ace regression is caught at the card level, not just by the net.

Unaffected: `sim_validate` (Hi-Lo only) — its 0.954 / 0.441 / −0.627 baseline is
unchanged. T5 (Hi-Opt II) is H17, so the I18 deviation layer is already gated
off (M63); the only Hi-Opt II consumer is bet-sizing + count-accuracy, both of
which now read the correct true count.

**Verification.** `tables_check` ALL PASS (incl. new Ace pin + −12 net);
`count_engine_check` ALL PASS; `sim_counting_systems` Tier 5 @ 300k hands,
seed 20260906: counting **1.4353%** vs basic **1.4440%** (counting ≥ basic −
0.30 floor holds; was 1.427 vs 1.444 under the −16 assumption — the corrected
Ace value is marginally better, as expected for the faithful system). No save
residue.

## M74 — Mid-hand runout re-syncs the deck estimate (multi-deck true-count bug)

Found (adversarial audit of the deal path): `GameLoop._deal_card()`'s mid-hand
runout branch reshuffled the shoe and called `count.reset()` but never re-synced
`decks_remaining`. `CountEngine.reset()` hardcodes `decks_remaining = 1.0`, so on
any multi-deck tier (T3–T6) a mid-hand runout left the count engine thinking
there was 1 deck left instead of the reshuffled shoe's full count. For the
remainder of that hand the true count `RC / decks_remaining` was inflated N-fold
(e.g. 6× on T5), which could trigger spurious I18 deviations / insurance tells
that the fresh-shoe true count did not justify. The start-of-hand path was
already correct: `begin_hand()` calls
`count.set_decks_remaining(shoe.decks_remaining_estimate())` after
`start_or_next_shoe()`.

Fix (production): `GameLoop._deal_card()` now calls
`count.set_decks_remaining(shoe.decks_remaining_estimate())` immediately after
`count.reset()` in the runout branch, mirroring the start-of-hand path. On a
1-deck shoe the estimate is 1.0 (behavior unchanged); on N-deck shoes it is the
full reshuffled estimate.

Fix (test): `robustness_check.gd` new check 6
`_check_runout_multideck_estimate()` — T4 (4-deck, 0.5 estimation step): exhaust
the shoe, force a `_deal_card()` runout, and assert `count.decks_remaining`
re-syncs to 4.0 (the reshuffled full-shoe estimate) rather than the 1.0
default. The existing check 2 (T1) still asserts 1.0, which remains correct
because a fresh 1-deck estimate rounds to 1.0.

**Verification.** `robustness_check` ALL PASS (6 checks). Full 21-tool check
suite: all pass. `sim_validate` baseline unchanged at 0.954 / 0.441 / −0.627
(runout is rare in the sim's single-hand loop; behavior at T1 is identical). No
save residue.

## M75 — Tool doc headers made 1:1 with their `_init` check lists

During a post-M74 review I re-audited the numbered doc headers of the check
tools against the actual `_init()` call order, on the assumption that the
headers had already been reconciled. One was not: `game_loop_check.gd` listed 20
items but item 3 ("optimal play never costs Discipline") duplicated a sub-assert
inside the bankroll check (item 2) and the list never named
`_check_deviation_tell` (the 20th `_init` call). The header now maps 1:1 —
items 1–20 correspond exactly to the 20 `_check_*` calls, with the deviation-tell
check documented as item 20.

Re-verified the rest, which were already correct: `count_check` (6),
`robustness_check` (6), `game_state_check` (9), `lifecycle_check` (5), and
`multi_hand_check` (8) each have a header that names their checks in `_init`
order. No behavior or assertion changed in this pass — pure doc hygiene — so no
production or sim code was touched.

**Verification.** `game_loop_check` re-parse-checked clean and re-ran ALL PASS
(1000 hands × optimal + invariants). Full 21-tool check suite: all pass.
`sim_validate` baseline unchanged at 0.954 / 0.441 / −0.627;
`sim_counting_systems` T5 (Hi-Opt II) still counting-better than basic
(counting 1.2096% vs basic 1.2622%, seed 20260906). No save residue.

## M76 — Production-readiness review: save-safety, window size, keyboard, version tag

Found: a production-readiness sweep surfaced seven items across two passes. None
change strategy or simulation behavior — `sim_validate` stays
0.954 / 0.441 / −0.627 throughout.

**1. `project.godot` version tag (resolved).** `config/features` is `"4.7"` and
the 4.7 binary (`E:\Godot_v4.7-stable_win64_console.exe`) is where every tool is
validated, so the tag and the toolchain now match.

**2. No save-schema guard.** `GameState.deserialize()` read
`save_schema_version` via `.get(key, default)` and never validated it, so a save
written by a *newer* schema would load with unknown fields silently defaulted.
Fix: `deserialize()` now reads the version and refuses it with a `push_warning`
when `version > SAVE_SCHEMA_VERSION`; older versions still load forward-compatibly
(defaults fill gaps). Pinned by `game_state_check` check 10
(`_check_schema_version_guard`): future version refused, current version preserved,
older version loads.

**3. `save()` write failures swallowed in the loop.** Both heat-floor write-back
sites in `CHGameLoop` (`_on_new_shoe` shoe-completion path and the `_finalize`
target/bust path) called `state.save()` and ignored the returned `bool`. A
disk-full or permissions failure would silently drop the persisted heat floor.
Fix: both now `push_error(...)` when the write fails.

**4. Duplicate `count_check_active` in `for_tier(5)`.** The Tier-5 branch set
`c.count_check_active = true` twice. Harmless, but a smell. Removed.

**5. No window size declared.** `[display]` set stretch mode/aspect but no
`viewport_width`/`height`, so the window fell back to the engine default. Fix:
`window/size/viewport_width=1280`, `viewport_height=720`.

**6. Silent progression loss on an unreadable save.** `Main._start_session` called
`_state.load_game()` and ignored the result. A corrupt or future-schema save at the
default path would fail to load, drop the player to tier 1 / rating 0 with no
notice, and the next session end would overwrite the original file — permanent
data loss. Fix: capture whether the file existed before loading and whether the load
succeeded; when a save existed but failed, call `_backup_unreadable_save()`
(copies it to `counting_house_save.json.corrupt.bak` via `DirAccess.copy_absolute`)
and surface a one-line warning in the status label. Pinned by `scene_smoke_check`
`_check_save_loss_warning`: writes a future-schema save, restarts, asserts rating
reset to default, warning text shown, and the backup file exists; cleans up both
files after.

**7. No keyboard input.** The trainer was mouse-button-only, slowing the play
loop. Fix: `Main._unhandled_input` maps keys per phase — Space/Enter deals
(IDLE); 1-6 place the bet and C toggles cover (BET); T/D take/decline insurance;
S/P split/play (PRESPLIT); H/S/D/R hit/stand/double/surrender (HAND). Each binding
is gated on the action actually being available in the current phase and on the
session being active; while the count-check `LineEdit` has focus it swallows its
own typed input, so shortcuts only fire when no text field is focused. Also wired
`LineEdit.text_submitted` → `_on_count_check_submit` so Enter submits the count
check. Pinned by `scene_smoke_check` `_check_keyboard_shortcuts` (Space in IDLE →
BET; "2" in BET leaves BET; an unmapped key is a no-op).

**Verification.** Full suite green: 21-tool check suite + `insurance_check`,
`scene_smoke_check` (now with the two new pins), and `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). No save residue.

## M77 — HUD layout wrap + live skill-rating readout

Found: two UI-layer gaps surfaced on the second production pass.

**1. HUD clips at the declared window size.** The HUD row was a single
`HBoxContainer` with up to 14 children (9 readout labels + count-system label +
tier selector + mode selector + shoe SpinBox). With the explicit 1280×720 window
from M76, most labels are visible simultaneously on T1 (TC, heat, count acc all
on), so the row overflows and the right-side interactive controls (tier/mode
dropdowns, shoe spinbox) get clipped. An `HBoxContainer` never wraps, so the
overflow silently cuts off controls rather than reflowing them.

Fix: the HUD row is now an `HFlowContainer` — identical child order and
separation, but items wrap to a second line instead of clipping. This also
self-heals as labels show/hide per tier (a tier with TC hidden reflows upward).
No scene-tree structure changed: the HUD is a local in `_build_ui`, and
`_refresh_cards`' HBox-scanning `queue_free` loop only touches `_player_area`
children, so the type swap is invisible to the render pass.

**2. Skill rating invisible mid-session.** The skill rating — the persistent
tier-unlock currency — was only readable in the post-session debrief. A player
could not tell how close they were to the next tier while playing, which weakens
the progression loop the whole tier ladder is built on. `CHGameState` already
persists `skill_rating`, `unlocked_tiers`, and `TIER_SKILL_THRESHOLDS`; nothing
surfaced the first two live.

Fix: a persistent `Skill: X (Tn at Y)` HUD label. `_skill_label_text()` reads
`get_skill_rating()` and `highest_unlocked_tier()`: if the player is below the
top tier it shows the next tier's unlock threshold (tier n → index n-1 in
`TIER_SKILL_THRESHOLDS`, so the next tier up from `h` is at index `h`); at the
top tier it shows `(max tier)`. Updated in `_refresh_hud()` like the other
labels — no visibility gating, it is meaningful on every tier.

**Verification.** `scene_smoke_check` gains `_check_skill_label`: forces rating
55.0 → asserts the exact string `Skill: 55.0 (T3 at 60)` (rating 55 clears the
tier-2 threshold of 50 but not tier-3's 60, so the next-tier index math is
pinned end-to-end), then rating 95.0 → asserts `Skill: 95.0 (max tier)`. Full
suite re-run: all 24 tools pass; `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). No save residue.

## M78 — GUI polish pass: key-hint labels, practice P&L wording, typed-array fix

**1. Keyboard shortcuts had no visible affordance (M76 follow-up).** M76 wired
`_unhandled_input` shortcuts but nothing in the UI told the player they existed.
Fix: `_action_title()` now returns labels with the key in parentheses —
`Hit (H)`, `Stand (S)`, `Double (D)`, `Split (S)`, `Surrender (R)`,
`Play (no split) (P)`, `Take Insurance (T)`, `Decline Insurance (D)`. S is
shared between Stand (HAND) and Split (PRESPLIT) — the two are never visible in
the same phase, so no collision. The deal button reads `Deal Next Hand
(Space)`, the cover toggle `Cover (C)`, and the count-check prompt title now
ends with `(Enter to submit)` (the `text_submitted` binding from M76).

**2. Practice-mode debrief claimed a bankroll that never moved (latent
inconsistency).** `_show_debrief` always printed `P&L: X (bankroll N)` using
`int(roundf(_session_net)) + SESSION_START_BANKROLL`. In practice mode the
bankroll is frozen (no economy stakes), so the HUD read `Bankroll: 100` all
session while the debrief showed a divergent figure. Fix: the P&L line now
branches on `session_mode` — practice reads `practice — no stakes`, other modes
keep the bankroll figure.

**3. `_refresh_actions` ternary typed-array bug (latent, surfaced by M78
pins).** `var available: Array[String] = [] if in_bet else _loop.
available_actions()` — the `[]` ternary branch is an untyped `Array`, which
fails the typed-array assignment at runtime whenever `_refresh_actions` runs in
the BET phase (a script error in the console, non-fatal). M76's keyboard path
was the first caller to reach `_refresh_all()` while in BET. Fix: build `[]` in
an `if not in_bet` branch instead of a ternary.

**4. Empty count-check submit graded the player for "0" (M79).**
`_on_count_check_submit` did `raw.to_int()` on the LineEdit text; an empty
field (accidental Enter or a Submit click before typing) parsed to `0` and was
recorded against the player's count accuracy as if they had reported a running
count of zero. Fix: an empty report is ignored — the status shows
"Enter a running count, or Skip.", the check stays pending, and the panel
stays open.

**Verification.** `scene_smoke_check` pins: button key-hint labels (hit /
insurance / deal / cover exact text), practice debrief P&L contains
`practice — no stakes` and never `(bankroll` after a practice session, and
`_check_count_check_empty_submit` (M79) asserts an empty submit leaves the
check pending with the hint shown while a valid report right after still
grades and clears. Full 24-tool suite: all pass; `sim_validate`
byte-identical (0.954 / 0.441 / −0.627). No save residue.

## M80 — System hardening: surface session-end save failures

**Found.** `GameState.end_session()` calls `save()` to persist the session's
skill-rating EMA, tier unlocks, lifetime counters, and heat floor — the *only*
moment progression is written — but discarded the return value. A failed write
(disk full, permissions, corrupt path) would silently lose all of that with no
console error and no UI notice; the player would just see "Session ended" and
assume progress was kept. M76 hardened the *load* side (corrupt-save backup +
schema guard) but left the *write* side silent.

**Fix.**
- `GameState`: new `save_path` (defaults to `DEFAULT_SAVE_PATH`, overridable in
  tests) and `last_save_ok` (result of the most recent `save()`). `save()` sets
  the flag; `_save_default()` now writes to `save_path`.
- `CHGameLoop`: new `save_failed()` signal, emitted at all three session-end
  sites (`cash_out`, terminal-hand `_finalize`, shoe-completion
  `_on_new_shoe`) when `state.last_save_ok` is false, with a `push_error`. The
  check runs *before* the separate heat-floor write at each site so a heat-floor
  success can't mask a session-save failure.
- `Main.gd`: connects `save_failed` to `_on_save_failed`, which sets
  `_save_failed_this_session` (reset in `_start_session`). `_on_session_ended`
  appends "— WARNING: save failed, progress may not have been persisted." to the
  status line when set, so the player sees it next to the debrief.

**Verification.** `game_state_check` pins `last_save_ok` true after a successful
save and false after a save to a nonexistent directory. `lifecycle_check`
gains `_check_save_failed_signal`: points `state.save_path` at a nonexistent
directory, cashes out, and asserts the session still ends normally while
`save_failed` fires exactly once and `last_save_ok` is false; a control arm on
a healthy path asserts no signal and `last_save_ok` true. Full 24-tool suite:
all pass; `sim_validate` byte-identical (0.954 / 0.441 / −0.627). No save
residue.

## M81 — Presplit rendering: show resolved splits + fix typed-array crash

**Found.** Two related defects in `Main.gd` card rendering for the presplit
phase:
1. *Rendering gap (multi-spot tables, tier 4+):* while deciding whether to split
   a later root, only the current root was drawn — hands already resolved from
   earlier roots (in `_loop.all_hands()`) were hidden, so the player lost sight
   of the table state.
2. *Latent typed-array crash:* the presplit branch built the render list with
   `hands = [pre] if pre != null else []` / `hands = hands + [pre]`. The RHS is
   an untyped `Array`, which fails the `Array[CHHand]` assignment at runtime and
   aborted `_refresh_cards()` mid-function on every presplit refresh (cards
   never drawn). The M78 pass had fixed the same class of bug in
   `_refresh_actions` but left this one.

**Fix.** Extracted `Main._hands_to_render() -> Array[CHHand]`: calls
`_loop.all_hands().duplicate()` (always a fresh typed copy), then appends
`current_hand()` if in the presplit phase. No mutation of loop-internal arrays;
no untyped-array assignment. `_refresh_cards()` now calls the helper.

**Verification.** `scene_smoke_check` gains
`_check_presplit_multi_spot_rendering`: rigs a deterministic two-spot 7,7 vs 5
opening on a tier-4 loop, splits spot 1, then asserts `_hands_to_render()`
returns 3 hands and includes the current root. A single-spot control arm asserts
the unchanged one-hand behavior. Full 24-tool suite: all pass; `sim_validate`
byte-identical (0.954 / 0.441 / −0.627). No save residue.

## M82 — Deal shortcut dead after the first hand; count-check input validation

**1. Space/Enter deal shortcut only worked in the initial IDLE phase.**
`_unhandled_input` matched `PHASE_IDLE` for the deal key, but the loop rests in
`PHASE_SETTLED` between hands (every settle path sets SETTLED; nothing ever
returns to IDLE after `_init`). The deal button is visible in both phases and
its label reads "Deal Next Hand (Space)" (M78), so after the first hand of a
session the advertised shortcut silently did nothing. Fix: the deal arm now
matches `PHASE_IDLE, PHASE_SETTLED` — `begin_hand()` itself gates on
`is_idle()`, so no double-deal is possible.

**2. Count-check input silently coerced non-integers.** `_on_count_check_submit`
ran `raw.to_int()`, so "abc" graded the player as reporting 0 and "4.5"
truncated to 4 — both against the player's count accuracy with no warning.
Fix: the empty-input guard (M79) now also rejects anything that is not a valid
integer string (`is_valid_int()`), showing "Enter a running count (an
integer), or Skip." and leaving the check pending.

**Verification.** `scene_smoke_check`: M79 pin extended with a non-integer
("abc") submit asserting the check stays pending and the hint shows; keyboard
pin extended with a fresh session forced to `PHASE_SETTLED` asserting Space
deals to BET. Full 24-tool suite: all pass; `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). No save residue.

## M83 — Atomic save writes (write-tmp-then-rename)

**Found.** `GameState.save()` serialized straight to the live save path. A
crash/kill mid-write leaves a truncated save; the next start fails to load it
and M76's backup preserves only the corrupt bytes, so the player's progression
(skill rating / tier unlocks / heat floor) is lost. This is the single most
consequential write in the game (the only moment progression persists), so a
half-written file is the worst possible failure mode.

**Fix.** `save()` now writes to a sibling `<target>.tmp` first, then
`DirAccess.rename_absolute()` onto the target (atomic on the same volume). If
the rename fails (cross-volume/permissions) it falls back to a full
`copy_absolute` of the completed temp file. A stale `.tmp` left by an
interrupted earlier save is removed before writing so it never accumulates.
`last_save_ok` (M80) now reflects the final move-into-place, not just the
temp write. Tool `_cleanup_save()` helpers also remove any `.tmp` residue.

**Verification.** `game_state_check` pins the atomic-write contract: no `.tmp`
residue after a successful save; a second save to the same path replaces the
first and reads back as the new state (exercises rename-onto-existing on
Windows); a pre-existing stale `.tmp` is cleaned up by the next save. Full
24-tool suite: all pass; `sim_validate` byte-identical (0.954 / 0.441 /
−0.627). No save residue.

## M84 — P0 onboarding: first-run help/intro panel

**Found.** The game had no onboarding: a new player opening it saw labeled
buttons and HUD readouts with no explanation of the objective (you are a
card counter), the tier ladder / skill-rating progression, the three session
modes, heat / backoff, cover plays, or the shoe-cut count check. Correct
behavior is documented in code, but nothing surfaces it to the player — the
single biggest gap between "working simulator" and "game a person sits down
and plays."

**Fix.**
- `Main.gd`: new full-rect `_help_panel` overlay (`_build_help_panel()`, added
  last in `_build_ui` so it draws above the table) with a title, a
  `ScrollContainer` of autowrapped sections from `_help_sections()` (what this
  is / progression / modes / heat / cover / count checks / controls), and a
  "Got it — start playing" close button.
- `_maybe_show_intro()` shows the panel on first launch (no save file on disk);
  called from `_ready()` after the first session starts.
- A "Help (F1)" button in the actions row reopens it any time; `_on_help_pressed`
  toggles it.
- `_unhandled_input` now handles F1 (toggle, any phase, even at the debrief)
  before the session-active gate, and Esc closes the panel. While the panel is
  up, all gameplay shortcuts are gated so keys can't act on the table behind it.

**Verification.** `scene_smoke_check` gains `_check_help_panel`: panel and
button exist; with no save file `_maybe_show_intro()` shows it; F1 closes and
reopens; Esc closes; the Help button toggles; with a save file present no intro
shows. The keyboard-shortcut pin now dismisses the panel first (`_hide_help()`)
since a first-run panel gates gameplay input by design. Full 24-tool suite: all
pass; `sim_validate` byte-identical (0.954 / 0.441 / −0.627). No save residue.

## M85 — P1: card-face visuals

**Found.** Cards rendered as a single 2-character text label (`AH`, `10S`) on a
white chip — the biggest "feel" gap keeping the game reading as a debug console
rather than a card game.

**Fix.**
- `CHCard`: added display helpers `rank_text()` (rank only, no suit),
  `suit_symbol()` (unicode pip ♠♥♦♣), and `is_red()` (hearts/diamonds red).
- `Main._card_label()` rewritten: returns a `PanelContainer` card face (44×60)
  with a white rounded/bordered stylebox; rank+suit pip in the top-left corner
  (14px) and a large centred suit symbol (28px), colour-coded red/black by
  `is_red()`.

**Verification.** `hand_check` gains `_check_card_display`: pins `rank_text()`
for 2/10/J/Q/K/A, all four `suit_symbol()` pips, and `is_red()` for each suit.
Full 24-tool suite: all pass; `sim_validate` byte-identical (0.954 / 0.441 /
−0.627). No save residue.

## M86 — P&L rounding fix, count-check keyboard gate, career stats in debrief

**Found.**
1. *P&L/bankroll divergence:* `_on_hand_settled` accumulated the raw float
   `net`, but `GameState.apply_hand_result` rounds each hand's net to an int
   before adding to bankroll. After multiple half-unit hands (e.g. 1u
   surrenders), the debrief's `final_bankroll` could diverge from the actual
   bankroll by ±1 per fractional hand.
2. *Count-check keyboard bypass:* the shoe-cut count check disabled the bet
   buttons (via `count_gate` in `_refresh_actions`), but the keyboard path in
   `_unhandled_input` (PHASE_BET arm) did not check `is_count_check_due()`.
   Pressing 1-6 while the check was pending would still place a bet,
   defeating the forcing function.
3. *Career stats invisible:* `lifetime_stats` tracks `hands_played` and
   `sessions_played` persistently, but the UI never surfaced them.

**Fix.**
- `Main._on_hand_settled`: accumulate `roundf(net)` instead of raw `net`,
  matching the per-hand integer rounding in `apply_hand_result`.
- `Main._unhandled_input` PHASE_BET arm: early-return when
  `is_count_check_due()` is true; if Enter is pressed, route to
  `_on_count_check_submit()` so the check can be closed via keyboard even
  when the LineEdit has lost focus.
- `Main._show_debrief`: added a "Career" line showing cumulative
  `hands_played` and `sessions_played` with correct singular/plural. Bumped
  `_debrief_lines` from 8 to 9 slots.

**Verification.**
- `scene_smoke_check._check_pnl_rounding`: two `_on_hand_settled(-0.5, 1.0)`
  calls must yield `_session_net == -2.0` (not -1.0).
- `scene_smoke_check._check_count_check_keyboard_gate`: pressing KEY_3 while
  a check is pending must NOT leave the BET phase; Enter submits; after the
  check clears, KEY_3 places a bet normally.
- Career line: the existing practice-session debrief check now asserts the
  "Career:" line matches `lifetime_stats` values.
Full 24-tool suite: all pass; `sim_validate` byte-identical (0.954 / 0.441 /
−0.627). No save residue.

## M87 — Bet-sizing feedback

**Found.** When the player places a bet on tiers that grade the ramp (T2–T6),
no feedback is shown about how their bet compared to the count-optimal size.
The discipline system grades it internally, but the player never learns
"you bet 2u, optimal was 4u" — the single most important lesson in card
counting (bet ramp adherence).

**Fix.**
- `Main._on_bet_units`: after `place_bet()`, if `config.grade_bet_ramp` is on,
  sets the status label to a feedback string via a new pure helper
  `_bet_status_text(u, optimal, cover_granted)`:
  - cover granted → "Bet: Nu (cover)"
  - u == optimal → "Bet: Nu (optimal)"
  - otherwise → "Bet: Nu — optimal was Mu"
- The helper is a pure function (no side effects, no deal interaction), making
  it trivially testable.

**Verification.** `scene_smoke_check._check_bet_feedback_text` asserts all
three branches (optimal match, short bet, long bet, cover override).
Full 24-tool suite: all pass; `sim_validate` byte-identical (0.954 / 0.441 /
−0.627). No save residue.

## M88 — Card-back for the dealer's hidden hole card

**Found.** While the player was acting, the dealer's hidden hole card rendered
as empty space — the dealer row showed only the upcard, leaving a visual gap
that broke immersion and made the table look unfinished.

**Fix.**
- `Main._refresh_cards()`: when the upcard exists but the hole card has not
  been revealed yet, a face-down card back is now rendered alongside the
  upcard.
- New `Main._card_back()` helper: builds a `PanelContainer` (44×60, matching
  the card face) with a dark blue-grey `StyleBoxFlat`, lighter border, and a
  centred diamond glyph (`\u25C6`) at 55% opacity.

**Verification.** `scene_smoke_check._check_card_back`: asserts the card back
is a `PanelContainer` with the correct footprint and a centred glyph; then
drives a live hand and confirms the dealer row shows two 44×60 slots (upcard
face + card back) while the hole is hidden.
Full 24-tool suite: all pass; `sim_validate` byte-identical (0.954 / 0.441 /
−0.627). No save residue.

## M89 — Active-hand highlight on multi-hand tables

**Found.** On split and multi-spot (tier 4+) tables, every player hand row
rendered identically (`Hand 1`, `Hand 2`, …), so the player had no visual cue
about which hand they were currently acting on.

**Fix.**
- `Main._active_hand_index(hands) -> int`: pure helper that returns the index
  of the hand the player is acting on, or -1 when no hand is live. In
  `PHASE_PRESPLIT` the active hand is the current root (the last rendered
  hand); in `PHASE_HAND` it is the loop's current terminal hand. Relies on
  Godot object-identity comparison (`==`), so the match is exact.
- `Main._refresh_cards()`: the active hand's label gets a `◀ ` prefix and an
  amber `font_color` override; all other rows stay uncoloured.

**Verification.** `scene_smoke_check._check_active_hand_index`: asserts index 0
for a single hand in `PHASE_HAND`, asserts -1 outside decision phases, and
asserts the presplit multi-spot case points at the current root (last rendered
hand). Full 24-tool suite: all pass; `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). No save residue.

## M90 — Hand total labels on player rows

**Found.** Player hand rows showed only cards with no numeric total. In a
card-counting trainer the player still needs to see their running hand total
to make hit/stand decisions; requiring mental arithmetic for every hand adds
cognitive load that obscures the counting practice.

**Fix.**
- `Main._hand_total_label(h: CHHand) -> Label`: builds a small numeric label
  showing `h.total()`. Red on bust (>21), green on 21, neutral grey otherwise.
- `Main._refresh_cards()`: appends the total label after each hand's cards.

**Verification.** `scene_smoke_check._check_hand_total_label`: pins the label
text and colour for a normal hand (15), a bust hand (25, red), and a 21
(blackjack, green). Full 24-tool suite: all pass; `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). No save residue.

## M91 — Heat label colour severity

**Found.** The heat label showed a bare percentage with no visual urgency cue;
a player watching heat climb had no immediate signal that backoff was near.

**Fix.**
- `Main._heat_color(hp, backed_off) -> Color`: pure helper returning a severity
  colour — white sentinel (no override) below 0.5, amber at 0.5–0.75,
  red-orange at 0.75+, hot red when backed off (backoff wins regardless of %).
- `Main._refresh_hud`: applies the colour via `add_theme_color_override` when
  the helper returns a non-sentinel colour; clears the override otherwise.

**Verification.** `scene_smoke_check._check_heat_color`: asserts all four
threshold branches (low/neutral, mid/amber, high/red-orange, backoff/hot-red).
Full 24-tool suite: all pass; `sim_validate` byte-identical (0.954 / 0.441 /
−0.627). No save residue.

## M92 — P2: Career & Stats overlay

**Found.** Persistent progression data (`lifetime_stats.hands_played`,
`sessions_played`, `unlocked_tiers`, per-tier heat floors) was only visible in
the session-end debrief, so a player mid-session had no way to review their
career progress or see which tiers they'd unlocked.

**Fix.**
- `Main`: new full-rect `_stats_panel` overlay (same structure as help panel)
  with title "Career & stats" and a `ScrollContainer` + `_stats_content`
  `VBoxContainer` repopulated each open.
- `Main._stats_lines() -> Array[String]`: pure helper building 4 lines from
  persistent state — skill rating + next-tier threshold, lifetime
  hands/sessions, unlocked tiers, per-tier heat floors.
- `Main._populate_stats()`: rebuilds the content labels from `_stats_lines()`.
- `Main._build_stats_panel()`: builds the panel, called from `_build_ui()`
  after the help panel so it stacks above.
- "Stats (Tab)" button in the actions row; `_unhandled_input` handles `KEY_TAB`
  (toggle) and gates gameplay input while the panel is open (same gate as
  help). Esc also closes.
- Help "Controls" section updated to include "Tab stats".

**Verification.** `scene_smoke_check._check_stats_panel`: rigs a known
persistent state, asserts `_stats_lines()` returns exactly 4 lines with the
expected content (rating + next threshold, lifetime counters, unlocked tier
list, heat floors with correct percentages); then verifies Tab opens the panel
with 4 content labels, Esc closes it, and the button toggles correctly.
Full 24-tool suite: all pass; `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). No save residue.

## M93 — Show the player's opening hand during the insurance prompt

**Found.** During `PHASE_INSURANCE` the player's own two cards were invisible:
`Main._hands_to_render()` only returned terminal `_hands` (empty until after
the insurance decision) plus the presplit root, so the insurance decision was
made with no cards on the table. On a real table the opening cards are dealt
face up *before* the insurance call, so this was a realism gap.

**Fix.**
- `GameLoop.opening_roots() -> Array[CHHand]`: accessor returning a copy of the
  two-card roots dealt at hand start (additive, no existing caller touched).
- `Main._hands_to_render()`: in `PHASE_INSURANCE` it now appends the opening
  roots, so the player's hand renders alongside the dealer upcard + face-down
  hole while the insurance prompt is up. `PHASE_PRESPLIT` behavior is unchanged.

**Verification.** `scene_smoke_check._check_insurance_shows_player_hand`:
rigs a deterministic shoe (up=A, hole=10, player 7+4) on the T1 tier
(`allows_insurance=true`), deals to `PHASE_INSURANCE`, and asserts
`_hands_to_render()` returns the single two-card opening hand. Also fixed the
`Main._heat_floors_text()` tier sort to order by tier number (not the label
string) so a future T10 would not file under T1. Full suite: all pass;
`sim_validate` byte-identical. No save residue.

## M94 — Sim honors the table's insurance payout

**Found.** `sim_validate` settled the insurance side-bet with a hardcoded 2:1
(`2.0 * insurance_bet`) while the game loop settles it from
`config.insurance_payout` (see `_settle_natural`). The sim's config never sets
that field, so today both default to 2.0 and agree — but the sim is the
house-edge oracle for the engine, and a future non-2:1 insurance table would
make the sim silently disagree with the loop it validates.

**Fix.** `sim_validate._play_hand` now reads `config.insurance_payout` for the
insurance win, exactly mirroring the loop. The sim already did this for the
blackjack payout (`config.blackjack_payout`), so insurance is now consistent.

**Verification.** `sim_validate` is byte-identical (0.954% / 0.441% / −0.627%)
since the sim's config uses the default 2.0 payout. Full suite: all pass.

## M95 — Early-surrender tier + counting-systems career record

**Found.** Two built-but-inert pieces: (a) the early-surrender path
(`StrategyEngine._apply_surrender` early chart, `GameLoop._can_enter_early_surrender`
+ `_early_surrender_phase`) was fully implemented but unreachable — every tier
with `allows_surrender = true` also set `late_surrender_only = true`, so no
table ever entered the early-surrender sub-phase; (b) the counting-system
persistence (`GameState.unlocked_systems` / `unlock_system()` /
`is_system_unlocked()`) round-tripped through save/load but had zero gameplay
callers and no UI readout — a pure scaffolding hole.

**Fix.**
- Tier 4 (Four-Deck Multi-Hand) now uses early surrender
  (`late_surrender_only = false`), the forgiving form, so the player learns the
  action where surrender is first introduced before the pit tightens it to late
  on the 6-deck / CSS tiers. One-line config flip; no test pinned T4's mode.
- `Main._on_session_ended()` records `_state.unlock_system(_loop.config.count_system)`
  so each completed session marks the tier's counting system as trained
  (progression record — the tier still dictates the active system, so this does
  not override the per-tier system pinning).
- `Main._stats_lines()` gains a "Counting systems:" line built by the new
  `Main._counting_systems_text()`, which maps `hi_lo`/`ko`/`hi_opt_ii` to
  "Hi-Lo"/"KO"/"Hi-Opt II" in canonical order.

**Verification.** `scene_smoke_check` updated for the 5-line stats panel (pins
"Counting systems:  Hi-Lo, KO" against a rigged state) and the M93
insurance-phase render test; `tables_check`, `multi_hand_soak_check`,
`game_state_check`, `spot_check` all pass. `sim_validate` byte-identical.

## M95 (deferred) — 6:5 payout tier

> **Resolved by M100.** The 6:5 table was inserted as Tier 6 (skill threshold
> 85), with the continuous-shuffle tier renumbered to Tier 7+. See M100 for the
> full renumbering and verification.

Adding a 6:5 table would require inserting a new tier into the validated
6-tier ladder, which renumbers the continuous-shuffle tier (currently the "6+"
catch-all), bumps `TIER_SKILL_THRESHOLDS` to 7 entries, changes the hard-coded
`for t in 6` selector loop, the "six table tiers" help prose, the
`sim_counting_systems` tier bound, and pinned expectations in `tables_check`
(`for_tier(5)` = hi_opt_ii) and `robustness_check` (`for_tier(4)` = 4-deck).
The 6:5 payout itself is already engine-supported and tested (`game_loop_check`
drives a 1.2 payout); this is a tier-ladder design decision (where the 6:5
table sits and its skill threshold) rather than a mechanical fix, so it is
deferred for explicit sign-off.

## M96 — Robustness: count-check input hardening

**Found.** Two input-robustness gaps in the M16 count-check flow:
(a) `report_count` accepted any reported RC, so a mistyped/nonsense value
(e.g. 99999) got a 0-grade and was recorded into the accuracy mean — dragging
the skill rating with a bogus input; (b) `Main._on_count_check_submit`
cleared the panel and input *before* checking the result, so a rejected or
stale submit swallowed the player's typed value and showed a misleading
"No count check pending."

**Fix.**
- `GameLoop.report_count` now rejects a reported magnitude beyond the shoe's
  card count (`config.deck_count * 52` — a running count can never exceed it)
  by returning empty and leaving the check *pending* (retry or skip), instead
  of recording a 0-score.
- `Main._on_count_check_submit` reorders: after `report_count`, if the result
  is empty but a check is still due, it keeps the panel open with a "try
  again or Skip" prompt; only a non-rejected submit (or a genuinely stale
  panel) clears the input and closes the panel.

**Verification.** `count_check._check_rejects_implausible_report` (new): an
out-of-range report is rejected, the check stays due, and no check is recorded,
while a valid report still succeeds and clears. `count_check`,
`scene_smoke_check`, `lifecycle_check`, `css_check`, `insurance_check`,
`multi_hand_check`, `deviation_check` all pass. No new warnings.

## M97 — Discipline recovery floor

**Found.** `CHDisciplineSystem._recovery_amount()` was `BASE_RECOVERY * (discipline / MAX_DISCIPLINE)`. At discipline 0 the rate hit exactly 0, so a correct play granted +0 and the meter was stuck at the floor for the rest of the session — contradicting the documented intent that "deep holes recover slowly" (which implies they DO recover). The existing tests only probed 50 and 100, so the floor was unpinned.

**Fix.**
- `CHDisciplineSystem`: new `MIN_RECOVERY_RATE = 0.05`; `_recovery_amount()` now floors the rate with `maxf(discipline / MAX_DISCIPLINE, MIN_RECOVERY_RATE)`. A player at 0 recovers +0.1 per correct play (slow but always moving up).
- `discipline_check.gd`: new "Check 6b" pins (a) a correct play at discipline 0 recovers exactly `BASE_RECOVERY * MIN_RECOVERY_RATE` and moves off 0, and (b) the floor does not leak into the scaled rates at 50 or 100.

**Verification.** `discipline_check` all pass (including the two new floor assertions); `game_loop_check`, `count_check`, `css_check`, `insurance_check`, `lifecycle_check`, `session_length_check`, `deviation_check`, `i18_check` all pass; `sim_validate` byte-identical (0.954% / 0.441% / −0.627%). No new warnings.

## M98 — Stale true count after a mid-hand cut-change runout

**Found.** `CHGameLoop._deal_card()` handles the pathological mid-hand runout (a
multi-split outdraws the 20-card shoe reserve) by reshuffling and calling
`count.reset()` + `set_decks_remaining(...)`, but it did NOT refresh the cached
`_tc` (floored true count) that `begin_hand()` sets. So after a cut-change the
count is effectively 0 on a fresh shoe, yet `_tc` kept its pre-cut value for the
rest of that hand. Every subsequent `effective_tc()` consumer in the same hand
(I18 deviation thresholds, the insurance take/decline decision) and the heat
tell gates (`_tc >= BET_TELL_TC` / `INSURANCE_TC_THRESHOLD`) would keep using
the stale — possibly hot — count.

**Fix.** `_deal_card()` now sets `_tc = count.true_count_floor()` immediately
after `count.set_decks_remaining(...)`, mirroring `begin_hand()`, so the cached
true count is consistent with the freshly-reset count for the remainder of the
hand.

**Verification.** `robustness_check._check_runout_resets_count_and_shoe` now
establishes a nonzero `_tc` via `begin_hand()` (fresh shoe -> no reshuffle) and
pins that it is refreshed to 0 and consistent with the fresh count after the
forced runout — the regression this fix addresses. `game_loop_check` (1000
hands + invariants), `robustness_check`, `multi_hand_soak_check` (200 rounds),
`insurance_check`, `spot_check` (120/120) all pass. The fix is on a rare path so
it is a correctness hardening, not a behavior change on normal hands.

## M99 — Count-check prompt leaks keyboard focus after dismissal

**Found.** `Main._on_count_check_due` grabs focus to the `LineEdit` so the player
can type their running count. The three dismissal paths (submit, skip, cash-out)
then hide `_count_check_panel` but never release that focus. In Godot 4 a hidden
`Control` does not reliably surrender GUI focus, so the now-hidden LineEdit stays
the focus owner and `_unhandled_input`'s `gui_get_focus_owner() is LineEdit`
guard (Main.gd:890) swallows every subsequent gameplay key — bet `1`-`6`,
`H`/`S`/`D`/`R`, Space — until the player clicks a real control. A keyboard-first
player who answered the prompt with Enter would find the table unresponsive and
could not tell why.

**Fix.** New `Main._dismiss_count_check_panel()` helper clears the input, hides
the panel, and calls `release_focus()`; all three dismissal sites now route
through it. `release_focus()` is a no-op when the input never held focus and
when the scene is not in a tree (headless), so this is safe under the test
harness and correct in the live scene.

**Verification.** `scene_smoke_check` (19 checks, drives a full session through
the count-check prompt) still ALL PASS. Focus ownership itself is not assertable
headless (the test instantiates `Main.tscn` without adding it to the tree, so
`has_focus()` is always false), so this pin rests on the state contract the
smoke test does assert — panel hidden and input cleared after each dismissal —
plus the no-op-safety of `release_focus()`.

## M100 — 6:5 payout tier (Tier 6) inserted; CSS renumbered to Tier 7+

Resolves the M95-deferred 6:5 tier decision (with sign-off).

**Design.** The 6:5 table is inserted as **Tier 6** ("Six-Five Payout"), pushed
the continuous-shuffle (CSS) contrast tier from the "6+" catch-all to the "7+"
catch-all. Placing it at T6 (rather than earlier in the ladder) is deliberate:
every existing `for_tier(4)` (4-deck, in `robustness_check`) and `for_tier(5)`
(hi_opt_ii / 6-deck, in `tables_check` + deck-estimation pins) expectation stays
valid, so the only renumbering is the CSS catch-all, which the `_:` match default
already handles. T6 isolates the payout handicap as its single new lesson: 4-deck
H17, late surrender, multi-hand (2 spots), still Hi-Lo — the pit has tightened
the blackjack payout from 3:2 to 6:5 (net 1.2 instead of 1.5).

**Changes.**
- `CHTableConfig.for_tier`: new explicit `6:` case (`blackjack_payout = 1.2`,
  H17, 4-deck, late surrender, 2 spots, hi_lo); the `_: ` catch-all comment
  renumbered "6+" -> "7+" and the CSS doc comment "(Tier 6)" -> "(Tier 7+)".
- `CHGameState.TIER_SKILL_THRESHOLDS`: `[0,50,60,70,80,90]` ->
  `[0,50,60,70,80,85,90]` (new T6 threshold 85; CSS moves to index 6 = 90).
  Tiers 1-5 thresholds are unchanged, so existing unlock pins are unaffected.
- `Main._populate_tier_selector`: `for t in 6` -> `for t in 7`; help prose
  "six table tiers ... up to Tier 6" -> "seven table tiers ... up to the
  Tier 7 continuous-shuffle contrast".
- `tables_check`: sanity loop now covers `for_tier(1..7)`; new
  `_check_six_five_tier()` pins `for_tier(6)` = 6:5/1.2/H17/4-deck/late-surrender
  /hi_lo/not-CSS and that `for_tier(7)` is the CSS catch-all (8-deck).
- `sim_counting_systems`: valid-tier bound 1-5 -> 1-6 (7+ is CSS); comment
  updated.
- `multi_hand_soak_check`: the CSS soak moved from Tier 6 to Tier 7
  (`_soak_tier(7, 3)`); header comment renumbered.

**Verification.** All 21 headless tools pass. `sim_validate` baseline
byte-identical (no-split 0.954%, split 0.441%, counting -0.627%). The new T6
tier is pinned by `tables_check._check_six_five_tier` and exercised end-to-end
by the tier-7 CSS soak. The 6:5 payout value (1.2) was already engine-tested by
`game_loop_check` (M9).

## M101 — is_tier_unlocked() returns True for out-of-range tier numbers

**Found.** `CHGameState.is_tier_unlocked(tier)` returned `True` for any tier
beyond the ladder (≥8). Root cause: `_tier_threshold(tier)` returns `0.0` when
the index is out of range, and `get_skill_rating() >= 0.0` is always true, so an
out-of-range tier number always reported "unlocked." No live path reached it
today (the tier selector and `_unlocked_tiers_text` loop are bounded to
1..`TIER_SKILL_THRESHOLDS.size()`), but it is a public method that would
misreport on a bad tier number — e.g. a corrupted `unlocked_tiers` entry or a
future caller passing a dynamic value.

**Fix.** `is_tier_unlocked()` now short-circuits: `if tier > TIER_SKILL_THRESHOLDS.size(): return false`. A tier number beyond the ladder is simply not a valid tier.

**Verification.** New pin in `game_state_check._check_highest_unlocked_tier()`:
with a 100.0 skill rating, `is_tier_unlocked(size + 1)` (tier 8) must report
locked. `game_state_check` ALL PASS; full 21-tool suite green.

## M102 — Remove dead Card.display_name()

`CHCard.display_name()` (rank + suit string, e.g. "K S") had no callers anywhere
in the codebase — `Main.gd` builds card faces from `rank_text() + suit_symbol()`,
and no tool or sim references it. Removed the method. `is_ace()`/`is_ten_value()`
stay (used by `CHHand.is_blackjack`). Import clean, all 21 tools green,
`sim_validate` byte-identical.

## M103 — Mental-stability layer ("going insane" meter)

**Intent.** Surface the player's composure while counting: a run of non-optimal
plays should read as the counter "going insane," and a correct play should visibly
steady them back out. Driven from **play-decision correctness only** (the same
`actual == optimal` signal that feeds the Discipline meter) — NOT bet sizing, so a
player who bets poorly but plays the hand right is not penalized on composure, and
the meter stays a presentational read-out rather than a second scoring lever.

**Design.** New pure `RefCounted` `CHMentalStateSystem`
(`scripts/systems/MentalStateSystem.gd`), session-scoped (auto-resets on the
existing `GameLoop` recreation, matching heat/discipline). Model:
- `stability` in `MIN_MENTAL..MAX_MENTAL` (0..100), start at max.
- `on_mistake()`: `stability -= BASE_MISTAKE * (1 + ESCALATION_STEP * (streak - 1))`
  (escalating penalty on a streak — the longer you stay wrong, the faster you
  spiral); clamps to floor; `mistake_streak += 1`. Returns the applied loss.
- `on_success()`: `stability += BASE_RECOVERY * clampf(1.0 - stability / MAX, MIN_RECOVERY_RATE, 1.0)`
  (recovery scales with **how deep the hole is** — the more shaken, the more a
  correct play steadies; **floored** so a player at 0 always climbs back);
  `mistake_streak = 0`.
- Four coarse bands: CALM ≥ `CALM_THRESHOLD` (80), STRAINED ≥ `STRAINED_THRESHOLD`
  (50), FRAYING ≥ `INSANE_THRESHOLD` (25), else INSANE. `is_insane()` =
  `stability < INSANE_THRESHOLD`.

**Wiring.**
- `CHGameLoop`: `var _mental` / `var _mental_insane`; signals
  `mental_changed(stability)` / `mental_insane()`; `_init` news + resets it;
  `_grade()` calls `_feed_mental(actual == optimal)` **unconditionally** (right
  after `record_decision`, before the `grade_decisions` gate) so even the T1
  teaching table moves the meter; `_feed_mental` emits `mental_insane` on the
  crossing edge and `mental_changed` every feed. Accessors:
  `mental_stability()`, `mental_state()`, `is_mental_insane()`,
  `get_mental_system()`.
- `Main.gd`: new `_mental_label` HUD label ("Mental: ...") shown on **every**
  tier (the feed is unconditional, so it is meaningful even with scoring off);
  `mental_changed` refreshes the HUD, `mental_insane` shows a transient status
  notice ("INSANE — you're losing your grip..."); `_mental_state_text()` /
  `_mental_color()` map band → label text and neutral→warm→hot colour.

**Verification.** New `tools/mental_check.gd` (SceneTree, 9 checks): fresh state,
escalation (2nd mistake costs more than 1st), success recovery + streak reset,
floored recovery at 0, the four state bands, the exact insanity boundary
(`at threshold` = not insane, `just below` = insane), `reset()`, and two
`CHGameLoop` integration pins (a wrong play erodes + sets streak to 1; a correct
play keeps streak 0 + CALM) — ALL PASS. Required a one-time global-class-cache
regeneration (`--headless --import`) because `CHMentalStateSystem` is a new
`class_name`. All 21 prior headless tools still green; `sim_validate`
byte-identical (no-split 0.954%, split 0.441%, counting -0.627%).

## M104 — Mental-stability durability: session peak + debrief line + HUD percentage

M103 shipped the live meter but its output was **ephemeral** — the HUD label
scrolls off as hands play, so a player could not look back and see *how badly*
they spiralled or *how long* a mistake run lasted. Three small, contained
improvements make the layer's output durable and consistent with the other
meters.

**1. Track a session peak mistake streak.** `CHMentalStateSystem` gains
`max_mistake_streak: int = 0`: `on_mistake()` records
`max_mistake_streak = max(max_mistake_streak, mistake_streak)` after incrementing
the live run, and `reset()` clears it to 0. This is a session-level record (the
longest consecutive-miss run), distinct from the live `mistake_streak` (which
resets on any correct play). `CHGameLoop` exposes it via
`max_mental_mistake_streak()`.

**2. Debrief composure line.** `_show_debrief` now appends
`Composure:  peaked at N consecutive mistake[s]` (only when `N > 0`, so a clean
session shows no line — mirroring how the Decisions and Counting lines are
conditional). The reserved debrief label slots grew from 9 → 10 to hold it.

**3. HUD label now shows the percentage.** The mental HUD label went from
`Mental: <band>` to `Mental: <pct>% <band>`, reading `mental_stability()`
(directly a 0–100 value since `MAX_MENTAL == 100`) and matching the heat meter's
`Heat: <pct>%` format. This also let us **delete the now-redundant
`CHMentalStateSystem.percent()` accessor** (it returned `stability / MAX_MENTAL`,
i.e. the same number 0–1 with no remaining caller) — consistent with the M102
dead-code cleanup.

**Verification.** `tools/mental_check.gd` gains two pins: `_check_loop_max_streak`
(loop accessor is 0 on a fresh loop, 1 after one wrong play) and an extended
`_check_max_streak` (peaks at 2, persists across a correct play, extends to 3,
cleared by `reset()`). All 24 tools green (mental_check now 11 checks);
`sim_validate` byte-identical (0.954 / 0.441 / −0.627). No save residue.

## M105 — Multi-hand natural settlement auto-lost the non-natural spots

**Found.** In `CHGameLoop._after_insurance`, the condition that settled the whole
round was `any_player_bj or dealer_bj`. On a multi-hand table (T4–T7), a single
natural spot routed the *entire* round into `_settle_natural`, which settles
every root: the natural spot(s) win 3:2, and every **non-natural spot loses its
full bet** instead of playing. In real multi-hand play a natural on one spot only
settles that spot; the other spots continue through the normal presplit/hand
flow. The error was on the player's side of the table — they lost money and a
decision opportunity they never got to make.

**Fix.** `CHGameLoop` splits the two cases:
- `dealer_bj`: unchanged — the whole round settles against the dealer natural
  (naturals push, non-naturals lose; early-surrender escape preserved).
- `any_player_bj and not dealer_bj` (new): the hole is revealed, each natural
  spot's win (`_base_bet * blackjack_payout`) and stake is accumulated into new
  members `_pre_settled_profit` / `_pre_settled_wagered`, any taken insurance is
  forfeited there (dealer has no natural) and `_insurance_bet` zeroed to prevent
  double-count, `_roots` is filtered to the non-natural spots, and the round
  continues through the normal `_process_next_root()` flow. If every spot was a
  natural the round finalizes immediately from the pre-settled values; otherwise
  `_play_dealer_and_settle` folds `_pre_settled_profit` / `_pre_settled_wagered`
  into its final profit/wagered. Both accumulators reset in `begin_hand()`.

Single-spot tiers are behavior-identical: with one root the new branch
accumulates exactly what `_settle_natural` used to compute and finalizes the same
P&L, so M34's natural-win pin still holds.

**Verification.** New `multi_hand_check` check 9
(`_check_one_natural_other_spot_plays`): 2 spots, base bet 3, dealer 5+10 (no
natural); s1 = A,K (natural), s2 = 10,8 (18). The engine stands 18 vs 5 and the
dealer (15) hits a 2 to 17, so s2 wins: net +7.5 (s1 +4.5, s2 +3.0), wagered 6.
The pre-M105 code settled the whole round and read net +1.5 (s2 auto-lost).
All 21 headless tools green; `sim_validate` byte-identical (0.954 / 0.441 /
−0.627) — the sim is single-hand, so the baseline is unaffected by construction.

## M106 — Mental-layer refinements: recovery signal, dead member removal, soak bound fix

Three small improvements to the mental-stability layer shipped in M103/M104.

**1. Dead member removal.** `CHGameLoop` had `var _mental_insane: bool` that was
initialized in `_init` but never read or written anywhere else — `is_mental_insane()`
reads `_mental.is_insane()` directly. Removed the member and its initializer.

**2. `mental_recovered` signal.** `mental_insane` fires on the entry edge
(not-insane → insane) but there was no symmetric signal for the exit edge.
A player who was told "INSANE — you're losing your grip" got no affirmative
confirmation when they pulled back out. Added `signal mental_recovered()` to
`CHGameLoop`, emitted in `_feed_mental` when `was_insane && !is_insane()`.
`Main.gd` connects it to a transient status line: "Back in your head — composure
recovered."

**3. Soak-check bound was too strict.** `multi_hand_soak_check` asserted
`net <= wagered`, which is false on 3:2 tables where a natural pays 1.5× its
stake. After M105 let non-natural spots play out alongside a natural, the
soak correctly produced net > wagered rounds (e.g. natural + two wins = 3.5
on 3.0 wagered). The bound is now `net <= wagered * blackjack_payout` — the
true maximum payout per unit staked on these insurance-free tables.

**4. `mental_check` signal-edge pin.** New check drives one loop through a
deliberate crossing-in (set stability just above threshold, force one mistake)
and a crossing-out (set stability just below, force one correct play), asserting
each signal fires exactly once and the inverse does not fire.

**Verification.** All 21 headless tools + `multi_hand_soak_check` green;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627).

## M107 — Process-score composition: named blend weight + redundant accessor removed

Two maintainability cleanups to the session process-score path (the value that
feeds the skill-rating EMA), found while auditing for latent refactor traps.

**1. The blend weight was a magic number.** `CHGameLoop._session_process_score()`
did `lerpf(discipline.discipline, _count_accuracy.accuracy, 0.5)` — an unexplained
equal-weight blend. Extracted to a named, documented constant
`PROCESS_BLEND_COUNT_WEIGHT` (0.5): the complement (1 − weight) is discipline's
share. Value unchanged, so behaviour and all pins are untouched — this is purely
a clarity/tunability change.

**2. `CHCountAccuracySystem.process_score()` was a redundant alias.** It returned
`MAX_ACCURACY` when `checks <= 0`, else `accuracy` — but `accuracy` is *already*
`MAX_ACCURACY` when no checks have been recorded (it is initialised and reset to
`MAX_ACCURACY` and only moves inside `record()`). So `process_score()` was always
identical to the public `accuracy` field, with a name that implied it computed the
blended process score when it does not (the blend lives in the loop). Removed it
(the single remaining caller, `count_check._check_no_check_neutral`, now asserts on
`accuracy` directly). Consistent with the M102/M106 dead-code hygiene.

**Verification.** `count_check` (now asserting on `accuracy` for no-check
neutrality), the full 21-tool suite, and `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). No behaviour change.

## M112 — Sanity layer decoupled from the HUD; `mental_band_changed` signal added

The mental-stability system was originally built as a *visible* composure meter:
a "Mental: NN% <band>" HUD label, INSANE / "Back in your head" status toasts, a
"Composure" debrief line, and the `×N run` streak tag added in the previous pass.
That framing is now abandoned. Sanity is intended to be a **hidden** state that
drives *ambient effects* (intrusive-thought overlays, music shifts, screen
distortion) in a later pass, not a number the player reads and manages. So this
pass removes the player-facing surface while keeping the underlying model
intact and testable.

**Removed from `Main.gd` (presentation only — no P&L/heat/skill effect):**
- The `Mental:` HUD label (declaration, creation, and its per-frame refresh
  block including the `×N run` suffix).
- The `mental_insane` / `mental_recovered` status toasts and their handlers
  (`_on_mental_insane`, `_on_mental_recovered`) plus their signal wiring.
- The "Composure: …" debrief line; the debrief label pool shrank 10 → 9.
- The now-orphaned `_mental_state_text` and `_mental_color` helpers.

**Kept / added:**
- `CHMentalStateSystem` is unchanged (still the source of truth).
- All `CHGameLoop` mental accessors remain (`mental_stability`, `mental_state`,
  `is_mental_insane`, `mental_mistake_streak`, `max_mental_mistake_streak`,
  `get_mental_system`), so future effect systems can read state.
- New `CHGameLoop.mental_band_changed(old_band, new_band)` signal, emitted in
  `_feed_mental` on *any* transition between the four bands — the hook an
  incoming audio/visual effect layer will subscribe to (rather than only the
  binary insane/not-insane edge).

**Tests.** `mental_check` gains check 11 `_check_band_changed_signal`: forces
three wrong plays from a calm start and asserts the signal fires exactly once,
on the calm→strained crossing, carrying the correct old/new band strings.

**Verification.** `mental_check` (now 14 checks) green; `scene_smoke_check`
green (confirms `Main.gd` still loads with all UI removed); `sim_validate`
byte-identical (0.954 / 0.441 / −0.627). No P&L, heat, or skill impact.

## M108 — Mental-stability recovery flipped to match the Discipline meter

The mental layer's `on_success` recovery was inverted relative to Discipline:
`rate = 1 - stability/MAX`, so a fully-insane player (stability 0) recovered
*fastest* (6.0/play) and a composed player slowest (0.3/play). Probe result:
from stability 20 (insane) only **2 correct plays** escaped the INSANE band,
making "insanity" a brief blip rather than the sustained spiral the concept
models — and it contradicted the one recovery philosophy already committed to
in M97 ("deep holes recover slowly", `rate = discipline/MAX`).

**Change.** Flipped the rate to `rate = clampf(stability / MAX_MENTAL,
MIN_RECOVERY_RATE, 1.0)`: the more composed the player already is, the quicker
the top-up; a deeper hole now takes *more* correct plays to climb out (from 20,
4 correct plays to leave INSANE instead of 2). This is the direction the
`MIN_RECOVERY_RATE` comment always described ("a player at the floor still
steadies a little… never stuck at 0") — the code had the formula backwards, so
the flip makes the code match its own docs. From 0 the floor now genuinely
applies (rate → 0, floored to 0.05, +0.3), and the `BASE_RECOVERY` /
`MIN_RECOVERY_RATE` comments were updated to describe the corrected behaviour.

Presentational-only (feeds HUD + debrief, nothing into P&L/skill/heat), so no
sim impact.

**Tests.** `mental_check.gd`:
- New `3b. _check_recovery_direction` pins the flipped direction: a correct
  play at stability 70 (composed) recovers more than at 30 (shaken), and the
  shaken gain equals `BASE_RECOVERY * 0.30` (within an epsilon — `on_success`
  returns `stability - before`, an add-then-subtract that is not bit-identical
  to the raw product). Catches a future re-inversion.
- `10. _check_mental_signal_edges` crossing-out start raised from
  `INSANE_THRESHOLD - 1.0` to `- 0.5` (24.5 → ~25.97): recovery is now slower,
  so the thin 24 → 25.44 margin was widened for robustness.
- `4. _check_floored_recovery` now genuinely exercises the floor (0 → +0.3)
  instead of the max-rate path.

**Verification.** `mental_check` (now 13 checks, incl. the new direction pin)
and `game_loop_check` green; `sim_validate` byte-identical
(0.954 / 0.441 / −0.627).

## M109 — Ace-upcard (dk=14) strategy audit + soft-table regression pins

Closed the open investigation into whether `CHHand.dealer_upcard_key(rank)`
returning **14** for an Ace upcard is handled correctly by the strategy
tables (only 10–13 map to 10; 14 passes through unchanged).

**Audit.** Walked every `match`/branch on `dealer_key` in
`StrategyEngine.gd`:
- **Hard:** 11/10/9 double ranges (`dk <= 10`, `2..9`, `3..6`) all exclude 14 → `hit`; 12–16 stand ranges (`2..6` / `4..6`) exclude 14 → `hit`; 17–21 stand regardless. All correct vs an Ace.
- **Soft:** 19 stand range `2..6`, 18 stand `2/7/8`, 18 double `3..6`, 17 double `3..7`, 16 double `3..6`, 15 double `4..6` — none include 14 → all `hit` vs A. Correct.
- **Pair:** `A,A` → split (rank-based, dk-agnostic); `9s` split `2..9` excludes 14 → `hit`; `8s` split all; `10s` stand. Correct.
- **Surrender:** `16 vs dk>=9` and `15/14/13 vs dk==10` — 16 vs A (14≥9) correctly surrenders; 15/14 vs A not in the chart (intentional, see below).

Conclusion: **dk=14 is handled correctly** by the existing tables. No
behavioural change.

**Known out-of-scope gap (documented, not fixed):** 15-vs-A and 14-vs-A early
surrender are not in the chart. Standard basic-strategy charts often include
15 vs A for early surrender, but the engine's surrender set is a deliberate,
tunable subset and extending it would change P&L, so it is left as a
playtest-tuning item, not a correctness fix.

**Change.** Hard- and pair-table Ace-upcard cells were already pinned
(`spot_check` lines 40/43/50/84/89/93/183/204), but the **soft** table had no
dk=14 coverage. Added five soft-vs-A pins to `spot_check.gd` (soft 15/16/17/18/19
vs A → all `hit`), locking in the audit result.

**Verification.** `spot_check` now 125/125 (was 120/120). `sim_validate`
byte-identical (0.954 / 0.441 / −0.627); `sim_counting_systems` unchanged
(Tier 1 counting −0.5670%). No behaviour change.

## M110 — Stale tier comment on `count_check_active` corrected

While auditing `CHTableConfig.for_tier` for cross-tier consistency, found the
field comment on `count_check_active` read "Run a running-count accuracy check
at each shoe cut (Tier 1-5). Off on the continuous-shuffle tier…". T6
("Six-Five Payout") also sets `count_check_active = true`; only the CSS catch-all
(T7+) leaves it off. The comment was stale from before T6 was authored and would
mislead a reader into thinking the T6 count check was a bug. Reworded to
"every tier except the continuous-shuffle tier."

Docs-only; no behaviour or sim impact.

## M111 — `sim_counting_systems` now models count-based insurance (fidelity fix)

**Found.** `tools/sim_counting_systems.gd` documents — in three places
(header line 13, `_sim_config` comment, and the "only difference is the count"
note) — that its counting run includes "count-based insurance," and it is the
designated cross-check of `sim_validate` on Tier 1. But its `_play_hand`
**never implemented insurance**: no `insurance_bet`, no offer/decision, no
settlement. `sim_validate._play_hand` does implement it. On the two
insurance-enabled tiers (T1, T2) this meant the tool validated a *no-insurance*
policy that differs from both its own docs and the actual game loop
(`CHGameLoop._apply_insurance` + the natural / M105 settle paths).

**Change.** Ported the three insurance pieces from `sim_validate._play_hand`
into `sim_counting_systems._play_hand`, keeping the same `insurance_payout`
config read so any non-2:1 table stays consistent:
- `insurance_bet := maxi(1, int(base_bet / 2))` when
  `allows_insurance and upcard == Ace and should_take_insurance(tc_floor)`.
- Natural branch: `ins_profit = payout * bet if dealer_bj else -bet`.
- Non-natural path: a taken side-bet is a loss (dealer has no BJ there).

Effect is limited to `allows_insurance == true` tiers (T1/T2). T3–T6 have
insurance off, so their numbers (including the M67 T5 reference, 1.0505%) are
untouched.

**Verification.** Tier-1 counting moved from −0.5670% → **−0.6613%** (insurance
taken at TC≥3 is +EV at high count, so the counting edge improves and now sits
*closer* to `sim_validate`'s −0.627% than the old no-insurance figure did).
`sim_counting_systems` stays green (counting beats basic by the full
~0.98pp; all sanity bands pass). `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). The "reproduces sim_validate's numbers" docstring line
was reworded: the counting *policy* now matches (enabling cross-validation),
but exact numbers were never guaranteed to coincide (the two tools have
independent hand loops).

## M112 — Live mistake-streak readout on the mental HUD (M103/M108 follow-through)

The mental layer tracked a *live* mistake run (`CHMentalStateSystem.mistake_streak`)
but surfaced only the stability percentage + coarse band in the HUD. The "insane"
notice fires only once the player crosses the 25-stability threshold, so a spiral
in progress (e.g. a 3-mistake run at 60%, still "fraying") was invisible until it
already hit the floor — defeating the trainer's purpose of warning the player
*before* composure breaks.

**Change.**
- `CHGameLoop.mental_mistake_streak()`: new accessor returning the live run
  (mirrors `max_mental_mistake_streak()`, which is the session peak).
- `Main.gd` HUD: when the live run is non-zero the mental label now appends a
  `×N run` tag — `Mental: 64% Fraying ×3 run`. The tag disappears on the next
  correct play (the run resets to 0), so it is a pure leading indicator that
  tracks the spiral in real time.

Presentational only: no P&L/skill/heat coupling, no sim impact.

**Tests.** `mental_check.gd` new `6c. _check_loop_live_streak` pins the accessor:
0 when fresh, 1 after a wrong play, and exact equality with the model's
`mistake_streak` (the reset-on-correct behaviour is already pinned at the model
level in check 3).

**Verification.** `mental_check` (now 14 checks) green; `sim_validate`
byte-identical (0.954 / 0.441 / −0.627); `scene_smoke_check` green.

## M113 — Sanity layer made invisible; `mental_band_changed` signal added (supersedes M112's visible HUD)

Design direction change: sanity should be a **hidden** state that drives ambient
effects (intrusive-thought overlays, music shifts, screen distortion) — not a
number the player reads and manages. This removes the player-facing surface added
across M103/M104/M106/M112 while keeping the model, loop accessors, and signals
intact as a clean head for the upcoming effect layer.

**Removed from `Main.gd` (presentation only — no P&L/heat/skill impact):**
- The `Mental: NN% <band>` HUD label (declaration, creation, per-frame refresh,
  and the `×N run` tag from M112).
- The "INSANE — losing your grip" / "Back in your head" status toasts and their
  handlers (`_on_mental_insane`, `_on_mental_recovered`) + signal wiring.
- The "Composure: …" debrief line; the debrief label pool shrank 10 → 9.
- The now-orphaned `_mental_state_text` / `_mental_color` helpers.

**Kept / added:**
- `CHMentalStateSystem` and all `CHGameLoop` mental accessors (`mental_stability`,
  `mental_state`, `is_mental_insane`, `mental_mistake_streak`,
  `max_mental_mistake_streak`, `get_mental_system`) — unchanged, still the source
  of truth.
- New `CHGameLoop.mental_band_changed(old_band, new_band)` signal, emitted in
  `_feed_mental` on *any* transition between the four bands (calm/strained/
  fraying/insane). This is the subscription point the future audio/VFX effect
  systems will use (rather than only the binary insane/not-insane edge that
  `mental_insane`/`mental_recovered` cover, which remain for that specific case).

**Tests.** `mental_check.gd` gains check 11 `_check_band_changed_signal`: forces
three wrong plays from a calm start and asserts the signal fires exactly once on
the calm→strained crossing, carrying the correct old/new band strings.

**Verification.** `mental_check` (now 15 checks) green; `scene_smoke_check` green
(confirms `Main.gd` still loads with all sanity UI removed); `sim_validate`
byte-identical (0.954 / 0.441 / −0.627). No P&L, heat, or skill impact.

## M114 — First ambient effect: intrusive-thought overlay on band degradation

M113 made the sanity layer invisible and added `mental_band_changed` as the
subscription point for ambient effects. This pass delivers the first effect:
a subtle "intrusive thought" overlay that fades in when the hidden sanity band
degrades into `fraying` or `insane`, holds ~3s, then fades out.

**Design rationale:** The overlay is a transient visual cue, not a meter. It
gives the player an atmospheric signal that composure is slipping without
displaying a numeric stability value or band name — preserving the "hidden
state" design intent from M113.

**Implementation (`Main.gd`):**
- `THOUGHTS` constant: pool of 10 thematically appropriate intrusive-thought
  strings (first-person, casino/counting context).
- `THOUGHT_COOLDOWN_SEC = 8`: minimum interval between thoughts to prevent
  spam when the band flaps between fraying and strained.
- `_thought_label`: a `Label` node anchored at the vertical center of the
  play area (PRESET_CENTER_TOP) so it clears the HUD, dim warm-grey with
  shadow for legibility over the table. Hidden by default.
- `_build_thought_label()`: creates the label, added last in `_build_ui` so
  it draws above help/stats overlays.
- `_on_mental_band_changed(old_band, new_band)`: connected to the M113
  `mental_band_changed` signal. Only reacts to transitions *into* fraying or
  insane (recovery is silent). Respects the cooldown. Picks a random thought.
- `_show_thought(text)`: fade-in (0.6s) → hold 3s → fade-out (0.8s) via
  `create_tween()`. The tween is killed before a new one starts to prevent
  half-faded leftovers on rapid re-triggers.

**Also fixed (found while verifying):** `scene_smoke_check._check_active_hand_index`
had a test bug: it assumed tier 1 could only reach `PHASE_HAND` after a bet.
Since tier 1 allows splits (`allows_split = true`), a dealt pair lands in
`PHASE_PRESPLIT` where `_active_hand_index` correctly returns 0. The test now
explicitly handles `PHASE_PRESPLIT` as a valid active-hand phase for the
single-hand case.

**Verification.** `scene_smoke_check` ALL PASS; `mental_check` ALL PASS (15
checks); `Main.gd` and `scene_smoke_check.gd` parse clean; `sim_validate`
byte-identical (0.954 / 0.441 / −0.627). No P&L, heat, or skill impact.

## M115 — Hygiene: removed stale generated dump; added `tools/run_all.ps1` suite runner

**Found.** A codebase audit flagged two things:
1. `tools/_all_gd_dump.txt` — a 262 KB generated concatenation of every `.gd`
   file, sitting in the source tree and not gitignored. Stale by definition and
   a grep hazard. Removed it.
2. No way to run the whole 25-tool check suite in one command — checks were
   each launched individually.

**Change.**
- Deleted `tools/_all_gd_dump.txt`.
- Added `tools/run_all.ps1`: runs every `tools/*_check.gd` plus `sim_validate`
  headless in sequence, shows only PASS/FAIL lines per script, and exits
  non-zero listing any failed scripts. `-AllSim` adds the slower
  `sim_counting_systems` + `sim_multiseed` runs.

**Verification.** `run_all.ps1` executed the full default set: **ALL PASS
(23 scripts)**, with `sim_validate` byte-identical (0.954 / 0.441 / −0.627).

## M116 — Tutorial mode: a three-stage, no-stakes counting on-ramp

New session mode for players who are not yet ready to commit money and play
decisions. The premise (per the design brief): first the player just keeps the
running count while the engine plays the hands, then one mechanic is introduced
per shoe as they advance.

**Design.** Three stages, one shoe each (stage = `clampi(shoes_this_session+1, 1, 3)`):
- **Stage 1 — count only.** No betting, no decisions. The engine auto-bets and
  auto-plays every hand; the player's only job is keeping the running count and
  reporting it at each shoe cut.
- **Stage 2 — + manual betting.** The player places the bet on the true count;
  the engine still auto-plays the strategy.
- **Stage 3 — full manual.** Standard play (bet + every decision by hand).

No stakes (like practice — the bankroll is decorative; a catastrophic loss
cannot end the session). Anchored to the Tier-1 teaching table with heat **off**
and the live count display **off** (the player is the count, not the readout).
Count checks stay **on** — the shoe-cut count report is the forcing function that
advances the on-ramp. The session ends with reason `tutorial_complete` after the
third shoe.

**Changes.**
- `GameState.gd`: `MODE_TUTORIAL := "tutorial"`, `TUTORIAL_TOTAL_SHOES := 3`;
  `apply_hand_result` is no-stakes for tutorial; `on_shoe_finished` ends with
  `"tutorial_complete"` after three shoes.
- `GameLoop.gd`: `tutorial_stage()` accessor (0 when not in an active tutorial
  session, else the clamped stage).
- `Main.gd`: "Tutorial" in the mode selector (index 3, tier selector disabled,
  forced to tier 1); `_start_session` applies the tutorial table overrides and
  resets the intrusive-thought overlay; new `_tutorial_stage_label` (HUD, names
  the stage + what's being practiced) and `_tutorial_next_button` ("Next
  (Space)") built in `_build_ui`; `_refresh_actions` gates the bet/action/deal/
  Next controls by stage (stage 1 hides bet+action and deals via Next; stage 2
  keeps betting manual and auto-plays; stage 3 is fully manual); `_on_tutorial_next()`
  is a one-step advance machine (idle→begin hand + auto-bet in stage 1, then
  auto-apply `optimal_action()` in stages 1–2), always gated by the pending count
  check; `_unhandled_input` routes Space→`_on_tutorial_next` and Enter→count
  submit in stages 1–2 and ignores the manual H/S/D/1-6 keys so a stray press
  can't slip a manual decision into the guided flow; debrief P&L suffix reads
  "tutorial — no stakes".

**Tests.**
- `tools/tutorial_check.gd` (new): loop/state logic — `tutorial_stage()` is 0
  outside a tutorial, progresses 1→2→3 across the three shoes ending in
  `tutorial_complete`, and a −500 loss neither moves the bankroll nor ends the
  session (no stakes). Redirects `save_path` to a throwaway file.
- `scene_smoke_check.gd` `_check_tutorial_mode` (new): the scene-level UI wiring
  `tutorial_check` can't reach — mode/tier anchoring, the `_start_session` config
  overrides (heat off, count display off, count checks on), stage-1 control
  visibility (deal hidden, Next visible, all bet/action/cover controls hidden),
  and that one Next press begins + auto-bets a live hand with the dealer upcard
  dealt.

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`tutorial_check` and the new `scene_smoke_check` tutorial check both green;
`Main.gd`/`GameState.gd`/`GameLoop.gd` parse clean; `sim_validate` byte-identical
(0.954 / 0.441 / −0.627). No P&L, heat, or skill impact on the existing modes.

## M117 — Tutorial stage-transition banner + progress marker

M116 made the stage label update silently. This pass makes the on-ramp's two
pivotal moments explicit:

1. **Stage-transition banner.** A dedicated `_tutorial_banner` label (18 px,
   teal-green, below the thought overlay) fades in for ~5 s when the stage
   rises past 1, naming the mechanic just unlocked. The stage-2 banner also
   quotes the player's running count accuracy so far (from `CHCountAccuracySystem`)
   so they know how well they tracked before being asked to bet on the count.
   Stage 3 gets its own banner. The banner is monotonic within a session
   (`_last_tutorial_stage`); a new session resets it.

2. **`N/3` progress marker** in the stage label text: "Tutorial 1/3 — …",
   "Tutorial 2/3 — …", "Tutorial 3/3 — …".

**Implementation.** `_show_tutorial_banner(text)` mirrors `_show_thought` but
with a longer hold (4 s) and an `is_inside_tree()` guard so the tween is only
created in a live scene (headless tests build the UI without a root, and
`create_tween()` on a node outside the tree logs a warning). `_refresh_hud`
calls `_maybe_announce_tutorial_stage(stage)` on every HUD refresh; the
tracker is monotonic so a repeated refresh at the same stage is silent.

**Tests.** `scene_smoke_check._check_tutorial_mode` extended:
- banner label exists and is hidden at rest
- `_stage_transition_text(2)` / `(3)` produce the expected prefixes
- `_maybe_announce_tutorial_stage(2)` from stage 1 shows the banner with the
  correct text; re-calling with the same stage is idempotent
- `_maybe_announce_tutorial_stage(3)` fires the stage-3 banner
- a lower live-stage read does not re-fire the banner; tracker stays monotonic

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627). No P&L, heat, or
skill impact on the existing modes.

## M118 — Tutorial polish: stage-2 keyboard betting + "press Next" nudge

Two gaps in the M116 tutorial on-ramp found in review:

1. **Stage-2 keyboard gap.** The M116 keyboard gate let only Space/Enter
   through in stages 1-2, but stage 2 requires *manual* betting — a keyboard
   player had no way to bet. Fix: in stage 2 during the BET phase, keys 1-6
   place a bet and C toggles cover (the same path the bet buttons use). Stage 1
   still blocks every non-essential key because the engine auto-bets there.

2. **Post-hand guidance.** In stages 1-2 the player advances with "Next", but
   after a hand settled the status line only said "Hand settled: ±N". It now
   appends "— press Next to continue" so the next step is obvious.

**Changes.**
- `Main.gd _unhandled_input`: stage-2 branch routes KEY_1..KEY_6 →
  `_on_bet_units()` and KEY_C → cover toggle while in the BET phase; the rest
  of the guided flow still ignores stray keys.
- `Main.gd _on_hand_settled`: appends the "press Next" hint for stages 1-2.
- `scene_smoke_check._check_tutorial_mode`: pins the stage-1 keyboard gate
  (KEY_1 and KEY_H are no-ops in the decision phase; phase unchanged).

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627).

## M119 — Tutorial stage-2/3 bet-ramp feedback (teaching-table exemption lifted for tutorial)

Stage 2 of the tutorial exists to teach betting on the true count, yet the player
got no feedback on whether their bet size matched the count. The post-bet feedback
line ("Bet: Ndu — optimal was Mdu") is gated in `_on_bet_units` by
`config.grade_bet_ramp`, which is **off** for the tier-1 teaching table the
tutorial runs on — so a manual bet in stage 2 committed silently with no signal
of right/wrong.

**Change.** `Main.gd::_on_bet_units`: the ramp-feedback condition now also fires
when `session_mode == MODE_TUTORIAL`, alongside the existing `grade_bet_ramp`
gate. Presentation-only (no Discipline score movement); because stage 1 auto-bets
through `CHGameLoop.place_bet` (never this handler), the feedback naturally
surfaces only in stages 2 and 3 — exactly where the player places the bet by hand.

**Tests.** `scene_smoke_check._check_tutorial_mode` extended: a forced stage-2
session (`shoes_this_session = 1`) deals into BET, and `_on_bet_units(2)` yields a
"Bet: " status line (feedback shown); a practice-mode session on the same tier-1
table with the same call stays silent (no ramp feedback), pinning that the
exemption is tutorial-scoped, not a global tier change.

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627).

## M120 — Tutorial: unified Next deal in stage 2 + per-stage counting in the debrief

Two gaps in the tutorial on-ramp from the M116–M119 passes:

1. **Stage 2 had two competing "deal" controls.** In stage 2 the `Deal` button
   was visible while idle (`_deal_button.visible = is_idle() and stage != 1`) while
   the `Next` button was *hidden* while idle — so the M118 "press Next to continue"
   hint was wrong for stage 2 (the player had to press `Deal`/Space instead). Now
   `Deal` is hidden in both guided stages (`stage == 0 or stage == 3`) and `Next` is
   shown whenever the player is not choosing a bet in stage 2 (`not in_bet`, covering
   both idle and the decision phase). `Next` is now the single advance control in
   stages 1–2; stage 3 and normal modes keep `Deal`. `_on_tutorial_next` already
   handled the idle→begin_hand step, so no change was needed there.

2. **The debrief showed only an aggregate counting score.** The on-ramp is about
   learning to count, but the player saw a single session-wide number with no sense
   of how tracking improved across the three stages. Now the per-shoe count-check
   scores are captured and the debrief breaks them down by stage.

**Changes (`Main.gd`).**
- `_refresh_actions`: `_deal_button.visible` now `is_idle() and (stage == 0 or stage == 3)`;
  stage-2 `next_visible` is `not in_bet` (was `not in_bet and not is_idle()`).
- New `_tutorial_count_results` (array of `{stage, reported, actual, score}`) and
  `_pending_count_check_stage` vars, reset in `_start_session`.
- `_on_count_check_due` records the stage the check belongs to. Because the shoe
  boundary has already advanced `shoes_this_session` by the time the check fires, the
  stage that just ended is `maxi(tutorial_stage() - 1, 1)`.
- `_on_count_check_submit` appends the graded result to `_tutorial_count_results` when
  in tutorial mode.
- New `_tutorial_counting_summary()` groups the recorded scores by stage and returns
  `"Counting:  S1 95%  |  S2 100%"` (empty string when nothing was reported, e.g. every
  check was skipped). `_show_debrief` uses it in place of the aggregate line when the
  session is a tutorial.

**Tests.** `scene_smoke_check._check_tutorial_mode` extended: a forced stage-2 session
(`shoes_this_session = 1`) confirms `Deal` is hidden and `Next` visible while idle, that
`Next` deals into BET and then hides while `bet_buttons[1]` shows (the manual-bet step),
and that `_tutorial_counting_summary()` returns `""` on empty input, groups by stage, and
reports the per-stage averages (S1 = 95 from two checks, S2 = 100).

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627).

## M121 — Tier 1 teaching table becomes count-only (no bet / cover / play controls)

The Tier 1 teaching table was meant to be the "what to look for" drill — train the
eye on tracking the running count before adding bets, cover, and play decisions.
But it shipped with the full control set live: the 1u–6u bet buttons, the Cover
toggle, insurance, and every hit/stand/double/split/surrender action were all
available, so a first session mixed counting with staking and strategy. A player
could (and would) bet and play while still learning to count, which muddies the
single skill the tier is supposed to isolate.

**Change.** Tier 1 is now a *count-only* table. The player deals hands; each hand
deals and plays itself to resolution using the engine's optimal actions, and the
only thing the player does is report the running count (a number such as `+3` or
`−2`) after each hand. No bet, cover, insurance, or play control is offered.

- `CHTableConfig.count_only` (new, default `false`) + `for_tier(1)` sets it true.
  It is the single source of truth for "this table is a pure counting drill."
- `CHGameLoop.auto_play_round()` (new): from `PHASE_BET` it places the count-optimal
  ramp bet and then drives the round to `PHASE_SETTLED` via `optimal_action()`,
  so the hand resolves with no player input. No-op unless in `PHASE_BET` (safe to
  call blindly). A bounded guard (64 steps) protects against a pathological
  non-terminating decision loop.
- `CHGameLoop` count checks: on a count-only table the running-count quiz fires
  **after every hand** (`_finalize`, when the session did not just end) so the
  player is graded on each hand they just watched; the shoe-cut check is
  suppressed in count-only mode (`start_or_next_shoe`) so the same count is not
  asked twice at the boundary. Non-count-only tiers keep the existing shoe-cut
  cadence unchanged.
- `Main.gd`: `_on_deal()` calls `auto_play_round()` when `config.count_only`, so
  the teaching table settles each hand without the player touching a decision.
  `_refresh_actions()` hides all bet / cover / play controls under
  `config.count_only` and keeps the Deal button gated while a count report is
  pending (the report is the only interaction, so it must be answered before the
  next hand is dealt). The keyboard idle/settled path honours the same gate
  (Enter submits the report; Space waits). `_on_count_check_due` phrases the
  prompt for the per-hand drill on count-only tables.
- `Main.gd::_start_session`: Tutorial mode disables `count_only` (the on-ramp
  needs bet/play controls for its staged stages 2–3), so the guided tutorial is
  unaffected.

**Tests.**
- `scene_smoke_check._check_count_only_teaching_table` (new): asserts T1 is
  `count_only`; that `_on_deal()` auto-plays a hand straight to `PHASE_SETTLED`
  (the player never sits in BET); that every bet / cover / play control is hidden;
  that the deal button is gated while the per-hand count report is pending and
  re-enabled once it is answered.
- `tables_check._check_tier1_defaults`: now asserts `count_only` on T1.
- `tutorial_check._make_loop` sets `count_only = false` (mirrors the scene override)
  so the guided on-ramp keeps its staged bet/play teaching.
- Three existing scene checks that drive the *normal* keyboard/deal/bet model on a
  T1 session (`_check_insurance_prompt_rendering`, `_check_keyboard_shortcuts`, and
  the M119 stage-2 negative control) set `count_only = false` because they exercise
  the non-auto-play control paths in isolation; their assertions are otherwise
  unchanged.

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627) — the sim drives its own
shoe/hand loop and never calls `CHGameLoop._finalize`/`auto_play_round`, so the
loop-side change is a no-op for it. `sim_counting_systems` unchanged
(counting −0.6613%, basic 0.3215%).

## M122 — Count-only T1: pressure-free (suppress player-agency heat) + count-focused status

Two refinements to the M121 count-only teaching table.

1. **Heat tells are noise on a count-only table.** Heat exists to catch the *player*
   revealing count knowledge through their choices (big bet on a hot count, taking
   insurance, an I18 deviation). On the count-only teaching table the player makes
   none of those choices — the engine auto-plays the optimal bet/insurance/deviation
   via `auto_play_round()`. So heat was building from the autopilot's correct play
   and could back the player off (re-seat at the tier floor) for doing exactly the
   right thing, which is confusing for a first drill. The three player-agency tell
   sites now all gate on `not config.count_only`:
   - `place_bet` bet-tell (GameLoop.gd),
   - `_apply_insurance` insurance-tell,
   - `_apply_hand` deviation-tell.
   The `heat_active` config flag is left `true` on T1 (the table is still a
   "heat-capable" table; only the player-driven tells are muted), and the HUD heat
   label stays visible. Decay/latch mechanics are untouched, so this only affects
   count-only tables. Tutorial mode is unaffected (it already disables heat and
   runs its own stages).

2. **Count-focused settled status.** On a count-only table the post-hand status no
   longer reads "Hand settled: +N" (P&L is not the lesson). `Main.gd::_on_hand_settled`
   now writes "Auto-played hand — report your running count." instead, reinforcing
   that the running count is the player's only responsibility. Non-count-only tiers
   keep the P&L line.

**Tests.**
- `game_loop_check._check_count_only_heat_suppressed` (new): a hot auto-bet (TC 5,
  4 units) on a `count_only` loop adds **0** heat, while an identical non-count-only
  control loop adds `BET_TELL_GAIN` (+6). The two loops differ only in `count_only`
  (same seed/shoe, both left in HAND so no decay muddies the delta), so the difference
  isolates the tell.
- `scene_smoke_check._check_count_only_teaching_table` extended: after the auto-played
  hand the status line must contain "running count" (count-focused, not P&L).

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627). No save residue.

## M123 — Count-only T1: hide the running count readout + hide the Decisions label

The M121/M122 count-only teaching table still showed two HUD read-outs that leaked
information the player was supposed to be tracking themselves:

1. **The live running count.** T1 had `show_count_display = true`, so the HUD
   displayed `TC: N (RC +N, 1.00 decks)` — giving the player the exact number
   they were supposed to be counting. For a "what to look for" drill the player
   should see the cards, track the count mentally, and report it at the per-hand
   prompt; the answer key should not be on the HUD.

2. **The Decisions label.** The player made no play decisions (the engine
   auto-played), so "Decisions: M/M" was a misleading self-grade — it implied
   the player had made calls. It belongs on tables where the player actually
   plays, not on the counting drill.

**Changes (`Main.gd`).**
- `_refresh_hud`: the count-display block now checks `count_only` first: on a
  count-only table the `_tc_label` shows a tracking nudge
  ("Running count: track it (report +N / -N)") instead of the numeric TC.
  Non-count-only tables are unchanged.
- `_refresh_hud` Decisions label: now hidden when `count_only` is true (the
  player made no decisions).
- `_show_debrief`: the "Decisions: M / N optimal" line is omitted on count-only
  tables (the engine auto-played; M/N optimal is not the player's skill).

**Tests.**
- `scene_smoke_check._check_count_only_teaching_table` extended: after
  auto-playing a hand, asserts the `_tc_label` no longer shows the numeric
  "TC:" readout (it shows a tracking nudge instead) and the Decisions label
  is hidden. The drive-to-completion section (previously on a target session
  that exercises the normal Decisions path) now sets `count_only = false` so
  it still asserts the Decisions label + debrief line on a real table.
- The count-only completion drive in the same check now asserts the debrief
  shows a "Counting:" line (the point of the table) and does NOT show a
  "Decisions:" line (no player decisions).

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627). No save residue.

## M124 — Count-only T1: skill rating is driven by count accuracy, not pinned discipline

On the M121–M123 count-only teaching table the player makes **no play decisions**, so
the Discipline meter is pinned at 100 (nothing suboptimal to grade). The session
process score was `lerpf(discipline, count_accuracy, 0.5)`, i.e.
`(100 + accuracy) / 2`. A player who counts at **0% accuracy** therefore still scored
**50** — exactly the Tier 2 unlock threshold — so the teaching table's sole skill
(counting) leaked progression: a poor counter could advance without counting.

**Change (`GameLoop.gd::_session_process_score`).** When `config.count_only` is set,
the process score is the count accuracy **alone** (`_count_accuracy.accuracy`), with
no discipline padding. With no recorded checks the accuracy is the neutral 100, so a
fully-skipped session still gets 100 (matching the previous behaviour — no regression
for the skip path). Non-count-only tables are unchanged (still the discipline/count
blend, or discipline alone when no checks were recorded).

Effect: a count-only session's skill-rating EMA step is now `alpha * accuracy`
(e.g. 0.2 × 60 = 12.0 for a 60% counter) instead of `alpha * (100 + accuracy)/2`
(0.2 × 80 = 16.0). The teaching table now genuinely gates progression on counting.

**Test (`count_check.gd::_check_count_only_rating_is_count_accuracy`).** Drives a
count-only T1 session reporting the RC off-by-8 at every check (per-check score 60,
so accuracy 60). Asserts the end-session rating equals `SKILL_EMA_ALPHA * accuracy`
(the pure-count formula) and is strictly **below** the discipline-padded blend a real
table would produce for the same counting.

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627). No save residue.

## M125 — Teaching table: show the player's own cards + add NPC players at higher tiers

Two related fixes to the Tier 1 teaching table (and its higher-tier successors):

**1. The teaching table was showing only the dealer's cards.** On a count-only
table the hand is auto-played and settles in one frame, and `_finalize` cleared
`_hands` — so the player never saw their own two cards, only the dealer's. But a
counter must track *every* visible card (their own + the dealer's + any other
seat's). Fix: `_finalize` now keeps `_hands` (and `_npc_hands`) when
`config.count_only` is set, so the auto-played hand stays on the table for the
player to count. The next hand's `_after_insurance()` rebuilds `_hands`, so
nothing goes stale. Every other table is unchanged (hands still clear on settle).
`scene_smoke_check` now asserts a player-hand row is present after an auto-played
teaching-table hand.

**2. Additional (NPC) players at higher tiers.** A busier table means more cards
per round — a harder, more realistic counting stream. `CHTableConfig` gains
`npc_players`, set per tier: T1 = 0 (pure drill, just you), T2–T3 = 1, T4–T5 = 2,
T6–T7 = 3. Each NPC is dealt two opening cards in `_deal_opening`, auto-played
to a terminal state in `_after_insurance` (flat basic strategy at TC 0, no
split/double/surrender), and their cards are revealed into the count — exactly as
on a real table. NPCs have **no stake**: their P&L is never tracked, so the
trainee's wagered/net/bankroll are unaffected. The dealer plays out while any NPC
hand is standing, so the full card stream is visible. `Main.gd` renders each NPC
as its own row ("Player 2", "Player 3", …) below the player's hands.

**Tests.**
- `game_loop_check._check_npc_players`: NPC dealt + auto-played to a terminal
  state; cards revealed exactly once (shoe conservation holds); trainee P&L
  isolated (wagered ≥ 1, never the NPC's); the run stays deterministic across two
  seeded runs (the trainee sequence is identical even though the NPC consumes
  cards).
- `tables_check`: pins the NPC ladder (T1=0, T2=1, T4=2, T6=3).
- `scene_smoke_check._check_npc_player_rows`: a 1-NPC table renders a "Player 2"
  row in the player area.

**Verification.** `run_all.ps1` full default set: **ALL PASS (24 scripts)**;
`sim_validate` byte-identical (0.954 / 0.441 / −0.627). No save residue.

## M126 — Canonical counting systems (KO + Hi-Opt II) + smoke-test robustness

The per-card count values for the two non-default systems were non-canonical, and
several comments pinned the old (wrong) values. This pass corrects them to the
standard definitions (Wong / Wikipedia), so every unlocked system now counts the
shoe the way its name actually means.

**Hi-Opt II — now balanced (net 0 per deck).**
`Card.gd::count_value("hi_opt_ii")` is now: **A = −1, 2–4 = +1, 5–9 = 0, J/Q = 0,
10/K = −1** (net 0). This **supersedes M73**, which documented Hi-Opt II as
A = 0 / 8–K = −1 / net −12; the A = −1, J/Q = 0, 10/K = −1 form is the canonical
Hi-Opt II and is balanced. The M73 "net −12" figure is no longer accurate and is
retained only as a historical reference.

**KO — now canonical (net +8 per deck).**
`Card.gd::count_value("ko")` is now: **2–7 = +1, 8–9 = 0, A = 0, 10–K = −1**
(unbalanced, net **+8** per deck). Previously it was 2–6 = +1 / net +4, which is
not the Knock-Out system. Hi-Lo (the default teaching system) is unchanged:
2–6 = +1, 7–9 = 0, 10–A = −1, net 0.

**Files changed.**
- `scripts/data/Card.gd`: per-card values for `ko` and `hi_opt_ii` (see above);
  inline comments now state the canonical net.
- `tools/tables_check.gd`: `DECK_NET["ko"]` → 8 and `DECK_NET["hi_opt_ii"]` → 0;
  header + per-card count pins updated (ko 7 = +1 / 8 = 0; hi_opt_ii 8 = 0,
  J = 0, 10 = −1, A = −1).
- Stale-value comments corrected in `scripts/systems/CountEngine.gd`
  (balanced = hi_lo + hi_opt_ii; unbalanced = ko net +8), `scripts/data/TableConfig.gd`,
  and `tools/sim_counting_systems.gd`.

**Smoke-test robustness (`tools/scene_smoke_check.gd`).**
- `_check_tutorial_mode`: the stage-1 "Next" assertions now tolerate a
  **SETTLED** outcome. The tutorial session is built with an unseeded shoe
  (`_start_session` → seed −1), so the first auto-bet hand can occasionally open
  a natural and settle immediately; the check now asserts the phase left
  BET/IDLE (the real "stuck" states) and guards the mid-hand button-visibility
  pins so they only apply when the hand is still live.
- Fixed `String.startswith()` → `String.begins_with()` at the count-only TC readout
  check. The invalid call threw a script error that aborted
  `_check_count_only_teaching_table`, silently skipping its trailing assertions
  (tracking nudge, Decisions label, count-check gate). Restores that coverage.

**Verification.** Full 24-script suite: **ALL PASS**. `sim_validate` Hi-Lo
baselines unchanged (0.954% / 0.441% / −0.627%) — unaffected by the KO/Hi-Opt
 changes. T2 (KO) sim: counting beats basic strategy (mean edge 0.0318% vs
 0.2262%). T5 (6-deck H17 Hi-Opt II) sim in-band (counting 0.9361% vs basic
 1.2092%; the H17 "not clearly worse" floor holds — note I18 deviations are gated
 off on H17, so T5's edge is bet-ramp-only, an accepted limitation). No save
 residue.

 ## M127 — Social opponent ("Sal") wired into the table loop (venue arc)

 The venue-arc social axis now has a real, tracked opponent. A recurring rival
 ("Sal") sits at every table with a named seat, a tracked session bankroll, and a
 betting policy. This is the "friend → casino" progression made concrete: the
 player is no longer alone against the house but facing a character who gets
 sharper and better-capitalized up the ladder.

 **`CHOpponent` (new, `scripts/data/CHOpponent.gd`).**
 A pure `RefCounted` model: `name`, `archetype` (friend/regular/shark/pro),
 `skill` (0–1 probability of the optimal play), `starting_bankroll`,
 `bet_policy` (flat/ramp/count/tilts), `tilt_factor`, and session-scoped
 `bankroll` / `net_pnl` / win-loss-push counters / `consecutive_losses`.
 API: `choose_bet(context)` (policy-driven sizing, clamped to bankroll),
 `choose_play(optimal, available)` (skill-gated optimal vs. random suboptimal),
 `apply_result(net)`, `is_busted()`, `reset()`, `summary()`, and a
 `for_opponent(...)` builder. Fixed per-tier seeds keep the character
 deterministic on every visit.

 **Per-tier rivals (`TableConfig.opponent` + `_opponent_for_tier`).**
 Every `for_tier(n)` now seats "Sal": T1 friend (skill .35, $25, flat) → T2
 regular (.5, $50, flat) → T3 regular (.6, $75, ramp) → T4 shark (.7, $100,
 ramp) → T5 shark (.8, $150, count) → T6 pro (.85, $200, count) → T7+ pro (.9,
 $300, count). The field is inert for the sims (they build their own configs),
 so baselines are untouched.

 **Loop wiring (`GameLoop`).**
 The opponent occupies its own seat: `_deal_opening` deals it two cards from the
 same shoe and freezes its bet (`choose_bet`) before the outcome is known;
 `_play_npcs` plays it to completion with basic strategy keyed to the running
 count (it counts too, so it is harder at higher tiers); `_finalize` settles it
 once per round (guarded by `_opponent_settled`) via `_settle_opponent()`, which
 computes its net vs. the dealer (BJ/bust/win/loss/push), calls
 `apply_result`, and emits the new `opponent_settled(net)` +
 `opponent_busted()` signals. The opponent's P&L is **session-scoped and never
 folds into the player's bankroll** — consistent with the "bankroll resets"
 constraint (stakes are reputation/standing, not shared money).

 **Test isolation.** The opponent consumes 2 extra cards/hand from the shoe,
 which shifts the card stream. Tests that pin exact card positions or hand
 counts (`multi_hand_check`, `count_check`, `mental_check`, `lifecycle_check`)
 now set `config.opponent = null` to isolate the mechanic under test from the
 social rival; the rival is exercised end-to-end in `opponent_check` instead.

 **Verification.** Full 28-script suite: **ALL PASS**. `opponent_check` covers
 construction/reset, busted, all 4 bet policies, bankroll clamping,
 skill=1.0-always-optimal / skill=0.0-never-optimal, single-option-forced,
 `apply_result` bookkeeping, seed determinism, summary format, plus two new
 loop-integration checks (per-hand settlement, net_pnl == Σ emitted signals,
 bankroll == start + net, valid 1-unit outcomes, opponent cards in the shoe
  stream; and same-seed same-arc determinism). Sim baselines unchanged.

## M128 — Sal gets a seat in the UI + audio layer + Godot 4.7 (gap pass)

Three gaps from the M127 opponent work were closed, and the project was
normalized onto the Godot 4.7 toolchain.

**Sal is now visible.** `Main.gd` renders the tracked rival as a distinct row
(purple, name + live bet + cards + total) separate from the filler NPC rows,
adds a persistent `Sal: … P&L` HUD read-out, and subscribes to the
`opponent_settled` / `opponent_busted` signals (bust flips the row to a red
"BUSTED" state for the rest of the session). New `GameLoop.opponent_hand()` /
`opponent_bet()` accessors back the rendering.

**Sal's bet now sees the count.** `_deal_opening` was passing an empty context
to `choose_bet`, so his ramp/count/tilt policies always computed their TC-0
value. It now passes `{"tc": effective_tc()}` (the live, floored true count),
so a T5/T6 counting rival actually sizes up on a hot shoe.

**Busted seat ends.** The `opponent_busted` signal's "seat ends" contract was
not enforced: a busted rival kept getting dealt and consuming the shoe.
`_deal_opening` now skips dealing when `opponent.is_busted()`, so a busted seat
stops drawing cards and settling for the rest of the session.

**Audio layer.** New `scripts/systems/AudioSystem.gd` — procedural, asset-free
SFX (deal click, win/loss tones) plus a looping ambient drone whose volume
tracks the hidden mental band (calm → silent, insane → loudest), wired into
`Main.gd` off `card_dealt`, `hand_settled`, and `mental_band_changed`.
Headless-safe: under `--headless` every play call is a no-op, so the test suite
runs silently.

**Deal SFX covers every revealed card.** "Any card shown to the player" is the
accurate trigger for a deal sound, but `card_dealt` only fired for *drawn*
cards (hits, doubles, dealer draws, hole reveal) — the opening deal never
played. The emit moved into `_reveal`, the single choke point every
player-visible card flows through (opening deal, draws, hole), and added to
`_mark_seen` for split-revealed cards. The six now-redundant explicit
`card_dealt.emit` calls were removed. No test subscribes to `card_dealt` (only
the audio lambda does), and audio is a no-op headless, so baselines are
untouched.

**Godot 4.7.** `project.godot` (`config/features = "4.7"`) and
`tools/run_all.ps1` (4.7 console binary) now match the installed toolchain; the
stale 4.5.1 references in this file were corrected.

**Tests.** New `tools/audio_check.gd` (headless detection, stream-builder sizes,
band-volume mapping, no-op calls) and `opponent_check._check_busted_seat_ends`
(a busted rival stops being dealt/settled). `scene_smoke_check` gained
`_check_opponent_row`. Full 29-script suite: **ALL PASS**, sim baselines
unchanged (no-split 0.954%, split 0.441%, counting −0.627%).

## M129 — Textbook S17 strategy: hard 15 vs 2–3 + 6s split range (re-baseline)

Found: Two basic-strategy cells deviated from the canonical single-deck S17
chart and were invisible to the suite because `spot_check` never pinned them:

1. **Hard 15** stood on dealer 2–6 (`_hard_play`, `dk >= 2 and dk <= 6`).
   Canonical S17: stand only on 4–6; **hit** on 2 and 3.
2. **6s** split on 4–7 for *every* table (`_pair_play`, `dk >= 4 and dk <= 7`)
   — that is the H17 range applied to S17 too. Canonical: **S17/DAS splits on
   2–7**; H17 splits on 4–7.

Cause: The tables were tuned against the multi-deck / H17 chart (or the 1-deck
sim edge) rather than the standard S17 chart a counter learns, and the spot
check's pair coverage skipped 6s-vs-2/3 while the hard-15 row only pinned the
6/7 edge.

Fix:
- `_hard_play` 15: stand `dk >= 4 and dk <= 6` (was `dk >= 2 and dk <= 6`) →
  hit on 2/3.
- `_pair_play` 6s: split `dk >= lo and dk <= 7` where
  `lo = 4 if config.dealer_hits_soft_17 else 2` → S17 splits 2–7, H17 splits
  4–7. `_pair_play` now takes `config` (was `_config`) for that branch.
- `spot_check`: pinned the four boundary cells (15 vs 2/3 hit, 15 vs 4 stand,
  6s vs 2/3 split) → 129/129 (was 125).

Sim re-baseline (seed 20260906, 500k hands; deterministic):
- No-split: 0.954% → **1.144%** (band 0.40–1.40, PASS). The no-split phase plays
  pairs by their hard/soft total, so only the 15-vs-2/3 change moves it.
- Split: 0.441% → **0.617%** (band 0.30–0.85, PASS).
- Counting: −0.627% → **−0.305%** (band −1.20 to −0.20, PASS) — still a player
  advantage.

Note: the 15-vs-2/3 and 6s-vs-2/3 cells are slightly house-favourable in a
single-deck game, so matching the textbook chart costs ~0.1–0.19pp of measured
edge versus the tuned tables. That is the correct trade for a trainer that
teaches the canonical S17 chart. `sim_validate.gd` baseline comments updated to
the new no-split figure (1.144%, post-M129). The I18 deviation set is unchanged
(a defensible non-canonical variant, sim-validated in M3).

Verified: full `*_check.gd` suite + `sim_validate` ALL PASS, in-band on all
three sim phases.

## M130 — Help panel no longer auto-shows on first launch

**Found.** The M84 onboarding help/intro panel popped up on its own the first
time the game launched (no save file on disk → `_maybe_show_intro()` called
`_show_help()` from `_ready()`). That interrupted play before the player asked
for anything: the goal is a panel that *shows when the player opens Help*, not
one that greets them.

**Fix.**
- `Main.gd`: removed the `_maybe_show_intro()` function and its call from
  `_ready()`. The `_help_panel` is built hidden (as before) and is reachable
  only on the player's action — the "Help (F1)" button, the F1 key, or Esc
  close. F1 / Esc / button-toggle behavior is unchanged.

**Verification.** `scene_smoke_check._check_help_panel` updated: with no save
file the panel now stays hidden until the player opens it ("no auto intro on
first run"); F1 opens, F1 closes, Esc closes, button toggles — all still pass.
Full 27-script `run_all.ps1` suite: ALL PASS.

## M131 — Venue/session banner moved to the screen center

**Found.** The session-start venue banner (e.g. Tier 1's *"A friend dares you
to count his single deck…"*, the M117 stage-transition banner's shared control
`_tutorial_banner`) was top-anchored (`PRESET_TOP_WIDE`, `offset_top = 24`),
so its text overlapped the top HUD readouts (bankroll / discipline / tier /
count labels).

**Fix.** `Main.gd` `_build_tutorial_banner()`: replaced the top-wide anchor with
`PRESET_FULL_RECT` + `vertical_alignment = VERTICAL_ALIGNMENT_CENTER` (margins
kept: `offset_left = 80`, `offset_right = -80`). The label fills the full screen
and vertically centers its text block within that region, so the wrapped text
appears at screen center rather than under the HUD.

**Verification.** `_check_venue_banner` and `_check_tutorial_mode` assert text /
visibility / modulate only (not anchor position), so they are unaffected. Full
27-script `run_all.ps1` suite: ALL PASS.

