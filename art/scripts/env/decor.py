"""Mansion kit: decor (rug, chandelier, portraits, suit of armour, plant, candelabra)."""
import math

from kit import Kit, ellipse_pts


# ---- rug ------------------------------------------------------------------------------------
def rug_long():
    """2.4 x 6.2 (incl. fringe) x 0.045, lies flat on the floor (Godot XZ). Long axis = Y (Godot Z)."""
    m = Kit()
    m.box(-1.2, 1.2, -3.0, 3.0, 0.0, 0.02, "Red", 0.006)

    def ring(xo, yo, xi, yi, z0, z1, mat):
        m.box(-xo, xo, -yo, -yi, z0, z1, mat)
        m.box(-xo, xo, yi, yo, z0, z1, mat)
        m.box(-xo, -xi, -yi, yi, z0, z1, mat)
        m.box(xi, xo, -yi, yi, z0, z1, mat)

    ring(1.14, 2.94, 1.04, 2.84, 0.02, 0.028, "Gold")
    ring(0.98, 2.78, 0.93, 2.73, 0.02, 0.028, "Teal")
    for cy, sx, sy in ((-1.75, 0.55, 0.9), (1.75, 0.55, 0.9), (0.0, 0.72, 1.15)):
        m.poly([(-sx, cy), (0, cy - sy), (sx, cy), (0, cy + sy)], "xy", 0.02, 0.028, "Cream")
        m.poly([(-sx * 0.66, cy), (0, cy - sy * 0.66), (sx * 0.66, cy), (0, cy + sy * 0.66)], "xy", 0.028, 0.035, "Teal")
        m.poly([(-sx * 0.3, cy), (0, cy - sy * 0.3), (sx * 0.3, cy), (0, cy + sy * 0.3)], "xy", 0.035, 0.042, "Gold")
    for cy in (-0.92, 0.92):
        m.poly([(-0.1, cy), (0, cy - 0.16), (0.1, cy), (0, cy + 0.16)], "xy", 0.02, 0.03, "Gold")
    for sx in (-1, 1):
        for sy in (-1, 1):
            m.sph((sx * 0.86, sy * 2.6, 0.03), (0.09, 0.09, 0.02), "Cream", 8, 4)
    for s in (-1, 1):                                                          # fringe
        for i in range(12):
            x = -1.1 + 0.2 * i
            y0, y1 = (3.0, 3.14) if s > 0 else (-3.14, -3.0)
            m.box(x - 0.045, x + 0.045, y0, y1, 0.0, 0.012, "Cream")
    return [m.build("rug_long")]


# ---- chandelier -----------------------------------------------------------------------------
def chandelier():
    """1.9 diameter, hangs 1.65 m: origin is the CEILING HOOK (top centre); geometry extends down (Godot -Y)."""
    m = Kit()
    m.cyl((0, 0, -0.03), 0.17, 0.06, "Gold", 12)
    m.cyl((0, 0, -0.5), 0.018, 0.9, "Charcoal", 6)
    for z in (-0.15, -0.3, -0.45, -0.6, -0.75, -0.9):
        m.torus((0, 0, z), 0.03, 0.01, "Gold", 8, 4, rot=(90 if int(z * 20) % 2 else 0, 0, 0))
    m.lathe([(0.0, -0.95, True), (0.07, -1.0), (0.05, -1.08), (0.16, -1.22), (0.07, -1.34), (0.19, -1.44),
             (0.09, -1.56), (0.0, -1.68)], (0, 0, 0), "Gold", seg=10)
    m.torus((0, 0, -1.34), 0.85, 0.04, "Gold", 24, 6)
    m.torus((0, 0, -1.14), 0.5, 0.035, "Gold", 20, 6)
    for k in range(8):                                                       # lower ring: arms + candles
        a = math.radians(45 * k)
        ca, sa = math.cos(a), math.sin(a)
        m.beam((0.14 * ca, 0.14 * sa, -1.3), (0.5 * ca, 0.5 * sa, -1.52), 0.045, 0.04, "Gold")
        m.beam((0.5 * ca, 0.5 * sa, -1.52), (0.85 * ca, 0.85 * sa, -1.36), 0.045, 0.04, "Gold")
        _candle(m, 0.85 * ca, 0.85 * sa, -1.32)
        m.sph((0.85 * math.cos(a + math.radians(22.5)), 0.85 * math.sin(a + math.radians(22.5)), -1.5), 0.055, "Teal", 8, 5)
    for k in range(6):                                                       # upper ring: candles
        a = math.radians(60 * k + 30)
        ca, sa = math.cos(a), math.sin(a)
        m.beam((0.1 * ca, 0.1 * sa, -1.12), (0.5 * ca, 0.5 * sa, -1.14), 0.04, 0.035, "Gold")
        _candle(m, 0.5 * ca, 0.5 * sa, -1.11, short=True)
    return [m.build("chandelier")]


