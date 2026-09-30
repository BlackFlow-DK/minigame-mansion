"""Shared geometry helpers for the face / neck / back wearables (art/scripts/cosmetics/wearables_*.py).

Everything is authored in GODOT WORLD SPACE (x right, y up, +z = the character's front), in metres, against
a stand-in of the blob body described in docs/contract.md (head sphere r=0.38 at y=0.62, body sphere r=0.40
at y=0.40). A Part collects vertices in those world coordinates; build() subtracts the item's socket, converts
to Blender (x, -z, y) and writes one object. The item is therefore exported with its origin at its socket.

Not for direct use in Blender GUI: run the wearables_face/neck/back.py scripts through tools/blender-run.ps1.
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import bmesh  # noqa: E402
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import artlib  # noqa: E402

# ---------------------------------------------------------------- palette
PAL = dict(
    wood="#8a5a3c", plum="#6d4a7c", teal="#2fa7a0", cream="#f3e6c8", gold="#e8b33a",
    red="#d9483b", green="#58b368", blue="#3f7fd9", pink="#f08fb0", charcoal="#2e2a33",
    white="#fafafa",
    # small derived shades (darker/lighter variants of the palette)
    darkred="#a83a30", darkgreen="#3b8a4a", darkteal="#237f7a", orange="#f28c38", lens="#231f2b",
)


def mat(name, color, rough=0.65):
    return artlib.material(name, PAL.get(color, color), roughness=rough)


# ---------------------------------------------------------------- the stand-in blob (Godot space)
HEAD_C = Vector((0.0, 0.62, 0.0))
HEAD_R = 0.38
BODY_C = Vector((0.0, 0.40, 0.0))
BODY_R = 0.40
SPHERES = ((HEAD_C, HEAD_R), (BODY_C, BODY_R))


def _dominant(y):
    """(centre, radius, horizontal radius) of the sphere that is widest at height y."""
    best = None
    for c, r in SPHERES:
        d = r * r - (y - c.y) ** 2
        if d > 0:
            R = math.sqrt(d)
            if best is None or R > best[2]:
                best = (c, r, R)
    return best


def blob_r(y):
    """Horizontal radius of the blob at height y (0 outside)."""
    b = _dominant(y)
    return b[2] if b else 0.0


def blob_surface(phi, y, off=0.0):
    """Point on the blob at angle phi (0 = front, +x side positive, pi = back) and height y, pushed `off` along the normal."""
    c, r, R = _dominant(y)
    base = Vector((R * math.sin(phi), y, R * math.cos(phi)))
    n = (base - c).normalized()
    return base + n * off


def blob_xy(x, y, front=True, off=0.0):
    """Point on the front (or back) of the blob above world (x, y), pushed `off` along the normal."""
    R = blob_r(y)
    s = max(-0.999, min(0.999, x / R)) if R > 1e-6 else 0.0
    a = math.asin(s)
    return blob_surface(a if front else math.pi - a, y, off)


def blob_ring(phi, y, roff=0.0):
    """Point at angle phi, height y, pushed `roff` HORIZONTALLY outward from the blob (for flared cloth)."""
    R = blob_r(y) + roff
    return Vector((R * math.sin(phi), y, R * math.cos(phi)))


def blob_normal(p):
    """Outward normal of the blob nearest to world point p (dominant sphere at p's height)."""
    c, _r, _R = _dominant(min(max(p.y, 0.02), 0.98))
    return (p - c).normalized()


def blob_sdf(p):
    return min((p - c).length - r for c, r in SPHERES)


# ---------------------------------------------------------------- small math helpers
def V(*a):
    return Vector(a[0] if len(a) == 1 else a)


def rx(deg):
    return Matrix.Rotation(math.radians(deg), 3, "X")


def ry(deg):
    return Matrix.Rotation(math.radians(deg), 3, "Y")


def rz(deg):
    return Matrix.Rotation(math.radians(deg), 3, "Z")


def basis_from_y(direction):
    """Rotation matrix taking +Y to `direction` (used to orient lathes/ellipsoids along an axis)."""
    d = Vector(direction).normalized()
    return Vector((0, 1, 0)).rotation_difference(d).to_matrix()


def catmull(points, per_seg=4, closed=False):
    """Catmull-Rom spline through Vector points."""
    p = [Vector(q) for q in points]
    n = len(p)
    out = []
    segs = n if closed else n - 1
    for i in range(segs):
        p0 = p[(i - 1) % n] if (closed or i > 0) else p[0] * 2 - p[1]
        p1 = p[i]
        p2 = p[(i + 1) % n]
        p3 = p[(i + 2) % n] if (closed or i + 2 < n) else p[-1] * 2 - p[-2]
        for k in range(per_seg):
            t = k / per_seg
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    if not closed:
        out.append(p[-1])
    return out


def star_poly(cx, cy, R, r, points=5, rot_deg=90.0):
    out = []
    for i in range(points * 2):
        a = math.radians(rot_deg) + math.pi * i / points
        rad = R if i % 2 == 0 else r
        out.append((cx + rad * math.cos(a), cy + rad * math.sin(a)))
    return out


def circle_poly(cx, cy, rad, n=16):
    return [(cx + rad * math.cos(2 * math.pi * i / n), cy + rad * math.sin(2 * math.pi * i / n)) for i in range(n)]


# ---------------------------------------------------------------- Part
class Part:
    """One exported mesh object built from world-space (Godot) geometry."""

    def __init__(self, name, socket, mats, smooth=True, sharp=50.0, closed=True, origin=None,
                 solidify=None, bevel=None, outward=None):
        self.name = name
        self.socket = Vector(socket)
        self.origin = Vector(origin) if origin is not None else self.socket
        self.mats = [mat(*m) if isinstance(m, tuple) else m for m in mats]
        self.smooth = smooth
        self.sharp = sharp
        self.closed = closed
        self.solidify = solidify            # thickness (centred on the sheet), or None
        self.bevel = bevel                  # (width, segments) or None
        self.outward = Vector(outward) if outward is not None else None  # flip faces to point away from this point
        self.v = []
        self.f = []
        self.obj = None

    # --- raw
    def vert(self, p):
        self.v.append(Vector(p))
        return len(self.v) - 1

    def face(self, idxs, m=0):
        self.f.append((tuple(idxs), m))

    # --- sheets
    def sheet(self, rows, closed_u=False, closed_v=False, m=0, mat_fn=None):
        """rows[j][i] are points; u runs along i, v along j. mat_fn(j, i) -> material index of the quad."""
        idx = [[self.vert(p) for p in row] for row in rows]
        nj, ni = len(idx), len(idx[0])
        for j in range(nj if closed_v else nj - 1):
            j2 = (j + 1) % nj
            for i in range(ni if closed_u else ni - 1):
                i2 = (i + 1) % ni
                mm = mat_fn(j, i) if mat_fn else m
                self.face((idx[j][i], idx[j][i2], idx[j2][i2], idx[j2][i]), mm)
        return idx

    def grid(self, fn, nu, nv, closed_u=False, closed_v=False, m=0, mat_fn=None):
        cu = nu if closed_u else nu + 1
        cv = nv if closed_v else nv + 1
        rows = [[fn(i / nu, j / nv) for i in range(cu)] for j in range(cv)]
        return self.sheet(rows, closed_u, closed_v, m, mat_fn)

    def cap(self, cx, cy, ax, ay, height, off0, front=True, power=0.5, seg=20, rings=4, m=0):
        """A dome of footprint ellipse (ax, ay) around world (cx, cy) hugging the blob front/back; rim at offset off0, apex off0+height."""
        rows = []
        for j in range(rings + 1):
            rho = 1.0 - j / rings
            off = off0 + height * (1.0 - rho * rho) ** power
            rows.append([blob_xy(cx + ax * rho * math.cos(2 * math.pi * i / seg), cy + ay * rho * math.sin(2 * math.pi * i / seg), front, off) for i in range(seg)])
        self.sheet(rows, closed_u=True, m=m)

    def ellipsoid(self, center, radii, seg=8, rings=4, rot=None, m=0):
        c = Vector(center)
        R = rot if rot is not None else Matrix.Identity(3)
        rows = []
        for j in range(rings + 1):
            ph = math.pi * j / rings
            row = []
            for i in range(seg):
                th = 2 * math.pi * i / seg
                p = Vector((radii[0] * math.sin(ph) * math.cos(th), radii[1] * math.cos(ph), radii[2] * math.sin(ph) * math.sin(th)))
                row.append(c + R @ p)
            rows.append(row)
        self.sheet(rows, closed_u=True, m=m)

    def lathe(self, profile, center, axis=(0, 1, 0), sides=12, m=0, mat_fn=None):
        """Revolve profile [(radius, height), ...] about `axis` through `center`. mat_fn(j) = material of profile segment j."""
        R = basis_from_y(axis)
        c = Vector(center)
        rows = []
        for rad, h in profile:
            row = []
            for i in range(sides):
                th = 2 * math.pi * i / sides
                row.append(c + R @ Vector((rad * math.cos(th), h, rad * math.sin(th))))
            rows.append(row)
        self.sheet(rows, closed_u=True, m=m, mat_fn=(lambda j, i: mat_fn(j)) if mat_fn else None)

    def tube(self, pts, r, sides=6, closed=False, m=0, mat_fn=None, cap=True, up=(0, 1, 0)):
        """Sweep a (possibly elliptical) section along a polyline. r: float, or fn(t) -> float | (a, b) (a along N, b along B)."""
        pts = [Vector(p) for p in pts]
        n = len(pts)
        T = []
        for i in range(n):
            d = (pts[(i + 1) % n] - pts[(i - 1) % n]) if closed else (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)])
            T.append(d.normalized())
        nv = Vector(up) - T[0] * Vector(up).dot(T[0])
        if nv.length < 1e-6:
            nv = Vector((1, 0, 0)) - T[0] * T[0].x
        nv.normalize()
        frames = []
        for i in range(n):
            if i > 0:
                nv = nv - T[i] * nv.dot(T[i])
                if nv.length < 1e-6:
                    nv = T[i].orthogonal()
                nv.normalize()
            frames.append((nv.copy(), T[i].cross(nv)))

        def rad(i):
            t = i / (n if closed else max(1, n - 1))
            v = r(t) if callable(r) else r
            return (v, v) if not isinstance(v, (tuple, list)) else v

        rows = []
        for i in range(n):
            Nn, Bb = frames[i]
            a, b = rad(i)
            rows.append([pts[i] + Nn * (math.cos(2 * math.pi * j / sides) * a) + Bb * (math.sin(2 * math.pi * j / sides) * b) for j in range(sides)])
        idx = self.sheet(rows, closed_u=True, closed_v=closed, m=m, mat_fn=(lambda j, i: mat_fn(j)) if mat_fn else None)
        if not closed and cap:
            for k in (0, n - 1):
                a, b = rad(k)
                if a > 1e-6 and b > 1e-6:
                    self.face(idx[k], m)
        return idx

    def prism(self, poly, f_front, f_back, m=0, m_side=None):
        """Extrude a 2D polygon (world x,y) between two mapped surfaces: f_front(x, y) / f_back(x, y) -> Vector."""
        a = [self.vert(f_front(x, y)) for x, y in poly]
        b = [self.vert(f_back(x, y)) for x, y in poly]
        self.face(a, m)
        self.face(list(reversed(b)), m)
        ms = m if m_side is None else m_side
        n = len(poly)
        for i in range(n):
            j = (i + 1) % n
            self.face((a[i], a[j], b[j], b[i]), ms)

    def box(self, center, size, rot=None, m=0):
        c = Vector(center)
        R = rot if rot is not None else Matrix.Identity(3)
        hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
        ids = {}
        for sx in (-1, 1):
            for sy in (-1, 1):
                for sz in (-1, 1):
                    ids[(sx, sy, sz)] = self.vert(c + R @ Vector((sx * hx, sy * hy, sz * hz)))
        q = lambda *k: tuple(ids[x] for x in k)  # noqa: E731
        self.face(q((1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)), m)
        self.face(q((-1, -1, 1), (-1, 1, 1), (-1, 1, -1), (-1, -1, -1)), m)
        self.face(q((-1, 1, -1), (-1, 1, 1), (1, 1, 1), (1, 1, -1)), m)
        self.face(q((-1, -1, 1), (-1, -1, -1), (1, -1, -1), (1, -1, 1)), m)
        self.face(q((-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)), m)
        self.face(q((1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, 1, -1)), m)

    # --- build
    def _orient(self):
        if self.outward is None:
            return
        fixed = []
        for idxs, m in self.f:
            pts = [self.v[i] for i in idxs]
            n = Vector((0, 0, 0))
            for k in range(len(pts)):
                a, b = pts[k], pts[(k + 1) % len(pts)]
                n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)))
            c = sum(pts, Vector()) / len(pts)
            fixed.append((tuple(reversed(idxs)) if n.dot(c - self.outward) < 0 else idxs, m))
        self.f = fixed

    def build(self):
        self._orient()
        to_bl = lambda p: Vector((p.x, -p.z, p.y))  # noqa: E731
        bm = bmesh.new()
        verts = [bm.verts.new(to_bl(p - self.origin)) for p in self.v]
        for idxs, m in self.f:
            if len(set(idxs)) < 3:
                continue
            try:
                fc = bm.faces.new([verts[i] for i in idxs])
            except ValueError:
                continue
            fc.material_index = m
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        big = [f for f in bm.faces if len(f.verts) > 4]
        if big:
            bmesh.ops.triangulate(bm, faces=big, quad_method="BEAUTY", ngon_method="EAR_CLIP")
        mesh = bpy.data.meshes.new(self.name)
        bm.to_mesh(mesh)
        bm.free()
        obj = bpy.data.objects.new(self.name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        obj.location = artlib.from_godot(self.origin - self.socket)
        for m in self.mats:
            mesh.materials.append(m)
        if self.solidify:
            md = obj.modifiers.new("solid", "SOLIDIFY")
            md.thickness = self.solidify
            md.offset = 0.0
            md.use_even_offset = True
            md.use_rim = True
        if self.bevel:
            md = obj.modifiers.new("bevel", "BEVEL")
            md.width = self.bevel[0]
            md.segments = self.bevel[1]
            md.limit_method = "ANGLE"
            md.angle_limit = math.radians(30)
        if obj.modifiers:
            bpy.context.view_layer.update()
            ev = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
            new = bpy.data.meshes.new_from_object(ev)
            old = obj.data
            obj.modifiers.clear()
            obj.data = new
            bpy.data.meshes.remove(old)
            new.name = self.name
            new.materials.clear()
            for m in self.mats:
                new.materials.append(m)
        mesh = obj.data
        bm = bmesh.new()
        bm.from_mesh(mesh)
        if self.closed:
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        lim = math.radians(self.sharp)
        for f in bm.faces:
            f.smooth = self.smooth
        if self.smooth:
            for e in bm.edges:
                if len(e.link_faces) == 2:
                    e.smooth = e.calc_face_angle(0.0) < lim
        bm.to_mesh(mesh)
        bm.free()
        obj.name = self.name
        self.obj = obj
        return obj

    def tris(self):
        return sum(len(p.vertices) - 2 for p in self.obj.data.polygons)

    def world_points(self):
        """Vertices in Godot world space."""
        out = []
        for v in self.obj.data.vertices:
            co = v.co + self.obj.location
            out.append(Vector((co.x, co.z, -co.y)) + self.socket)
        return out


# ---------------------------------------------------------------- export + checks
SLOT_LIMITS = {
    "neck": dict(max_y=0.52),
    "back": dict(max_z=0.02),
}


def export_item(slot, item_id, build_fn, socket):
    """Reset the scene, build parts with build_fn(socket) -> [Part], check the contract, export cosmetics/<slot>_<id>.glb."""
    artlib.reset_scene()
    parts = build_fn(Vector(socket))
    for p in parts:
        p.build()
    tris = sum(p.tris() for p in parts)
    pts = [w for p in parts for w in p.world_points()]
    lo = Vector((min(q.x for q in pts), min(q.y for q in pts), min(q.z for q in pts)))
    hi = Vector((max(q.x for q in pts), max(q.y for q in pts), max(q.z for q in pts)))
    deepest = -min(blob_sdf(q) for q in pts)
    name = f"{slot}_{item_id}"
    print(f"WEARABLE {name}: tris={tris} bbox_world=({lo.x:.2f},{lo.y:.2f},{lo.z:.2f})..({hi.x:.2f},{hi.y:.2f},{hi.z:.2f}) deepest_in_body={deepest:.3f} parts={[p.name for p in parts]}")
    problems = []
    if not 200 <= tris <= 1500:
        problems.append(f"triangle count {tris} outside 200..1500")
    lim = SLOT_LIMITS.get(slot, {})
    if "max_y" in lim and hi.y > lim["max_y"]:
        problems.append(f"top y {hi.y:.3f} > {lim['max_y']} (would cover the mouth)")
    if "max_z" in lim and hi.z > lim["max_z"]:
        problems.append(f"front z {hi.z:.3f} > {lim['max_z']} (pokes to the front)")
    if deepest > 0.06:
        problems.append(f"sinks {deepest:.3f} m into the body")
    if problems:
        raise RuntimeError(f"{name}: " + "; ".join(problems))
    artlib.export_glb(name, family="cosmetics")
    return tris
