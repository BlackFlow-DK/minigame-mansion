# Minigame Mansion: agent guide

Tooling only: Godot 4.7.2 (GDScript, Forward+) + Blender 5.2.1. Everything runs from the CLI; never open the editor/GUI.
Run tools from anywhere; they resolve paths from their own repo/worktree root. Never hardcode absolute paths in project files.

**Interfaces: `docs/contract.md`.** Build against it; do not invent cross-system APIs. Design: `docs/superpowers/specs/`.

## Worktrees (every system agent)
- One agent = one branch = one worktree. Never work in the main checkout, never touch `main` or another worktree, never merge.
- Setup: `git -C C:\Users\Sander\games\minigame-mansion worktree add C:\Users\Sander\games\mm-wt\<branch> -b <branch> main`, then run every tool from inside `C:\Users\Sander\games\mm-wt\<branch>` (`powershell ... -File tools\godot-check.ps1` there). The first check/test imports automatically (`.godot/` is per worktree).
- Commit on your branch. Edit only the files your brief names.

## Orchestrator-owned files (report needed changes, do not edit)
`game/project.godot`, `game/player/player.tscn`, `game/player/player.gd`, `game/player/player_component.gd`, `game/player/player_intent.gd`, `game/minigames/minigame.gd`, `game/minigames/registry.gd`, `game/stage/`, `game/dev/`, `game/tests/harness.gd`, `game/tests/run_tests.gd`, `game/tests/test_skeleton.gd`, `game/tools/`, `art/scripts/artlib.py`, `tools/`, `CLAUDE.md`, `docs/`.

## Executables (override with env vars)
- Godot: `GODOT_BIN`, else `%LOCALAPPDATA%\Microsoft\WinGet\Links\godot_console.exe`, else PATH. Use the `_console` variant (it prints to stdout).
- Blender: `BLENDER_BIN`, else `C:\Program Files\Blender Foundation\Blender 5.2\blender.exe`, else PATH.
- Export templates: `%APPDATA%\Godot\export_templates\4.7.2.stable\` (installed).

## Tools (PowerShell 5.1; all exit non-zero on failure)
Call as `powershell -NoProfile -ExecutionPolicy Bypass -File tools\<name>.ps1 ...`
- `blender-run.ps1 art\scripts\x.py [args]` runs a Blender script headless (`--factory-startup --python-exit-code 1`). Fails if the script raises.
- `godot-import.ps1` headless import. Run after adding/changing any asset (.glb, textures, audio) or a new `class_name`.
- `godot-check.ps1` parses every `.gd` and loads every `.tscn/.scn` (via `game/tools/check_project.gd`). Catches parse, type and undefined-identifier errors and broken scene references. Imports first if `.godot/` is missing.
- `godot-test.ps1 [-Filter text]` runs `game/tests/test_*.gd` headless at fixed 60 ticks/s; one line per test (`PASS/FAIL <file>::<test>`). Fails on a failed assert, any script/engine error or push_error, a timeout, or nothing run. Harness API: `docs/contract.md` "Tests".
- `godot-screenshot.ps1 [-Scene res://x.tscn] [-Out build\screenshots\x.png] [-Frames 60] [-Resolution 1280x720] [-TimeoutSec 60] [-GameArgs "--minigame=bumper_sumo --players=8"]` runs the game in a real window, saves the viewport PNG after N frames, quits. Default scene: main scene (the sandbox). Fails on timeout, missing PNG, or any `SCRIPT ERROR`/`ERROR` line.
- `export-windows.ps1 [-DebugBuild]` exports `build\windows\<repo-folder>.exe` (PCK embedded, single file, ~105 MB).
- Single script check without the wrapper: `godot_console --headless --path game --check-only --script res://path.gd`.

## Done means
`godot-import` (if assets or class names changed) -> `godot-check` -> `godot-test` -> `godot-screenshot` if visible, then Read the PNG and confirm with your own eyes. Report the PNG path.

## Layout
- `game/` Godot project root (`res://`). Per-system folders as in `docs/contract.md` "File ownership". `dev/sandbox.tscn` is the main scene for now: offline, you + bots, `-- --players=N --minigame=<id>`. `tools/` agent helpers (`screenshot.gd` is an autoload, inert without `--screenshot=`).
- `art/scripts/<family>/` Blender Python generators using `artlib.py`; `art/blend/` optional hand-made .blend sources.
- `tools/` PowerShell wrappers. `build/` exports + screenshots (gitignored).

## Asset conventions
- Units metres, real-world scale. Author in Blender Z-up; exporter writes glTF +Y up (Godot's up). Godot (x, y, z) = Blender (x, -z, y): `artlib.from_godot()`.
- Model front faces Blender -Y, which lands on Godot +Z (`Vector3.MODEL_FRONT`).
- Origin at the base centre (object stands on y=0 in Godot). Single-mesh props: build around the world origin, bottom at z=0, then `artlib.join()`.
- Multi-part models (character, cosmetics): keep parts separate with `artlib.finalize(obj, "Name")` (origin stays where the primitive was added), sockets with `artlib.empty("HatSocket", loc)`, hierarchy with `artlib.set_parent()`. Object names become Godot node names.
- Family scripts live in `art/scripts/<family>/` and import artlib with `sys.path.insert(0, str(Path(__file__).resolve().parents[1]))`.
- Export only through `artlib.export_glb(name, family="<family>")` -> `game/assets/models/<family>/<name>.glb`: GLB, +Y up, apply modifiers, materials on, no cameras/lights, whole scene.
- Colours: `artlib.material(name, "#rrggbb")` takes sRGB hex and converts to linear for Principled BSDF. Base colour, roughness, metallic survive to Godot; flat colours need no textures.
- Commit the `.glb` AND its `.glb.import`, plus Godot's `*.gd.uid` files. Never commit `.godot/` or `build/`.
- Regenerate a model: `blender-run` -> `godot-import`. Instance a .glb in a scene as a PackedScene (`instance=ExtResource(...)`).

## Gotchas (hit while setting this up)
- Blender exits 0 when a `--python` script raises unless `--python-exit-code 1` (the wrapper sets it).
- Blender 5.x: materials always have a node tree (`use_nodes` is deprecated, do not set it); `Principled BSDF` exists by default.
- Godot colours its output with ANSI codes even when redirected; the wrappers strip them before matching `ERROR`.
- `--headless` uses a dummy renderer: it cannot screenshot. The screenshot tool opens a real window briefly.
- Loading the currently running `--script` file with `CACHE_MODE_IGNORE` segfaults Godot 4.7.2 (check_project.gd skips itself).
- A `--script` main loop (run_tests.gd, check_project.gd) and every script it references statically compile before autoloads exist: autoload names there are "Identifier not found". Load such scripts dynamically (`load()` at runtime).
- A runtime error aborts only the current function; an awaiting caller resumes with null. Tests guard against this; your code should too.
- Exported release builds also honour `-- --screenshot=<png>` (handy to verify an export actually renders).
- Hand-written .tscn: omit `uid=` and `load_steps`; Godot accepts it. `rotation`/`position` can be set directly instead of a `transform`.
- Export preset sets `application/modify_resources=false` (no rcedit, so no custom exe icon/metadata).
