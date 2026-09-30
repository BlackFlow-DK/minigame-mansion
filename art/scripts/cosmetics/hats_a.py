"""Hats 1-6: top_hat, party_cone, crown, wizard, cowboy, chef. Godot-up = Blender Z, front = -Y."""
import math

from mathutils import Matrix, Vector

import hats_lib as H
from hats_lib import Builder, mat, smoothstep

RX = Matrix.Rotation(math.pi / 2, 4, "X")  # local +Z (extrusion) -> -Y (front), local +Y -> +Z


def front_xf(y, z, x=0.0):
    """Place a flat decal (outline in local XY, extruded along local +Z) facing the front (-Y)."""
    return Matrix.Translation((x, y, z)) @ RX


def loop(*pts):
    """Closed profile loop: repeats the first point at the end."""
    return list(pts) + [pts[0]]


@H.hat("top_hat")
def top_hat():
    b = Builder()
    charcoal, plum, gold = mat("charcoal"), mat("plum"), mat("gold", 0.4)
    S = 26
    # crown: slight flare, rounded top edge
    b.lathe([(0.246, -0.11), (0.250, -0.07), (0.262, 0.30), (0.258, 0.322), (0.245, 0.338),
             (0.225, 0.345)], charcoal, S)
    # brim with a rolled-up edge
    # (the top surface rises into a collar against the crown, so no scalp shows at the joint)
    b.lathe(loop((0.235, -0.135), (0.33, -0.135), (0.372, -0.118), (0.384, -0.09), (0.372, -0.072),
                 (0.33, -0.082), (0.288, -0.066), (0.256, -0.045), (0.235, -0.045)), charcoal, S)
    # plum band, flanged
    b.lathe(loop((0.245, -0.035), (0.270, -0.035), (0.276, -0.028), (0.276, 0.05), (0.270, 0.057),
                 (0.245, 0.057)), plum, S)
    # gold buckle on the front with a dark slot
    b.prism(H.rect_outline(0.105, 0.115, 0.012), 0.0, 0.02, gold, 0.005, front_xf(-0.265, 0.011))
    b.prism(H.rect_outline(0.058, 0.066, 0.006), 0.0, 0.026, plum, 0.0, front_xf(-0.265, 0.011))
    # gold pin across the slot
    b.prism(H.rect_outline(0.075, 0.014, 0.004), 0.0, 0.030, gold, 0.003, front_xf(-0.265, 0.011))
    return b


