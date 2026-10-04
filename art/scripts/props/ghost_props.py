"""Ghost Tag props: ghost_sheet, ghost_lantern, ghost_covered_sofa, ghost_covered_chair,
ghost_covered_wardrobe, ghost_trunk, ghost_window, ghost_cobweb.

ghost_sheet: the ghost's draped sheet, sized over the 1.0 m blob (top at ~1.12 m, hem ~0.56 m wide at
  y 0.06 with a wavy edge), two dark eye holes at the blob's eye height on the front (Godot +Z).
  Surfaces: `GhostSheet` (the game swaps it for its own translucent material) and `GhostEye`.
  Origin at the base centre (it sits on the blob model root).
ghost_lantern: a small hand lantern, 0.30 m tall, ORIGIN AT THE TOP OF THE HANDLE (the hang point; the
  body hangs below, Godot y -0.30..0). Warm emissive glass `EmitLanternGlass`.
ghost_covered_sofa: a sofa under a dust sheet, 2.0 x 0.9 m footprint, 0.9 m tall, back toward Godot -Z.
ghost_covered_chair: an armchair under a dust sheet, 0.8 x 0.8 m, 1.1 m tall, back toward Godot -Z.
ghost_covered_wardrobe: a tall cupboard under a dust sheet, 1.3 x 0.8 m, 2.0 m tall.
ghost_trunk: an old travel chest, 1.0 x 0.6 m, 0.7 m tall, front Godot +Z.
ghost_window: a round attic window for a wall face, 1.2 m across, origin at the bottom centre, glass
  `EmitMoonGlass` facing Godot +Z, back at z = 0 (stick it on a wall's +Z face).
ghost_cobweb: a corner cobweb in a vertical plane, 0.8 m wide, origin at its top centre (hang it in a
  corner, turned 45 degrees across it).
Run: tools/blender-run.ps1 art/scripts/props/ghost_props.py [piece names...]
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

HALF_PI = math.pi / 2


def _dust():
    return M("cream", 0.9, name="DustSheet", hexv="#a9b1c2")


def _dust_shade():
    return M("cream", 0.9, name="DustSheetShade", hexv="#7c8496")


def _wavy_hem(ob, z_hem, depth, waves, amp_z, amp_r, phase=0.0):
    """Ripples the vertices near the bottom: hem height and radius wave around the Z axis."""
    for v in ob.data.vertices:
        if v.co.z > z_hem + depth:
            continue
        k = 1.0 - max(0.0, v.co.z - z_hem) / depth
        a = math.atan2(v.co.y, v.co.x)
        w = math.sin(waves * a + phase)
        v.co.z += amp_z * w * k
        r = math.hypot(v.co.x, v.co.y)
        if r > 1e-6:
            f = 1.0 + amp_r * math.sin(waves * a + phase + 1.1) * k
            v.co.x *= f
            v.co.y *= f


def ghost_sheet():
    new_piece()
    sheet = M("cream", 0.6, name="GhostSheet", hexv="#e8f0ff")
    eye = M("charcoal", 0.6, name="GhostEye", hexv="#1d1a2b")
    b = Builder("ghost_sheet", angle=60)
    # open shell: dome on top, a gentle bell down to a flared hem
    prof = [(0.0, 1.13), (0.12, 1.12), (0.24, 1.08), (0.34, 1.0), (0.42, 0.88), (0.47, 0.72), (0.49, 0.55),
            (0.5, 0.38), (0.52, 0.22), (0.56, 0.08), (0.58, 0.04)]
    b.lathe(prof[::-1], sheet, segs=28, solid=False)
    # eye holes: dark ovals just outside the sheet at the blob's eye height (front = Blender -Y)
    for sx in (-1, 1):
        b.sphere(0.07, (sx * 0.15, -0.465, 0.72), eye, scale=(0.75, 0.25, 1.15), segs=12, rings=8)
    ob = b.build()
    _wavy_hem(ob, 0.04, 0.3, 7, 0.035, 0.05)
    return finish("ghost_sheet", [ob], expect_tris=(200, 2500))


def ghost_lantern():
    new_piece()
    metal = M("charcoal", 0.45, 0.6, name="LanternIron", hexv="#3a3440")
    brass = M("gold", 0.35, 0.5, name="LanternBrass", hexv="#b98a3a")
    glass = EM("EmitLanternGlass", "#ffbf5c", 3.0, 0.3)
    b = Builder("ghost_lantern", angle=40)
    # body hangs below the origin: handle top at z = 0, base at z = -0.30
    b.tube([(-0.05, 0, -0.06), (-0.045, 0, -0.02), (0.0, 0, 0.0), (0.045, 0, -0.02), (0.05, 0, -0.06)], 0.009, metal,
           sides=6, caps=True)
    b.cyl(0.05, 0.035, (0, 0, -0.095), brass, segs=12, r_top=0.022)        # cap cone
    b.cyl(0.072, 0.02, (0, 0, -0.115), metal, segs=12, bevel=0.005)        # top plate
    b.cyl(0.055, 0.15, (0, 0, -0.265), glass, segs=12)                      # glass
    for k in range(4):
        a = k * HALF_PI + math.pi / 4
        b.box((0.012, 0.012, 0.16), (0.06 * math.cos(a), 0.06 * math.sin(a), -0.19), metal)
    b.cyl(0.075, 0.03, (0, 0, -0.3), metal, segs=12, bevel=0.006)          # base
    ob = b.build()
    return finish("ghost_lantern", [ob], expect_tris=(100, 1500))


def _draped(name, size, seed, top_bulge, legs, leg_h, extra=None):
    """A lumpy dust-sheet blob over a piece of furniture: `size` (x, depth, height) in metres."""
    new_piece()
    dust, shade = _dust(), _dust_shade()
    wood = M("dark_wood", 0.75)
    b = Builder(name, angle=50)
    sx, sy, sz = size
    fn = lumps(seed, n=6, amp=0.06)

    def shape(d):
        # a squarish blob: superellipse-ish pull toward the box corners, plus soft lumps
        k = fn(d)
        box = 1.0 / max(1e-3, (abs(d.x) ** 4 + abs(d.y) ** 4 + abs(d.z) ** 4) ** 0.25)
        return k * (0.55 + 0.45 * box) * (1.0 + top_bulge * max(0.0, d.z))
    b.ico(1.0, (0, 0, leg_h), dust, subdiv=3, scale=(sx * 0.5, sy * 0.5, sz - leg_h), fn=shape, zmin=0.0,
          mat_fn=lambda nz: dust if nz > -0.2 else shade)
    if extra:
        extra(b, dust, shade, wood)
    for (lx, ly) in legs:
        b.cyl(0.035, leg_h + 0.03, (lx, ly, 0.0), wood, segs=8, r_top=0.025)
    ob = b.build()
    # the ico's flat base sits at leg_h: clamp anything under it and drop the hem a little
    for v in ob.data.vertices:
        if v.co.z < leg_h + 0.02 and math.hypot(v.co.x / (sx * 0.5), v.co.y / (sy * 0.5)) > 0.5:
            v.co.z = max(leg_h * 0.4, v.co.z - leg_h * 0.6)
    ob.data.update()
    return ob


def ghost_covered_sofa():
    def back(b, dust, shade, wood):
        # the backrest under the sheet: a long ridge at the back (Godot -Z = Blender +Y)
        b.ico(1.0, (0, 0.25, 0.35), dust, subdiv=2, scale=(0.95, 0.2, 0.5), fn=lumps(11, n=4, amp=0.05))
        for sx in (-1, 1):  # arm rests
            b.ico(1.0, (sx * 0.85, 0.0, 0.3), dust, subdiv=2, scale=(0.16, 0.4, 0.3), fn=lumps(12 + sx, n=3, amp=0.05))
    legs = [(sx * 0.88, sy * 0.36) for sx in (-1, 1) for sy in (-1, 1)]
    ob = _draped("ghost_covered_sofa", (2.0, 0.9, 0.62), 5, 0.0, legs, 0.08, back)
    return finish("ghost_covered_sofa", [ob], expect_tris=(300, 6000))


def ghost_covered_chair():
    def back(b, dust, shade, wood):
        b.ico(1.0, (0, 0.24, 0.62), dust, subdiv=2, scale=(0.36, 0.16, 0.48), fn=lumps(21, n=4, amp=0.06))
    legs = [(sx * 0.32, sy * 0.3) for sx in (-1, 1) for sy in (-1, 1)]
    ob = _draped("ghost_covered_chair", (0.8, 0.8, 0.6), 9, 0.0, legs, 0.1, back)
    return finish("ghost_covered_chair", [ob], expect_tris=(300, 5000))


def ghost_covered_wardrobe():
    def cornice(b, dust, shade, wood):
        # the cornice under the sheet: a ridge round the top
        b.ico(1.0, (0, 0, 1.9), dust, subdiv=2, scale=(0.68, 0.43, 0.12), fn=lumps(31, n=3, amp=0.04))
    legs = [(sx * 0.55, sy * 0.3) for sx in (-1, 1) for sy in (-1, 1)]
    ob = _draped("ghost_covered_wardrobe", (1.3, 0.8, 1.98), 17, 0.0, legs, 0.1, cornice)
    _wavy_hem(ob, 0.04, 0.3, 9, 0.03, 0.03)
    return finish("ghost_covered_wardrobe", [ob], expect_tris=(300, 6000))


def ghost_trunk():
    new_piece()
    wood = M("wood", 0.8, name="TrunkWood", hexv="#6e4a33")
    band = M("charcoal", 0.5, 0.5, name="TrunkIron", hexv="#3b3540")
    brass = M("gold", 0.35, 0.5, name="TrunkBrass", hexv="#c4943e")
    b = Builder("ghost_trunk", angle=35)
    b.box((1.0, 0.6, 0.45), (0, 0, 0.225), wood, bevel=0.02)
    # curved lid: a half cylinder along X
    # rot -90 about Y: the polygon's x becomes height (Blender +Z), the extrusion runs along X
    lid = [(0.3 * math.sin(math.radians(a)) * 0.8, -0.3 * math.cos(math.radians(a))) for a in range(0, 181, 20)]
    b.prism(lid, -0.5, 0.5, wood, rot=(0, -HALF_PI, 0), loc=(0, 0, 0.45))
    for x in (-0.38, 0.0, 0.38):
        b.box((0.06, 0.62, 0.47), (x, 0, 0.235), band)
        b.prism([(0.3 * math.sin(math.radians(a)) * 0.82, -0.31 * math.cos(math.radians(a))) for a in range(0, 181, 20)],
                -0.03, 0.03, band, rot=(0, -HALF_PI, 0), loc=(x, 0, 0.45))
    b.box((0.12, 0.03, 0.14), (0, -0.31, 0.42), brass, bevel=0.01)  # lock plate on the front
    ob = b.build()
    return finish("ghost_trunk", [ob], expect_tris=(80, 2500))


def ghost_window():
    new_piece()
    wood = M("dark_wood", 0.75, name="WindowWood", hexv="#3d2b25")
    glass = EM("EmitMoonGlass", "#9cc4ff", 1.6, 0.2)
    b = Builder("ghost_window", angle=35)
    # vertical disc in the Blender XZ plane, facing -Y (Godot +Z); centre at z 0.6
    ring, _ = rrect(0.5, 0.6, 0.0, 0.1, 0.02, 0.02, 1)
    b.lathe(ring, wood, segs=28, closed=True, rot=(HALF_PI, 0, 0), loc=(0, 0.0, 0.6))
    b.cyl(0.5, 0.03, (0, 0.02, 0.6), glass, segs=28, rot=(HALF_PI, 0, 0))
    b.box((0.06, 0.08, 1.0), (0, -0.05, 0.6), wood)
    b.box((1.0, 0.08, 0.06), (0, -0.05, 0.6), wood)
    b.box((1.3, 0.16, 0.08), (0, -0.08, 0.0), wood, bevel=0.015)  # sill
    ob = b.build()
    return finish("ghost_window", [ob], expect_tris=(80, 2500))


def ghost_cobweb():
    new_piece()
    silk = M("cream", 0.9, name="Cobweb", hexv="#d8d6e6")
    b = Builder("ghost_cobweb", angle=80)
    # a fan hanging down from its top edge (z = 0), in the Blender XZ plane
    spokes = 7
    pts = []
    for k in range(spokes):
        a = math.pi + math.pi * k / (spokes - 1)
        pts.append((0.4 * math.cos(a), 0.4 * math.sin(a)))
    for (x, z) in pts:
        b.tube([(0, 0, 0), (x, 0, z * 0.9)], 0.006, silk, sides=3, caps=False)
    for r in (0.12, 0.22, 0.31, 0.38):
        ring = []
        for k in range(spokes):
            x, z = pts[k]
            sag = 0.92 if k % 2 else 1.0
            ring.append((x * r / 0.4 * sag, 0, z * 0.9 * r / 0.4 * sag))
        b.tube(ring, 0.005, silk, sides=3, caps=False)
    ob = b.build()
    return finish("ghost_cobweb", [ob], expect_tris=(50, 1500))


ALL = [ghost_sheet, ghost_lantern, ghost_covered_sofa, ghost_covered_chair, ghost_covered_wardrobe, ghost_trunk,
       ghost_window, ghost_cobweb]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