def _candle(m, x, y, z, short=False):
    h = 0.16 if short else 0.2
    m.cyl((x, y, z + 0.02), 0.06, 0.04, "Gold", 6, r2=0.04)
    m.cyl((x, y, z + 0.04 + h / 2), 0.03, h, "Cream", 6)
    m.lathe([(0.03, 0.0, False), (0.04, 0.04), (0.0, 0.12)], (x, y, z + 0.04 + h), "EmitCandle", seg=6)


# ---- candelabra -----------------------------------------------------------------------------
def candelabra():
    """0.6 x 0.16 x 1.45 floor-standing five-candle candelabra (arms spread along X)."""
    m = Kit()
    m.lathe([(0.0, 0.0, True), (0.2, 0.0, False), (0.2, 0.04), (0.1, 0.1), (0.045, 0.22), (0.045, 0.3)], (0, 0, 0), "Gold", seg=12)
    for z, r in ((0.32, 0.075), (0.62, 0.065), (0.9, 0.06)):
        m.sph((0, 0, z), r, "Gold", 10, 6)
    m.cyl((0, 0, 0.6), 0.04, 0.7, "Gold", 8)
    m.cyl((0, 0, 1.17), 0.06, 0.06, "Gold", 8, r2=0.04)
    for s in (-1, 1):
        m.beam((0, 0, 0.82), (s * 0.14, 0, 0.92), 0.04, 0.04, "Gold")
        m.beam((s * 0.14, 0, 0.92), (s * 0.15, 0, 1.06), 0.04, 0.04, "Gold")
        m.beam((0, 0, 0.72), (s * 0.27, 0, 0.8), 0.04, 0.04, "Gold")
        m.beam((s * 0.27, 0, 0.8), (s * 0.28, 0, 0.92), 0.04, 0.04, "Gold")
        _candle(m, s * 0.15, 0, 1.04)
        _candle(m, s * 0.28, 0, 0.9)
    _candle(m, 0, 0, 1.18)
    return [m.build("candelabra")]


# ---- plant ----------------------------------------------------------------------------------
def potted_plant():
    """0.8 x 0.8 x 1.6: teal pot, fiddle-leaf plant."""
    m = Kit()
    m.lathe([(0.2, 0.0, False), (0.26, 0.05), (0.36, 0.42), (0.4, 0.46), (0.4, 0.5, False)], (0, 0, 0), "Teal", seg=16)
    m.torus((0, 0, 0.5), 0.39, 0.03, "Gold", 24, 6)
    m.lathe([(0.37, 0.44, False), (0.37, 0.46)], (0, 0, 0), "DarkWood", seg=16)
    m.cyl((0, 0, 0.7), 0.035, 0.95, "Wood", 6, r2=0.02)
    m.cyl((0.03, 0, 1.15), 0.02, 0.5, "Wood", 5)
    n = 21
    for i in range(n):
        t = i / (n - 1)
        a = math.radians(i * 137.5)
        z = 0.62 + 0.85 * t
        d = 0.16 + 0.2 * math.sin(math.pi * min(1.0, t * 1.15)) + 0.04
        pitch = 20 + 40 * t
        rx = 0.22 - 0.06 * t
        cx, cy = math.cos(a) * d, math.sin(a) * d
        m.sph((cx + 0.0, cy, z), (rx, rx * 0.62, 0.03), "Green", 8, 4, rot=(0, -pitch, math.degrees(a)))
    m.sph((0, 0, 1.55), (0.14, 0.09, 0.03), "Green", 8, 4, rot=(0, -80, 40))
    return [m.build("potted_plant")]


