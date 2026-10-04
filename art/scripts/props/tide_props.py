"""Rising Tide props: a flooded ruined tower climbed from the side-front.

Pieces (Godot metres; origin base centre unless noted):
  tide_shelf          stone shelf 8 (x) x 0.9 (y) x 3.6 (z), y 0..0.9, z -1.8..1.8 (front face +Z).
  tide_roof           roof slab 3.6 x 0.9 x 3.6 with a gold trim (same frame as the shelf).
  tide_floor          ground floor 14 x 0.9 x 3.6, mossy flagstones.
  tide_wall           back wall storey 14 (x) x 3.6 (y) x 0.6: front face at z = 0, extends to -0.6;
  tide_wall_b         two window slits (tide_wall at x = +-4.2, tide_wall_b at x = +-1.4 and +-6.0).
  tide_pillar         front corner column storey 1.0 x 3.6 x 1.0.
  tide_pillar_top     the ruined, jagged top of a corner column (about 1.6 tall).
  tide_crate          wooden crate 1.2 x 0.9 x 1.2 (stacked to build steps).
  tide_block_cracked  cracked sandstone block 1.2 x 0.9 x 1.2 (crumbling steps).
  tide_ladder         wooden step-ladder of 5 treads (0.6 m each): tread j (1..5) tops out at 0.6 j over
                      x in [0.72 (5 - j), 0.72 (6 - j)]; z -0.6..0.6. Origin at the high end's base (x = 0).
  tide_awning         bouncy striped awning, footprint 1.2 x 1.2, top 0.45.
  tide_hanging        hanging platform 1.0 x 0.3 x 1.2, origin at the centre of its TOP (walk surface y = 0);
                      chain rings at x = +-0.35.
  tide_chain          1 m of chain, origin at its top end, hanging down to y = -1 (scaled in y in game).
  tide_beam           timber beam 4.4 (x) x 0.35 x 0.35, origin at its centre.
  tide_torch          wall torch: origin where the bracket meets the wall, sticks out +Z, flame at about
                      (0, 0.62, 0.32).
  tide_flag           summit flag: Pole (plinth, pole, knob) + separate object Flag (material FlagCloth,
                      recoloured in game; origin on the pole so it can wave). 2.9 m tall.
Run: tools/blender-run.ps1 art/scripts/props/tide_props.py [piece names...]
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

PI = math.pi


def G(x, y, z):
    """Godot position -> Blender location."""
    return (x, -z, y)


def GS(sx, sy, sz):
    """Godot box size -> Blender box size."""
    return (sx, sz, sy)


def gbox(b, size, center, mat, bevel=0.0, rot=(0, 0, 0)):
    b.box(GS(*size), G(*center), mat, bevel=bevel, rot=rot)


def stone_mats():
    return (M("stone", 0.95, name="TideStone", hexv="#a99d8c"), M("stone", 0.95, name="TideStoneDark", hexv="#8a7f72"),
            M("stone", 0.95, name="TideStoneLight", hexv="#c4b8a4"), M("dark_stone", 0.95, name="TideStoneUnder", hexv="#5a5249"))


def wall_mats():
    return (M("dark_stone", 0.95, name="WallBrick", hexv="#4d4b5c"), M("dark_stone", 0.95, name="WallBrickDark", hexv="#3f3d4d"),
            M("dark_stone", 0.95, name="WallMortar", hexv="#2c2a36"))


def wood_mats():
    return (M("wood", 0.85, name="CratePlank", hexv="#b5814f"), M("dark_wood", 0.85, name="CrateFrame", hexv="#6b4630"),
            M("charcoal", 0.5, 0.6, name="Iron", hexv="#3b3a40"))


# ---------------------------------------------------------------- slabs
def _slab(name, sx, sz, seed, gold=False, moss=False):
    """Stone slab sx x 0.9 x sz (base centre): a dark core, a course of blocks on every side face,
    flagstones on top."""
    new_piece()
    st, dark, light, under = stone_mats()
    rng = random.Random(seed)
    b = Builder(name, angle=40)
    h = 0.9
    gbox(b, (sx - 0.04, h - 0.06, sz - 0.04), (0, (h - 0.06) / 2, 0), under)
    # side faces: two courses of blocks, staggered
    for course in range(2):
        y0 = 0.06 + course * 0.4
        ch = 0.38
        for face, length, along in ((1, sx, "x"), (-1, sx, "x"), (1, sz, "z"), (-1, sz, "z")):
            n = max(1, round(length / 0.95))
            off = 0.5 if course % 2 else 0.0
            i = -off
            while i < n:
                a0 = max(i, 0.0) / n * length - length / 2
                a1 = min(i + 1, n) / n * length - length / 2
                i += 1
                if a1 - a0 < 0.2:
                    continue
                m = st if rng.random() < 0.55 else (dark if rng.random() < 0.6 else light)
                w = a1 - a0 - 0.05
                c = (a0 + a1) / 2
                if along == "x":
                    gbox(b, (w, ch, 0.1), (c, y0 + ch / 2, face * (sz / 2 - 0.03)), m, bevel=0.03)
                else:
                    gbox(b, (0.1, ch, w), (face * (sx / 2 - 0.03), y0 + ch / 2, c), m, bevel=0.03)
    # top flagstones
    nx = max(1, round(sx / 1.2))
    nz = max(1, round(sz / 1.2))
    for i in range(nx):
        for j in range(nz):
            x = -sx / 2 + sx * (i + 0.5) / nx
            z = -sz / 2 + sz * (j + 0.5) / nz
            m = light if (i + j) % 2 == 0 else st
            if moss and rng.random() < 0.3:
                m = M("green", 0.95, name="Moss", hexv="#6f8a5a")
            gbox(b, (sx / nx - 0.05, 0.08, sz / nz - 0.05), (x, h - 0.04, z), m, bevel=0.02)
    if gold:
        g = M("gold", 0.45, 0.4, name="TrimGold", hexv="#e8b33a")
        gbox(b, (sx + 0.06, 0.1, 0.12), (0, h - 0.18, sz / 2 + 0.02), g, bevel=0.03)
        for s in (-1, 1):
            gbox(b, (0.12, 0.1, sz + 0.06), (s * (sx / 2 + 0.02), h - 0.18, 0), g, bevel=0.03)
    return b.build()


def tide_shelf():
    ob = _slab("tide_shelf", 8.0, 3.6, 11)
    return finish("tide_shelf", [ob], expect_tris=(200, 6000))


def tide_roof():
    ob = _slab("tide_roof", 3.6, 3.6, 12, gold=True)
    return finish("tide_roof", [ob], expect_tris=(100, 4000))


def tide_floor():
    ob = _slab("tide_floor", 14.0, 3.6, 13, moss=True)
    return finish("tide_floor", [ob], expect_tris=(200, 8000))


# ---------------------------------------------------------------- back wall
def _wall(name, slits, seed):
    new_piece()
    brick, dark, mortar = wall_mats()
    glass = EM("EmitWindow", "#5f78b8", 0.6)
    frame = M("stone", 0.95, name="WindowStone", hexv="#6b6878")
    rng = random.Random(seed)
    b = Builder(name, angle=40)
    W, H, T = 14.0, 3.6, 0.6
    gbox(b, (W, H, T - 0.08), (0, H / 2, -T / 2 - 0.04), mortar)
    rows = 8
    rh = H / rows
    for r in range(rows):
        y = rh * (r + 0.5)
        off = 0.45 if r % 2 else 0.0
        x = -W / 2 - off
        while x < W / 2 - 0.05:
            w = rng.uniform(0.75, 1.05)
            x0, x1 = max(x, -W / 2), min(x + w, W / 2)
            x += w
            if x1 - x0 < 0.15:
                continue
            cx = (x0 + x1) / 2
            # leave the window slits open
            if any(abs(cx - s) < 0.42 + (x1 - x0) / 2 and 0.9 < y < 3.1 for s in slits):
                continue
            m = brick if rng.random() < 0.7 else dark
            gbox(b, (x1 - x0 - 0.05, rh - 0.05, 0.1), (cx, y, -0.05 + rng.uniform(-0.015, 0.015)), m, bevel=0.025)
    for s in slits:
        # recessed glowing slit with a pointed stone frame
        gbox(b, (0.36, 1.7, 0.05), (s, 2.0, -0.4), glass)
        for sx in (-1, 1):
            gbox(b, (0.22, 2.0, 0.42), (s + sx * 0.29, 2.0, -0.21), frame, bevel=0.03)
        gbox(b, (0.8, 0.22, 0.42), (s, 0.89, -0.21), frame, bevel=0.03)
        gbox(b, (0.8, 0.22, 0.42), (s, 3.11, -0.21), frame, bevel=0.03)
        gbox(b, (0.36, 0.18, 0.3), (s, 2.92, -0.25), frame, bevel=0.03)
    return b.build()


def tide_wall():
    return finish("tide_wall", [_wall("tide_wall", (-4.2, 4.2), 21)], expect_tris=(300, 9000))


def tide_wall_b():
    return finish("tide_wall_b", [_wall("tide_wall_b", (-6.0, -1.4, 1.4, 6.0), 22)], expect_tris=(300, 9000))


# ---------------------------------------------------------------- pillars
def tide_pillar():
    new_piece()
    st, dark, light, under = stone_mats()
    b = Builder("tide_pillar", angle=40)
    gbox(b, (0.86, 3.6, 0.86), (0, 1.8, 0), under)
    for k in range(6):
        y = 0.3 + 0.6 * k
        w = 1.0 if k % 2 == 0 else 0.94
        gbox(b, (w, 0.56, w), (0, y, 0), st if k % 3 else light, bevel=0.05)
    return finish("tide_pillar", [b.build()], expect_tris=(50, 3000))


def tide_pillar_top():
    new_piece()
    st, dark, light, under = stone_mats()
    b = Builder("tide_pillar_top", angle=40)
    rng = random.Random(5)
    for k in range(3):
        y = 0.3 + 0.6 * k
        w = 1.0 - 0.12 * k
        gbox(b, (w, 0.56, w), (rng.uniform(-0.05, 0.05), y, rng.uniform(-0.05, 0.05)), st if k % 2 else light,
             bevel=0.06, rot=(0, rng.uniform(-0.15, 0.15), rng.uniform(-0.08, 0.08)))
    for i in range(3):
        gbox(b, (0.3, 0.3, 0.3), (rng.uniform(-0.3, 0.3), 1.95 + 0.1 * i, rng.uniform(-0.3, 0.3)), dark, bevel=0.06,
             rot=(rng.uniform(0, 1), rng.uniform(0, 1), rng.uniform(0, 1)))
    return finish("tide_pillar_top", [b.build()], expect_tris=(50, 3000))


# ---------------------------------------------------------------- crates and blocks
def tide_crate():
    new_piece()
    plank, frame, iron = wood_mats()
    b = Builder("tide_crate", angle=40)
    W, H, D = 1.2, 0.9, 1.2
    gbox(b, (W - 0.08, H - 0.04, D - 0.08), (0, H / 2, 0), plank, bevel=0.02)
    # planks on the faces (grooves read as lines)
    for i in range(3):
        y = 0.12 + 0.3 * i + 0.03
        for s in (-1, 1):
            gbox(b, (W - 0.2, 0.24, 0.05), (0, y + 0.12 - 0.03, s * (D / 2 - 0.03)), plank, bevel=0.015)
            gbox(b, (0.05, 0.24, D - 0.2), (s * (W / 2 - 0.03), y + 0.12 - 0.03, 0), plank, bevel=0.015)
    # frame on the 12 edges
    t = 0.12
    for sx in (-1, 1):
        for sz in (-1, 1):
            gbox(b, (t, H, t), (sx * (W / 2 - t / 2), H / 2, sz * (D / 2 - t / 2)), frame, bevel=0.025)
    for y in (t / 2, H - t / 2):
        for s in (-1, 1):
            gbox(b, (W, t, t), (0, y, s * (D / 2 - t / 2)), frame, bevel=0.025)
            gbox(b, (t, t, D), (s * (W / 2 - t / 2), y, 0), frame, bevel=0.025)
    # diagonal braces front and back
    ang = math.atan2(H - 2 * t, W - 2 * t)
    ln = math.hypot(W - 2 * t, H - 2 * t)
    for s in (-1, 1):
        gbox(b, (ln, 0.1, 0.05), (0, H / 2, s * (D / 2 + 0.005)), frame, rot=(0, ang, 0))
    # iron corner caps
    for sx in (-1, 1):
        for sz in (-1, 1):
            gbox(b, (0.16, 0.06, 0.16), (sx * (W / 2 - 0.07), H - 0.025, sz * (D / 2 - 0.07)), iron)
    return finish("tide_crate", [b.build()], expect_tris=(100, 3000))


def _crack(b, pts, mat):
    """A crack line along Godot points (thin dark tube just proud of the surface)."""
    b.tube([Vector(G(*p)) for p in pts], 0.022, mat, sides=4)


def tide_block_cracked():
    new_piece()
    sand = M("stone", 0.95, name="Sandstone", hexv="#d1b48a")
    sand_dark = M("stone", 0.95, name="SandstoneDark", hexv="#b69568")
    crack = M("charcoal", 0.9, name="Crack", hexv="#3a2018")
    b = Builder("tide_block_cracked", angle=40)
    W, H, D = 1.2, 0.9, 1.2
    gbox(b, (W - 0.04, H - 0.04, D - 0.04), (0, H / 2, 0), sand, bevel=0.06)
    gbox(b, (W - 0.1, 0.08, D - 0.1), (0, H - 0.03, 0), sand_dark, bevel=0.03)
    f = D / 2 + 0.005
    _crack(b, [(-0.55, 0.75, f), (-0.25, 0.55, f), (-0.05, 0.62, f), (0.2, 0.35, f), (0.5, 0.15, f)], crack)
    _crack(b, [(-0.2, 0.55, f), (-0.3, 0.2, f), (-0.15, 0.05, f)], crack)
    _crack(b, [(-0.55, 0.3, -f), (0.0, 0.5, -f), (0.55, 0.7, -f)], crack)
    t = H + 0.005
    _crack(b, [(-0.55, t, -0.3), (-0.1, t, -0.05), (0.15, t, 0.3), (0.5, t, 0.5)], crack)
    _crack(b, [(-0.1, t, -0.05), (0.3, t, -0.45)], crack)
    s = W / 2 + 0.005
    for sx in (-1, 1):
        _crack(b, [(sx * s, 0.8, -0.4), (sx * s, 0.45, 0.0), (sx * s, 0.2, 0.45)], crack)
    return finish("tide_block_cracked", [b.build()], expect_tris=(80, 3000))


def tide_ladder():
    new_piece()
    plank, frame, iron = wood_mats()
    tread = M("wood", 0.85, name="Tread", hexv="#cf9a62")
    b = Builder("tide_ladder", angle=40)
    for j in range(1, 6):
        top = 0.6 * j
        x0, x1 = 0.72 * (5 - j), 0.72 * (6 - j)
        cx = (x0 + x1) / 2
        gbox(b, (0.72 - 0.06, top - 0.06, 1.0), (cx, (top - 0.06) / 2, 0), plank, bevel=0.02)
        gbox(b, (0.76, 0.08, 1.2), (cx - 0.02, top - 0.04, 0), tread, bevel=0.02)
        for s in (-1, 1):
            gbox(b, (0.08, top, 0.08), (x1 - 0.06, top / 2, s * 0.52), frame, bevel=0.02)
    # side stringers
    ln = math.hypot(3.6, 3.0)
    ang = math.atan2(3.0, 3.6)
    for s in (-1, 1):
        gbox(b, (ln + 0.2, 0.14, 0.08), (1.8, 1.5 + 0.2, s * 0.56), frame, bevel=0.03, rot=(0, ang, 0))
    return finish("tide_ladder", [b.build()], expect_tris=(100, 3000))


# ---------------------------------------------------------------- awning
def tide_awning():
    new_piece()
    plank, frame, iron = wood_mats()
    red = M("red", 0.7, name="AwningRed", hexv="#d9483b")
    cream = M("cream", 0.7, name="AwningCream", hexv="#f3e6c8")
    b = Builder("tide_awning", angle=50)
    gbox(b, (1.2, 0.24, 1.2), (0, 0.12, 0), frame, bevel=0.03)
    for sx in (-1, 1):
        for sz in (-1, 1):
            b.cyl(0.07, 0.12, G(sx * 0.48, 0.24, sz * 0.48), iron, segs=8)  # springs
    n = 6
    arch = [(-0.6 + 1.2 * i / 10, 0.3 + 0.15 * math.sin(PI * i / 10)) for i in range(11)]
    poly = arch + [(0.6, 0.27), (-0.6, 0.27)]
    poly = [arch[0]] + arch[1:] + [(0.6, 0.27), (-0.6, 0.27)]
    poly = _dedupe_poly(poly)
    for k in range(n):
        z0 = -0.6 + 1.2 * k / n
        z1 = z0 + 1.2 / n
        b.prism(poly, z0, z1, red if k % 2 == 0 else cream, rot=(PI / 2, 0, 0))
    # scalloped valance on the front and back
    for s in (-1, 1):
        for i in range(6):
            x = -0.5 + 0.2 * i
            b.sphere(0.1, G(x, 0.27, s * 0.62), red if i % 2 else cream, scale=(1, 0.3, 1), segs=8, rings=4)
    return finish("tide_awning", [b.build()], expect_tris=(100, 3000))


def _dedupe_poly(p):
    out = []
    for q in p:
        if not out or abs(out[-1][0] - q[0]) > 1e-6 or abs(out[-1][1] - q[1]) > 1e-6:
            out.append(q)
    return out


# ---------------------------------------------------------------- hanging platform, chain, beam
def tide_hanging():
    new_piece()
    plank, frame, iron = wood_mats()
    light = M("wood", 0.85, name="HangPlank", hexv="#c89460")
    b = Builder("tide_hanging", angle=40)
    W, T, D = 1.0, 0.3, 1.2
    for i in range(4):
        z = -D / 2 + D * (i + 0.5) / 4
        gbox(b, (W, 0.12, D / 4 - 0.03), (0, -0.06, z), light if i % 2 else plank, bevel=0.02)
    gbox(b, (W + 0.04, 0.16, 0.12), (0, -0.2, -D / 2 + 0.06), frame, bevel=0.02)
    gbox(b, (W + 0.04, 0.16, 0.12), (0, -0.2, D / 2 - 0.06), frame, bevel=0.02)
    for s in (-1, 1):
        gbox(b, (0.1, 0.18, D), (s * (W / 2 - 0.05), -0.18, 0), iron, bevel=0.02)
        b.tube([Vector(G(s * 0.35, 0.0, 0.0)), Vector(G(s * 0.35, 0.16, 0.0))], 0.03, iron, sides=6)
        b.cyl(0.09, 0.04, G(s * 0.35, 0.16, 0.0), iron, segs=10, rot=(PI / 2, 0, 0))
    return finish("tide_hanging", [b.build()], expect_tris=(80, 3000))


def tide_chain():
    new_piece()
    iron = M("charcoal", 0.45, 0.7, name="ChainIron", hexv="#55535c")
    b = Builder("tide_chain", angle=60)
    n = 8
    L = 1.0 / n
    for i in range(n):
        y = -L * (i + 0.5)
        hw, hh = 0.045, L * 0.62
        loop = [G(-hw, y - hh, 0), G(hw, y - hh, 0), G(hw, y + hh, 0), G(-hw, y + hh, 0), G(-hw, y - hh, 0)]
        rot = (0, 0, PI / 2) if i % 2 else (0, 0, 0)
        b.tube([Vector(p) for p in loop], 0.016, iron, sides=4, caps=False,
               xf=Matrix.Translation(Vector(G(0, y, 0))) @ Euler(rot).to_matrix().to_4x4() @ Matrix.Translation(-Vector(G(0, y, 0))))
    return finish("tide_chain", [b.build()], expect_tris=(50, 2000))


def tide_beam():
    new_piece()
    plank, frame, iron = wood_mats()
    b = Builder("tide_beam", angle=40)
    gbox(b, (4.4, 0.35, 0.35), (0, 0, 0), frame, bevel=0.04)
    for x in (-1.8, -0.6, 0.6, 1.8):
        gbox(b, (0.08, 0.39, 0.39), (x, 0, 0), iron)
    return finish("tide_beam", [b.build()], expect_tris=(30, 2000))


# ---------------------------------------------------------------- torch and flag
def tide_torch():
    new_piece()
    plank, frame, iron = wood_mats()
    flame = EM("EmitFlame", "#ffb347", 3.0)
    core = EM("EmitFlameCore", "#fff1b8", 4.0)
    b = Builder("tide_torch", angle=40)
    gbox(b, (0.22, 0.34, 0.05), (0, 0.1, 0.025), iron, bevel=0.01)
    b.tube([Vector(G(0, 0.05, 0.03)), Vector(G(0, 0.05, 0.22)), Vector(G(0, 0.2, 0.3))], 0.025, iron, sides=6)
    b.cyl(0.045, 0.5, G(0, 0.0, 0.3), frame, segs=8, rot=(0.25, 0, 0))
    b.cyl(0.075, 0.1, G(0, 0.42, 0.3 + 0.1), iron, segs=8)
    b.ico(0.13, G(0, 0.62, 0.42), flame, subdiv=1, scale=(1, 1, 1.6))
    b.ico(0.07, G(0, 0.6, 0.42), core, subdiv=1, scale=(1, 1, 1.4))
    return finish("tide_torch", [b.build()], expect_tris=(50, 2000))


def tide_flag():
    new_piece()
    st, dark, light, under = stone_mats()
    dw = M("dark_wood", 0.85)
    gold = M("gold", 0.4, 0.45, name="FlagGold", hexv="#e8b33a")
    pb = Builder("Pole", angle=40)
    prof, _ = rrect(0, 0.42, 0, 0.3, 0.05, 0.02, 2)
    pb.lathe(prof, light, segs=8)
    pb.cyl(0.07, 2.5, G(0, 0.3, 0), dw, segs=8)
    pb.sphere(0.14, G(0, 2.9, 0), gold, segs=10, rings=6)
    pole = pb.build()
    cloth = M("cream", 0.8, name="FlagCloth", hexv="#f3e6c8")
    fb = Builder("Flag", angle=60)
    n = 6
    bottom = [(1.5 * i / n, -0.45 + 0.06 * math.sin(i * 1.5)) for i in range(n + 1)]
    top = [(1.5 * i / n, 0.45 + 0.06 * math.sin(i * 1.5)) for i in range(n, -1, -1)]
    poly = bottom + [(1.38, 0.0)] + top
    poly = _dedupe_poly(poly)
    # swallow-tailed banner: the notch is the extra (1.38, 0) point
    poly = bottom[:-1] + [(1.5, bottom[-1][1]), (1.2, 0.0), (1.5, top[0][1])] + top[1:]
    fb.prism(poly, -0.025, 0.025, cloth, rot=(PI / 2, 0, 0))
    flag = fb.build(loc=G(0.06, 2.3, 0))
    bpy.context.view_layer.update()
    artlib.set_parent(flag, pole)
    return finish("tide_flag", [pole, flag], expect_tris=(60, 2500))


ALL = [tide_shelf, tide_roof, tide_floor, tide_wall, tide_wall_b, tide_pillar, tide_pillar_top, tide_crate,
       tide_block_cracked, tide_ladder, tide_awning, tide_hanging, tide_chain, tide_beam, tide_torch, tide_flag]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
