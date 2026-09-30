"""Mansion kit: furniture (armchair, sofa, side table, bookshelf, piano, fireplace, grandfather clock, trophy pedestal).
Every piece faces -Y (Godot +Z), origin at the base centre of its footprint."""
import math
import random

import bmesh

from kit import Kit, star_pts, arch_pts


def _legs(m, xs, ys, h=0.18, mat="DarkWood"):
    for x in xs:
        for y in ys:
            m.cyl((x, y, h / 2), 0.055, h, mat, 8, r2=0.035)


def armchair():
    """1.0 x 1.0 x 1.1: teal wing-less club chair, cream seat cushion."""
    m = Kit()
    _legs(m, (-0.38, 0.38), (-0.38, 0.38))
    m.box(-0.5, 0.5, -0.5, 0.5, 0.16, 0.42, "Teal", 0.06)                  # base
    m.box(-0.5, 0.5, 0.26, 0.5, 0.16, 1.02, "Teal", 0.07)                  # back
    m.cyl((0, 0.38, 1.02), 0.12, 1.0, "Teal", 10, axis="x")               # rolled top
    for s in (-1, 1):
        m.box(s * 0.32, s * 0.5, -0.5, 0.3, 0.16, 0.66, "Teal", 0.06)      # arms
        m.cyl((s * 0.41, -0.1, 0.68), 0.1, 0.84, "Teal", 10, axis="y")     # arm roll
    m.box(-0.31, 0.31, -0.5, 0.28, 0.42, 0.56, "Cream", 0.05)              # seat cushion
    m.box(-0.28, 0.28, 0.12, 0.27, 0.56, 0.98, "Cream", 0.06)              # back cushion
    for x in (-0.15, 0.15):
        for z in (0.68, 0.86):
            m.sph((x, 0.1, z), 0.028, "Gold", 8, 5)
    return [m.build("armchair")]


def sofa():
    """2.2 x 0.95 x 1.05: red three-seater with cream cushions."""
    m = Kit()
    _legs(m, (-1.0, 1.0), (-0.38, 0.38))
    m.box(-1.1, 1.1, -0.475, 0.475, 0.16, 0.42, "Red", 0.06)
    m.box(-1.1, 1.1, 0.24, 0.475, 0.16, 0.98, "Red", 0.07)
    m.cyl((0, 0.36, 0.98), 0.12, 2.2, "Red", 10, axis="x")
    for s in (-1, 1):
        m.box(s * 0.92, s * 1.1, -0.475, 0.28, 0.16, 0.66, "Red", 0.06)
        m.cyl((s * 1.01, -0.1, 0.68), 0.1, 0.8, "Red", 10, axis="y")
    for cx in (-0.42, 0.42):
        m.box(cx - 0.4, cx + 0.4, -0.47, 0.26, 0.42, 0.56, "Cream", 0.05)
        m.box(cx - 0.38, cx + 0.38, 0.1, 0.25, 0.56, 0.94, "Cream", 0.06)
    for x in (-0.6, -0.2, 0.2, 0.6):
        for z in (0.62, 0.82):
            m.sph((x, 0.235, z), 0.03, "Gold", 8, 5)
    return [m.build("sofa")]


def side_table():
    """0.7 x 0.7 x 0.95 including the little vase and books on top."""
    m = Kit()
    m.lathe([(0.24, 0.0, False), (0.24, 0.05), (0.09, 0.14), (0.06, 0.3), (0.075, 0.5), (0.05, 0.64), (0.2, 0.7)],
            (0, 0, 0), "DarkWood", seg=12)
    m.cyl((0, 0, 0.73), 0.35, 0.06, "Wood", 16)
    m.torus((0, 0, 0.73), 0.345, 0.02, "Gold", 24, 6)
    # books
    m.boxc((-0.12, 0.05, 0.795), (0.26, 0.19, 0.05), "Red", 0.01)
    m.boxc((-0.12, 0.05, 0.84), (0.24, 0.17, 0.04), "Teal", 0.01, rot=(0, 0, 12))
    m.boxc((-0.12, 0.05, 0.875), (0.2, 0.15, 0.03), "Cream", 0.01, rot=(0, 0, -8))
    # vase with blooms
    m.lathe([(0.04, 0.0, False), (0.075, 0.07), (0.05, 0.16), (0.06, 0.2)], (0.15, -0.06, 0.76), "Gold", seg=10)
    for i, (dx, dz) in enumerate(((0.0, 0.3), (-0.06, 0.27), (0.06, 0.26))):
        m.cyl((0.15 + dx * 0.5, -0.06, 0.96 + dz * 0.15), 0.008, 0.2 + dz * 0.3, "Green", 5)
        m.sph((0.15 + dx, -0.06, 1.0 + dz * 0.1 - 0.05 + i * 0.01), 0.045, "Red" if i != 1 else "Cream", 8, 6)
    return [m.build("side_table")]


