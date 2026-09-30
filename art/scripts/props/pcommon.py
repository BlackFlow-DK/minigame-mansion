"""Shared mesh-building helpers for the props family (Blender 5.2, Z-up, metres).

Everything is built with bmesh straight into one mesh per exported object (no bpy.ops booleans or joins),
so materials, sharp-edge shading and origins are fully under control.
Authoring space is Blender: +Z up, model front = -Y (= Godot +Z).
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

import artlib

TAU = math.tau
HEX = dict(
    wood="#8a5a3c", dark_wood="#5b3a29", stone="#8d8794", dark_stone="#4a4652", plum="#6d4a7c",
    teal="#2fa7a0", cream="#f3e6c8", gold="#e8b33a", red="#d9483b", green="#58b368", blue="#3f7fd9",
    charcoal="#2e2a33", lava="#ff6a1f",
)
NAME = dict(
    wood="Wood", dark_wood="DarkWood", stone="Stone", dark_stone="DarkStone", plum="Plum", teal="Teal",
    cream="Cream", gold="Gold", red="Red", green="Green", blue="Blue", charcoal="Charcoal", lava="Lava",
)


def M(key, rough=0.8, metallic=0.0, name=None, hexv=None):
    """Palette material by key ('stone'), or a custom one via name/hexv."""
    return artlib.material(name or NAME[key], hexv or HEX[key], rough, metallic)


def EM(name, hexv, strength=1.0, rough=0.5):
    """Emissive material; name must start with 'Emit'."""
    assert name.startswith("Emit")
    m = artlib.material(name, hexv, rough)
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Emission Color"].default_value = m.diffuse_color
    b.inputs["Emission Strength"].default_value = strength
    return m


def xform(loc=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1)):
    if isinstance(scale, (int, float)):
        scale = (scale, scale, scale)
    s = Matrix.Diagonal((*scale, 1.0))
    return Matrix.Translation(loc) @ Euler(rot).to_matrix().to_4x4() @ s


# ---------------------------------------------------------------- profiles
def _arc(cx, cz, r, a0, a1, n):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
             cz + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def _dedupe(pts):
    out = []
    for p in pts:
        if not out or abs(out[-1][0] - p[0]) > 1e-9 or abs(out[-1][1] - p[1]) > 1e-9:
            out.append(p)
    return out


def rrect(r0, r1, z0, z1, bt=0.0, bb=None, seg=2):
    """CCW profile (r, z) of a rounded solid (r0 <= 0: open profile from the axis) or annulus (closed).

    bt/bb: corner radius top/bottom. Returns (points, closed)."""
    bb = bt if bb is None else bb
    solid = r0 <= 1e-9
    p = []
    if solid:
        p.append((0.0, z0))
        p.append((r1 - bb, z0))
    else:
        p.append((r0 + bb, z0))
        p.append((r1 - bb, z0))
    if bb > 0:
        p += _arc(r1 - bb, z0 + bb, bb, -90, 0, seg)
    p.append((r1, z1 - bt))
    if bt > 0:
        p += _arc(r1 - bt, z1 - bt, bt, 0, 90, seg)
    if solid:
        p.append((0.0, z1))
    else:
        p.append((r0 + bt, z1))
        if bt > 0:
            p += _arc(r0 + bt, z1 - bt, bt, 90, 180, seg)
        p.append((r0, z0 + bb))
        if bb > 0:
            p += _arc(r0 + bb, z0 + bb, bb, 180, 270, seg)
    return _dedupe(p), not solid


def _closed_dedupe(p):
    p = _dedupe(p)
    if len(p) > 1 and abs(p[0][0] - p[-1][0]) < 1e-9 and abs(p[0][1] - p[-1][1]) < 1e-9:
        p = p[:-1]
    return p


# ---------------------------------------------------------------- builder
class Builder:
    """One exported mesh object. `angle` = degrees above which an edge is shaded hard."""

    def __init__(self, name, angle=38.0):
        self.name = name
        self.angle = angle
        self.bm = bmesh.new()
        self.mats = []

    def mi(self, mat):
        if mat not in self.mats:
            self.mats.append(mat)
        return self.mats.index(mat)

    def _merge(self, tmp, xf=None):
        if xf is not None:
            bmesh.ops.transform(tmp, matrix=xf, verts=tmp.verts)
        me = bpy.data.meshes.new("_tmp")
        tmp.to_mesh(me)
        tmp.free()
        self.bm.from_mesh(me)
        bpy.data.meshes.remove(me)

    # -- primitives ---------------------------------------------------
    def lathe(self, profile, mat, segs=24, a0=0.0, a1=TAU, closed=False, loc=(0, 0, 0), rot=(0, 0, 0),
              scale=(1, 1, 1), solid=True, caps=True, xf=None):
        """Revolve `profile` [(r, z)] about Z. `mat` is a material or callable(r_mid, z_mid) -> material."""
        if closed:
            profile = _closed_dedupe(profile)
        n = len(profile)
        nseg = n if closed else n - 1
        full = abs((a1 - a0) - TAU) < 1e-6
        rings = segs if full else segs + 1
        tmp = bmesh.new()
        V = []
        for j in range(rings):
            a = a0 + (a1 - a0) * j / segs
            c, s = math.cos(a), math.sin(a)
            row = []
            for i, (r, z) in enumerate(profile):
                if r < 1e-9 and j > 0:
                    row.append(V[0][i])
                else:
                    row.append(tmp.verts.new((r * c, r * s, z)))
            V.append(row)
        for i in range(nseg):
            i2 = (i + 1) % n
            (ra, za), (rb, zb) = profile[i], profile[i2]
            m = mat((ra + rb) / 2, (za + zb) / 2) if callable(mat) else mat
            mi = self.mi(m)
            for j in range(segs):
                j2 = (j + 1) % rings if full else j + 1
                vs = []
                for v in (V[j][i], V[j2][i], V[j2][i2], V[j][i2]):
                    if v not in vs:
                        vs.append(v)
                if len(vs) < 3:
                    continue
                f = tmp.faces.new(vs)
                f.material_index = mi
        if not full and caps and solid:
            for j, flip in ((0, True), (rings - 1, False)):
                vs = []
                for v in V[j]:
                    if v not in vs:
                        vs.append(v)
                if len(vs) >= 3:
                    f = tmp.faces.new(vs[::-1] if flip else vs)
                    f.material_index = self.mi(mat(profile[0][0], profile[0][1]) if callable(mat) else mat)
        if solid:
            bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
        self._merge(tmp, xf if xf is not None else xform(loc, rot, scale))
        return self

    def cyl(self, r, h, loc, mat, segs=16, bevel=0.0, rot=(0, 0, 0), r_top=None, seg=2):
        """Cylinder standing on z = loc.z (base) with rounded corners."""
        if r_top is None or abs(r_top - r) < 1e-9:
            prof, _ = rrect(0, r, 0, h, bevel, bevel, seg)
        else:  # tapered: straight cone frustum with optional tiny bevel ignored
            prof = [(0, 0), (r, 0), (r_top, h), (0, h)]
        return self.lathe(prof, mat, segs=segs, loc=loc, rot=rot)

    def sphere(self, r, loc, mat, scale=(1, 1, 1), segs=16, rings=10, rot=(0, 0, 0), zmin=None, xf=None):
        prof = [(r * math.sin(math.pi * i / rings), -r * math.cos(math.pi * i / rings)) for i in range(rings + 1)]
        prof[0] = (0.0, prof[0][1])
        prof[-1] = (0.0, prof[-1][1])
        return self.lathe(prof, mat, segs=segs, loc=loc, scale=scale, rot=rot, xf=xf)

    def box(self, size, loc, mat, bevel=0.0, rot=(0, 0, 0), seg=1, xf=None):
        """Box centred on `loc`."""
        sx, sy, sz = (size, size, size) if isinstance(size, (int, float)) else size
        tmp = bmesh.new()
        hx, hy, hz = sx / 2, sy / 2, sz / 2
        vs = [tmp.verts.new((x, y, z)) for z in (-hz, hz) for y in (-hy, hy) for x in (-hx, hx)]
        # index = x + 2y + 4z
        quads = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
        mi = self.mi(mat)
        for q in quads:
            f = tmp.faces.new([vs[i] for i in q])
            f.material_index = mi
        bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
        if bevel > 0:
            bmesh.ops.bevel(tmp, geom=list(tmp.edges), offset=min(bevel, min(hx, hy, hz) * 0.95),
                            offset_type="OFFSET", segments=seg, profile=0.5, affect="EDGES")
        self._merge(tmp, xf if xf is not None else xform(loc, rot))
        return self

    def prism(self, poly, z0, z1, mat, bevel=0.0, loc=(0, 0, 0), rot=(0, 0, 0), seg=1, caps=True, xf=None):
        """Extrude a 2D polygon (CCW, may be concave when bevel == 0) from z0 to z1."""
        tmp = bmesh.new()
        lo = [tmp.verts.new((x, y, z0)) for x, y in poly]
        hi = [tmp.verts.new((x, y, z1)) for x, y in poly]
        mi = self.mi(mat)
        n = len(poly)
        fs = [tmp.faces.new(hi), tmp.faces.new(lo[::-1])]
        for i in range(n):
            j = (i + 1) % n
            fs.append(tmp.faces.new([lo[i], lo[j], hi[j], hi[i]]))
        for f in fs:
            f.material_index = mi
        bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
        if bevel > 0:
            # horizontal edges only, so vertical corners stay sharp and neighbouring prisms tile exactly
            edges = [e for e in tmp.edges if abs(e.verts[0].co.z - e.verts[1].co.z) < 1e-9]
            bmesh.ops.bevel(tmp, geom=edges, offset=bevel, offset_type="OFFSET", segments=seg,
                            profile=0.5, affect="EDGES")
        self._merge(tmp, xf if xf is not None else xform(loc, rot))
        return self

    def tube(self, path, r, mat, sides=6, loc=(0, 0, 0), rot=(0, 0, 0), radii=None, caps=True, up=(0, 0, 1), xf=None):
        """Swept circle along a polyline (Blender-space points)."""
        tmp = bmesh.new()
        pts = [Vector(p) for p in path]
        rings = []
        upv = Vector(up)
        for i, p in enumerate(pts):
            if i == 0:
                t = pts[1] - pts[0]
            elif i == len(pts) - 1:
                t = pts[-1] - pts[-2]
            else:
                t = pts[i + 1] - pts[i - 1]
            t.normalize()
            ref = upv if abs(t.dot(upv)) < 0.95 else Vector((1, 0, 0))
            side = t.cross(ref).normalized()
            nrm = side.cross(t).normalized()
            rr = radii[i] if radii else r
            rings.append([tmp.verts.new(p + (side * math.cos(TAU * k / sides) + nrm * math.sin(TAU * k / sides)) * rr)
                          for k in range(sides)])
        mi = self.mi(mat)
        for i in range(len(pts) - 1):
            for k in range(sides):
                k2 = (k + 1) % sides
                f = tmp.faces.new([rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]])
                f.material_index = mi
        if caps:
            for ring in (rings[0], rings[-1]):
                f = tmp.faces.new(ring)
                f.material_index = mi
        bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
        self._merge(tmp, xf if xf is not None else xform(loc, rot))
        return self

    def ico(self, r, loc, mat, subdiv=2, scale=(1, 1, 1), rot=(0, 0, 0), fn=None, zmin=None, mat_fn=None, xf=None):
        """Icosphere with optional per-vertex displacement fn(Vector unit_dir) -> radius factor; flat base at zmin.

        mat_fn(normal_z) -> material lets top faces read lighter."""
        tmp = bmesh.new()
        bmesh.ops.create_icosphere(tmp, subdivisions=subdiv, radius=1.0)
        for v in tmp.verts:
            d = v.co.normalized()
            k = fn(d) if fn else 1.0
            v.co = Vector((d.x * k * scale[0], d.y * k * scale[1], d.z * k * scale[2])) * r
        if zmin is not None:
            for v in tmp.verts:
                if v.co.z < zmin:
                    v.co.z = zmin
        bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
        tmp.normal_update()
        for f in tmp.faces:
            m = mat_fn(f.normal.z) if mat_fn else mat
            f.material_index = self.mi(m)
        self._merge(tmp, xf if xf is not None else xform(loc, rot))
        return self

    def raw(self, tmp, xf=None):
        """Merge a prepared bmesh (materials already through self.mi)."""
        self._merge(tmp, xf)
        return self

    # -- output ---------------------------------------------------------
    def build(self, loc=(0, 0, 0)):
        bm = self.bm
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        bm.normal_update()
        lim = math.radians(self.angle)
        for f in bm.faces:
            f.smooth = True
        for e in bm.edges:
            if len(e.link_faces) == 2:
                e.smooth = e.calc_face_angle(0.0) <= lim
            else:
                e.smooth = True
        me = bpy.data.meshes.new(self.name)
        bm.to_mesh(me)
        bm.free()
        for m in self.mats:
            me.materials.append(m)
        ob = bpy.data.objects.new(self.name, me)
        bpy.context.scene.collection.objects.link(ob)
        ob.location = loc
        return ob


# ---------------------------------------------------------------- misc helpers
def hexagon(R, flat_top=True):
    """Regular hexagon; flat_top => vertices at 0, 60, ... degrees (points along +-X)."""
    off = 0.0 if flat_top else math.pi / 6
    return [(R * math.cos(off + math.pi / 3 * i), R * math.sin(off + math.pi / 3 * i)) for i in range(6)]


def star_poly(r_out, r_in, points=5, rot=math.pi / 2):
    out = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = rot + math.pi * i / points
        out.append((r * math.cos(a), r * math.sin(a)))
    return out


def lumps(seed, n=5, amp=0.18, fmax=2.6):
    """Smooth lumpy radius function of a unit direction (deterministic)."""
    rng = random.Random(seed)
    waves = []
    for _ in range(n):
        d = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))).normalized() * rng.uniform(1.0, fmax)
        waves.append((d, rng.uniform(0, TAU), rng.uniform(0.4, 1.0)))
    norm = sum(w[2] for w in waves)

    def fn(d):
        return 1.0 + amp * sum(a * math.sin(dirv.dot(d) * 2.4 + ph) for dirv, ph, a in waves) / norm * 1.6
    return fn


def tri_count(ob):
    me = ob.data
    me.calc_loop_triangles()
    return len(me.loop_triangles)


def report(name, objs):
    total = sum(tri_count(o) for o in objs)
    print(f"PIECE {name}: {total} tris, objects={[o.name for o in objs]}")
    return total


def finish(name, objs, expect_tris=(50, 2500)):
    """Print stats/bounds and export game/assets/models/props/<name>.glb."""
    total = report(name, objs)
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    for o in objs:
        for v in o.data.vertices:
            w = o.matrix_basis @ v.co
            lo = Vector((min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z)))
            hi = Vector((max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z)))
    # Godot axes: x, y=blender z, z=-blender y
    print(f"BOUNDS {name}: godot x[{lo.x:.3f},{hi.x:.3f}] y[{lo.z:.3f},{hi.z:.3f}] z[{-hi.y:.3f},{-lo.y:.3f}]")
    if not (expect_tris[0] <= total <= expect_tris[1]):
        raise RuntimeError(f"{name}: {total} tris outside {expect_tris}")
    artlib.export_glb(name, family="props")
    return total


def new_piece():
    artlib.reset_scene()


def polar_cells(b, r0, r1, z, ring_h, cell_w, gap, pick, seed=1, jit=0.0, brick=True):
    """Flat cobble/plate quads on a polar grid at height z. pick(k, j, r_mid, rng) -> material.
    Cells are shrunk by `gap` (the base under them shows as grout) and corners jittered by `jit`."""
    rng = random.Random(seed)
    tmp = bmesh.new()
    n = max(1, round((r1 - r0) / ring_h))
    for k in range(n):
        ra, rb = r0 + (r1 - r0) * k / n, r0 + (r1 - r0) * (k + 1) / n
        rm = (ra + rb) / 2
        c = max(5, round(TAU * rm / cell_w))
        off = (TAU / c * 0.5) if (brick and k % 2) else 0.0
        ri, ro = ra + gap / 2, rb - gap / 2
        for j in range(c):
            a0 = off + TAU * j / c
            a1 = a0 + TAU / c
            m = pick(k, j, rm, rng)
            pts = [(ri, a0 + gap / 2 / ri), (ro, a0 + gap / 2 / ro), (ro, a1 - gap / 2 / ro), (ri, a1 - gap / 2 / ri)]
            vs = []
            for r, a in pts:
                x, y = r * math.cos(a) + rng.uniform(-jit, jit), r * math.sin(a) + rng.uniform(-jit, jit)
                vs.append(tmp.verts.new((x, y, z)))
            f = tmp.faces.new(vs)
            f.material_index = b.mi(m)
    b.raw(tmp)
