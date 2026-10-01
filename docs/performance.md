# Performance: running on weak PCs

Target: school PCs with integrated Intel/AMD graphics, 8 GB RAM, old drivers. Dev box for the
numbers below: Ryzen 5 3600, RTX 3060 Ti, Godot 4.7.2 Forward+ (Vulkan), editor binary.

## How to measure

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\perf-run.ps1 -Label after -Shots
powershell ... tools\perf-run.ps1 -Scenes lobby,bumper_sumo -Qualities low -Seconds 15 -Throttle
```

`tools/perf-run.ps1` runs the real game windowed at 1280x720 through
`res://tools/perf/perf_driver.tscn`, once per scene and quality: title (live hall behind the
menu), lobby (offline, 8 players), the dev arena and every minigame through the sandbox with
8 players (7 bots). Each run warms up (3 s, shader compiles), then measures (8-10 s) with vsync
off and no frame cap, and appends one row to `build\perf\<label>.csv`: average and 1 % low frame
time (mean of the worst 1 % of frames), renderer CPU/GPU time summed over every viewport, draw
calls, primitives, video/texture memory, static memory, engine and scene startup. A second CSV
(`<label>.mem.csv`) has the peak working set / private bytes of the game process. `-Throttle`
pins the process to 2 logical cores at below-normal priority (weak-CPU proxy); `-Shots` saves a
PNG per run; ERROR / SHADER ERROR lines go to `build\perf\<label>_errors.log`.
`res://tools/perf/startup_probe.tscn` prints a startup breakdown (see below).

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
| Lobby lights | fire (no shadow), 4 chandeliers, portal; candelabras and moonbeams glow only | all 14, fire casts shadows | all |
| Title's hall (SubViewport) | 0.5 scale (0.75 x 0.67) | 0.67 scale | full, 2x MSAA |

LOW still looks like the same game: same palette, toon ramp, rim light, sun shadows and blob
shadows, just no ink lines, bloom or contact shading and a slightly softer image. Side by side:
`build\screenshots\showcase_sbs.png` (look showcase), `showcase_crop_sbs.png` (close-up),
`sumo_sbs.png` (Bumper Sumo, 8 players), `lobby_sbs.png` (lobby), `title_sbs.png` (title LOW vs HIGH),
`build\perf\shots\after_<scene>_<level>.png` (every scene). A hard (blur 0) LOW shadow left acne
rings on round shapes at 1024 texels; blur 1.0 with the very-low filter removes them.

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

## Results (1280x720, 8 players, ms per frame)

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

## Memory and startup

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

## School-PC advice

- Windowed 1280x720 and Quality **Low** (auto-detect picks it on Intel/AMD integrated graphics).
- Keep the GPU driver current if the school allows it; Godot needs Vulkan 1.x (Intel 6th gen / Skylake or newer on Windows).
- Plug laptops in (power-saving modes halve iGPU clocks) and close the browser.
- If a round still stutters: fewer bots, and Show FPS in Settings to check.
- Medium is for mid GPUs (GTX 1050-1650, RX 470-580, Intel Arc); a fast Iris Xe may manage it too.

## Not verified

- No run on real integrated graphics: the iGPU numbers are scaled estimates.
- First-ever start (empty shader cache) was not timed; Godot 4.7 ubershaders keep it from
  blocking, but expect a few extra seconds on the first launch.
- `-Exe` runs need a debug export; release templates refuse a scene path on the command line.
