"""Hats 7-12: propeller_cap, pirate, viking, flower_pot, traffic_cone, cat_ears."""
import math

from mathutils import Matrix, Vector

import hats_lib as H
from hats_lib import Builder, mat, smoothstep
from hats_a import front_xf, loop

MIRROR_X = Matrix.Diagonal((-1.0, 1.0, 1.0, 1.0))


def rot_about(pivot, rot):
    return Matrix.Translation(pivot) @ rot @ Matrix.Translation(-Vector(pivot))


@H.hat("propeller_cap")
def propeller_cap():
    b = Builder()
    panels = [mat("red"), mat("gold"), mat("blue")]
    cream, teal, gold = mat("cream"), mat("teal"), mat("gold", 0.4)
    S = 30  # 6 panels x 5 segments
    P = 5

    def seam(th, r, z):
        j = round(th / (2 * math.pi) * S) % S
        rr = r * (1 - (0.022 if j % P == 0 else 0.0))
        return Vector((rr * math.cos(th), rr * math.sin(th), z))
    prof = [(0.352, -0.165), (0.381, -0.15), (0.395, -0.11), (0.396, -0.06), (0.382, 0.0), (0.348, 0.045),
            (0.29, 0.075), (0.21, 0.095), (0.11, 0.106), (0.04, 0.109)]
    b.lathe(prof, lambda i, j: panels[(j // P) % 3], S, ring_fn=seam)
    # hem band
    b.lathe(loop((0.335, -0.172), (0.386, -0.172), (0.394, -0.16), (0.394, -0.128), (0.384, -0.122),
                 (0.335, -0.122)), cream, S)
    # button + stem
    b.ellipsoid((0, 0, 0.108), (0.05, 0.05, 0.034), gold, 10, 5)
    b.lathe([(0.02, 0.10), (0.02, 0.205)], teal, 8)
    # visor (a rounded tongue, tilted down a little)
    pts = []
    for k in range(9):
        u = math.pi * k / 8
        pts.append((0.235 * math.cos(u), -0.29 - 0.255 * math.sin(u)))
    tilt = rot_about((0, -0.30, -0.12), Matrix.Rotation(math.radians(9), 4, "X"))
    b.prism(pts, -0.140, -0.108, teal, 0.006, tilt)
    # propeller: separate Spin object, origin at the hub
    sp = Builder()
    sp.ellipsoid((0, 0, 0), (0.045, 0.045, 0.036), gold, 10, 5)
    blade = H.rect_outline(0.32, 0.115, 0.05)
    sp.prism(blade, -0.008, 0.008, mat("green"), 0.004,
             Matrix.Translation((0.19, 0, 0.012)) @ Matrix.Rotation(math.radians(15), 4, "X"))
    sp.prism(blade, -0.008, 0.008, mat("pink"), 0.004,
             Matrix.Translation((-0.19, 0, 0.012)) @ Matrix.Rotation(math.radians(-15), 4, "X"))
    return b, {"Spin": (sp, (0.0, 0.0, 0.215))}


@H.hat("pirate")
def pirate():
    b = Builder()
    charcoal, gold, white, red = mat("charcoal"), mat("gold", 0.4), mat("white"), mat("red")
    S = 26
    b.lathe([(0.240, -0.115), (0.256, -0.04), (0.266, 0.05), (0.262, 0.14), (0.238, 0.21), (0.185, 0.258),
             (0.10, 0.282), (0.04, 0.288)], charcoal, S)
    th_c = math.radians(90)  # back corner; corners at 90, 210, 330 deg; flat wall faces the front (-Y)

    def top_pt(th, u):
        c = (math.cos(3 * (th - th_c)) + 1) / 2
        r_edge = 0.325 + 0.15 * c ** 1.5
        z_edge = 0.15 - 0.29 * c ** 0.75
        r = 0.240 + (r_edge - 0.240) * u
        z = -0.09 + (z_edge + 0.09) * u ** 2.2
        return r, z

    def ring_at(u, dz=0.0, out=0.0):
        pts = []
        for j in range(S):
            th = 2 * math.pi * j / S
            r, z = top_pt(th, u)
            r += out
            pts.append(Vector((r * math.cos(th), r * math.sin(th), z + dz)))
        return pts
    tops = [0.0, 0.4, 0.75, 0.92, 1.0]
    thick = 0.032
    rings = [ring_at(u) for u in tops]
    rings.append(ring_at(1.0, -thick * 0.5, 0.012))
    rings += [ring_at(u, -thick) for u in (1.0, 0.6, 0.0)]
    rings.append(ring_at(0.0))
    n_top = len(tops)
    gold_iv = {n_top - 1, n_top}  # thin gold edge trim only
    b.surf(rings, lambda i, j: gold if i in gold_iv else charcoal)
    # badge: gold plate with a skull and crossbones
    bx = front_xf(-0.313, 0.04)
    b.prism(H.rect_outline(0.19, 0.16, 0.05), -0.05, 0.006, gold, 0.006, bx)
    # crossbones
    for sx in (-1, 1):
        a = Vector((-0.07 * sx, -0.048, 0.016))
        c = Vector((0.07 * sx, 0.048, 0.016))
        b.sweep([a, a.lerp(c, 0.5), c], 0.0095, white, 6, cap=True, xf=bx)
        for e in (a, c):
            b.ellipsoid(e + Vector((0, 0, 0.002)), (0.016, 0.016, 0.012), white, 6, 3, bx)
    # skull
    b.ellipsoid((0, 0.014, 0.02), (0.055, 0.05, 0.026), white, 10, 5, bx)
    b.prism(H.rect_outline(0.05, 0.036, 0.008), 0.014, 0.046, white, 0.005,
            bx @ Matrix.Translation((0, -0.036, 0)))
    for sx in (-1, 1):
        b.ellipsoid((0.022 * sx, 0.012, 0.043), (0.014, 0.017, 0.008), charcoal, 6, 3, bx)
    b.ellipsoid((0, -0.012, 0.045), (0.007, 0.011, 0.006), charcoal, 6, 3, bx)
    return b


@H.hat("viking")
def viking():
    b = Builder()
    steel, wood, leather, gold, cream = mat("steel", 0.55, 0.0), mat("wood"), mat("leather"), mat("gold", 0.4), mat("cream")
    S = 22
    RH = 0.405

    def helm_r(z):
        dz = z - H.HEAD_C
        return math.sqrt(max(RH ** 2 - dz * dz, 0.0))
    a0 = math.asin((-0.175 - H.HEAD_C) / RH)
    prof = []
    for k in range(8):
        a = a0 + (math.pi / 2 - a0) * k / 7
        prof.append((RH * math.cos(a), H.HEAD_C + RH * math.sin(a)))
    b.lathe(prof, steel, S)
    # brow band hugging the dome
    zs = [-0.175, -0.11, -0.06]
    outer = [(helm_r(z) + 0.016, z) for z in zs]
    inner = [(helm_r(z) - 0.012, z) for z in reversed(zs)]
    b.lathe(outer + inner + [outer[0]], leather, S)
    # rivets
    for k in range(9):
        th = 2 * math.pi * (k + 0.5) / 9
        rr = helm_r(-0.118) + 0.017
        xf = Matrix.Translation((rr * math.cos(th), rr * math.sin(th), -0.118)) @ Matrix.Rotation(th, 4, "Z")
        b.ellipsoid((0, 0, 0), (0.013, 0.015, 0.015), gold, 5, 3, xf)
    # ridge over the top, front to back
    R2 = RH + 0.012
    path = [Vector((0, math.sin(math.radians(a)) * R2, H.HEAD_C + math.cos(math.radians(a)) * R2))
            for a in range(-54, 55, 18)]
    b.sweep(path, (0.03, 0.016), wood, 6, cap=True)
    # top knob
    b.ellipsoid((0, 0, H.HEAD_C + RH + 0.01), (0.032, 0.032, 0.036), gold, 8, 4)
    # horns: cream, gold collars, curving up
    for xf in (None, MIRROR_X):
        hp = H.bend_path((0.25, 0, -0.105), (1, 0, 0.25), 0.44, -105, 8, (0, 1, 0), 1.1)
        n = len(hp)
        rad = [0.098, 0.098, 0.084] + [0.084 * (1 - (i - 2) / (n - 3)) ** 0.8 + 0.014 for i in range(3, n)]
        b.sweep(hp, rad, lambda i, j: gold if i <= 3 else cream, 8, cap=True, xf=xf)
    return b


@H.hat("flower_pot")
def flower_pot():
    b = Builder()
    clay, teal, soil = mat("terracotta"), mat("teal"), mat("soil")
    green, dgreen, pink, gold = mat("green"), mat("darkgreen"), mat("pink"), mat("gold", 0.5)
    S = 24
    prof = [(0.190, -0.06), (0.200, -0.045), (0.2168, 0.02), (0.2343, 0.085), (0.238, 0.10),
            (0.252, 0.152), (0.284, 0.158), (0.298, 0.172), (0.298, 0.222), (0.288, 0.236),
            (0.262, 0.236), (0.252, 0.205), (0.0, 0.205)]
    body_teal = 2
    soil_iv = len(prof) - 2

    def pm(i, j):
        if i == body_teal:
            return teal
        if i == soil_iv:
            return soil
        return clay
    b.lathe(prof, pm, S)
    # stem
    stem = H.bend_path((0.0, 0.0, 0.20), (0, 0, 1), 0.40, 34, 6, (-0.35, 0.94, 0), 1.0)
    b.sweep(stem, [0.024, 0.022, 0.020, 0.018, 0.017, 0.017, 0.017], green, 6, cap=True)
    top = stem[-1]
    tans, frames = H.sweep_frames(stem)
    # flower facing front/up
    nf = Vector((0.0, -0.72, 0.69)).normalized()
    xa = Vector((1, 0, 0))
    ya = nf.cross(xa).normalized()
    xa = ya.cross(nf).normalized()
    ctr = top + nf * 0.01
    b.ellipsoid((0, 0, 0), (0.05, 0.05, 0.026), gold, 8, 4, H.basis_xf(ctr + nf * 0.012, xa, ya, nf))
    for k in range(8):
        a = 2 * math.pi * k / 8
        rx = xa * math.cos(a) + ya * math.sin(a)
        ry = nf.cross(rx).normalized()
        xf = H.basis_xf(ctr + nf * (0.002 if k % 2 else 0.0), rx, ry, nf)
        b.ellipsoid((0.088, 0, 0), (0.064, 0.032, 0.011), pink, 8, 3, xf)
    # leaves
    for sx, col, yaw in ((1, dgreen, 12), (-1, green, -8)):
        base = stem[1]
        d = Vector((sx * math.cos(math.radians(yaw)), math.sin(math.radians(yaw)), 0))
        d = (d + Vector((0, 0, 0.55))).normalized()
        ry = Vector((0, 0, 1)).cross(d).normalized()
        rz = d.cross(ry).normalized()
        b.ellipsoid((0.125, 0, 0), (0.14, 0.06, 0.012), col, 8, 4, H.basis_xf(base, d, ry, rz))
    # a small forward leaf
    d = Vector((0.0, -0.9, 0.42)).normalized()
    ry = Vector((0, 0, 1)).cross(d).normalized()
    rz = d.cross(ry).normalized()
    b.ellipsoid((0.09, 0, 0), (0.1, 0.044, 0.010), green, 8, 3, H.basis_xf(stem[2], d, ry, rz))
    return b


@H.hat("traffic_cone")
def traffic_cone():
    b = Builder()
    orange, white, charcoal = mat("orange"), mat("white"), mat("charcoal")
    S = 24

    def R(z):
        return 0.172 - 0.142 * (z + 0.055) / 0.455
    st = 0.010
    zs = [(0.05, 0.14), (0.19, 0.265)]
    prof = [(R(-0.055), -0.055)]
    tags = []
    for z0, z1 in zs:
        prof += [(R(z0), z0), (R(z0) + st, z0), (R(z1) + st, z1), (R(z1), z1)]
        tags += ["o", "w", "w", "w"]
    prof += [(R(0.40), 0.40), (0.024, 0.416), (0.0, 0.426)]
    tags += ["o", "o", "o"]
    b.lathe(prof, lambda i, j: white if tags[min(max(i - 1, 0), len(tags) - 1)] == "w" else orange, S)
    b.prism(H.rect_outline(0.37, 0.37, 0.10), -0.12, -0.055, charcoal, 0.014)
    return b


@H.hat("cat_ears")
def cat_ears():
    b = Builder()
    charcoal, pink = mat("charcoal"), mat("pink")
    Rb = 0.395
    path = []
    for k in range(13):
        a = math.radians(-58 + 116 * k / 12)
        rr = Rb - 0.03 * smoothstep(0.6, 1.0, abs(k - 6) / 6.0)  # ends dive into the head
        path.append(Vector((math.sin(a) * rr, 0.0, H.HEAD_C + math.cos(a) * rr)))
    b.sweep(path, (0.044, 0.02), pink, 8, cap=True, up=(0, 0, 1))

    def squash(k, off):
        def fn(th, r, z):
            return Vector((r * math.cos(th), k * r * math.sin(th) + off * smoothstep(0.0, 0.05, z), z))
        return fn
    outer = [(0.14, -0.06), (0.136, 0.0), (0.114, 0.08), (0.08, 0.15), (0.046, 0.215), (0.018, 0.268)]
    inner = [(0.098, 0.0), (0.08, 0.07), (0.054, 0.14), (0.028, 0.2), (0.009, 0.238)]
    for sx in (1, -1):
        base = Vector((sx * Rb * math.sin(math.radians(27)), 0.0, H.HEAD_C + Rb * math.cos(math.radians(27)) - 0.05))
        xf = Matrix.Translation(base) @ Matrix.Rotation(math.radians(10 * sx), 4, "Y") @ Matrix.Rotation(math.radians(13), 4, "X")
        b.lathe(outer, charcoal, 16, xf, ring_fn=squash(0.62, 0.0))
        b.lathe(inner, pink, 12, xf, ring_fn=squash(0.42, -0.03))
    return b
