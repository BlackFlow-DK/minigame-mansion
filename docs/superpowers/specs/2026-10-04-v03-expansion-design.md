# v0.3 expansion: design decisions (2026-10-04)

Sander asked for a much bigger game to fool around in with friends: many more minigames of DIFFERENT kinds (not all elimination brawls: hide-and-seek, races, teams...), good performance, pretty animation. Character customisation is enough as it is. The orchestrator decides.

Guiding rule: every new minigame must add a new *verb* or a new *social situation*. The seven existing ones cover: survive hazards (lava, cannons), shove brawl (sumo), keep-away of a bad thing (potato), grab race (coins), territory (paint), musical chairs.

## A. Framework additions (needed by the new kinds)

A1. **Teams and roles.** `Minigame` gains optional teams: `assign_teams(count)` splits players evenly (host decides, sent to all), `team_of(slot)`, team colours shown as a ring under the blob and on the HUD strip. `finish()` accepts a ranking with ties: an array whose entries are slots or arrays of slots (a tied group shares the best place's points). Round UI shows tied groups on one line. Roles (seeker/hider, ghost/hunter) are the minigame's own business; the title card can show a per-player role line ("You are the SEEKER").
A2. **NPC extras.** A minigame may ask Stage for extra bot-driven blobs that are not in the roster (`Stage.spawn_extras(count, loadouts)`, slots 100+), host-owned, synced like bots, never scored, never shown in the HUD. For crowds and dummies.
A3. **Game modes** (after the minigames land): the host chooses in the lobby between Shuffle (as now), Playlist (tick the minigames to include), and Vote (three portals light up before each round; stand at one to vote). Plus **Mutators**: optional per-round twists announced on the title card (low gravity, giant blobs, tiny blobs, turbo speed, slippery floor, super shove), off by default, "Sometimes" or "Always".
A4. **Practice**: from the lobby, the host can start a single chosen minigame (no score), for fooling around.

## B. New minigames (target: 15 in total)

| id | Name | Kind | One-line rule |
|---|---|---|---|
| `mansion_dash` | Mansion Dash | race | Obstacle course through the mansion gardens: swinging hammers, rolling logs, moving platforms, a see-saw; first to the finish wins; fall = back to the last checkpoint. |
| `statue_garden` | Statue Garden | red light, green light | A giant stone butler turns its head. Move while it looks away; anyone moving while it stares is sent back to the start. First to touch it wins. Shoving someone while it stares gets THEM caught. |
| `crown_keeper` | Crown Keeper | keep-away (good thing) | One crown. Wearing it scores a point per second. Shove the wearer to make it drop; most points after 60 s. |
| `hide_and_sneak` | Hide and Sneak | hide and seek / prop hunt | Hiders turn into furniture in a cluttered parlour and may shuffle slowly; the seeker (2 with 6+ players) has limited pokes; hiders score for time survived, seekers for finds. Roles rotate if the session draws it again. |
| `blob_ball` | Blob Ball | team sport | Two teams, one huge ball, two goals. Shove the ball and each other. First to 3 or most goals at 90 s. |
| `masquerade` | Masquerade | hidden identity | Everyone looks identical and walks among 20 identical NPC dancers. Find and shove the real players; shoving an NPC stuns you and reveals you briefly. Last unfound wins. |
| `ghost_tag` | Ghost Tag | infection tag | One ghost. Touch turns blobs into ghosts. Survivors score for time alive; the first ghost scores per catch. Dark mansion corridor loop with lanterns. |
| `portrait_panic` | Portrait Panic | memory / reaction | The floor is a grid of picture tiles. A portrait is shown; stand on a matching tile before the rest drop. Patterns get harder; last blob standing. |
| `snowball_fight` | Snowball Fight | throwing | Scoop snow (hold action), throw (release). Hits knock back and score; three hits and you sit out 3 s. Most hits in 60 s. |
| `rising_tide` | Rising Tide | climbing | Water rises in a ruined tower. Climb crates, ledges and ladders; shove climbers off. Highest blob when the water reaches the top, or last one dry. |

(Ten are specified; the first eight are the v0.3 target, the last two follow if time allows.)

## C. Polish

- **Animation:** more life in the blob: idle fidgets (look around, stretch, yawn, hat adjust), run start/stop skids, turn leans, victory and defeat poses per placement on the podium, taunt/emote wheel (4 emotes on keys 1-4 / d-pad), reaction faces to nearby events, carrying and throwing poses for the new minigames.
- **Lobby toys:** a kickable football with two small goals, a trampoline, a bell, a see-saw: things to do while waiting. Host-authoritative, cheap.
- **Performance:** re-measure all 15 minigames at Low/Medium/High with 8 players, fix regressions, keep the exe startup and memory in budget; per-minigame draw-call budget (under 1000 at Low).

## D. Order of work

Batch 1: A1 teams, A2 extras, `mansion_dash`, `statue_garden`, `crown_keeper`.
Batch 2: A3+A4 modes/mutators/practice, `hide_and_sneak`, `blob_ball` (teams), `masquerade` (extras), `ghost_tag`.
Batch 3: `portrait_panic`, `snowball_fight`, `rising_tide`, animation, lobby toys, performance.
Then: balance batch on the new games, independent review, release v0.3.

At most five agents at once: six or more starved the machine last time.
