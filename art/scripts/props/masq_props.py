"""Masquerade props: masq_mask, masq_garland, masq_rosette.

masq_mask: the eye mask every blob wears in Masquerade. Origin at the blob's FaceSocket (Godot
  (0, 0.68, 0.37)), so the game parents it to FaceSocket with an identity transform. A thin shell
  that hugs the head dome (sphere r=0.38 centred at Godot y=0.62, see character/blob.py) from
  y 0.55 to 0.83, 62 degrees either side of the nose, with two eye holes the blob's eyes poke
  through, a gold trim along the top and bottom edges, a gem on the bridge and a feather plume.
masq_garland: a 4 m fabric swag for the ballroom walls with three small glowing lanterns, modelled
  at its real height (ends at y 3.0, sagging to 2.45): place it at floor level against a wall.
masq_rosette: a 7 m dance-floor medallion (concentric rings and a star), 0.02 m thick, base at y 0.
Run: tools/blender-run.ps1 art/scripts/props/masq_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

# Head dome of the blob (Godot): sphere centre y and radius; FaceSocket height and depth.
HEAD_C, HEAD_R = 0.62, 0.38
FACE_Y, FACE_Z = 0.68, 0.37
SHELL_IN, SHELL_OUT = 0.389, 0.403


def _phi(y, r):
    return math.asin(max(-1.0, min(1.0, (y - HEAD_C) / r)))


def _shell(b, mat, y0, y1, th0, th1, r_in=SHELL_IN, r_out=SHELL_OUT, segs=4, rings=3):
    """A patch of the head shell between heights y0..y1 (Godot) and angles th0..th1 (degrees from
    the nose toward Godot +X). Built in mask space (origin at FaceSocket)."""
    prof = []
    for i in range(rings + 1):
        y = y0 + (y1 - y0) * i / rings
        p = _phi(y, r_out)
        prof.append((r_out * math.cos(p), r_out * math.sin(p)))
    for i in range(rings, -1, -1):
        y = y0 + (y1 - y0) * i / rings
        p = _phi(y, r_in)
        prof.append((r_in * math.cos(p), r_in * math.sin(p)))
    # Lathe angle a: x = r cos a, y = r sin a; the nose (Godot +Z = Blender -Y) is a = -90 deg.
    a0 = math.radians(th0 - 90.0)
    a1 = math.radians(th1 - 90.0)
    # Head centre relative to FaceSocket, in Blender space: Godot (0, 0.62-0.68, -0.37).
    b.lathe(prof, mat, segs=segs, a0=a0, a1=a1, closed=True, loc=(0.0, FACE_Z, HEAD_C - FACE_Y))


def _on_head(th_deg, y, out=0.0):
    """Blender point on the head shell (mask space) at angle th from the nose and height y."""
    r = SHELL_OUT + out
    p = _phi(y, r)
    a = math.radians(th_deg - 90.0)
    return (r * math.cos(p) * math.cos(a), FACE_Z + r * math.cos(p) * math.sin(a), HEAD_C - FACE_Y + r * math.sin(p))


def masq_mask():
    new_piece()
    b = Builder("masq_mask", angle=35)
    velvet = M("plum", 0.55, name="MaskVelvet", hexv="#3a1f4d")
    gold = M("gold", 0.35, 0.6, name="MaskGold", hexv="#e8b33a")
    y0, y1 = 0.55, 0.83          # mask band
    hy0, hy1 = 0.575, 0.772      # eye holes (the eyes are 0.55..0.78 tall at 8..35 deg)
    edge, hole_in, hole_out = 62.0, 7.0, 37.0
    for s in (-1.0, 1.0):
        lo, hi = (hole_out, edge) if s > 0 else (-edge, -hole_out)
        _shell(b, velvet, y0, y1, lo, hi, segs=4)                       # outer cheek piece
        lo, hi = (hole_in, hole_out) if s > 0 else (-hole_out, -hole_in)
        _shell(b, velvet, hy1, y1, lo, hi, segs=5, rings=1)             # brow over the eye
        _shell(b, velvet, y0, hy0, lo, hi, segs=5, rings=1)             # under the eye
        # gold rim around the eye hole (slightly proud of the velvet)
        _shell(b, gold, hy1 - 0.004, hy1 + 0.012, lo, hi, SHELL_OUT - 0.002, SHELL_OUT + 0.006, segs=5, rings=1)
        _shell(b, gold, hy0 - 0.012, hy0 + 0.004, lo, hi, SHELL_OUT - 0.002, SHELL_OUT + 0.006, segs=5, rings=1)
        # upswept wing tip at the outer top corner
        base_a = _on_head(s * (edge - 10.0), y1 - 0.02, 0.002)
        base_b = _on_head(s * edge, y1 - 0.09, 0.002)
        tip = _on_head(s * (edge + 8.0), y1 + 0.06, -0.01)
        b.tube([base_a, tip], 0.018, velvet, sides=5, radii=[0.03, 0.006])
        b.tube([base_b, tip], 0.014, gold, sides=5, radii=[0.018, 0.005])
    _shell(b, velvet, y0, y1, -hole_in, hole_in, segs=2)                # the bridge
    # gold trim along the top and bottom edges
    _shell(b, gold, y1 - 0.016, y1, -edge, edge, SHELL_OUT - 0.002, SHELL_OUT + 0.006, segs=10, rings=1)
    _shell(b, gold, y0, y0 + 0.014, -edge, edge, SHELL_OUT - 0.002, SHELL_OUT + 0.006, segs=10, rings=1)
    # a gem on the bridge
    gx, gy, gz = _on_head(0.0, 0.79, 0.01)
    b.sphere(0.028, (gx, gy, gz), gold, scale=(1.0, 0.6, 1.2), segs=6, rings=4)
    # feather plume rising from the left (Godot -X) top corner, leaning out
    root = _on_head(-40.0, y1, 0.0)
    b.sphere(0.05, (root[0] - 0.03, root[1], root[2] + 0.14), gold, scale=(0.45, 0.3, 1.0), segs=6, rings=4,
             rot=(0.0, math.radians(-25.0), 0.0))
    b.sphere(0.04, (root[0] - 0.075, root[1] + 0.02, root[2] + 0.11), velvet, scale=(0.4, 0.3, 1.0), segs=6, rings=4,
             rot=(0.0, math.radians(-40.0), 0.0))
    b.tube([root, (root[0] - 0.05, root[1], root[2] + 0.1)], 0.006, gold, sides=4)
    ob = b.build()
    return finish("masq_mask", [ob], expect_tris=(100, 1000))


def masq_garland():
    new_piece()
    b = Builder("masq_garland", angle=40)
    cloth = M("plum", 0.75, name="Drape", hexv="#7a2d5c")
    trim = M("gold", 0.4, 0.4)
    glow = EM("EmitLantern", "#ffcf7a", 2.2)
    half, sag, top = 2.0, 0.55, 3.0
    pts, rad = [], []
    n = 16
    for i in range(n + 1):
        t = i / n
        x = -half + 2 * half * t
        z = top - sag * (1.0 - (2 * t - 1) ** 2)
        pts.append((x, 0.0, z))
        rad.append(0.05 + 0.05 * math.sin(math.pi * t))
    b.tube(pts, 0.08, cloth, sides=8, radii=rad)
    b.tube([(p[0], -0.02, p[2] - 0.08) for p in pts], 0.012, trim, sides=4)
    for sx in (-1.0, 1.0):
        b.sphere(0.09, (sx * half, 0.0, top), trim, segs=10, rings=6)
        b.tube([(sx * half, 0.0, top), (sx * half, 0.0, top - 0.5)], 0.03, cloth, sides=6, radii=[0.04, 0.012])
    for x in (-1.1, 0.0, 1.1):
        t = (x + half) / (2 * half)
        z = top - sag * (1.0 - (2 * t - 1) ** 2) - 0.06
        b.tube([(x, 0.0, z), (x, 0.0, z - 0.25)], 0.006, trim, sides=4)
        b.cyl(0.075, 0.03, (x, 0.0, z - 0.29), trim, segs=10)
        b.sphere(0.09, (x, 0.0, z - 0.37), glow, scale=(1.0, 1.0, 1.25), segs=10, rings=6)
        b.cyl(0.05, 0.03, (x, 0.0, z - 0.5), trim, segs=10)
    ob = b.build()
    return finish("masq_garland", [ob], expect_tris=(200, 2500))


def masq_rosette():
    new_piece()
    b = Builder("masq_rosette", angle=40)
    dark = M("dark_wood", 0.6)
    plum = M("plum", 0.5, name="RosettePlum", hexv="#5a2a63")
    gold = M("gold", 0.35, 0.5)
    cream = M("cream", 0.6)
    rings = [(3.5, 3.38, gold), (3.38, 3.0, plum), (3.0, 2.92, gold), (2.92, 1.6, dark), (1.6, 1.52, gold),
             (1.52, 0.9, cream)]
    for r1, r0, mat in rings:
        b.lathe([(r0, 0.0), (r1, 0.0), (r1, 0.02), (r0, 0.02)], mat, segs=48, closed=True)
    b.lathe([(0.0, 0.0), (0.9, 0.0), (0.9, 0.02), (0.0, 0.02)], plum, segs=32)
    b.prism(star_poly(1.3, 0.45, 8), 0.0, 0.026, gold)
    b.prism(star_poly(0.5, 0.2, 8, rot=math.pi / 2 + math.pi / 8), 0.0, 0.03, cream)
    ob = b.build()
    return finish("masq_rosette", [ob], expect_tris=(100, 2500))


ALL = [masq_mask, masq_garland, masq_rosette]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
