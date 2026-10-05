# Balance pass v0.3, part B (2026-10-05, branch `bal-b`)

Masquerade, Hide and Sneak, Portrait Panic, Ghost Tag, Snowball Fight. Method as in
`docs/balance.md` (bot-only rounds through the real Session flow, personalities rotated over
the seats), with two additions the stock `tools/balance-batch.ps1` does not have (see "Tooling"):
mixed body sizes and one JSON line per round with the roles and in-game scores.

- Every cell: 48 rounds (more where pooled: the row says how many), mixed sizes. Sizes rotate
  per seat in blocks of N rounds (seat s plays size (s + block) mod 3), so over 3N rounds
  every seat plays every size and every personality equally often.
- "Length": mean / median (min-max) in seconds from GO to the result, **including the 2 s end
  grace** (a 60 s timer shows as 62). "Cap / <20": rounds that ran to the time limit / rounds
  under 20 s.
- "Seats": win share per seat in %, tied winners share a win; p = chi-square test of "every
  seat wins equally often" (p < 0.05 would be a bias worth chasing).
- "Sizes s/n/b": wins per appearance in % (fair = 100 / N).
- Roles: "1st place" = which side holds the first-place group (the game's own ranking);
  "pts" = Session points per player per round in that role (the table: 2-3 players 3/2/1,
  4-5 4/3/2/1, 6-8 5/4/3/2/1/1).
- Noise: Masquerade forces every body to normal size (the disguise), so its size column is a
  null control. It still swung 6-16 % at 8 players over 128 appearances: a 10-point size gap
  in one 48-round cell is not evidence on its own. Everything below that was acted on was seen
  in two or more independent batches.

## Ghost Tag

| | N | rounds | length | cap / <20 | seats | sizes s/n/b | 1st place ghost / runner | pts ghost / runner |
|---|---|---|---|---|---|---|---|---|
| before | 2 | 48 | 46.6 / 59.5 (12-62) | 24 / 7 | **79 21 (p=0.00)** | 47/53/50 | 52% / 48% | 2.52 / 2.48 |
| before | 4 | 48 | 55.2 / 62.0 (21-62) | 38 / 0 | 20 26 23 31 (p=0.71) | 31/27/**17** | 21% / 79% | 2.77 / 2.49 |
| before | 8 | 48 | 58.9 / 62.0 (18-62) | 43 / 1 | 13 12 15 11 12 12 12 13 (p=1.00) | 14/12/12 | 10% / 90% | 2.42 / 2.38 |
| after | 2 | 192 | 50.1 / 62.0 (13-62) | 112 / 19 | 53 47 (p=0.47) | 55/48/47 | 43% / 57% | 2.43 / 2.57 |
| after | 4 | 144 | 55.7 / 62.0 (20-62) | 112 / 1 | 25 21 30 24 (p=0.42) | 25/23/27 | 15% / 85% | 2.46 / 2.68 |
| after | 8 | 48 | 58.5 / 62.0 (16-62) | 42 / 1 | 13 10 11 15 16 15 12 7 (p=0.91) | 12/12/14 | 10% / 90% | 2.54 / 2.24 |

After rows pool the batches made once the matching change was in: 2 players = 96 rounds with
fixes 1-2, 48 with 1-3 and 48 with all four (the credit does not act with one runner); 4 players = 96 rounds
with fixes 1-3 and 48 with all four (seats and sizes do not depend on the credit); 8 players = 48
with all four. The two role columns at 4 players are the final 48 rounds only (all 144: 22 % /
78 %, 2.62 / 2.59).

Changes:
1. **Seat bias (2 players): fixed at the cause.** Seat 0 won 79 % of 48 two-player rounds, as
   ghost (24 of 33) and as runner (14 of 15). The map and the two spawns are 180-degree
   symmetric; the asymmetry was the prowling ghost's "per-ghost taste" term
   `(slot * 7 + cell) % 5`, a fixed, slot-dependent preference over the prowl points: seat 0's
   ghost walked toward where seat 1 waits, seat 1's ghost did not. The taste is now drawn per
   round (`hash([_prowl_salt, slot, cell])`, salt from the host rng at `_start`), so two prowlers
   still split up but no seat has a standing route. After: 53 / 47 over 192 rounds.
2. **Role rotation.** The starting ghost was a fresh random draw each round (8 players, 48
   rounds: one seat 6 times, another 19). Now the same rotation as Hide and Sneak: least-used
   slots first, never last round's ghosts if avoidable, random among equals; the counts start
   over when the set of players changes. After: every seat exactly 12 of 48 at 4 and 8.
3. **Body size: `size_speed_keep` 0.5 (new).** A pure chase is decided by speed; the size factor
   (big 0.88x, small 1.15x) made a big runner the ghost's meal: caught 75-77 % against 54-65 %
   (two batches, 4 players), big wins 15-17 % against 27-33 %. Ghost Tag now keeps half the size's
   speed factor (big 0.94x, small 1.07x; looks, capsule, shove unchanged). After, 4 players over
   144 rounds: wins 25 / 23 / 27 %, runners caught 60 / 69 / 58 % (s/n/b).
4. **`chain_credit` 1.0 -> 0.75.** The starting ghosts scored 1.08-1.18x the average player at
   8 players (they get the whole chain's catches). 0.75: 1.02 / 1.14 (two batches) at 8, 0.96-1.04
   at 4. The 12-round check in `test_ghost_tag_bots.gd` reads 1.24 (limit 1.25); with fixes 1-3
   and the old credit it read 1.27 and failed.

Fine as is: round length (a 60 s survive-the-timer game: most rounds run to the timer by design;
first catches come early, wipe-outs are 10-25 %); points per role (ghost 0.92-1.13x a runner over
four batches with the final credit). The "1st place" column is structural, see "Asymmetric games" below.

## Hide and Sneak

| | N | rounds | length | cap / <20 | seats | sizes s/n/b | 1st place seeker / hider | pts seeker / hider |
|---|---|---|---|---|---|---|---|---|
| before | 3 | 48 | 72.2 / 74.0 (57-74) | 38 / 0 | 35 32 32 (p=0.95) | 34/41/25 | 23% / 77% | 1.96 / 2.16 |
| before | 4 | 48 | 73.1 / 74.0 (51-74) | 43 / 0 | 26 19 31 24 (p=0.68) | 23/29/23 | 15% / 85% | 2.50 / 2.77 |
| before | 8 | 48 | 73.4 / 74.0 (49-74) | 45 / 0 | 12 14 19 17 11 10 8 9 (p=0.74) | 12/12/14 | 12% / 88% | 2.57 / 2.19 |
| after | 3 | 48 | 69.9 / 74.0 (36-74) | 32 / 0 | 26 43 31 (p=0.35) | 41/29/30 | 46% / 54% | 2.33 / 1.90 |
| after | 4 | 48 | 71.9 / 74.0 (54-74) | 38 / 0 | 22 26 28 24 (p=0.93) | 28/30/17 | 23% / 77% | 2.67 / 2.68 |
| after | 5 | 48 | 73.2 / 74.0 (63-74) | 43 / 0 | 24 17 26 13 20 (p=0.65) | 19/21/21 | 12% / 88% | 2.23 / 2.25 |
| after | 6 | 48 | 73.1 / 74.0 (44-74) | 46 / 0 | 17 20 16 14 18 16 (p=0.99) | 18/15/17 | 8% / 92% | 3.04 / 2.74 |
| after | 7 | 48 | 73.4 / 74.0 (62-74) | 45 / 0 | 15 12 21 14 15 10 14 (p=0.90) | 10/19/14 | 10% / 90% | 2.61 / 2.60 |
| after | 8 | 48 | 73.8 / 74.0 (70-74) | 46 / 0 | 11 15 13 12 11 8 11 20 (p=0.85) | 12/13/13 | 8% / 92% | 2.39 / 2.32 |

Changes:
1. **Seeker rotation reset when the table changes.** The rotation counts were app-lifetime and
   never forgot anyone: in one app run that went from 3 to 4 to 8 players, slot 3 sought 16
   rounds in a row to "catch up", and at 8 players only slots 4-7 ever sought (24 of 48 rounds
   each, slots 0-3 never). The counts now start over when the set of slots changes (last
   round's seekers still sit the next one out). After: every seat 12 of 48 at 4 and 8, 16 of 48
   at 3 and 6, 9-10 at 5, 13-14 at 7.
2. **Glow time by player count (`glow_by_players`, was a flat `glow_time` 10 s):**
   3: 15, 4: 20, 5: 20, 6: 5, 7: 7.5, 8: 10 s. The end glow is the seekers' catch-up lever and
   moves seeker points strongly (5 players: 10-15 s gave a seeker 1.7 points vs a hider's 2.6,
   25 s gave 2.5 vs 2.1; 6 players, two seekers vs four hiders: 10 s gave 3.4 vs 2.5, 0-5 s
   2.9 vs 2.9). Measured per cell in 48-round batches (seeds 1-6, about 27 batches); the 7-player
   value is interpolated and measured once (2.61 vs 2.60). After: seeker points 0.99-1.11x a
   hider's at 4-8 players; 3 players 1.23x in the final batch but 0.93x and 1.17x in two other
   batches at the same 15 s (noise at 48 rounds is about +-0.15 here).
3. Tests: `test_rustle_every_interval_and_glow_at_the_end` computed its rustle count from a
   fixed 10 s glow; it now expects one rustle per interval until this round's glow.

Measurement note: the stock runner reconfigures every brain at the round intro (rotated
personalities), which overwrote Hide and Sneak's own bot setup (hiders sharp, seekers 0.7) made
in `_setup`. My batches re-run `_plan_bots` after that, so the numbers above are the game's real
bots. See "Tooling".

Fine as is / not fixable by numbers: round length. Hiders win by surviving the 60 s SEEK, so
every round with a survivor runs to the 72 s limit (74 s with the grace): 67-96 % of rounds.
Size: single cells swing (hiders caught 41-69 % by size), but pooled over every batch of this
pass (all glow variants; 160-768 hider appearances per size and count) hiders are caught 52-65 %
whatever their size, and wins per size stay within 4.4 points of each other at every count.

## Masquerade

| | N | rounds | length | cap / <20 | seats | sizes s/n/b (null) | unmasks / wrong shoves per round |
|---|---|---|---|---|---|---|---|
| before | 2 | 48 | 31.8 / **21.0** (8-77) | 6 / **21** | 58 42 (p=0.25) | 52/41/58 | 0.92 / 4.1 |
| before | 4 | 96 | 45.3 / 41.5 (14-77) | 13 / 3 | 18 31 26 26 (p=0.39) | 23/28/24 | 2.9 / 8.7 |
| before | 8 | 96 | 63.8 / **72.8** (24-77) | **46** / 0 | 10 16 13 6 12 16 10 16 (p=0.42) | 9/16/13 | 6.5 / 13.0 |
| after | 2 | 96 | 47.8 / 45.5 (6-77) | 28 / 12 | 49 51 (p=0.92) | 48/38/63 | 0.74 / 4.3 |
| after | 3 | 48 | 43.8 / 41.4 (8-77) | 10 / 6 | 35 31 33 (p=0.94) | 36/35/28 | 1.8 / 5.7 |
| after | 4 | 48 | 49.9 / 45.2 (14-77) | 13 / 4 | 29 25 19 27 (p=0.80) | 26/25/24 | 2.7 / 9.3 |
| after | 8 | 48 | 50.6 / 47.8 (27-77) | 7 / 0 | 20 9 15 9 12 9 16 9 (p=0.77) | 14/10/13 | 6.9 / 13.0 |

Change (a bot hook only, so it merges cleanly with the frame-spike work on this minigame): **`bot_hunt_scale`
by player count** replaces the built-in `clampf(5.5 / players, 0.55, 1.0)` calming of
MasqBots' hunt eagerness: 2: 0.55, 3: 0.75, 4-8: 1.0. With 2 players one shove ends the round,
and at full eagerness 44 % of duels were over in under 20 s (a wrong shove flashes the shover's
colours and the other bot pounces); at 8 the old 0.69 left 48 % of rounds running to the 75 s
limit. 2-player tries (48 rounds each): 0.6 -> median 32 s, 29 % under 20 s; 0.5 -> median 62 s, 40 % at
the limit; 0.4 -> median 53 s; 0.55 (kept, 96 rounds) -> median 46 s, 12 % under 20 s, 29 % at the
limit. 3 players (0.75) and 8 (1.0) were measured once each with the final table.

Seats: an 8-player lean toward seat 1 (best mean place in three batches, 3.90 over 144 rounds,
fair 4.5) did not repeat in the final batch (4.56); win shares p = 0.28 pooled. Cleared.
Players with in-game points above 0: 30-42 % (points only order the survivors; Session points
come from the ranking, so everyone scores by place).

## Portrait Panic (unchanged)

| | N | rounds | length | cap / <20 | seats | sizes s/n/b | mean place s/n/b |
|---|---|---|---|---|---|---|---|
| now | 2 | 96 | 32.8 / 34.6 (11-57) | 0 / 13 | 43 57 (p=0.15) | 41/59/50 | 1.58 / 1.39 / 1.47 |
| now | 4 | 144 | 43.2 / 42.6 (24-64) | 0 / 0 | 20 27 25 28 (p=0.51) | **19**/25/**31** | 2.59 / 2.32 / 2.28 |
| now | 8 | 144 | 46.3 / 42.9 (27-64) | 0 / 0 | 10 17 9 15 12 9 12 15 (p=0.46) | 10/13/14 | 4.53 / 4.29 / 3.98 |

- **The seat suspicion is cleared.** The earlier 12-round sample (wins 4/2/2/5) is noise: over
  144 four-player rounds (three seeds) the seats won 20 / 27 / 25 / 28 % (chi-square p = 0.51,
  mean places 2.22-2.53, and seat 0 is the lowest here, the opposite of that sample). With 96
  more rounds of a bot-aggression variant (same rules): 22 / 25 / 25 / 28 % over 240, p = 0.66.
- Length: fine at 4 and 8 (median 43 s, nothing at the 90 s limit, nothing under 20 s). Two
  players: median 35 s, 14 % under 20 s (an early duel fall).
- **Size: borderline at 4 players, not changed.** Small wins 19 % and big 31 % (fair 25) over
  192 appearances each, mean place 2.59 vs 2.28; at 8 players 10 vs 14 % (inside +-5). The
  cause is the size's shove/knockback factors in the late-loop tile scrum: falls without a shove
  are the same per size (0.45-0.47 per appearance), shoved falls are not (small 0.38, big 0.28
  per appearance). Lowering the bots' scrum (`BOT_AGGRESSION_MAX` 0.6 -> 0.35, 96 rounds) did
  not move it (19 / 27 / 30 %), so it is not a bot artefact. Options for the orchestrator: accept
  (about +-6 points), or give Portrait Panic a partial size factor for shove/knockback the way
  Ghost Tag now does for speed.

## Snowball Fight (rules and tuning unchanged; its seat test fixed)

Free-for-all (no teams). 96 rounds per count (seeds 1 and 2), fixed 60 s by design.

Slot 1 is not favoured: it won 44 % (2 players, fair 50), 27 % (4, fair 25) and 15 % (8, fair
12.5) over 96 rounds each. `test_snowball_fight_bots::test_slot_bias_rounds_10_12` ("slot 1 won
7 of 12", seen on main) measured personalities, not seats: each seat kept its own brain roll
per seed. The 12 rounds now rotate one set of four personalities over the seats per block of 4
rounds (the balance runner's Latin square), and the limit is at most 7 of 12 instead of 6: a fair
seat reaches 8 with p ~ 0.003 (~1 % for any of four), against ~5 % for 7. Now: wins 3 / 2 / 4 / 3.

| | N | rounds | length | seats | sizes s/n/b | mean place s/n/b | in-game score mean (max) | scored |
|---|---|---|---|---|---|---|---|---|
| now | 2 | 96 | 62 (timer) | 56 44 (p=0.22) | 56/42/52 | 1.44 / 1.58 / 1.48 | 5.7 (14) | 100 % |
| now | 4 | 96 | 62 (timer) | 29 27 22 22 (p=0.66) | 25/19/31 | 2.41 / 2.62 / 2.47 | 8.0 (21) | 100 % |
| now | 8 | 96 | 62 (timer) | 12 15 6 19 9 19 11 8 (p=0.12) | 10/16/12 | 4.54 / 4.49 / 4.47 | 10.2 (25) | 100 % |

Fine as is: no seat or size effect that holds across counts (normal is lowest at 4 and highest
at 8), mean places within 0.4 of fair, every player scores every round, bots throw ~17 and land
5-9 balls a round, no ties. The spawn ellipse puts seats 2/3 nearer the centre than 0/1 at 4
players; mean places 2.44 / 2.49 / 2.53 / 2.54: no effect.

## Asymmetric games: the "65 % per side" target

Hide and Sneak and Ghost Tag rank survivors as one tied first place, and the hunters only take
first place by catching everyone. So "the side holding first place" is the hiders/runners in
54-92 % of rounds at 3-8 players, while the points per player are even (seeker 0.99-1.11x a
hider at 4-8; ghost 0.92-1.13x a runner). Pushing the hunters until they wipe out a third of the
rounds makes them a points jackpot (8 players, Hide and Sneak with a 20 s glow: seeker 3.4 points
vs hider 1.7, hiders still first in 69 %). On "who caught most": seekers find more than half the
hiders in 57-69 % of rounds, ghosts catch more than half the runners in 62-77 %. I tuned for even
points; meeting 65 % on first place needs a ranking rule change (e.g. the hunters share first
place when they catch more than half), which is a design call: left for the orchestrator.

## Tooling (needs, not done: `tools/` and `game/tools/` are orchestrator-owned)

Worked around with a subclass of the runner in `game/build/balb/` (gitignored, not committed):
1. **Mixed sizes per seat** (the stock `-Size` sets every seat alike, so a size bias can't show).
2. **A per-round machine line** with roles and in-game state read at `round_finished`
   (seekers/hiders, original ghosts, catches, scores, KOs with the shover), so role balance,
   role assignment per seat and size-by-role can be computed. Today only per-seat totals print.
3. **The runner overwrites a minigame's own bot setup**: it calls `brain.configure(seed)` at the
   round intro, after `_setup`; Hide and Sneak configures its bots in `_setup`, so stock batches
   measured random-skill hiders instead of the game's sharp ones. Fix: configure before
   `_setup`, or let a minigame opt out.
4. Static rotations (Hide and Sneak, now Ghost Tag) carry over between player counts in one
   batch process; with the reset-on-new-table fix this is now harmless.

## How to re-run

The driver is `game/build/balb/driver.tscn` (not committed). With the stock tool, the closest is:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\balance-batch.ps1 -Minigame ghost_tag -Players 4 -Rounds 48 -Seed 1
```