# ---- armour ---------------------------------------------------------------------------------
def suit_of_armour():
    """0.75 x 0.6 x 2.05 chunky knight on a plinth, holding a halberd."""
    m = Kit()
    m.box(-0.36, 0.36, -0.3, 0.3, 0.0, 0.12, "DarkWood", 0.03)
    for s in (-1, 1):
        m.box(s * 0.13 - 0.09, s * 0.13 + 0.09, -0.2, 0.06, 0.12, 0.22, "Steel", 0.03)          # boots
        m.cyl((s * 0.13, -0.02, 0.5), 0.085, 0.55, "Steel", 8, r2=0.075)                       # legs
        m.sph((s * 0.13, -0.03, 0.56), 0.1, "Steel", 8, 6)
    m.lathe([(0.33, 0.62, False), (0.22, 0.86)], (0, 0, 0), "Steel", seg=12)                    # skirt
    m.lathe([(0.2, 0.84, False), (0.29, 1.0), (0.34, 1.25), (0.3, 1.45), (0.14, 1.5)], (0, 0, 0), "Steel", seg=12)
    m.torus((0, 0, 0.86), 0.24, 0.03, "Gold", 16, 6)
    m.box(-0.035, 0.035, -0.34, -0.29, 1.05, 1.38, "Red")                                       # chest cross
    m.box(-0.11, 0.11, -0.34, -0.29, 1.19, 1.26, "Red")
    m.cyl((0, 0, 1.52), 0.12, 0.08, "Steel", 10)
    for s in (-1, 1):
        m.sph((s * 0.37, 0, 1.38), (0.15, 0.14, 0.11), "Steel", 10, 6)
        m.beam((s * 0.4, 0, 1.3), (s * 0.44, -0.08, 1.05), 0.11, 0.11, "Steel", 0.02)           # upper arm
        m.beam((s * 0.44, -0.08, 1.05), (s * 0.38, -0.24, 0.98), 0.09, 0.09, "Steel", 0.02)     # forearm
        m.sph((s * 0.38, -0.25, 0.98), 0.075, "Steel", 8, 6)
    m.sph((0, -0.02, 1.7), (0.22, 0.21, 0.23), "Steel", 12, 8)                                   # helmet
    m.torus((0, -0.02, 1.62), 0.215, 0.018, "Gold", 16, 5)
    m.box(-0.12, 0.12, -0.24, -0.16, 1.62, 1.7, "Charcoal", 0.012)                              # visor slit
    m.box(-0.12, 0.12, -0.24, -0.16, 1.73, 1.75, "Charcoal")
    m.sph((0, 0.06, 1.95), (0.05, 0.14, 0.14), "Red", 8, 6)                                     # plume
    m.sph((0, 0.16, 1.85), (0.05, 0.1, 0.1), "Red", 8, 6)
    # halberd in the right hand (character's left = +X)
    m.cyl((0.38, -0.25, 0.98), 0.02, 1.85, "DarkWood", 6)
    m.poly([(0.4, 1.55), (0.7, 1.68), (0.7, 1.9), (0.4, 1.86)], "xz", -0.27, -0.23, "Steel", 0.01)
    m.lathe([(0.03, 0.0, False), (0.0, 0.2)], (0.38, -0.25, 1.9), "Steel", seg=6)
    m.sph((0.38, -0.25, 0.25), 0.03, "Gold", 6, 4)
    return [m.build("suit_of_armour")]


# ---- portraits ------------------------------------------------------------------------------
class _Canvas:
    """Stack flat colour layers on a wall-hung frame; layers are proud of each other by 4 mm."""

    def __init__(self, m, w, h, oval=False):
        self.m = m
        self.i = 0
        self.w, self.h, self.oval = w, h, oval

    def _clip(self, p):
        x, z = p
        if self.oval:
            a, b = self.w / 2 - 0.115, self.h / 2 - 0.115
            u, v = x / a, (z - self.h / 2) / b
            r = math.hypot(u, v)
            return (x, z) if r <= 1 else (u / r * a, self.h / 2 + v / r * b)
        lx, lz = self.w / 2 - 0.115, 0.115
        return (max(-lx, min(lx, x)), max(lz, min(self.h - 0.115, z)))

    def layer(self, pts, mat):
        pts = [self._clip(p) for p in pts]
        self.i += 1
        self.m.poly(pts, "xz", -0.022 - 0.002 * self.i, -0.02, mat)

    def ell(self, cx, cz, rx, rz, mat, ang=0.0, n=18):
        a = math.radians(ang)
        pts = [(cx + p * math.cos(a) - q * math.sin(a), cz + p * math.sin(a) + q * math.cos(a))
               for p, q in ((x - cx, z - cz) for x, z in ellipse_pts(cx, cz, rx, rz, n))]
        self.layer(pts, mat)

    def eye_pair(self, cz, dx=0.09, r=0.055, look=0.0):
        for s in (-1, 1):
            self.ell(s * dx, cz, r, r * 1.05, "Cream")
        for s in (-1, 1):
            self.ell(s * dx + look, cz - 0.005, r * 0.5, r * 0.55, "Charcoal", n=10)


