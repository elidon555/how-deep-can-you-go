"""Models the burrowing worm in Blender and renders flat + clay + normal passes.

Run headless:
  blender -b --factory-startup -P tools/worm_blender.py -- <out_dir>
tools/worm_sheet.py turns the renders into assets/sprites/worm_segment.png / worm_head.png.

Units: 1 Blender unit = 1 game px. The body is a chain of round segments that never rotate,
so each segment is drawn as seen down the body's axis: a pale ball with dark rings around it.
The head is rendered in 16 travel directions (0 = moving right, 22.5 degree steps clockwise on
screen) with its three hooked mandibles closed and open; turning the 3D model before rendering
keeps the light coming from the same side in every direction. The head is also turned 35
degrees toward the viewer so its round maw reads.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_pass import PASSES, normal_shader, set_view  # noqa: E402

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/worm"
os.makedirs(OUT, exist_ok=True)
SEGMENT_SIZES = (24, 18, 12)
HEAD_CELL, HEAD_DIRS = 32, 16
MOUTH = {0: 14.0, 1: -20.0}     # mandible hinge angle: 0 = closed (tips meet), 1 = open

COLORS = {
    "flesh": "#b8a0a8", "flesh_b": "#a68e98", "ring": "#5e4652", "lip": "#7a4e5e",
    "bone": "#e6dccb", "bone_dark": "#a8987e", "maw": "#1a0a10", "maw_wet": "#4a1a26",
}

# ---------------------------------------------------------------- scene setup (as the other scripts)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 48
scene.cycles.use_denoising = False
scene.cycles.filter_width = 0.01
scene.render.film_transparent = True
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "Standard"
world = bpy.data.worlds.new("W")
scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.12, 0.12, 0.12, 1)
cam_data = bpy.data.cameras.new("Cam")
cam_data.type = "ORTHO"
cam_data.clip_end = 1000
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam
sun_data = bpy.data.lights.new("Sun", "SUN")
sun_data.energy = 1.4
sun = bpy.data.objects.new("Sun", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = (-Vector((0.55, 0.75, -0.8)).normalized()).to_track_quat("Z", "Y").to_euler()

MATS = {}


def hex_rgb(h):
    h = h.lstrip("#")
    return [(int(h[i:i + 2], 16) / 255) ** 2.2 for i in (0, 2, 4)] + [1.0]


def material(name):
    if name in MATS:
        return MATS[name][0]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = hex_rgb(COLORS[name])
    df = nt.nodes.new("ShaderNodeBsdfDiffuse")
    df.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    MATS[name] = (m, nt, out, em, df, normal_shader(nt))
    return m


def set_mode(mode):
    """mode: "flat" (albedo), "clay" (white clay lit by the sun) or "normal" (camera normals)."""
    for m, nt, out, em, df, nm in MATS.values():
        for l in list(out.inputs["Surface"].links):
            nt.links.remove(l)
        nt.links.new({"flat": em, "clay": df, "normal": nm}[mode].outputs[0], out.inputs["Surface"])
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0 if mode == "clay" else 0.0
    sun_data.energy = 1.4 if mode == "clay" else 0.0
    set_view(scene, mode)


# ---------------------------------------------------------------- modelling helpers
current = []


def add(obj, mat, smooth=True):
    obj.data.materials.append(material(mat))
    if smooth:
        for p in obj.data.polygons:
            p.use_smooth = True
    current.append(obj)
    return obj


def ball(loc, r, mat, scale=(1, 1, 1)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=r, location=loc)
    o = bpy.context.active_object
    o.scale = scale
    return add(o, mat)


def ring(loc, major, minor, mat, rot=(0, 0, 0), scale=(1, 1, 1)):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, major_segments=32,
                                     minor_segments=8, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = scale
    return add(o, mat)


def tube(a, b, r0, r1, mat, verts=8):
    """Tapered limb from point a (radius r0) to point b (radius r1)."""
    a, b = Vector(a), Vector(b)
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r0, radius2=r1, depth=(b - a).length,
                                    location=(a + b) / 2)
    o = bpy.context.active_object
    o.rotation_euler = (b - a).to_track_quat("Z", "Y").to_euler()
    return add(o, mat)


def empty(loc=(0, 0, 0)):
    e = bpy.data.objects.new("e", None)
    scene.collection.objects.link(e)
    e.location = loc
    return e


def parent_to(objs, parent):
    bpy.context.view_layer.update()
    for o in objs:
        o.parent = parent
        o.matrix_parent_inverse = parent.matrix_world.inverted()


SPRITES = {}   # name -> (objects, size)


def sprite(name, size):
    global current
    SPRITES[name] = (current, size)
    current = []


# ---------------------------------------------------------------- body segments (seen down the axis)
FACE = (math.radians(90), 0, 0)          # a torus facing the camera
for size in SEGMENT_SIZES:
    r = (size - 2) / 2                   # leave 1 px for the outline
    ball((0, 0, 0), r, "flesh")
    for k, t in enumerate((0.84, 0.55)):  # two dark rings: the grooves between body rings
        ring((0, -r * math.sqrt(1 - t * t) + 0.2, 0), r * t, max(0.7, r * 0.07), "ring", rot=FACE)
    ring((0, -r * 0.2, 0), r * 0.25, max(0.6, r * 0.08), "flesh_b", rot=FACE)   # a lighter knot in the middle
    sprite(f"segment_{size}", size)

# ---------------------------------------------------------------- head, built facing +X
HR = 10.0                                # head radius
head = empty()
parts = [ball((0, 0, 0), HR, "flesh", scale=(1.0, 0.95, 0.95))]
for x in (-6.0, -1.5):                   # body rings round the head, axis along X
    rr = HR * math.sqrt(1 - (x / HR) ** 2)
    parts.append(ring((x, 0, 0), rr * 0.97, 0.9, "ring", rot=(0, math.radians(90), 0)))
# the round maw sits proud of the head's front: fleshy lip, wet inner flesh, dark throat, teeth
parts.append(ring((8.4, 0, 0), 4.7, 1.5, "lip", rot=(0, math.radians(90), 0)))
parts.append(ball((9.2, 0, 0), 4.6, "maw_wet", scale=(0.3, 1, 1)))
parts.append(ball((9.6, 0, 0), 3.2, "maw", scale=(0.35, 1, 1)))
for k in range(9):
    a = 2 * math.pi * k / 9
    base = Vector((10.0, 3.9 * math.sin(a), 3.9 * math.cos(a)))
    parts.append(tube(base, base + Vector((0.8, -1.7 * math.sin(a), -1.7 * math.cos(a))), 0.5, 0.05, "bone", 5))
parent_to(parts, head)
hinges = []
for k in range(3):                       # three hooked mandibles round the maw (one up, two down)
    roll = empty()
    hinge = empty((8.4, 0, 5.0))
    mand = [tube((8.4, 0, 5.0), (12.0, 0, 6.4), 1.5, 1.1, "bone"),
            tube((12.0, 0, 6.4), (14.2, 0, 4.4), 1.1, 0.7, "bone"),
            tube((14.2, 0, 4.4), (14.4, 0, 2.6), 0.7, 0.05, "bone_dark", 6)]
    parent_to(mand, hinge)
    parent_to([hinge], roll)
    parent_to([roll], head)
    roll.rotation_euler.x = math.radians(120 * k)     # spin it round the maw after parenting
    hinges.append(hinge)
# turned a little toward the viewer so the round maw shows; `turn` then aims it per direction
HEAD_YAW = -35
turn = empty()
parent_to([head], turn)
head.rotation_euler.z = math.radians(HEAD_YAW)
sprite("head", HEAD_CELL)


# ---------------------------------------------------------------- render
def render(name, size):
    scene.render.resolution_x = scene.render.resolution_y = size
    cam_data.ortho_scale = size
    cam.location = (0, -300, 0)
    for mode in PASSES:
        set_mode(mode)
        scene.render.filepath = os.path.join(OUT, f"{name}_{mode}.png")
        bpy.ops.render.render(write_still=True)


all_objs = [o for objs, _ in SPRITES.values() for o in objs]
for name, (objs, size) in SPRITES.items():
    for o in all_objs:
        o.hide_render = o not in objs
    if name != "head":
        render(name, size)
        continue
    for frame, hinge_deg in MOUTH.items():
        for h in hinges:
            h.rotation_euler.y = math.radians(hinge_deg)
        for d in range(HEAD_DIRS):
            # screen angle, y down, clockwise: turning the head by +a about Y points +X there
            turn.rotation_euler.y = math.radians(360 * d / HEAD_DIRS)
            render(f"head_{frame}_{d}", size)
print("WORM_DONE")