@H.hat("party_cone")
def party_cone():
    b = Builder()
    pink, cream, teal, gold = mat("pink"), mat("cream"), mat("teal"), mat("gold", 0.5)
    S = 24
    R0, Z0, ZT = 0.222, -0.085, 0.43
    prof = []
    N = 16
    for i in range(N + 1):
        t = i / N
        prof.append((R0 * (1 - t) ** 0.92 + 0.004 * (1 - t), Z0 + (ZT - Z0) * t))
    # spiral stripes: shift by 2 segments per ring interval
    b.lathe(prof, lambda i, j: pink if ((j + i) % S) // 4 % 2 == 0 else cream, S)
    # teal base ring with a lip
    b.lathe(loop((0.205, -0.10), (0.238, -0.10), (0.245, -0.092), (0.245, -0.052), (0.232, -0.046),
                 (0.20, -0.046)), teal, S)
    # pompom: fluffy lumpy ball
    b.ellipsoid((0, 0, ZT + 0.035), (0.072, 0.072, 0.068), gold, 12, 7)
    return b


@H.hat("crown")
def crown():
    b = Builder()
    gold = mat("gold", 0.35, 0.25)
    gems = [mat("red"), mat("blue"), mat("green"), mat("pink"), mat("teal")]
    S = 24
    # band with flanges top and bottom
    b.lathe(loop((0.245, -0.125), (0.292, -0.125), (0.298, -0.115), (0.298, -0.095), (0.276, -0.088),
                 (0.268, 0.030), (0.284, 0.038), (0.284, 0.062), (0.262, 0.068), (0.245, 0.068)), gold, S)
    # five spikes, each with a gem ball on the tip and a gem set into the band below it
    for k in range(5):
        th = math.radians(-90 + 72 * k)
        cx, cy = 0.262 * math.cos(th), 0.262 * math.sin(th)
        b.lathe([(0.062, 0.05), (0.048, 0.12), (0.016, 0.235)], gold, 8, center=(cx, cy))
        b.ellipsoid((cx, cy, 0.252), (0.034, 0.034, 0.034), gems[k], 8, 4)
        gx, gy = 0.290 * math.cos(th), 0.290 * math.sin(th)
        xf = Matrix.Translation((gx, gy, -0.03)) @ Matrix.Rotation(th, 4, "Z")
        b.ellipsoid((0, 0, 0), (0.016, 0.03, 0.036), gems[(k + 2) % 5], 8, 4, xf)
        # small pointed spike between the tall ones
        th2 = math.radians(-90 + 72 * k + 36)
        b.lathe([(0.048, 0.05), (0.02, 0.125)], gold, 6,
                center=(0.262 * math.cos(th2), 0.262 * math.sin(th2)))
    return b


@H.hat("wizard")
def wizard():
    b = Builder()
    plum, gold, teal = mat("plum"), mat("gold", 0.4), mat("teal")
    S = 18
    R0, H0, HT = 0.235, -0.10, 0.66
    ax_ang = math.radians(25)  # bend direction in the XY plane (mostly +x, a little back)
    axis = (-math.sin(ax_ang), math.cos(ax_ang), 0)
    N = 12
    path = H.bend_path((0, 0, H0), (0, 0, 1), HT, 75, N, axis, 2.0)
    rad = [R0 * (1 - i / N) ** 0.95 + 0.006 for i in range(N + 1)]
    b.sweep(path, rad, plum, S, cap=True)
    tans, frames = H.sweep_frames(path)

    def surf_pt(t, phi, lift=0.0):
        f = t * N
        i = min(int(f), N - 1)
        u = f - i
        c = path[i].lerp(path[i + 1], u)
        nrm, side = frames[i]
        tan = tans[i].lerp(tans[i + 1], u).normalized()
        r = rad[i] * (1 - u) + rad[i + 1] * u
        radial = math.cos(phi) * side + math.sin(phi) * nrm
        slope = math.atan2(R0, HT)
        n = radial * math.cos(slope) + tan * math.sin(slope)
        return c + radial * (r + lift), n.normalized(), tan

    # gold stars on the cone: (t along the height, angle around, size)
    for t, phi, sz in ((0.20, 180, 0.055), (0.42, 232, 0.045), (0.31, 122, 0.040), (0.56, 178, 0.034)):
        p, n, tan = surf_pt(t, math.radians(phi), -0.004)
        ydir = (tan - n * tan.dot(n)).normalized()
        xdir = ydir.cross(n).normalized()
        xf = H.basis_xf(p, xdir, ydir, n)
        b.prism(H.star_outline(sz, sz * 0.46), 0.0, 0.012, gold, 0.0, xf)
    # wavy floppy brim, drooping at the edge
    def brim_ring(th, r, z):
        k = smoothstep(0.26, 0.42, r)
        return Vector((r * math.cos(th), r * math.sin(th), z + 0.022 * math.cos(3 * th + 0.6) * k))
    b.lathe(loop((0.225, -0.128), (0.32, -0.136), (0.425, -0.170), (0.434, -0.156),
                 (0.42, -0.144), (0.32, -0.110), (0.25, -0.095)), plum, 22, ring_fn=brim_ring)
    # band + buckle
    b.lathe(loop((0.205, -0.115), (0.246, -0.115), (0.250, -0.108), (0.240, -0.02), (0.236, -0.014),
                 (0.20, -0.014)), teal, S)
    b.prism(H.rect_outline(0.085, 0.09, 0.01), 0.0, 0.018, gold, 0.005, front_xf(-0.242, -0.066))
    b.prism(H.rect_outline(0.045, 0.05, 0.006), 0.0, 0.024, teal, 0.0, front_xf(-0.242, -0.066))
    return b


@H.hat("cowboy")
def cowboy():
    b = Builder()
    wood, leather, cream, gold = mat("wood"), mat("leather"), mat("cream"), mat("gold", 0.4)
    S = 24
    prof = [(0.244, -0.11), (0.248, -0.07), (0.250, 0.0), (0.246, 0.09), (0.232, 0.17), (0.215, 0.206),
            (0.195, 0.222), (0.15, 0.228), (0.10, 0.231), (0.05, 0.232)]
    crown_b = Builder()
    crown_b.lathe(prof, wood, S)

    def dent(v):
        top = smoothstep(0.12, 0.23, v.z)
        v.z -= 0.055 * top * math.exp(-(v.x / 0.085) ** 2)
        # pinch the front of the crown a little
        f = smoothstep(0.02, 0.2, v.z) * max(0.0, -v.y / 0.25)
        v.x *= 1 - 0.16 * f
        return v
    crown_b.apply(dent)
    _merge(b, crown_b)

    # brim: saddle shape, sides roll up, front/back droop slightly
    def brim_ring(th, r, z):
        k = smoothstep(0.24, 0.42, r) ** 1.4
        x = r * math.cos(th)
        y = r * math.sin(th) * 0.93
        return Vector((x, y, z + k * (0.115 * math.cos(th) ** 2 - 0.03 * math.sin(th) ** 2)))
    b.lathe(loop((0.235, -0.135), (0.32, -0.138), (0.41, -0.136), (0.425, -0.12), (0.41, -0.104),
                 (0.32, -0.104), (0.24, -0.09)), wood, S, ring_fn=brim_ring)
    # stitched rings on the brim
    b.lathe(loop((0.372, -0.106), (0.380, -0.097), (0.388, -0.106)), cream, S, ring_fn=brim_ring)
    # leather band
    b.lathe(loop((0.235, -0.04), (0.256, -0.04), (0.262, -0.034), (0.262, 0.045), (0.256, 0.05),
                 (0.235, 0.05)), leather, S)
    # sheriff star badge on the band front
    b.prism(H.star_outline(0.085, 0.040), 0.0, 0.016, gold, 0.005, front_xf(-0.262, 0.006))
    for k in range(5):
        a = math.radians(90 + 72 * k)
        b.ellipsoid((0.085 * math.cos(a), 0.085 * math.sin(a), 0.017), (0.011, 0.011, 0.008), gold, 6, 2,
                    front_xf(-0.262, 0.006))
    return b


def _merge(dst, src):
    """Copy src builder geometry into dst (same materials list mapped)."""
    import bmesh
    idx_map = {}
    for i, m in enumerate(src.mats):
        idx_map[i] = dst._mi(m)
    vmap = {}
    for v in src.bm.verts:
        vmap[v] = dst.bm.verts.new(v.co)
    for f in src.bm.faces:
        nf = dst.bm.faces.new([vmap[v] for v in f.verts])
        nf.material_index = idx_map[f.material_index]
    src.bm.free()


@H.hat("chef")
def chef():
    b = Builder()
    white, cream, red = mat("white"), mat("cream"), mat("red")
    S = 32
    FL = 8  # flutes

    def flute(th, r, z):
        k = smoothstep(0.02, 0.12, z) * smoothstep(0.42, 0.30, z)
        rr = r * (1 + 0.075 * k * math.cos(FL * th))
        return Vector((rr * math.cos(th), rr * math.sin(th), z))
    # puffy fluted top
    b.lathe([(0.27, -0.04), (0.285, 0.0), (0.30, 0.05), (0.325, 0.12), (0.345, 0.20), (0.342, 0.27),
             (0.315, 0.33), (0.25, 0.372), (0.15, 0.392), (0.06, 0.397)],
            lambda i, j: cream if (j % 4 in (1, 2) and 2 <= i <= 7) else white, S, ring_fn=flute)
    # band
    b.lathe(loop((0.262, -0.135), (0.290, -0.135), (0.296, -0.128), (0.296, -0.02), (0.288, -0.008),
                 (0.262, -0.008)), cream, S)
    # red stripe ring on the band
    b.lathe(loop((0.292, -0.085), (0.299, -0.079), (0.299, -0.058), (0.292, -0.052)), red, S)
    return b
