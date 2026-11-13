"""Builds the hand tools of the explorer (pickaxe, bucket, fuel torch, bundle torch) and exports them for Godot.

Run (from the project root):
    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --python tools/blender/build_tools.py

Writes  assets/tools/<tool>.glb   (the 3D model the game holds in the ball's "hand")
        assets/icons/<tool>.png   (the picture in the tool bar)

Conventions every model follows, so the game needs no per-tool fixes:
  * metres, Blender Z up (the glTF export turns it into Godot's Y up);
  * the ORIGIN is the grip: the point the game holds the tool by;
  * the handle runs along +Z (up), the working end is at the top;
  * the pickaxe head runs along Blender Y (= Godot Z), so a swing in the forward/up plane drives the point into the ground;
  * a mesh called "Water" (bucket) is the water surface: the game moves it with the fill level;
  * an empty called "FlamePoint" (torch) marks where the flame's light comes from;
  * flat shaded and low poly, like the terrain.
"""
import math
import os

import bmesh
import bpy
from mathutils import Euler, Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TOOLS_DIR = os.path.join(ROOT, "assets", "tools")
ICONS_DIR = os.path.join(ROOT, "assets", "icons")


# ------------------------------------------------------------------ helpers

def srgb(hex_str):
    """'rrggbb' -> linear rgb tuple (Blender stores colours linear)."""
    h = hex_str.lstrip("#")
    return tuple(pow(int(h[i:i + 2], 16) / 255.0, 2.2) for i in (0, 2, 4))


def material(name, hex_str, metallic=0.0, rough=0.75, emit_hex=None, emit_strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*srgb(hex_str), 1.0)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    if emit_hex:
        b.inputs["Emission Color"].default_value = (*srgb(emit_hex), 1.0)
        b.inputs["Emission Strength"].default_value = emit_strength
    m.diffuse_color = (*srgb(hex_str), 1.0)      # what the icon render (workbench) shows
    return m


def make_object(name, verts, faces, mat, shift=(0.0, 0.0, 0.0), recalc=True):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(Vector(v) + Vector(shift)) for v in verts], [], faces)
    mesh.update()
    bm = bmesh.new()
    bm.from_mesh(mesh)
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)  # whatever order the faces came in, they face outwards (closed shapes only)
    bm.to_mesh(mesh)
    bm.free()
    for p in mesh.polygons:
        p.use_smooth = False                                # faceted
    mesh.materials.append(mat)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def ring(z, r, sides, rot=0.0, cx=0.0, cy=0.0):
    return [Vector((cx + r * math.cos(rot + math.tau * i / sides), cy + r * math.sin(rot + math.tau * i / sides), z))
            for i in range(sides)]


def loft(name, rings, mat, shift=(0, 0, 0), cap_start=True, cap_end=True, recalc=True, flip_start=False):
    """A closed surface through rings of equal vertex counts."""
    n = len(rings[0])
    verts = [v for r in rings for v in r]
    faces = []
    for i in range(len(rings) - 1):
        for j in range(n):
            a = i * n + j
            b = i * n + (j + 1) % n
            faces.append((a, b, (i + 1) * n + (j + 1) % n, (i + 1) * n + j))
    if cap_start:
        faces.append(tuple(reversed(range(n))) if flip_start else tuple(range(n)))
    if cap_end:
        faces.append(tuple(range((len(rings) - 1) * n, len(rings) * n)))
    return make_object(name, verts, faces, mat, shift, recalc)


def box(name, size, center, mat, shift=(0, 0, 0)):
    sx, sy, sz = (s / 2 for s in size)
    cx, cy, cz = center
    verts = [(cx + dx * sx, cy + dy * sy, cz + dz * sz) for dz in (-1, 1) for dy in (-1, 1) for dx in (-1, 1)]
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    return make_object(name, verts, faces, mat, shift)


def sweep(name, path, half, mat, shift=(0, 0, 0)):
    """A square bar along a path that lies in the XZ plane."""
    rings = []
    side = Vector((0, 1, 0))
    for i, p in enumerate(path):
        a = path[max(i - 1, 0)]
        b = path[min(i + 1, len(path) - 1)]
        t = (Vector(b) - Vector(a)).normalized()
        nrm = t.cross(side).normalized()
        p = Vector(p)
        rings.append([p + side * half + nrm * half, p - side * half + nrm * half,
                      p - side * half - nrm * half, p + side * half - nrm * half])
    return loft(name, rings, mat, shift)


# ------------------------------------------------------------------ the tools

