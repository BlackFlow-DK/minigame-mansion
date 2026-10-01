"""Cannon Alley props: cannon_cannon, cannon_ball, cannon_floor, cannon_wall, cannon_parapet.

Layout (Godot metres): the lane is x in [-9.5, 9.5], z in [-5, 5], top at y = 0. Two gun decks
(ledges 0.35 m high) run along both long sides out to |z| = 7.4; the cannons stand on them.
cannon_cannon: separate objects Carriage, Barrel (origin at the trunnion, 0.62 m up; the
muzzle is 0.95 m in front of it along +Z) with children EmitFuse (spark on the touch hole) and
EmitFlash (muzzle flash; the game hides both until they are needed).
cannon_ball: 0.35 m radius iron ball, origin at its CENTRE (it rolls), with a lighter seam band.
Run: tools/blender-run.ps1 art/scripts/props/cannon_alley.py [piece names...]
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

LANE_X = 9.5
LANE_Z = 5.0
DECK_Z = 7.4
DECK_H = 0.35
BALL_R = 0.35
TRUNNION_H = 0.62
MUZZLE = 0.95


def _prism_yz(b, poly_yz, x0, x1, mat, bevel=0.0):
    """Extrude a CCW (y, z) polygon along X from x0 to x1 (a side-profile plank)."""
    tmp = bmesh.new()
    lo = [tmp.verts.new((x0, y, z)) for y, z in poly_yz]
    hi = [tmp.verts.new((x1, y, z)) for y, z in poly_yz]
    mi = b.mi(mat)
    n = len(poly_yz)
    fs = [tmp.faces.new(hi), tmp.faces.new(lo[::-1])]
    for i in range(n):
        j = (i + 1) % n
        fs.append(tmp.faces.new([lo[i], lo[j], hi[j], hi[i]]))
    for f in fs:
        f.material_index = mi
    bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
    if bevel > 0:
        edges = [e for e in tmp.edges if abs(e.verts[0].co.x - e.verts[1].co.x) < 1e-9]
        bmesh.ops.bevel(tmp, geom=edges, offset=bevel, offset_type="OFFSET", segments=1, profile=0.5,
                        affect="EDGES")
    b.raw(tmp)


def _rect_cells(b, x0, x1, y0, y1, z, cw, ch, gap, pick, seed=1, jit=0.0, brick=True):
    """Flat stone quads on a running-bond grid (Blender x, y) at height z; pick(i, j, rng) -> material."""
    rng = random.Random(seed)
    tmp = bmesh.new()
    rows = max(1, round((y1 - y0) / ch))
    h = (y1 - y0) / rows
    for j in range(rows):
        ya, yb = y0 + h * j + gap / 2, y0 + h * (j + 1) - gap / 2
        off = cw * 0.5 if (brick and j % 2) else 0.0
        xs = [x0]
        x = x0 + (cw - off if off > 0 else cw)
        while x < x1 - cw * 0.35:
            xs.append(x)
            x += cw * rng.uniform(0.85, 1.15)
        xs.append(x1)
        for i in range(len(xs) - 1):
            xa, xb = xs[i] + gap / 2, xs[i + 1] - gap / 2
            m = pick(i, j, rng)
            pts = [(xa, ya), (xb, ya), (xb, yb), (xa, yb)]
            vs = [tmp.verts.new((px + rng.uniform(-jit, jit), py + rng.uniform(-jit, jit), z)) for px, py in pts]
            f = tmp.faces.new(vs)
            f.material_index = b.mi(m)
    b.raw(tmp)


# ---------------------------------------------------------------- cannon
def cannon_cannon():
    """Cartoon cannon on a red two-wheeled carriage, ~1.5 m wide, muzzle 0.95 m in front of the trunnion."""
    new_piece()
    red = M("red", 0.7)
    dw = M("dark_wood", 0.85)
    wood = M("wood", 0.85)
    iron = M("charcoal", 0.45, 0.35, name="Iron", hexv="#34303b")
    gold = M("gold", 0.4, 0.5)

    cb = Builder("Carriage", angle=35)
    # two cheek planks: tall at the front (-Y), sloping to a trail on the ground at the back (+Y)
    cheek = [(-0.55, 0.14), (0.95, 0.0), (0.95, 0.12), (0.35, 0.5), (-0.1, 0.62), (-0.55, 0.62)]
    for sx in (-1, 1):
        _prism_yz(cb, cheek, sx * 0.48 - 0.05, sx * 0.48 + 0.05, red, bevel=0.02)
        # iron cap square over the trunnion
        cb.box((0.12, 0.26, 0.07), (sx * 0.48, 0.0, 0.64), iron, bevel=0.02)
    # transom and bed between the cheeks
    cb.box((0.8, 0.5, 0.1), (0, -0.15, 0.2), dw, bevel=0.02)
    cb.box((0.8, 0.12, 0.3), (0, 0.55, 0.2), dw, bevel=0.02)
    # quoin (wedge block) under the breech
    cb.box((0.3, 0.3, 0.12), (0, 0.42, 0.34), wood, bevel=0.02)
    # axle
    cb.cyl(0.06, 1.5, (-0.75, -0.2, 0.44), iron, segs=10, rot=(0, math.pi / 2, 0))
    # wheels: rim, hub, six spokes
    wr = 0.44
    for sx in (-1, 1):
        cx = sx * 0.68
        rim, _ = rrect(wr - 0.08, wr, -0.065, 0.065, 0.02, 0.02, 1)
        cb.lathe(rim, dw, segs=22, closed=True, loc=(cx, -0.2, wr), rot=(0, math.pi / 2, 0))
        tyre, _ = rrect(wr - 0.012, wr + 0.012, -0.07, 0.07, 0.0, 0.0, 1)
        cb.lathe(tyre, iron, segs=22, closed=True, loc=(cx, -0.2, wr), rot=(0, math.pi / 2, 0))
        cb.cyl(0.11, 0.2, (cx - 0.1, -0.2, wr), gold, segs=12, bevel=0.03, rot=(0, math.pi / 2, 0))
        for k in range(6):
            a = math.pi * k / 3
            cb.box((0.05, 0.05, wr - 0.1), (cx, -0.2 - math.sin(a) * (wr - 0.04) / 2,
                                            wr + math.cos(a) * (wr - 0.04) / 2), wood, rot=(a, 0, 0))
    carriage = cb.build()

    # barrel: lathe about its own axis (+Z), turned so +Z points to the front (-Y)
    bb = Builder("Barrel", angle=40)
    prof = [(0.0, -0.74), (0.09, -0.72), (0.12, -0.66), (0.1, -0.61), (0.06, -0.58), (0.3, -0.57), (0.42, -0.52),
            (0.45, -0.44), (0.45, -0.3), (0.48, -0.28), (0.48, -0.2), (0.45, -0.18), (0.41, 0.5), (0.44, 0.52),
            (0.44, 0.58), (0.41, 0.6), (0.41, 0.74), (0.5, 0.84), (0.55, 0.9), (0.55, MUZZLE), (0.37, MUZZLE),
            (0.37, 0.45), (0.0, 0.45)]
    gold_z = [(-0.3, -0.18), (0.5, 0.6), (0.84, MUZZLE + 0.01)]

    def bmat(r, z):
        if r < 0.38 and z > 0.4:
            return M("charcoal", 0.9, name="Bore", hexv="#141217")
        for z0, z1 in gold_z:
            if z0 - 1e-6 <= z <= z1 + 1e-6 and r > 0.4:
                return gold
        if z < -0.56:
            return gold
        return iron
    bb.lathe(prof, bmat, segs=24, rot=(math.pi / 2, 0, 0))
    # trunnion pins
    bb.cyl(0.08, 1.02, (-0.51, 0, 0), iron, segs=10, rot=(0, math.pi / 2, 0))
    # fuse stub on the touch hole
    bb.tube([(0, 0.36, 0.4), (0.0, 0.38, 0.5), (0.05, 0.42, 0.57)], 0.025, M("wood", 0.9, name="Fuse",
                                                                             hexv="#b98a4e"), sides=5)
    barrel = bb.build(loc=(0, 0, TRUNNION_H))

    spark = EM("EmitFuse", "#ffcf4a", 5.0)
    sb = Builder("EmitFuse", angle=90)
    pts = star_poly(0.2, 0.07, 5)
    sb.prism(pts, -0.015, 0.015, spark)
    sb.prism(pts, -0.015, 0.015, spark, rot=(math.pi / 2, 0, 0))
    sb.prism(pts, -0.015, 0.015, spark, rot=(0, math.pi / 2, 0))
    sb.sphere(0.07, (0, 0, 0), spark, segs=8, rings=5)
    fuse = sb.build(loc=(0.05, 0.42, TRUNNION_H + 0.6))

    flash_m = EM("EmitFlash", "#ffb43a", 6.0)
    core_m = EM("EmitFlashCore", "#fff3b0", 8.0)
    fb = Builder("EmitFlash", angle=90)
    fb.prism(star_poly(0.78, 0.36, 8, rot=0.2), -0.02, 0.02, flash_m, rot=(math.pi / 2, 0, 0))
    fb.prism(star_poly(0.5, 0.24, 6, rot=0.0), -0.02, 0.02, core_m, loc=(0, -0.05, 0), rot=(math.pi / 2, 0, 0))
    fb.sphere(0.26, (0, 0.06, 0), core_m, scale=(1, 1.6, 1), segs=10, rings=6)
    flash = fb.build(loc=(0, -(MUZZLE + 0.12), TRUNNION_H))
    bpy.context.view_layer.update()  # world matrices of the new objects, so parenting keeps them in place
    artlib.set_parent(fuse, barrel)
    artlib.set_parent(flash, barrel)
    return finish("cannon_cannon", [carriage, barrel, fuse, flash], expect_tris=(300, 9000))


def cannon_ball():
    """Iron ball, radius 0.35, origin at the centre, with a lighter seam band around its equator."""
    new_piece()
    iron = M("charcoal", 0.35, 0.3, name="BallIron", hexv="#24212a")
    seam = M("dark_stone", 0.5, 0.3, name="BallSeam", hexv="#6a6475")
    b = Builder("Ball", angle=60)
    b.sphere(BALL_R, (0, 0, 0), iron, segs=20, rings=12)
    band, _ = rrect(BALL_R - 0.03, BALL_R + 0.012, -0.035, 0.035, 0.01, 0.01, 1)
    b.lathe(band, seam, segs=24, closed=True)
    # a band the other way too, so the roll reads from any side
    b.lathe(band, seam, segs=24, closed=True, rot=(math.pi / 2, 0, 0))
    ob = b.build()
    return finish("cannon_ball", [ob], expect_tris=(200, 3000))


# ---------------------------------------------------------------- courtyard
def cannon_floor():
    """Sandstone cobbled lane with a raised flagstone gun deck on both long sides. Origin at lane centre top."""
    new_piece()
    grout = M("stone", 0.95, name="Grout", hexv="#8f7d63")
    sand = M("stone", 0.95, name="Sand", hexv="#d9c6a0")
    sand2 = M("stone", 0.95, name="SandLight", hexv="#e6d7b8")
    sand3 = M("stone", 0.95, name="SandWarm", hexv="#cdb28a")
    sand4 = M("stone", 0.95, name="SandDeep", hexv="#b99b76")
    flag = M("stone", 0.95, name="Flag", hexv="#a99c90")
    flag2 = M("stone", 0.95, name="FlagLight", hexv="#bdb1a4")
    kerb = M("stone", 0.9, name="Kerb", hexv="#7c6f73")
    plum = M("plum", 0.85)
    b = Builder("cannon_floor", angle=30)
    X = LANE_X + 0.1
    b.box((2 * X, 2 * DECK_Z, 0.5), (0, 0, -0.28), grout)

    def lane_pick(i, j, rng):
        v = rng.random()
        return sand if v < 0.36 else sand2 if v < 0.66 else sand3 if v < 0.93 else sand4
    _rect_cells(b, -X, X, -LANE_Z + 0.2, LANE_Z - 0.2, 0.0, 0.62, 0.5, 0.05, lane_pick, seed=11, jit=0.025)
    # a plum-and-cream runner stripe down the middle of the lane (the spawn line)
    for k in range(19):
        x = -9.0 + k
        b.box((0.9, 0.34, 0.02), (x, 0, 0.005), plum if k % 2 == 0 else sand2, bevel=0.005)
    for s in (-1, 1):
        # kerb stones along the foot of each deck
        _rect_cells(b, -X, X, s * LANE_Z - 0.2 if s > 0 else -LANE_Z, s * LANE_Z if s > 0 else -LANE_Z + 0.2,
                    0.0, 0.8, 0.2, 0.04, lambda i, j, rng: kerb, seed=3, brick=False)
        # deck body and its lane-side face
        y0, y1 = (LANE_Z, DECK_Z) if s > 0 else (-DECK_Z, -LANE_Z)
        b.box((2 * X, y1 - y0, DECK_H), (0, (y0 + y1) / 2, DECK_H / 2 - 0.02), kerb, bevel=0.03)

        def deck_pick(i, j, rng):
            return flag if rng.random() < 0.55 else flag2
        _rect_cells(b, -X, X, y0 + 0.06, y1 - 0.04, DECK_H, 0.95, 0.78, 0.06, deck_pick, seed=5 + s, jit=0.02)
        # coping lip on the lane edge
        edge = s * LANE_Z
        b.box((2 * X, 0.22, 0.08), (0, edge + s * 0.08, DECK_H + 0.02), flag2, bevel=0.025)
    ob = b.build()
    return finish("cannon_floor", [ob], expect_tris=(500, 16000))


def _wall_body(b, length, height, stone, dark, cap):
    b.box((length, 0.6, 0.3), (0, 0, 0.15), dark, bevel=0.04)
    b.box((length - 0.04, 0.5, height - 0.3), (0, 0, 0.3 + (height - 0.3) / 2), stone, bevel=0.03)
    # block courses: shallow proud bands on the lane side
    rng = random.Random(int(length * 10 + height * 100))
    z = 0.42
    row = 0
    while z < height - 0.3:
        x = -length / 2 + (0.35 if row % 2 else 0.0)
        while x < length / 2 - 0.2:
            w = rng.uniform(0.55, 0.85)
            x1 = min(x + w, length / 2 - 0.05)
            if x1 - x > 0.2:
                b.box((x1 - x - 0.05, 0.04, 0.3), ((x + x1) / 2, -0.26, z + 0.15), stone if rng.random() < 0.7 else cap,
                      bevel=0.012)
            x = x1
        z += 0.36
        row += 1
    b.box((length, 0.66, 0.12), (0, 0, height - 0.06), cap, bevel=0.03)


def cannon_wall():
    """4.8 m crenellated courtyard wall, 2.3 m to the coping, with a hanging banner. Lane side = front."""
    new_piece()
    stone = M("stone", 0.95, name="WallStone", hexv="#b7a58e")
    dark = M("dark_stone", 0.95, name="WallDark", hexv="#7e7068")
    cap = M("stone", 0.95, name="WallCap", hexv="#cfc0a9")
    red, gold, plum = M("red", 0.85), M("gold", 0.5, 0.3), M("plum", 0.85)
    b = Builder("cannon_wall", angle=35)
    L, H = 4.8, 2.3
    _wall_body(b, L, H, stone, dark, cap)
    for k in range(4):
        x = -L / 2 + 0.6 + k * 1.2
        b.box((0.62, 0.6, 0.5), (x, 0, H + 0.25), stone, bevel=0.04)
        b.box((0.7, 0.66, 0.08), (x, 0, H + 0.54), cap, bevel=0.03)
    # banner: rod, cloth with a swallowtail, gold ball emblem
    b.cyl(0.03, 1.3, (-0.65, -0.34, H - 0.28), gold, segs=8, rot=(0, math.pi / 2, 0))
    cloth = [(-0.55, 0.0), (0.55, 0.0), (0.55, -1.25), (0.0, -1.0), (-0.55, -1.25)]
    tmp_poly = [(x, z) for x, z in cloth]
    b.prism(tmp_poly, -0.02, 0.02, red, loc=(0, -0.33, H - 0.3), rot=(math.pi / 2, 0, 0))
    b.prism([(x * 0.8, z * 0.86 - 0.03) for x, z in cloth], -0.01, 0.01, plum, loc=(0, -0.36, H - 0.3),
            rot=(math.pi / 2, 0, 0))
    b.sphere(0.2, (0, -0.39, H - 0.85), gold, scale=(1, 0.35, 1), segs=14, rings=8)
    b.prism(star_poly(0.14, 0.06, 4, rot=0.0), -0.01, 0.01, red, loc=(0, -0.47, H - 0.85), rot=(math.pi / 2, 0, 0))
    ob = b.build()
    return finish("cannon_wall", [ob], expect_tris=(200, 9000))


def cannon_parapet():
    """4.8 m low parapet (0.6 m) for the camera side, so it never hides the lane."""
    new_piece()
    stone = M("stone", 0.95, name="WallStone", hexv="#b7a58e")
    dark = M("dark_stone", 0.95, name="WallDark", hexv="#7e7068")
    cap = M("stone", 0.95, name="WallCap", hexv="#cfc0a9")
    b = Builder("cannon_parapet", angle=35)
    L = 4.8
    b.box((L, 0.5, 0.2), (0, 0, 0.1), dark, bevel=0.03)
    b.box((L - 0.04, 0.4, 0.34), (0, 0, 0.37), stone, bevel=0.03)
    b.box((L, 0.52, 0.1), (0, 0, 0.58), cap, bevel=0.03)
    for k in range(4):
        x = -L / 2 + 0.6 + k * 1.2
        b.box((0.26, 0.26, 0.22), (x, 0, 0.74), stone, bevel=0.03)
        b.box((0.32, 0.32, 0.06), (x, 0, 0.87), cap, bevel=0.02)
    ob = b.build()
    return finish("cannon_parapet", [ob], expect_tris=(100, 4000))


ALL = [cannon_cannon, cannon_ball, cannon_floor, cannon_wall, cannon_parapet]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
