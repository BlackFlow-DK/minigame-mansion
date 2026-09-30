# Minigame Mansion: expansion ideas

Written 2026-09-30 after the first playable build. Marks: **[tonight]** being built now, **[next]** good candidates for the next session, **[later]** bigger or riskier, **[no]** considered and rejected, with the reason.

## Minigames

Each minigame is one folder and one agent, so adding them is cheap. Variety matters more than count: mix elimination, score-race, team and co-op rounds so a session has rhythm.

Elimination (last blob standing):
- **Spotlight Chairs** [tonight]: musical chairs. Pads on the floor, one fewer than players; when the music stops, be on a pad or you are out. Pads shuffle each round.
- **Cannon Alley** [tonight]: cannons on the walls fire slow cannonballs across the arena; dodge and jump, shove others into the line of fire.
- **Wrecking Ball** [next]: a huge ball swings through a narrow platform on a chain; timing and shoving.
- **Rising Tide** [next]: water rises in a ruined tower; climb crates and ledges, shove climbers off.
- **Tightrope** [next]: narrow beams over the void, converging on one platform; knockback is deadly, jumping is brave.
- **Lights Out** [later]: the arena goes dark except a torch on each blob; hazards appear when lit.
- **Bomb Barrels** [later]: barrels roll down a slope in waves; jump them.

Score race (most points at the end):
- **Paint Splat** [tonight]: every tile you run over turns your colour; most tiles at the end wins; shoving stuns and lets you repaint under someone.
- **Gem Miner** [next]: gems in breakable rocks; the shove breaks rocks; bigger rocks need more hits; carry gems back to your chest (drop them if shoved).
- **Snowball Fight** [next]: pick up snow, throw with the action; hits knock and steal points.
- **Balloon Pop** [next]: everyone has three balloons on a string; pop others' by shoving; last balloons and pops both score.
- **Pancake Stack** [later]: catch falling pancakes on your head; the stack wobbles with movement; shoves topple it.
- **Delivery Dash** [later]: carry parcels to a moving van across a busy street.

Team and co-op (players split 2v2 / 4v4, or all together against the mansion):
- **Ghost Hunt** [next]: 1 ghost (invisible except when moving fast) vs hunters with lanterns.
- **Tug of Blobs** [later]: two teams push a giant ball into the other's goal.
- **Escape the Cellar** [later]: co-op puzzle-lite: buttons that need N blobs, doors, a timer.
- **Boss Bash** [later]: everyone vs a giant mansion butler robot; points for damage, penalties for getting squashed.

Round modifiers (cheap variety multiplier, one line per minigame):
- **Mutators** [next]: low gravity, giant mode, ice floor, double speed, bombs everywhere. Roll one on a random round, announce it on the title card.
- **Sudden Death** [next]: a tie-break round on the sumo core.
- **Final round double points** [next].

## Characters and customisation

- **Body size** [tonight]: small / normal / big with trade-offs.
- **Unlockable cosmetics with Mansion Coins** [tonight].
- **Emotes** [next]: a wheel (taunt, dance, cry, wave) usable in the lobby and after elimination; some unlockable.
- **Victory poses** [next]: chosen in the wardrobe, played on the podium.
- **Eye and mouth styles** [next]: angry brows, sleepy eyes, buck teeth: separate face-shape slot from face items.
- **Patterns** [next]: spots, stripes, gradient on the body (shader-driven, no new models).
- **Trails and particles** [next]: sparkles, bubbles, flames behind a running blob; unlockable.
- **Pets** [later]: a tiny follower (duck, ghost, robot) that copies emotes.
- **Name tag styles and titles** [later]: "Lava Lord" earned by winning Floor Is Lava 5 times.
- **Seasonal items** [later]: pumpkin head, Santa hat, on real-date triggers.

## Progression and meta

- **Mansion Coins** [tonight]: earned by placement and round wins; spent in the wardrobe.
- **Stats page** [next]: sessions, wins, best minigame, shoves landed, times knocked out; per player, local.
- **Achievements** [next]: "Win a round without shoving", "Survive lava for 45 s", each pays coins.
- **Daily/weekly challenges** [later]: local-time based.
- **Session summary card** [next]: after the podium, funniest stat of the night ("Most shoved: Bob, 31 times").
- **Rivalries** [later]: track head-to-head between two players over sessions.

## Lobby and social

- **Lobby toys** [next]: a football to kick around, a bell, a trapdoor, a scoreboard on the wall showing tonight's totals.
- **Trophy room** [next]: a room off the hall where each player's podium wins appear as trophies (from local stats, shown to all).
- **Vote for the next minigame** [next]: three portals light up; stand in front of one to vote; ties random.
- **Spectator mode for late joiners** [next]: join mid-session as a ghost in the lobby, play from the next session.
- **Quick chat** [later]: a few canned messages / emojis over the head (no free text: no moderation needed).
- **Voice chat** [no]: complex, and friends on a LAN already have Discord.

## Feel and polish

- **Music** [next]: procedural or CC0 loops per mood (lobby waltz, lava drums, sumo taiko, night funk), ducked during results.
- **Screen shake, hit-stop and slow-mo on the final knockout** [next].
- **Camera intro fly-through per arena** [next] during the title card.
- **Crowd**: cheering blob spectators around arenas [later].
- **Weather and time of day in the lobby** [later].
- **Accessibility** [next]: colour-blind-safe player palette check, hold-to-shove option, reduced shake toggle, remappable keys.
- **Settings screen** [next]: volume sliders, fullscreen, quality low/high, key rebinding.

## Multiplayer and sharing

- **Reconnect** [next]: a dropped player rejoins the same session with their slot and score.
- **Internet play via a relay** [later]: Steam networking or a small relay server; needed only if friends are not on one LAN.
- **Web build** [later]: friends open a link; networking in browsers needs WebRTC or a relay, so pair with the above.
- **Steam release with Remote Play Together** [later]: same-screen play over the internet without any networking work.
- **Local multiplayer on one PC** [later]: two players on one keyboard/gamepads, useful with a TV.
- **In-game invite link** [no]: needs internet play first.

## Tooling for us

- **Balance dashboard** [tonight, first version]: bot-vs-bot batch runs printing round lengths, slot bias and points spread per minigame.
- **Replay capture** [later]: record inputs for bug reports.
- **Auto-updater** [later]: the exe checks a shared folder or GitHub release for a newer version.

## Rejected

- **Random character sizes** [no, changed]: randomness would feel unfair in a competitive round; a chosen size with trade-offs keeps the fun and the fairness.
- **Server-side unlock checks** [no]: friends only; a cheat only cheats yourself.
- **Real-money anything** [no].