def bookshelf():
    """2.0 x 0.5 x 2.62: dark wood case with 4 shelves of colourful books."""
    rnd = random.Random(7)
    m = Kit()
    m.box(-1.0, -0.92, -0.25, 0.25, 0.0, 2.5, "DarkWood", 0.015)
    m.box(0.92, 1.0, -0.25, 0.25, 0.0, 2.5, "DarkWood", 0.015)
    m.box(-0.92, 0.92, 0.2, 0.25, 0.0, 2.5, "Wood")
    m.box(-0.92, 0.92, -0.25, 0.25, 0.0, 0.2, "DarkWood", 0.02)          # kick plate
    m.box(-0.92, 0.92, -0.25, 0.25, 2.42, 2.5, "DarkWood", 0.02)
    m.box(-1.06, 1.06, -0.3, 0.25, 2.5, 2.62, "Wood", 0.04)               # crown
    m.box(-0.5, 0.5, -0.3, 0.1, 2.62, 2.68, "Gold", 0.02)
    tops = [0.2, 0.75, 1.3, 1.85]
    for i, t in enumerate(tops):
        if i > 0:
            m.box(-0.92, 0.92, -0.24, 0.25, t - 0.05, t, "DarkWood", 0.01)
        x = -0.88
        limit = 0.88
        gap_at = rnd.uniform(-0.2, 0.3) if i in (1, 3) else None
        while x < limit - 0.06:
            if gap_at is not None and abs(x - gap_at) < 0.05:
                # a little ornament instead of books
                if i == 1:
                    m.sph((x + 0.12, 0.0, t + 0.14), 0.13, "Gold", 12, 8)
                    m.cyl((x + 0.12, 0.0, t + 0.02), 0.06, 0.04, "Gold", 8)
                else:
                    m.lathe([(0.07, 0.0, False), (0.12, 0.12), (0.06, 0.3), (0.09, 0.36)], (x + 0.14, 0.0, t), "Teal", seg=10)
                x += 0.34
                gap_at = None
                continue
            w = rnd.uniform(0.05, 0.1)
            h = rnd.uniform(0.28, 0.44)
            mat = rnd.choice(["Red", "Teal", "Green", "Gold", "Cream", "Wallpaper", "Charcoal", "Red", "Teal"])
            lean = rnd.random() < 0.06
            if lean:
                m.boxc((x + 0.09, 0.02, t + h / 2 - 0.01), (w, 0.26, h), mat, rot=(0, 16, 0))
                x += w + 0.14
            else:
                m.box(x, x + w, -0.14, 0.14, t, t + h, mat)
                x += w + 0.005
    return [m.build("bookshelf")]


def piano():
    """Grand piano 1.7 x 2.85 x 1.3 with stool in front (keys face -Y)."""
    m = Kit()
    outline = [(-0.78, -0.8), (0.78, -0.8), (0.8, -0.1), (0.86, 0.35), (0.78, 0.75), (0.5, 1.0), (0.1, 1.1),
               (-0.3, 1.0), (-0.6, 0.85), (-0.78, 0.6)]
    cx = sum(p[0] for p in outline) / len(outline)
    cy = sum(p[1] for p in outline) / len(outline)
    m.poly(outline, "xy", 0.72, 0.95, "Charcoal", 0.025)
    m.poly([(cx + (x - cx) * 0.94, cy + (y - cy) * 0.94) for x, y in outline], "xy", 0.95, 1.0, "Charcoal", 0.012)
    # keybed, keys
    m.box(-0.66, 0.66, -1.0, -0.6, 0.66, 0.78, "Charcoal", 0.02)
    m.box(-0.62, 0.62, -0.98, -0.66, 0.78, 0.82, "Cream")
    n = 14
    kw = 1.24 / n
    for i in range(n):
        if i % 7 in (2, 6):
            continue
        x = -0.62 + kw * (i + 1)
        m.box(x - 0.014, x + 0.014, -0.98, -0.8, 0.82, 0.86, "Charcoal")
    # music desk
    m.boxc((0, -0.55, 1.14), (0.62, 0.025, 0.3), "DarkWood", 0.008, rot=(-18, 0, 0))
    m.boxc((0, -0.575, 1.16), (0.5, 0.012, 0.24), "Cream", rot=(-18, 0, 0))
    for (x, y) in ((-0.65, -0.65), (0.65, -0.65), (0.45, 0.85)):
        m.lathe([(0.045, 0.0, False), (0.05, 0.08), (0.075, 0.6), (0.095, 0.72)], (x, y, 0), "DarkWood", seg=8)
    m.box(-0.03, 0.03, -0.66, -0.64, 0.12, 0.7, "DarkWood")
    for x in (-0.09, 0.0, 0.09):
        m.box(x - 0.025, x + 0.025, -0.9, -0.68, 0.0, 0.03, "Gold")
    m.box(-0.03, 0.03, -0.68, -0.64, 0.12, 0.7, "DarkWood")
    # stool
    m.cyl((0, -1.45, 0.5), 0.26, 0.08, "Red", 14)
    m.cyl((0, -1.45, 0.44), 0.27, 0.04, "DarkWood", 14)
    for a in (90, 210, 330):
        x, y = 0.15 * math.cos(math.radians(a)), 0.15 * math.sin(math.radians(a))
        m.cyl((x, -1.45 + y, 0.21), 0.03, 0.42, "DarkWood", 6, r2=0.02)
    return [m.build("piano")]