def build_pickaxe():
    wood = material("Wood", "8a5a2e", rough=0.85)
    leather = material("Grip", "4a3322", rough=0.9)
    iron = material("Iron", "7c828c", metallic=0.7, rough=0.45)
    dark = material("IronDark", "4c5058", metallic=0.6, rough=0.55)
    top = 0.64
    objs = []
    # handle: flared knob at the bottom, slim shaft, straight to the head
    objs.append(loft("Handle", [ring(-0.32, 0.036, 8), ring(-0.27, 0.027, 8), ring(0.20, 0.025, 8), ring(top + 0.03, 0.024, 8)], wood))
    objs.append(loft("GripWrap", [ring(-0.24, 0.031, 8), ring(-0.02, 0.031, 8)], leather))
    # head: a curved bar through the handle, thick in the middle, drawn out to two points
    rings = []
    for k in range(-4, 5):
        t = k / 4.0
        y = t * 0.36
        zc = top - 0.14 * t * t
        a = abs(t)
        th = 0.050 * (1.0 - a) ** 0.8 + 0.004          # half thickness
        wx = 0.030 * (1.0 - a) ** 0.7 + 0.003          # half width
        rings.append([Vector((wx, y, zc)), Vector((0, y, zc + th)), Vector((-wx, y, zc)), Vector((0, y, zc - th))])
    objs.append(loft("Head", rings, iron))
    objs.append(box("Collar", (0.075, 0.085, 0.075), (0, 0, top), dark))
    return objs, []


def build_bucket():
    wood = material("BucketWood", "a9794a", rough=0.85)
    # the inside is always in shadow, where the sky's blue ambient light turned it navy: it read as water. A faint warm glow keeps it wood-coloured.
    inner = material("BucketInner", "c9a070", rough=0.9, emit_hex="8a5c2a", emit_strength=1.2)
    iron = material("Hoop", "5b6068", metallic=0.7, rough=0.5)
    water = material("WaterSurface", "3f8fd2", rough=0.15)
    grasp = 0.46                                                       # the top of the handle is the origin
    shift = (0, 0, -grasp)
    sides = 12

    def rb(z):
        return 0.135 + 0.055 * (z / 0.30)                              # outside radius at height z

    # outer wall + rim (bottom closed, facing down), then the inside as its own surface (facing in) with its own lighter wood
    objs = [loft("Body", [ring(0.0, 0.135, sides, 0.13), ring(0.30, 0.19, sides, 0.13), ring(0.30, 0.172, sides, 0.13)],
                 wood, shift, cap_start=True, cap_end=False, recalc=False, flip_start=True),
            loft("Inside", [ring(0.30, 0.172, sides, 0.13), ring(0.03, 0.123, sides, 0.13)],
                 inner, shift, cap_start=False, cap_end=True, recalc=False)]
    for z0, z1 in ((0.05, 0.085), (0.22, 0.255)):
        # an open band (outside, top, inside, bottom): a capped one would be a solid lid across the bucket
        outer0, outer1 = ring(z0, rb(z0) + 0.012, sides, 0.13), ring(z1, rb(z1) + 0.012, sides, 0.13)
        inner1, inner0 = ring(z1, rb(z1) - 0.002, sides, 0.13), ring(z0, rb(z0) - 0.002, sides, 0.13)
        objs.append(loft("Hoop", [outer0, outer1, inner1, inner0, outer0], iron, shift, cap_start=False, cap_end=False, recalc=False))
    arc = [(0.19 * math.cos(math.pi * i / 10), 0.0, 0.27 + 0.19 * math.sin(math.pi * i / 10)) for i in range(11)]
    objs.append(sweep("Handle", arc, 0.009, iron, shift))
    # the water surface (the game moves it up and down with the fill level)
    r_w = 0.158
    verts = [Vector((0, 0, 0.0))] + ring(0.0, r_w, sides, 0.13)
    faces = [(0, 1 + i, 1 + (i + 1) % sides) for i in range(sides)]
    w = make_object("Water", verts, faces, water, (0, 0, 0.22 - grasp), recalc=False)       # one flat disc, facing up
    objs.append(w)
    return objs, []


def build_torch():
    """The fuel torch: a thick stick with a big coal-wrapped head and a big flame (burns 15 minutes)."""
    wood = material("TorchWood", "5e3b20", rough=0.9)
    char = material("TorchWrap", "2a1d14", rough=0.95)
    coal = material("TorchCoal", "3a3a42", rough=0.6)
    iron = material("TorchBand", "6a6f78", metallic=0.6, rough=0.5)
    flame = material("Flame", "ff7a1c", rough=0.5, emit_hex="ff6a10", emit_strength=6.0)
    core = material("FlameCore", "ffd070", rough=0.5, emit_hex="ffc850", emit_strength=9.0)
    objs = [
        loft("Stick", [ring(-0.20, 0.028, 8), ring(0.40, 0.023, 8)], wood),
        loft("Wrap", [ring(0.34, 0.025, 8), ring(0.44, 0.052, 8), ring(0.60, 0.050, 8), ring(0.66, 0.036, 8)], char),
        loft("CoalLumps", [ring(0.46, 0.055, 7, 0.2), ring(0.52, 0.062, 7, 0.5), ring(0.58, 0.053, 7, 0.2)], coal),
        loft("Band", [ring(0.40, 0.034, 8), ring(0.43, 0.034, 8)], iron),
        loft("Flame", [ring(0.64, 0.042, 6), ring(0.75, 0.068, 6, 0.3), ring(0.87, 0.042, 6, 0.6), ring(1.04, 0.004, 6, 0.9)], flame),
        loft("FlameCore", [ring(0.65, 0.027, 6), ring(0.73, 0.040, 6, 0.3), ring(0.90, 0.004, 6, 0.6)], core),
    ]
    anchor = bpy.data.objects.new("FlamePoint", None)
    anchor.location = (0, 0, 0.82)
    anchor.scale = (1.6, 1.6, 1.6)                  # the game reads this as the strength of the light: a big flame lights more
    bpy.context.scene.collection.objects.link(anchor)
    return objs, [anchor]