def _frame(m, w, h, oval=False):
    """Hollow gold frame (canvas plane at y=-0.02, frame proud to y=-0.09) so the painted layers show."""
    if oval:
        n = 32
        m.ring(ellipse_pts(0, h / 2, w / 2, h / 2, n), ellipse_pts(0, h / 2, w / 2 - 0.09, h / 2 - 0.09, n), "xz", -0.09, 0.0, "Gold")
        m.ring(ellipse_pts(0, h / 2, w / 2 - 0.09, h / 2 - 0.09, n), ellipse_pts(0, h / 2, w / 2 - 0.115, h / 2 - 0.115, n), "xz", -0.07, -0.02, "DarkWood")
        m.poly(ellipse_pts(0, h / 2, w / 2 - 0.09, h / 2 - 0.09, n), "xz", -0.02, 0.0, "DarkWood")
    else:
        b = 0.09
        m.box(-w / 2, -w / 2 + b, -0.09, 0.0, 0.0, h, "Gold", 0.02)
        m.box(w / 2 - b, w / 2, -0.09, 0.0, 0.0, h, "Gold", 0.02)
        m.box(-w / 2 + b, w / 2 - b, -0.09, 0.0, 0.0, b, "Gold", 0.02)
        m.box(-w / 2 + b, w / 2 - b, -0.09, 0.0, h - b, h, "Gold", 0.02)
        lip = 0.025
        m.box(-w / 2 + b, -w / 2 + b + lip, -0.07, -0.02, b, h - b, "DarkWood")
        m.box(w / 2 - b - lip, w / 2 - b, -0.07, -0.02, b, h - b, "DarkWood")
        m.box(-w / 2 + b + lip, w / 2 - b - lip, -0.07, -0.02, b, b + lip, "DarkWood")
        m.box(-w / 2 + b + lip, w / 2 - b - lip, -0.07, -0.02, h - b - lip, h - b, "DarkWood")
        m.box(-w / 2 + b, w / 2 - b, -0.02, 0.0, b, h - b, "DarkWood")


def portrait_frame_a():
    """1.0 x 0.09 x 1.3 gold frame: Sir Blobsworth with top hat and curly moustache."""
    m = Kit()
    w, h = 1.0, 1.3
    _frame(m, w, h)
    c = _Canvas(m, w, h)
    c.layer([(-0.385, 0.115), (0.385, 0.115), (0.385, h - 0.115), (-0.385, h - 0.115)], "Teal")
    c.ell(0, 0.28, 0.36, 0.3, "Charcoal")
    c.layer([(-0.14, 0.4), (0.14, 0.4), (0.0, 0.14)], "Cream")
    c.layer([(-0.07, 0.36), (0.0, 0.32), (0.07, 0.36), (0.0, 0.41)], "Red")
    c.ell(0, 0.63, 0.25, 0.25, "Cream")
    c.ell(-0.24, 0.62, 0.05, 0.06, "Cream"); c.ell(0.24, 0.62, 0.05, 0.06, "Cream")
    c.eye_pair(0.68, 0.09, 0.05)
    c.ell(0.0, 0.7, 0.03, 0.06, "Red", n=10)
    c.ell(-0.12, 0.535, 0.13, 0.05, "DarkWood", ang=12); c.ell(0.12, 0.535, 0.13, 0.05, "DarkWood", ang=-12)
    c.ell(-0.26, 0.555, 0.045, 0.045, "DarkWood", n=10); c.ell(0.26, 0.555, 0.045, 0.045, "DarkWood", n=10)
    c.ell(0, 0.47, 0.06, 0.035, "Red", n=10)
    c.ell(0, 0.86, 0.3, 0.06, "Charcoal")
    c.layer([(-0.17, 0.86), (0.17, 0.86), (0.15, 1.1), (-0.15, 1.1)], "Charcoal")
    c.layer([(-0.17, 0.88), (0.17, 0.88), (0.165, 0.94), (-0.165, 0.94)], "Red")
    c.ell(-0.11, 0.7, 0.06, 0.06, "Gold", n=12)                                                 # monocle
    return [m.build("portrait_frame_a")]


