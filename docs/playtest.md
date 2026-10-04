# Minigame Mansion: playtest guide

A party game for 2 to 8 players on the same network (same Wi-Fi or cable). Everyone runs the game on their own Windows PC.

## Get the game
- Sander sends you one file: `minigame-mansion.exe` (about 110 MB). No install: put it anywhere, for example your Desktop, and double-click it.
- Windows SmartScreen may say "Windows protected your PC" because the exe is not signed: click **More info**, then **Run anyway**.

## The firewall prompt (important)
The first time you host or join, Windows Firewall asks whether to allow the game.
- Tick **both** boxes, **Private networks** and **Public networks**, then click **Allow access**. Home Wi-Fi is often marked "Public", and then only the Public box counts.
- Missed it or clicked Cancel? Open Start, type "Allow an app through Windows Firewall", click **Change settings**, find Minigame Mansion (or the exe name) and tick Private and Public. If it is not listed, use **Allow another app...** and pick the exe.

## Host or join
- Type your name on the title screen (you get a random fun name the first time).
- **One person hosts**: click **Host game**. The lobby shows the host's IP address (for example `192.168.1.23`); click it to copy it ("Copied!") and paste it to your friends.
- **Everyone else joins**: click **Join game**. The host's game appears in the list after a second or two: click it.
  - Not listed? Type the host's IP address in the box at the bottom and click **Join**.
  - Still nothing? The firewall is almost always the reason: check the section above on **both** PCs.
- **Play offline** plays alone against bots (handy for trying the controls).
- In the lobby, run around while you wait. The host can add bots, pick the number of rounds, and press **START!**
- **Wardrobe** (title screen and lobby): pick your colours, hat, face, neck and back items. Everyone sees your new look straight away.
- Nobody can join once a session has started: join in the lobby.

## Controls
| | Keyboard / mouse | Gamepad |
|---|---|---|
| Move | WASD or arrow keys | Left stick |
| Jump | Space | A |
| Action (shove) | E or left mouse button | X |
| Pause menu (Resume / Settings / Leave / Quit) | Esc | Start |
| Use the lobby menu | Tab | Back / Select |
| Menus: move / press / back | Arrow keys or Tab, Enter or Space, Esc | Left stick or D-pad, A, B |
| Change a slider or chip in Settings | Left / Right | Left / Right |
| Fullscreen on/off | F11 or Alt+Enter | |

The game keeps running while your pause menu is open: other players are still playing. The highlighted button always has a gold ring around it.

## Settings
Open **Settings** from the title screen or the pause menu (Esc / B closes it). Everything applies straight away and is remembered for next time (in `%APPDATA%\Godot\app_userdata\Minigame Mansion\settings.json`):
- **Sound**: Master, Music, Effects and Interface volume (each slider plays a little preview sound).
- **Display**: Fullscreen, window size (1280 x 720, 1600 x 900, 1920 x 1080), Quality Low/High (Low helps older laptops), Show FPS.
- **Comfort**: Screen shake on/off, Reduced motion (calmer menus and effects).
- **Player**: your name, and **Show the welcome prompt again** (the "New here? Try the Training Room" offer on the title screen).

## A session
Each round is a random minigame: Floor Is Lava, Bumper Sumo, Hot Potato or Coin Scramble. A title card explains the rule, then 3-2-1-GO. Points per round: 1st 4, 2nd 3, 3rd 2, 4th 1. After the last round, the podium shows the winner; the host presses **Back to lobby** (or it returns by itself) for a rematch.

## Game modes
The host presses **Game setup** in the lobby (Tab / Select, then the pad works too; Esc / B closes it). The choices are remembered for next time; everyone else sees them in one line under "Waiting for the host".
- **Rounds**: 4, 8 or 12.
- **Order**: **Shuffle** (every game, no repeats until all were played), **Playlist** (only the ticked games, shuffled) or **Vote** (before each round three game cards appear: Left / Right moves your marker, E / X locks it in, or click a card; most votes wins, ties are random, bots vote too). Tick games in the grid (All / None); Playlist and Vote use the ticks. Games that need more players than are in the lobby are skipped (the grid shows "(3+)").
- **Mutators**: Off, Sometimes (about 1 round in 4) or Always. A mutator is a twist for one round, shown on the title card and as a badge top right: Low gravity, Giant blobs, Tiny blobs, Turbo, Slippery floor, Super shove, Heavy blobs, Mirror (left and right swapped). Some games never get some mutators.
- **Practice...**: pick one game (and a mutator if you like) and play it once with everyone in the lobby. No points, no coins; afterwards you are back in the lobby.

## Known issues
- If a PC drops off the network, its blob disappears for everyone after a few seconds.
- When many blobs stand in one spot, some name tags step up or fade a little so the names stay readable.
- If the host quits, everyone returns to the title screen with a message; start a new game from there.

Tell Sander what felt good, what felt unfair, and anything that looked broken (a screenshot helps: Win+Shift+S).
