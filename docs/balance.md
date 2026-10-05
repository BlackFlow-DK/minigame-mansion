# Balance pass (2026-09-30)

Spec: `docs/superpowers/specs/2026-09-30-night-features-design.md` section 1. Fairness first,
then pacing, measured with bot-only batches, not guessed.

## Method

- `tools/balance-batch.ps1` (driver `game/tools/balance/balance_batch.tscn`, engine
  `game/tools/balance/balance_runner.gd`) plays whole rounds through the real `Session` flow
  (intro/results times set to 0, real points table, real time-limit backstop where tied
  survivors share first place) with every slot a bot, slot 0 (the host's seat) included.
- Seats vs. bots: a bot's personality (skill, aggression) is rolled from its seed. The runner
  rotates the personalities over the seats in blocks of N rounds (a Latin square), so every
  seat plays every personality equally often; a seat's win rate then measures only the seat
  (spawn point, slot-ordered rules, tick order). Use round counts that are multiples of N.
- No time scaling: 60 physics ticks per game second, so lengths are real seconds. Headless
  with `--fixed-fps 60` this runs 4x (8 bots) to 15x (2 bots) faster than real time.
- A "win" is first place; tied winners (time-out survivors) share one win.
- Noise: with 40 rounds a fair seat's win rate has a standard deviation of about 8 points
  (2 players), 7 (4 players) and 5 (8 players). One seat at +2 sd in one cell is expected
  somewhere in a 12-cell table; only a seat that stays high across seeds is a bias.

## Before (main at 003b8db, seed 1, 40 rounds per cell, old 4/3/2/1 table)

Round length in seconds: mean / median (min-max). "Top seat": the highest win share of any
seat (fair = 50 / 25 / 12.5 %).

| Minigame | 2 players | 4 players | 8 players | Top seat 2 / 4 / 8 |
|---|---|---|---|---|
| Floor Is Lava | 12.9 / 10.1 (2.1-31.1) | 27.4 / 31.0 (6.7-34.5) | 35.8 / 37.1 (25.3-38.0) | 55 / 27.5 / 20 % |
| Bumper Sumo | 8.1 / 7.8 (2.4-17.2) | 21.8 / 23.5 (8.9-31.9) | 28.3 / 27.7 (20.9-36.6) | 52.5 / 35 / 17.5 % |
| Hot Potato | 12.5 / 12.2 (9.1-15.8) | 36.9 / 36.6 (30.8-42.0) | 53.5 / 53.3 (47.5-58.8) | 55 / 30 / 32.5 % |
| Coin Scramble | 45 (fixed) | 45 | 45 | 50 / 30 / 17.5 % |

Findings:
- Bumper Sumo was far too short at every count: the shove (10 m/s x knockback 1.05) rang
  blobs out from mid-platform, so the shrinking rings rarely mattered.
- Floor Is Lava and Hot Potato were too short with 2-4 players (2 players: one ~10 s duel,
  one bomb). Lava's small fields (3 rings for 2, 4 for 3-4) kept everyone near the rim.
- No seat bias that survives a second seed. The two outliers were re-run: Hot Potato 8
  players, seat 7 at 32.5 % (seed 1), was 15 % on seed 2 and 12.5 % on seed 5; Sumo 4
  players, seat 0 at 35 %, was 19-33 % on other seeds. Mean places stay within ~0.4 of fair.
- Coin Scramble: the leader at 60 % of the round wins 34-35 % of 4-8 player rounds (81 %
  with 2 players, where bot skill decides): no coasting, the gold rush works. Unchanged.

## Changes (numbers only)

| What | Before | After | Why / effect (bots) |
|---|---|---|---|
| Session points | 4/3/2/1 for every count | 2-3 players 3/2/1; 4-5 4/3/2/1; 6-8 5/4/3/2/1/1 (`Session.place_points`) | spec; the table goes by the players who started the round |
| Sumo `SHOVE_FORCE` x `KNOCKBACK_MULTIPLIER` | 10 x 1.05 | 8.5 x 1.0 | the rings become the finisher: 4 players 21.8 -> 32.3 s, 8 players 28.3 -> 38.3 s. Also tried 8 x 1.05 (36.3 s at 4) and knockback 0.8 / 0.85 / 0.9 (34.3 / 31.6 / 30.3 s at 4) |
| Sumo `SMALL_ROUND_PLAYERS` (was the literal `<= 3`) | 2-3 players start on 7 m | 0: everyone starts on 9 m | with the softer shove, 2-3 players on 7 m still lasted 17-19 s; on 9 m 2 players 24-27 s, 3 players ~30 s |
| Lava `rings_for` (`FULL_FIELD_PLAYERS`) | 2 players 3 rings, 3-4 players 4 | 5 rings from 2 players up | 2 players 12.9 -> 22.8 s, 4 players 27.4 -> 36.0 s (shortest 6.7 -> 16.4 s). A softer lava shove (8.5) added ~1 s and was not kept |
| Potato fuse scale cap (`SMALL_ROUND_FUSE_SCALE`) | 1.0 | 1.8 (= 4.5 / 2.5, the formula's own 2-player value) | 2 players 12.5 -> 22.3 s; 3 players longer too; 4-8 unchanged |

Tests updated for these numbers: `test_session.gd` (new table), `test_bumper_sumo.gd`
(start platform, exact sumo tuning), `test_floor_is_lava.gd` (2-player field, rim tile).
The body-size multipliers (main, `size` component) apply on top of these bases.

## After (balance branch with main merged, seed 1, 24 rounds per cell, new table)

| Minigame | 2 players | 4 players | 8 players | Top seat 2 / 4 / 8 |
|---|---|---|---|---|
| Floor Is Lava | 22.8 / 25.3 (2.5-38.0) | 36.0 / 37.7 (16.4-38.4) | 34.9 / 36.8 (25.3-38.0) | 58 / 37.5 / 21 % |
| Bumper Sumo | 24.3 / 26.5 (3.5-38.4) | 32.3 / 34.8 (19.1-39.0) | 38.3 / 38.0 (36.6-42.1) | 58 / 33 / 21 % |
| Hot Potato | 22.3 / 21.7 (16.9-27.3) | 37.1 / 36.9 (30.8-41.9) | 53.5 / 53.1 (50.1-58.8) | 62.5 / 33 / 29 % |
| Coin Scramble | 45 | 45 | 45 | 54 / 33 / 21 % |
| Cannon Alley (new, not tuned here) | 37.8 / 38.4 (27.8-50.1) | 43.4 / 44.0 (24.9-55.8) | 49.3 / 49.0 (39.1-59.0) | 50 / 33 / 29 % |

3 players (seed 1, 24 rounds): Lava 28.1 / 32.7 (6.8-38.2), Sumo 29.1 / 29.6 (14.0-38.1),
Hot Potato 30.0 / 29.6 (23.1-36.7), Coin Scramble 45, Cannon Alley 42.2 / 40.7. Seat 2 won
46 % (Lava) and 50 % (Sumo) here; see "3-player seat" under open questions.

Every 4-8 player median is now inside 30-60 s; 2-player rounds moved from 8-13 s to 22-25 s
(below 30 s; the spec's target is for 4-8 players). No round never ended; Hot Potato's
180 s limit is never reached (longest 59 s). Top-seat shares sit inside the noise band
above (24 rounds: ~10 points sd at 2 players, ~9 at 4, ~7 at 8). The 8-player Hot Potato
seat 7 (29 %) replays the same seed-1 rounds as the "before" outlier, so it is not new
evidence. A 4-bot run on seed 20260930 gave seat 2 15 of its first 32 rounds, but over 32
rounds per minigame seat 2 was 22-34 % everywhere: noise, which is why the test below is
only a coarse guard.

## Feel numbers (checked, unchanged unless listed above)

- Shove reach 1.3 m centre to centre vs. blobs touching at 0.8 m (radius 0.4): reaches
  0.5 m past contact, width 1.4 m. Normal for the genre; unchanged.
- Stun vs. shove cooldown (defaults): a 10 m/s shove stuns ~0.56 s, the cooldown is 0.6 s,
  and by then the victim has slid ~1.5 m, out of reach; `stun_chain_max` 1.2 s caps gang
  chains. No infinite chains; unchanged. Sumo is the exception, see open questions.
- Jump: apex 1.3 m, ~0.63 s air time, ~3.8 m at full run. Clears one fallen lava tile
  (a ~1.8 m hole) easily and two (~3.6 m) only just; clears the coin bar (0.71 m) and single
  potato crates (0.9 m); sumo rings drop whole, no gaps. Unchanged.
- Hot Potato holder bonus 1.12: holds last 2.35-2.6 s with 4 players and 1.4-1.6 s with 8,
  under the 3-5 s brief. Bonus 1.05 moved them +0.16 s (4) and -0.08 s (8);
  `gotcha_slow_time` 0.8 likewise did nothing. Holds are set by crowding (8 blobs in a
  7.6 m ring), not speed, so the numbers stay.
- A shove adds to the victim's own running speed (a running blob shoved from behind slides
  ~11 m): the source of the rare 2-4 s two-player lava/sumo rounds.

## How to re-run

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\balance-batch.ps1 -Minigame all -Players "2,4,8" -Rounds 24 -Seed 1 -Parallel -Out build\balance\report.txt
powershell -NoProfile -ExecutionPolicy Bypass -File tools\balance-batch.ps1 -Minigame bumper_sumo -Players 4 -Rounds 16 -Set "shove.force=9.0" -Verbose
```

- `-Minigame id|all`, `-Players N` or `"2,4,8"`, `-Rounds M` (multiples of the player
  counts keep the personality rotation balanced), `-Seed S`, `-Parallel` (one process per
  minigame), `-Verbose` (a line per round, the seats' personalities, every knock-out),
  `-Set` (override exported tuning after `_setup`: `minigame.<prop>` or
  `<component>.<prop>`, `;`-separated, Godot value syntax), `-Size small|big` (every seat's
  body), `-Out` (report file). Each block ends with a machine-readable `BALANCE_JSON` line.
- `-Size mixed`: small/normal/big rotate over the seats (seat s plays size (s + block) mod 3 in
  each personality block of N rounds), so a size bias can show; use round counts that are
  multiples of 3N for a balanced rotation. `-Verbose` names each seat's size.
- `-RoundJson`: one `ROUND_JSON {...}` line per round (kept by `-Out`): `r`, `sec`, `timeout`,
  `rank`, `win`, `groups` (ties), `pts` (Session points), `sizes` (s/n/b per seat), `kos`
  ([slot, seconds, shover or -1, reason]) and `x`, the minigame's role and score state at the
  end (`seekers`, `hider_slots`, `original_ghosts`, `caught_at`, `scores`, ... when it has them:
  `ROUND_PROPS` in the runner). Per-role and per-size numbers are computed from these lines.
- Bot personalities are set when the Stage spawns the players, before the minigame's `_setup`,
  so a minigame that configures its own bots there (Hide and Sneak: sharp hiders) keeps them.
  Before 2026-10-05 they were set at the round intro and overwrote that; other minigames' rounds
  are unchanged (same seed, same report).
- Cost on an idle machine: ~3 minutes for all five minigames at 2+4 players x 24 rounds,
  ~3 at 8 players. Same seed, same rounds (deterministic). Presentation components are
  paused while measuring (`--full` keeps them; the rankings are identical either way).
- Test: `tools\godot-test.ps1 -Filter test_balance` (4 bots through Session, 12 rounds per
  minigame, 8 for Coin Scramble, every round within its limit, pooled top seat <= 35 %).
  Even a fair game fails that check for about one seed in five at 44 rounds; it runs on
  this document's seed 1 and guards against gross regressions only.

## Open feel questions (need humans)

1. Sumo shove 8.5 with cooldown 0.45: a mashing human can shove again before the victim's
   0.51 s stun ends (the gap is ~1.1 m < reach 1.3 m at 0.45 s), so one blob can carry
   another to the rim. Bots never mash (their own cooldown is 0.7-1.4 s). Fun combo, or
   "caught = dead"? Knob: `BumperSumo.SHOVE_COOLDOWN` 0.6.
2. Does sumo still feel punchy at 8.5, next to the 10 m/s shove of the other games? If it
   is too soft, try 9.0 (bots: 4 players ~30 s).
3. Lava with 2 players on all 91 tiles: tense, or empty? (Bots still meet: 92 % of falls
   are shoves.)
4. Hot Potato holds of ~1.5 s at 8 players: frantic fun, or does the blast feel random?
5. 2-player rounds of 22-25 s: right for a duel, or should 2-player sessions run longer?
6. 3-player seat: the first three spawn points are +Z, -Z and +X, so seats 0 and 1 start
   face to face and seat 2 starts beside the duel. Seat 2 won 40-50 % of 3-player Lava and
   Sumo rounds over two seeds (fair 33 %; about 1.3 sd, so a lean, not proof). A fair
   triangle for 3 players needs a per-count spawn layout (Stage picks point i for player i),
   which is a rule change, not a number: left for the orchestrator.
7. Bots chase and flee with fixed perception delays; humans with a camera and a pad land
   fewer shoves, so human rounds probably run longer than these numbers.

## Elsewhere (outside this pass's files)

- `game/net/sync/dev/run_sync_smoke.ps1` checks session points against a fixed 4/3/2/1
  table; a 3-player session now scores 3/2/1, so it needs `Session.place_points(n)`.
- `game/ui/round/dev/round_ui_dev.gd` fakes results with 4/3/2/1 (visual dev scene only).
- Cannon Alley (new, not part of this pass): 8 players, seats 0-1 won 25-29 % and seat 7
  0 % of 24 rounds; worth a second seed by its owner.

## Fairness follow-ups (2026-10-01, branch `fairness`)

### 1. Spawn layout by player count (Floor Is Lava, Bumper Sumo)

Before, Stage put player i on marker i: with 3 players seats 0 and 1 started face to face
(+Z / -Z) and seat 2 beside them (+X). Now `_setup` on the host picks a random turn
(`randf() * TAU`) and sends it with the slot order (`_rpc_spawn_layout`, reliable,
`call_local`); every peer places the N players evenly around a circle (equal angles),
each facing the centre, for every N from 2 to 8 (`spawn_layout(count, turn)`). Sumo keeps
its markers as the 8-player layout (already an even 45-degree ring of 4.5 m), turned the
same way; fewer players use the same 4.5 m circle. Lava's markers sit on tile centres at
4.9-5.5 m (not an even ring), so every count is computed on a 5.2 m circle (on solid tiles,
off the edges, for any turn: tested). The markers still exist; they only place players at
load. The net checks (`run_lava_net.ps1`, `run_sumo_net_check.ps1`) now also assert that
every peer applied the same turn and order.

3 players, 24 rounds per cell, `tools\balance-batch.ps1 -Minigame floor_is_lava,bumper_sumo
-Players "3" -Rounds 24 -Seed S`. Win share by seat 0 / 1 / 2 (fair 33.3 %), mean place
(fair 2.00):

| Minigame, seed | Before: wins | Before: mean place | After: wins | After: mean place |
|---|---|---|---|---|
| Lava, seed 1 | 29 / 25 / 46 % | 2.04 / 2.25 / 1.71 | 42 / 8 / 50 % | 1.83 / 2.50 / 1.67 |
| Lava, seed 2 | 29 / 42 / 29 % | 2.21 / 1.83 / 1.96 | 33 / 25 / 42 % | 2.04 / 2.13 / 1.83 |
| Sumo, seed 1 | 21 / 29 / 50 % | 2.21 / 2.08 / 1.71 | 37.5 / 25 / 37.5 % | 1.96 / 2.08 / 1.96 |
| Sumo, seed 2 | 42 / 42 / 17 % | 1.83 / 1.88 / 2.29 | 37.5 / 29 / 33 % | 1.96 / 2.04 / 2.00 |

Sumo meets the target on both seeds (top seat 37.5 %, mean places within 0.12). Lava seed
1 does not (seat 2 50 %, seat 1 2 of 24, mean places 1.67-2.50), so Lava got three more
seeds: seed 3 29 / 37.5 / 33 % (1.92 / 2.08 / 2.00), seed 4 17 / 42 / 42 % (2.33 / 1.79 /
1.88), seed 5 42 / 42 / 17 % (2.04 / 1.92 / 2.04). Pooled over seeds 1-5 (120 rounds):
32.5 / 30.8 / 36.7 % wins, mean place 2.03 / 2.08 / 1.88. The seat that leads changes from
seed to seed, and the 3-seat ring is now the same from every seat (rotation symmetric, random
turn), so no layout cause is left; seed 1 is the noise band (24 rounds: ~10 points sd).
Round lengths barely moved (Lava 28.1 -> 27.2 s mean on seed 1, Sumo 29.1 -> 31.7 s).

### 2. Cannon Alley, 8 players: seat 7 (noise, layout unchanged)

The spawns are already symmetric: all eight on z = 0 (equidistant from both cannon walls),
mirrored left-right (seat 7 at x = 3.45 mirrors seat 6 at x = -3.45: both 0.3 m from a near
cannon lane, 0.95 m from a far one). 24 rounds per seed, 8 players, win share of seat 7
(fair 12.5 %) and its mean place (fair 4.50):

| Seed | Seat 7 wins | Seat 7 mean place | Top seat | Mean place range |
|---|---|---|---|---|
| 1 | 0 % | 4.71 | seat 1, 29 % | 3.50-5.71 |
| 2 | 4.2 % | 4.92 | seat 0, 25 % | 3.58-5.04 |
| 3 | 12.5 % | 4.42 | seat 4, 25 % | 4.13-4.96 |
| 4 | 20.8 % (top) | 3.79 (best) | seat 7, 21 % | 3.63-5.33 |

Over 96 rounds seat 7 won 9.4 % with a mean place of 4.46: noise, not the spawn. Seat 0
(25 / 25 / 15 / 6 %, mean place 4.18) is worth a glance in a later pass but changes with the
seed too. Nothing changed in Cannon Alley.

### 3. `test_balance.gd` split into 4-round blocks

One test per minigame ran 12 rounds (8 for Coin Scramble, ~36 s) against the runner's 60 s
per-test limit. Now each test plays one personality block of 4 rounds with its own seed
(seeds 1, 2, 3; Coin Scramble 1, 2): 11 tests, the same 44 pooled rounds as before, so the
pooled "no seat above 35 %" check is unchanged in strength (it fires once all blocks have
run: use `-Filter test_balance`). The rounds differ from before (seeds 2 and 3 added, and
Lava/Sumo spawn differently), so the pooled numbers are new: wins by seat 11 / 34 / 34 /
20 % (passes, but seats 1 and 2 sit 1 point under the 35 % line; the rounds are
deterministic, so it only moves when a minigame or the bots change). Block times in a full
`godot-test` run (other agents' Godot processes running too): 5-11 s each, Coin Scramble
the longest at ~11 s, against ~36 s for the old Coin Scramble test. Full suite green (512
tests). Trade-off: none in rounds or the bias check; a block alone (one test filtered) only
checks its own rounds' time limits.
