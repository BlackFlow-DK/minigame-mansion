"""Floor Is Lava props: hex_tile, hex_tile_cracked, lava_rock_a/b/c, cave_stalagmite, cave_wall_chunk.

Run: tools/blender-run.ps1 art/scripts/props/lava.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib


def _clip(poly, keep):
    """Sutherland-Hodgman against a half-plane; keep(p) -> signed distance (>= 0 inside)."""
    out = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        da, db = keep(a), keep(b)
        if da >= 0:
            out.append(a)
        if (da >= 0) != (db >= 0):
            t = da / (da - db)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def _tile_body(b, top=-0.03):
    """Shared slab: dark-stone body full 1.0 m circumradius, top of body at `top`."""
    b.prism(hexagon(1.0), -0.4, top, M("dark_stone", 0.9), bevel=0.045, seg=2)


def hex_tile():
    new_piece()
    b = Builder("hex_tile", angle=30)
    _tile_body(b)
    # top plate (stone), top face exactly at y = 0
    b.prism(hexagon(0.935), -0.12, 0.0, M("stone", 0.9), bevel=0.04, seg=2)
    dk = M("dark_stone", 0.9)
    # cracked-top detail: a hairline zig-zag, raised 1 cm so it reads from a distance
    pts = [(-0.62, -0.30), (-0.30, -0.12), (-0.12, -0.22), (0.14, 0.02), (0.02, 0.22), (0.30, 0.40)]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        L = math.hypot(x1 - x0, y1 - y0)
        ang = math.atan2(y1 - y0, x1 - x0)
        b.box((L + 0.05, 0.05, 0.022), ((x0 + x1) / 2, (y0 + y1) / 2, 0.0), dk, rot=(0, 0, ang))
    # small branch crack and chips
    b.box((0.26, 0.04, 0.02), (-0.24, 0.27, 0.0), dk, rot=(0, 0, 0.9))
    b.box((0.16, 0.12, 0.024), (0.5, -0.32, 0.0), M("dark_stone", 0.9), rot=(0, 0, 0.4), bevel=0.02)
    ob = b.build()
    return finish("hex_tile", [ob])


def hex_tile_cracked():
    new_piece()
    b = Builder("hex_tile_cracked", angle=30)
    _tile_body(b, top=-0.10)
    lava = EM("EmitLava", "#ff6a1f", 1.8)
    b.prism(hexagon(0.9), -0.12, -0.065, lava)  # glows through the fissures
    plate = hexagon(0.935)
    c = (0.06, 0.04)
    angs = [math.radians(a) for a in (18, 150, 262)]
    stone = M("stone", 0.9)
    dk = M("dark_stone", 0.9)
    drops = [(0.0, (0, 0, 0)), (-0.035, (0.03, -0.025, 0.02)), (-0.018, (-0.022, 0.028, -0.015))]
    g = 0.05  # half gap
    for i in range(3):
        da, db = angs[i], angs[(i + 1) % 3]
        dira = (math.cos(da), math.sin(da))
        dirb = (math.cos(db), math.sin(db))
        poly = _clip(plate, lambda p: dira[0] * (p[1] - c[1]) - dira[1] * (p[0] - c[0]) - g)
        poly = _clip(poly, lambda p: -(dirb[0] * (p[1] - c[1]) - dirb[1] * (p[0] - c[0])) - g)
        dz, rot = drops[i]
        b.prism(poly, -0.14, 0.0, stone, bevel=0.03, seg=1, loc=(0, 0, dz), rot=rot)
    # extra hairline cracks on the biggest slab
    b.box((0.5, 0.04, 0.02), (-0.4, -0.35, 0.002), dk, rot=(0, 0, 0.5))
    b.box((0.3, 0.035, 0.02), (0.5, 0.3, -0.03), dk, rot=(0, 0, -0.7))
    ob = b.build()
    return finish("hex_tile_cracked", [ob])


def _rock_mat_fn(top, side):
    return lambda nz: top if nz > 0.55 else side


def lava_rock_a():
    """Single chunky boulder with glowing embers at its foot, ~1.2 m wide."""
    new_piece()
    b = Builder("lava_rock_a", angle=1)
    side, top = M("charcoal", 0.95), M("dark_stone", 0.95)
    ember = EM("EmitLava", "#ff6a1f", 1.3)
    b.ico(0.6, (0, 0, 0.36), None, subdiv=2, scale=(1.05, 0.9, 0.78), fn=lumps(11, amp=0.16), zmin=-0.36,
          mat_fn=_rock_mat_fn(top, side))
    b.ico(0.2, (0.42, -0.45, 0.13), None, subdiv=1, scale=(1, 1, 0.8), fn=lumps(3, amp=0.12), zmin=-0.13,
          mat_fn=_rock_mat_fn(top, side))
    b.ico(0.11, (-0.5, -0.3, 0.03), ember, subdiv=1, scale=(1, 1, 0.75), zmin=-0.03)
    b.ico(0.09, (0.05, -0.62, 0.02), ember, subdiv=1, scale=(1.3, 1, 0.7), zmin=-0.02)
    b.ico(0.08, (0.62, 0.05, 0.02), ember, subdiv=1, scale=(1, 1.2, 0.7), zmin=-0.02)
    ob = b.build()
    return finish("lava_rock_a", [ob])


def lava_rock_b():
    """Cluster of three rocks with a glowing fissure between them."""
    new_piece()
    b = Builder("lava_rock_b", angle=1)
    side, top = M("charcoal", 0.95), M("dark_stone", 0.95)
    ember = EM("EmitLava", "#ff6a1f", 1.3)
    mf = _rock_mat_fn(top, side)
    b.ico(0.5, (-0.32, 0.05, 0.3), None, subdiv=2, scale=(1, 1.1, 0.85), fn=lumps(21, amp=0.15), zmin=-0.3, mat_fn=mf)
    b.ico(0.4, (0.42, -0.1, 0.24), None, subdiv=2, scale=(1.1, 0.95, 0.75), fn=lumps(22, amp=0.17), zmin=-0.24, mat_fn=mf)
    b.ico(0.26, (0.05, -0.5, 0.15), None, subdiv=1, scale=(1, 1, 0.8), fn=lumps(23, amp=0.13), zmin=-0.15, mat_fn=mf)
    # glow wedge in the gap
    b.ico(0.16, (0.06, 0.08, 0.12), ember, subdiv=1, scale=(0.7, 1.5, 1.0), zmin=-0.12)
    b.ico(0.1, (0.05, -0.3, 0.03), ember, subdiv=1, scale=(1.2, 1, 0.6), zmin=-0.03)
    b.ico(0.08, (-0.1, 0.62, 0.02), ember, subdiv=1, scale=(1.3, 1, 0.7), zmin=-0.02)
    ob = b.build()
    return finish("lava_rock_b", [ob])


def lava_rock_c():
    """Tall stacked rock pair with a glowing seam, ~1.5 m high."""
    new_piece()
    b = Builder("lava_rock_c", angle=1)
    side, top = M("charcoal", 0.95), M("dark_stone", 0.95)
    ember = EM("EmitLava", "#ff6a1f", 1.3)
    mf = _rock_mat_fn(top, side)
    b.ico(0.6, (0, 0, 0.42), None, subdiv=2, scale=(1.0, 0.95, 0.75), fn=lumps(31, amp=0.14), zmin=-0.42, mat_fn=mf)
    b.ico(0.42, (0.05, 0.02, 1.0), None, subdiv=2, scale=(1.0, 0.95, 1.2), fn=lumps(32, amp=0.15), mat_fn=mf)
    b.ico(0.3, (-0.28, -0.05, 1.42), None, subdiv=1, scale=(0.9, 0.9, 1.0), fn=lumps(33, amp=0.12), mat_fn=mf)
    # glowing seam between the two big rocks
    b.ico(0.4, (0.05, -0.1, 0.72), ember, subdiv=2, scale=(1.0, 1.0, 0.28), fn=lumps(34, amp=0.05))
    b.ico(0.1, (0.45, -0.4, 0.03), ember, subdiv=1, scale=(1.2, 1, 0.7), zmin=-0.03)
    ob = b.build()
    return finish("lava_rock_c", [ob])


def cave_stalagmite():
    new_piece()
    b = Builder("cave_stalagmite", angle=30)
    dk, lt = M("dark_stone", 0.9), M("stone", 0.9)

    def mat(r, z):
        return lt if z > 0.95 else dk
    main = [(0.46, 0.0), (0.4, 0.3), (0.32, 0.72), (0.22, 1.08), (0.1, 1.42), (0.0, 1.7)]
    b.lathe(main, mat, segs=8, rot=(0.05, -0.04, 0), loc=(0, 0, 0))
    small = [(0.3, 0.0), (0.25, 0.22), (0.17, 0.5), (0.08, 0.78), (0.0, 0.98)]
    b.lathe(small, mat, segs=7, loc=(0.52, -0.22, 0), rot=(0.12, 0.18, 0))
    small2 = [(0.24, 0.0), (0.2, 0.18), (0.12, 0.4), (0.0, 0.62)]
    b.lathe(small2, mat, segs=7, loc=(-0.44, -0.3, 0), rot=(-0.1, -0.16, 0))
    for (x, y, r) in ((-0.4, 0.3, 0.14), (0.3, 0.45, 0.1), (0.62, 0.18, 0.09)):
        b.ico(r, (x, y, r * 0.5), dk, subdiv=1, scale=(1, 1, 0.7), fn=lumps(int(x * 100)), zmin=-r * 0.5 + 0.0)
    ob = b.build()
    return finish("cave_stalagmite", [ob])


def cave_wall_chunk():
    """4 m wide backdrop chunk. Front faces Godot +Z; flat back (y=+0.5 blender), flat ends, sits on z=0."""
    new_piece()
    b = Builder("cave_wall_chunk", angle=1)
    side, top = M("charcoal", 0.95), M("dark_stone", 0.95)
    ember = EM("EmitLava", "#ff6a1f", 1.3)
    mf = _rock_mat_fn(top, side)
    # (x, y, z, r, sx, sy, sz, seed)
    rocks = [
        (-1.5, 0.05, 0.95, 1.15, 1.35, 0.8, 0.95, 41),
        (-0.3, 0.05, 1.15, 1.2, 1.3, 0.8, 1.15, 42),
        (0.95, 0.05, 1.0, 1.15, 1.35, 0.8, 1.05, 43),
        (1.9, 0.0, 0.8, 1.0, 1.2, 0.85, 0.9, 44),
        (-1.0, -0.42, 0.42, 0.75, 1.5, 0.8, 0.6, 45),
        (0.4, -0.45, 0.38, 0.7, 1.6, 0.8, 0.55, 46),
        (1.6, -0.4, 0.36, 0.62, 1.3, 0.8, 0.6, 47),
    ]
    for (x, y, z, r, sx, sy, sz, seed) in rocks:
        b.ico(r, (x, y, z), None, subdiv=2 if r > 0.9 else 1, scale=(sx, sy, sz), fn=lumps(seed, amp=0.13), mat_fn=mf)
    # glowing fissure lumps between rocks
    b.ico(0.16, (-0.95, -0.55, 0.9), ember, subdiv=1, scale=(0.5, 0.6, 2.2))
    b.ico(0.15, (0.35, -0.6, 0.85), ember, subdiv=1, scale=(0.5, 0.6, 1.8))
    b.ico(0.11, (1.25, -0.6, 0.15), ember, subdiv=1, scale=(1.4, 1, 0.7))
    # clip: flat back, flat ends, flat base
    for v in b.bm.verts:
        v.co.x = max(-2.0, min(2.0, v.co.x))
        v.co.y = min(0.5, v.co.y)
        v.co.z = max(0.0, v.co.z)
    ob = b.build()
    return finish("cave_wall_chunk", [ob])


ALL = [hex_tile, hex_tile_cracked, lava_rock_a, lava_rock_b, lava_rock_c, cave_stalagmite, cave_wall_chunk]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