def trophy_pedestal():
    """1.2 x 1.2 x 0.75: round winner's podium, walkable top at z=0.72."""
    m = Kit()
    m.cyl((0, 0, 0.06), 0.6, 0.12, "DarkWood", 20)
    m.cyl((0, 0, 0.37), 0.5, 0.5, "Cream", 20)
    m.torus((0, 0, 0.13), 0.5, 0.035, "Gold", 24, 6)
    m.torus((0, 0, 0.61), 0.5, 0.035, "Gold", 24, 6)
    m.cyl((0, 0, 0.665), 0.5, 0.11, "Red", 20)
    m.torus((0, 0, 0.72), 0.5, 0.03, "Gold", 24, 6)
    m.poly(star_pts(0, 0.37, 0.19, 0.08), "xz", -0.55, -0.45, "Gold", 0.008)
    return [m.build("trophy_pedestal")]


def fireplace():
    """2.8 x 1.0 x 5.0 (floor to ceiling). Back at +Y, opening faces -Y. Fire glows via EmitFire."""
    m = Kit()
    m.box(-1.4, 1.4, -0.52, -0.2, 0.0, 0.07, "Charcoal", 0.02)                 # hearth
    for s in (-1, 1):
        m.box(s * 0.62, s * 1.32, -0.3, 0.5, 0.0, 1.9, "Cream", 0.03)          # jambs
        m.box(s * 0.6, s * 1.4, -0.34, 0.5, 0.0, 0.22, "DarkWood", 0.03)       # jamb bases
        m.box(s * 0.6, s * 0.66, -0.32, -0.28, 0.22, 1.4, "Gold", 0.01)        # gold trim strips
        m.box(s * 0.62, s * 0.68, -0.3, 0.3, 0.07, 1.36, "Charcoal")            # sooty liners
        m.box(s * 1.05, s * 1.25, -0.55, -0.3, 1.65, 1.85, "DarkWood", 0.03)   # corbels
    m.box(-1.32, 1.32, -0.3, 0.5, 1.36, 1.9, "Cream", 0.03)                     # lintel
    m.box(-0.66, 0.66, -0.32, -0.28, 1.36, 1.42, "Gold", 0.01)
    m.box(-0.66, 0.66, 0.3, 0.5, 0.0, 1.4, "Charcoal")                          # firebox back
    m.box(-0.66, 0.66, -0.3, 0.3, 0.0, 0.07, "Charcoal")
    m.box(-0.66, 0.66, -0.3, 0.3, 1.32, 1.36, "Charcoal")
    m.box(-1.5, 1.5, -0.52, 0.5, 1.9, 2.05, "Wood", 0.035)                      # mantel shelf
    m.box(-1.0, 1.0, -0.1, 0.5, 2.05, 5.0, "Cream", 0.02)                       # chimney breast
    m.box(-1.1, 1.1, -0.16, 0.5, 4.8, 5.0, "DarkWood", 0.03)
    m.box(-1.06, 1.06, -0.13, 0.5, 2.05, 2.25, "DarkWood", 0.02)
    m.box(-0.72, 0.72, -0.14, -0.1, 2.5, 2.56, "Gold")
    m.box(-0.72, 0.72, -0.14, -0.1, 4.44, 4.5, "Gold")
    for s in (-1, 1):
        m.box(s * 0.72 - 0.03, s * 0.72 + 0.03, -0.14, -0.1, 2.5, 4.5, "Gold")
    # fire
    m.cyl((0, 0.05, 0.19), 0.09, 0.95, "DarkWood", 8, axis="x")
    m.cyl((-0.12, -0.1, 0.32), 0.075, 0.7, "Wood", 8, axis="x")
    m.cyl((0.1, 0.12, 0.17), 0.07, 0.55, "Wood", 8, axis="y")
    m.box(-0.5, 0.5, -0.15, 0.4, 0.07, 0.12, "EmitFire", 0.02)
    for (x, y, h, r) in ((-0.3, 0.05, 0.68, 0.2), (0.0, 0.0, 1.0, 0.26), (0.3, 0.08, 0.78, 0.21), (0.08, -0.14, 0.55, 0.17)):
        m.lathe([(r, 0.0, False), (r * 0.75, h * 0.35), (r * 0.35, h * 0.72), (0.0, h)], (x, y, 0.2), "EmitFire", seg=8)
    m.lathe([(0.1, 0.0, False), (0.06, 0.2), (0.0, 0.42)], (0.0, -0.02, 0.22), "EmitCandle", seg=8, scale=(1.3, 1.3, 1.3))
    return [m.build("fireplace")]


