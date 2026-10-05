# Performance: running on weak PCs

Target: school PCs with integrated Intel/AMD graphics, 8 GB RAM, old drivers. Dev box for the
numbers below: Ryzen 5 3600, RTX 3060 Ti, Godot 4.7.2 Forward+ (Vulkan), editor binary.

## If it stutters on your PC (for players)

1. Settings > Display > Quality: **Low**. (On Intel/AMD laptop graphics the game already picks it.)
2. Play **windowed at 1280x720** (F11 / Alt+Enter toggles fullscreen); a big fullscreen window
   costs the graphics chip more pixels.
3. **Close other apps**: the browser, video calls, other games. Laptops: plug in the charger
   (battery saving halves the graphics speed).
4. Still stuttering? Fewer bots (each bot thinks every tick), and Settings > Show FPS to check.
5. The very first start after an update compiles shaders: the first minute can hitch once or
   twice, later starts do not.

## How to measure

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf-run.ps1 -Label after -Shots
powershell ... tools\perf-run.ps1 -Scenes lobby,bumper_sumo -Qualities low -Seconds 15 -Census
powershell ... tools\perf-run.ps1 -Label loads -Transitions -Qualities low,high
powershell ... tools\perf-run.ps1 -Label rel -Release build\windows\minigame-mansion.exe -Qualities low
powershell ... tools\perf-run.ps1 -Label base -GameDirOverride build\base\game -Scenes lobby   # A/B
```

`tools/perf-run.ps1` runs the real game windowed at 1280x720 through
`res://tools/perf/perf_driver.tscn`, once per scene and quality: title (live hall behind the
menu), lobby (offline, 8 players), the dev arena, every minigame through the sandbox with
8 players (7 bots), then the **podium** (a 1-round session of `-PodiumGame`, default Bumper
Sumo) and the **vote** screen (the VOTE cards over the lobby hall); for these two the probe
waits for the Session state and slows `Session.time_scale` so the phase outlasts the
measurement. `-ListScenes` lists the scenes (not podium/vote). Each run warms up (3 s), then
measures (10 s) with vsync off and no frame cap, and appends one row to `build\perf\<label>.csv`:
average and 1 % low frame time (mean of the worst 1 % of frames), renderer CPU/GPU time summed
over every viewport (mean and median), draw calls, primitives, video/texture memory, static
memory, startup, and a **frame breakdown**: physics ticks per frame, physics scripts (every
`_physics_process`: movement, bot brains, minigame host ticks), physics total (+ the physics
server), process scripts (`_process`: visuals, dressing, UI) and the rest (render submit, sync),
each for all frames and for the worst 1 % (`w_*`). `<label>.mem.csv` has the peak working set.
Other switches: `-Throttle` (2 cores, below-normal priority), `-Shots` (PNG per run), `-Census`
(`RenderCensus` per node: lights, surfaces, shadow casters, outlines, materials, MultiMesh ->
`<label>_census.log`), `-Transitions` (one offline playlist session through every minigame:
stage load -> first drawn frame and the worst frame of the next 2 s -> `<label>.load.csv`),
`-Release <exe>` (launch -> title drawn, exe size, peak RAM of an offline session),
`-GameDirOverride <dir>` (measure another copy of the project: `git archive main game` into
`build\base\` plus this branch's `game/tools/perf/`, for interleaved A/B runs),
`--perf-hide=Name,lights` via `-ExtraArgs` (hide nodes to see what they cost).
`res://tools/perf/startup_probe.tscn` prints the startup breakdown, `res://tools/perf/load_probe.tscn
-- --minigame=<id>` where one minigame's load goes (resource load, instance + `_ready` with the
outline bake and the static merge, `_setup`, first frame). Script hot spots: run the game with
`-d --profiling` (Godot's local debugger prints the top functions of one frame per second);
summing each function's self time over the sampled frames found the bot costs below.

**Noise.** This pass ran while 2-4 other agents ran Godot test suites and a game was open on
the same GPU: single runs scatter by +-30 % (GPU) and more (1 % lows). Every before/after pair
below was measured interleaved (base run, branch run, same scene and level, back to back), and
GPU ms is the median of the frames, not the mean. Treat differences under ~20 % as noise; draw
calls and triangles are exact.

## LOW / MEDIUM / HIGH

Settings > Display > Quality (Low / Medium / High), live, no restart. `--quality=low|medium|high`
on the command line overrides the saved choice. Code: `Look.set_quality` (`game/look/look.gd`),
`StageLook.apply`, `Fx` caps, lobby lights.

| | LOW | MEDIUM | HIGH (unchanged) |
|---|---|---|---|
| 3D resolution | 0.75 scale, FSR1 upscale | 1.0 | 1.0 |
| Anti-aliasing | FXAA (MSAA off) | FXAA (MSAA off) | as the viewport had it |
| SSAO | off | off | on |
| Glow (emissive bloom) | off | on | on |
| Distance fog | off | on | on |
| Sun shadow | 1 split, 1024 atlas, 60 % range, light blur | 2 splits, 2048 atlas, 75 % range | 2 splits, 4096 atlas, blended |
| Soft-shadow filter | very low | very low | low |
| Toon outlines | off | on | on |
| Fx | 4 live per effect, half the particles | 8 live, 3/4 of the particles | 10 live, all |
| Feel extras (spotlight, vignette, extra confetti, flash lights) | off | on | on |
| Lobby lights | fire (no shadow), 4 chandeliers (8 m reach), portal; candelabras and moonbeams glow only | all 14, fire casts shadows | all |
| Title's hall (SubViewport) | 0.5 scale (0.75 x 0.67) | 0.67 scale | full, 2x MSAA |
| Blob mesh | blob_lod.glb for NPC extras and blobs > 14 m | blob_lod.glb for extras and blobs > 20 m | full |
| Blob animation | extras and blobs > 14 m pose every other frame | every frame | every frame |
| Minigame lights | Hot Potato 4 of 8 lanterns, Spotlight Chairs without the stage wash | all | all |

LOW still looks like the same game: same palette, toon ramp, rim light, sun shadows and blob
shadows, just no ink lines, bloom or contact shading and a slightly softer image. Side by side:
`build\screenshots\showcase_sbs.png` (look showcase), `showcase_crop_sbs.png` (close-up),
`sumo_sbs.png` (Bumper Sumo, 8 players), `lobby_sbs.png` (lobby), `title_sbs.png` (title LOW vs HIGH),
`build\perf\shots\after_<scene>_<level>.png` (every scene). A hard (blur 0) LOW shadow left acne
rings on round shapes at 1024 texels; blur 1.0 with the very-low filter removes them.
v0.3 before/after side by side (main vs perf2, LOW and HIGH, every scene changed):
`build\screenshots\sbs\<scene>_<level>.png` (title, lobby, mansion_dash, hide_and_sneak,
statue_garden, masquerade, hot_potato, spotlight_chairs); round layouts differ between runs
(random seeds, round phase), the dressing does not.

## First-run auto-detect

With no `user://settings.json` yet, `Settings.detect_quality(adapter name, device type)` picks
the level (it is not saved until the player changes a setting, so it re-detects until then):

1. software or virtual device (llvmpipe, WARP, VMs) -> LOW
2. name contains "arc" (Intel Arc, discrete or the newer iGPUs) -> MEDIUM
3. Vulkan reports an integrated GPU -> LOW
4. name contains intel, uhd, iris, hd graphics, radeon(tm) graphics, radeon graphics, radeon vega,
   vega 3/6/8/10/11, llvmpipe, swiftshader, microsoft basic, mali, adreno, powervr -> LOW
5. name contains gt 7xx, gt 1030, gtx 9xx/10xx/16xx, mx1xx-mx5xx, rx 4xx/5xx, rx 6400/6500,
   radeon r5/r7/r9, radeon hd, quadro, rtx 2050/3050 -> MEDIUM
6. any other name -> HIGH (an empty name -> MEDIUM)

Godot 4.7 exposes no VRAM size, so the rule uses the adapter name and device type only.
The dev box (RTX 3060 Ti, discrete) detects HIGH.

## v0.3 pass: results (1280x720, 8 players, ms per frame)

"before" = main at e626182 (17 minigames, rising_tide in), "after" = branch `perf2`; interleaved
pairs, see Noise above. VRAM and RAM are the after values.

| scene | level | frame ms | 1 % low ms | 1 % low / avg | GPU ms (median) | draws | tris (k) | VRAM MB | RAM MB |
|---|---|---|---|---|---|---|---|---|---|
| title | low | 3.99 -> 3.14 | 12.01 -> 6.7 | 3 -> 2.1 | 0.62 -> 0.57 | 681 -> 448 | 207 -> 223 | 88.4 | 755 |
| title | medium | 5.18 -> 4.11 | 14.86 -> 7.85 | 2.9 -> 1.9 | 1.13 -> 0.9 | 1282 -> 859 | 366 -> 506 | 117.4 | 761 |
| title | high | 5.45 -> 4.3 | 10.06 -> 12.06 | 1.8 -> 2.8 | 1.52 -> 1.44 | 1326 -> 853 | 390 -> 539 | 193.9 | 769 |
| lobby | low | 8.45 -> 7.01 | 17.18 -> 13.87 | 2 -> 2 | 1.92 -> 1.44 | 942 -> 643 | 286 -> 242 | 109.8 | 855 |
| lobby | medium | 11.75 -> 9.82 | 27.11 -> 16.35 | 2.3 -> 1.7 | 2.67 -> 2.63 | 1758 -> 1131 | 578 -> 620 | 165.9 | 859 |
| lobby | high | 13.8 -> 9.77 | 21.96 -> 20.4 | 1.6 -> 2.1 | 3.87 -> 2.17 | 2023 -> 1238 | 696 -> 732 | 198.6 | 864 |
| podium | low | 4.3 -> 4.9 | 10.4 -> 10.36 | 2.4 -> 2.1 | 0.63 -> 0.59 | 424 -> 387 | 132 -> 109 | 136.5 | 828 |
| podium | medium | 5.81 -> 4.83 | 10.32 -> 9.73 | 1.8 -> 2 | 1.0 -> 0.91 | 643 -> 556 | 275 -> 226 | 153.4 | 833 |
| podium | high | 4.68 -> 4.95 | 9.46 -> 9.23 | 2 -> 1.9 | 1.0 -> 1.17 | 788 -> 655 | 373 -> 280 | 186.1 | 833 |
| vote | low | 5.7 -> 6.49 | 10.19 -> 9.69 | 1.8 -> 1.5 | 1.58 -> 1.6 | 758 -> 484 | 258 -> 250 | 108.8 | 786 |
| vote | medium | 7.24 -> 6.19 | 13.35 -> 12.24 | 1.8 -> 2 | 1.72 -> 1.67 | 1838 -> 1071 | 666 -> 697 | 165.1 | 794 |
| vote | high | 6.51 -> 5.66 | 11.51 -> 10.38 | 1.8 -> 1.8 | 1.83 -> 1.59 | 1963 -> 1107 | 703 -> 711 | 197.8 | 799 |
| dev_arena | low | 2.77 -> 2.1 | 8.58 -> 6.51 | 3.1 -> 3.1 | 0.4 -> 0.3 | 291 -> 211 | 124 -> 47 | 60.7 | 716 |
| dev_arena | medium | 4.63 -> 4.12 | 10.63 -> 8.18 | 2.3 -> 2 | 0.96 -> 0.92 | 431 -> 370 | 245 -> 162 | 77.5 | 716 |
| dev_arena | high | 3.46 -> 3.39 | 8.22 -> 7.1 | 2.4 -> 2.1 | 0.67 -> 0.74 | 482 -> 443 | 268 -> 245 | 110.3 | 721 |
| floor_is_lava | low | 2.88 -> 2.46 | 8.34 -> 7.56 | 2.9 -> 3.1 | 0.53 -> 0.44 | 309 -> 269 | 167 -> 112 | 61.8 | 726 |
| floor_is_lava | medium | 3.98 -> 3.89 | 8.84 -> 10.18 | 2.2 -> 2.6 | 0.95 -> 0.88 | 493 -> 530 | 310 -> 289 | 78.7 | 728 |
| floor_is_lava | high | 3.32 -> 3.7 | 8.95 -> 12.21 | 2.7 -> 3.3 | 1.11 -> 1.11 | 568 -> 479 | 375 -> 335 | 111.4 | 734 |
| bumper_sumo | low | 3.49 -> 3.18 | 8.47 -> 7.75 | 2.4 -> 2.4 | 0.5 -> 0.5 | 384 -> 340 | 186 -> 119 | 61.2 | 722 |
| bumper_sumo | medium | 5.54 -> 3.32 | 9.71 -> 8.45 | 1.8 -> 2.5 | 1.29 -> 0.67 | 597 -> 495 | 349 -> 284 | 79.1 | 723 |
| bumper_sumo | high | 4.22 -> 4.25 | 10.0 -> 10.13 | 2.4 -> 2.4 | 1.03 -> 0.83 | 784 -> 655 | 479 -> 376 | 111.8 | 724 |
| hot_potato | low | 3.86 -> 5.17 | 9.31 -> 10.01 | 2.4 -> 1.9 | 0.69 -> 0.68 | 369 -> 343 | 169 -> 122 | 62.2 | 725 |
| hot_potato | medium | 6.07 -> 4.08 | 10.4 -> 8.84 | 1.7 -> 2.2 | 1.05 -> 0.89 | 712 -> 690 | 394 -> 361 | 79.1 | 727 |
| hot_potato | high | 4.71 -> 4.19 | 9.45 -> 9.9 | 2 -> 2.4 | 1.07 -> 0.96 | 798 -> 663 | 445 -> 379 | 111.8 | 731 |
| coin_scramble | low | 3.71 -> 4.97 | 10.15 -> 10.5 | 2.7 -> 2.1 | 0.47 -> 1.0 | 415 -> 361 | 159 -> 88 | 65.1 | 721 |
| coin_scramble | medium | 4.42 -> 4.52 | 11.37 -> 9.58 | 2.6 -> 2.1 | 0.72 -> 0.77 | 641 -> 611 | 310 -> 215 | 82.0 | 726 |
| coin_scramble | high | 4.78 -> 4.44 | 11.09 -> 11.47 | 2.3 -> 2.6 | 0.97 -> 0.93 | 673 -> 569 | 332 -> 282 | 114.7 | 729 |
| cannon_alley | low | 3.82 -> 3.63 | 10.74 -> 9.4 | 2.8 -> 2.6 | 0.65 -> 0.55 | 431 -> 369 | 277 -> 207 | 61.7 | 729 |
| cannon_alley | medium | 5.73 -> 5.7 | 16.22 -> 11.37 | 2.8 -> 2 | 1.04 -> 1.25 | 635 -> 600 | 555 -> 470 | 78.6 | 730 |
| cannon_alley | high | 5.71 -> 4.95 | 16.72 -> 11.09 | 2.9 -> 2.2 | 1.31 -> 1.18 | 813 -> 660 | 655 -> 584 | 111.3 | 738 |
| paint_splat | low | 3.72 -> 3.07 | 8.63 -> 8.17 | 2.3 -> 2.7 | 0.51 -> 0.47 | 400 -> 355 | 185 -> 115 | 61.0 | 734 |
| paint_splat | medium | 5.37 -> 6.11 | 9.72 -> 12.76 | 1.8 -> 2.1 | 1.33 -> 1.5 | 623 -> 616 | 341 -> 231 | 77.9 | 735 |
| paint_splat | high | 5.89 -> 6.11 | 14.15 -> 10.39 | 2.4 -> 1.7 | 1.32 -> 1.25 | 733 -> 681 | 373 -> 334 | 110.7 | 739 |
| spotlight_chairs | low | 4.78 -> 4.62 | 19.82 -> 12.03 | 4.1 -> 2.6 | 0.8 -> 0.77 | 526 -> 502 | 211 -> 161 | 63.4 | 719 |
| spotlight_chairs | medium | 6.51 -> 7.09 | 21.88 -> 25.92 | 3.4 -> 3.7 | 1.32 -> 1.79 | 962 -> 930 | 463 -> 352 | 80.3 | 732 |
| spotlight_chairs | high | 7.56 -> 7.71 | 23.93 -> 30.95 | 3.2 -> 4 | 1.67 -> 1.53 | 999 -> 912 | 475 -> 424 | 113.1 | 731 |
| crown_keeper | low | 5.35 -> 5.07 | 16.43 -> 10.05 | 3.1 -> 2 | 1.24 -> 0.7 | 519 -> 460 | 213 -> 143 | 62.0 | 735 |
| crown_keeper | medium | 6.06 -> 5.63 | 17.67 -> 11.5 | 2.9 -> 2 | 1.18 -> 1.16 | 838 -> 757 | 420 -> 283 | 78.9 | 735 |
| crown_keeper | high | 6.25 -> 6.87 | 13.39 -> 14.0 | 2.1 -> 2 | 1.45 -> 1.52 | 879 -> 782 | 447 -> 399 | 111.6 | 738 |
| mansion_dash | low | 5.99 -> 4.55 | 15.89 -> 11.88 | 2.7 -> 2.6 | 1.06 -> 0.62 | 330 -> 232 | 108 -> 115 | 68.5 | 749 |
| mansion_dash | medium | 6.08 -> 7.34 | 15.01 -> 14.62 | 2.5 -> 2 | 1.19 -> 1.33 | 616 -> 542 | 239 -> 302 | 86.8 | 747 |
| mansion_dash | high | 7.8 -> 6.85 | 18.21 -> 15.08 | 2.3 -> 2.2 | 1.49 -> 1.22 | 726 -> 522 | 289 -> 391 | 119.6 | 754 |
| blob_ball | low | 4.34 -> 3.46 | 10.0 -> 9.48 | 2.3 -> 2.7 | 0.51 -> 0.48 | 380 -> 330 | 143 -> 72 | 69.7 | 734 |
| blob_ball | medium | 4.56 -> 4.9 | 11.52 -> 9.28 | 2.5 -> 1.9 | 0.78 -> 0.83 | 582 -> 510 | 277 -> 138 | 86.9 | 730 |
| blob_ball | high | 5.13 -> 5.57 | 10.29 -> 10.59 | 2 -> 1.9 | 1.14 -> 1.13 | 579 -> 488 | 284 -> 236 | 119.6 | 738 |
| statue_garden | low | 6.07 -> 5.53 | 13.99 -> 18.03 | 2.3 -> 3.3 | 1.08 -> 0.8 | 390 -> 301 | 163 -> 124 | 66.5 | 726 |
| statue_garden | medium | 7.4 -> 5.84 | 16.78 -> 13.68 | 2.3 -> 2.3 | 1.33 -> 0.93 | 670 -> 504 | 366 -> 257 | 83.4 | 730 |
| statue_garden | high | 5.87 -> 5.0 | 15.76 -> 14.31 | 2.7 -> 2.9 | 1.09 -> 1.14 | 739 -> 513 | 407 -> 360 | 116.1 | 733 |
| masquerade | low | 9.75 -> 9.24 | 30.13 -> 26.43 | 3.1 -> 2.9 | 1.65 -> 1.54 | 364 -> 331 | 455 -> 217 | 63.4 | 729 |
| masquerade | medium | 9.84 -> 9.2 | 37.17 -> 26.56 | 3.8 -> 2.9 | 1.76 -> 1.58 | 716 -> 683 | 876 -> 399 | 80.2 | 740 |
| masquerade | high | 16.0 -> 14.99 | 59.47 -> 42.3 | 3.7 -> 2.8 | 3.66 -> 3.37 | 702 -> 634 | 888 -> 737 | 113.0 | 738 |
| hide_and_sneak | low | 5.33 -> 2.53 | 11.86 -> 7.26 | 2.2 -> 2.9 | 0.72 -> 0.44 | 483 -> 225 | 230 -> 221 | 64.9 | 726 |
| hide_and_sneak | medium | 4.62 -> 3.04 | 10.2 -> 8.36 | 2.2 -> 2.8 | 0.96 -> 0.71 | 976 -> 444 | 484 -> 440 | 81.8 | 728 |
| hide_and_sneak | high | 5.07 -> 3.61 | 9.84 -> 8.47 | 1.9 -> 2.3 | 1.13 -> 0.94 | 1027 -> 450 | 493 -> 558 | 114.5 | 727 |
| portrait_panic | low | 4.7 -> 3.73 | 14.51 -> 14.72 | 3.1 -> 3.9 | 0.57 -> 0.48 | 502 -> 449 | 162 -> 97 | 76.1 | 756 |
| portrait_panic | medium | 7.86 -> 7.57 | 17.96 -> 16.46 | 2.3 -> 2.2 | 1.58 -> 1.4 | 866 -> 856 | 322 -> 254 | 91.9 | 744 |
| portrait_panic | high | 4.65 -> 6.42 | 13.78 -> 19.92 | 3 -> 3.1 | 0.92 -> 1.21 | 1067 -> 921 | 374 -> 303 | 125.7 | 762 |
| ghost_tag | low | 5.89 -> 4.47 | 23.43 -> 21.05 | 4 -> 4.7 | 0.62 -> 0.59 | 409 -> 342 | 142 -> 81 | 61.2 | 742 |
| ghost_tag | medium | 5.3 -> 5.68 | 17.39 -> 14.67 | 3.3 -> 2.6 | 1.03 -> 1.04 | 575 -> 621 | 207 -> 200 | 78.0 | 733 |
| ghost_tag | high | 6.87 -> 7.2 | 24.81 -> 21.73 | 3.6 -> 3 | 1.27 -> 1.34 | 751 -> 656 | 307 -> 293 | 110.8 | 744 |
| snowball_fight | low | 5.33 -> 4.28 | 15.75 -> 12.65 | 3 -> 3 | 0.96 -> 0.55 | 441 -> 390 | 228 -> 160 | 61.8 | 743 |
| snowball_fight | medium | 6.51 -> 5.74 | 18.49 -> 14.09 | 2.8 -> 2.5 | 1.04 -> 1.01 | 693 -> 668 | 460 -> 360 | 78.6 | 744 |
| snowball_fight | high | 5.91 -> 6.08 | 14.64 -> 15.95 | 2.5 -> 2.6 | 1.22 -> 1.19 | 767 -> 677 | 505 -> 453 | 111.4 | 752 |
| rising_tide | low | 6.57 -> 7.46 | 18.67 -> 29.32 | 2.8 -> 3.9 | 0.83 -> 0.78 | 511 -> 378 | 277 -> 202 | 66.5 | 754 |
| rising_tide | medium | 9.17 -> 9.62 | 28.15 -> 66.78 | 3.1 -> 6.9 | 1.18 -> 1.19 | 777 -> 605 | 488 -> 523 | 84.8 | 774 |
| rising_tide | high | 10.87 -> 8.57 | 35.71 -> 23.91 | 3.3 -> 2.8 | 1.41 -> 1.48 | 868 -> 648 | 537 -> 586 | 117.5 | 794 |

### Budgets at LOW (8 players)

| budget | result |
|---|---|
| draw calls <= 600 per minigame, lobby <= 900 | **met** everywhere: minigames 225-502 (was 309-526), lobby 942 -> 643, vote 758 -> 484, title 681 -> 448 |
| GPU <= 0.9 ms (this GPU) | met by every minigame but **Masquerade (1.54)**; **lobby 1.44** and **vote 1.6** (the vote cards over the lobby) still over (lobby was 1.92). Coin Scramble's 1.0 is one noisy run (0.47 before, nothing changed there but the blob LOD) |
| 1 % low <= 2.5 x average | **not met** in 12 of 21 scenes. Not a rendering problem: see "1 % lows" |

### What changed (LOW gains from the table unless noted)

1. **StaticMerge** (`game/look/static_merge.gd`): `merge(root, skip, cell)` bakes the static
   kit under a node into one mesh per material (and per `cell` metres, so culling still works);
   materials with the same name and equal properties (every kit glb imports its own "Wood") are
   shared first; the outline data (CUSTOM0) is carried and rotated, so outlines and the live
   quality switch are unchanged. `batch(root)` turns repeated pieces (same mesh, same materials,
   3+) into one MultiMesh each. Used in:
   - Lobby hall (16 m cells; tiles, rugs and the keyboard cast no sun shadow): 942 -> 643 draws
     LOW, 2023 -> 1238 HIGH; GPU 1.92 -> 1.44 LOW, 3.87 -> 2.17 HIGH. The title hall and the
     vote screen share it: title 681 -> 448, vote 758 -> 484 draws.
   - Hide and Sneak room shell (furniture was already MultiMesh): 483 -> 225 draws LOW,
     1027 -> 450 HIGH, GPU 0.72 -> 0.44.
   - Mansion Dash (hedge blocks, borders, bumpers, plants, wall kit as MultiMesh): 330 -> 232
     LOW, 726 -> 522 HIGH (the known 757), GPU 1.06 -> 0.62 LOW.
   - Statue Garden (hedges, topiaries, urns batched, the rest merged; lawn strips no shadow):
     390 -> 301 LOW, 739 -> 513 HIGH, GPU 1.08 -> 0.80.
   - Rising Tide (crates, shelves, wall storeys, pillars, torches batched, rest merged per 8 m):
     511 -> 378 LOW, 868 -> 648 HIGH.
   Trade-off: merged meshes lose Godot's per-piece auto-LOD and some shadow-split culling, so
   triangles rise at MEDIUM/HIGH in the lobby/title (+5-40 %) while draws and GPU time fall.
2. **Blob LOD mesh** (`art/scripts/character/blob_lod.py` -> `blob_lod.glb`, decimated from the
   real blob.py build: 6168 -> 2596 triangles, same parts, origins, sockets and material slots;
   body 1916 -> 574, the face parts keep 50-60 %). `BlobRig.lod_mesh(part)` carries blob.glb's
   materials, so tints, toon, outline and the hit flash carry over. `VisualsComponent` swaps it
   in below HIGH for NPC extras always and for blobs further than 14 m (LOW) / 20 m (MEDIUM)
   from the camera (`is_lod()`). Masquerade (28 blobs): 455k -> 217k triangles LOW, 876k -> 399k
   MEDIUM; every minigame loses 20-50 % of its triangles at LOW. Side by side:
   `build\screenshots\extras_face_sbs.png` (LOW LOD vs HIGH full, 4x crop): same silhouette, the
   face reads.
3. **Blob shadow LOD**: the face parts (eyes, pupils, lids, mouth, cheeks) cast no sun shadow
   (they sit on the body; ~13 of a blob's ~22 surfaces fewer in every shadow split).
4. **Animation LOD at LOW** (`visuals.gd`): extras and blobs beyond 14 m pose every other frame
   (staggered by slot; the body still follows every frame). **BlobShadow** skips its ray cast
   while the body stands on the floor (28 rays per tick in Masquerade before).
5. **Fewer real lights at LOW**: Hot Potato lights every other lantern (8 -> 4, range 6 -> 7.5 m;
   the lanterns still glow), Spotlight Chairs drops the two stage-wash spots (12 -> 10), lobby
   chandelier lights reach 8 m instead of 11 m (x1.25 energy): lobby GPU -0.15 to -0.2 ms in
   A/B pairs, the hall looks the same (`build\screenshots\sbs\lobby_low.png`).
6. **Round loads** (`Look.prepare_outline`): the outline analysis ran once per *instance*
   (30 floor tiles = 30 passes) with array-keyed dictionaries; now once per mesh, cached, with
   packed arrays. Outline bake while a round loads: Mansion Dash 2.1 s -> 0.2 s, Hide and Sneak
   1.7 -> 0.4, Statue Garden 1.4 -> 0.1 (`load_probe`).
7. **Startup** (`menu_backdrop.gd`): the title opens over a flat plum backdrop; the hall builds
   after two drawn frames and fades in over 0.6 s (`build\screenshots\exe_title_f120.png`); a run
   that leaves the title within those frames (straight into a game) does not build it until the
   title shows again.

### 1 % lows: physics-tick spikes from bot thinking (not rendering)

Uncapped, a frame that runs a 60 Hz physics tick costs more than one that does not, so the
1 % low is the worst physics ticks. The breakdown columns show it for every spiky scene: in the
worst 1 % of frames the physics *scripts* take 6-30 ms while process scripts take 1.5-5 ms and
the physics server < 1 ms (LOW, after): Portrait Panic 6.9, Spotlight Chairs 6.3, Ghost Tag
11.3, Rising Tide 13.2 (60 at MEDIUM in one run: three catch-up ticks), Masquerade 18.1.
The Godot script profiler (`-d --profiling`) names them:
- **Portrait Panic** (the reported 16 ms): `ControllerComponent.physics_tick` (= `BotBrain.fill_intent`,
  called through `Object.call`, so its time shows there) up to 3.2 ms in one tick for 7 bots,
  plus `PortraitPanic.is_safe` called ~1000 times in one tick (0.9 ms), `BotBrain._most_open`,
  `_path_safe`, `_to3`. Not physics bodies, not the MultiMesh (`_update_tiles`, flips included:
  ~0.1 ms per frame).
- **Rising Tide**: bot brains again, with `RisingTide.is_safe` (rising_tide.gd:747) ~3000 calls
  per sampled frame, each walking `TideTower.pieces()` / `TideTower.piece()` (tide_tower.gd:144,
  :212; ~50 000 calls) and `Piece.covers`. Caching the piece list per section in `is_safe` (or a
  coarser safety grid) is the fix; owner: Rising Tide / bot brain.
- **Masquerade** (28 blobs): per blob per tick `Player._physics_process` (move_and_slide),
  `VisualsComponent._process`, `SizeComponent._sync` (called ~7 times per blob per frame), plus
  the 20 extras' brains. LOD 2-4 above trims visuals and shadows; the rest is gameplay code.
- Spikes coincide when many bots think on the same tick (a rethink after a phase change).
  Staggering think ticks across bots is the bot-brain agent's change, not this pass's.
On a school PC with vsync at 60 fps these spikes only show when a tick plus a frame exceed
16.7 ms: at a 2-3x slower CPU, Masquerade, Rising Tide and Ghost Tag will drop frames in busy
moments; the rest stays inside the frame.

### Loading (stage load -> first drawn frame, real session flow)

`perf-run -Transitions`: offline 8-player playlist session through all 17 minigames, the time
from the last frame before the round's stage load to the first frame drawn after it, interleaved.

| minigame | LOW before (s) | LOW after | HIGH before | HIGH after |
|---|---|---|---|---|
| blob_ball | 1.49 | 2.49 | 1.15 | 0.29 |
| bumper_sumo | 1.24 | 0.32 | 0.92 | 0.39 |
| cannon_alley | 4.71 | 0.93 | 2.03 | 0.35 |
| coin_scramble | 1.10 | 0.26 | 0.87 | 0.23 |
| crown_keeper | 2.39 | 0.74 | 1.58 | 0.44 |
| floor_is_lava | 1.07 | 0.42 | 0.84 | 0.36 |
| ghost_tag | 1.65 | 0.64 | 1.63 | 0.69 |
| hide_and_sneak | 2.50 | 0.85 | 2.56 | 1.17 |
| hot_potato | 1.55 | 0.34 | 1.37 | 2.67 |
| mansion_dash | 3.08 | 0.75 | 3.46 | 0.78 |
| masquerade | 2.92 | 0.39 | 1.83 | 0.31 |
| paint_splat | 1.39 | 0.42 | 1.50 | 0.30 |
| portrait_panic | 1.19 | 0.58 | 1.62 | 0.43 |
| rising_tide | 2.42 | 0.95 | 5.69 | 0.74 |
| snowball_fight | 2.15 | 0.67 | 2.53 | 0.50 |
| spotlight_chairs | 2.20 | 0.51 | 2.03 | 0.29 |
| statue_garden | 2.07 | 0.51 | 2.05 | 0.51 |

The first round of a run (Blob Ball LOW, Hot Potato HIGH above) also pays one-time loads
(round UI, shared assets): 2.1-2.8 s after vs 4.7 s before; its 0.6-1.2 s hitch right after the
first frame in the table run came from the deferred title hall building mid-round and is fixed
(re-measured: 17-28 ms). Worst frame in the 2 s after the first frame is 10-30 ms everywhere
(Masquerade was 300-540 ms: 20 extras spawning; 26-28 ms now). Everything but Hide and Sneak
at HIGH (1.17 s) is under 1.0 s after the first round. What is left per round (`load_probe`):
the resource load 0.4-0.85 s, `_ready` building the arena 0.03-0.7 s (Hide and Sneak: merge
0.33 s, `_setup` 0.3 s). A shader warm-up was not needed: no first-use hitch above 30 ms
showed after the first round (Godot 4.7's ubershaders compile pipelines in the background).
**Next-round preload (branch `preload`):** every peer loads the next round's scene on a worker
thread (`Stage.preload_minigame`) as soon as it is known: during the 0.75 s launch beat after
START, at RESULTS (the host's `_rpc_upcoming`) and at the vote result; `Stage.load_minigame`
takes it. `perf-run -Transitions`, LOW, 6 minigames, 2 runs each (ms, stage load -> first
frame's load part; machine shared with other agents):

| minigame | before | after |
|---|---|---|
| first round of the session | 1753, 2133 | 172, 862 |
| bumper_sumo | 212, 213 | 95 |
| cannon_alley | 260, 332 | 163, 129 |
| mansion_dash | 460, 501 | 181, 193 |
| crown_keeper | 329, 417 | 218, 235 |
| rising_tide | 511 | 185, 216 |
| hide_and_sneak (not first) | 750 | 682 |

Hide and Sneak's remainder is `_ready` building the arena (merge, `_setup`), not the resource
load. Not measured: frame times during RESULTS while the worker thread loads.

### Startup, memory, exe

- Release exe launch -> title drawn (6 alternating runs each, loaded machine): median **6.9 s ->
  5.2 s**, best 4.8 -> 4.7 s. Editor-binary breakdown (`startup_probe`, 3 runs each): enter tree
  + `_ready` 1.2-1.7 s -> 0.26-0.32 s; the hall then builds in the frames after the title is up
  (~0.9-1.3 s on this busy machine) and fades in. Engine + autoloads (2.9-5 s here; 2.2 s on
  an idle machine in v0.2) dominate and are not this pass's.
- RAM: peak working set 716-864 MB in every scene and level (lobby/title highest), an offline
  8-player session in the release exe 838-906 MB (base 891-895). VRAM LOW 61-110 MB, HIGH
  110-199 MB. Budget 1.5 GB: met.
- Exe: 116.0 MB (main: 115.9 MB; v0.2 was 112 MB; blob_lod.glb adds 69 KB).

### Remaining risks on integrated graphics

- Lobby (and the vote screen over it) is still the heaviest GPU scene: 1.44 ms here, ~15-30 ms
  on a UHD 620-class iGPU at 1280x720 LOW (30-60 fps). Next steps: fewer chandelier lights at
  LOW (2 of 4), a cheaper title hall (render it every other frame).
- Masquerade: 28 blobs are CPU-bound (gameplay, physics, visuals) more than GPU-bound; expect
  ~2-3x the 9 ms here on a weak CPU (30-45 fps) in busy moments.
- Bot thinking spikes (above) on weak CPUs; fewer bots helps.
- Merged meshes trade triangles for draws at MEDIUM/HIGH; on a mid GPU that is the right trade,
  but the lobby's MEDIUM triangle count rose 578k -> 620k.
- No run on real integrated graphics: the iGPU numbers are scaled estimates.

### Not verified

- No measurement on an iGPU, only proxies on an RTX 3060 Ti that other processes shared.
- Startup numbers are noisy (+-2 s per run on this busy machine); the median gain is modest.
- First-ever start (empty shader cache) not timed.
- `-Release` session RAM uses `--auto-start` in the release exe; startup timing uses
  `-- --screenshot` (honoured by release builds).

## v0.2 pass (history): results (1280x720, 8 players, ms per frame)

"before" = main at afa61ce (LOW/HIGH only), "after" = this branch. GPU ms is the measured
render time of all viewports. On this machine every scene is CPU-bound (300-600 fps); the GPU
column is the one that predicts integrated graphics. Run-to-run noise is about +-0.3 ms
(HIGH did not change; its before/after gap is noise).

| scene | level | frame before | frame after | 1% low before | 1% low after | GPU before | GPU after | draws before | draws after | tris after (k) | VRAM MB after | RAM MB after |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| title | low | 2.42 | 1.52 | 5.59 | 4.22 | 1.19 | 0.39 | 1064 | 639 | 193 | 85 | 693 |
| title | medium | - | 2.24 | - | 5.02 | - | 0.70 | - | 1154 | 320 | 114 | 683 |
| title | high | 2.61 | 2.37 | 4.73 | 4.52 | 1.64 | 1.52 | 1185 | 1186 | 342 | 191 | 695 |
| lobby | low | 4.95 | 3.57 | 10.52 | 8.35 | 1.08 | 0.78 | 1427 | 928 | 274 | 103 | 715 |
| lobby | medium | - | 5.02 | - | 11.28 | - | 1.14 | - | 1628 | 531 | 162 | 741 |
| lobby | high | 5.78 | 5.08 | 12.98 | 11.40 | 1.28 | 1.37 | 1906 | 1880 | 639 | 195 | 719 |
| dev_arena | low | 2.16 | 1.91 | 6.41 | 5.45 | 0.26 | 0.32 | 316 | 277 | 111 | 60 | 672 |
| dev_arena | medium | - | 2.18 | - | 5.87 | - | 0.45 | - | 419 | 232 | 77 | 672 |
| dev_arena | high | 2.64 | 2.35 | 7.12 | 6.28 | 0.62 | 0.56 | 570 | 558 | 320 | 110 | 682 |
| floor_is_lava | low | 2.48 | 2.17 | 7.86 | 5.90 | 0.65 | 0.48 | 329 | 325 | 169 | 65 | 690 |
| floor_is_lava | medium | - | 2.23 | - | 7.00 | - | 0.65 | - | 516 | 335 | 81 | 690 |
| floor_is_lava | high | 2.93 | 3.01 | 8.02 | 7.19 | 1.26 | 1.12 | 529 | 597 | 391 | 114 | 693 |
| bumper_sumo | low | 2.73 | 2.25 | 7.54 | 6.26 | 0.44 | 0.41 | 406 | 396 | 190 | 61 | 679 |
| bumper_sumo | medium | - | 2.63 | - | 5.51 | - | 0.63 | - | 586 | 347 | 78 | 677 |
| bumper_sumo | high | 3.86 | 3.19 | 9.26 | 7.84 | 0.89 | 0.80 | 790 | 786 | 464 | 111 | 679 |
| hot_potato | low | 3.04 | 2.21 | 9.38 | 6.14 | 0.69 | 0.48 | 517 | 369 | 170 | 65 | 692 |
| hot_potato | medium | - | 2.82 | - | 7.12 | - | 0.73 | - | 720 | 379 | 82 | 691 |
| hot_potato | high | 3.80 | 3.15 | 8.09 | 7.69 | 1.04 | 0.93 | 907 | 869 | 476 | 115 | 696 |
| coin_scramble | low | 2.56 | 2.43 | 8.19 | 7.55 | 0.43 | 0.42 | 408 | 415 | 157 | 65 | 680 |
| coin_scramble | medium | - | 2.99 | - | 7.91 | - | 0.63 | - | 635 | 310 | 82 | 679 |
| coin_scramble | high | 3.20 | 3.02 | 8.35 | 7.69 | 0.77 | 0.77 | 652 | 649 | 321 | 114 | 683 |
| paint_splat | low | 2.86 | 2.18 | 7.98 | 6.12 | 0.57 | 0.42 | 408 | 403 | 185 | 61 | 688 |
| paint_splat | medium | - | 2.76 | - | 7.17 | - | 0.65 | - | 648 | 340 | 78 | 691 |
| paint_splat | high | 3.59 | 2.90 | 8.06 | 7.61 | 0.91 | 0.78 | 801 | 807 | 391 | 110 | 692 |
| cannon_alley | low | 2.66 | 2.38 | 6.59 | 6.14 | 0.61 | 0.50 | 427 | 421 | 277 | 61 | 691 |
| cannon_alley | medium | - | 2.87 | - | 7.94 | - | 0.72 | - | 644 | 551 | 78 | 690 |
| cannon_alley | high | 3.63 | 3.17 | 8.98 | 9.86 | 0.93 | 0.86 | 746 | 724 | 603 | 115 | 698 |
| spotlight_chairs | low | 2.75 | 2.57 | 7.87 | 7.69 | 0.64 | 0.59 | 570 | 563 | 233 | 66 | 691 |
| spotlight_chairs | medium | - | 3.40 | - | 10.11 | - | 0.90 | - | 969 | 468 | 79 | 690 |
| spotlight_chairs | high | 3.17 | 3.52 | 11.55 | 12.82 | 0.94 | 0.97 | 996 | 1019 | 487 | 116 | 697 |

What moved: LOW now costs about half the GPU time of HIGH in a round (0.4-0.6 ms vs 0.8-1.1)
and a quarter at the title (0.39 vs 1.52). The lobby was the worst scene at LOW (1427 draw
calls): its fire light cast omni (cube) shadows and 14 lights shaded every pixel; LOW is now
928 draws. Outlines double the draw calls of every toon mesh, so MEDIUM/HIGH have ~1.5-2x the
draws of LOW.

**Rough integrated-GPU estimate** (not measured on such hardware): an Intel UHD 620-class iGPU
has ~1/20-1/40 of this GPU's throughput, Iris Xe / Vega 8 ~1/8-1/15. At x20, HIGH rounds are
16-22 ms of GPU (45-60 fps) and the lobby/title 27-30 ms (~35 fps); LOW rounds 8-12 ms and the
lobby 16 ms, title 8 ms (60 fps with vsync). The CPU side scales with draw calls: Intel iGPU
drivers spend roughly 2-4 us per draw, i.e. 2-4 ms for the 930 LOW lobby draws, 4-8 ms for HIGH.

**Weak-CPU proxy**: pinning to 2 cores (`-Throttle`) changed nothing measurable (the game is
effectively single-threaded on this CPU). Per-player cost: dev arena LOW with 1 player 0.63 ms,
with 8 players 1.84 ms, so ~0.17 ms per player for physics, bot brain, procedural animation,
name tag and ~27 draw calls. On a CPU 2-3x slower per core that is ~3 ms for 8 players: no LOD
or frame-skipping in the visuals component was needed.

**Compatibility renderer**: not attempted (out of scope for this pass). `fallback_to_opengl3`
stays off; a PC without Vulkan 1.x will not start the game.

## v0.2: memory and startup

- RAM: peak working set 670-740 MB in every scene and level (private bytes 830-1040 MB), well
  under the 1.5 GB budget. Godot static memory 95-127 MB. VRAM (also system RAM on an iGPU):
  LOW 60-103 MB, HIGH 110-195 MB (title/lobby are the largest: the hall is loaded).
- Title's live hall: renders in its own SubViewport. Before: full window size with 2x MSAA,
  1.2-1.6 ms GPU, ~1060-1185 draws. Now 0.5 (LOW) / 0.67 (MEDIUM) of the 3D scale without
  MSAA: 0.39 / 0.70 ms GPU. A still image would save the rest but loses the drift; not done.
- Startup, launch to title drawn, release export (`export-windows.ps1`, `-- --screenshot` at
  frame 2): **4.05 s** (3 runs, warm shader cache). Editor binary breakdown
  (`startup_probe.tscn`): engine + Vulkan + autoloads 2.2 s (an empty Godot project takes
  1.5-2.4 s on this PC, so the autoloads add ~0.3-0.7 s), load `main.tscn` 0.9 s (menu UI 0.3 s,
  round UI 0.2 s, script compilation), enter tree + `_ready` 0.5 s (building the hall behind the
  title), first frame 25-50 ms. The 3 s target is not met. Next steps, owned by other systems:
  build the title hall (`ui/menu/menu_backdrop.gd`) after the first frame instead of in `_ready`
  (-0.5 s), load the round UI lazily on the first round (-0.2 s).

## v0.2: school-PC advice

- Windowed 1280x720 and Quality **Low** (auto-detect picks it on Intel/AMD integrated graphics).
- Keep the GPU driver current if the school allows it; Godot needs Vulkan 1.x (Intel 6th gen / Skylake or newer on Windows).
- Plug laptops in (power-saving modes halve iGPU clocks) and close the browser.
- If a round still stutters: fewer bots, and Show FPS in Settings to check.
- Medium is for mid GPUs (GTX 1050-1650, RX 470-580, Intel Arc); a fast Iris Xe may manage it too.

## v0.2: not verified

- No run on real integrated graphics: the iGPU numbers are scaled estimates.
- First-ever start (empty shader cache) was not timed; Godot 4.7 ubershaders keep it from
  blocking, but expect a few extra seconds on the first launch.
- `-Exe` runs need a debug export; release templates refuse a scene path on the command line.
