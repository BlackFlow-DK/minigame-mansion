"""Shared helpers for procedural Blender asset scripts (Blender 5.2).

Run scripts through tools/blender-run.ps1, never the Blender GUI. Conventions:
metres, Blender Z-up (exporter converts to glTF/Godot +Y up), model front faces
Blender -Y (becomes Godot +Z = Vector3.MODEL_FRONT), origin at the base centre.

Multi-part models (character, cosmetics): keep parts as separate named objects
(finalize()), add sockets with empty(), parent with set_parent(), then
export_glb(name, family="character").
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


def from_godot(xyz):
    """Godot-space (x, y, z) (Y up, front +Z) -> Blender location (x, -z, y) (Z up, front -Y)."""
    x, y, z = xyz
    return (x, -z, y)


def empty(name, location=(0.0, 0.0, 0.0), parent=None, size=0.1):
    """A named empty (a socket/attachment point); imports into Godot as a Node3D `name`.

    `location` is in Blender space; wrap Godot-space numbers in from_godot(...).
    """
    obj = bpy.data.objects.new(name, None)
    obj.empty_display_type = "PLAIN_AXES"
    obj.empty_display_size = size
    bpy.context.scene.collection.objects.link(obj)
    obj.location = location
    if parent is not None:
        set_parent(obj, parent)
    return obj


def set_parent(child, parent, keep_world=True):
    """Parent `child` to `parent` (exported as a child node). keep_world keeps its world placement."""
    world = child.matrix_world.copy()
    child.parent = parent
    if keep_world:
        child.matrix_world = world
    return child


def finalize(obj, name=None):
    """Name a separate part and apply its rotation and scale, keeping its origin where it is.

    Use for parts that must stay separate objects (unlike join(), which moves the origin
    to the world origin). Mesh primitives get their origin at the `location` they are added at.
    """
    if name:
        obj.name = name
        if obj.data is not None:
            obj.data.name = name
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    return obj


def export_glb(filename, family=None, out_dir=MODELS_DIR):
    """Export the whole scene to <out_dir>/[<family>/]<filename>.glb with the project's glTF settings.

    Every object keeps its own name, origin and transform (join() only what should be one mesh);
    empties export as plain nodes. Family example: export_glb("blob", family="character")
    writes game/assets/models/character/blob.glb.
    """
    out = Path(out_dir) / (family or "") / f"{filename}.glb"
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
