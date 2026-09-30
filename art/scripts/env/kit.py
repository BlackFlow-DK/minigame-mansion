"""Mansion kit helpers: palette + a bmesh mesh builder (many primitives -> ONE mesh, per-face materials).

Coordinates are Blender space (Z up, model front = -Y, which is Godot +Z). Every piece is built around
the world origin with its base at z=0, then exported through artlib.export_glb(name, family="env").
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import artlib  # noqa: E402

# name: (hex, roughness, metallic, emissive)
PALETTE = {
    "Wood": ("#8a5a3c", 0.75, 0.0, False),
    "DarkWood": ("#5b3a29", 0.7, 0.0, False),
    "Wallpaper": ("#6d4a7c", 0.9, 0.0, False),
    "WallpaperStripe": ("#7d5a8d", 0.9, 0.0, False),
    "Teal": ("#2fa7a0", 0.6, 0.0, False),
    "Cream": ("#f3e6c8", 0.8, 0.0, False),
    "Gold": ("#e8b33a", 0.35, 0.6, False),
    "Red": ("#d9483b", 0.7, 0.0, False),
    "Green": ("#58b368", 0.75, 0.0, False),
    "Charcoal": ("#2e2a33", 0.5, 0.0, False),
    "Steel": ("#a9b2bd", 0.4, 0.5, False),
    "Parquet": ("#c39a6c", 0.6, 0.0, False),
    "ParquetDark": ("#9a6c46", 0.6, 0.0, False),
    "EmitMoon": ("#bcd7ff", 0.3, 0.0, True),
    "EmitFire": ("#ff8a2a", 0.5, 0.0, True),
    "EmitCandle": ("#ffd27a", 0.5, 0.0, True),
    "EmitPortal": ("#7ff5e6", 0.4, 0.0, True),
    "EmitPortalDeep": ("#2fa7a0", 0.4, 0.0, True),
}


def get_material(name):
    hex_, rough, metal, emit = PALETTE[name]
    mat = artlib.material(name, hex_, roughness=rough, metallic=metal)
    if emit:
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Emission Color"].default_value = mat.diffuse_color
        bsdf.inputs["Emission Strength"].default_value = 1.0
    return mat


def arch_pts(cx, zs, r, n=14):
    """Semicircle from the left end over the top to the right end (a=180..0 deg), spring line at zs."""
    return [(cx + r * math.cos(math.pi * (1 - i / n)), zs + r * math.sin(math.pi * (1 - i / n))) for i in range(n + 1)]


def ellipse_pts(cx, cz, rx, rz, n=20):
    return [(cx + rx * math.cos(2 * math.pi * i / n), cz + rz * math.sin(2 * math.pi * i / n)) for i in range(n)]


def star_pts(cx, cz, r_out, r_in, points=5, rot=90.0):
    pts = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(rot) + math.pi * i / points
        pts.append((cx + r * math.cos(a), cz + r * math.sin(a)))
    return pts


class Kit:
    def __init__(self):
        self.bm = bmesh.new()
        self.mats = []

    def _mi(self, name):
        if name not in self.mats:
            self.mats.append(name)
        return self.mats.index(name)

    def _merge(self, tb, mat, smooth_faces=(), matrix=None, flip_check=True):
        if matrix is not None:
            bmesh.ops.transform(tb, matrix=matrix, verts=tb.verts)
        bmesh.ops.recalc_face_normals(tb, faces=tb.faces)
        tb.faces.index_update()
        sm = {f.index for f in smooth_faces} if not isinstance(smooth_faces, (set, frozenset)) else smooth_faces
        mi = self._mi(mat)
        vmap = {v: self.bm.verts.new(v.co) for v in tb.verts}
        for f in tb.faces:
            nf = self.bm.faces.new([vmap[v] for v in f.verts])
            nf.material_index = mi
            nf.smooth = f.index in sm
        tb.free()

    @staticmethod
    def _xf(loc=(0, 0, 0), rot=None, scale=None):
        m = Matrix.Translation(loc)
        if rot is not None:
            m = m @ Matrix.Rotation(math.radians(rot[2]), 4, "Z") @ Matrix.Rotation(math.radians(rot[1]), 4, "Y") @ Matrix.Rotation(math.radians(rot[0]), 4, "X")
        if scale is not None:
            m = m @ Matrix.Diagonal((*scale, 1.0))
        return m

    # ---- primitives -------------------------------------------------------------------------
    def boxc(self, center, size, mat, bevel=0.0, seg=1, rot=None):
        """Box by centre + size; optional bevel (bevel strips smooth, big faces flat)."""
        tb = bmesh.new()
        bmesh.ops.create_cube(tb, size=1.0, matrix=Matrix.Diagonal((*size, 1.0)))
        smooth = set()
        if bevel > 0:
            b = min(bevel, min(size) * 0.45)
            res = bmesh.ops.bevel(tb, geom=tb.edges[:], offset=b, offset_type="OFFSET", segments=seg,
                                  profile=0.5, affect="EDGES", clamp_overlap=True)
            tb.faces.index_update()
            smooth = {f.index for f in res["faces"] if f.is_valid}
        self._merge(tb, mat, smooth, self._xf(center, rot))

    def box(self, x0, x1, y0, y1, z0, z1, mat, bevel=0.0, seg=1, rot=None):
        """Box by ranges (order-insensitive)."""
        xa, xb = sorted((x0, x1))
        ya, yb = sorted((y0, y1))
        za, zb = sorted((z0, z1))
        self.boxc(((xa + xb) / 2, (ya + yb) / 2, (za + zb) / 2), (xb - xa, yb - ya, zb - za), mat, bevel, seg, rot)

    def lathe(self, profile, center, mat, seg=20, rot=None, scale=None):
        """Surface of revolution about local Z. profile = [(r, z[, smooth])...] bottom to top; r>0 end points get
        flat caps, r==0 end points are apexes. `smooth` (default True) is for the segment ending at that point."""
        tb = bmesh.new()
        rings = []
        for (r, z, *_s) in profile:
            if r <= 1e-6:
                rings.append([tb.verts.new((0, 0, z))])
            else:
                rings.append([tb.verts.new((r * math.cos(2 * math.pi * i / seg), r * math.sin(2 * math.pi * i / seg), z))
                              for i in range(seg)])
        smooth = set()
        made = []
        for k in range(1, len(rings)):
            a, b = rings[k - 1], rings[k]
            sflag = profile[k][2] if len(profile[k]) > 2 else True
            for i in range(seg):
                j = (i + 1) % seg
                if len(a) == 1 and len(b) == 1:
                    continue
                if len(a) == 1:
                    f = tb.faces.new([a[0], b[j], b[i]])
                elif len(b) == 1:
                    f = tb.faces.new([a[i], a[j], b[0]])
                else:
                    f = tb.faces.new([a[i], a[j], b[j], b[i]])
                made.append((f, sflag))
        for ring in (rings[0], rings[-1]):
            if len(ring) > 2:
                tb.faces.new(ring)
        tb.faces.index_update()
        smooth = {f.index for f, s in made if s}
        self._merge(tb, mat, smooth, self._xf(center, rot, scale))

    def cyl(self, center, r, h, mat, seg=16, r2=None, axis="z", smooth=True):
        """Cylinder/cone frustum of height h centred at `center`; axis 'x','y' or 'z'."""
        top = r if r2 is None else r2
        prof = [(r, -h / 2, True), (top, h / 2, smooth)]
        rot = {"z": None, "x": (0, 90, 0), "y": (-90, 0, 0)}[axis]
        self.lathe(prof, center, mat, seg=seg, rot=rot)

    def sph(self, center, radii, mat, seg=12, rings=8, rot=None):
        rx, ry, rz = (radii, radii, radii) if isinstance(radii, (int, float)) else radii
        prof = [(0.0, -1.0)]
        for k in range(1, rings):
            a = -math.pi / 2 + math.pi * k / rings
            prof.append((math.cos(a), math.sin(a)))
        prof.append((0.0, 1.0))
        self.lathe(prof, center, mat, seg=seg, rot=rot, scale=(rx, ry, rz))

    def torus(self, center, R, r, mat, seg=20, rseg=8, rot=None):
        tb = bmesh.new()
        ring = []
        for i in range(seg):
            a = 2 * math.pi * i / seg
            row = []
            for j in range(rseg):
                b = 2 * math.pi * j / rseg
                rr = R + r * math.cos(b)
                row.append(tb.verts.new((rr * math.cos(a), rr * math.sin(a), r * math.sin(b))))
            ring.append(row)
        for i in range(seg):
            for j in range(rseg):
                i2, j2 = (i + 1) % seg, (j + 1) % rseg
                tb.faces.new([ring[i][j], ring[i2][j], ring[i2][j2], ring[i][j2]])
        tb.faces.index_update()
        self._merge(tb, mat, {f.index for f in tb.faces}, self._xf(center, rot))

    def poly(self, pts, plane, a0, a1, mat, bevel=0.0, seg=1):
        """Extrude a 2D polygon. plane 'xz' -> along Y between a0..a1; 'yz' -> along X; 'xy' -> along Z."""
        tb = bmesh.new()

        def p3(p, a):
            u, v = p
            return {"xz": (u, a, v), "yz": (a, u, v), "xy": (u, v, a)}[plane]

        lo = [tb.verts.new(p3(p, min(a0, a1))) for p in pts]
        hi = [tb.verts.new(p3(p, max(a0, a1))) for p in pts]
        n = len(pts)
        tb.faces.new(lo)
        tb.faces.new(hi)
        for i in range(n):
            j = (i + 1) % n
            tb.faces.new([lo[i], lo[j], hi[j], hi[i]])
        smooth = set()
        if bevel > 0:
            res = bmesh.ops.bevel(tb, geom=tb.edges[:], offset=bevel, offset_type="OFFSET", segments=seg,
                                  profile=0.5, affect="EDGES", clamp_overlap=True)
            tb.faces.index_update()
            smooth = {f.index for f in res["faces"] if f.is_valid}
        self._merge(tb, mat, smooth)

    def ring(self, outer, inner, plane, a0, a1, mat):
        """Extruded band between two point loops with the same point count (e.g. two ellipses)."""
        tb = bmesh.new()

        def p3(p, a):
            u, v = p
            return {"xz": (u, a, v), "yz": (a, u, v), "xy": (u, v, a)}[plane]

        lo_o = [tb.verts.new(p3(p, min(a0, a1))) for p in outer]
        hi_o = [tb.verts.new(p3(p, max(a0, a1))) for p in outer]
        lo_i = [tb.verts.new(p3(p, min(a0, a1))) for p in inner]
        hi_i = [tb.verts.new(p3(p, max(a0, a1))) for p in inner]
        n = len(outer)
        for i in range(n):
            j = (i + 1) % n
            tb.faces.new([lo_o[i], lo_o[j], lo_i[j], lo_i[i]])
            tb.faces.new([hi_o[i], hi_o[j], hi_i[j], hi_i[i]])
            tb.faces.new([lo_o[i], lo_o[j], hi_o[j], hi_o[i]])
            tb.faces.new([lo_i[i], lo_i[j], hi_i[j], hi_i[i]])
        self._merge(tb, mat, set())

    def beam(self, p0, p1, w, h, mat, bevel=0.0):
        """Box of cross-section w (sideways) x h (vertical-ish) running from p0 to p1."""
        a, b = Vector(p0), Vector(p1)
        d = b - a
        q = d.normalized().to_track_quat("X", "Z")
        tb = bmesh.new()
        bmesh.ops.create_cube(tb, size=1.0, matrix=Matrix.Diagonal((d.length, w, h, 1.0)))
        smooth = set()
        if bevel > 0:
            res = bmesh.ops.bevel(tb, geom=tb.edges[:], offset=min(bevel, min(w, h) * 0.45), offset_type="OFFSET",
                                  segments=1, profile=0.5, affect="EDGES", clamp_overlap=True)
            tb.faces.index_update()
            smooth = {f.index for f in res["faces"] if f.is_valid}
        self._merge(tb, mat, smooth, Matrix.Translation((a + b) / 2) @ q.to_matrix().to_4x4())

    # ---- output -----------------------------------------------------------------------------
    def build(self, name, origin=(0.0, 0.0, 0.0), parent=None):
        """Turn the accumulated geometry into an object named `name`. `origin` becomes the object's pivot
        (mesh is offset so it stays put in the world)."""
        bmesh.ops.translate(self.bm, vec=(-origin[0], -origin[1], -origin[2]), verts=self.bm.verts)
        me = bpy.data.meshes.new(name)
        self.bm.to_mesh(me)
        self.bm.free()
        for m in self.mats:
            me.materials.append(get_material(m))
        obj = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(obj)
        obj.location = origin
        if parent is not None:
            bpy.context.view_layer.update()
            obj.parent = parent
            obj.matrix_parent_inverse = parent.matrix_world.inverted()
        return obj


def stats(objs):
    tris, mn, mx = 0, Vector((1e9,) * 3), Vector((-1e9,) * 3)
    mats = set()
    for o in objs:
        if o.type != "MESH":
            continue
        tris += sum(len(p.vertices) - 2 for p in o.data.polygons)
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            for i in range(3):
                mn[i] = min(mn[i], w[i])
                mx[i] = max(mx[i], w[i])
        mats.update(m.name for m in o.data.materials)
    return tris, mn, mx, sorted(mats)
