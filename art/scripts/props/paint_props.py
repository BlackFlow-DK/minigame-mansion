"""Paint Splat props: paint_tile, paint_bucket, paint_wall, paint_easel, paint_cans.

Run: tools/blender-run.ps1 art/scripts/props/paint_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

PI = math.pi
# Splash colours (the first eight player primaries), for decoration only.
SPLASH = ["#e0303a", "#2f7fe0", "#3cb44b", "#ffe03a", "#9b5de5", "#ff7a1a", "#1cc7c1", "#ff6fb5"]


def _sq(h):
    return [(-h, -h), (h, -h), (h, h), (-h, h)]


def _blob(n, r, seed, squash=1.0):
    """A soft paint-splat outline (CCW), radius about r."""
    import random
    rng = random.Random(seed)
    pts = []
    for i in range(n):
        a = TAU * i / n
        k = 1.0 + (0.28 if i % 3 == 0 else 0.0) * rng.uniform(0.4, 1.0) - rng.uniform(0.0, 0.1)
        pts.append((r * k * math.cos(a), r * k * math.sin(a) * squash))
    return pts


def paint_tile():
    """1 m floor tile. Surfaces: PaintGrout (the body, shows as a thin seam) and PaintTop (white, recoloured
    per player in Godot). Top face exactly at y = 0."""
    new_piece()
    b = Builder("paint_tile", angle=30)
    grout = M(None, 0.9, name="PaintGrout", hexv="#8f877c")
    top = M(None, 0.7, name="PaintTop", hexv="#ffffff")
    b.prism(_sq(0.5), -0.3, -0.04, grout, bevel=0.015, seg=1)
    b.prism(_sq(0.47), -0.12, 0.0, top, bevel=0.03, seg=2)
    ob = b.build()
    return finish("paint_tile", [ob], expect_tris=(12, 400))


def paint_bucket():
    """The splash bomb: a ~0.6 m paint bucket with rainbow paint inside, drips down the side, a wire handle and
    a glowing gold rim. Origin at the base centre."""
    new_piece()
    metal = M(None, 0.45, 0.3, name="BucketMetal", hexv="#e9e4da")
    band = M("red", 0.6)
    rim = EM("EmitPaintRim", "#ffd23f", 1.6, 0.4)
    dark = M("charcoal", 0.8)
    paints = [M(None, 0.35, name="Paint%d" % i, hexv=h) for i, h in enumerate(SPLASH)]
    b = Builder("paint_bucket", angle=35)
    r0, r1, h = 0.24, 0.29, 0.5
    # tapered wall with a thickness (open top)
    prof = [(0.0, 0.0), (r0 - 0.02, 0.0), (r0, 0.02), (r1, h), (r1 - 0.025, h), (r0 - 0.025, 0.04), (0.0, 0.04)]
    b.lathe(prof, metal, segs=24)
    # red label band
    band_prof = [(r0 + (r1 - r0) * 0.3 + 0.004, 0.3 * h), (r0 + (r1 - r0) * 0.62 + 0.004, 0.62 * h)]
    zb0, zb1 = 0.3 * h, 0.62 * h
    b.lathe([(band_prof[0][0], zb0), (band_prof[1][0], zb1), (band_prof[1][0] - 0.01, zb1),
             (band_prof[0][0] - 0.01, zb0)], band, segs=24, closed=True)
    # glowing rolled rim
    rr = 0.028
    rim_prof = [(r1 - 0.03 + rr * math.cos(a), h + rr * math.sin(a)) for a in
                [TAU * i / 8 for i in range(8)]]
    b.lathe(rim_prof, rim, segs=24, closed=True)
    # paint surface: four wedges of colour, slightly domed swirl
    for k in range(4):
        a0 = TAU * k / 4 + 0.3
        b.lathe([(0.0, h - 0.06), (r1 - 0.03, h - 0.07), (r1 - 0.03, h - 0.09), (0.0, h - 0.09)],
                paints[[0, 1, 2, 3][k]], segs=6, a0=a0, a1=a0 + TAU / 4)
    b.sphere(0.06, (0.0, 0.0, h - 0.07), paints[4], scale=(1, 1, 0.35), segs=10, rings=5)
    # drips over the lip (front and sides)
    for i, (ang, length, col) in enumerate(((-100, 0.2, 0), (-55, 0.12, 3), (-140, 0.15, 1), (20, 0.18, 2),
                                            (160, 0.1, 5), (95, 0.14, 6))):
        a = math.radians(ang)
        rt = r1 + 0.012
        z_top = h + 0.01
        z_bot = z_top - length
        rb_ = r0 + (r1 - r0) * (z_bot / h) + 0.012
        path = [(rt * math.cos(a), rt * math.sin(a), z_top), (((rt + rb_) / 2) * math.cos(a),
                ((rt + rb_) / 2) * math.sin(a), (z_top + z_bot) / 2), (rb_ * math.cos(a), rb_ * math.sin(a), z_bot)]
        b.tube(path, 0.025, paints[col], sides=6, radii=[0.03, 0.024, 0.02])
        b.sphere(0.032, (rb_ * math.cos(a), rb_ * math.sin(a), z_bot), paints[col], segs=8, rings=5)
    # wire handle with ears
    for s in (-1, 1):
        b.sphere(0.035, (s * (r1 - 0.005), 0.0, h - 0.07), dark, scale=(0.5, 1, 1), segs=8, rings=5)
    arc =[((r1 + 0.005) * math.cos(PI * i / 10), -0.0, h - 0.07 + 0.28 * math.sin(PI * i / 10)) for i in range(11)]
    b.tube(arc, 0.012, dark, sides=6)
    ob = b.build()
    return finish("paint_bucket", [ob])


def paint_wall():
    """7 m long studio wall segment along X, centred on x = 0, 0.5 m high (low, so blobs by the front wall stay
    visible). Inner face at Godot z = 0 facing +Z
    (Blender -Y); the wall body runs back to Godot z = -0.3. A pilaster at the +X end covers joints/corners."""
    new_piece()
    plaster = M(None, 0.85, name="Plaster", hexv="#f1e8d8")
    wood, dw = M("wood", 0.8), M("dark_wood", 0.8)
    b = Builder("paint_wall", angle=30)
    L = 7.0
    # body (Blender y from 0 to +0.3 is Godot z 0 .. -0.3)
    H = 0.5
    b.box((L, 0.3, H), (0.0, 0.15, H / 2), plaster, bevel=0.02)
    # baseboard and cap rail on the inner face and top
    b.box((L, 0.05, 0.12), (0.0, -0.02, 0.06), dw, bevel=0.012)
    b.box((L, 0.4, 0.06), (0.0, 0.13, H + 0.03), wood, bevel=0.02)
    # a band of colour swatches along the inner face (studio paint chart)
    n = 14
    for i in range(n):
        x = -L / 2 + (i + 0.5) * L / n
        col = M(None, 0.6, name="Swatch%d" % (i % 8), hexv=SPLASH[i % 8])
        b.box((L / n - 0.06, 0.02, 0.09), (x, -0.005, 0.3), col, bevel=0.008)
    # pilaster at the +X end
    b.box((0.36, 0.42, 0.66), (L / 2 + 0.15, 0.12, 0.33), wood, bevel=0.03)
    b.box((0.44, 0.5, 0.07), (L / 2 + 0.15, 0.12, 0.68), dw, bevel=0.02)
    ob = b.build()
    return finish("paint_wall", [ob])


def paint_easel():
    """Artist's easel with a splashed canvas, ~1.75 m tall, front faces Godot +Z. Origin base centre."""
    new_piece()
    wood, dw = M("wood", 0.8), M("dark_wood", 0.8)
    canvas = M(None, 0.9, name="Canvas", hexv="#faf6ec")
    b = Builder("paint_easel", angle=30)
    # front legs (splayed) and back leg
    for s in (-1, 1):
        b.tube([(s * 0.42, -0.12, 0.0), (s * 0.08, 0.02, 1.72)], 0.03, wood, sides=6)
    b.tube([(0.0, 0.55, 0.0), (0.0, 0.05, 1.6)], 0.028, dw, sides=6)
    # tray and cross bar
    b.box((0.9, 0.12, 0.04), (0.0, -0.1, 0.62), dw, bevel=0.01)
    b.box((0.9, 0.03, 0.06), (0.0, -0.16, 0.66), dw, bevel=0.01)
    b.box((0.55, 0.04, 0.05), (0.0, -0.02, 1.35), wood, bevel=0.01)
    # canvas, leaning on the tray
    tilt = math.radians(-8)
    b.box((0.86, 0.04, 0.66), (0.0, -0.08, 1.0), canvas, bevel=0.01, rot=(tilt, 0, 0))
    # splats on the canvas front
    for i, (x, z, r, c) in enumerate(((-0.2, 1.1, 0.14, 0), (0.18, 0.92, 0.12, 1), (0.05, 1.18, 0.08, 3),
                                      (-0.22, 0.84, 0.07, 2), (0.26, 1.2, 0.06, 7))):
        col = M(None, 0.5, name="Paint%d" % c, hexv=SPLASH[c])
        y = -0.08 - 0.021 - (z - 1.0) * math.tan(-tilt)
        b.prism(_blob(10, r, 40 + i), -0.004, 0.004, col, loc=(x, y, z), rot=(PI / 2 + tilt, 0, 0))
    # a couple of brushes on the tray
    for x, c in ((-0.25, 5), (0.1, 6)):
        b.tube([(x, -0.12, 0.66), (x + 0.2, -0.1, 0.665)], 0.012, wood, sides=5)
        b.sphere(0.02, (x + 0.21, -0.1, 0.665), M(None, 0.5, name="Paint%d" % c, hexv=SPLASH[c]),
                 scale=(1.6, 1, 1), segs=6, rings=4)
    ob = b.build()
    return finish("paint_easel", [ob])


