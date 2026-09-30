"""Coin Scramble props: coin, coin_big, spinner_bar (Post + Bar), bumper_post, treasure_chest,
vault_floor_disc, vault_wall_segment.

Run: tools/blender-run.ps1 art/scripts/props/coin.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib
from mathutils import Matrix

PI = math.pi


def _coin(name, R, t, star_mat_fn, rim_extra=False):
    new_piece()
    gold = EM("EmitGold", "#e8b33a", 0.35)
    dark = EM("EmitGoldDark", "#b8801c", 0.2)
    star = star_mat_fn()
    rr = R * 0.2
    rim = R - rr
    rec = t * 0.22  # recess depth of the face
    prof = [(0, -t / 2 + rec), (rim, -t / 2 + rec), (rim, -t / 2), (R - t * 0.25, -t / 2), (R, -t / 2 + t * 0.25),
            (R, t / 2 - t * 0.25), (R - t * 0.25, t / 2), (rim, t / 2), (rim, t / 2 - rec), (0, t / 2 - rec)]

    def mat(r, z):
        return dark if (abs(z) < t / 2 - rec * 0.5 and r < rim - 1e-6) else gold
    b = Builder(name, angle=40)
    rot = (PI / 2, 0, 0)  # local +Z axis -> Blender -Y (Godot +Z): the coin faces the camera
    b.lathe(prof, mat, segs=20, rot=rot)
    pts = star_poly(R * 0.62, R * 0.27, 5)
    b.prism(pts, t / 2 - rec - 0.001, t / 2 - 0.004, star, rot=rot)
    b.prism(pts, -t / 2 + 0.004, -t / 2 + rec + 0.001, star, rot=rot)
    ob = b.build()
    return finish(name, [ob])


def coin():
    return _coin("coin", 0.175, 0.085, lambda: EM("EmitGoldLight", "#f9dc7a", 0.5))


def coin_big():
    return _coin("coin_big", 0.3, 0.13, lambda: M("red", 0.5))


def spinner_bar():
    """Objects: Post (static) and Bar (6 m long, spins about the vertical axis through the origin). Both origins at
    the post base centre; bar centre height 0.5 m."""
    new_piece()
    ds, ch, dw, gold = M("dark_stone", 0.9), M("charcoal", 0.9), M("dark_wood", 0.85), M("gold", 0.45)
    red, cream = M("red", 0.85), M("cream", 0.9)
    pb = Builder("Post", angle=35)
    prof, _ = rrect(0, 0.7, 0, 0.16, 0.05, 0.03, 2)
    pb.lathe(prof, ds, segs=20)
    pb.lathe([(0, 0.1), (0.24, 0.1), (0.24, 0.98), (0.0, 0.98)], dw, segs=16)
    prof, _ = rrect(0, 0.3, 0.96, 1.12, 0.06, 0.02, 2)
    pb.lathe(prof, gold, segs=16)
    post = pb.build()

    zc = 0.5
    L, r = 6.0, 0.2
    bb = Builder("Bar", angle=40)
    n_sec, sec = 8, 0.7
    z0 = -sec * n_sec / 2
    prof = [(0.0, -L / 2)]
    for i in range(1, 5):  # rounded end
        a = PI / 2 * i / 4
        prof.append((r * 0.96 * math.sin(a), -L / 2 + (L - n_sec * sec) / 2 - (L - n_sec * sec) / 2 * math.cos(a)))
    for i in range(n_sec):
        za = z0 + i * sec
        prof += [(r * 0.94, za), (r * 1.04, za + 0.09), (r * 1.04, za + sec - 0.09), (r * 0.94, za + sec)]
    for i in range(4, -1, -1):
        a = PI / 2 * i / 4
        prof.append((r * 0.96 * math.sin(a), L / 2 - (L - n_sec * sec) / 2 + (L - n_sec * sec) / 2 * math.cos(a)))

    def mat(rm, zm):
        i = int((zm - z0) // sec)
        if zm < z0 or zm > z0 + n_sec * sec:
            return red
        return red if i % 2 == 0 else cream
    bb.lathe(prof, mat, segs=12, rot=(0, PI / 2, 0), loc=(0, 0, zc))
    # hub sleeve around the post
    prof, _ = rrect(0, 0.31, zc - 0.28, zc + 0.28, 0.05, 0.05, 2)
    bb.lathe(prof, dw, segs=16)
    bar = bb.build()
    return finish("spinner_bar", [post, bar])


def bumper_post():
    """1 m pinball bumper, origin at base centre."""
    new_piece()
    ds, red, cream = M("dark_stone", 0.9), M("red", 0.45), M("cream", 0.6)
    top = EM("EmitBumper", "#ffbe2e", 0.8)
    prof = [(0, 0), (0.5, 0), (0.5, 0.15), (0.45, 0.2), (0.45, 0.24), (0.47, 0.26), (0.45, 0.45), (0.5, 0.5),
            (0.5, 0.58), (0.44, 0.6), (0.4, 0.68), (0.32, 0.78), (0.2, 0.85), (0.0, 0.88)]

    def mat(r, z):
        if z < 0.2:
            return ds
        if z > 0.66:
            return top
        if 0.45 < z < 0.6:
            return cream
        return red
    b = Builder("bumper_post", angle=40)
    b.lathe(prof, mat, segs=20)
    ob = b.build()
    return finish("bumper_post", [ob])


def treasure_chest():
    """0.9 x 0.6 x ~0.95 m open chest full of gold, front faces Godot +Z (Blender -Y), origin base centre."""
    new_piece()
    wood, dw, gold = M("wood", 0.85), M("dark_wood", 0.85), M("gold", 0.4)
    eg = EM("EmitGold", "#e8b33a", 0.35)
    b = Builder("treasure_chest", angle=35)
    b.box((0.9, 0.6, 0.4), (0, 0, 0.24), wood, bevel=0.03)
    b.box((0.94, 0.64, 0.1), (0, 0, 0.05), dw, bevel=0.025)
    for x in (-0.3, 0.3):
        b.box((0.11, 0.64, 0.42), (x, 0, 0.25), dw, bevel=0.02)
    b.box((0.16, 0.05, 0.17), (0, -0.315, 0.37), gold, bevel=0.015)
    b.box((0.04, 0.06, 0.07), (0, -0.335, 0.36), M("charcoal"), bevel=0.008)
    # gold heap
    b.ico(0.4, (0, 0.0, 0.44), eg, subdiv=2, scale=(1.05, 0.62, 0.45), fn=lumps(5, amp=0.06), zmin=0.0)
    for (x, y, tilt) in ((-0.22, -0.2, 0.5), (0.18, -0.22, -0.4), (0.05, -0.05, 0.2)):
        b.lathe([(0, -0.012), (0.075, -0.012), (0.075, 0.012), (0, 0.012)], eg, segs=10,
                loc=(x, y, 0.54 if y > -0.1 else 0.49), rot=(tilt, 0.3, 0))
    # open lid, hinged at the back top edge
    hinge = Vector((0, 0.3, 0.44))
    base = Matrix.Translation(hinge) @ Matrix.Rotation(math.radians(-112), 4, "X") @ Matrix.Translation((0, -0.3, 0.0))
    ry = Matrix.Rotation(PI / 2, 4, "Y")
    b.lathe([(0, -0.45), (0.3, -0.45), (0.3, 0.45), (0, 0.45)], wood, segs=10, a0=PI / 2, a1=PI * 1.5,
            xf=base @ ry)
    for dz in (-0.3, 0.3):
        b.lathe([(0, -0.055), (0.32, -0.055), (0.32, 0.055), (0, 0.055)], dw, segs=10, a0=PI / 2, a1=PI * 1.5,
                xf=base @ ry @ Matrix.Translation((0, 0, dz)))
    ob = b.build()
    return finish("treasure_chest", [ob])


def vault_floor_disc():
    """10 m radius bank-vault floor: steel plates with gold seams, dial in the middle, bolted rim. Top at y=0."""
    new_piece()
    gold = M("gold", 0.45)
    st, dk, ch = M("stone", 0.6), M("dark_stone", 0.6), M("charcoal", 0.7)
    b = Builder("vault_floor_disc", angle=30)
    prof, _ = rrect(0, 10.0, -0.5, -0.05, 0.0, 0.08, 1)
    b.lathe(prof, gold, segs=64)

    def pick(k, j, rm, rng):
        return st if (k + j) % 2 == 0 else dk
    polar_cells(b, 2.7, 9.3, 0.0, 1.32, 1.65, 0.075, pick, seed=3)
    # outer kerb ring (gold) and rivets
    b.lathe([(9.3, -0.05), (10.0, -0.05), (10.0, 0.0), (9.3, 0.0)], gold, segs=64, closed=True)
    for i in range(16):
        a = TAU * i / 16
        b.sphere(0.13, (9.65 * math.cos(a), 9.65 * math.sin(a), 0.0), M("cream", 0.4), scale=(1, 1, 0.55),
                 segs=6, rings=4)
    # dial: concentric flat bands
    def dial(r, z):
        for a_, b_, m in ((0, 0.55, gold), (0.55, 0.7, ch), (0.7, 2.0, st), (2.0, 2.18, gold), (2.18, 2.7, ch)):
            if a_ <= r < b_:
                return m
        return ch
    b.lathe([(0, 0.0), (0.55, 0.0), (0.7, 0.0), (2.0, 0.0), (2.18, 0.0), (2.7, 0.0), (2.7, -0.05), (0, -0.05)],
            dial, segs=40)
    for i in range(8):
        a = TAU * i / 8 + TAU / 16
        b.box((1.25, 0.12, 0.02), (1.35 * math.cos(a), 1.35 * math.sin(a), 0.005), gold, rot=(0, 0, a))
    ob = b.build()
    return finish("vault_floor_disc", [ob])


def vault_wall_segment():
    """45 degree wall arc for a 10 m radius disc, 1.5 m high. Origin at the disc centre (y=0); the arc is centred on
    Godot +Z (Blender -Y); rotate about Y in 45 degree steps for the full ring."""
    new_piece()
    ch, ds, gold, steel = M("charcoal", 0.7), M("stone", 0.6), M("gold", 0.45), M("cream", 0.5)
    a0, a1 = math.radians(-90 - 22.5), math.radians(-90 + 22.5)
    prof = [(9.4, 0), (10.0, 0), (10.0, 0.32), (9.9, 0.32), (9.9, 1.32), (9.98, 1.32), (9.98, 1.5), (9.42, 1.5),
            (9.42, 1.32), (9.5, 1.32), (9.5, 0.32), (9.4, 0.32)]

    def mat(r, z):
        if z < 0.32:
            return ch
        if z > 1.32:
            return gold
        return ds
    b = Builder("vault_wall_segment", angle=30)
    b.lathe(prof, mat, segs=12, a0=a0, a1=a1, closed=True)
    # ribs and bolts every 22.5 degrees (never on a segment end, so neighbours never double up)
    for da in (-11.25, 11.25):
        ac = math.radians(-90 + da)
        w = 0.2 / 9.5 / 2
        b.lathe([(9.36, 0.3), (9.52, 0.3), (9.52, 1.34), (9.36, 1.34)], steel, segs=1, a0=ac - w, a1=ac + w, closed=True)
        for z in (0.5, 0.85, 1.2):
            b.sphere(0.06, (9.36 * math.cos(ac), 9.36 * math.sin(ac), z), gold, scale=(1, 1, 1), segs=6, rings=4)
    # gold band along the middle of the plates
    b.lathe([(9.42, 0.74), (9.5, 0.74), (9.5, 0.82), (9.42, 0.82)], gold, segs=12, a0=a0, a1=a1, closed=True)
    ob = b.build()
    return finish("vault_wall_segment", [ob])


ALL = [coin, coin_big, spinner_bar, bumper_post, treasure_chest, vault_floor_disc, vault_wall_segment]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
