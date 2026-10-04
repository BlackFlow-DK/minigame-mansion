"""Portrait Panic props: portrait_frame_big.

portrait_frame_big: the huge gilded frame on the gallery's back wall (the minigame's big screen).
  Outer 7.4 m x 5.0 m, 0.34 m deep; origin at the bottom centre of its back (against the wall), front
  faces Godot +Z. The opening is 6.2 m x 4.0 m (Godot x -3.1..3.1, y 0.5..4.5); a dark backboard sits
  in it with its front at Godot z = 0.06, where the game puts its canvas quad. A crest on top, rosettes
  in the corners, a small plaque under the bottom edge.
Run: tools/blender-run.ps1 art/scripts/props/portrait_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

W, H = 7.4, 5.0          # outer size
IW, IH = 6.2, 4.0        # opening
CZ = H / 2               # centre height (Blender z)


def _ring(b, hw, hh, band, depth, mat, bevel=0.02, y0=0.0):
    """A rectangular ring of four boxes: outer half-size (hw, hh), `band` wide, from y0 to y0 - depth."""
    y = y0 - depth / 2
    b.box((hw * 2, depth, band), (0, y, CZ + hh - band / 2), mat, bevel=bevel)
    b.box((hw * 2, depth, band), (0, y, CZ - hh + band / 2), mat, bevel=bevel)
    side_h = hh * 2 - band * 2
    b.box((band, depth, side_h), (-hw + band / 2, y, CZ), mat, bevel=bevel)
    b.box((band, depth, side_h), (hw - band / 2, y, CZ), mat, bevel=bevel)


def portrait_frame_big():
    new_piece()
    b = Builder("portrait_frame_big", angle=35)
    gold = M("gold", 0.5, 0.2)
    gold_hi = M("gold", 0.45, 0.25, name="GoldBright", hexv="#f2c75a")
    gold_dk = M("gold", 0.6, 0.15, name="GoldDark", hexv="#a8741f")
    back = M("charcoal", 0.9, name="Backboard", hexv="#1d1622")
    plaque = M("dark_wood", 0.7)
    hw, hh = W / 2, H / 2
    band = (W - IW) / 2  # 0.6
    # backboard behind the opening (its front at y = -0.06)
    b.box((IW + 0.3, 0.06, IH + 0.3), (0, -0.03, CZ), back)
    # outer moulding: broad, shallow
    _ring(b, hw, hh, band, 0.2, gold_dk, bevel=0.05)
    # the raised ridge: the brightest, deepest part
    _ring(b, hw - 0.1, hh - 0.1, 0.3, 0.32, gold, bevel=0.07)
    # a thin bright bead along the ridge's crest
    _ring(b, hw - 0.2, hh - 0.2, 0.1, 0.36, gold_hi, bevel=0.03)
    # inner step down to the canvas
    _ring(b, IW / 2 + 0.08, IH / 2 + 0.08, 0.1, 0.24, gold_dk, bevel=0.025)
    # beads along the outer edge (egg-and-dart, simplified)
    for i in range(22):
        x = -hw + 0.3 + (W - 0.6) * i / 21
        for z in (CZ + hh - 0.05, CZ - hh + 0.05):
            b.sphere(0.06, (x, -0.2, z), gold_hi, segs=6, rings=4)
    for i in range(14):
        z = CZ - hh + 0.3 + (H - 0.6) * i / 13
        for x in (-hw + 0.05, hw - 0.05):
            b.sphere(0.06, (x, -0.2, z), gold_hi, segs=6, rings=4)
    # corner rosettes: a disc with a star on top
    for sx in (-1, 1):
        for sz in (-1, 1):
            cx, cz = sx * (hw - 0.3), CZ + sz * (hh - 0.3)
            prof = [(0.0, 0.0), (0.3, 0.0), (0.32, 0.05), (0.26, 0.1), (0.0, 0.12)]
            b.lathe(prof, gold, segs=16, closed=False, loc=(cx, -0.34, cz), rot=(math.pi / 2, 0, 0))
            b.prism(star_poly(0.22, 0.1, 6), -0.03, 0.05, gold_hi, loc=(cx, -0.45, cz), rot=(math.pi / 2, 0, 0))
    # crest: a shell-like fan of petals over the top centre, flanked by scrolls
    top = CZ + hh
    for i in range(7):
        a = math.radians(-60 + 20 * i)
        tip = (math.sin(a) * 0.95, -0.25, top + 0.15 + math.cos(a) * 0.75)
        b.tube([(0, -0.25, top - 0.05), tip], 0.11, gold, sides=6, radii=[0.08, 0.14])
        b.sphere(0.13, tip, gold_hi, segs=8, rings=5)
    b.sphere(0.3, (0, -0.3, top + 0.1), gold_hi, segs=12, rings=8, scale=(1.0, 0.6, 1.0))
    for sx in (-1, 1):
        path = [(sx * 0.6, -0.22, top + 0.02), (sx * 1.3, -0.22, top + 0.12), (sx * 1.8, -0.22, top + 0.02),
                (sx * 1.95, -0.22, top - 0.08)]
        b.tube(path, 0.08, gold, sides=6, radii=[0.1, 0.08, 0.07, 0.05])
        b.sphere(0.11, (sx * 1.95, -0.24, top - 0.08), gold_hi, segs=8, rings=5)
    # a small plaque under the bottom edge
    b.box((1.6, 0.08, 0.36), (0, -0.2, -0.12), plaque, bevel=0.02)
    b.box((1.7, 0.06, 0.44), (0, -0.16, -0.12), gold_dk, bevel=0.015)
    ob = b.build()
    return finish("portrait_frame_big", [ob], expect_tris=(500, 9000))


ALL = [portrait_frame_big]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
