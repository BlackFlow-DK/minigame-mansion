"""Geometry helpers for the hat family (Blender 5.2, bmesh only, Z-up).

Hats are authored around the socket: origin = top of the head dome, +Z up, front = -Y.
The head is approximated by a sphere of radius HEAD_R centred at z = HEAD_C.
Everything is built into a Builder (one bmesh + material slots), then turned into an
object with Builder.to_object(). Lathes/sweeps/ellipsoids are all "surf" calls over rings.
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import artlib  # noqa: E402

HEAD_R = 0.38
HEAD_C = -0.38  # dome centre z (socket at 0)
FRONT_LIMIT_Z = -0.20  # nothing in front of the face below this

PAL = {
    "wood": "#8a5a3c", "plum": "#6d4a7c", "teal": "#2fa7a0", "cream": "#f3e6c8",
    "gold": "#e8b33a", "red": "#d9483b", "green": "#58b368", "blue": "#3f7fd9",
    "pink": "#f08fb0", "charcoal": "#2e2a33", "white": "#fafafa",
    # extras needed by specific hats
    "terracotta": "#c8663d", "orange": "#ef7b2c", "steel": "#7d8996", "soil": "#4a3324",
    "darkgreen": "#3c8a4e", "leather": "#5a3a26",
}

_mat_cache = {}


def mat(key, roughness=0.75, metallic=0.0):
    """Palette material by key (cached per scene reset)."""
    k = (key, roughness, metallic)
    m = _mat_cache.get(k)
    if m is None or m.name not in bpy.data.materials:
        name = key if (roughness, metallic) == (0.75, 0.0) else f"{key}_{roughness}_{metallic}"
        m = artlib.material(name, PAL[key], roughness=roughness, metallic=metallic)
        _mat_cache[k] = m
    return m


HATS = {}


def hat(hat_id):
    """Register a hat builder. It returns a Builder, or (Builder, {"Spin": (Builder, hub_location)})."""
    def deco(fn):
        HATS[hat_id] = fn
        return fn
    return deco


def reset():
    artlib.reset_scene()
    _mat_cache.clear()


def dome_z(r):
    """Height of the head surface at horizontal radius r."""
    return HEAD_C + math.sqrt(max(HEAD_R ** 2 - r * r, 0.0))


def dome_r(z):
    """Horizontal radius of the head at height z."""
    dz = z - HEAD_C
    return math.sqrt(max(HEAD_R ** 2 - dz * dz, 0.0))


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def arc(cx, cz, r, a0, a1, n):
    """Profile points (r, z) along a circle arc, angles in degrees (0 = +r direction)."""
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cz + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def ring_pts(fn, segs):
    """Ring of `segs` points; fn(theta) -> Vector."""
    return [fn(2 * math.pi * j / segs) for j in range(segs)]


class Builder:
    def __init__(self):
        self.bm = bmesh.new()
        self.mats = []
        self._faces_mat = {}

    # ---- materials
    def _mi(self, m):
        if m not in self.mats:
            self.mats.append(m)
        return self.mats.index(m)

    # ---- core: surfaces over rings
    def surf(self, rings, m, xf=None, periodic=True):
        """rings: list of rings. A ring is a list of Vectors (all full rings the same length,
        closed loop) or a single Vector (pole). Consecutive rings are stitched with quads
        (triangles at poles). `m` is a material or callable (i, j) -> material, where i is the
        ring interval and j the segment. Closed solids are auto-oriented outward.
        Returns the list of faces."""
        bm = self.bm
        vr = []
        for ring in rings:
            if isinstance(ring, Vector):
                p = xf @ ring if xf is not None else ring
                vr.append(bm.verts.new(p))
            else:
                vr.append([bm.verts.new(xf @ p if xf is not None else p) for p in ring])
        faces = []
        for i in range(len(vr) - 1):
            a, b = vr[i], vr[i + 1]
            a_pole = not isinstance(a, list)
            b_pole = not isinstance(b, list)
            if a_pole and b_pole:
                continue
            n = len(b) if a_pole else len(a)
            for j in range(n):
                j2 = (j + 1) % n
                if a_pole:
                    vs = [a, b[j2], b[j]]
                elif b_pole:
                    vs = [a[j], a[j2], b]
                else:
                    vs = [a[j], a[j2], b[j2], b[j]]
                if len(set(vs)) < 3:
                    continue
                try:
                    f = bm.faces.new(vs)
                except ValueError:
                    continue
                mm = m(i, j) if callable(m) else m
                f.material_index = self._mi(mm)
                faces.append(f)
        # orient outward using signed volume
        vol = 0.0
        for f in faces:
            v = [x.co for x in f.verts]
            for k in range(1, len(v) - 1):
                vol += v[0].dot(v[k].cross(v[k + 1])) / 6.0
        if vol < 0:
            for f in faces:
                f.normal_flip()
        return faces

    def lathe(self, profile, m, segs=28, xf=None, center=(0.0, 0.0), ring_fn=None):
        """Revolve profile [(r, z), ...] (bottom to top) around Z. Open ends are capped to the axis.
        ring_fn(theta, r, z) -> Vector allows non-circular / modulated rings."""
        prof = list(profile)
        closed = abs(prof[0][0] - prof[-1][0]) < 1e-9 and abs(prof[0][1] - prof[-1][1]) < 1e-9 and len(prof) > 3
        if not closed:  # cap open ends onto the axis
            if prof[0][0] > 1e-6:
                prof.insert(0, (0.0, prof[0][1]))
            if prof[-1][0] > 1e-6:
                prof.append((0.0, prof[-1][1]))
        rings = []
        for r, z in prof:
            if r <= 1e-6:
                rings.append(Vector((center[0], center[1], z)))
            else:
                if ring_fn:
                    rings.append([ring_fn(2 * math.pi * j / segs, r, z) for j in range(segs)])
                else:
                    rings.append([Vector((center[0] + r * math.cos(2 * math.pi * j / segs),
                                          center[1] + r * math.sin(2 * math.pi * j / segs), z))
                                  for j in range(segs)])
        return self.surf(rings, m, xf)

    def ellipsoid(self, center, radii, m, segs=10, lats=6, xf=None):
        """Ellipsoid at `center` (Vector/tuple), radii (rx, ry, rz)."""
        c = Vector(center)
        rx, ry, rz = radii
        rings = [Vector((c.x, c.y, c.z - rz))]
        for i in range(1, lats):
            a = -math.pi / 2 + math.pi * i / lats
            rr, zz = math.cos(a), math.sin(a)
            rings.append([Vector((c.x + rx * rr * math.cos(2 * math.pi * j / segs),
                                  c.y + ry * rr * math.sin(2 * math.pi * j / segs),
                                  c.z + rz * zz)) for j in range(segs)])
        rings.append(Vector((c.x, c.y, c.z + rz)))
        return self.surf(rings, m, xf)

    def prism(self, outline, z0, z1, m, chamfer=0.0, xf=None, top_m=None):
        """Extruded convex/star-shaped polygon `outline` [(x, y)...] from z0 to z1, with the top
        edge chamfered inward by `chamfer` (a small bevel). Fans from the centroid."""
        cx = sum(p[0] for p in outline) / len(outline)
        cy = sum(p[1] for p in outline) / len(outline)

        def scaled(p, s):
            return Vector((cx + (p[0] - cx) * s, cy + (p[1] - cy) * s, 0))

        def at(p, z, s=1.0):
            v = scaled(p, s)
            v.z = z
            return v
        # inset factor from chamfer relative to mean radius
        mr = sum(math.hypot(p[0] - cx, p[1] - cy) for p in outline) / len(outline)
        s = max(0.05, 1.0 - chamfer / mr) if chamfer > 0 else 1.0
        zc = z1 - chamfer
        rings = [Vector((cx, cy, z0)),
                 [at(p, z0) for p in outline],
                 [at(p, zc) for p in outline] if chamfer > 0 else None,
                 [at(p, z1, s) for p in outline],
                 Vector((cx, cy, z1))]
        rings = [r for r in rings if r is not None]
        if top_m is None:
            return self.surf(rings, m, xf)
        last = len(rings) - 2
        return self.surf(rings, lambda i, j: top_m if i >= last else m, xf)

    def sweep(self, path, radii, m, segs=10, cap=True, up=None, xf=None, ring_m=None):
        """Tube along `path` (list of Vector). radii: float or list per point, or (a, b) tuples
        for an elliptical section (a along the side vector, b along the normal). Parallel transport
        frames, rounded end caps."""
        pts = [Vector(p) for p in path]
        n = len(pts)
        if isinstance(radii, (int, float)) or (isinstance(radii, tuple) and len(radii) == 2):
            radii = [radii] * n
        rl = []
        for r in radii:
            rl.append((r, r) if isinstance(r, (int, float)) else tuple(r))
        tans, frames = sweep_frames(pts, up)
        rings = []

        def make_ring(i, scale=1.0, shift=0.0):
            nrm_i, side = frames[i]
            a, b = rl[i]
            c = pts[i] + tans[i] * shift
            return [c + side * (a * scale * math.cos(2 * math.pi * j / segs))
                    + nrm_i * (b * scale * math.sin(2 * math.pi * j / segs)) for j in range(segs)]
        if cap:
            r0 = max(rl[0])
            rings.append(pts[0] - tans[0] * r0 * 0.55)
            rings.append(make_ring(0, 0.75, -r0 * 0.3))
        for i in range(n):
            rings.append(make_ring(i))
        if cap:
            r1 = max(rl[-1])
            rings.append(make_ring(n - 1, 0.75, r1 * 0.3))
            rings.append(pts[-1] + tans[-1] * r1 * 0.55)
        return self.surf(rings, m, xf)

    # ---- output
    def apply(self, fn):
        """Deform every vertex: fn(Vector) -> Vector."""
        for v in self.bm.verts:
            v.co = fn(v.co.copy())

    def tri_count(self):
        return sum(len(f.verts) - 2 for f in self.bm.faces)

    def to_object(self, name, location=(0, 0, 0), sharp_deg=38.0):
        bm = self.bm
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
        bm.normal_update()
        lim = math.radians(sharp_deg)
        for e in bm.edges:
            e.smooth = True
        for f in bm.faces:
            f.smooth = True
        for e in bm.edges:
            if len(e.link_faces) != 2:
                continue
            if e.calc_face_angle(0.0) > lim:
                e.smooth = False
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        for m in self.mats:
            me.materials.append(m)
        obj = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(obj)
        obj.location = location
        return obj


def check_fit(obj, name):
    """Print fit diagnostics for a hat object (world-space vertex checks)."""
    worst_front = 9.0
    deepest = 9.0
    for v in obj.data.vertices:
        p = obj.matrix_world @ v.co
        d = (p - Vector((0, 0, HEAD_C))).length
        deepest = min(deepest, d)
        # front zone (Godot +Z is Blender -Y)
        if p.y < -0.12 and abs(p.x) < 0.25 and p.z < worst_front:
            worst_front = p.z
    msg = f"  fit {name}: lowest front z={worst_front:.3f} (limit {FRONT_LIMIT_Z}), deepest vertex {deepest:.3f} from head centre (head R {HEAD_R})"
    print(msg)
    if worst_front < FRONT_LIMIT_Z - 1e-4:
        print(f"  WARNING {name}: covers the face (front z {worst_front:.3f} < {FRONT_LIMIT_Z})")


def sweep_frames(pts, up=None):
    """Tangents and (normal, side) frames along a path (parallel transport). A section point at
    angle phi is  c + r*(cos(phi)*side + sin(phi)*normal)  (same convention as Builder.sweep)."""
    n = len(pts)
    tans = []
    for i in range(n):
        a = pts[max(i - 1, 0)]
        b = pts[min(i + 1, n - 1)]
        tans.append((b - a).normalized())
    ref = Vector(up) if up is not None else (Vector((0, 0, 1)) if abs(tans[0].z) < 0.9 else Vector((1, 0, 0)))
    nrm = (ref - tans[0] * ref.dot(tans[0])).normalized()
    frames = []
    for i in range(n):
        t = tans[i]
        nrm = nrm - t * nrm.dot(t)
        nrm.normalize()
        side = t.cross(nrm).normalized()
        frames.append((nrm.copy(), side))
    return tans, frames


def basis_xf(origin, x_axis, y_axis, z_axis):
    """4x4 matrix with the given local axes (columns) and origin."""
    m = Matrix((x_axis, y_axis, z_axis)).transposed().to_4x4()
    m.translation = Vector(origin)
    return m


def star_outline(r_out, r_in, n=5, rot_deg=90.0):
    pts = []
    for k in range(n * 2):
        r = r_out if k % 2 == 0 else r_in
        a = math.radians(rot_deg) + math.pi * k / n
        pts.append((r * math.cos(a), r * math.sin(a)))
    return pts


def rect_outline(w, h, rx=0.0):
    """Rounded rectangle outline (w x h) centred at origin, corner radius rx."""
    if rx <= 0:
        return [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
    pts = []
    for cx, cy, a0 in ((w / 2 - rx, h / 2 - rx, 0), (-w / 2 + rx, h / 2 - rx, 90),
                       (-w / 2 + rx, -h / 2 + rx, 180), (w / 2 - rx, -h / 2 + rx, 270)):
        for k in range(4):
            a = math.radians(a0 + 90 * k / 3)
            pts.append((cx + rx * math.cos(a), cy + rx * math.sin(a)))
    return pts


def bend_path(p0, direction, length, bend_deg, n=12, axis=(0, 1, 0), power=1.0):
    """Path from p0 heading `direction`; the heading rotates about `axis` by bend_deg*t**power
    (t = 0..1 along the length). Returns n+1 points."""
    d0 = Vector(direction).normalized()
    ax = Vector(axis)
    pts = [Vector(p0)]
    cur = Vector(p0)
    step = length / n
    for i in range(n):
        t = (i + 0.5) / n
        d = Matrix.Rotation(math.radians(bend_deg) * (t ** power), 3, ax) @ d0
        cur = cur + d * step
        pts.append(cur.copy())
    return pts
