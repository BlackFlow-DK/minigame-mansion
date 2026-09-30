# Godot game repo: agent guide

Tooling only: Godot 4.7.2 (GDScript, Forward+) + Blender 5.2.1. Everything runs from the CLI; never open the editor/GUI.
Run tools from anywhere; they resolve paths from the repo root. Never hardcode absolute paths in project files.

## Executables (override with env vars)
- Godot: `GODOT_BIN`, else `%LOCALAPPDATA%\Microsoft\WinGet\Links\godot_console.exe`, else PATH. Use the `_console` variant (it prints to stdout).
- Blender: `BLENDER_BIN`, else `C:\Program Files\Blender Foundation\Blender 5.2\blender.exe`, else PATH.
- Export templates: `%APPDATA%\Godot\export_templates\4.7.2.stable\` (installed).

## Tools (PowerShell 5.1; all exit non-zero on failure)
Call as `powershell -NoProfile -ExecutionPolicy Bypass -File tools\<name>.ps1 ...`
- `blender-run.ps1 art\scripts\x.py [args]` runs a Blender script headless (`--factory-startup --python-exit-code 1`). Fails if the script raises.
- `godot-import.ps1` headless import. Run after adding/changing any asset (.glb, textures, audio).
- `godot-check.ps1` parses every `.gd` and loads every `.tscn/.scn` (via `game/tools/check_project.gd`). Catches parse, type and undefined-identifier errors and broken scene references. Imports first if `.godot/` is missing.
- `godot-screenshot.ps1 [-Scene res://scenes/x.tscn] [-Out build\screenshots\x.png] [-Frames 60] [-Resolution 1280x720] [-TimeoutSec 60]` runs the game in a real window, saves the viewport PNG after N frames, quits. Default scene: main scene; default out: `build\screenshots\<scene>.png`. Fails on timeout, missing PNG, or any `SCRIPT ERROR`/`ERROR` line.
- `export-windows.ps1 [-DebugBuild]` exports `build\windows\<repo-folder>.exe` (PCK embedded, single file, ~105 MB).
- Single script check without the wrapper: `godot_console --headless --path game --check-only --script res://path.gd`.

## Done means
Before reporting any change as done: `godot-import` (if assets changed) -> `godot-check` -> `godot-screenshot`, then Read the PNG and confirm with your own eyes that the change is visible and correct. Report the PNG path.

## Layout
- `game/` Godot project root (`res://`). `scenes/` .tscn, `scripts/` gameplay .gd, `assets/models/` .glb from Blender, `tools/` agent helpers (do not delete: `screenshot.gd` is an autoload, inert without `--screenshot=`).
- `art/scripts/` Blender Python generators, one script per asset (or family), using `artlib.py`. `art/blend/` optional hand-made .blend sources.
- `tools/` PowerShell wrappers. `build/` exports + screenshots (gitignored).

## Asset conventions
- Units metres, real-world scale. Author in Blender Z-up; exporter writes glTF +Y up (Godot's up).
- Model front faces Blender -Y, which lands on Godot +Z (`Vector3.MODEL_FRONT`).
- Origin at the base centre (object stands on y=0 in Godot). Build around the world origin with the bottom at z=0, then `artlib.join()` applies all transforms.
- Names: snake_case files (`test_prop.py` -> `game/assets/models/test_prop.glb`); PascalCase object/material names.
- Export only through `artlib.export_glb(name)`: GLB, +Y up, apply modifiers, materials on, no cameras/lights, whole scene.
- Colours: `artlib.material(name, "#rrggbb")` takes sRGB hex and converts to linear for Principled BSDF. Base colour, roughness, metallic survive to Godot; flat colours need no textures.
- Commit the `.glb` AND its `.glb.import`, plus Godot's `*.gd.uid` files. Never commit `.godot/` or `build/`.
- Regenerate a model: `blender-run` -> `godot-import`. Instance a .glb in a scene as a PackedScene (`instance=ExtResource(...)`).

## Gotchas (hit while setting this up)
- Blender exits 0 when a `--python` script raises unless `--python-exit-code 1` (the wrapper sets it).
- Blender 5.x: materials always have a node tree (`use_nodes` is deprecated, do not set it); `Principled BSDF` exists by default.
- Godot colours its output with ANSI codes even when redirected; the wrappers strip them before matching `ERROR`.
- `--headless` uses a dummy renderer: it cannot screenshot. The screenshot tool opens a real window briefly.
- Loading the currently running `--script` file with `CACHE_MODE_IGNORE` segfaults Godot 4.7.2 (check_project.gd skips itself).
- Exported release builds also honour `-- --screenshot=<png>` (handy to verify an export actually renders).
- Hand-written .tscn: omit `uid=` and `load_steps`; Godot accepts it. `rotation`/`position` can be set directly instead of a `transform`.
- Export preset sets `application/modify_resources=false` (no rcedit, so no custom exe icon/metadata).