def paint_cans():
    """Three paint cans (one tipped over with a spill), ~0.8 m across. Origin base centre."""
    new_piece()
    metal = M(None, 0.45, 0.3, name="CanMetal", hexv="#d9d5cc")
    dark = M("charcoal", 0.8)
    b = Builder("paint_cans", angle=35)
    cans = [((-0.2, 0.05), 0.15, 0.26, 1), ((0.16, 0.12), 0.13, 0.22, 3)]
    for (x, y), r, h, c in cans:
        col = M(None, 0.4, name="Paint%d" % c, hexv=SPLASH[c])
        b.cyl(r, h, (x, y, 0.0), metal, segs=18, bevel=0.012)
        b.lathe([(r * 0.7, h - 0.004), (r + 0.004, h - 0.004), (r + 0.004, h + 0.012), (r * 0.7, h + 0.012)],
                col, segs=18, loc=(x, y, 0.0), closed=True)
        b.cyl(r * 0.72, 0.008, (x, y, h), col, segs=18)
        b.box((2 * r + 0.01, 0.02, 0.05), (x, y - r * 0.02, h * 0.55), col, rot=(0, 0, 0))
        b.lathe([(r + 0.002, h * 0.35), (r + 0.006, h * 0.35), (r + 0.006, h * 0.75), (r + 0.002, h * 0.75)],
                col, segs=18, loc=(x, y, 0.0), closed=True)
    # tipped can with a puddle
    col = M(None, 0.35, name="Paint0", hexv=SPLASH[0])
    b.cyl(0.12, 0.2, (0.0, 0.05, 0.12), metal, segs=16, bevel=0.01, rot=(PI / 2, 0, 0.5))
    b.cyl(0.09, 0.012, (0.096, -0.126, 0.12), dark, segs=16, rot=(PI / 2, 0, 0.5))  # open end
    b.prism(_blob(12, 0.26, 7, 0.8), 0.0, 0.012, col, loc=(0.22, -0.3, 0.0), rot=(0, 0, 0.5))
    ob = b.build()
    return finish("paint_cans", [ob])


ALL = [paint_tile, paint_bucket, paint_wall, paint_easel, paint_cans]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
