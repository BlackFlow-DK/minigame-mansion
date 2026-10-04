"""Crown Keeper props: crown_royal, crown_throne, crown_dais, crown_floor, crown_banner.

crown_royal: chunky jewelled gold crown, 0.47 m across, ~0.33 m tall, origin base centre. The rims use the
  emissive `EmitCrownRim`, the jewels `EmitJewel*` (a faint glow so it reads from across the room).
crown_throne: 1.4 m wide (x -0.7..0.7), 1.0 m deep (Godot z -0.5..0.5), seat top at 0.57 m, back up to 2.47 m.
  Front faces Godot +Z.
crown_dais: two round marble steps, r 3.0 (top 0.25 m) and r 2.1 (top 0.5 m), gold trim, red carpet disc on top.
crown_floor: octagonal throne-room floor, apothem 9.85 m (a face toward Godot +Z), top at y=0, slab to -0.15;
  checker marble ring, gold band, red carpet from the dais (z +2.9) to the front edge (z +9.85).
crown_banner: 1.2 x 2.6 m royal red swallowtail banner with a gold crown, on a gold rod; origin at the bottom
  centre (the tail tips), cloth front faces Godot +Z, back face at Godot z = 0 (hang it on a wall face).
Run: tools/blender-run.ps1 art/scripts/props/crown_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

HALF_PI = math.pi / 2


def _gold():
    return M("gold", 0.3, 0.45, name="CrownGold", hexv="#f2bd3c")


def _velvet():
    return M("red", 0.85, name="Velvet", hexv="#a3203a")


def crown_royal():
    new_piece()
    gold = _gold()
    rim = EM("EmitCrownRim", "#ffd56a", 2.2, 0.3)
    velvet = _velvet()
    jewels = [EM("EmitJewelRed", "#ff3048", 0.9, 0.2), EM("EmitJewelBlue", "#3f8bff", 0.9, 0.2),
              EM("EmitJewelGreen", "#2fe07a", 0.9, 0.2)]
    pearl = M("cream", 0.35, name="Pearl", hexv="#fff6e0")
    b = Builder("crown_royal", angle=40)
    # band, with glowing rims top and bottom
    prof, _ = rrect(0.185, 0.215, 0.0, 0.125, 0.008, 0.008, 1)
    b.lathe(prof, gold, segs=32, closed=True)
    prof, _ = rrect(0.2, 0.235, 0.0, 0.035, 0.012, 0.01, 1)
    b.lathe(prof, rim, segs=32, closed=True)
    prof, _ = rrect(0.2, 0.232, 0.1, 0.132, 0.01, 0.01, 1)
    b.lathe(prof, rim, segs=32, closed=True)
    # velvet cap inside, with a gold orb and cross on top
    dome =[(0.0, 0.05), (0.188, 0.05)] + [(0.188 * math.cos(math.radians(a)), 0.05 + 0.15 * math.sin(math.radians(a)))
                                            for a in range(15, 90, 15)] + [(0.0, 0.2)]
    b.lathe(dome, velvet, segs=24)
    b.sphere(0.045, (0, 0, 0.235), gold, segs=12, rings=8)
    b.box((0.026, 0.026, 0.1), (0, 0, 0.3), gold, bevel=0.006)
    b.box((0.075, 0.026, 0.026), (0, 0, 0.31), gold, bevel=0.006)
    # six big points leaning out a little, a pearl on every tip; a jewel on the band under each point
    poly = [(-0.085, 0.0), (0.085, 0.0), (0.0, 0.17)]
    for k in range(6):
        a = -HALF_PI + k * math.pi / 3
        lean = HALF_PI + 0.2
        base = Vector((0.2 * math.cos(a), 0.2 * math.sin(a), 0.11))
        xf = xform(base, (lean, 0.0, a + HALF_PI))
        b.prism(poly, -0.016, 0.016, gold, xf=xf)
        tip = xf @ Vector((0.0, 0.175, 0.0))
        b.sphere(0.032, tip, pearl, segs=8, rings=5)
        jb = Vector((0.222 * math.cos(a), 0.222 * math.sin(a), 0.067))
        b.sphere(0.036, jb, jewels[k % 3], scale=(1.0, 0.55, 1.0), segs=10, rings=6, rot=(0, 0, a + HALF_PI))
        # small gold stud between the points
        a2 = a + math.pi / 6
        b.sphere(0.018, (0.218 * math.cos(a2), 0.218 * math.sin(a2), 0.067), gold, segs=6, rings=4)
    ob = b.build()
    return finish("crown_royal", [ob], expect_tris=(50, 4000))


def crown_throne():
    new_piece()
    gold, velvet = _gold(), _velvet()
    dw = M("dark_wood", 0.75)
    b = Builder("crown_throne", angle=35)
    # plinth and seat block (front edge at Blender y = -0.5 = Godot z +0.5)
    b.box((1.4, 1.0, 0.12), (0, 0, 0.06), dw, bevel=0.025)
    b.box((1.24, 0.86, 0.35), (0, -0.04, 0.295), gold, bevel=0.03)
    b.box((1.0, 0.72, 0.11), (0, -0.1, 0.52), velvet, bevel=0.045, seg=2)
    # back: gold frame, velvet panel, a pointed crest with a jewel
    b.box((1.4, 0.22, 1.9), (0, 0.39, 1.07), gold, bevel=0.035)
    b.box((0.98, 0.05, 1.4), (0, 0.27, 1.25), velvet, bevel=0.02)
    crest = [(-0.7, 0.0), (0.7, 0.0), (0.55, 0.22), (0.18, 0.3), (0.0, 0.45), (-0.18, 0.3), (-0.55, 0.22)]
    b.prism(crest, -0.48, -0.3, gold, loc=(0, 0, 2.02), rot=(HALF_PI, 0, 0))
    b.sphere(0.07, (0, 0.27, 2.2), EM("EmitJewelRed", "#ff3048", 0.9, 0.2), scale=(1.0, 0.5, 1.0), segs=10, rings=6)
    for sx in (-1, 1):
        b.sphere(0.085, (sx * 0.64, 0.39, 2.09), gold, segs=12, rings=8)
        # arms with round gold knobs
        b.box((0.16, 0.74, 0.3), (sx * 0.63, -0.07, 0.62), gold, bevel=0.04)
        b.box((0.2, 0.78, 0.06), (sx * 0.63, -0.08, 0.79), velvet, bevel=0.025)
        b.sphere(0.09, (sx * 0.63, -0.44, 0.84), gold, segs=12, rings=8)
    ob = b.build()
    return finish("crown_throne", [ob])


def crown_dais():
    new_piece()
    gold = _gold()
    marble = M("cream", 0.55, name="Marble", hexv="#efe4d2")
    plum = M("plum", 0.7)
    velvet = _velvet()
    b = Builder("crown_dais", angle=35)
    prof, _ = rrect(0, 3.0, 0.0, 0.25, 0.03, 0.0, 2)
    b.lathe(prof, lambda r, z: plum if z > 0.245 and r < 2.9 else marble, segs=56)
    prof, _ = rrect(0, 2.1, 0.25, 0.5, 0.03, 0.0, 2)
    b.lathe(prof, lambda r, z: plum if z > 0.495 and r < 2.0 else marble, segs=48)
    # gold trim bands just under each top edge
    for r, z in ((3.0, 0.25), (2.1, 0.5)):
        pr, _ = rrect(r - 0.01, r + 0.02, z - 0.08, z - 0.04, 0.008, 0.008, 1)
        b.lathe(pr, gold, segs=56, closed=True)
    # red carpet disc on the top step with a gold edge
    pr, _ = rrect(0, 1.85, 0.5, 0.515, 0.006, 0.0, 1)
    b.lathe(pr, velvet, segs=40)
    pr, _ = rrect(1.85, 1.92, 0.5, 0.512, 0.004, 0.0, 1)
    b.lathe(pr, gold, segs=40, closed=True)
    ob = b.build()
    return finish("crown_dais", [ob], expect_tris=(50, 6000))


def crown_floor():
    new_piece()
    APO = 9.85
    rv = APO / math.cos(math.pi / 8)
    grout = M("charcoal", 0.9, name="FloorGrout", hexv="#2b2433")
    marble = M("cream", 0.5, name="Marble", hexv="#efe4d2")
    dark = M("plum", 0.6, name="MarbleDark", hexv="#5a4170")
    gold = _gold()
    velvet = _velvet()
    b = Builder("crown_floor", angle=30)
    # octagon slab; a face toward Godot +Z (Blender -Y): vertices at 22.5 + k * 45 degrees from -Y
    octo = [(rv * math.sin(math.radians(22.5 + 45 * k)), -rv * math.cos(math.radians(22.5 + 45 * k)))
            for k in range(8)]
    octo = octo[::-1] if _signed_area(octo) < 0 else octo
    b.prism(octo, -0.15, -0.004, grout)
    # checker marble ring around the dais, then a gold band
    polar_cells(b, 2.9, 9.1, 0.0, 0.775, 0.85, 0.035,
                lambda k, j, rm, rng: marble if (k + j) % 2 == 0 else dark, seed=3, brick=False)
    pr, _ = rrect(9.1, 9.3, -0.004, 0.003, 0.0, 0.0, 1)
    b.lathe(pr, gold, segs=64, closed=True)
    # red carpet from the dais to the front edge, gold edging
    y0, y1 = -APO, -2.85
    b.box((1.7, y1 - y0, 0.016), (0, (y0 + y1) / 2, 0.004), velvet, bevel=0.004)
    for sx in (-1, 1):
        b.box((0.08, y1 - y0, 0.018), (sx * 0.89, (y0 + y1) / 2, 0.005), gold, bevel=0.004)
    ob = b.build()
    return finish("crown_floor", [ob], expect_tris=(50, 6000))


def _signed_area(poly):
    s = 0.0
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        s += x0 * y1 - x1 * y0
    return s / 2


def crown_banner():
    new_piece()
    gold = _gold()
    red = M("red", 0.85, name="BannerRed", hexv="#b3203a")
    b = Builder("crown_banner", angle=35)
    cloth = [(-0.6, 0.0), (0.0, 0.38), (0.6, 0.0), (0.6, 2.6), (-0.6, 2.6)]
    border = [(-0.66, -0.07), (0.0, 0.31), (0.66, -0.07), (0.66, 2.62), (-0.66, 2.62)]
    # prism in local XY, rotated so local Y is up and the extrusion runs toward Blender -Y (Godot +Z)
    b.prism(border, 0.0, 0.015, gold, rot=(HALF_PI, 0, 0))
    b.prism(cloth, 0.015, 0.03, red, rot=(HALF_PI, 0, 0))
    emblem = [(-0.32, 1.45), (0.32, 1.45), (0.32, 1.72), (0.38, 2.02), (0.17, 1.84), (0.0, 2.12), (-0.17, 1.84),
              (-0.38, 2.02), (-0.32, 1.72)]
    b.prism(emblem, 0.03, 0.045, gold, rot=(HALF_PI, 0, 0))
    b.prism([(-0.36, 1.3), (0.36, 1.3), (0.36, 1.38), (-0.36, 1.38)], 0.03, 0.045, gold, rot=(HALF_PI, 0, 0))
    b.cyl(0.03, 1.56, (-0.78, -0.03, 2.66), gold, segs=8, rot=(0, HALF_PI, 0))
    for sx in (-1, 1):
        b.sphere(0.055, (sx * 0.8, -0.03, 2.66), gold, segs=10, rings=6)
    ob = b.build()
    return finish("crown_banner", [ob])


ALL = [crown_royal, crown_throne, crown_dais, crown_floor, crown_banner]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
