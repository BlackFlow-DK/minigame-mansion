"""Statue Garden props: statue_butler, statue_hedge, statue_topiary, statue_urn, statue_bench, statue_fountain.

statue_butler: a giant stone butler on a plinth, ~5.4 m tall. Three objects: `Plinth` (origin at the base
  centre; 3.6 m x 2.8 m at the foot, cap 3.4 m wide (x) x 2.6 m deep, top at 1.03 m), `Body` (the figure, origin on
  the plinth top centre, so the game can turn it around Y) and its child `Head` (origin at the neck pivot, Godot
  y = HEAD_PIVOT_Z, turns around Y relative to the body). The figure faces Godot +Z; the eyes use the emissive
  material `EmitEyes` (the game drives their glow).
statue_hedge: a clipped hedge block 2 m long (x), 0.9 m deep, ~1.25 m tall.
statue_topiary: three clipped balls on a stem in a terracotta pot, ~2.1 m tall, r 0.55.
statue_urn: a stone pedestal (0.6 m square) with a flowering urn, ~1.75 m tall.
statue_bench: a stone garden bench 2.0 m x 0.62 m, seat at 0.5 m, low back at the Godot -Z side.
statue_fountain: a round basin (r 1.4 m, rim 0.55 m) with a two-tier centre, ~1.9 m tall.
Run: tools/blender-run.ps1 art/scripts/props/statue_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

PLINTH_TOP = 1.03
HEAD_PIVOT_Z = PLINTH_TOP + 3.12


def _stones():
    return dict(
        light=M("stone", 0.85, name="StoneLight", hexv="#d6d0c4"),
        mid=M("stone", 0.85, name="StoneMid", hexv="#aaa49b"),
        dark=M("stone", 0.9, name="StoneDark", hexv="#5f5967"),
        deep=M("stone", 0.9, name="StoneDeep", hexv="#3b3641"),
        moss=M("green", 0.95, name="Moss", hexv="#6f8f48"),
    )


def statue_butler():
    new_piece()
    s = _stones()
    gold = M("gold", 0.35, 0.5)
    P = PLINTH_TOP
    pl = Builder("Plinth", angle=36)
    # --- plinth: base slab, block, cap, a gold plaque, moss in the corners
    pl.box((3.6, 2.8, 0.25), (0, 0, 0.125), s["dark"], bevel=0.05)
    pl.box((3.1, 2.3, 0.62), (0, 0, 0.25 + 0.31), s["mid"], bevel=0.05)
    pl.box((3.4, 2.6, 0.18), (0, 0, P - 0.09), s["light"], bevel=0.05)
    pl.box((1.3, 0.05, 0.34), (0, -1.165, 0.56), gold, bevel=0.015)
    pl.box((1.1, 0.03, 0.04), (0, -1.19, 0.62), s["deep"])
    pl.box((0.8, 0.03, 0.04), (0, -1.19, 0.52), s["deep"])
    for (x, y, sc) in [(-1.45, -1.12, 0.32), (1.5, 1.05, 0.28), (1.48, -1.0, 0.2), (-1.5, 1.1, 0.24)]:
        pl.ico(sc, (x, y, 0.22), s["moss"], subdiv=1, scale=(1.3, 1.0, 0.7), fn=lumps(int(x * 10 + y * 3), amp=0.2))
    plinth = pl.build()
    # --- the figure, built with its feet at z = 0 (the plinth top) and placed there
    P = 0.0
    b = Builder("Body", angle=36)
    # --- shoes and trousers
    for sx in (-1, 1):
        b.box((0.46, 0.78, 0.24), (sx * 0.34, -0.14, P + 0.12), s["deep"], bevel=0.1, seg=2)
        b.cyl(0.29, 1.2, (sx * 0.33, 0.0, P + 0.18), s["deep"], segs=14, bevel=0.04)
    # --- tailcoat body (a squashed lathe), tails at the back
    prof = [(0.0, P + 1.15), (0.66, P + 1.15), (0.76, P + 1.35), (0.82, P + 1.75), (0.85, P + 2.2),
            (0.82, P + 2.55), (0.74, P + 2.8), (0.56, P + 2.98), (0.32, P + 3.06), (0.0, P + 3.08)]
    b.lathe(prof, s["dark"], segs=24, scale=(1.0, 0.74, 1.0))
    for sx in (-1, 1):
        b.tube([(sx * 0.26, 0.42, P + 1.55), (sx * 0.3, 0.55, P + 1.1), (sx * 0.32, 0.6, P + 0.6)], 0.2, s["dark"],
               sides=8, radii=[0.24, 0.2, 0.12])
    # shirt front, waistcoat buttons, lapels, stiff collar and the bow tie
    b.sphere(1.0, (0, -0.5, P + 2.42), s["light"], scale=(0.3, 0.14, 0.56), segs=14, rings=8)
    for z in (P + 1.95, P + 2.2, P + 2.45):
        b.sphere(0.055, (0, -0.635, z), s["deep"], segs=8, rings=5)
    for sx in (-1, 1):
        b.tube([(sx * 0.18, -0.6, P + 2.9), (sx * 0.34, -0.6, P + 2.4), (sx * 0.24, -0.62, P + 1.95)], 0.07,
               s["deep"], sides=6, radii=[0.06, 0.09, 0.05])
    b.cyl(0.26, 0.2, (0, 0, P + 2.98), s["light"], segs=16, bevel=0.04)
    wing = [(0.0, 0.0), (0.3, 0.16), (0.3, -0.16)]
    b.prism(wing, 0.48, 0.62, s["deep"], loc=(0, 0, P + 2.88), rot=(math.pi / 2, 0, 0))
    b.prism([(-x, y) for x, y in wing][::-1], 0.48, 0.62, s["deep"], loc=(0, 0, P + 2.88), rot=(math.pi / 2, 0, 0))
    b.sphere(0.09, (0, -0.6, P + 2.88), s["deep"], segs=8, rings=6)
    # --- raised arm with the tray and cloche (Godot +X side)
    arm_r = [(0.72, 0.0, P + 2.78), (1.22, 0.02, P + 2.55), (1.3, -0.05, P + 3.35)]
    b.tube(arm_r, 0.2, s["dark"], sides=10, radii=[0.22, 0.2, 0.17])
    b.sphere(0.2, (1.22, 0.02, P + 2.55), s["dark"], segs=10, rings=6)
    b.sphere(0.17, (1.3, -0.05, P + 3.42), s["light"], segs=10, rings=6, scale=(1.0, 1.0, 0.7))
    b.cyl(0.62, 0.05, (1.3, -0.05, P + 3.5), s["light"], segs=24, bevel=0.02)
    prof, _ = rrect(0.58, 0.64, P + 3.5, P + 3.6, 0.02, 0.0, 1)
    b.lathe(prof, s["light"], segs=24, closed=True, loc=(1.3, -0.05, 0))
    dome = [(0.42 * math.sin(math.pi / 2 * i / 6), 0.36 * math.cos(math.pi / 2 * i / 6)) for i in range(7)]
    dome = [(r, z) for r, z in reversed(dome)]
    b.lathe([(0.0, 0.36)] + dome[1:] + [(0.0, 0.0)], s["mid"], segs=20, loc=(1.3, -0.05, P + 3.55))
    b.sphere(0.07, (1.3, -0.05, P + 3.97), s["dark"], segs=8, rings=5)
    # --- other arm across the waist with a towel over it
    arm_l = [(-0.72, 0.0, P + 2.78), (-0.92, 0.0, P + 2.05), (-0.35, -0.6, P + 1.95)]
    b.tube(arm_l, 0.2, s["dark"], sides=10, radii=[0.22, 0.2, 0.17])
    b.sphere(0.2, (-0.92, 0.0, P + 2.05), s["dark"], segs=10, rings=6)
    b.sphere(0.17, (-0.28, -0.66, P + 1.97), s["light"], segs=10, rings=6)
    b.box((0.36, 0.08, 0.7), (-0.62, -0.66, P + 1.62), s["light"], bevel=0.03, rot=(0.12, 0, 0.35))
    body = b.build(loc=(0, 0, PLINTH_TOP))

    # --- the head, built around its pivot (the neck), looking along Blender -Y (Godot +Z)
    h = Builder("Head", angle=36)
    eyes = EM("EmitEyes", "#ff3a2e", 3.0)
    h.cyl(0.2, 0.18, (0, 0, -0.06), s["mid"], segs=12)
    h.sphere(0.56, (0, 0, 0.6), s["light"], scale=(1.0, 0.95, 1.08), segs=20, rings=12)
    h.sphere(0.46, (0, -0.1, 0.4), s["light"], scale=(1.05, 0.9, 0.78), segs=16, rings=10)
    # slicked hair: a dark cap at the back and over the crown, side wings
    h.sphere(0.6, (0, 0.12, 0.72), s["dark"], scale=(1.02, 0.86, 0.9), segs=18, rings=10)
    for sx in (-1, 1):
        h.sphere(0.25, (sx * 0.47, 0.1, 0.72), s["dark"], scale=(0.6, 1.2, 0.8), segs=10, rings=6)
        h.sphere(0.16, (sx * 0.56, -0.02, 0.55), s["mid"], scale=(0.45, 0.7, 1.0), segs=10, rings=6)  # ears
    # stern brows angled down to the middle, deep sockets, glowing eye slits
    for sx in (-1, 1):
        h.tube([(sx * 0.06, -0.54, 0.76), (sx * 0.2, -0.56, 0.82), (sx * 0.38, -0.47, 0.9)], 0.06, s["deep"],
               sides=6, radii=[0.05, 0.07, 0.04])
        h.sphere(0.12, (sx * 0.19, -0.47, 0.67), s["deep"], scale=(1.35, 0.6, 0.85), segs=12, rings=6)
        h.sphere(0.085, (sx * 0.19, -0.53, 0.665), eyes, scale=(1.4, 0.55, 0.62), segs=12, rings=6)
    # nose and a grand curled moustache
    h.sphere(0.13, (0, -0.6, 0.55), s["mid"], scale=(0.8, 1.15, 1.0), segs=10, rings=6)
    for sx in (-1, 1):
        h.tube([(0.0, -0.6, 0.42), (sx * 0.22, -0.58, 0.39), (sx * 0.42, -0.45, 0.46), (sx * 0.46, -0.38, 0.6),
                (sx * 0.38, -0.42, 0.66)], 0.08, s["deep"], sides=8, radii=[0.08, 0.075, 0.055, 0.035, 0.02])
    head = h.build(loc=(0, 0, HEAD_PIVOT_Z))
    bpy.context.view_layer.update()
    artlib.set_parent(head, body)
    return finish("statue_butler", [plinth, body, head], expect_tris=(1500, 16000))


def statue_hedge():
    new_piece()
    b = Builder("statue_hedge", angle=40)
    leaf = M("green", 0.95, name="Hedge", hexv="#3d7a3a")
    leaf_hi = M("green", 0.95, name="HedgeLight", hexv="#559448")
    soil = M("dark_wood", 0.95, name="Soil", hexv="#4a3426")
    b.box((2.0, 0.92, 0.08), (0, 0, 0.04), soil, bevel=0.02)
    b.box((1.96, 0.86, 1.05), (0, 0, 0.06 + 0.525), leaf, bevel=0.14, seg=2)
    for i in range(4):
        x = -0.75 + 0.5 * i
        b.ico(0.32, (x, 0.0, 1.06), leaf_hi, subdiv=1, scale=(1.0, 1.25, 0.55), fn=lumps(17 + i, amp=0.12))
    ob = b.build()
    return finish("statue_hedge", [ob], expect_tris=(200, 3000))


def statue_topiary():
    new_piece()
    b = Builder("statue_topiary", angle=40)
    pot = M("red", 0.85, name="Terracotta", hexv="#b9653d")
    pot_rim = M("red", 0.85, name="TerracottaDark", hexv="#93502f")
    leaf = M("green", 0.95, name="Hedge", hexv="#3d7a3a")
    leaf_hi = M("green", 0.95, name="HedgeLight", hexv="#559448")
    stem = M("dark_wood", 0.9)
    prof = [(0.0, 0.0), (0.3, 0.0), (0.4, 0.45), (0.0, 0.45)]
    b.lathe(prof, pot, segs=16)
    prof, _ = rrect(0.32, 0.46, 0.42, 0.52, 0.02, 0.0, 1)
    b.lathe(prof, pot_rim, segs=16, closed=True)
    b.cyl(0.05, 1.3, (0, 0, 0.45), stem, segs=6)
    for z, r, m, sd in [(0.85, 0.5, leaf, 3), (1.45, 0.38, leaf_hi, 5), (1.92, 0.24, leaf, 7)]:
        b.ico(r, (0, 0, z), m, subdiv=2, fn=lumps(sd, amp=0.08))
    ob = b.build()
    return finish("statue_topiary", [ob], expect_tris=(200, 3000))


def statue_urn():
    new_piece()
    s = _stones()
    b = Builder("statue_urn", angle=38)
    leaf = M("green", 0.95, name="HedgeLight", hexv="#559448")
    pink = M("red", 0.8, name="Blossom", hexv="#f08fb0")
    b.box((0.66, 0.66, 0.12), (0, 0, 0.06), s["dark"], bevel=0.03)
    b.box((0.52, 0.52, 0.6), (0, 0, 0.12 + 0.3), s["mid"], bevel=0.03)
    b.box((0.64, 0.64, 0.1), (0, 0, 0.72 + 0.05), s["light"], bevel=0.03)
    prof = [(0.0, 0.82), (0.16, 0.82), (0.1, 0.9), (0.26, 1.02), (0.33, 1.18), (0.3, 1.3), (0.22, 1.36),
            (0.3, 1.42), (0.28, 1.46), (0.0, 1.46)]
    b.lathe(prof, s["light"], segs=18)
    b.ico(0.32, (0, 0, 1.52), leaf, subdiv=2, scale=(1.0, 1.0, 0.75), fn=lumps(41, amp=0.12))
    for i in range(7):
        a = TAU * i / 7
        b.sphere(0.06, (0.24 * math.cos(a), 0.24 * math.sin(a), 1.6 + 0.04 * (i % 2)), pink, segs=6, rings=4)
    ob = b.build()
    return finish("statue_urn", [ob], expect_tris=(200, 3000))


def statue_bench():
    new_piece()
    s = _stones()
    b = Builder("statue_bench", angle=38)
    for sx in (-1, 1):
        b.box((0.22, 0.52, 0.38), (sx * 0.72, 0, 0.19), s["mid"], bevel=0.04)
        b.box((0.3, 0.58, 0.06), (sx * 0.72, 0, 0.03), s["dark"], bevel=0.02)
    b.box((2.0, 0.62, 0.12), (0, 0, 0.44), s["light"], bevel=0.04)
    # low back on the Blender +Y side (Godot -Z), on two posts
    for sx in (-1, 1):
        b.box((0.14, 0.12, 0.34), (sx * 0.72, 0.25, 0.62), s["mid"], bevel=0.03)
    b.box((2.0, 0.12, 0.2), (0, 0.27, 0.86), s["light"], bevel=0.04)
    ob = b.build()
    return finish("statue_bench", [ob], expect_tris=(100, 2000))


def statue_fountain():
    new_piece()
    s = _stones()
    b = Builder("statue_fountain", angle=38)
    water = M("blue", 0.12, name="Water", hexv="#5fb5d8")
    prof, _ = rrect(1.12, 1.4, 0.0, 0.55, 0.05, 0.02, 2)
    b.lathe(prof, s["light"], segs=36, closed=True)
    b.cyl(1.14, 0.1, (0, 0, 0), s["dark"], segs=36)
    b.cyl(1.14, 0.38, (0, 0, 0.0), water, segs=36)
    b.cyl(0.2, 1.25, (0, 0, 0.3), s["mid"], segs=14, bevel=0.03)
    prof = [(0.0, 1.15), (0.2, 1.15), (0.55, 1.32), (0.6, 1.4), (0.0, 1.4)]
    b.lathe(prof, s["light"], segs=24)
    b.cyl(0.52, 0.04, (0, 0, 1.34), water, segs=24)
    b.cyl(0.1, 0.3, (0, 0, 1.38), s["mid"], segs=10)
    b.sphere(0.16, (0, 0, 1.78), s["light"], segs=12, rings=8)
    ob = b.build()
    return finish("statue_fountain", [ob], expect_tris=(200, 4000))


ALL = [statue_butler, statue_hedge, statue_topiary, statue_urn, statue_bench, statue_fountain]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
