"""Snowball Fight props (the mansion's snowy courtyard): snow_wall, snow_man, snow_man_shell, snow_pile,
snow_pine, snow_lantern, snow_drift, snow_yard_wall.

snow_wall: a low wall of packed snow blocks, 2.4 m long (Godot x -1.2..1.2), 0.6 m thick (z -0.3..0.3),
  1.1 m high with a rounded snow cap. Cover: the game blocks snowballs with a box of that size.
snow_man: a cover snowman, three balls (base r 0.55), coal eyes and buttons, carrot nose, red scarf, top hat,
  stick arms. About 1.9 m tall; the game blocks snowballs with a cylinder r 0.55. Faces Godot +Z.
snow_man_shell: the "snowed in" shell put over a blob (1.0 m tall, 0.8 m wide): a big snow body r 0.5 that
  hides the blob, a head ball with coal eyes and a carrot nose, stick arms and a little bucket hat.
  About 1.55 m tall, faces Godot +Z.
snow_pile: the giant ammo pile: a snow mound (r 0.95) stacked with a pyramid of snowballs and a little
  blue pennant on top, about 1.5 m tall.
snow_pine: a pine (trunk + four tiers) with snow on every tier, 3.8 m tall, r 1.3 at the bottom tier.
snow_lantern: an iron lamp post 2.1 m tall with a warm glowing lantern (EmitLanternGlow) and a snow cap.
snow_drift: a low lumpy snow mound, about 2.2 x 1.3 m, 0.4 m high.
snow_yard_wall: a courtyard boundary wall segment of grey stone, 4.2 m long (x -2.1..2.1), 0.5 m thick
  (z -0.25..0.25), 1.5 m high, with a thick snow cap and icicles on the front (+Z) face.
Run: tools/blender-run.ps1 art/scripts/props/snow_props.py [piece names...]
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

HALF_PI = math.pi / 2


def _snow():
    return M("cream", 0.9, name="Snow", hexv="#e2eaf4")


def _snow_shade():
    return M("cream", 0.9, name="SnowShade", hexv="#bccde2")


def _coal():
    return M("charcoal", 0.6, name="Coal", hexv="#26232b")


def _carrot():
    return M("lava", 0.6, name="Carrot", hexv="#f08a24")


def _stick():
    return M("dark_wood", 0.85, name="Stick", hexv="#5e4030")


def _face(b, cx, cy, cz, r, coal, carrot, nose=0.22):
    """Coal eyes and a carrot nose on a head ball of radius r centred at (cx, cy, cz); front is -Y."""
    for sx in (-1, 1):
        a = math.radians(22 * sx)
        b.sphere(r * 0.12, (cx + math.sin(a) * r * 0.9, cy - math.cos(a) * r * 0.9 * 0.97, cz + r * 0.25), coal,
                 segs=6, rings=4)
    b.cyl(r * 0.16, nose, (cx, cy - r * 0.85, cz), carrot, segs=8, rot=(HALF_PI, 0, 0), r_top=0.01)


def _arm(b, x0, z0, side, length, stick):
    """A twig arm leaving the body at (x0, 0, z0) to one side, with two small fingers."""
    end = (x0 + side * length, 0.0, z0 + length * 0.45)
    b.tube([(x0, 0.0, z0), end], 0.03, stick, sides=5)
    for k in (-1, 1):
        f = (end[0] + side * 0.12, 0.0, end[2] + 0.08 * k + 0.05)
        b.tube([end, f], 0.018, stick, sides=4)


def snow_wall():
    new_piece()
    snow, shade = _snow(), _snow_shade()
    b = Builder("snow_wall", angle=40)
    rng = random.Random(7)
    L, T, H = 2.4, 0.6, 1.1
    # two staggered rows of packed blocks
    rows = [(0.0, 0.46, 0.6), (0.46, 0.84, 0.3)]
    for z0, z1, off in rows:
        edges = [-L / 2]
        x = -L / 2 + off
        while x < L / 2 - 0.1:
            edges.append(x)
            x += 0.6
        edges.append(L / 2)
        for i, (x0, x1) in enumerate(zip(edges[:-1], edges[1:])):
            jit = rng.uniform(-0.015, 0.015)
            mat = shade if (i + int(off * 10)) % 3 == 0 else snow
            b.box((x1 - x0 - 0.03, T + jit, z1 - z0 - 0.03), ((x0 + x1) / 2, 0, (z0 + z1) / 2), mat, bevel=0.06, seg=2)
    # rounded cap on top
    b.box((L + 0.04, T + 0.08, 0.3), (0, 0, H - 0.15), snow, bevel=0.14, seg=3)
    # lumps along the cap
    for i in range(6):
        x = -L / 2 + 0.25 + (L - 0.5) * i / 5 + rng.uniform(-0.08, 0.08)
        b.ico(0.16, (x, rng.uniform(-0.08, 0.08), H - 0.06), snow, subdiv=1, scale=(1.3, 1.0, 0.55))
    ob = b.build()
    return finish("snow_wall", [ob], expect_tris=(100, 4000))


def snow_man():
    new_piece()
    snow, shade, coal, carrot, stick = _snow(), _snow_shade(), _coal(), _carrot(), _stick()
    scarf = M("red", 0.8, name="Scarf", hexv="#d9483b")
    hat = M("charcoal", 0.7, name="HatBlack", hexv="#2b2730")
    band = M("red", 0.7, name="HatBand", hexv="#3f7fd9")
    b = Builder("snow_man", angle=40)
    b.sphere(0.55, (0, 0, 0.5), snow, segs=20, rings=12, scale=(1, 1, 0.92))
    b.sphere(0.41, (0, 0, 1.13), snow, segs=18, rings=10)
    b.sphere(0.29, (0, 0, 1.6), snow, segs=16, rings=10)
    # a skirt of shade at the bottom so it sits in the snow
    b.cyl(0.6, 0.08, (0, 0, 0), shade, segs=18, bevel=0.03)
    _face(b, 0, 0, 1.6, 0.29, coal, carrot, nose=0.26)
    for k in range(3):
        z = 1.0 + 0.16 * k
        b.sphere(0.04, (0, -math.sqrt(max(0.41 ** 2 - (z - 1.13) ** 2, 0.01)) - 0.005, z), coal, segs=6, rings=4)
    # scarf: a ring plus a hanging tail
    prof, _ = rrect(0.25, 0.33, 1.34, 1.44, 0.03, 0.03, 1)
    b.lathe(prof, scarf, segs=18, closed=True)
    b.box((0.12, 0.05, 0.32), (0.16, -0.27, 1.22), scarf, bevel=0.02, rot=(0, 0.15, 0))
    # top hat
    b.cyl(0.3, 0.03, (0, 0, 1.84), hat, segs=16, bevel=0.01)
    b.cyl(0.19, 0.32, (0, 0, 1.86), hat, segs=16, bevel=0.02)
    b.cyl(0.195, 0.06, (0, 0, 1.9), band, segs=16)
    _arm(b, 0.36, 1.18, 1, 0.48, stick)
    _arm(b, -0.36, 1.18, -1, 0.48, stick)
    ob = b.build()
    return finish("snow_man", [ob], expect_tris=(200, 5000))


def snow_man_shell():
    new_piece()
    snow, shade, coal, carrot, stick = _snow(), _snow_shade(), _coal(), _carrot(), _stick()
    bucket = M("blue", 0.6, name="Bucket", hexv="#3f7fd9")
    b = Builder("snow_man_shell", angle=40)
    # body: a big lumpy snow ball that swallows the blob (1.0 m tall, 0.8 m wide)
    b.ico(0.52, (0, 0, 0.52), snow, subdiv=3, scale=(1.0, 1.0, 1.04), fn=lumps(3, amp=0.05), zmin=-0.5)
    b.cyl(0.56, 0.07, (0, 0, 0), shade, segs=18, bevel=0.03)
    # head
    b.sphere(0.27, (0, 0, 1.25), snow, segs=16, rings=10)
    _face(b, 0, 0, 1.25, 0.27, coal, carrot, nose=0.22)
    for k in range(2):
        b.sphere(0.04, (0, -0.5, 0.55 + 0.2 * k), coal, segs=6, rings=4)
    # bucket hat, tilted
    b.cyl(0.17, 0.2, (0.02, 0.0, 1.45), bucket, segs=14, r_top=0.13, rot=(0.0, 0.18, 0.0))
    _arm(b, 0.45, 0.75, 1, 0.42, stick)
    _arm(b, -0.45, 0.75, -1, 0.42, stick)
    ob = b.build()
    return finish("snow_man_shell", [ob], expect_tris=(200, 5000))


def snow_pile():
    new_piece()
    snow, shade = _snow(), _snow_shade()
    pole = _stick()
    flag = M("blue", 0.6, name="Pennant", hexv="#3fa8ff")
    b = Builder("snow_pile", angle=40)
    b.ico(0.95, (0, 0, 0), shade, subdiv=3, scale=(1.0, 1.0, 0.42), fn=lumps(11, amp=0.08), zmin=0.0)
    # pyramid of snowballs
    r = 0.2
    layers = [(0.42, 7, 0.36), (0.24, 5, 0.68), (0.0, 1, 0.98)]
    for ring_r, n, z in layers:
        for i in range(n):
            a = TAU * i / n + 0.3 * z
            b.sphere(r, (ring_r * math.cos(a), ring_r * math.sin(a), z), snow, segs=12, rings=8)
    b.sphere(r, (0, 0, 0.6), snow, segs=12, rings=8)
    # pennant
    b.cyl(0.02, 0.55, (0, 0, 1.12), pole, segs=6)
    b.prism([(0.0, 0.0), (0.3, 0.09), (0.0, 0.18)], -0.01, 0.01, flag, loc=(0.0, 0.0, 1.47), rot=(HALF_PI, 0, 0))
    ob = b.build()
    return finish("snow_pile", [ob], expect_tris=(200, 5000))


def snow_pine():
    new_piece()
    snow = _snow()
    bark = M("dark_wood", 0.9, name="PineBark", hexv="#5b3a29")
    needles = M("green", 0.85, name="PineNeedles", hexv="#2f6b4f")
    needles_dk = M("green", 0.85, name="PineNeedlesDark", hexv="#24543f")
    b = Builder("snow_pine", angle=50)
    b.cyl(0.18, 0.9, (0, 0, 0), bark, segs=8)
    tiers = [(1.3, 0.6, 1.4), (1.05, 1.3, 1.25), (0.8, 2.0, 1.1), (0.5, 2.7, 1.0)]
    for i, (rad, z, h) in enumerate(tiers):
        mat = needles if i % 2 == 0 else needles_dk
        b.cyl(rad, h, (0, 0, z), mat, segs=10, r_top=0.05)
        # snow cap on the upper part of each tier
        cap_r = rad * 0.55
        b.cyl(cap_r + 0.04, h * 0.42, (0, 0, z + h * 0.58 - 0.02), snow, segs=10, r_top=0.06)
    ob = b.build()
    return finish("snow_pine", [ob], expect_tris=(100, 3000))


def snow_lantern():
    new_piece()
    snow = _snow()
    iron = M("charcoal", 0.5, 0.3, name="Iron", hexv="#2e2a33")
    glow = EM("EmitLanternGlow", "#ffc46b", 2.4, 0.4)
    b = Builder("snow_lantern", angle=40)
    b.cyl(0.16, 0.12, (0, 0, 0), iron, segs=10, bevel=0.02)
    b.cyl(0.05, 1.7, (0, 0, 0.1), iron, segs=8)
    b.box((0.26, 0.26, 0.04), (0, 0, 1.8), iron, bevel=0.01)
    b.box((0.2, 0.2, 0.26), (0, 0, 1.95), glow, bevel=0.01)
    for sx in (-1, 1):
        for sy in (-1, 1):
            b.box((0.03, 0.03, 0.28), (sx * 0.11, sy * 0.11, 1.95), iron)
    b.cyl(0.2, 0.12, (0, 0, 2.08), iron, segs=4, r_top=0.03, rot=(0, 0, math.pi / 4))
    b.ico(0.13, (0, 0, 2.12), snow, subdiv=1, scale=(1.2, 1.2, 0.5))
    ob = b.build()
    return finish("snow_lantern", [ob], expect_tris=(100, 2500))


def snow_drift():
    new_piece()
    snow, shade = _snow(), _snow_shade()
    b = Builder("snow_drift", angle=50)
    b.ico(1.0, (0, 0, 0), snow, subdiv=3, scale=(1.1, 0.65, 0.4), fn=lumps(5, amp=0.12),
          zmin=0.0, mat_fn=lambda nz: snow if nz > 0.35 else shade)
    b.ico(0.6, (0.7, 0.2, 0), snow, subdiv=2, scale=(1.0, 0.8, 0.45), fn=lumps(9, amp=0.1), zmin=0.0)
    ob = b.build()
    return finish("snow_drift", [ob], expect_tris=(100, 3000))


def snow_yard_wall():
    new_piece()
    snow = _snow()
    stone = M("stone", 0.85, name="YardStone", hexv="#8d8794")
    stone_dk = M("dark_stone", 0.85, name="YardStoneDark", hexv="#6e6876")
    ice = M("blue", 0.2, name="Ice", hexv="#cfe8ff")
    b = Builder("snow_yard_wall", angle=40)
    rng = random.Random(21)
    L, T, H = 4.2, 0.5, 1.5
    rows = 4
    for r in range(rows):
        z0 = r * (H - 0.2) / rows
        z1 = z0 + (H - 0.2) / rows
        w = L / 5
        off = w / 2 if r % 2 else w
        edges = [-L / 2]
        x = -L / 2 + off
        while x < L / 2 - 0.15:
            edges.append(x)
            x += w
        edges.append(L / 2)
        for x0, x1 in zip(edges[:-1], edges[1:]):
            mat = stone_dk if rng.random() < 0.3 else stone
            b.box((x1 - x0 - 0.03, T + rng.uniform(-0.02, 0.02), z1 - z0 - 0.03),
                  ((x0 + x1) / 2, 0, (z0 + z1) / 2), mat, bevel=0.03)
    # snow cap
    b.box((L + 0.02, T + 0.14, 0.28), (0, 0, H - 0.1), snow, bevel=0.12, seg=2)
    for i in range(8):
        x = -L / 2 + 0.25 + (L - 0.5) * i / 7 + rng.uniform(-0.1, 0.1)
        b.ico(0.18, (x, rng.uniform(-0.06, 0.06), H + 0.0), snow, subdiv=1, scale=(1.4, 1.0, 0.5))
    # icicles on the front (-Y = Godot +Z)
    for i in range(9):
        x = -L / 2 + 0.2 + (L - 0.4) * i / 8 + rng.uniform(-0.08, 0.08)
        h = rng.uniform(0.12, 0.3)
        b.cyl(0.04, h, (x, -T / 2 - 0.05, H - 0.2), ice, segs=5, r_top=0.004, rot=(math.pi, 0, 0))
    ob = b.build()
    return finish("snow_yard_wall", [ob], expect_tris=(100, 4000))


ALL = [snow_wall, snow_man, snow_man_shell, snow_pile, snow_pine, snow_lantern, snow_drift, snow_yard_wall]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
