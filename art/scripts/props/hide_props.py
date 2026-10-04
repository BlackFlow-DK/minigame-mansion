"""Hide and Sneak disguise props (blob-sized parlour furniture the kit lacks).

hide_clock: a stubby longcase clock, 0.62 m wide (x -0.31..0.31), 0.42 m deep, 1.46 m tall; dial on the
  front (Godot +Z). Origin base centre.
hide_vase: a porcelain vase on a marble pedestal, 0.5 m square base, 1.42 m tall. Origin base centre.
Run: tools/blender-run.ps1 art/scripts/props/hide_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

HALF_PI = math.pi / 2


def hide_clock():
    new_piece()
    dark = M("dark_wood", 0.7)
    wood = M("wood", 0.65)
    gold = M("gold", 0.3, 0.45, name="ClockGold", hexv="#e8b33a")
    cream = M("cream", 0.6, name="ClockFace", hexv="#f6ecd2")
    ink = M("charcoal", 0.6)
    b = Builder("hide_clock", angle=40)
    # plinth, trunk, hood
    b.box((0.62, 0.42, 0.2), (0, 0, 0.1), dark, bevel=0.02)
    b.box((0.66, 0.46, 0.03), (0, 0, 0.215), gold, bevel=0.008)
    b.box((0.5, 0.34, 0.78), (0, 0, 0.62), wood, bevel=0.02)
    b.box((0.26, 0.02, 0.5), (0, -0.172, 0.62), ink, bevel=0.005)
    b.box((0.012, 0.012, 0.36), (0, -0.18, 0.66), gold)
    b.cyl(0.065, 0.02, (0, -0.172, 0.46), gold, segs=14, rot=(HALF_PI, 0, 0))
    b.box((0.6, 0.42, 0.04), (0, 0, 1.03), gold, bevel=0.01)
    b.box((0.58, 0.4, 0.36), (0, 0, 1.23), dark, bevel=0.025)
    # arched crest with a finial
    b.cyl(0.2, 0.36, (0, 0.18, 1.41), wood, segs=20, rot=(HALF_PI, 0, 0))
    b.box((0.62, 0.42, 0.03), (0, 0, 1.425), gold, bevel=0.008)
    b.sphere(0.045, (0, 0, 1.48), gold, segs=10, rings=6)
    # dial with a gold ring and hands
    b.cyl(0.155, 0.025, (0, -0.2, 1.23), cream, segs=24, rot=(HALF_PI, 0, 0))
    ring = [(0.15, -0.012), (0.18, -0.012), (0.18, 0.012), (0.15, 0.012)]
    b.lathe(ring, gold, segs=24, closed=True, loc=(0, -0.225, 1.23), rot=(HALF_PI, 0, 0))
    b.box((0.018, 0.01, 0.11), (0, -0.23, 1.27), ink)
    b.box((0.08, 0.01, 0.018), (0.035, -0.23, 1.23), ink)
    for a in range(0, 360, 90):
        x, z = 0.12 * math.cos(math.radians(a)), 1.23 + 0.12 * math.sin(math.radians(a))
        b.sphere(0.012, (x, -0.226, z), ink, segs=6, rings=4)
    ob = b.build()
    return finish("hide_clock", [ob])


def hide_vase():
    new_piece()
    marble = M("cream", 0.5, name="Marble", hexv="#e6ded0")
    vein = M("stone", 0.55, name="MarbleDark", hexv="#b9ae9c")
    porcelain = M("blue", 0.35, name="Porcelain", hexv="#3f6fbf")
    glaze = M("cream", 0.3, name="Glaze", hexv="#f4f0e6")
    gold = M("gold", 0.3, 0.45, name="VaseGold", hexv="#e8b33a")
    b = Builder("hide_vase", angle=40)
    # pedestal: square foot, fluted-looking column, square cap
    b.box((0.5, 0.5, 0.1), (0, 0, 0.05), vein, bevel=0.015)
    b.box((0.42, 0.42, 0.06), (0, 0, 0.13), marble, bevel=0.012)
    col = [(0.0, 0.16), (0.17, 0.16), (0.15, 0.24), (0.14, 0.62), (0.16, 0.7), (0.0, 0.7)]
    b.lathe(col, marble, segs=16)
    b.box((0.44, 0.44, 0.05), (0, 0, 0.725), vein, bevel=0.012)
    b.box((0.4, 0.4, 0.04), (0, 0, 0.77), marble, bevel=0.01)
    # the vase: white foot, blue belly, white shoulder band, gold lip
    foot = [(0.0, 0.79), (0.11, 0.79), (0.12, 0.83), (0.0, 0.83)]
    b.lathe(foot, glaze, segs=20)
    belly = [(0.0, 0.83), (0.12, 0.83), (0.19, 0.9), (0.23, 1.0), (0.235, 1.07), (0.21, 1.15), (0.0, 1.15)]
    b.lathe(belly, porcelain, segs=20)
    band = [(0.0, 1.15), (0.21, 1.15), (0.17, 1.22), (0.0, 1.22)]
    b.lathe(band, glaze, segs=20)
    neck = [(0.0, 1.22), (0.17, 1.22), (0.1, 1.29), (0.09, 1.35), (0.0, 1.35)]
    b.lathe(neck, porcelain, segs=20)
    lip = [(0.0, 1.35), (0.09, 1.35), (0.13, 1.4), (0.12, 1.42), (0.0, 1.42)]
    b.lathe(lip, gold, segs=20)
    ob = b.build()
    return finish("hide_vase", [ob])


ALL = [hide_clock, hide_vase]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
