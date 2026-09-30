"""Neck wearables: scarf, bow_tie, gold_chain, flower_lei, bandana.

Run: tools\\blender-run.ps1 art\\scripts\\cosmetics\\wearables_neck.py [item_id ...]
Origin of every model = NeckSocket (0, 0.40, 0). Everything stays below y = 0.52 (the mouth is at ~0.55).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mathutils import Matrix, Vector  # noqa: E402

import artlib  # noqa: E402
from wearables_lib import (Part, basis_from_y, blob_normal, blob_surface, blob_xy, catmull,  # noqa: E402
                           export_item, rz)

SOCKET = (0.0, 0.40, 0.0)
TAU = 2 * math.pi


def back_w(phi, a0=1.4, a1=2.4):
    """0 over the front and sides, smoothly 1 over the back (|phi| from a0 to a1 rad): neck items go flat there so they sit under back items."""
    a = abs(math.remainder(phi, TAU))
    k = min(1.0, max(0.0, (a - a0) / (a1 - a0)))
    return k * k * (3 - 2 * k)


# ------------------------------------------------------------------ scarf  (real body)
def scarf(sock):
    wrap = Part("Wrap", sock, [("ScarfRed", "red", 0.85), ("ScarfCream", "cream", 0.85)], sharp=75)
    for y0, t, wob, ph in ((0.385, 0.033, 0.010, 0.0), (0.440, 0.034, 0.010, 2.0), (0.494 - 0.034, 0.031, 0.006, 4.0)):
        n = 28
        # cross-section: round (t x t) over the front, a flat ribbon (t x 0.007 thick) over the back
        thick = lambda w, t=t: t - (t - 0.007) * w  # noqa: E731
        pts = [blob_surface(TAU * i / n, y0 + wob * math.cos(TAU * i / n - ph), thick(back_w(TAU * i / n)) + 0.008) for i in range(n)]
        wrap.tube(pts, lambda u, t=t: (t - 0.003 * back_w(TAU * u), thick(back_w(TAU * u))), sides=6, closed=True, mat_fn=lambda i: (i // 2) % 2)
    # hanging end
    tail = Part("Tail", sock, [("ScarfRed", "red", 0.85), ("ScarfCream", "cream", 0.85)], closed=True,
                outward=(0, 0.4, 0), solidify=0.034, sharp=70)
    rows = []
    K = 12
    for j in range(K + 1):
        v = j / K
        y = 0.43 - 0.32 * v
        R = blob_surface(0, y, 0)
        half = 0.068 / max(0.15, math.hypot(R.x, R.z)) * (1.0 + 0.25 * v)
        pc = 0.42 + 0.06 * math.sin(v * math.pi)
        rows.append([blob_surface(pc + (u / 4 - 0.5) * 2 * half, y, 0.03) for u in range(5)])
    tail.sheet(rows, m=0, mat_fn=lambda j, i: (j // 2) % 2)
    fringe = Part("Fringe", sock, [("ScarfCream", "cream", 0.85)], sharp=80)
    for u in range(5):
        p = rows[-1][u]
        low = blob_surface(0.42 + (u / 4 - 0.5) * 0.24, 0.045, 0.03)
        fringe.tube([p, (p + low) * 0.5, low], 0.011, sides=5)
    return [wrap, tail, fringe]


# ------------------------------------------------------------------ bow_tie
def bow_tie(sock):
    yc = 0.425
    wings = Part("Wings", sock, [("BowRed", "red", 0.5)], sharp=70)
    for s in (-1, 1):
        pts = [blob_xy(s * x, yc, True, 0.034) for x in (0.03, 0.07, 0.115, 0.155, 0.19)]
        wings.tube(pts, lambda t: (0.017 + 0.048 * t ** 0.9, 0.018 + 0.004 * math.sin(math.pi * t)), sides=8)
    knot = Part("Knot", sock, [("BowKnot", "darkred", 0.5)], sharp=75)
    knot.ellipsoid(blob_xy(0, yc, True, 0.036), (0.036, 0.042, 0.032), seg=10, rings=6)
    band = Part("Band", sock, [("BowBand", "charcoal", 0.6)], sharp=75)
    band.tube([blob_surface(TAU * i / 22, yc - 0.004, 0.014) for i in range(22)], 0.011, sides=5, closed=True)
    return [wings, knot, band]


# ------------------------------------------------------------------ gold_chain
def chain_y(phi):
    return 0.425 - 0.115 * math.cos(phi / 2) ** 2


def gold_chain(sock):
    gold = ("ChainGold", "gold", 0.3)
    links = Part("Links", sock, [gold], sharp=85)
    # dense front path, arc-length walk
    lim = 1.5
    N = 160
    dense = [blob_surface(-lim + 2 * lim * i / N, chain_y(-lim + 2 * lim * i / N), 0.02) for i in range(N + 1)]
    cum = [0.0]
    for i in range(1, len(dense)):
        cum.append(cum[-1] + (dense[i] - dense[i - 1]).length)
    s_mid = cum[N // 2]

    def at(s):
        s += s_mid
        for i in range(1, len(cum)):
            if cum[i] >= s:
                f = (s - cum[i - 1]) / max(1e-9, cum[i] - cum[i - 1])
                p = dense[i - 1].lerp(dense[i], f)
                return p, (dense[i] - dense[i - 1]).normalized()
        return dense[-1], (dense[-1] - dense[-2]).normalized()

    step = 0.078
    k_max = int((cum[-1] / 2) / step)
    for k in range(-k_max, k_max + 1):
        p, t = at(k * step)
        n = blob_normal(p)
        w = n if k % 2 == 0 else t.cross(n).normalized()
        loop = [p + t * (0.043 * math.cos(TAU * i / 6)) + w * (0.021 * math.sin(TAU * i / 6)) for i in range(6)]
        links.tube(loop, 0.0115, sides=4, closed=True)
    # rope at the back: thins out and lies flat (top <= ~0.014 above the body) so it sits under a shell/backpack
    nb = 18
    phis = [lim - 0.05 + (TAU - 2 * lim + 0.1) * i / nb for i in range(nb + 1)]
    wts = [1.0 - back_w(ph, 1.4, 2.3) for ph in phis]
    back = [blob_surface(ph, chain_y(ph), 0.008 + 0.012 * w) for ph, w in zip(phis, wts)]
    links.tube(back, lambda u: 0.006 + 0.006 * wts[min(nb, int(round(u * nb)))], sides=4)
    # medallion
    p, t = at(0.0)
    top = p + Vector((0, -0.02, 0))
    yc = blob_xy(0, 0.222, True, 0).y
    c0 = blob_surface(0, yc, 0.032)
    nrm = blob_normal(c0)
    R = basis_from_y(nrm)
    medal = Part("Medallion", sock, [gold, ("MedalGem", "red", 0.25)], sharp=60)
    medal.lathe([(0, 0.011), (0.052, 0.011), (0.064, 0.007), (0.068, 0.0), (0.064, -0.007), (0.052, -0.011), (0, -0.011)], c0, nrm, sides=14, m=0)
    medal.tube([c0 + R @ Vector((0.066 * math.cos(TAU * i / 14), 0.0, 0.066 * math.sin(TAU * i / 14))) for i in range(14)], 0.0105, sides=5, closed=True)
    medal.lathe([(0, 0.024), (0.02, 0.019), (0.034, 0.009), (0.034, 0.0), (0, 0.0)], c0 + nrm * 0.006, nrm, sides=10, m=1)
    up_t = (Vector((0, 1, 0)) - nrm * nrm.y).normalized()
    side = up_t.cross(nrm).normalized()
    bc = c0 + up_t * 0.074
    medal.tube([bc + up_t * (0.02 * math.cos(TAU * i / 6)) + side * (0.011 * math.sin(TAU * i / 6)) for i in range(6)], 0.0055, sides=4, closed=True)
    return [links, medal]


# ------------------------------------------------------------------ flower_lei
def flower_lei(sock):
    cols = [("LeiPink", "pink", 0.7), ("LeiRed", "red", 0.7), ("LeiCream", "cream", 0.7), ("LeiBlue", "blue", 0.7), ("LeiGold", "gold", 0.6)]
    fl = Part("Flowers", sock, cols, sharp=75)
    stem = Part("Garland", sock, [("LeiGreen", "green", 0.75)], sharp=75)

    def gy(phi):
        return 0.392 + 0.012 * math.sin(3 * phi)

    stem.tube([blob_surface(TAU * i / 24, gy(TAU * i / 24), 0.02) for i in range(24)], 0.017, sides=5, closed=True)
    n = 7
    for k in range(n):
        phi = TAU * k / n + 0.1
        c = blob_surface(phi, gy(phi), 0.03)
        nrm = blob_normal(c)
        e1 = Vector((math.cos(phi), 0, -math.sin(phi)))
        e2 = nrm.cross(e1).normalized()
        pm = k % 4
        for i in range(5):
            th = TAU * i / 5 + k
            d = e1 * math.cos(th) + e2 * math.sin(th)
            perp = nrm.cross(d).normalized()
            R = Matrix((perp, nrm, d)).transposed()
            fl.ellipsoid(c + d * 0.052 + nrm * 0.014, (0.036, 0.017, 0.054), seg=6, rings=3, rot=R, m=pm)
        fl.ellipsoid(c + nrm * 0.03, (0.03, 0.02, 0.03), seg=6, rings=3, m=4)
        # a leaf between this flower and the next
        pl = phi + TAU / n / 2
        lc = blob_surface(pl, gy(pl), 0.03)
        ln = blob_normal(lc)
        tang = Vector((math.cos(pl), 0, -math.sin(pl)))
        stem.ellipsoid(lc, (0.022, 0.012, 0.04), seg=6, rings=3, rot=_leaf_rot(tang, ln))
    return [fl, stem]


def _leaf_rot(tang, n):
    """Rotation with local z along `tang` (the leaf's length), local y along the surface normal."""
    from mathutils import Matrix
    z = tang.normalized()
    y = (n - z * n.dot(z)).normalized()
    x = y.cross(z)
    return Matrix((x, y, z)).transposed()


# ------------------------------------------------------------------ bandana
def bandana(sock):
    red = ("BandanaRed", "red", 0.8)
    cream = ("BandanaCream", "cream", 0.8)
    band = Part("Band", sock, [red], closed=True, outward=(0, 0.4, 0), solidify=0.012, sharp=70)
    # over the back the band lies flat (mid-surface 0.009 above the body) so it disappears under a backpack or shell
    rows = [[blob_surface(TAU * i / 24, y, 0.009 + (0.013 + 0.004 * math.sin(TAU * i / 24 * 6)) * (1 - back_w(TAU * i / 24))) for i in range(24)] for y in (0.385, 0.44, 0.495)]
    band.sheet(rows, closed_u=True)
    tri = Part("Triangle", sock, [red], closed=True, outward=(0, 0.4, 0), solidify=0.016, sharp=70)
    rows = []
    for j in range(9):
        v = j / 8
        y = 0.40 - 0.20 * v
        half = 0.50 * (1 - v) ** 0.8 + 0.03
        rows.append([blob_surface((u / 8 * 2 - 1) * half, y, 0.024 + 0.014 * math.sin(math.pi * v) * (1 - (u / 4 - 1) ** 2)) for u in range(9)])
    tri.sheet(rows)
    dots = Part("Dots", sock, [cream], sharp=80)
    spots = [(0.0, 0.345), (-0.24, 0.36), (0.24, 0.36), (0.0, 0.28), (-0.12, 0.31), (0.12, 0.31)]
    for phi, y in spots:
        c = blob_surface(phi, y, 0.046)
        dots.ellipsoid(c, (0.02, 0.006, 0.02), seg=6, rings=3, rot=basis_from_y(blob_normal(c)))
    for i in range(9):
        phi = TAU * (i + 0.5) / 9
        if back_w(phi, 1.4, 2.0) > 0.0:
            continue  # no bumps over the back
        c = blob_surface(phi, 0.44, 0.03)
        dots.ellipsoid(c, (0.017, 0.006, 0.017), seg=6, rings=3, rot=basis_from_y(blob_normal(c)))
    return [band, tri, dots]


# (builder, uses the real blob profile). Items still on the two-sphere stand-in keep their tuned catalog fits.
ITEMS = {
    "scarf": (scarf, True),
    "bow_tie": (bow_tie, False),
    "gold_chain": (gold_chain, True),
    "flower_lei": (flower_lei, False),
    "bandana": (bandana, True),
}

if __name__ == "__main__":
    only = artlib.script_args()
    for item_id, (fn, real) in ITEMS.items():
        if not only or item_id in only:
            export_item("neck", item_id, fn, SOCKET, real)
