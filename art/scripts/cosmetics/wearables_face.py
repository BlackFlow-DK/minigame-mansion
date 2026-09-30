"""Face wearables: round_glasses, star_shades, monocle, moustache, clown_nose, eye_patch.

Run: tools\\blender-run.ps1 art\\scripts\\cosmetics\\wearables_face.py [item_id ...]
Origin of every model = FaceSocket (0, 0.68, 0.37) on the head surface between the eyes.
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mathutils import Vector  # noqa: E402

import artlib  # noqa: E402
from wearables_lib import (Part, V, basis_from_y, blob_normal, blob_surface, blob_xy, catmull,  # noqa: E402
                           circle_poly, export_item, rz, star_poly)

SOCKET = (0.0, 0.68, 0.37)
EX, EY = 0.14, 0.68  # eye centres (x = +-EX)


def ring_pts(cx, cy, rad, off, n=20):
    return [blob_xy(cx + rad * math.cos(2 * math.pi * i / n), cy + rad * math.sin(2 * math.pi * i / n), True, off) for i in range(n)]


def temple_pts(x0, y0, sign, off, phi_end=1.32, n=8):
    """A glasses arm hugging the head from (x0, y0) round the side towards the ear."""
    p0 = blob_xy(x0 * sign, y0, True, off)
    phi0 = math.atan2(p0.x, p0.z)
    return [blob_surface(phi0 + (sign * phi_end - phi0) * (i / (n - 1)), y0 - 0.025 * (i / (n - 1)), off) for i in range(n)]


def surf_path(ctrl_xy, off, per_seg=2, sign=1):
    pts = catmull([Vector((sign * x, y, 0)) for x, y in ctrl_xy], per_seg)
    return [blob_xy(p.x, p.y, True, off) for p in pts]


# ------------------------------------------------------------------ round_glasses
def round_glasses(sock):
    m = ("GlassesRed", "red", 0.45)
    fr = Part("Frame", sock, [m], sharp=75)
    for s in (-1, 1):
        fr.tube(ring_pts(s * EX, EY, 0.112, 0.03, 28), 0.013, sides=6, closed=True)
        fr.tube(temple_pts(EX + 0.112, 0.70, s, 0.016), 0.009, sides=5)
    fr.tube(surf_path([(-0.026, 0.69), (-0.012, 0.712), (0.0, 0.716), (0.012, 0.712), (0.026, 0.69)], 0.03), 0.009, sides=5)
    return [fr]


# ------------------------------------------------------------------ star_shades
def star_shades(sock):
    gold = ("ShadesGold", "gold", 0.4)
    frame = Part("Frame", sock, [gold], sharp=60, bevel=(0.004, 1))
    lens = Part("Lens", sock, [("ShadesLens", "lens", 0.25)], sharp=60, bevel=(0.003, 1))
    glint = Part("Glint", sock, [("ShadesGlint", "white", 0.3)])
    arms = Part("Arms", sock, [gold], sharp=75)
    front = lambda off: (lambda x, y: blob_xy(x, y, True, off))  # noqa: E731
    for s in (-1, 1):
        cx = s * EX
        frame.prism(star_poly(cx, 0.685, 0.13, 0.062), front(0.046), front(0.016))
        lens.prism(star_poly(cx, 0.685, 0.104, 0.05), front(0.054), front(0.02))
        glint.prism(star_poly(cx - s * 0.03, 0.72, 0.024, 0.007, points=4, rot_deg=90), front(0.06), front(0.05))
        arms.tube(temple_pts(EX + 0.124, 0.722, s, 0.02), 0.009, sides=5)
    arms.tube(surf_path([(-0.03, 0.716), (0.0, 0.738), (0.03, 0.716)], 0.05, per_seg=3), 0.01, sides=5)
    return [frame, lens, glint, arms]


# ------------------------------------------------------------------ monocle
def monocle(sock):
    gold = ("MonocleGold", "gold", 0.35)
    ring = Part("Ring", sock, [gold], sharp=75)
    cx = EX
    ring.tube(ring_pts(cx, EY, 0.106, 0.03, 22), 0.014, sides=6, closed=True)
    ring.ellipsoid(blob_xy(cx + 0.106 * math.cos(math.radians(-58)), EY + 0.106 * math.sin(math.radians(-58)), True, 0.032), (0.02, 0.02, 0.018), seg=8, rings=4)
    # chain: dense path along the chest, links every ~0.05
    ctrl = [(cx + 0.106 * math.cos(math.radians(-58)), EY + 0.106 * math.sin(math.radians(-58))), (0.225, 0.52), (0.255, 0.45), (0.268, 0.38), (0.262, 0.31)]
    dense = surf_path(ctrl, 0.016, per_seg=10)
    chain = Part("Chain", sock, [gold], sharp=80)
    acc, last, pts, tang = 0.0, dense[0], [], []
    step = 0.052
    for i in range(1, len(dense)):
        acc += (dense[i] - dense[i - 1]).length
        if acc >= step * (len(pts) + 1):
            pts.append(dense[i])
            tang.append((dense[min(i + 1, len(dense) - 1)] - dense[i - 1]).normalized())
    for k, (p, t) in enumerate(zip(pts, tang)):
        n = blob_normal(p)
        w = n if k % 2 == 0 else t.cross(n).normalized()
        loop = [p + t * (0.03 * math.cos(2 * math.pi * i / 6)) + w * (0.0135 * math.sin(2 * math.pi * i / 6)) for i in range(6)]
        chain.tube(loop, 0.0065, sides=4, closed=True)
    if pts:
        chain.ellipsoid(pts[-1] + tang[-1] * 0.03, (0.016, 0.016, 0.016), seg=8, rings=4)
    return [ring, chain]


# ------------------------------------------------------------------ moustache
def moustache(sock):
    p = Part("Moustache", sock, [("MoustacheDark", "charcoal", 0.55)], sharp=85)
    ctrl = [(0.0, 0.598), (0.045, 0.588), (0.10, 0.583), (0.155, 0.591), (0.195, 0.611), (0.212, 0.636)]
    for s in (-1, 1):
        p.tube(surf_path(ctrl, 0.028, per_seg=2, sign=s), lambda t: 0.006 + 0.022 * (1 - t) ** 0.7, sides=8)
    p.ellipsoid(blob_xy(0, 0.597, True, 0.026), (0.052, 0.034, 0.03), seg=10, rings=6)
    return [p]


# ------------------------------------------------------------------ clown_nose
def clown_nose(sock):
    red = Part("Nose", sock, [("NoseRed", "red", 0.3)], sharp=80)
    c = Vector((0.0, 0.68, 0.37 + 0.032))
    red.ellipsoid(c, (0.066, 0.066, 0.066), seg=14, rings=10)
    d = Vector((-0.35, 0.45, 0.82)).normalized()
    gl = Part("Shine", sock, [("NoseShine", "white", 0.25)], sharp=85)
    gl.ellipsoid(c + d * 0.060, (0.017, 0.007, 0.011), seg=8, rings=4, rot=basis_from_y(d))
    return [red, gl]


# ------------------------------------------------------------------ eye_patch
def eye_patch(sock):
    ch = ("PatchCharcoal", "charcoal", 0.7)
    cx = -EX
    patch = Part("Patch", sock, [ch], closed=False, outward=(0, 0.62, 0), sharp=70)
    patch.cap(cx, EY, 0.125, 0.112, 0.064, -0.004, True, 0.5, seg=20, rings=7)
    strap = Part("Strap", sock, [ch], sharp=75)
    for ctrl in (
        [(-0.22, 0.775), (-0.02, 0.83), (0.25, 0.885), (0.6, 0.92), (1.0, 0.90), (1.5, 0.85), (2.0, 0.80)],
        [(-0.76, 0.70), (-1.05, 0.69), (-1.5, 0.68), (-2.0, 0.67)],
    ):
        pts = catmull([Vector((a, y, 0)) for a, y in ctrl], 2)
        strap.tube([blob_surface(q.x, q.y, 0.01) for q in pts], 0.011, sides=5)
    x_mark = Part("Stitch", sock, [("PatchCream", "cream", 0.6)], sharp=85, bevel=(0.002, 1))

    def dome(x, y):
        rho2 = ((x - cx) / 0.125) ** 2 + ((y - EY) / 0.112) ** 2
        return -0.004 + 0.064 * math.sqrt(max(0.0, 1.0 - rho2))

    L, w = 0.048, 0.0115
    plus = [(L, -w), (L, w), (w, w), (w, L), (-w, L), (-w, w), (-L, w), (-L, -w), (-w, -w), (-w, -L), (w, -L), (w, -w)]
    ca, sa = math.cos(math.radians(45)), math.sin(math.radians(45))
    cross = [(cx + px * ca - py * sa, EY + px * sa + py * ca) for px, py in plus]
    x_mark.prism(cross, lambda x, y: blob_xy(x, y, True, dome(x, y) + 0.007), lambda x, y: blob_xy(x, y, True, dome(x, y) - 0.003))
    return [patch, strap, x_mark]


def _rot_in_plane(n, ang_deg):
    """Rotation whose local z is the surface normal and whose local x is world x rotated by ang about n."""
    from mathutils import Matrix
    z = n.normalized()
    x = (Vector((1, 0, 0)) - z * z.x).normalized()
    y = z.cross(x)
    base = Matrix((x, y, z)).transposed()
    return base @ Matrix.Rotation(math.radians(ang_deg), 3, "Z")


ITEMS = {
    "round_glasses": round_glasses,
    "star_shades": star_shades,
    "monocle": monocle,
    "moustache": moustache,
    "clown_nose": clown_nose,
    "eye_patch": eye_patch,
}

if __name__ == "__main__":
    only = artlib.script_args()
    for item_id, fn in ITEMS.items():
        if not only or item_id in only:
            export_item("face", item_id, fn, SOCKET)
