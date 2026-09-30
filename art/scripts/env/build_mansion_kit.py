"""Builds the mansion hall kit: one .glb per piece into game/assets/models/env/.

Run: tools\\blender-run.ps1 art\\scripts\\env\\build_mansion_kit.py [-- piece_name ...]   (no names = everything)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import artlib  # noqa: E402
import architecture  # noqa: E402
import furniture  # noqa: E402
import decor  # noqa: E402
from kit import stats  # noqa: E402

PIECES = {}
for mod in (architecture, furniture, decor):
    PIECES.update(mod.PIECES)


def main():
    wanted = artlib.script_args() or list(PIECES)
    report = []
    for name in wanted:
        artlib.reset_scene()
        objs = PIECES[name]()
        tris, mn, mx, mats = stats(objs)
        artlib.export_glb(name, family="env")
        report.append((name, tris, mn, mx, mats))
    print("PIECE | tris | min xyz | max xyz | size (w x d x h) | materials")
    for name, tris, mn, mx, mats in report:
        sz = mx - mn
        print(f"PIECE {name} | {tris} | {mn.x:.2f},{mn.y:.2f},{mn.z:.2f} | {mx.x:.2f},{mx.y:.2f},{mx.z:.2f} | "
              f"{sz.x:.2f} x {sz.y:.2f} x {sz.z:.2f} | {','.join(mats)}")


main()
