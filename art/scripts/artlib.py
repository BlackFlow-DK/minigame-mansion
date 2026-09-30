"""Shared helpers for procedural Blender asset scripts (Blender 5.2).

Run scripts through tools/blender-run.ps1, never the Blender GUI. Conventions:
metres, Blender Z-up (exporter converts to glTF/Godot +Y up), model front faces
Blender -Y (becomes Godot +Z = Vector3.MODEL_FRONT), origin at the base centre.
"""
import sys
from pathlib import Path

import bpy

REPO_ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = REPO_ROOT / "game" / "assets" / "models"


def script_args():
    """Arguments passed after '--' on the Blender command line."""
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def reset_scene():
    """Remove all objects and orphaned data so each script starts clean."""
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.curves):
        for block in list(coll):
            coll.remove(block)


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def material(name, hex_srgb, roughness=0.8, metallic=0.0):
    """Principled BSDF material from an sRGB hex colour like '#6b4a2b'."""
    h = hex_srgb.lstrip("#")
    rgb = [_srgb_to_linear(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)]
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    mat.diffuse_color = (*rgb, 1.0)  # viewport colour only
    return mat


def with_material(obj, mat):
    obj.data.materials.append(mat)
    return obj


def join(objs, name):
    """Join objects into one mesh named `name` and apply all transforms.

    Build geometry around the world origin with the base at z=0: applying the
    location puts the object origin at the world origin, i.e. at the base.
    """
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return obj


def export_glb(filename, out_dir=MODELS_DIR):
    """Export the whole scene to <out_dir>/<filename>.glb with the project's glTF settings."""
    out = Path(out_dir) / f"{filename}.glb"
    out.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(out),
        check_existing=False,
        export_format="GLB",
        export_yup=True,
        export_apply=True,
        export_materials="EXPORT",
        export_cameras=False,
        export_lights=False,
        use_selection=False,
    )
    if not out.is_file():
        raise RuntimeError(f"glTF export did not write {out}")
    print(f"EXPORTED {out} ({out.stat().st_size} bytes)")
    return out
