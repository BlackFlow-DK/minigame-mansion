"""Hot Potato props: bomb (Bomb + Fuse + EmitSpark objects), crate, barrel, fence_segment_2m, arena_floor_disc.

Run: tools/blender-run.ps1 art/scripts/props/potato.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib


def bomb():
    """Round cartoon bomb ~0.45 m. Origin at body centre. Separate objects: Bomb, Fuse, EmitSpark."""
    new_piece()
    R = 0.225
    char, ds, red, cream = M("charcoal", 0.35), M("dark_stone", 0.6), M("red", 0.6), M("cream", 0.7)
    b = Builder("Bomb", angle=40)
    b.sphere(R, (0, 0, 0), char, segs=20, rings=12)
    # neck: dark cap sitting on top of the ball
    b.lathe([(0, 0.17), (0.085, 0.17), (0.085, 0.235), (0.1, 0.25), (0.1, 0.275), (0.075, 0.29), (0, 0.29)],
            ds, segs=12)
    # red collar
    b.lathe([(0.09, 0.2), (0.115, 0.2), (0.115, 0.226), (0.09, 0.226)], red, segs=12, solid=False)
    # glossy highlight blob (upper left front)
    d = Vector((-0.4, -0.7, 0.6)).normalized()
    rot = Vector((0, 0, 1)).rotation_difference(d).to_euler()
    b.sphere(0.055, d * (R - 0.01), cream, scale=(1.4, 0.8, 0.3), segs=10, rings=6, rot=rot)
    body = b.build()

    neck_top = Vector((0, 0, 0.29))
    fb = Builder("Fuse", angle=60)
    path = [(0, 0, 0), (0.005, 0, 0.05), (0.035, 0.0, 0.1), (0.085, 0.0, 0.125), (0.13, 0.0, 0.115)]
    fb.tube(path, 0.02, M("wood", 0.9), sides=5)
    fuse = fb.build(loc=neck_top)

    tip = neck_top + Vector((0.13, 0, 0.115))
    spark = EM("EmitSpark", "#ffb02e", 4.0)
    sb = Builder("EmitSpark", angle=90)
    pts = star_poly(0.085, 0.03, 4, rot=math.pi / 4)
    sb.prism(pts, -0.012, 0.012, spark)
    sb.prism(pts, -0.012, 0.012, spark, rot=(math.pi / 2, 0, 0))
    sb.prism(star_poly(0.06, 0.025, 4, rot=0), -0.012, 0.012, spark, rot=(0, math.pi / 2, 0))
    sb.sphere(0.035, (0, 0, 0), spark, segs=8, rings=5)
    sp = sb.build(loc=tip)
    return finish("bomb", [body, fuse, sp])


def crate():
    """0.9 m wooden crate, origin at base centre."""
    new_piece()
    w, dw = M("wood", 0.85), M("dark_wood", 0.85)
    b = Builder("crate", angle=35)
    b.box((0.86, 0.86, 0.86), (0, 0, 0.45), w, bevel=0.02)
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.box((0.11, 0.11, 0.9), (sx * 0.395, sy * 0.395, 0.45), dw, bevel=0.02)
    for z in (0.05, 0.85):
        for s in (-1, 1):
            b.box((0.7, 0.1, 0.1), (0, s * 0.4, z), dw, bevel=0.02)
            b.box((0.1, 0.7, 0.1), (s * 0.4, 0, z), dw, bevel=0.02)
    for s in (-1, 1):
        for t in (-1, 1):  # diagonal braces on the four sides
            b.box((0.96, 0.05, 0.085), (0, s * 0.445, 0.45), dw, bevel=0.012, rot=(0, t * math.radians(45), 0))
            b.box((0.05, 0.96, 0.085), (s * 0.445, 0, 0.45), dw, bevel=0.012, rot=(t * math.radians(45), 0, 0))
    ob = b.build()
    return finish("crate", [ob])


def barrel():
    """0.75 m tall wooden barrel with metal hoops, origin at base centre."""
    new_piece()
    wood, dw, hoop = M("wood", 0.85), M("dark_wood", 0.85), M("charcoal", 0.5, 0.3)
    H = 0.72
    hoops = [(0.09, 0.17), (0.3, 0.38), (0.55, 0.63)]

    def rad(z):
        return 0.27 + 0.09 * math.sin(math.pi * z / H)
    prof = [(0.0, 0.0), (rad(0.0), 0.0)]
    zs = [0.03, 0.09]
    cur = 0.09
    pts = [(rad(0.03), 0.03)]
    for z0, z1 in hoops:
        pts.append((rad(z0), z0))
        pts.append((rad(z0) + 0.018, z0))
        pts.append((rad(z1) + 0.018, z1))
        pts.append((rad(z1), z1))
    pts.append((rad(H - 0.03), H - 0.03))
    prof = [(0.0, 0.0), (0.24, 0.0), (rad(0.02), 0.02)] + pts[1:] + [(rad(H), H), (rad(H) - 0.02, H + 0.03),
                                                                    (rad(H) - 0.05, H + 0.03), (rad(H) - 0.05, H - 0.03),
                                                                    (0.0, H - 0.03)]

    def mat(r, z):
        if z >= H - 0.031:
            return dw
        for z0, z1 in hoops:
            if z0 - 1e-6 <= z <= z1 + 1e-6:
                return hoop
        return wood
    b = Builder("barrel", angle=28)
    b.lathe(prof, mat, segs=12)
    ob = b.build()
    return finish("barrel", [ob])


def fence_segment_2m():
    """2 m fence piece: posts at both ends, two rails that run the full 2 m so neighbours join. Origin base centre."""
    new_piece()
    w, dw, cream = M("wood", 0.85), M("dark_wood", 0.85), M("cream", 0.85)
    b = Builder("fence_segment_2m", angle=35)
    for sx in (-1, 1):
        b.box((0.17, 0.17, 0.92), (sx * 0.9, 0, 0.46), dw, bevel=0.03)
        b.box((0.2, 0.2, 0.09), (sx * 0.9, 0, 0.93), dw, bevel=0.03)
    for z in (0.3, 0.68):
        b.box((2.0, 0.08, 0.13), (0, 0, z), w, bevel=0.02)
    # planks: four vertical pickets with cream tips? keep it chunky: diagonal brace both faces
    for s in (-1, 1):
        b.box((1.05, 0.05, 0.085), (0, s * 0.065, 0.49), dw, bevel=0.012, rot=(0, math.radians(20.0), 0))
    ob = b.build()
    return finish("fence_segment_2m", [ob])


def _cobbles(b, r0, r1, seed):
    st, dk = M("stone", 0.95), M("dark_stone", 0.95)
    lt = M("stone", 0.95, name="StoneLight", hexv="#a59fae")
    wm = M("stone", 0.95, name="StoneWarm", hexv="#9a8d86")
    plum, cream = M("plum", 0.9), M("cream", 0.95)

    def pick(k, j, rm, rng):
        if rm < 1.75:  # centre emblem
            return plum if (k + j) % 2 == 0 else cream
        v = rng.random()
        return st if v < 0.34 else lt if v < 0.66 else wm if v < 0.92 else dk
    polar_cells(b, r0, r1, 0.0, 0.62, 0.78, 0.055, pick, seed=seed, jit=0.03)


def arena_floor_disc():
    """10 m radius courtyard floor: cobbles in flat colours, kerb ring, top at y=0, origin at centre top."""
    new_piece()
    dk, cd, ch = M("dark_stone", 0.95), M("charcoal", 0.95), M("dark_stone", 0.95)
    b = Builder("arena_floor_disc", angle=30)
    prof, _ = rrect(0, 10.0, -0.5, -0.04, 0.0, 0.08, 1)
    b.lathe(prof, dk, segs=64)
    # kerb: alternating dark blocks
    kd = M("charcoal", 0.95)

    def kpick(k, j, rm, rng):
        return kd if j % 2 == 0 else dk
    polar_cells(b, 9.35, 10.0, 0.0, 0.65, 1.15, 0.045, kpick, seed=5)
    _cobbles(b, 1.0, 9.35, 7)
    # centre medallion
    b.lathe([(0, -0.04), (1.0, -0.04), (1.0, 0.0), (0, 0.0)], M("plum", 0.9), segs=24)
    ob = b.build()
    return finish("arena_floor_disc", [ob])


ALL = [bomb, crate, barrel, fence_segment_2m, arena_floor_disc]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
