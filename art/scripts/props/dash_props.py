"""Mansion Dash props: a toy obstacle course through the mansion gardens.

Pieces (Godot metres; the course runs along -Z, x in [-4.5, 4.5], ground top y = 0):
  dash_course       the whole ground: gravel path, wooden log ramp (z 5 -> -5 up to 1.2 m, flat top to -7.5,
                    down to 0 at -10.5), the pond basin (z -11.6 .. -21.4, floor -1.8), start/finish stripes.
                    Origin at the world origin.
  dash_border       10 m hedge strip along Z, 0.8 wide, 1.3 tall (course sides). Origin base centre.
  dash_hedge        2 x 1 x 1.3 m hedge block (slalom, walls). Origin base centre.
  dash_hammer_frame one rail along the hammer alley with the 4 pivot hubs (y 6.4), gantries at both ends.
  dash_hammer       origin at the pivot; arm hangs down -Y, head (capsule along X, r 0.48, 1.5 long) centred
                    5.6 m below the pivot.
  dash_log          rolling log, origin at its centre, axis along X, 2.6 long, radius 0.32.
  dash_platform     floating raft 2.8 (x) x 2.3 (z), origin at the centre of its TOP (walk surface y = 0).
  dash_flag         checkpoint flag: Pole + separate object Flag (material FlagCloth, recoloured in game);
                    Flag's origin sits on the pole so it can wave. Origin base centre.
  dash_start_gate   arch over the start line, inner width 9.4. Origin base centre.
  dash_finish_arch  checkered finish arch, inner width 9.4. Origin base centre.
  dash_disc         turntable, radius 3.9, top at y = 0.06. Origin at the centre, y = 0.
  dash_sweeper      Post (static) + Bar (7.4 m, spins about the post); bar centre 0.48 m above the origin.
Run: tools/blender-run.ps1 art/scripts/props/dash_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

PI = math.pi
HALF_W = 4.5
RAMP_Z0, RAMP_Z1, TOP_Z1, DOWN_Z1 = 5.0, -5.0, -7.5, -10.5
RAMP_H = 1.2
POND_Z0, POND_Z1 = -11.6, -21.4
POND_FLOOR = -1.8
COURSE_Z0, COURSE_Z1 = 36.5, -45.0


def G(x, y, z):
    """Godot position -> Blender location."""
    return (x, -z, y)


def GS(sx, sy, sz):
    """Godot box size -> Blender box size."""
    return (sx, sz, sy)


def gbox(b, size, center, mat, bevel=0.0, rot=(0, 0, 0)):
    b.box(GS(*size), G(*center), mat, bevel=bevel, rot=rot)


def hedge_mats():
    return (M("green", 0.85, name="Hedge", hexv="#4f9a4a"), M("green", 0.85, name="HedgeDark", hexv="#3b7a3d"),
            M("green", 0.85, name="HedgeLight", hexv="#6cb85a"))


def _hedge_body(b, sx, sz, h, seed, flowers=True):
    """Hedge of Godot size sx (x) by sz (z), h tall, base at y = 0, centred on the origin."""
    leaf, dark, light = hedge_mats()
    gbox(b, (sx, 0.22, sz), (0, 0.11, 0), dark, bevel=0.05)
    gbox(b, (sx - 0.06, h - 0.3, sz - 0.06), (0, 0.15 + (h - 0.3) / 2, 0), leaf, bevel=0.12)
    # lumpy top: a row of squashed balls along the long side
    rng = random.Random(seed)
    long_x = sx >= sz
    length = sx if long_x else sz
    n = max(2, round(length / 0.9))
    for i in range(n):
        u = -length / 2 + length * (i + 0.5) / n
        r = (min(sx, sz) / 2) * rng.uniform(0.85, 1.0)
        x, z = (u, rng.uniform(-0.04, 0.04)) if long_x else (rng.uniform(-0.04, 0.04), u)
        b.ico(r, G(x, h - 0.32, z), light if i % 3 == 1 else leaf, subdiv=1,
              scale=(1.05 if long_x else 0.9, 1.05 if not long_x else 0.9, 0.62), fn=lumps(seed * 31 + i, 4, 0.12))
    if flowers:
        pink = M("red", 0.7, name="Blossom", hexv="#f08fb0")
        cream = M("cream", 0.8)
        for i in range(max(1, n // 2)):
            u = -length / 2 + length * (i * 2 + 1) / (n + 1)
            side = 1 if i % 2 == 0 else -1
            off = (min(sx, sz) / 2 + 0.01) * side
            x, z = (u, off) if long_x else (off, u)
            b.ico(0.07, G(x, h * rng.uniform(0.45, 0.75), z), pink if i % 2 == 0 else cream, subdiv=1)


# ---------------------------------------------------------------- hedges
def dash_hedge():
    """2 x 1 x 1.3 m hedge block."""
    new_piece()
    b = Builder("dash_hedge", angle=45)
    _hedge_body(b, 2.0, 1.0, 1.3, 3)
    return finish("dash_hedge", [b.build()], expect_tris=(100, 2500))


def dash_border():
    """10 m hedge strip along Godot Z, 0.8 wide, 1.3 tall, on a low stone kerb."""
    new_piece()
    b = Builder("dash_border", angle=45)
    stone = M("stone", 0.95, name="Kerb", hexv="#a99c90")
    gbox(b, (0.95, 0.12, 10.0), (0, 0.06, 0), stone, bevel=0.03)
    _hedge_body(b, 0.8, 10.0, 1.3, 11, flowers=True)
    return finish("dash_border", [b.build()], expect_tris=(100, 2500))


# ---------------------------------------------------------------- hammer
HAMMER_Z = (17.0, 14.2, 11.4, 8.6)
HAMMER_MID = 12.8


def dash_hammer_frame():
    """Hammer alley: one overhead rail along the course (x = 0, y 6.6) carrying the four pivot hubs
    (y = 6.4 at Godot z = HAMMER_Z, relative to the origin at HAMMER_MID), held by a striped gantry
    at each end (posts at x = +-5.8, outside the course). Origin at the ground below the rail centre."""
    new_piece()
    red, cream = M("red", 0.7), M("cream", 0.8)
    dw, gold = M("dark_wood", 0.85), M("gold", 0.45, 0.4)
    b = Builder("dash_hammer_frame", angle=40)
    ends = (19.0 - HAMMER_MID, 7.0 - HAMMER_MID)
    for ez in ends:
        for sx in (-1, 1):
            x = sx * 5.8
            gbox(b, (0.8, 0.3, 0.8), (x, 0.15, ez), dw, bevel=0.05)
            n = 6
            for i in range(n):
                y0 = 0.3 + (6.9 - 0.3) * i / n
                y1 = 0.3 + (6.9 - 0.3) * (i + 1) / n
                gbox(b, (0.34, y1 - y0, 0.34), (x, (y0 + y1) / 2, ez), red if i % 2 == 0 else cream)
            b.sphere(0.26, G(x, 7.15, ez), gold, segs=10, rings=5)
            b.tube([G(x, 0.3, ez + (1.1 if ez > 0 else -1.1)), G(x, 2.4, ez)], 0.08, dw, sides=5)
        gbox(b, (12.0, 0.4, 0.4), (0, 6.9, ez), dw, bevel=0.04)
        gbox(b, (2.2, 0.5, 0.5), (0, 6.9, ez), gold, bevel=0.06)
    # the rail along the course and the four pivot hubs
    gbox(b, (0.3, 0.3, ends[0] - ends[1]), (0, 6.75, (ends[0] + ends[1]) / 2), dw, bevel=0.03)
    for hz in HAMMER_Z:
        z = hz - HAMMER_MID
        b.cyl(0.24, 0.5, G(0, 6.4, z - 0.25), gold, segs=10, bevel=0.04, rot=(PI / 2, 0, 0))
        gbox(b, (0.42, 0.3, 0.42), (0, 6.65, z), gold, bevel=0.05)
    return finish("dash_hammer_frame", [b.build()], expect_tris=(100, 2500))


def dash_hammer():
    """Swinging mallet: origin at the pivot, head centre 5.6 m below, head axis along X."""
    new_piece()
    red, cream = M("red", 0.6), M("cream", 0.8)
    dw, gold = M("dark_wood", 0.85), M("gold", 0.4, 0.45)
    b = Builder("dash_hammer", angle=40)
    L = 5.6
    b.cyl(0.11, L - 0.4, G(0, -(L - 0.4), 0), dw, segs=10)
    b.cyl(0.16, 0.5, G(0, -0.25, 0), gold, segs=12, bevel=0.04)
    # head: barrel along X with red body, cream bands and gold faces
    R, half = 0.48, 0.75

    def hmat(r, z):
        if abs(z) > half - 0.08:
            return gold
        if abs(abs(z) - 0.42) < 0.09:
            return cream
        return red
    prof = [(0.0, -half), (R - 0.12, -half), (R - 0.02, -half + 0.06), (R, -half + 0.16), (R, -0.51),
            (R + 0.03, -0.49), (R + 0.03, -0.33), (R, -0.31), (R, 0.31), (R + 0.03, 0.33), (R + 0.03, 0.49),
            (R, 0.51), (R, half - 0.16), (R - 0.02, half - 0.06), (R - 0.12, half), (0.0, half)]
    b.lathe(prof, hmat, segs=20, rot=(0, PI / 2, 0), loc=G(0, -L, 0))
    gbox(b, (0.3, 0.3, 0.3), (0, -L + 0.48, 0), gold, bevel=0.05)
    return finish("dash_hammer", [b.build()], expect_tris=(100, 2500))


# ---------------------------------------------------------------- log
def dash_log():
    """Rolling log along X, 2.6 m, radius 0.32, origin at its centre."""
    new_piece()
    bark = M("wood", 0.9, name="Bark", hexv="#7a4e33")
    bark2 = M("dark_wood", 0.9, name="BarkDark", hexv="#5b3a29")
    ring = M("cream", 0.85, name="LogEnd", hexv="#e6c48f")
    ring2 = M("wood", 0.85, name="LogRing", hexv="#c49660")
    b = Builder("dash_log", angle=35)
    R, half = 0.32, 1.3

    def lmat(r, z):
        if abs(z) >= half - 1e-4:
            return ring if (r < 0.1 or 0.17 < r < 0.24) else ring2
        return bark2 if int((z + half) / 0.65) % 2 else bark
    prof = [(0.0, -half), (0.1, -half), (0.17, -half), (0.24, -half), (R - 0.03, -half), (R, -half + 0.04)]
    for i in range(1, 8):
        z = -half + 2 * half * i / 8
        prof.append((R + (0.018 if i % 2 else -0.004), z if i < 8 else half - 0.04))
    prof += [(R, half - 0.04), (R - 0.03, half), (0.24, half), (0.17, half), (0.1, half), (0.0, half)]
    b.lathe(prof, lmat, segs=14, rot=(0, PI / 2, 0))
    # a couple of stubby branch knots so the roll reads
    for x, a in ((-0.7, 0.0), (0.45, 2.2)):
        d = (0.0, -math.sin(a), math.cos(a))  # Blender Z turned about X by a
        b.cyl(0.07, 0.12, (x, d[1] * 0.28, d[2] * 0.28), bark2, segs=6, rot=(a, 0, 0), r_top=0.05)
    return finish("dash_log", [b.build()], expect_tris=(100, 2500))


# ---------------------------------------------------------------- platform
def dash_platform():
    """Floating raft 2.8 x 2.3, top surface at y = 0 (origin), barrels underneath."""
    new_piece()
    w1, w2 = M("wood", 0.85, name="Plank", hexv="#b98a5a"), M("wood", 0.85, name="PlankDark", hexv="#9a6c45")
    dw, teal, gold = M("dark_wood", 0.9), M("teal", 0.7), M("gold", 0.5, 0.3)
    b = Builder("dash_platform", angle=40)
    W, D = 2.8, 2.3
    n = 6
    for i in range(n):
        z = -D / 2 + D * (i + 0.5) / n
        gbox(b, (W, 0.16, D / n - 0.04), (0, -0.08, z), w1 if i % 2 else w2, bevel=0.025)
    for sx in (-1, 1):
        gbox(b, (0.16, 0.22, D + 0.04), (sx * (W / 2 - 0.08), -0.11, 0), dw, bevel=0.03)
        gbox(b, (W - 0.2, 0.08, 0.14), (0, -0.2, sx * 0.8), dw)
    # teal float barrels, half sunk
    for sx in (-0.85, 0.85):
        for sz in (-0.68, 0.68):
            b.cyl(0.3, 0.9, G(sx, -0.5, sz - 0.45), teal, segs=12, bevel=0.05, rot=(PI / 2, 0, 0))
            b.cyl(0.31, 0.06, G(sx, -0.5, sz - 0.03), gold, segs=12, rot=(PI / 2, 0, 0))
    return finish("dash_platform", [b.build()], expect_tris=(100, 2500))


# ---------------------------------------------------------------- flag
def dash_flag():
    """Checkpoint flag: Pole (with plinth and gold knob) and Flag (pennant, FlagCloth), 2.8 m tall."""
    new_piece()
    stone, dw, gold = M("stone", 0.95, name="Plinth", hexv="#bdb1a4"), M("dark_wood", 0.85), M("gold", 0.4, 0.45)
    pb = Builder("Pole", angle=40)
    prof, _ = rrect(0, 0.4, 0, 0.25, 0.05, 0.02, 2)
    pb.lathe(prof, stone, segs=8)
    pb.cyl(0.06, 2.6, G(0, 0.25, 0), dw, segs=8)
    pb.sphere(0.12, G(0, 2.9, 0), gold, segs=10, rings=6)
    pole = pb.build()
    cloth = M("cream", 0.8, name="FlagCloth", hexv="#f3e6c8")
    fb = Builder("Flag", angle=60)
    # pennant in the Godot XY plane, pointing +X from the pole, slightly wavy
    bottom = [(1.3 * i / 5, -0.38 * (1 - i / 5) + 0.05 * math.sin(i * 1.7)) for i in range(5)]
    top = [(1.3 * i / 5, 0.38 * (1 - i / 5) + 0.05 * math.sin(i * 1.7)) for i in range(4, -1, -1)]
    poly = bottom + [(1.3, 0.0)] + top
    # poly is in Godot (x, y); the prism is built flat, then stood up into the Godot XY plane
    fb.prism(poly, -0.025, 0.025, cloth, rot=(PI / 2, 0, 0))
    flag = fb.build(loc=G(0.05, 2.35, 0))
    bpy.context.view_layer.update()
    artlib.set_parent(flag, pole)
    return finish("dash_flag", [pole, flag], expect_tris=(60, 2500))


# ---------------------------------------------------------------- gates
def _pillar(b, x, h, mat, cap, base):
    gbox(b, (0.9, 0.3, 0.9), (x, 0.15, 0), base, bevel=0.05)
    gbox(b, (0.62, h - 0.6, 0.62), (x, 0.3 + (h - 0.6) / 2, 0), mat, bevel=0.06)
    gbox(b, (0.82, 0.3, 0.82), (x, h - 0.15, 0), cap, bevel=0.05)


def dash_start_gate():
    """Start gate: plum pillars outside the course (x = +-5.15), a cream banner beam with a teal stripe."""
    new_piece()
    plum, cream, teal = M("plum", 0.8), M("cream", 0.85), M("teal", 0.7)
    gold, stone = M("gold", 0.4, 0.45), M("stone", 0.95, name="Plinth", hexv="#bdb1a4")
    b = Builder("dash_start_gate", angle=40)
    for sx in (-1, 1):
        _pillar(b, sx * 5.15, 3.9, plum, gold, stone)
        b.ico(0.32, G(sx * 5.15, 4.25, 0), gold, subdiv=1)
    gbox(b, (10.6, 0.7, 0.36), (0, 3.45, 0), cream, bevel=0.06)
    gbox(b, (10.0, 0.18, 0.4), (0, 3.45, 0), teal)
    # pennant bunting under the beam
    cols = [M("red", 0.8), teal, M("gold", 0.6, name="Yellow", hexv="#f2c94c"), M("blue", 0.8)]
    for i in range(12):
        x = -4.4 + 8.8 * i / 11
        tri = [(-0.22, 0.0), (0.22, 0.0), (0.0, -0.42)]
        b.prism(tri, -0.02, 0.02, cols[i % 4], loc=G(x, 3.05, 0), rot=(PI / 2, 0, 0))
    return finish("dash_start_gate", [b.build()], expect_tris=(100, 2500))


def dash_finish_arch():
    """Finish arch: gold-capped teal pillars at x = +-5.15, a black/white checkered banner, balloons on top."""
    new_piece()
    teal, gold, cream = M("teal", 0.7), M("gold", 0.4, 0.45), M("cream", 0.85)
    blk, wht = M("charcoal", 0.8, name="CheckDark", hexv="#2e2a33"), M("cream", 0.8, name="CheckLight", hexv="#f7f2e6")
    stone = M("stone", 0.95, name="Plinth", hexv="#bdb1a4")
    b = Builder("dash_finish_arch", angle=40)
    for sx in (-1, 1):
        _pillar(b, sx * 5.15, 4.4, teal, gold, stone)
    # checkered banner: 2 rows of squares across 10.6 m
    n = 16
    for i in range(n):
        x = -5.3 + 10.6 * (i + 0.5) / n
        for j in range(2):
            gbox(b, (10.6 / n, 0.4, 0.4), (x, 3.85 + 0.4 * j, 0), blk if (i + j) % 2 else wht)
    gbox(b, (10.8, 0.12, 0.46), (0, 3.6, 0), gold, bevel=0.03)
    gbox(b, (10.8, 0.12, 0.46), (0, 4.7, 0), gold, bevel=0.03)
    # balloons
    bal = [M("red", 0.5, name="BalloonRed", hexv="#e8574a"), M("blue", 0.5, name="BalloonBlue", hexv="#4f8fe6"),
           M("gold", 0.5, name="BalloonYellow", hexv="#f2c94c"), M("green", 0.5, name="BalloonGreen", hexv="#62c46f")]
    for sx in (-1, 1):
        for k, (dx, dy, dz) in enumerate(((0, 0.75, 0), (0.35, 0.55, 0.15), (-0.32, 0.6, -0.12))):
            b.sphere(0.3, G(sx * 5.15 + dx, 4.4 + dy, dz), bal[(k + (1 if sx > 0 else 0)) % 4], segs=10, rings=7,
                     scale=(1, 1, 1.18))
    b.sphere(0.36, G(0, 5.15, 0), cream, segs=12, rings=7)
    star = M("gold", 0.4, 0.5, name="StarGold", hexv="#ffd447")
    b.prism(star_poly(0.5, 0.22, 5), -0.06, 0.06, star, loc=G(0, 5.25, 0.0), rot=(PI / 2, 0, 0))
    return finish("dash_finish_arch", [b.build()], expect_tris=(100, 2500))


# ---------------------------------------------------------------- spinner
def dash_disc():
    """Turntable radius 3.9, top at y = 0.06, pie wedges so the turn reads, gold rim."""
    new_piece()
    teal, cream, gold = M("teal", 0.75), M("cream", 0.85), M("gold", 0.45, 0.4)
    plum = M("plum", 0.8)
    b = Builder("dash_disc", angle=40)
    R, top = 3.9, 0.06
    prof = [(0.0, -0.24), (R - 0.05, -0.24), (R, -0.2), (R, top - 0.03), (R - 0.04, top), (R - 0.16, top),
            (R - 0.16, top - 0.005)]
    b.lathe(prof, gold, segs=40, closed=False)
    n = 12
    for k in range(n):
        a0, a1 = TAU * k / n, TAU * (k + 1) / n
        pts = [(0.0, 0.0)]
        for i in range(5):
            a = a0 + (a1 - a0) * i / 4
            pts.append(((R - 0.16) * math.cos(a), (R - 0.16) * math.sin(a)))
        b.prism(pts, top - 0.01, top, teal if k % 2 else cream, caps=True)
    b.cyl(0.6, 0.02, (0, 0, top), plum, segs=16)
    return finish("dash_disc", [b.build()], expect_tris=(100, 2500))


def dash_sweeper():
    """Post (static, r 0.35) and Bar (7.4 m padded sweeper, centre 0.48 m up), both origins at the base centre."""
    new_piece()
    red, cream, gold, dw = M("red", 0.75), M("cream", 0.85), M("gold", 0.45, 0.4), M("dark_wood", 0.85)
    pb = Builder("Post", angle=35)
    pb.lathe([(0, 0), (0.35, 0), (0.35, 1.0), (0.0, 1.0)], dw, segs=16)
    prof, _ = rrect(0, 0.42, 0.95, 1.12, 0.06, 0.02, 2)
    pb.lathe(prof, gold, segs=16)
    post = pb.build()
    bb = Builder("Bar", angle=40)
    L, r, zc = 7.4, 0.18, 0.48
    n_sec = 10
    sec = (L - 0.6) / n_sec
    z0 = -sec * n_sec / 2
    prof = [(0.0, -L / 2), (r * 0.7, -L / 2), (r, -L / 2 + 0.12)]
    for i in range(n_sec):
        za = z0 + i * sec
        prof += [(r * 0.94, za), (r * 1.05, za + 0.08), (r * 1.05, za + sec - 0.08), (r * 0.94, za + sec)]
    prof += [(r, L / 2 - 0.12), (r * 0.7, L / 2), (0.0, L / 2)]

    def mat(rm, zm):
        if zm < z0 or zm > -z0:
            return gold
        return red if int((zm - z0) // sec) % 2 == 0 else cream
    bb.lathe(prof, mat, segs=10, rot=(0, PI / 2, 0), loc=(0, 0, zc))
    prof, _ = rrect(0, 0.45, zc - 0.25, zc + 0.25, 0.06, 0.06, 2)
    bb.lathe(prof, gold, segs=16)
    bar = bb.build()
    return finish("dash_sweeper", [post, bar], expect_tris=(100, 2500))


# ---------------------------------------------------------------- course ground
def dash_course():
    """The ground of the whole course (see module doc). Origin at the world origin."""
    new_piece()
    gravel, gravel2 = M("cream", 0.95, name="Gravel", hexv="#e3d3ad"), M("cream", 0.95, name="GravelDark", hexv="#d2be93")
    kerb, dark = M("stone", 0.95, name="Kerb", hexv="#a99c90"), M("dark_stone", 0.95, name="BasinStone", hexv="#5d6a6e")
    p1, p2 = M("wood", 0.85, name="Plank", hexv="#b98a5a"), M("wood", 0.85, name="PlankDark", hexv="#9a6c45")
    dw, white = M("dark_wood", 0.9), M("cream", 0.8, name="LineWhite", hexv="#f7f2e6")
    blk = M("charcoal", 0.8, name="CheckDark", hexv="#2e2a33")
    basin = M("teal", 0.95, name="PondFloor", hexv="#1d4a52")
    gold = M("gold", 0.6, name="LineGold", hexv="#e8b33a")
    b = Builder("dash_course", angle=30)
    W = HALF_W
    # flat gravel strips (top y = 0) with alternating bands every 3 m so motion reads
    def strip(z0, z1):
        n = max(1, round((z0 - z1) / 3.0))
        for i in range(n):
            za = z0 - (z0 - z1) * i / n
            zb = z0 - (z0 - z1) * (i + 1) / n
            gbox(b, (2 * W, 0.3, za - zb), (0, -0.15, (za + zb) / 2), gravel if i % 2 == 0 else gravel2)
    strip(COURSE_Z0, RAMP_Z0)
    strip(DOWN_Z1, POND_Z0)
    strip(POND_Z1, COURSE_Z1)
    # side kerbs along the whole course
    for sx in (-1, 1):
        gbox(b, (0.3, 0.32, COURSE_Z0 - COURSE_Z1), (sx * (W + 0.15), -0.14, (COURSE_Z0 + COURSE_Z1) / 2), kerb)
    # log ramp: planks up, flat top, planks down, with stone retaining sides
    def slope(z0, y0, z1, y1, n):
        for i in range(n):
            za, zb = z0 + (z1 - z0) * i / n, z0 + (z1 - z0) * (i + 1) / n
            ya, yb = y0 + (y1 - y0) * i / n, y0 + (y1 - y0) * (i + 1) / n
            length = math.hypot(zb - za, yb - ya)
            ang = math.atan2(yb - ya, abs(zb - za)) * (1 if zb < za else -1)
            gbox(b, (2 * W, 0.2, length - 0.03), (0, (ya + yb) / 2 - 0.1, (za + zb) / 2), p1 if i % 2 else p2,
                 rot=(ang, 0, 0))
    slope(RAMP_Z0, 0.0, RAMP_Z1, RAMP_H, 10)
    slope(RAMP_Z1, RAMP_H, TOP_Z1, RAMP_H, 3)
    slope(TOP_Z1, RAMP_H, DOWN_Z1, 0.0, 4)
    # retaining walls of the ramp (stone wedges on both sides)
    for sx in (-1, 1):
        poly = [(RAMP_Z0, -0.3), (RAMP_Z0, 0.0), (RAMP_Z1, RAMP_H + 0.15), (TOP_Z1, RAMP_H + 0.15),
                (DOWN_Z1, 0.0), (DOWN_Z1, -0.3)]
        _wedge(b, sx * (W + 0.2), poly, kerb)
    # dark wood log catcher trough at the ramp foot
    gbox(b, (2 * W, 0.08, 0.5), (0, 0.0, RAMP_Z0 + 0.6), dw)
    # pond basin: floor and stone walls
    gbox(b, (2 * W, 0.2, POND_Z0 - POND_Z1), (0, POND_FLOOR - 0.1, (POND_Z0 + POND_Z1) / 2), basin)
    for z in (POND_Z0, POND_Z1):
        gbox(b, (2 * W, -POND_FLOOR, 0.3), (0, POND_FLOOR / 2, z + (0.15 if z == POND_Z0 else -0.15)), dark)
    for sx in (-1, 1):
        gbox(b, (0.3, -POND_FLOOR, POND_Z0 - POND_Z1), (sx * (W + 0.15), POND_FLOOR / 2, (POND_Z0 + POND_Z1) / 2), dark)
    # bank edging stones
    for z in (POND_Z0 + 0.15, POND_Z1 - 0.15):
        gbox(b, (2 * W, 0.06, 0.3), (0, 0.0, z), kerb)
    # start line (white) and finish line (checker)
    gbox(b, (2 * W, 0.02, 0.3), (0, 0.005, 32.5), white)
    n = 18
    for i in range(n):
        for j in range(2):
            x = -W + 2 * W * (i + 0.5) / n
            gbox(b, (2 * W / n, 0.02, 0.35), (x, 0.006, -38.0 + 0.175 - 0.35 * j), blk if (i + j) % 2 else white)
    # checkpoint lines (gold)
    for z, y in ((6.6, 0.0), (-11.1, 0.0), (-22.4, 0.0)):
        gbox(b, (2 * W, 0.02, 0.18), (0, y + 0.005, z), gold)
    return finish("dash_course", [b.build()], expect_tris=(200, 2500))


def _wedge(b, x, pts_zy, mat):
    """A 0.4 m thick stone wall at Godot x whose side profile is the closed polygon [(godot_z, y)]."""
    tmp = bmesh.new()
    lo = [tmp.verts.new((x - 0.2, -z, y)) for z, y in pts_zy]
    hi = [tmp.verts.new((x + 0.2, -z, y)) for z, y in pts_zy]
    mi = b.mi(mat)
    n = len(pts_zy)
    fs = [tmp.faces.new(hi), tmp.faces.new(lo[::-1])]
    for i in range(n):
        j = (i + 1) % n
        fs.append(tmp.faces.new([lo[i], lo[j], hi[j], hi[i]]))
    for f in fs:
        f.material_index = mi
    bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
    b.raw(tmp)


ALL = [dash_course, dash_border, dash_hedge, dash_hammer_frame, dash_hammer, dash_log, dash_platform, dash_flag,
       dash_start_gate, dash_finish_arch, dash_disc, dash_sweeper]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
