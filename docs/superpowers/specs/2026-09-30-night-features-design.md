# Night features: design decisions (2026-09-30)

Sander asked for: expansion ideas (see `docs/expansion-ideas.md`), a balance pass, a tutorial, character size options, and unlockable cosmetics earned by playing, and left the decisions to the orchestrator. These are the decisions.

## 1. Balance pass

Goal: fairness first, then round pacing. Measured with bot-vs-bot batches, not guessed.
- Placement points scale with player count so most players score most rounds: 2-3 players 3/2/1; 4-5 players 4/3/2/1; 6-8 players 5/4/3/2/1/1. Round winner bonus stays implicit (top points).
- Per minigame: target round length 30-60 s with 4-8 players; no slot bias (slot 0 must not win more than others across 30+ bot rounds); no size bias beyond ±5 % win rate once sizes exist; the leader should not be able to coast (each minigame keeps a comeback path: lava collapse, sumo ring drops, coin gold rush, potato fuse shrink).
- Output: `docs/balance.md` with the numbers before and after, and `tools/balance-batch.ps1` to re-run them.

## 2. Tutorial: the Training Room

- Offline, solo, bots as dummies. Entry: **How to play** on the title screen; first run suggests it once; also reachable from the pause menu.
- A guided course through a mansion garden/basement with stations. Each station: a card (title, one line, key/button glyphs for keyboard and gamepad), a task, a checkmark when done, then the gate opens. Stations: Move -> Jump (gaps, a ledge) -> Shove (a dummy blob off a pad) -> Getting shoved (a dummy shoves you; stun explained) -> Hazard tasters: a cracking lava tile, a shrinking ring edge, a bomb hand-off dummy, a coin rain patch and the sweeping bar -> Finish: confetti, "Ready to play", back to title.
- Skippable at any time (Esc -> Skip tutorial). Progress checklist in a corner. Under 3 minutes for a quick player.

## 3. Body size

- Loadout gets `size`: `small` / `normal` / `big` (wardrobe tab "Body"). Free (not an unlock).
- Visual scale 0.82 / 1.0 / 1.22 (whole model root, so items follow). Collision capsule scaled the same.
- Trade-offs (multipliers applied through the components' exported tuning in `_setup`, replicated through the loadout so every peer agrees): small: speed x1.12, jump height x1.08, shove force x0.85, knockback taken x1.25. big: speed x0.90, jump height x0.94, shove force x1.20, knockback taken x0.78. Normal: all 1.0.
- Balance target: bot batches with mixed sizes show no size with a win rate more than 5 points from the others; tune multipliers, not the rules.

## 4. Mansion Coins and unlocks

- Currency: Mansion Coins, per player, saved in the player's own `user://profile.json` (progress travels with the player, not the host).
- Earning: per round by placement (1st 6, 2nd 4, 3rd 3, others 2 for taking part) and per session by final placement (1st 40, 2nd 25, 3rd 15, others 10). A full 8-round session earns roughly 60-90 coins. Bots earn nothing. Coins are shown on the results and podium screens ("+6 coins") and the balance in the wardrobe.
- Unlocks: items have a tier price: common 30, rare 60, epic 100. Starter set free for everyone: all colours, 2 hats (party cone, cat ears), 1 face (round glasses), 1 neck (scarf), 1 back (backpack), all sizes. The rest are locked; the wardrobe shows them greyed with a price, and one click unlocks when affordable (a little fanfare). A locked item can still be worn by bots and by other players who unlocked it.
- Offline bot sessions earn coins at half rate (so the tutorial and solo play still progress, but LAN play is the fast path).
- Dev/testing switch: `--unlock-all` user arg and a hidden option; never in the UI.
- Not doing: any server-side enforcement (friends only), trading, gifting, real money.

## 5. New minigames (three)

- **Paint Splat** (score race, 45 s): floor of tiles; running over a tile paints it your colour; most tiles at the end. Shoving stuns the victim (existing) and paint under a stunned blob counts as yours. Every 15 s a "splash bomb" drops that paints a big circle for whoever grabs it.
- **Spotlight Chairs** (elimination): a ballroom; pads on the floor, one fewer than living players; music plays (a jaunty loop) while blobs mill about; the music stops with a 0.8 s warning flash; whoever is not standing on a pad is out; pads shuffle position each round. Shoving off a pad is the whole game.
- **Cannon Alley** (elimination, 60 s cap): a courtyard between two walls of cannons; cannonballs roll across in patterns that speed up; hit = knocked out (or big knockback + stun on the first hit, out on the second); jumping over slow balls is possible; shove others into the path.

Each: own folder, own art scripts under `art/scripts/props/<id>_*.py` and models `game/assets/models/props/<id>_*.glb`, bot hooks, bot-only tests, three-process network check, registry entry.
