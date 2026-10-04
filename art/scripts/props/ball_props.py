"""Blob Ball props: ball_beach (the 1.4 m beach ball), ball_goal (posts, crossbar, net).

Run: tools/blender-run.ps1 art/scripts/props/ball_props.py [piece names...]

ball_beach: origin at the ball's CENTRE (it spins about it), radius 0.7 m. Six gores in the
  classic beach-ball colours alternating with white, white caps on both poles.
ball_goal: origin at the middle of the goal mouth on the ground. The mouth faces Godot +Z
  (Blender -Y); the net box runs 1.8 m back (Godot -Z). Posts at Godot x = +-2.0 (centre),
  0.12 m radius, crossbar centre 2.2 m up. Frame material `TeamFrame` is recoloured per team
  at runtime; the net is `Net`.
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pcommon import *  # noqa: F401,F403
import artlib

BALL_R = 0.7
GOAL_HALF_W = 2.0
GOAL_H = 2.2
GOAL_DEPTH = 1.8
GOAL_BACK_H = 1.45
POST_R = 0.12


def ball_beach():
    """Beach ball, 1.4 m across. Origin at its centre."""
    new_piece()
    R = BALL_R
    white = M("cream", 0.45, name="BallWhite", hexv="#fbf7ee")
    colours = [M("red", 0.45, name="BallRed", hexv="#e6413a"),
               M("gold", 0.45, name="BallYellow", hexv="#f6c632"),
               M("blue", 0.45, name="BallBlue", hexv="#2f7fe0")]
    cap = math.radians(16.0)
    rings = 14
    b = Builder("Ball", angle=60)
    # gores between the caps: 6 sectors, coloured / white alternating
    prof = []
    for i in range(rings + 1):
        a = cap + (math.pi - 2 * cap) * i / rings
        prof.append((R * math.sin(a), -R * math.cos(a)))
    for g in range(6):
        a0 = math.tau * g / 6
        a1 = math.tau * (g + 1) / 6
        mat = colours[g // 2] if g % 2 == 0 else white
        b.lathe(prof, mat, segs=6, a0=a0, a1=a1, caps=False)
    # pole caps (white, a hair proud of the gores so the seam reads)
    cprof = [(0.0, -R * 1.004)] + [(R * 1.004 * math.sin(cap * i / 3), -R * 1.004 * math.cos(cap * i / 3)) for i in range(1, 4)]
    b.lathe(cprof, white, segs=36)
    b.lathe([(r, -z) for r, z in reversed(cprof)], white, segs=36)
    # valve nub on one cap
    b.sphere(0.05, (0, 0, R * 1.0), M("cream", 0.5, name="BallValve", hexv="#d8d2c4"), segs=8, rings=5, scale=(1, 1, 0.6))
    ob = b.build()
    return finish("ball_beach", [ob], expect_tris=(300, 3000))


def _bar(b, p0, p1, r, mat, sides=6):
    b.tube([p0, p1], r, mat, sides=sides)


def ball_goal():
    """Goal frame + net. Origin at the mouth centre on the ground; mouth faces Godot +Z (Blender -Y)."""
    new_piece()
    frame = M("cream", 0.55, name="TeamFrame", hexv="#f3f1ea")
    back = M("charcoal", 0.7, name="GoalBack", hexv="#3b3640")
    net = M("cream", 0.9, name="Net", hexv="#eef0f2")
    W, H, D, BH = GOAL_HALF_W, GOAL_H, GOAL_DEPTH, GOAL_BACK_H
    fb = Builder("Frame", angle=50)
    for sx in (-1, 1):
        fb.cyl(POST_R, H + POST_R, (sx * W, 0, 0), frame, segs=12, bevel=0.03)
    # crossbar along X at the top
    fb.cyl(POST_R, 2 * W, (-W, 0, H), frame, segs=12, rot=(0, math.pi / 2, 0))
    # corner caps where the crossbar meets the posts
    for sx in (-1, 1):
        fb.sphere(POST_R * 1.05, (sx * W, 0, H), frame, segs=12, rings=6)
    frame_ob = fb.build()

    bb = Builder("Support", angle=50)
    br = 0.05
    for sx in (-1, 1):
        _bar(bb, (sx * W, D, 0), (sx * W, D, BH), br, back)            # back posts
        _bar(bb, (sx * W, 0, H), (sx * W, D, BH), br, back)            # roof sides
        _bar(bb, (sx * W, 0, 0.03), (sx * W, D, 0.03), br, back)       # ground sides
    _bar(bb, (-W, D, BH), (W, D, BH), br, back)                        # back top
    _bar(bb, (-W, D, 0.03), (W, D, 0.03), br, back)                    # back ground
    support_ob = bb.build()

    nb = Builder("Net", angle=80)
    t = 0.014
    # back panel
    nx = 10
    for i in range(1, nx):
        x = -W + 2 * W * i / nx
        _bar(nb, (x, D, 0), (x, D, BH), t, net, sides=4)
    for k in range(1, 5):
        z = BH * k / 5
        _bar(nb, (-W, D, z), (W, D, z), t, net, sides=4)
    # side panels (trapezoids: H at the mouth, BH at the back)
    for sx in (-1, 1):
        for i in range(1, 5):
            y = D * i / 5
            top = H + (BH - H) * i / 5
            _bar(nb, (sx * W, y, 0), (sx * W, y, top), t, net, sides=4)
        for k in range(1, 6):
            z = H * k / 6
            # horizontal line clipped by the sloping roof
            yend = D if z <= BH else D * (H - z) / (H - BH)
            _bar(nb, (sx * W, 0, z), (sx * W, yend, z), t, net, sides=4)
    # roof (sloping from the crossbar to the back top)
    for i in range(1, nx):
        x = -W + 2 * W * i / nx
        _bar(nb, (x, 0, H), (x, D, BH), t, net, sides=4)
    for k in range(1, 4):
        f = k / 4
        _bar(nb, (-W, D * f, H + (BH - H) * f), (W, D * f, H + (BH - H) * f), t, net, sides=4)
    net_ob = nb.build()
    return finish("ball_goal", [frame_ob, support_ob, net_ob], expect_tris=(300, 5000))


ALL = [ball_beach, ball_goal]

if __name__ == "__main__":
    want = artlib.script_args()
    for fn in ALL:
        if not want or fn.__name__ in want:
            fn()