def build_torch_bundle():
    """The bundle torch: three pale splinters tied with a cord and a small flame (burns 5 minutes)."""
    wood = material("SplinterWood", "c19a62", rough=0.9)
    cord = material("Cord", "4a3a2a", rough=0.95)
    flame = material("Flame", "ff7a1c", rough=0.5, emit_hex="ff6a10", emit_strength=6.0)
    core = material("FlameCore", "ffd070", rough=0.5, emit_hex="ffc850", emit_strength=9.0)
    objs = []
    for i in range(3):
        a = math.tau * i / 3 + 0.4
        dx, dy = 0.024 * math.cos(a), 0.024 * math.sin(a)       # the splinters lean apart towards the top
        objs.append(loft("Splinter%d" % i, [ring(-0.20, 0.010, 5, cx=0.0, cy=0.0), ring(0.14, 0.011, 5, cx=dx * 0.45, cy=dy * 0.45),
                                            ring(0.28, 0.009, 5, cx=dx, cy=dy)], wood))
    objs.append(loft("Cord", [ring(0.08, 0.021, 8), ring(0.13, 0.021, 8)], cord))
    objs.append(loft("Flame", [ring(0.28, 0.016, 6), ring(0.32, 0.026, 6, 0.3), ring(0.37, 0.015, 6, 0.6), ring(0.44, 0.003, 6, 0.9)], flame))
    objs.append(loft("FlameCore", [ring(0.29, 0.010, 6), ring(0.32, 0.016, 6, 0.3), ring(0.39, 0.003, 6, 0.6)], core))
    anchor = bpy.data.objects.new("FlamePoint", None)
    anchor.location = (0, 0, 0.34)
    anchor.scale = (0.7, 0.7, 0.7)                  # a small flame: a smaller light
    bpy.context.scene.collection.objects.link(anchor)
    return objs, [anchor]


TOOLS = {
    # builder, icon roll (degrees), icon view size (m), icon turn about the vertical axis (degrees)
    "pickaxe": (build_pickaxe, 36.0, 1.35, 0.0),
    "bucket": (build_bucket, 8.0, 0.75, -55.0),
    "torch": (build_torch, 28.0, 1.25, 0.0),
    "torch_bundle": (build_torch_bundle, 28.0, 0.8, 0.0),
}


# ------------------------------------------------------------------ export and icons

def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials):
        for b in list(block):
            block.remove(b)


def export_glb(objs, path):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_yup=True, export_cameras=False, export_lights=False)


def render_icon(objs, roll_deg, size, yaw_deg, path):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.film_transparent = True
    scene.render.resolution_x = scene.render.resolution_y = 128
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_object_outline = True
    scene.display.shading.object_outline_color = (0.05, 0.05, 0.05)
    scene.display.render_aa = "8"
    for o in objs:
        o.rotation_euler.z += math.radians(yaw_deg)        # every tool is built around the vertical axis through its grip
    bpy.context.view_layer.update()
    meshes = [o for o in objs if o.type == "MESH"]
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in meshes:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    mid = (lo + hi) / 2
    cam_data = bpy.data.cameras.new("IconCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = size
    cam = bpy.data.objects.new("IconCam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    base = Euler((math.pi / 2, 0, math.pi / 2)).to_matrix()      # looks along -X, Z up, +Y to the right
    cam.rotation_euler = (base @ Euler((0, 0, math.radians(roll_deg))).to_matrix()).to_euler()
    cam.location = mid + Vector((3, 0, 0))
    scene.camera = cam
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)
    bpy.data.cameras.remove(cam_data)


def main():
    os.makedirs(TOOLS_DIR, exist_ok=True)
    os.makedirs(ICONS_DIR, exist_ok=True)
    for name, (builder, roll, size, yaw) in TOOLS.items():
        clear_scene()
        objs, empties = builder()
        export_glb(objs + empties, os.path.join(TOOLS_DIR, name + ".glb"))
        render_icon(objs + empties, roll, size, yaw, os.path.join(ICONS_DIR, name + ".png"))
        print("built", name, len(objs), "parts")


if __name__ == "__main__":
    main()
