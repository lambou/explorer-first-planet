"""Builds the explorer himself (an original round mint-green blob with a leaf sprout on top) and exports it for Godot.

Run (from the project root):
    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --python tools/blender/build_character.py

Writes  assets/character/explorer.glb

The character is made of SEPARATE parts that float around the body (no legs, no arms): the game animates them
(PlayerCharacter), so every part is its own object with its origin at its own centre:
    Body (round, with the face and sprout as children of it in the game: EyeL EyeR ShineL ShineR Nose Sprout(+LeafL LeafR)),
    FootL FootR (the boots, floating below the body with a clear gap), HandL HandR (floating beside it).
The model's origin is the centre of the physics ball (0.5 m radius): the feet's soles are at -0.5 m.
Metres, Blender Z up, the face looks along Blender +Y (= Godot -Z, forward). Flat shaded and low poly, like the terrain.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_tools as bt  # noqa: E402  (the shared helpers: materials, export)

OUT = os.path.join(bt.ROOT, "assets", "character", "explorer.glb")


def blob(name, radii, center, mat, subdiv=2, yaw_deg=0.0, flat_bottom=0.0):
    """A flat shaded ellipsoid with its origin at `center`.

    flat_bottom: 0..1, how much of the lower half to flatten into a sole (a flat base instead of
    a curved underside, for better ground contact) - 0 keeps the ellipsoid round.
    """
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * radii[0], v.co.y * radii[1], v.co.z * radii[2]))
    if flat_bottom > 0.0:
        floor = -radii[2] * (1.0 - flat_bottom)
        for v in bm.verts:
            if v.co.z < floor:
                v.co.z = floor
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    if yaw_deg:
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0), matrix=__import__("mathutils").Matrix.Rotation(math.radians(yaw_deg), 3, "Z"))
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    for p in mesh.polygons:
        p.use_smooth = False
    mesh.materials.append(mat)
    obj = bpy.data.objects.new(name, mesh)
    obj.location = center
    bpy.context.scene.collection.objects.link(obj)
    return obj


def build():
    mint = bt.material("Mint", "4fcb86", rough=0.7)
    boot = bt.material("Boot", "8a5636", rough=0.8)
    mitt = bt.material("Mitt", "f2e4c2", rough=0.8)
    eye_mat = bt.material("Eye", "14212b", rough=0.3)
    shine = bt.material("Shine", "ffffff", rough=0.2, emit_hex="ffffff", emit_strength=1.0)
    nose_mat = bt.material("Nose", "ff9a4a", rough=0.6)
    leaf_mat = bt.material("Leaf", "5fcf4f", rough=0.7)
    stem_mat = bt.material("Stem", "3f9a3c", rough=0.7)
    lift = 0.255                                  # the body floats this far above the ball's centre: a wide, clearly visible gap above the boots
    r = 0.46
    c = Vector((0, 0, lift))
    parts = [blob("Body", (r, r, r), c, mint, subdiv=3)]

    def on_body(direction, depth):
        """A point on (just under, for negative depth) the body's surface in a direction."""
        d = Vector(direction).normalized()
        return c + d * (r + depth)

    for side, sx in (("L", -1), ("R", 1)):
        # eyes: big round dark eyes, each with a white shine
        parts.append(blob("Eye" + side, (0.062, 0.036, 0.074), on_body((sx * 0.36, 0.90, 0.16), -0.012), eye_mat, subdiv=1))
        parts.append(blob("Shine" + side, (0.024, 0.016, 0.026), on_body((sx * 0.34, 0.92, 0.25), 0.010), shine, subdiv=1))
        # boots: floating ovals under the body, toes forward, soles flattened for ground contact
        parts.append(blob("Foot" + side, (0.115, 0.19, 0.075), Vector((sx * 0.20, 0.07, -0.425)), boot, subdiv=2, flat_bottom=0.6))
        # mitts: floating beside the body
        parts.append(blob("Hand" + side, (0.105, 0.105, 0.105), Vector((sx * 0.58, 0.0, lift - 0.02)), mitt, subdiv=2))
    # a small orange nose between the eyes, low
    parts.append(blob("Nose", (0.04, 0.03, 0.03), on_body((0.0, 1.0, -0.02), -0.004), nose_mat, subdiv=1))
    # a sprout on top: a stem and two leaves (the game sways them as he moves)
    top = c + Vector((0, 0, r - 0.03))
    parts.append(blob("Sprout", (0.016, 0.016, 0.085), top + Vector((0, 0, 0.05)), stem_mat, subdiv=1))
    tip = top + Vector((0, 0, 0.12))
    parts.append(blob("LeafL", (0.17, 0.06, 0.03), tip + Vector((-0.14, 0, 0.03)), leaf_mat, subdiv=1, yaw_deg=18))
    parts.append(blob("LeafR", (0.17, 0.06, 0.03), tip + Vector((0.14, 0, 0.03)), leaf_mat, subdiv=1, yaw_deg=-18))
    return parts


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bt.clear_scene()
    parts = build()
    bt.export_glb(parts, OUT)
    print("built the character,", len(parts), "parts")


main()
