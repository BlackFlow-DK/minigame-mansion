"""Low-poly blob for crowds and far blobs -> game/assets/models/character/blob_lod.glb.

Same parts, names, origins, sockets and material slots (in the same order) as blob.glb, so
the visuals component can swap each part's mesh in place and the cosmetics tint (surface
override materials by slot) keeps working. Built by running blob.py itself (its export is
held back), then a collapse Decimate per part: the body and limbs lose most of their rings,
the face parts (eyes, pupils, lids, mouth, cheeks) keep enough to read.

Used at LOW/MEDIUM quality for NPC extras and for blobs further than the LOD distance
(game/player/anim/blob_rig.gd, docs/performance.md).

Run: powershell -NoProfile -ExecutionPolicy Bypass -File tools\\blender-run.ps1 art\\scripts\\character\\blob_lod.py
"""
import runpy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import bpy  # noqa: E402

import artlib  # noqa: E402

# Fraction of the faces each part keeps. Silhouette parts go lowest; the face stays readable.
RATIO = {
    "Body": 0.30,
    "HandL": 0.35, "HandR": 0.35, "FootL": 0.35, "FootR": 0.35,
    "CheekL": 0.5, "CheekR": 0.5,
    "EyeL": 0.5, "EyeR": 0.5, "LidL": 0.5, "LidR": 0.5,
    "PupilL": 0.6, "PupilR": 0.6, "Mouth": 0.6,
}


def tri_count(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def main():
    real_export = artlib.export_glb
    artlib.export_glb = lambda *a, **k: None  # build blob.glb's scene without writing it
    try:
        runpy.run_path(str(Path(__file__).with_name("blob.py")), run_name="blob_build")
    finally:
        artlib.export_glb = real_export
    total_before = 0
    total_after = 0
    for name, ratio in RATIO.items():
        obj = bpy.data.objects.get(name)
        if obj is None or obj.type != "MESH":
            raise RuntimeError(f"blob_lod: blob.py built no mesh '{name}'")
        before = tri_count(obj)
        used_before = sorted({p.material_index for p in obj.data.polygons})
        mod = obj.modifiers.new("LOD", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
        mod.use_collapse_triangulate = True
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=mod.name)
        after = tri_count(obj)
        if len(obj.data.materials) == 0 or after < 8:
            raise RuntimeError(f"blob_lod: {name} decimated to nothing")
        # every material slot must keep faces: the glTF surfaces (and the tint by slot) line up
        used_after = sorted({p.material_index for p in obj.data.polygons})
        if used_after != used_before:
            raise RuntimeError(f"blob_lod: {name} lost material slots {used_before} -> {used_after}")
        total_before += before
        total_after += after
        print(f"LOD {name:7s} tris {before} -> {after} mats={[m.name for m in obj.data.materials]}")
    print(f"LOD TOTAL_TRIS {total_before} -> {total_after}")
    artlib.export_glb("blob_lod", family="character")


main()
