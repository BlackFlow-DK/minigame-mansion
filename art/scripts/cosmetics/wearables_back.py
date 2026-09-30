"""Back wearables: cape, backpack, angel_wings, jetpack, turtle_shell.

Run: tools\\blender-run.ps1 art\\scripts\\cosmetics\\wearables_back.py [item_id ...]
Origin of every model = BackSocket (0, 0.50, -0.37) on the back surface. Nothing may reach the front (z <= 0.02).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mathutils import Matrix, Vector  # noqa: E402

import artlib  # noqa: E402
from wearables_lib import (Part, basis_from_y, blob_ring, blob_surface, blob_xy, catmull,  # noqa: E402
                           export_item, ry, rz)

SOCKET = (0.0, 0.50, -0.37)
TAU = 2 * math.pi
PI = math.pi


# ------------------------------------------------------------------ cape  (real body, catalog fit = identity)
def cape(sock):
    """Gathered into a small collar high on the back, flaring out away from the body to a wavy hem.
    It spans only +-26..52 degrees round the back (never the sides) and stays clear of the belly."""
    ytop, ybot = 0.63, 0.14

    def cp(u, s, extra=0.0):
        f1 = math.cos(5 * PI * u)
        f2 = 0.5 * math.cos(3 * PI * u + 1.0)
        y = ytop + (ybot - ytop) * s - 0.034 * s ** 2.5 * (0.5 - 0.5 * f1)
        th = math.radians(26 + 26 * s) * u
        gap = 0.016 + 0.085 * s ** 1.3 + 0.03 * s * (0.8 * f1 + f2)
        return blob_ring(PI + th, y, gap + extra)

    cloth = Part("Cloth", sock, [("CapeRed", "red", 0.8)], closed=True, outward=(0, 0.45, 0), solidify=0.014, sharp=70)
    cloth.grid(lambda u, v: cp(u * 2 - 1, v), 24, 6)
    collar = Part("Collar", sock, [("CapeCream", "cream", 0.85)], sharp=75)
    collar.tube([cp(-0.96 + 1.92 * i / 18, 0.0, 0.012) for i in range(19)],
                lambda t: 0.008 + 0.018 * (1 - (2 * t - 1) ** 2), sides=6)
    trim = Part("Trim", sock, [("CapeGold", "gold", 0.4)], sharp=75)
    trim.tube([cp(-1 + 2 * i / 26, 1.0, 0.003) for i in range(27)], 0.009, sides=4)
    c = cp(0.0, 0.0, 0.034)
    trim.ellipsoid(c, (0.028, 0.012, 0.028), seg=8, rings=4, rot=basis_from_y(Vector((0, 0, -1))))
    return [cloth, collar, trim]


# ------------------------------------------------------------------ backpack
def backpack(sock):
    bev = (0.03, 2)
    pack = Part("Pack", sock, [("PackTeal", "teal", 0.7)], sharp=55, bevel=bev)
    pack.box((0, 0.445, -0.435), (0.29, 0.34, 0.17))
    flap = Part("Flap", sock, [("PackWood", "wood", 0.75)], sharp=55, bevel=(0.022, 2))
    flap.box((0, 0.575, -0.445), (0.30, 0.11, 0.19))
    pocket = Part("Pocket", sock, [("PackCream", "cream", 0.8)], sharp=55, bevel=(0.02, 2))
    pocket.box((0, 0.35, -0.53), (0.20, 0.13, 0.05))
    pouches = Part("Pouches", sock, [("PackWood", "wood", 0.75)], sharp=55)
    for sx in (-1, 1):
        pouches.tube([Vector((sx * 0.175, 0.30, -0.405)), Vector((sx * 0.175, 0.31, -0.405)), Vector((sx * 0.175, 0.44, -0.405)), Vector((sx * 0.175, 0.45, -0.405))],
                     lambda t: 0.046 - 0.02 * (abs(t - 0.5) * 2) ** 6, sides=10)
    gold = Part("Buckles", sock, [("PackGold", "gold", 0.35)], sharp=55, bevel=(0.006, 1))
    gold.box((0, 0.532, -0.545), (0.055, 0.05, 0.022))
    gold.box((0, 0.35, -0.562), (0.036, 0.03, 0.014))
    handle = Part("Handle", sock, [("PackCream", "cream", 0.8)], sharp=75)
    handle.tube(catmull([Vector((-0.06, 0.63, -0.445)), Vector((-0.04, 0.675, -0.445)), Vector((0.04, 0.675, -0.445)), Vector((0.06, 0.63, -0.445))], 3), 0.011, sides=5)
    return [pack, flap, pocket, pouches, gold, handle]


# ------------------------------------------------------------------ angel_wings
def angel_wings(sock):
    parts = []
    yaw = ry(28)
    arm_pts = catmull([Vector(p) for p in [(0, 0, 0), (0.12, 0.12, 0), (0.26, 0.22, 0), (0.42, 0.25, 0), (0.55, 0.17, 0)]], 2)

    def arm_at(s):
        f = s * (len(arm_pts) - 1)
        i = min(int(f), len(arm_pts) - 2)
        return arm_pts[i].lerp(arm_pts[i + 1], f - i)

    rows = [  # (bases along arm, fan angle deg from straight down toward outward, length, half width, layer depth, material)
        ([0.42, 0.54, 0.66, 0.78, 0.90, 1.0], [4, 15, 26, 37, 48, 58], [0.30, 0.33, 0.34, 0.33, 0.30, 0.26], 0.062, 0.0, 0),
        ([0.12, 0.26, 0.40], [-10, 0, 10], [0.22, 0.24, 0.24], 0.058, 0.012, 1),
        ([0.08, 0.28], [-16, 0], [0.14, 0.15], 0.05, 0.026, 0),
    ]
    for sgn in (-1, 1):
        P = Vector((sgn * 0.10, 0.56, -0.35))
        w = Part("WingR" if sgn > 0 else "WingL", sock, [("WingWhite", "white", 0.6), ("WingCream", "cream", 0.6), ("WingGold", "gold", 0.4)],
                 origin=P, sharp=65)

        def to_world(u, v, wd, sgn=sgn, P=P):
            q = yaw @ Vector((u, v, -wd))
            return Vector((P.x + sgn * q.x, P.y + q.y, P.z + q.z))

        w.tube([to_world(p.x, p.y, 0.0) for p in arm_pts], lambda t: 0.032 - 0.014 * t, sides=5, m=0)
        w.ellipsoid(P + Vector((0, 0, -0.005)), (0.04, 0.04, 0.04), seg=8, rings=4, m=2)
        for bases, angs, lens, hw, layer, m in rows:
            for s, a, L in zip(bases, angs, lens):
                b = arm_at(s)
                d = Vector((math.sin(math.radians(a)), -math.cos(math.radians(a)), 0))
                c_local = b + d * (L / 2)
                cw = to_world(c_local.x, c_local.y, layer)
                # feather axes: local y along the feather, local z = wing-plane normal; mirror x for the left wing
                R = yaw @ rz(180 + a)
                if sgn < 0:
                    R = Matrix.Diagonal(Vector((-1, 1, 1))) @ R @ Matrix.Diagonal(Vector((-1, 1, 1)))
                w.ellipsoid(cw, (hw, L / 2, 0.012), seg=8, rings=4, rot=R, m=m)
        parts.append(w)
    return parts


# ------------------------------------------------------------------ jetpack
def jetpack(sock):
    y0 = 0.25
    zc = -0.44
    prof = [  # (radius, height, material of the segment that starts here)
        (0.0, 0.0, 0), (0.055, 0.0, 0), (0.078, 0.018, 0), (0.085, 0.045, 3),
        (0.094, 0.05, 3), (0.094, 0.072, 3), (0.085, 0.077, 0),
        (0.085, 0.24, 3), (0.094, 0.245, 3), (0.094, 0.267, 3), (0.085, 0.272, 0),
        (0.085, 0.29, 1), (0.072, 0.325, 1), (0.048, 0.355, 1), (0.022, 0.375, 1), (0.0, 0.382, 1),
    ]
    tanks = Part("Tanks", sock, [("JetTeal", "teal", 0.55), ("JetRed", "red", 0.45), ("JetCharcoal", "charcoal", 0.6), ("JetGold", "gold", 0.35)], sharp=60)
    noz = Part("Nozzles", sock, [("JetCharcoal", "charcoal", 0.6)], sharp=60)
    fl = Part("Flames", sock, [("FlameRed", "red", 0.5), ("FlameGold", "gold", 0.5)], sharp=60)
    for sx in (-1, 1):
        c = Vector((sx * 0.105, y0, zc))
        tanks.lathe([(r, h) for r, h, _ in prof], c, sides=10, mat_fn=lambda j: prof[j][2])
        noz.tube([c + Vector((0, 0.005, 0)), c + Vector((0, -0.03, 0)), c + Vector((0, -0.06, 0))], lambda t: 0.05 + 0.02 * t, sides=10)
        base = c + Vector((0, -0.06, 0))
        fl.lathe([(0.052, 0.0), (0.058, -0.02), (0.044, -0.055), (0.022, -0.09), (0.0, -0.115)], base, sides=8, m=0)
        fl.lathe([(0.03, 0.0), (0.034, -0.016), (0.024, -0.045), (0.011, -0.075), (0.0, -0.095)], base + Vector((0, -0.004, 0)), sides=8, m=1)
    gear = Part("Straps", sock, [("JetWood", "wood", 0.75), ("JetGold", "gold", 0.35)], sharp=55, bevel=(0.01, 1))
    gear.box((0, 0.33, -0.405), (0.22, 0.045, 0.075))
    hose = Part("Hose", sock, [("JetGold", "gold", 0.35)], sharp=75)
    hose.tube(catmull([Vector((-0.105, 0.62, zc)), Vector((-0.05, 0.665, zc)), Vector((0.05, 0.665, zc)), Vector((0.105, 0.62, zc))], 3), 0.011, sides=5)
    return [tanks, noz, fl, gear, hose]


# ------------------------------------------------------------------ turtle_shell
def turtle_shell(sock):
    cx, cy, ax, ay, H, off0 = 0.0, 0.44, 0.29, 0.27, 0.17, -0.004

    def dome_off(x, y):
        rho2 = ((x - cx) / ax) ** 2 + ((y - cy) / ay) ** 2
        return off0 + H * math.sqrt(max(0.0, 1.0 - rho2))

    shell = Part("Shell", sock, [("ShellBrown", "wood", 0.7)], closed=False, outward=(0, 0.45, 0), sharp=70)
    shell.cap(cx, cy, ax, ay, H, off0, False, 0.5, seg=20, rings=6)
    plates = Part("Plates", sock, [("ShellGreen", "green", 0.6)], sharp=60, bevel=(0.006, 1))
    centers = [(cx, cy)] + [(cx + 0.142 * math.cos(math.radians(60 * k)), cy + 0.142 * math.sin(math.radians(60 * k))) for k in range(6)]
    for px, py in centers:
        poly = [(px + 0.07 * math.cos(math.radians(30 + 60 * i)), py + 0.07 * math.sin(math.radians(30 + 60 * i))) for i in range(6)]
        plates.prism(poly, lambda x, y: blob_xy(x, y, False, dome_off(x, y) + 0.016), lambda x, y: blob_xy(x, y, False, dome_off(x, y) - 0.006))
    rim = Part("Rim", sock, [("ShellCream", "cream", 0.8)], sharp=75)
    rim.tube([blob_xy(cx + ax * math.cos(TAU * i / 24), cy + ay * math.sin(TAU * i / 24), False, 0.0) for i in range(24)], 0.02, sides=5, closed=True)
    return [shell, plates, rim]


# (builder, uses the real blob profile). Items still on the two-sphere stand-in keep their tuned catalog fits.
ITEMS = {
    "cape": (cape, True),
    "backpack": (backpack, False),
    "angel_wings": (angel_wings, False),
    "jetpack": (jetpack, False),
    "turtle_shell": (turtle_shell, False),
}

if __name__ == "__main__":
    only = artlib.script_args()
    for item_id, (fn, real) in ITEMS.items():
        if not only or item_id in only:
            export_item("back", item_id, fn, SOCKET, real)
