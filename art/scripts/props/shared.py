"""Shared props: spawn_pad, arrow_marker.

Run: tools/blender-run.ps1 art/scripts/props/shared.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib


def spawn_pad():
    """0.9 m disc a player stands on. Ring material `PlayerPrimary` is recoloured per player. Origin base centre."""
    new_piece()
    ch, cream = M("charcoal", 0.85), M("cream", 0.9)
    prim = M("stone", 0.6, name="PlayerPrimary", hexv="#3f7fd9")
    b = Builder("spawn_pad", angle=40)
    prof, _ = rrect(0, 0.45, 0, 0.06, 0.02, 0.015, 2)
    b.lathe(prof, ch, segs=32)
    prof, _ = rrect(0.29, 0.4, 0.045, 0.095, 0.02, 0.0, 2)
    b.lathe(prof, prim, segs=32, closed=True)
    prof, _ = rrect(0, 0.245, 0.05, 0.078, 0.014, 0.0, 2)
    b.lathe(prof, cream, segs=32)
    # four small pips on the ring so it reads as a target
    for i in range(4):
        a = math.pi / 2 * i + math.pi / 4
        b.sphere(0.034, (0.345 * math.cos(a), 0.345 * math.sin(a), 0.1), ch, segs=6, rings=4, scale=(1, 1, 0.6))
    ob = b.build()
    return finish("spawn_pad", [ob])


def arrow_marker():
    """Floating down-pointing arrow, ~0.3 m tall, origin at its centre. Emissive gold."""
    new_piece()
    arrow = EM("EmitArrow", "#ffb81f", 0.8)
    b = Builder("arrow_marker", angle=40)
    b.lathe([(0, 0.02), (0.07, 0.02), (0.075, 0.16), (0.0, 0.16)], arrow, segs=14)
    b.lathe([(0, -0.15), (0.03, -0.12), (0.17, 0.03), (0.17, 0.05), (0.0, 0.05)], arrow, segs=14)
    ob = b.build()
    return finish("arrow_marker", [ob])


ALL = [spawn_pad, arrow_marker]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