def portrait_frame_b():
    """1.0 x 0.09 x 1.3 oval gold frame: Lady Blobelia with a plumed hat and pearls."""
    m = Kit()
    w, h = 1.0, 1.3
    _frame(m, w, h, oval=True)
    c = _Canvas(m, w, h, oval=True)
    c.ell(0, h / 2, w / 2 - 0.13, h / 2 - 0.13, "Charcoal", n=28)
    c.ell(0, 0.3, 0.3, 0.26, "Green")
    for k in range(9):
        t = k / 8
        c.ell(-0.16 + 0.32 * t, 0.42 - 0.07 * math.sin(math.pi * t), 0.027, 0.027, "Cream", n=8)
    c.ell(0, 0.62, 0.22, 0.22, "Cream")
    c.eye_pair(0.65, 0.085, 0.05)
    for s in (-1, 1):
        c.ell(s * 0.15, 0.57, 0.05, 0.035, "Red", n=10)
    c.ell(0, 0.53, 0.05, 0.03, "Red", n=10)
    c.ell(0, 0.83, 0.34, 0.06, "Gold")
    c.ell(0, 0.92, 0.17, 0.11, "Gold")
    c.layer([(0.05, 0.98), (0.3, 1.14), (0.24, 0.94)], "Red")
    c.ell(0.2, 1.06, 0.05, 0.11, "Red", ang=-40)
    c.ell(-0.1, 0.95, 0.05, 0.05, "Teal", n=10)
    return [m.build("portrait_frame_b")]


def portrait_frame_c():
    """1.5 x 0.09 x 1.0 landscape frame: Admiral Blobbington with bicorne hat and medals."""
    m = Kit()
    w, h = 1.5, 1.0
    _frame(m, w, h)
    c = _Canvas(m, w, h)
    c.layer([(-0.635, 0.115), (0.635, 0.115), (0.635, h - 0.115), (-0.635, h - 0.115)], "Green")
    c.ell(0, 0.2, 0.42, 0.24, "Charcoal")
    for s in (-1, 1):
        c.ell(s * 0.4, 0.34, 0.11, 0.045, "Gold", ang=s * -15, n=12)
    for i, mat in enumerate(("Gold", "Red", "Teal")):
        c.ell(-0.18 + i * 0.08, 0.27, 0.03, 0.03, mat, n=8)
    c.ell(0, 0.52, 0.24, 0.23, "Cream")
    c.eye_pair(0.56, 0.085, 0.05)
    c.ell(0, 0.44, 0.15, 0.04, "Charcoal", n=10)
    c.ell(0.0, 0.47, 0.03, 0.03, "Red", n=8)
    c.ell(-0.22, 0.47, 0.07, 0.12, "Cream", n=10); c.ell(0.22, 0.47, 0.07, 0.12, "Cream", n=10)
    c.layer([(-0.34, 0.7), (-0.26, 0.86), (0.0, 0.8), (0.26, 0.86), (0.34, 0.7), (0.0, 0.66)], "Charcoal")
    c.layer([(-0.34, 0.7), (-0.26, 0.86), (-0.22, 0.84), (-0.3, 0.7)], "Gold")
    c.layer([(0.34, 0.7), (0.26, 0.86), (0.22, 0.84), (0.3, 0.7)], "Gold")
    c.ell(0.0, 0.76, 0.045, 0.045, "Red", n=10)
    return [m.build("portrait_frame_c")]


PIECES = {
    "rug_long": rug_long,
    "chandelier": chandelier,
    "candelabra": candelabra,
    "potted_plant": potted_plant,
    "suit_of_armour": suit_of_armour,
    "portrait_frame_a": portrait_frame_a,
    "portrait_frame_b": portrait_frame_b,
    "portrait_frame_c": portrait_frame_c,
}