def grandfather_clock():
    """0.7 x 0.5 x 2.35; the `Pendulum` object swings about its own origin (its pivot), rotate it on local Y."""
    m = Kit()
    m.box(-0.36, 0.36, -0.26, 0.26, 0.0, 0.28, "DarkWood", 0.03)
    m.box(-0.37, 0.37, -0.27, 0.27, 0.26, 0.31, "Gold", 0.01)
    for s in (-1, 1):
        m.box(s * 0.15, s * 0.28, -0.2, 0.2, 0.31, 1.55, "Wood", 0.02)
    m.box(-0.28, 0.28, -0.2, 0.2, 0.31, 0.56, "Wood", 0.02)
    m.box(-0.28, 0.28, -0.2, 0.2, 1.4, 1.55, "Wood", 0.02)
    m.box(-0.15, 0.15, 0.1, 0.2, 0.31, 1.55, "Wood")
    m.box(-0.15, 0.15, 0.06, 0.1, 0.56, 1.4, "Charcoal")
    m.box(-0.29, 0.29, -0.215, -0.19, 0.53, 0.56, "Gold", 0.005)
    m.box(-0.34, 0.34, -0.24, 0.24, 1.55, 1.95, "DarkWood", 0.03)
    m.box(-0.3, 0.3, -0.22, 0.22, 1.95, 2.0, "Gold", 0.01)
    m.poly(arch_pts(0, 2.0, 0.3, 10), "xz", -0.21, 0.21, "Wood", 0.02)
    m.sph((0, 0, 2.36), 0.05, "Gold", 8, 6)
    # dial
    m.cyl((0, -0.245, 1.75), 0.17, 0.03, "Cream", 20, axis="y")
    m.torus((0, -0.245, 1.75), 0.17, 0.018, "Gold", 24, 6, rot=(90, 0, 0))
    m.boxc((0, -0.27, 1.8), (0.022, 0.012, 0.11), "Charcoal")
    m.boxc((0.035, -0.27, 1.75), (0.07, 0.012, 0.02), "Charcoal")
    m.cyl((0, -0.275, 1.75), 0.02, 0.014, "Gold", 8, axis="y")
    for a in range(0, 360, 90):
        x, z = 0.135 * math.cos(math.radians(a)), 1.75 + 0.135 * math.sin(math.radians(a))
        m.sph((x, -0.262, z), 0.014, "Charcoal", 6, 4)
    body = m.build("grandfather_clock")
    p = Kit()
    pivot = (0.0, 0.0, 1.45)
    p.box(-0.008, 0.008, -0.01, 0.01, 0.75, 1.45, "Gold")
    p.cyl((0, 0, 0.72), 0.085, 0.03, "Gold", 14, axis="y")
    p.cyl((0, -0.016, 0.72), 0.04, 0.012, "Red", 10, axis="y")
    pend = p.build("Pendulum", origin=pivot, parent=body)
    return [body, pend]


PIECES = {
    "armchair": armchair,
    "sofa": sofa,
    "side_table": side_table,
    "bookshelf": bookshelf,
    "piano": piano,
    "trophy_pedestal": trophy_pedestal,
    "fireplace": fireplace,
    "grandfather_clock": grandfather_clock,
}
