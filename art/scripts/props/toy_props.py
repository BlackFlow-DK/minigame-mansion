"""Lobby toys for the mansion hall: chunky toy-box look, flat colours, few materials each.

Run: tools/blender-run.ps1 art/scripts/props/toy_props.py [piece names...]

toy_football: 0.8 m ball (radius 0.4), origin at its CENTRE. Cream with charcoal pentagon patches.
toy_goal: small goal, origin at the mouth centre on the ground, mouth faces Godot +Z. Posts at
  x = +-1.1 (centres), crossbar 1.2 m up, the box runs 0.9 m back (Godot -Z). The frame material
  `GoalFrame` is recoloured per side at runtime.
toy_trampoline: round trampoline, radius 1.2, padded rim top at y = 0.46. Objects `Frame` (rim, pads,
  legs) and `Mat` (the jumping mat; origin at its centre (0, 0.40, 0), squashed at runtime).
toy_bell: brass bell on a wooden frame facing +Z, 2.15 m tall, posts at x = +-0.85. Objects `Frame`
  and `Bell` (origin at the pivot (0, 1.7, 0); hangs down to y = 0.75, blob-head height, so a
  shove reaches it; swings about X at runtime).
toy_seesaw: objects `Base` (pivot stand, 0.5 m) and `Plank` (origin at the pivot (0, 0.5, 0), 4.2 m
  along X, 0.7 m wide; red seat at -X, blue seat at +X; tilts about Z at runtime).
toy_photo_frame: standing gold picture frame 2.9 m wide, 2.5 m tall with a starry backdrop canvas,
  facing +Z, origin base centre (feet reach 0.35 m forward).
toy_photo_button: pedestal 0.9 m with a big red push button: objects `Pedestal` and `ButtonCap`
  (origin at the cap's base (0, 0.9, 0); pressed down at runtime).
toy_scoreboard: wall board 1.9 x 1.0 m, back flat at z = 0 facing +Z, origin bottom centre. Red
  panel left, blue panel right (digits are Label3D in game).
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib
import bmesh
from mathutils import Vector

RED = "#e0483e"
BLUE = "#3f86e0"


def toy_football():
    """Soccer-style toy ball: an icosphere whose faces around the 12 icosahedron corners are dark."""
    new_piece()
    R = 0.4
    white = M("cream", 0.5, name="BallCream", hexv="#fbf5e6")
    dark = M("charcoal", 0.55, name="BallPatch", hexv="#2e2a33")
    b = Builder("Ball", angle=70)
    tmp = bmesh.new()
    bmesh.ops.create_icosphere(tmp, subdivisions=4, radius=R)
    phi = (1 + 5 ** 0.5) / 2
    corners = []
    for a, c in ((1, phi), (-1, phi), (1, -phi), (-1, -phi)):
        corners += [Vector((0, a, c)), Vector((a, c, 0)), Vector((c, 0, a))]
    corners = [v.normalized() for v in corners]
    iw, idk = b.mi(white), b.mi(dark)
    for v in tmp.verts:
        v.co = v.co.normalized() * R
    for f in tmp.faces:
        d = f.calc_center_median().normalized()
        near = max(d.dot(c) for c in corners)
        f.material_index = idk if near > 0.945 else iw
    b.raw(tmp)
    ob = b.build()
    return finish("toy_football", [ob], expect_tris=(600, 2000))


def toy_goal():
    """Small goal for the hall. Mouth faces Godot +Z (Blender -Y); box runs back to Blender +Y."""
    new_piece()
    frame = M("cream", 0.5, name="GoalFrame", hexv="#f3f1ea")
    net = M("cream", 0.9, name="GoalNet", hexv="#f4eedf")
    W, H, D, BH, PR = 1.1, 1.2, 0.9, 0.85, 0.075
    fb = Builder("Frame", angle=50)
    for sx in (-1, 1):
        fb.cyl(PR, H + PR, (sx * W, 0, 0), frame, segs=10, bevel=0.025)
        fb.sphere(PR * 1.15, (sx * W, 0, H), frame, segs=10, rings=6)
        # chunky foot blocks
        fb.box((0.22, 0.22, 0.08), (sx * W, 0, 0.04), frame, bevel=0.02)
    fb.cyl(PR, 2 * W, (-W, 0, H), frame, segs=10, rot=(0, math.pi / 2, 0))
    br = 0.04
    for sx in (-1, 1):
        fb.tube([(sx * W, D, 0), (sx * W, D, BH)], br, frame, sides=6)
        fb.tube([(sx * W, 0, H), (sx * W, D, BH)], br, frame, sides=6)
        fb.tube([(sx * W, 0, 0.03), (sx * W, D, 0.03)], br, frame, sides=6)
    fb.tube([(-W, D, BH), (W, D, BH)], br, frame, sides=6)
    fb.tube([(-W, D, 0.03), (W, D, 0.03)], br, frame, sides=6)
    frame_ob = fb.build()

    nb = Builder("Net", angle=80)
    t = 0.013
    for i in range(1, 8):
        x = -W + 2 * W * i / 8
        nb.tube([(x, D, 0), (x, D, BH)], t, net, sides=4)
        nb.tube([(x, 0, H), (x, D, BH)], t, net, sides=4)
    for k in range(1, 4):
        z = BH * k / 4
        nb.tube([(-W, D, z), (W, D, z)], t, net, sides=4)
    for sx in (-1, 1):
        for i in range(1, 4):
            y = D * i / 4
            nb.tube([(sx * W, y, 0), (sx * W, y, H + (BH - H) * i / 4)], t, net, sides=4)
        for k in range(1, 4):
            z = H * k / 4
            yend = D if z <= BH else D * (H - z) / (H - BH)
            nb.tube([(sx * W, 0, z), (sx * W, yend, z)], t, net, sides=4)
    net_ob = nb.build()
    return finish("toy_goal", [frame_ob, net_ob], expect_tris=(300, 3000))


def toy_trampoline():
    new_piece()
    R, TOP = 1.2, 0.46
    red = M("red", 0.6, name="PadRed", hexv=RED)
    blue = M("blue", 0.6, name="PadBlue", hexv=BLUE)
    gold = M("gold", 0.4, 0.3, name="Gold")
    mat_dark = M("charcoal", 0.85, name="MatDark", hexv="#34303c")
    star = M("gold", 0.6, name="MatStar", hexv="#f2c94c")
    fb = Builder("Frame", angle=40)
    # padded rim: 12 alternating pads, a fat rounded ring
    n = 12
    prof, _ = rrect(R - 0.24, R + 0.04, TOP - 0.13, TOP, 0.06, 0.05, 2)
    for i in range(n):
        a0 = TAU * i / n
        fb.lathe(prof, red if i % 2 == 0 else blue, segs=4, a0=a0, a1=a0 + TAU / n, closed=True)
    # gold ring under the pads + 6 stubby legs
    prof, _ = rrect(R - 0.2, R - 0.02, TOP - 0.2, TOP - 0.12, 0.02, 0.02, 1)
    fb.lathe(prof, gold, segs=36, closed=True)
    for i in range(6):
        a = TAU * (i + 0.5) / 6
        fb.cyl(0.07, TOP - 0.18, ((R - 0.11) * math.cos(a), (R - 0.11) * math.sin(a), 0), gold, segs=8, bevel=0.02)
        fb.sphere(0.1, ((R - 0.11) * math.cos(a), (R - 0.11) * math.sin(a), 0.03), gold, segs=8, rings=4,
                  scale=(1, 1, 0.45))
    frame_ob = fb.build()

    mb = Builder("Mat", angle=40)
    prof, _ = rrect(0, R - 0.2, -0.025, 0.02, 0.0, 0.0, 1)
    mb.lathe(prof, mat_dark, segs=36)
    mb.prism(star_poly(0.42, 0.18, 5), 0.019, 0.03, star)
    # a ring of stitching dots
    for i in range(16):
        a = TAU * i / 16
        mb.box((0.08, 0.03, 0.012), (0.78 * math.cos(a), 0.78 * math.sin(a), 0.024), star, rot=(0, 0, a + math.pi / 2))
    mat_ob = mb.build()
    mat_ob.location = (0, 0, 0.40)
    return finish("toy_trampoline", [frame_ob, mat_ob], expect_tris=(400, 3500))


def _bell_profile(scale=1.0):
    """(r, z) of the bell body, hanging from z = 0 down to z = -0.95 (closed, thick lip)."""
    pts = [(0.0, 0.0), (0.12, 0.0), (0.2, -0.05), (0.25, -0.18), (0.27, -0.38), (0.3, -0.6),
           (0.37, -0.8), (0.45, -0.9), (0.47, -0.95), (0.4, -0.95), (0.33, -0.88), (0.26, -0.75),
           (0.22, -0.55), (0.2, -0.3), (0.15, -0.12), (0.0, -0.08)]
    return [(r * scale, z * scale) for r, z in pts]


def toy_bell():
    new_piece()
    wood = M("wood", 0.7, name="Wood")
    dark = M("dark_wood", 0.8, name="DarkWood")
    brass = M("gold", 0.3, 0.6, name="Brass", hexv="#e2a93b")
    clapper = M("charcoal", 0.5, 0.3, name="Clapper", hexv="#4a4652")
    PX, PIVOT, TOPB = 0.85, 1.7, 1.95
    fb = Builder("Frame", angle=40)
    for sx in (-1, 1):
        fb.box((0.18, 0.18, TOPB), (sx * PX, 0, TOPB / 2), wood, bevel=0.035)
        fb.box((0.26, 0.9, 0.16), (sx * PX, 0, 0.08), dark, bevel=0.04)       # feet
        fb.box((0.08, 0.5, 0.08), (sx * PX, 0, 0.38), dark, bevel=0.02, rot=(0.0, 0, 0))
        fb.sphere(0.13, (sx * PX, 0, TOPB + 0.08), brass, segs=10, rings=6)   # finials
    fb.box((2 * PX + 0.34, 0.22, 0.2), (0, 0, TOPB - 0.02), dark, bevel=0.04)   # beam
    fb.cyl(0.05, 0.25, (0, 0, PIVOT), dark, segs=8)                            # hanger
    frame_ob = fb.build()

    bb = Builder("Bell", angle=40)
    bb.lathe(_bell_profile(), brass, segs=28, closed=True)
    bb.sphere(0.08, (0, 0, 0.02), brass, segs=10, rings=6)                     # crown knob
    # a raised band and a lip ring for the chunky toy read
    prof, _ = rrect(0.272, 0.3, -0.42, -0.36, 0.01, 0.01, 1)
    bb.lathe(prof, brass, segs=28, closed=True)
    bb.tube([(0, 0, -0.05), (0, 0, -0.78)], 0.025, clapper, sides=6)
    bb.sphere(0.09, (0, 0, -0.82), clapper, segs=10, rings=6)
    bell_ob = bb.build()
    bell_ob.location = (0, 0, PIVOT)  # built hanging from z = 0: the origin is the pivot
    return finish("toy_bell", [frame_ob, bell_ob], expect_tris=(500, 4000))


def toy_seesaw():
    new_piece()
    wood = M("wood", 0.7, name="Wood")
    dark = M("dark_wood", 0.8, name="DarkWood")
    red = M("red", 0.6, name="SeatRed", hexv=RED)
    blue = M("blue", 0.6, name="SeatBlue", hexv=BLUE)
    gold = M("gold", 0.4, 0.3, name="Gold")
    PIV = 0.5
    bb = Builder("Base", angle=40)
    # a chunky A-shaped stand seen from the front: two wedge plates with an axle
    for sy in (-1, 1):
        bb.prism([(-0.45, 0.0), (0.45, 0.0), (0.12, PIV - 0.02), (-0.12, PIV - 0.02)], -0.05, 0.05, dark,
                 bevel=0.02, rot=(math.pi / 2, 0, 0), loc=(0, sy * 0.28, 0))
    bb.box((1.0, 0.75, 0.1), (0, 0, 0.05), dark, bevel=0.03)
    bb.cyl(0.07, 0.72, (0, 0.36, PIV), gold, segs=10, rot=(math.pi / 2, 0, 0))
    base_ob = bb.build()

    pb = Builder("Plank", angle=40)
    L, Wd, T = 4.2, 0.7, 0.12
    pb.box((L, Wd, T), (0, 0, PIV + T / 2 + 0.06), wood, bevel=0.04)
    pb.box((0.3, 0.76, 0.1), (0, 0, PIV + 0.04), dark, bevel=0.03)             # hub
    for sx, mat in ((-1, red), (1, blue)):
        pb.box((0.95, Wd - 0.04, 0.06), (sx * (L / 2 - 0.55), 0, PIV + T + 0.09), mat, bevel=0.025)
        # handle loop
        x = sx * (L / 2 - 1.15)
        pb.tube([(x, -0.22, PIV + T + 0.06), (x, -0.22, PIV + T + 0.42), (x, 0.22, PIV + T + 0.42),
                 (x, 0.22, PIV + T + 0.06)], 0.035, gold, sides=6)
        # rubber stop under each end
        pb.box((0.2, 0.4, 0.08), (sx * (L / 2 - 0.2), 0, PIV + 0.02), dark, bevel=0.02)
    plank_ob = pb.build()
    for v in plank_ob.data.vertices:
        v.co.z -= PIV
    plank_ob.location = (0, 0, PIV)
    return finish("toy_seesaw", [base_ob, plank_ob], expect_tris=(300, 3000))


def toy_photo_frame():
    new_piece()
    gold = M("gold", 0.35, 0.5, name="Gold")
    canvas = M("plum", 0.9, name="Backdrop", hexv="#5b3f7a")
    star = M("cream", 0.6, name="BackdropStar", hexv="#f6d77a")
    dark = M("dark_wood", 0.8, name="DarkWood")
    W, H, Z0, FW = 2.9, 2.5, 0.25, 0.16
    b = Builder("Frame", angle=40)
    # canvas panel (sits a little behind the frame)
    b.box((W - 0.1, 0.05, H - Z0 - 0.1), (0, 0.04, Z0 + (H - Z0) / 2), canvas)
    # chunky frame bars with corner blocks
    b.box((W, 0.16, FW), (0, 0, H - FW / 2), gold, bevel=0.04)
    b.box((W, 0.16, FW), (0, 0, Z0 + FW / 2), gold, bevel=0.04)
    for sx in (-1, 1):
        b.box((FW, 0.16, H - Z0), (sx * (W / 2 - FW / 2), 0, Z0 + (H - Z0) / 2), gold, bevel=0.04)
        b.box((0.26, 0.22, 0.26), (sx * (W / 2 - FW / 2), 0, H - FW / 2), gold, bevel=0.06)
        b.box((0.26, 0.22, 0.26), (sx * (W / 2 - FW / 2), 0, Z0 + FW / 2), gold, bevel=0.06)
        # feet
        b.box((0.2, 0.75, 0.12), (sx * (W / 2 - 0.3), -0.15, 0.06), dark, bevel=0.03)
        b.box((0.12, 0.12, Z0), (sx * (W / 2 - 0.3), 0, Z0 / 2), dark, bevel=0.02)
    # stars on the canvas (front face at Blender y = 0.015)
    import random
    rng = random.Random(7)
    for i in range(14):
        x = rng.uniform(-W / 2 + 0.35, W / 2 - 0.35)
        z = rng.uniform(Z0 + 0.3, H - 0.3)
        r = rng.uniform(0.06, 0.13)
        b.prism(star_poly(r, r * 0.45, 5), 0.0, 0.012, star, rot=(math.pi / 2, 0, 0), loc=(x, 0.016, z))
    # a crown ornament on top
    b.prism(star_poly(0.22, 0.1, 5), -0.05, 0.05, gold, rot=(math.pi / 2, 0, 0), loc=(0, 0, H + 0.16))
    ob = b.build()
    return finish("toy_photo_frame", [ob], expect_tris=(300, 3000))


def toy_photo_button():
    new_piece()
    gold = M("gold", 0.35, 0.5, name="Gold")
    dark = M("dark_wood", 0.8, name="DarkWood")
    red = M("red", 0.45, name="ButtonRed", hexv="#e8383a")
    H = 0.9
    pb = Builder("Pedestal", angle=40)
    prof, _ = rrect(0, 0.26, 0, 0.08, 0.03, 0.0, 2)
    pb.lathe(prof, dark, segs=20)
    pb.cyl(0.12, H - 0.16, (0, 0, 0.06), dark, segs=14, bevel=0.02)
    prof, _ = rrect(0, 0.22, H - 0.12, H, 0.03, 0.02, 2)
    pb.lathe(prof, gold, segs=20)
    ped = pb.build()
    cb = Builder("ButtonCap", angle=40)
    cb.sphere(0.15, (0, 0, 0.0), red, segs=16, rings=8, scale=(1, 1, 0.55))
    cb.cyl(0.155, 0.04, (0, 0, -0.02), red, segs=16)
    cap = cb.build()
    for v in cap.data.vertices:
        if v.co.z < 0:
            v.co.z = 0.0
    cap.location = (0, 0, H)
    return finish("toy_photo_button", [ped, cap], expect_tris=(150, 2000))


def toy_scoreboard():
    new_piece()
    wood = M("dark_wood", 0.8, name="DarkWood")
    gold = M("gold", 0.35, 0.5, name="Gold")
    red = M("red", 0.7, name="PanelRed", hexv="#b8332d")
    blue = M("blue", 0.7, name="PanelBlue", hexv="#2d64b0")
    W, H, D = 1.9, 1.0, 0.1
    b = Builder("Board", angle=40)
    b.box((W, D, H), (0, -D / 2, H / 2), wood, bevel=0.035)
    b.box((W + 0.08, D + 0.04, 0.07), (0, -D / 2, H), gold, bevel=0.025)
    b.box((W + 0.08, D + 0.04, 0.07), (0, -D / 2, 0.0), gold, bevel=0.025)
    for sx, mat in ((-1, red), (1, blue)):
        b.box((0.72, 0.03, 0.66), (sx * 0.47, -D - 0.005, 0.45), mat, bevel=0.012)
        b.box((0.06, 0.04, 0.06), (sx * (W / 2 + 0.02), -D / 2, H + 0.08), gold, bevel=0.015)
    # gold divider dots ':'
    for z in (0.33, 0.57):
        b.sphere(0.04, (0, -D - 0.01, z), gold, segs=8, rings=4)
    ob = b.build()
    return finish("toy_scoreboard", [ob], expect_tris=(80, 1500))


ALL = [toy_football, toy_goal, toy_trampoline, toy_bell, toy_seesaw, toy_photo_frame, toy_photo_button,
       toy_scoreboard]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
