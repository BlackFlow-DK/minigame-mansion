# Balance pass v0.3, part A (2026-10-05, branch `bal-a`)

Crown Keeper, Mansion Dash, Blob Ball, Statue Garden, Rising Tide; plus a seat-bias check of
Cannon Alley. Targets: rounds 30-60 s typical (none under 20 s, none dragging to the cap), no
seat bias, no body-size bias beyond about +-5 points of win rate, neither team side favoured,
a comeback path, bots that actually play. Method as in `docs/balance.md` (bot-only rounds
through the real Session, personalities rotated over the seats).

## Method and noise

- Seats and lengths: `tools\balance-batch.ps1` (normal size), 48 rounds per cell, 96 for the
  seat re-checks.
- Body size, teams and per-game numbers: `balance-batch` has no mixed sizes and no per-size or
  per-team counts, so this pass used a driver in its own `build\bal\` (not committed; the tool
  is orchestrator-owned): `mixed_runner.gd` extends `game/tools/balance/balance_runner.gd`,
  overrides `_play_round` to give seat s in round r the size `[small, normal, big][(s + r div N)
  mod 3]` (sizes rotate per personality block, so every seat plays every size with every
  personality), and adds: win rate per size per appearance and mean normalised place (1 = first,
  0 = last), team-0 / team-1 / tie and smaller-team wins, crown points spread and the 60 % leader,
  statue catches, blob goals, end positions with `--verbose`. Run as
  `godot_console --headless --fixed-fps 60 --path game --script <abs>\build\bal\mixed_main.gd --
  --minigame=<id> --players=4,8 --rounds=48 --seed=S [--normal] [--set=...]`.
- Noise (1 sd): seat win rate at 48 rounds about 7 points (2 players), 6 (4), 5 (8); at 96
  rounds 4.4 (4) and 3.4 (8). Size win rate per appearance: about 5.4 points with 4 players
  (64 appearances a size), 2.9 with 8 (128). One cell in a table at 2 sd is expected.
- "Before" = main at e6608c3. Seeds differ between before and after rows unless noted.

## Crown Keeper: size bias fixed (speed and pickup reach)

| | Before | After |
|---|---|---|
| Round length | 60 s + 2 s grace, every round (fixed clock) | same |
| Win by seat, 4 players | 19 / 21 / 25 / 35 % (seed 1) | 26 / 27 / 27 / 20 % (96 rounds, seed 10) |
| Win by seat, 2 / 3 players | 56 / 44 %, 29 / 40 / 31 % | 46 / 54 %, 35 / 33 / 31 % (seed 12) |
| Win by seat, 8 players | 4-17 % (seed 1) | 8-17 % (seed 12), mean places 4.10-4.81 |
| Win by size, 4 players (small / normal / big) | 47 / 20 / 8 % | 22 / 31 / 22 % (96 rounds) |
| Win by size, 8 players | 18 / 14 / 5.5 % | 8.6 / 17 / 12 % (seed 12); 3 players 23 / 40 / 38 % and 46 / 29 / 25 % (seeds 12, 8) |
| Players scoring > 0, 4 / 8 | 95 / 89 % | 95 / 86 % |
| 60 % leader goes on to win, 4 / 8 | 73 / 49 % | 64 / 47 % |

Changes:
- `wearer_speed_factor` is now of a NORMAL blob's speed for every wearer. With the size's 1.15
  on top, a small wearer ran 6 % faster than a normal chaser and could not be caught.
- `size_speed_share` 0 (new): non-wearers all run at normal speed here; shove, reach, jump and
  knockback still follow the size. A pure chase: speed decides almost everything. Tried 1 and
  0.5 (4 / 8 players small-normal-big: 30/31/14 % and 20/9/8 %; 31/19/25 % and 17/13/7 %).
- Pickups measure to the blob's surface (normal-size equivalent): nearest wins a contested grab
  and a big body cannot get its centre as close to the throne or the crown (with speed already
  neutral, big still won 16 % of 4-player rounds over 192, small 30 %).
- Bots: the chasers' lead amounts were a hash of slot and pickup count only (the same every
  round for a slot); now salted per round from `rng`.
Seat 3's 35 % (4 players, seed 1) did not repeat: 23 / 25 / 23 / 20 % on seeds 2 / 6 / 8 / 10.

## Mansion Dash: seat layout and size bias fixed

| | Before | After |
|---|---|---|
| Length mean / median (min-max), 2 players | 49.0 / 49.1 (32-76) | 48.1 / 48.3 (34-76) |
| 3 players | 47.8 / 46.4 (35-67) | 48.6 / 47.0 (34-76) |
| 4 players | 45.8 / 44.5 (34-63) | 46.2 / 43.7 (37-76) |
| 8 players | 45.3 / 43.7 (36-59) | 45.8 / 46.0 (34-62) |
| Win by seat, 4 players | pooled seeds 1-4 (192): 21 / 22 / 30 / 27 %, mean place 2.67 / 2.50 / 2.46 / 2.38 | pooled seeds 4 / 6 / 8 (144): 29 / 27 / 26 / 18 %, mean place 2.49 / 2.49 / 2.43 / 2.57 |
| Win by seat, 8 players | 10-17 % | 6-25 % (seed 8), 2-19 % (seed 6); mean places 3.94-4.96 |
| Win by size, 4 players | 34 / 28 / 13 % | 22 / 20 / 33 % (seed 8); pooled 3 seeds 24 / 25 / 26 % |
| Win by size, 8 players | 23 / 9 / 6 % | 12.5 / 10 / 15 % (seed 8), 12.5 / 12.5 / 12.5 % (seed 6) |

Changes:
- Start layout: the old straight row (x = -3.85 + 1.1 i) put 2-4 players all left of the first
  slalom row's single middle gap. Over 192 four-player rounds the outermost seat placed worst
  (2.67) and the seat nearest the middle best (2.38): small, but in the direction the geometry
  predicts. Now every spawn point sits on an arc of 5.5 m round that gap (the same run for every
  point), N players take the middle N points 1.1 m apart, and the host shuffles which slot gets
  which point (`_rpc_spawn_layout`, reliable, from `_setup`; checkpoint respawns use the same
  index). The markers in the scene are the 8-point arc. The network check now also asserts every
  peer applied the same layout.
- `size_speed_share` 0 (new): every size runs at normal speed in the race (jump, shove and
  knockback still follow the size). Share 0.4 still left big at 7 % with 8 players.
- Bots: the lane taste hash had no round seed (a slot drove the same lines every round); now
  salted with the course seed.
The "seat 3" suspicion: not a high seat 3 but a slight edge for the middle seats under the old
row; seat 3 pooled 27 % (192 rounds) before. Cleared as a bias of its own; the layout cause fixed.

## Blob Ball: shorter matches, wider goals

| | Before (seed 1 / 2) | After (seed 11) |
|---|---|---|
| Length mean / median (min-max), 2 players | 82.6 / 91.8 (31-118) | 57.7 / 58.1 (26-73) |
| 3 players | 81.4 / 84.3 (25-121) | 52.7 / 55.0 (21-74) |
| 4 players | 91.8 / 95.0 (29-124) | 60.8 / 61.1 (25-73) |
| 5 / 7 players | 91.7 / 98.5 mean | 57.9 / 58.3 mean |
| 8 players | 101.0 / 99.2 (64-124) | 58.0 / 58.1 (20-73) |
| Goals per round, 4 / 8 | 2.4 / 1.9 | 1.8 / 1.9 |
| Team 0 / team 1 / tie, 4 players | 40 / 35 / 25 % | 29 / 40 / 31 % |
| Team 0 / team 1 / tie, 8 players | 40 / 44 / 17 % | 42 / 44 / 15 % |
| Win by size, 4 / 8 players | 23 / 28 / 24 %, 12.8 / 12.2 / 12.5 % | 27 / 22 / 25 %, 13.7 / 12.7 / 11.1 % |
| Smaller team's share of decided odd rounds (3 / 5 / 7 players) | 23 / 37 / 41 % | 27 / 47 / 30 % |
| Win by seat | max 29 % (4), 15 % (8) | max 29 % (4), 14 % (8) |

Changes:
- `match_time` 90 -> 50 s, `golden_goal_time` 20 -> 15 s. Bots reached 3 goals in only 10-19 %
  of matches, so almost every round ran the full clock plus a golden goal: 92-101 s.
  60 s + 15 s gave 69-71 s; first-to-2 instead allowed 15 s blowouts.
- `GOAL_WIDTHS` (new const) 3.6 / 3.8 / 4.0 -> 4.4 / 4.6 / 4.8 m: with the 1.4 m ball, bots
  scored 1.2-1.5 goals in 60 s and a quarter of the matches ended level.
- Kept: `small_team_kick_bonus` 1.15. Scaling it with the size ratio (up to x1.41 for a 1 v 2)
  did not move the bots' 1 v 2 (22 -> 24 %).
Team sides: neither favoured (team 0 led on seed 2 in every variant, team 1 on seed 11: the seed
fixes the team draws). Ties: a level match after the golden goal ties everyone; 13-31 % of
rounds, as before (17-25 %). Uneven counts: see open questions.

## Statue Garden: two bot bugs, a slower pace, size-neutral speed

| | Before (seed 1) | After (seed 5) |
|---|---|---|
| Length mean / median (min-max), 2 players | 65.3 / 76.5 (30-77), 26 of 48 at the limit | 47.7 / 44.5 (38-77), 4 of 48 |
| 3 players | 54.0 / 51.0 (30-77), 10 at the limit | 45.4 / 44.1 (36-77), 1 |
| 4 players | 44.7 / 40.4 (24-77), 4 at the limit | 44.8 / 44.5 (32-67), 0 |
| 8 players | 35.8 / 32.3 (25-77) | 42.3 / 42.5 (33-61) |
| Catches per bot per round, 2 / 4 / 8 | ~3 / 1.2 / 0.9 (after the touch fix, seed 1) | 1.0 / 0.8 / 1.1 |
| Win by size, 4 / 8 players | 45 / 23 / 6 %, 27 / 9 / 2 % (new pace, before the size fix) | 27 / 21 / 27 % (96 rounds, seed 13); 9 / 11 / 17 % |
| Win by seat, 4 players | 25 / 21 / 19 / 35 % | 27 / 27 / 23 / 23 %; 96 rounds seed 13: 27 / 23 / 31 / 19 % |

Changes:
- Bot bug: on the last stretch bots aimed at a point 0.05 m in front of the plinth; the brain
  counts a goal within 0.6 m as reached and stops, which left them 0.8-0.9 m from the face,
  outside the 0.55 m touch distance: they stood at the plinth till time-up. Now they aim 0.5 m
  into the plinth (`BOT_TOUCH_PUSH`) and walk until they touch.
- Bot bug: beside an obstacle (urn, bench, hedge) the detour point was within the arrival
  radius and the line on to the lane goal still clipped the obstacle, so the bot got the same
  point again and stood still. Now a bot already beside it heads 1 m past the obstacle.
- `bot_hold_reaction` 0.9 (new; `bot_reaction_scale` = it / time_scale): at the brain's
  default hold reactions two mid-skill bots were caught ~3 times each per round; at 0.7 nobody
  was caught; 0.9 still catches the slow ones.
- `WALK_SPEED` 2.2 -> 1.5, `red_range` 1.5-3.0 -> 2.0-3.2 s: 8-player rounds were 25-36 s
  (median 32) against the 30 s floor; now 33-61 s (median 42.5).
- `size_speed_share` 0 (new): every size tiptoes at `WALK_SPEED` (small 1.15x won 45 % of
  4-player rounds).
- `test_statue_garden_bots`: the 12-round seat check runs in 4 tests of 3 rounds (60 s per test)
  and rotates personalities over the slots like the balance runner (it had a fixed personality
  per slot and seed, so it measured which slot drew the sharpest bot).
Seat 3 in 4-player rounds: 35 % on seed 1 before; after the changes 23 / 32 / 21 % on seeds
5 / 7 / 9 (240 rounds, 25.8 %): cleared.

## Rising Tide: shorter water

| | Before (seed 1) | After (seeds 2 / 6 / 7) |
|---|---|---|
| Length mean / median (min-max), 2 players | 53.9 / 62.0 (14-66) | 46.3 / 50.5 (13-60); 47.8 / 56.5 (13-60) |
| 3 players | 62.6 / 66.2 (26-66) | 56.4 / 59.2 (35-60); 52.2 / 58.0 (24-60) |
| 4 players | 63.8 / 65.8 (37-66) | 56.4 / 60.0 (25-60); 57.3 / 59.9 (35-60) |
| 8 players | 65.8 / 66.2 (62-66) | 57.6 / 60.0 (31-60) |
| Blobs drowned, 4 / 8 players | 61 / 71 % (seed 2) | 59 / 76 % (seed 2) |
| Win by size, 4 / 8 players (small / normal / big) | 23 / 30 / 22 %, 14 / 13 / 10 % (seed 2) | 27 / 23 / 25 %, 10 / 16 / 12 % (seed 2); 25 / 27 / 23 % (4, seed 6) |
| Win by size, 2 / 3 players | not measured | 53 / 34 / 63 %, 23 / 27 / 50 % (seed 6); 47 / 42 / 61 %, 24 / 22 / 54 % (seed 7) |
| Win by seat, 4 players | 29 / 19 / 15 / 38 % | 19 / 25 / 33 / 23 % (seed 2), 23 / 25 / 21 / 31 % (seed 6) |

Change: `TideTower.WATER_RATE1` 0.5 -> 0.6 m/s. The water topped out at 64.2 s, so nearly every
4-8 player round ran 66 s; now 57.9 s (60 s with the end grace). Only the late climb is faster
(+1 m of water at 30 s); drownings barely moved. Every other number is unchanged.

Not fixed: big blobs win 2-3 player rounds too often (+10 to +20 points, two seeds; 4-8 players
are fine). Ruled out by experiment, not kept: drowning at a fixed 0.5 m above the feet instead
of the blob's own centre (0.61 m for big) and neutralising shove force and knockback by size;
neither moved it (3 players big 54 -> 56 / 52 %). Left: the body itself (a bigger capsule on
0.9 m steps and ledges, or in the narrow lanes of a duel); needs a look at where the small blob
loses in a duel.

Slot 3 in 4-player rounds: 38 % on seed 1, then 21 / 17 / 27 / 35 % on seeds 2-5 (before the
water change): pooled 240 rounds 27.5 % (+0.9 sd): cleared. Seat 1 sat lowest on 4 of those 5
seeds (19 % wins, mean place 2.66 over 240 rounds, about 2 sd); no slot-ordered rule was found
(spawns, route tastes and roof tastes are all seeded per round; tie-breaks favour low slots if
anything), and after the water change seat 1 won 25 % on two seeds.

## Cannon Alley: seat bias check (no change)

| | 4 players, 96 rounds, seed 7 | 8 players, 96 rounds, seed 7 |
|---|---|---|
| Win by seat | 26 / 24 / 22 / 28 % | 14.6 / 9.4 / 13.5 / 17.7 / 9.4 / 13.5 / 13.5 / 8.3 % |
| Mean place | 2.39-2.63 | 4.30-4.84 (fair 4.50) |
| Length mean / median | 43.4 / 44.5 (25-57) | 46.5 / 46.9 (31-59) |

Seat 7 (8 players) 8.3 % here, 9.4 % over the earlier 96 (`docs/balance.md`): about 1.2 sd
low each time, mean place 4.49 now. Seat 0 14.6 %. A chi-square over the 8 seats is far from
significant (p ~ 0.6). Cleared; the spawns are mirror-symmetric.

## Tests touched

- `test_crown_keeper.gd`: run speed ignores body size (1 s runs; wearers of any size at the
  crowned pace).
- `test_mansion_dash.gd`: spawn markers on the arc (same run to the choke, 1.1 m apart), every
  slot on its own layout point; run speed ignores body size. `test_mansion_dash_bots.gd` seeds
  the global RNG per race (the start-layout shuffle uses it), so the races replay exactly.
- `test_statue_garden.gd`: last-stretch goal inside the plinth; walk pace ignores body size;
  `bot_reaction_scale` follows `bot_hold_reaction`. `test_statue_garden_bots.gd`: see above.
- `test_rising_tide.gd`: water end time 52-60 s, late rate 0.6 m/s.
- Crown Keeper's per-round taste salt is drawn from `rng` at the first chase, not in `_start`,
  so `test_crown_keeper_bots` (which seeds `rng` after spawning) stays deterministic.

## The three seat suspicions

| Suspicion | Sample | Verdict |
|---|---|---|
| Mansion Dash seat 3 | 192 four-player rounds (seeds 1-4) | not a seat-3 bias: a slight middle-seat edge from the straight start row (outermost seat mean place 2.67, middle 2.38); layout fixed |
| Rising Tide slot 3 | 240 four-player rounds (seeds 1-5) | cleared: 27.5 % |
| Cannon Alley | 96 + 96 rounds (4 and 8 players), plus 96 earlier | cleared |

## Open questions and requests

- Tool (`balance-batch.ps1`, orchestrator-owned): mixed body sizes and per-size / per-team
  tallies would let the size and team targets be measured without a side driver
  (`build\bal\mixed_runner.gd` here is the sketch: one override of `_play_round` and a
  tally after each round).
- Shared (`SizeComponent`, catalog): the size speed factors (small 1.15, big 0.88) decide races
  and chases outright; three minigames (Crown Keeper, Mansion Dash, Statue Garden) now carry the same "write base / factor each frame"
  code to opt out. A minigame hint (`size_speed_share`) read by the size component would be
  simpler and avoids a bookkeeping corner: a minigame value that happens to equal what the size
  component wrote last is taken as its own write and not rescaled.
- Blob Ball 1 v 2 (3 players): the lone blob's side wins about a quarter of decided rounds
  even with a x1.41 kick. Each player still wins equally often over a session (teams are drawn
  at random), but in that round the lone blob is the underdog. Options: accept, a lone-blob
  goal that counts double, or a narrower goal behind the lone blob (BallSim has one goal width).
- Blob Ball ties: a level match after the golden goal makes everyone a tied winner, 13-31 % of
  bot rounds. A longer golden goal (20 s) or a penalty shoot-out would cut it.
- Rising Tide: big blobs in 2-3 player rounds (above); the shortest 2-player rounds are 13 s
  (a bot shoved into the water early; rare, as before).
- Statue Garden with humans: bots now stop on the tune with 0.9x the brain's reaction; humans
  probably react faster still and get caught less, so human rounds may run near the 2-4 bot
  numbers (~44 s).
