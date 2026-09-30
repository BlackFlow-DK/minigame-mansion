"""Player blob -> game/assets/models/character/blob.glb.

Binding spec: docs/contract.md "Character model and cosmetics". Separate objects so the
visuals component can animate without a skeleton:
  Body, EyeL, EyeR, PupilL, PupilR, LidL, LidR, Mouth, CheekL, CheekR, HandL, HandR,
  FootL, FootR + empties HatSocket, FaceSocket, NeckSocket, BackSocket.
All are direct children of the scene root. Extra detail (belly patch, thumbs, soles,
eye shines, tongue, teeth, lip rim) is merged into its owner mesh as extra material
slots, so it follows that object automatically and adds no nodes.

Geometry is written in Godot space (x, y, z: +Y up, front +Z, character left = +X)
relative to each object's origin and converted to Blender (x, -z, y) once, in
make_object(). No object carries a rotation or scale: animation starts from identity.

Run: powershell -NoProfile -ExecutionPolicy Bypass -File tools\\blender-run.ps1 art\\scripts\\character\\blob.py
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import bmesh  # noqa: E402
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import artlib  # noqa: E402

TAU = 2.0 * math.pi

# ---------------------------------------------------------------- body profile
# Head dome: exact sphere r=0.38 centred at y=0.62 (hats are fitted to it).
HEAD_C, HEAD_R = 0.62, 0.38
# Neck ring: r=0.40 at y=0.40 (scarves are fitted to it).
NECK_Y, NECK_R, NECK_SLOPE = 0.40, 0.40, -0.12
# Belly (widest, slight pear) and the rounded base.
BELLY_Y, BELLY_R = 0.29, 0.41
BASE_R = 0.10


def _herm(y, y0, r0, m0, y1, r1, m1):
    h = y1 - y0
    t = (y - y0) / h
    t2, t3 = t * t, t * t * t
    return ((2 * t3 - 3 * t2 + 1) * r0 + (t3 - 2 * t2 + t) * h * m0
            + (-2 * t3 + 3 * t2) * r1 + (t3 - t2) * h * m1)


def body_r(y):
    """Body radius at height y (Godot)."""
    if y < BELLY_Y:
        k = (BELLY_Y - max(y, 0.0)) / BELLY_Y
        return BASE_R + (BELLY_R - BASE_R) * math.sqrt(max(0.0, 1.0 - k * k))
    if y < NECK_Y:
        return _herm(y, BELLY_Y, BELLY_R, 0.0, NECK_Y, NECK_R, NECK_SLOPE)
    if y < HEAD_C:
        return _herm(y, NECK_Y, NECK_R, NECK_SLOPE, HEAD_C, HEAD_R, 0.0)
    return math.sqrt(max(0.0, HEAD_R ** 2 - (y - HEAD_C) ** 2))


def body_host(s, y):
    """Point and outward normal on the body surface; s = arc length around from the front."""
    r = body_r(y)
    th = s / r
    e = 1e-4
    drdy = (body_r(y + e) - body_r(y - e)) / (2 * e)
    nr, ny = 1.0, -drdy
    ln = math.hypot(nr, ny)
    nr, ny = nr / ln, ny / ln
    p = Vector((r * math.sin(th), y, r * math.cos(th)))
    n = Vector((nr * math.sin(th), ny, nr * math.cos(th)))
    return p, n


def body_surface_z(x, y):
    r = body_r(y)
    return math.sqrt(max(0.0, r * r - x * x))


# ---------------------------------------------------------------- face layout
EYE_X, EYE_Y = 0.138, 0.665
EYE_A, EYE_B = 0.090, 0.114          # ellipsoid semi-axes: x, and y = z (circular in YZ for the lid)
EYE_PROTRUDE = 0.027                  # how far the eye front stands off the body surface
EYE_Z = body_surface_z(EYE_X, EYE_Y) + EYE_PROTRUDE - EYE_B
PUPIL_S, PUPIL_T = 0.047, 0.060       # pupil semi-axes on the eye surface
PUPIL_OFF = (-0.006, 0.003)           # rest look: a hair inward (toward the nose) and up (camera is above)
LID_IN, LID_OUT = 0.0068, 0.0138      # lid shell offsets from the eye surface
# Lid spans LID_BACK..LID_EDGE (angle about the eye's X axis, from +Y toward +Z). At rest the
# edge is tucked inside the head (eyes fully open); rotation.x > 0 lowers it over the eye.
LID_BACK, LID_EDGE = math.radians(-128.0), math.radians(14.0)
MOUTH_Y = 0.54
CHEEK_S, CHEEK_Y = 0.218, 0.555
HAND_POS = (0.485, 0.30, 0.05)
FOOT_POS = (0.165, 0.058, 0.20)

SOCKETS = {
    "HatSocket": (0.0, 1.00, 0.0),
    "FaceSocket": (0.0, 0.68, 0.37),
    "NeckSocket": (0.0, 0.40, 0.0),
    "BackSocket": (0.0, 0.50, -0.37),
}


# ---------------------------------------------------------------- mesh building
class MB:
    """Minimal mesh builder: vertices in Godot space (relative to the object origin), faces, materials."""

    def __init__(self):
        self.v, self.f, self.m = [], [], []

    def rings(self, rings, mats, pole0=None, pole1=None, fan_mats=None, mat_fn=None):
        """Quad bands between closed rings (same length), optional fans to poles.
        mats[i] is the material of band i (ring i -> i+1); pole fans use fan_mats or the first/last.
        mat_fn(i, j) -> material or None overrides the quad between ring points j and j+1 of band i."""
        m0, m1 = fan_mats or (mats[0], mats[-1])
        base = len(self.v)
        n = len(rings[0])
        for ring in rings:
            self.v.extend(Vector(p) for p in ring)
        idx = lambda i, j: base + i * n + (j % n)  # noqa: E731
        if pole0 is not None:
            c = len(self.v)
            self.v.append(Vector(pole0))
            for j in range(n):
                self.f.append((c, idx(0, j + 1), idx(0, j)))
                self.m.append(m0)
        for i in range(len(rings) - 1):
            for j in range(n):
                self.f.append((idx(i, j), idx(i, j + 1), idx(i + 1, j + 1), idx(i + 1, j)))
                self.m.append((mat_fn and mat_fn(i, j)) or mats[i])
        if pole1 is not None:
            c = len(self.v)
            self.v.append(Vector(pole1))
            last = len(rings) - 1
            for j in range(n):
                self.f.append((c, idx(last, j), idx(last, j + 1)))
                self.m.append(m1)


def ellipsoid(mb, centre, axes, mat, n=16, rings=8, deform=None, xform=None):
    """Closed ellipsoid, poles along local Y. deform(p, unit) -> p; xform: Matrix applied after."""
    cx = Vector(centre)
    pts = []
    for i in range(1, rings):
        ph = math.pi * i / rings
        ring = []
        for j in range(n):
            be = TAU * j / n
            u = Vector((math.sin(ph) * math.cos(be), math.cos(ph), math.sin(ph) * math.sin(be)))
            p = Vector((u.x * axes[0], u.y * axes[1], u.z * axes[2]))
            if deform:
                p = deform(p, u)
            if xform:
                p = xform @ p
            ring.append(p + cx)
        pts.append(ring)

    def pole(y):
        u = Vector((0.0, y, 0.0))
        p = Vector((0.0, y * axes[1], 0.0))
        if deform:
            p = deform(p, u)
        if xform:
            p = xform @ p
        return p + cx

    mb.rings(pts, [mat] * (len(pts) - 1) or [mat], pole(1.0), pole(-1.0))


def decal(mb, host, centre_st, outline, profile, origin, segs=24):
    """A closed lens stuck onto a host surface.

    host(s, t) -> (point, normal); outline(alpha) -> (s, t) around (0, 0);
    profile: [(rho, d, h, mat)] from the top pole to the bottom pole: each ring is
    rho * outline + d * outline_normal, lifted h along the host normal.
    """
    s0, t0 = centre_st
    origin = Vector(origin)

    def o_and_n(a):
        s, t = outline(a)
        e = 1e-3
        s1, t1 = outline(a - e)
        s2, t2 = outline(a + e)
        tx, ty = s2 - s1, t2 - t1
        nx, ny = ty, -tx
        ln = math.hypot(nx, ny) or 1.0
        nx, ny = nx / ln, ny / ln
        if nx * s + ny * t < 0:
            nx, ny = -nx, -ny
        return s, t, nx, ny

    frame = [o_and_n(TAU * j / segs) for j in range(segs)]

    def point(s, t, h):
        p, nrm = host(s0 + s, t0 + t)
        return p + nrm * h - origin

    # profile entry i's material covers the span from entry i to entry i+1.
    rings = [[point(rho * s + d * nx, rho * t + d * ny, h) for (s, t, nx, ny) in frame]
             for rho, d, h, _ in profile[1:-1]]
    mats = [e[3] for e in profile]
    mb.rings(rings, mats[1:-2], point(0.0, 0.0, profile[0][2]), point(0.0, 0.0, profile[-1][2]),
             fan_mats=(mats[0], mats[-2]))


def ellipse(a, b):
    return lambda al: (a * math.cos(al), b * math.sin(al))


def make_object(name, mb, origin, sharp_deg=50.0):
    """Create the mesh object `name` with its origin at Godot position `origin`."""
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(p.x, -p.z, p.y) for p in mb.v], [], [tuple(f) for f in mb.f])
    slots = []
    for m in mb.m:
        if m not in slots:
            slots.append(m)
    for m in slots:
        mesh.materials.append(m)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.faces.ensure_lookup_table()
    for f, m in zip(bm.faces, mb.m):
        f.material_index = slots.index(m)
        f.smooth = True
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    sharp = math.radians(sharp_deg)
    for e in bm.edges:
        if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > sharp:
            e.smooth = False
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = artlib.from_godot(tuple(origin))
    return artlib.finalize(obj, name)


def mirror_x(mb):
    for p in mb.v:
        p.x = -p.x
    return mb


# ---------------------------------------------------------------- materials
def build_materials():
    mats = {
        "PlayerPrimary": artlib.material("PlayerPrimary", "#e8e8e8", roughness=0.42),
        "PlayerSecondary": artlib.material("PlayerSecondary", "#bdbdbd", roughness=0.5),
        "EyeWhite": artlib.material("EyeWhite", "#fbfaf5", roughness=0.18),
        "Pupil": artlib.material("Pupil", "#1d1a2c", roughness=0.15),
        "EyeShine": artlib.material("EyeShine", "#ffffff", roughness=0.1),
        "MouthInterior": artlib.material("MouthInterior", "#5c1d33", roughness=0.6),
        "Tongue": artlib.material("Tongue", "#ff7089", roughness=0.45),
        "Teeth": artlib.material("Teeth", "#fffaf0", roughness=0.3),
        "CheekBlush": artlib.material("CheekBlush", "#ff8c9e", roughness=0.75),
        "ShoeSole": artlib.material("ShoeSole", "#564a60", roughness=0.7),
        "LidLine": artlib.material("LidLine", "#2b2238", roughness=0.4),
    }
    shine = mats["EyeShine"].node_tree.nodes.get("Principled BSDF")
    shine.inputs["Emission Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    shine.inputs["Emission Strength"].default_value = 1.0
    return mats


# ---------------------------------------------------------------- parts
def build_body(M):
    mb = MB()
    segs = 36
    prof = [(0.05, 0.0)]
    for i in range(8):
        t = (i / 7) * math.pi / 2
        prof.append((BASE_R + (BELLY_R - BASE_R) * math.sin(t), BELLY_Y - BELLY_Y * math.cos(t)))
    for y in (0.345, NECK_Y, 0.455, 0.51, 0.565, HEAD_C):
        prof.append((body_r(y), y))
    for k in range(1, 9):
        al = math.radians(10 * k)
        prof.append((HEAD_R * math.cos(al), HEAD_C + HEAD_R * math.sin(al)))
    rings = [[(r * math.sin(TAU * j / segs), y, r * math.cos(TAU * j / segs)) for j in range(segs)]
             for r, y in prof]
    prim = M["PlayerPrimary"]
    mb.rings(rings, [prim] * (len(rings) - 1), (0.0, 0.0, 0.0), (0.0, HEAD_C + HEAD_R, 0.0))

    # Belly patch (secondary colour): a soft raised oval on the front, below the neck ring.
    sec = M["PlayerSecondary"]
    # Its edge stays a hair above the faceted body so the outline is clean, then drops inside.
    decal(mb, body_host, (0.0, 0.212), ellipse(0.212, 0.150), [
        (0.0, 0.0, 0.0055, sec), (0.45, 0.0, 0.0054, sec), (0.75, 0.0, 0.0048, sec),
        (0.92, 0.0, 0.0034, sec), (1.0, 0.0, 0.0016, sec), (1.0, 0.0, -0.005, sec),
        (0.0, 0.0, -0.007, sec)], origin=(0, 0, 0), segs=26)
    return make_object("Body", mb, (0.0, 0.0, 0.0))


def eye_host(s, t):
    """Front surface of the eye ellipsoid (A, B, B), eye-local coordinates."""
    a, b = EYE_A, EYE_B
    q = max(1e-6, 1.0 - (s / a) ** 2 - (t / b) ** 2)
    z = b * math.sqrt(q)
    n = Vector((s / (a * a), t / (b * b), z / (b * b))).normalized()
    return Vector((s, t, z)), n


def eye_param(u, v, rad):
    """Ellipsoid point with poles along X: u from +X (0) to -X (pi); v from +Y toward +Z."""
    return Vector(((EYE_A + rad) * math.cos(u), (EYE_B + rad) * math.sin(u) * math.cos(v),
                   (EYE_B + rad) * math.sin(u) * math.sin(v)))


def build_eye(M, side):
    centre = Vector((side * EYE_X, EYE_Y, EYE_Z))
    mb = MB()
    n, nr = 20, 10
    rings = [[eye_param(math.pi * i / nr, TAU * j / n, 0.0) for j in range(n)] for i in range(1, nr)]
    mb.rings(rings, [M["EyeWhite"]] * (len(rings) - 1),
             eye_param(0.0, 0.0, 0.0), eye_param(math.pi, 0.0, 0.0))
    eye = make_object("EyeL" if side > 0 else "EyeR", mb, centre)

    # Pupil with two shine dots, conforming to the eye front; origin at the pupil centre.
    ps, pt = PUPIL_OFF[0] * side, PUPIL_OFF[1]
    p0, n0 = eye_host(ps, pt)
    p_origin = p0 + n0 * 0.0014
    mb = MB()
    pup, shine = M["Pupil"], M["EyeShine"]
    decal(mb, eye_host, (ps, pt), ellipse(PUPIL_S, PUPIL_T), [
        (0.0, 0.0, 0.0022, pup), (0.55, 0.0, 0.0021, pup), (0.85, 0.0, 0.0015, pup),
        (1.0, 0.0, 0.0002, pup), (1.0, 0.0, -0.007, pup), (0.0, 0.0, -0.007, pup)],
        origin=p_origin, segs=18)
    for (ds, dt, r) in ((0.015, 0.022, 0.016), (-0.017, -0.023, 0.007)):
        decal(mb, eye_host, (ps + ds, pt + dt), ellipse(r, r * 1.08), [
            (0.0, 0.0, 0.0034, shine), (0.65, 0.0, 0.0032, shine), (1.0, 0.0, 0.0024, shine),
            (1.0, 0.0, 0.0010, shine), (0.0, 0.0, 0.0010, shine)],
            origin=p_origin, segs=10)
    pupil = make_object("PupilL" if side > 0 else "PupilR", mb, centre + p_origin, sharp_deg=70.0)

    # Lid: thick shell of the eye ellipsoid spanning LID_BACK..LID_EDGE in v, pivot = eye centre.
    # Cross-section loop (v, offset): outer shell -> rounded front rim -> inner shell -> back rim.
    # The front rim and a thin band of the outer shell are the dark lash line: a closed eye
    # reads as a curved line, a half-closed one as a heavy upper lid.
    loop = []
    rm, rr = (LID_IN + LID_OUT) / 2, (LID_OUT - LID_IN) / 2
    bm_ = EYE_B + rm
    near_edge = LID_EDGE - 0.20
    for k in range(8):
        loop.append((LID_BACK + (near_edge - LID_BACK) * k / 7, LID_OUT))
    loop.append((LID_EDGE - 0.06, LID_OUT))
    loop.append((LID_EDGE, LID_OUT))
    for k in (1, 2, 3):
        ph = math.pi * k / 4
        loop.append((LID_EDGE + rr / bm_ * math.sin(ph) * 1.4, rm + rr * math.cos(ph)))
    for k in range(9):
        loop.append((LID_EDGE + (LID_BACK - LID_EDGE) * k / 8, LID_IN))
    for k in (1, 2, 3):
        ph = math.pi * k / 4
        loop.append((LID_BACK - rr / bm_ * math.sin(ph), rm - rr * math.cos(ph)))
    eps = 0.10
    nu = 9
    rings = []
    for i in range(nu):
        u = eps + (math.pi - 2 * eps) * i / (nu - 1)
        rings.append([eye_param(u, v, rad) for (v, rad) in loop])
    cap = lambda ring: sum(ring, Vector()) / len(ring)  # noqa: E731
    mb = MB()
    lash = M["LidLine"]
    mb.rings(rings, [M["PlayerPrimary"]] * (nu - 1), cap(rings[0]), cap(rings[-1]),
             mat_fn=lambda i, j: lash if 8 <= j <= 12 else None)
    lid = make_object("LidL" if side > 0 else "LidR", mb, centre, sharp_deg=80.0)
    return eye, pupil, lid


def mouth_outline(al):
    """Open 'D' smile: shallow smiling top edge, deep round bottom; centred on its bounding box."""
    w, ht, hb, lift = 0.064, 0.008, 0.041, 0.017
    s = w * math.cos(al)
    sn = math.sin(al)
    t = (ht if sn >= 0 else hb) * sn + lift * math.cos(al) ** 2
    return s, t + 0.0125


def build_mouth(M):
    origin, _ = body_host(0.0, MOUTH_Y)
    mb = MB()
    ins, prim = M["MouthInterior"], M["PlayerPrimary"]
    decal(mb, body_host, (0.0, MOUTH_Y), mouth_outline, [
        (0.0, 0.0, 0.0010, ins), (0.5, 0.0, 0.0010, ins), (1.0, -0.010, 0.0013, ins),
        (1.0, -0.0055, 0.0028, ins), (1.0, -0.0025, 0.0047, prim), (1.0, 0.0008, 0.0056, prim),
        (1.0, 0.0045, 0.0040, prim), (1.0, 0.0080, 0.0008, prim), (1.0, 0.0095, -0.0045, prim),
        (0.0, 0.0, -0.0090, prim)], origin=origin, segs=22)
    tongue = M["Tongue"]
    decal(mb, body_host, (0.004, MOUTH_Y - 0.016), ellipse(0.024, 0.0125), [
        (0.0, 0.0, 0.0044, tongue), (0.6, 0.0, 0.0041, tongue), (0.9, 0.0, 0.0030, tongue),
        (1.0, 0.0, 0.0010, tongue), (0.0, 0.0, 0.0005, tongue)], origin=origin, segs=16)
    teeth = M["Teeth"]

    def tooth(al):
        c, s = math.cos(al), math.sin(al)
        f = lambda x: math.copysign(abs(x) ** 0.5, x)  # noqa: E731  (superellipse, p=4)
        return 0.0046 * f(c), 0.0052 * f(s)

    for side in (-1, 1):
        decal(mb, body_host, (side * 0.0058, MOUTH_Y + 0.0105), tooth, [
            (0.0, 0.0, 0.0040, teeth), (0.7, 0.0, 0.0038, teeth), (1.0, 0.0, 0.0026, teeth),
            (1.0, 0.0, 0.0006, teeth), (0.0, 0.0, 0.0006, teeth)], origin=origin, segs=8)
    return make_object("Mouth", mb, origin)


def build_cheek(M, side):
    origin, _ = body_host(side * CHEEK_S, CHEEK_Y)
    mb = MB()
    c = M["CheekBlush"]
    decal(mb, body_host, (side * CHEEK_S, CHEEK_Y), ellipse(0.048, 0.029), [
        (0.0, 0.0, 0.0030, c), (0.5, 0.0, 0.0028, c), (0.82, 0.0, 0.0021, c),
        (1.0, 0.0, 0.0010, c), (0.0, 0.0, -0.004, c)], origin=origin, segs=18)
    return make_object("CheekL" if side > 0 else "CheekR", mb, origin)


def build_hand(M, side):
    """Mitten with a thumb, fingers hanging down, palm toward the body, thumb forward."""
    sec = M["PlayerSecondary"]
    mb = MB()
    length, thick, width = 0.080, 0.040, 0.064

    def mitten_deform(p, u):
        f = 1.0 + 0.16 * max(0.0, -u.y)                   # fuller toward the fingertips
        p = Vector((p.x * (0.92 + 0.08 * f), p.y, p.z * f))
        p.x -= 0.024 * max(0.0, -u.y) ** 2                # fingertips curl toward the palm (-x)
        p.x += 0.007 * u.x * (1 - abs(u.y))               # puffy back of the hand
        return p

    # Palm turned toward the body and a little forward, fingertips flared out, thumb forward-out.
    tilt = (Matrix.Rotation(math.radians(38.0), 3, "Y") @ Matrix.Rotation(math.radians(16.0), 3, "Z")
            @ Matrix.Rotation(math.radians(-10.0), 3, "X"))
    ellipsoid(mb, (0, 0, 0), (thick, length, width), sec, n=14, rings=8, deform=mitten_deform, xform=tilt)
    thumb_rot = tilt @ Matrix.Rotation(math.radians(-55.0), 3, "X") @ Matrix.Rotation(math.radians(-12.0), 3, "Z")
    ellipsoid(mb, tilt @ Vector((-0.005, 0.010, 0.056)), (0.019, 0.034, 0.021), sec, n=10, rings=6,
              xform=thumb_rot)
    if side < 0:
        mirror_x(mb)
    pos = (side * HAND_POS[0], HAND_POS[1], HAND_POS[2])
    return make_object("HandL" if side > 0 else "HandR", mb, pos)


def build_foot(M, side):
    """Rounded shoe (secondary colour) on a darker sole; toes point forward and a little out."""
    sec, sole = M["PlayerSecondary"], M["ShoeSole"]
    a, b, c = 0.073, 0.050, 0.116          # upper half-width, half-height, half-length
    y_bottom = -FOOT_POS[1]                # ground, in foot-local space
    sole_top = y_bottom + 0.021
    pe = 2.6                               # superellipse exponent: rounded-boxy

    def se(x):
        return math.copysign(abs(x) ** (2.0 / pe), x)

    def toe(z):
        return 1.0 + 0.10 * (z / c)

    mb = MB()

    def upper_deform(p, u):
        q = Vector((a * se(u.x), b * se(u.y), c * se(u.z)))
        k = toe(q.z)
        q.x *= k
        q.y = q.y * (0.9 + 0.1 * k) + 0.008
        q.y -= 0.012 * max(0.0, q.z / c) ** 2 * max(0.0, u.y)   # toe box slopes down to the front
        floor = sole_top - 0.004
        if q.y < floor + 0.012:
            q.y = floor + 0.012 + (q.y - floor - 0.012) * 0.25
        return q

    ellipsoid(mb, (0, 0, 0), (1, 1, 1), sec, n=16, rings=9, deform=upper_deform)

    # Sole: slab following the shoe's footprint, a few mm proud all round.
    segs = 20

    def outline(al, grow):
        cx, sz = math.cos(al), math.sin(al)
        z = (c + grow) * se(sz)
        x = (a + grow) * se(cx) * toe(z)
        return x, z

    ys = [(0.0, sole_top), (0.97, sole_top), (1.0, (sole_top + y_bottom) / 2), (0.97, y_bottom), (0.0, y_bottom)]
    rings = []
    for rho, y in ys[1:-1]:
        ring = []
        for j in range(segs):
            x, z = outline(TAU * j / segs, 0.007)
            ring.append(Vector((x * rho, y, z * rho + 0.002)))
        rings.append(ring)
    mb.rings(rings, [sole] * 2, (0.0, sole_top, 0.002), (0.0, y_bottom, 0.002))

    yaw = Matrix.Rotation(math.radians(10.0), 3, "Y")
    for p in mb.v:
        p.xyz = yaw @ p
    if side < 0:
        mirror_x(mb)
    pos = (side * FOOT_POS[0], FOOT_POS[1], FOOT_POS[2])
    return make_object("FootL" if side > 0 else "FootR", mb, pos, sharp_deg=55.0)


# ---------------------------------------------------------------- main
def tri_count(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def main():
    artlib.reset_scene()
    M = build_materials()
    objs = [build_body(M)]
    for side in (1, -1):
        objs.extend(build_eye(M, side))
    objs.append(build_mouth(M))
    for side in (1, -1):
        objs.append(build_cheek(M, side))
    for side in (1, -1):
        objs.append(build_hand(M, side))
    for side in (1, -1):
        objs.append(build_foot(M, side))
    for name, pos in SOCKETS.items():
        artlib.empty(name, artlib.from_godot(pos))

    total = 0
    for o in objs:
        t = tri_count(o)
        total += t
        x, y, z = o.location
        print(f"PART {o.name:8s} origin(godot)=({x:+.4f}, {z:+.4f}, {-y:+.4f}) tris={t} mats={[m.name for m in o.data.materials]}")
    print(f"TOTAL_TRIS {total}")
    # Keep-out checks: nothing but the Body above y=0.80 (hats), hands clear of the neck ring.
    for o in objs[1:]:
        ys = [(o.matrix_world @ v.co).z for v in o.data.vertices]
        if max(ys) > 0.80:
            raise RuntimeError(f"{o.name} reaches y={max(ys):.3f}, above the hat zone limit 0.80")
    lid_top = EYE_Y + EYE_B + LID_OUT  # the lid shell stays at this radius while it rotates
    print(f"LID_MAX_Y {lid_top:.4f} (any rotation)")
    if lid_top > 0.80:
        raise RuntimeError("lid can reach above y=0.80")
    body = bpy.data.objects["Body"]
    zs = [v.co.z for v in body.data.vertices]
    ring40 = [math.hypot(v.co.x, v.co.y) for v in body.data.vertices if abs(v.co.z - 0.40) < 1e-6]
    print(f"BODY height={max(zs):.4f} min={min(zs):.4f} r@0.40={max(ring40):.4f} "
          f"eye_centre_z={EYE_Z:.4f} eye_front_z={EYE_Z + EYE_B:.4f}")
    artlib.export_glb("blob", family="character")


main()
