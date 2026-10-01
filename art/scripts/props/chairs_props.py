"""Spotlight Chairs props: chairs_pad, chairs_stage, chairs_gramophone.

chairs_pad: 1.1 m disc, 0.05 m tall, origin base centre. The glowing ring uses the emissive material
  `EmitPadRing`; the game swaps it for its own material to recolour the pad per owner.
chairs_stage: band stage for the back of the ballroom, 7 m wide (x -3.5..3.5), 2.4 m deep (Godot z -1.2..1.2),
  deck top at 0.5 m, with a curtain backdrop at the back edge up to 4.6 m. Front faces Godot +Z.
chairs_gramophone: ~1.35 m tall gramophone, horn pointing forward (Godot +Z) and up.
Run: tools/blender-run.ps1 art/scripts/props/chairs_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib


def chairs_pad():
    new_piece()
    b = Builder("chairs_pad", angle=40)
    ch = M("charcoal", 0.8)
    gold = M("gold", 0.4, 0.4)
    cream = M("cream", 0.7, name="PadTop", hexv="#f6ecd6")
    ring = EM("EmitPadRing", "#ffd98a", 1.5)
    # dark base plate with a soft bevel
    prof, _ = rrect(0, 0.55, 0.0, 0.03, 0.012, 0.006, 2)
    b.lathe(prof, ch, segs=40)
    # thin gold rim just outside the glowing ring
    prof, _ = rrect(0.515, 0.545, 0.028, 0.042, 0.006, 0.0, 1)
    b.lathe(prof, gold, segs=40, closed=True)
    # the glowing ring
    prof, _ = rrect(0.37, 0.505, 0.028, 0.044, 0.006, 0.0, 1)
    b.lathe(prof, ring, segs=40, closed=True)
    # cream centre with a gold star on it
    prof, _ = rrect(0, 0.355, 0.028, 0.04, 0.006, 0.0, 1)
    b.lathe(prof, cream, segs=32)
    b.prism(star_poly(0.24, 0.1, 5), 0.038, 0.05, gold, rot=(0, 0, 0))
    ob = b.build()
    return finish("chairs_pad", [ob])


def _folds(x0, x1, y, depth, n_folds, pts_per_fold=6):
    """Wavy curtain footprint (Blender XY) from x0 to x1 around y, as a closed thin polygon (CCW)."""
    front, back = [], []
    steps = n_folds * pts_per_fold
    for i in range(steps + 1):
        t = i / steps
        x = x0 + (x1 - x0) * t
        w = math.sin(t * n_folds * TAU) * depth
        front.append((x, y + w - 0.04))
        back.append((x, y + w + 0.04))
    return front + back[::-1]


def chairs_stage():
    new_piece()
    b = Builder("chairs_stage", angle=35)
    wood, dw = M("wood", 0.7), M("dark_wood", 0.8)
    plank_b = M("wood", 0.7, name="WoodLight", hexv="#a06d48")
    gold = M("gold", 0.35, 0.5)
    plum = M("plum", 0.85)
    velvet = M("red", 0.9, name="Velvet", hexv="#a3243b")
    velvet_dark = M("red", 0.9, name="VelvetDark", hexv="#7c1a31")
    W, D, H = 7.0, 2.4, 0.5
    # body: dark wood block, deck of planks (planks run along X, alternate shades)
    b.box((W, D, H - 0.06), (0, 0, (H - 0.06) / 2), dw, bevel=0.03)
    n_planks = 8
    pw = D / n_planks
    for i in range(n_planks):
        y = -D / 2 + pw * (i + 0.5)
        b.box((W - 0.04, pw - 0.02, 0.06), (0, y, H - 0.03), wood if i % 2 == 0 else plank_b, bevel=0.01)
    # gold nosing along the front edge, plum skirt with gold scallop studs under it
    b.box((W + 0.06, 0.1, 0.06), (0, -D / 2 - 0.02, H - 0.03), gold, bevel=0.015)
    b.box((W - 0.1, 0.04, H - 0.14), (0, -D / 2 - 0.01, (H - 0.14) / 2 + 0.04), plum, bevel=0.01)
    for i in range(13):
        x = -W / 2 + 0.35 + (W - 0.7) * i / 12
        b.sphere(0.045, (x, -D / 2 - 0.035, H - 0.14), gold, segs=8, rings=5)
    # footlights: small gold cups along the front edge of the deck
    for i in range(6):
        x = -W / 2 + 0.7 + (W - 1.4) * i / 5
        b.cyl(0.07, 0.06, (x, -D / 2 + 0.14, H), gold, segs=8, bevel=0.01)
    # backdrop curtain: wavy velvet from the deck to 4.2 m, darker lower folds
    y_back = D / 2 - 0.12
    b.prism(_folds(-W / 2 + 0.1, W / 2 - 0.1, y_back, 0.07, 14), H, 4.25, velvet)
    # side drapes gathered at the corners (swag bulges)
    for sx in (-1, 1):
        x = sx * (W / 2 - 0.35)
        path = [(x, y_back - 0.1, 4.3), (x - sx * 0.05, y_back - 0.2, 2.8), (x + sx * 0.05, y_back - 0.18, 1.6),
                (x, y_back - 0.12, H)]
        b.tube(path, 0.3, velvet_dark, sides=8, radii=[0.22, 0.12, 0.3, 0.34])
        b.sphere(0.1, (x, y_back - 0.33, 1.9), gold, segs=8, rings=5)
    # valance: a pelmet board with gold trim and a scalloped velvet hem
    b.box((W, 0.22, 0.55), (0, y_back - 0.1, 4.45), velvet_dark, bevel=0.03)
    b.box((W + 0.08, 0.26, 0.07), (0, y_back - 0.1, 4.75), gold, bevel=0.02)
    b.box((W + 0.04, 0.24, 0.05), (0, y_back - 0.1, 4.18), gold, bevel=0.015)
    for i in range(14):
        x = -W / 2 + 0.25 + (W - 0.5) * i / 13
        b.sphere(0.12, (x, y_back - 0.2, 4.12), velvet, segs=8, rings=5, scale=(1.4, 0.6, 0.8))
    # a gold star medallion on the valance
    b.prism(star_poly(0.3, 0.13, 5), -0.03, 0.03, gold, loc=(0, y_back - 0.23, 4.45), rot=(math.pi / 2, 0, 0))
    ob = b.build()
    return finish("chairs_stage", [ob], expect_tris=(200, 6000))


def chairs_gramophone():
    new_piece()
    b = Builder("chairs_gramophone", angle=35)
    wood, dw = M("wood", 0.6), M("dark_wood", 0.8)
    gold = M("gold", 0.3, 0.6)
    brass_in = M("gold", 0.5, 0.3, name="HornInside", hexv="#b57a2a")
    ch = M("charcoal", 0.5)
    red = M("red", 0.8)
    # cabinet
    b.box((0.56, 0.56, 0.3), (0, 0, 0.15 + 0.04), wood, bevel=0.03)
    b.box((0.6, 0.6, 0.04), (0, 0, 0.02), dw, bevel=0.012)
    b.box((0.6, 0.6, 0.03), (0, 0, 0.355), dw, bevel=0.01)
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.sphere(0.035, (sx * 0.27, sy * 0.27, 0.015), gold, segs=6, rings=4)
    # crank on the side
    b.tube([(0.3, 0.0, 0.2), (0.4, 0.0, 0.2), (0.4, -0.08, 0.2)], 0.015, gold, sides=6)
    b.sphere(0.03, (0.4, -0.08, 0.2), red, segs=6, rings=4)
    # record and label
    prof, _ = rrect(0, 0.24, 0.37, 0.385, 0.004, 0.0, 1)
    b.lathe(prof, ch, segs=24, loc=(0, 0.02, 0))
    prof, _ = rrect(0, 0.08, 0.385, 0.39, 0.002, 0.0, 1)
    b.lathe(prof, red, segs=16, loc=(0, 0.02, 0))
    # tone arm: from a post at the back right, over the record
    b.cyl(0.03, 0.12, (0.2, 0.2, 0.37), gold, segs=8)
    arm = [(0.2, 0.2, 0.47), (0.12, 0.05, 0.5), (0.0, -0.08, 0.52)]
    b.tube(arm, 0.02, gold, sides=6)
    # horn neck rising from the arm end, then a flared bell pointing forward (-Y) and up
    neck = [(0.0, -0.08, 0.52), (0.0, -0.02, 0.7), (0.0, 0.02, 0.86)]
    b.tube(neck, 0.035, gold, sides=8, radii=[0.03, 0.04, 0.05])
    bell_prof = []
    L = 0.62
    for i in range(9):
        t = i / 8
        r = 0.05 + 0.38 * t ** 2.4
        bell_prof.append((r, L * t))
    outer = bell_prof + [(bell_prof[-1][0] + 0.015, L + 0.01)]
    inner = [(r - 0.012, z + 0.004) for r, z in reversed(bell_prof)]
    prof = outer + inner
    # rotating the lathe axis (+Z) about X by `tilt` points it along (0, -sin, cos): forward and up
    tilt = math.radians(53)
    b.lathe(prof, gold, segs=16, closed=True, loc=(0, 0.02, 0.86), rot=(tilt, 0, 0))
    # the darker throat inside the bell: a disc a little inside the mouth
    b.lathe([(0.0, 0.0), (0.26, 0.0), (0.26, 0.01), (0.0, 0.01)], brass_in, segs=16,
            xf=xform((0, 0.02, 0.86), (tilt, 0, 0)) @ xform((0, 0, L * 0.8)))
    ob = b.build()
    return finish("chairs_gramophone", [ob])


ALL = [chairs_pad, chairs_stage, chairs_gramophone]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
