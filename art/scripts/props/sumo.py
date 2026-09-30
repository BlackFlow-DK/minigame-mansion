"""Bumper Sumo props: sumo_core, sumo_ring_1..3, sumo_lantern, cloud_puff.

Platform: core radius 3, rings out to 5 / 7 / 9 m, all 0.6 m thick, top at y=0, origin at centre top.
All discs share N segments so rings meet exactly.
Run: tools/blender-run.ps1 art/scripts/props/sumo.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib
from pcommon import _arc

N = 40
THICK = 0.6
PAD = 0.14  # depth of the coloured mat pad on the rim


def _profile(ri, ro, bounds, bt=0.06, bb=0.04):
    """CCW (r, z) profile. ri == 0 -> solid from the axis (open profile). bounds: radii (descending) to split the top."""
    p = []
    zb = -THICK
    if ri > 0:
        p.append((ri + bb, zb))
    else:
        p.append((0.0, zb))
    p.append((ro - bb, zb))
    p += _arc(ro - bb, zb + bb, bb, -90, 0, 1)
    p.append((ro, -PAD))
    p.append((ro, -bt))
    p += _arc(ro - bt, -bt, bt, 0, 90, 2)
    for r in sorted(bounds, reverse=True):
        p.append((r, 0.0))
    if ri > 0:
        p.append((ri + bt, 0.0))
        p += _arc(ri + bt, -bt, bt, 90, 180, 2)
        p.append((ri, -PAD))
        p.append((ri, zb + bb))
        p += _arc(ri + bb, zb + bb, bb, 180, 270, 1)
    else:
        p.append((0.0, 0.0))
    return p, ri > 0


def _bands(spec, skirt):
    """spec: list of (r_from, r_to, material) for the top surface (z > -PAD); skirt material below."""
    def fn(rm, zm):
        if zm < -PAD:
            return skirt
        for a, b, m in spec:
            if a <= rm < b:
                return m
        return spec[-1][2]
    return fn


def _platform(name, ri, ro, spec_fn, extra=None):
    new_piece()
    plum = M("plum", 0.9)
    spec = spec_fn()  # materials are created after the reset
    bounds = sorted({b for a, b, _ in spec if ri < b < ro} | {a for a, b, _ in spec if ri < a < ro})
    prof, closed = _profile(ri, ro, bounds)
    b = Builder(name, angle=30)
    b.lathe(prof, _bands(spec, plum), segs=N, closed=closed)
    if extra:
        extra(b)
    ob = b.build()
    return finish(name, [ob])


def sumo_core():
    def spec():
        cream, red, plum = M("cream", 0.95), M("red", 0.9), M("plum", 0.9)
        return [(0, 1.0, red), (1.0, 1.15, cream), (1.15, 1.3, plum), (1.3, 2.62, cream), (2.62, 2.76, red),
                (2.76, 3.0, plum)]

    def extra(b):
        # a chunky embossed star at the centre, flush with the rim height
        pass
    return _platform("sumo_core", 0.0, 3.0, spec)


def sumo_ring_1():
    def spec():
        teal, cream, plum = M("teal", 0.9), M("cream", 0.95), M("plum", 0.9)
        return [(3.0, 3.24, plum), (3.24, 3.9, teal), (3.9, 4.1, cream), (4.1, 4.76, teal), (4.76, 5.0, plum)]
    return _platform("sumo_ring_1", 3.0, 5.0, spec)


def sumo_ring_2():
    def spec():
        cream, plum, red = M("cream", 0.95), M("plum", 0.9), M("red", 0.9)
        return [(5.0, 5.24, plum), (5.24, 5.9, cream), (5.9, 6.1, red), (6.1, 6.76, cream), (6.76, 7.0, plum)]
    return _platform("sumo_ring_2", 5.0, 7.0, spec)


def sumo_ring_3():
    def spec():
        cream, plum, red = M("cream", 0.95), M("plum", 0.9), M("red", 0.9)
        return [(7.0, 7.24, plum), (7.24, 7.9, red), (7.9, 8.1, cream), (8.1, 8.6, red), (8.6, 9.0, plum)]

    def extra(b):
        cream, dw = M("cream", 0.95), M("dark_wood", 0.85)
        posts = 8
        rp = 8.78
        hp = 0.78
        for i in range(posts):
            a = TAU * i / posts + TAU / posts / 2
            x, y = rp * math.cos(a), rp * math.sin(a)
            b.lathe([(0, 0), (0.16, 0), (0.13, 0.06), (0.13, hp - 0.02), (0.19, hp + 0.02), (0.16, hp + 0.1), (0.0, hp + 0.14)],
                    lambda r, z: cream if z > hp else dw, segs=6, loc=(x, y, 0))
        # two rope strands sagging between posts, following the ring
        rope = M("cream", 0.9)
        for zc, sag in ((0.62, 0.1), (0.34, 0.07)):
            for i in range(posts):
                a0 = TAU * i / posts + TAU / posts / 2
                a1 = a0 + TAU / posts
                steps = 5
                path = []
                for s in range(steps + 1):
                    t = s / steps
                    a = a0 + (a1 - a0) * t
                    path.append((rp * math.cos(a), rp * math.sin(a), zc - sag * math.sin(math.pi * t)))
                b.tube(path, 0.06, rope, sides=4, caps=False)
    return _platform("sumo_ring_3", 7.0, 9.0, spec, extra)


def sumo_lantern():
    """Stone-post paper lantern, 1.5 m tall, origin at base centre."""
    new_piece()
    b = Builder("sumo_lantern", angle=30)
    ds, dw, red, gold = M("dark_stone", 0.9), M("dark_wood", 0.85), M("red", 0.8), M("gold", 0.5, 0.2)
    glow = EM("EmitLantern", "#ffc85a", 1.6)
    prof, _ = rrect(0, 0.3, 0, 0.14, 0.04, 0.03, 1)
    b.lathe(prof, ds, segs=12)
    prof, _ = rrect(0, 0.09, 0.1, 0.72, 0.02, 0.0, 1)
    b.lathe(prof, dw, segs=8)
    # glowing paper body: 8-sided barrel
    body = [(0.0, 0.7), (0.22, 0.7), (0.29, 0.86), (0.29, 1.08), (0.22, 1.24), (0.0, 1.24)]
    b.lathe(body, glow, segs=8)
    # red cap plate and roof
    b.lathe([(0, 0.66), (0.26, 0.66), (0.26, 0.72), (0, 0.72)], red, segs=8)
    b.lathe([(0, 1.22), (0.34, 1.22), (0.36, 1.27), (0.16, 1.44), (0.0, 1.46)], red, segs=8)
    b.sphere(0.07, (0, 0, 1.5), gold, segs=8, rings=5)
    for i in range(8):
        a = TAU * i / 8 + TAU / 16
        b.box((0.035, 0.035, 0.54), (0.285 * math.cos(a), 0.285 * math.sin(a), 0.97), dw, rot=(0, 0, a))
    ob = b.build()
    return finish("sumo_lantern", [ob])


def cloud_puff():
    """Soft cloud cluster ~3 m wide, 1.2 m tall. Flat-ish base at z=0, origin at base centre."""
    new_piece()
    b = Builder("cloud_puff", angle=60)
    white, shade = M("cream", 1.0, name="Cloud", hexv="#fdf7ea"), M("cream", 1.0, name="CloudShade", hexv="#d3cbe6")

    def puff(r, loc, sc=(1, 1, 0.85)):
        b.lathe([(r * math.sin(math.pi * i / 7), -r * math.cos(math.pi * i / 7)) for i in range(8)],
                lambda rm, zm: shade if zm < -0.5 * r else white, segs=14, loc=loc, scale=sc)
    puffs = [
        (0.75, (0.0, 0.0, 0.62)), (0.6, (0.95, 0.1, 0.5)), (0.55, (-0.95, -0.05, 0.47)),
        (0.5, (0.35, 0.6, 0.45)), (0.5, (-0.4, -0.55, 0.45)), (0.42, (1.5, -0.2, 0.36)), (0.4, (-1.5, 0.2, 0.34)),
        (0.45, (0.05, -0.15, 1.02)),
    ]
    for r, loc in puffs:
        puff(r, loc)
    # make sure the poles are closed points
    ob = b.build()
    return finish("cloud_puff", [ob])


ALL = [sumo_core, sumo_ring_1, sumo_ring_2, sumo_ring_3, sumo_lantern, cloud_puff]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
