"""Smoke-test asset: a ~2.1 m low-poly tree on a stone base, with red apples.

Run: tools/blender-run.ps1 art/scripts/test_prop.py
Out: game/assets/models/test_prop.glb
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bpy  # noqa: E402
import artlib  # noqa: E402

artlib.reset_scene()

stone = artlib.material("Stone", "#8a8a86", roughness=0.95)
bark = artlib.material("Bark", "#6b4423", roughness=0.9)
leaf_dark = artlib.material("LeafDark", "#2f7d32", roughness=0.8)
leaf_light = artlib.material("LeafLight", "#56b04a", roughness=0.8)
apple = artlib.material("Apple", "#d62828", roughness=0.4)

parts = []


def add(obj, mat):
    parts.append(artlib.with_material(obj, mat))


# Base: 0.15 m tall stone disc, bottom at z=0.
bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=0.45, depth=0.15, location=(0, 0, 0.075))
add(bpy.context.active_object, stone)
# Trunk: z 0.15 .. 1.05
bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.1, depth=0.9, location=(0, 0, 0.6))
add(bpy.context.active_object, bark)
# Lower foliage cone: z 0.9 .. 1.8
bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=0.6, radius2=0.0, depth=0.9, location=(0, 0, 1.35))
add(bpy.context.active_object, leaf_dark)
# Upper foliage cone: z 1.4 .. 2.1
bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=0.45, radius2=0.0, depth=0.7, location=(0, 0, 1.75),
                                rotation=(0, 0, math.radians(22.5)))
add(bpy.context.active_object, leaf_light)

# Apples sitting on the foliage surface.
for z, r, angles in ((1.1, 0.49, (20, 110, 200, 290)), (1.5, 0.41, (65, 245))):
    for a in angles:
        t = math.radians(a)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.07,
                                              location=(r * math.cos(t), r * math.sin(t), z))
        add(bpy.context.active_object, apple)

artlib.join(parts, "TestProp")
artlib.export_glb("test_prop")
