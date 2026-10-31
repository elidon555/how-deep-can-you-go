"""Models the cave bat in Blender, poses it, and renders flat + clay + normal passes.

Run headless:
  blender -b --factory-startup -P tools/bat_blender.py -- <out_dir>
tools/bat_sheet.py turns the renders into assets/sprites/bat.png (+ _n, _glow) and bat.json.

Units: 1 Blender unit = 1 game px; cells are 24x24 with the camera on the cell centre. The bat
faces +X but is turned 60 degrees toward the viewer: its wings spread left and right
across the screen and beat up and down, and both red eyes face out. Each wing is a
leathery membrane on finger bones, on two joints: a roll about the body axis (the wingbeat)
and a sweep in the wing's own plane (spread / swept back / folded).
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_pass import PASSES, normal_shader, set_view  # noqa: E402

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/bat"
os.makedirs(OUT, exist_ok=True)
CELL = 24
NEAR, FAR = -1, 1

COLORS = {
    "fur": "#664850", "fur_light": "#82626a", "skin": "#946064", "ear_in": "#a86c72",
    "membrane": "#7a4c5a", "membrane_far": "#5e3a48", "bone": "#2a1a20", "claw": "#1e1418",
    "eye": "#ff3a2a",
}
UNLIT = {"eye"}

# ---------------------------------------------------------------- scene setup (as the other scripts)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 48
scene.cycles.use_denoising = False
scene.cycles.filter_width = 0.01
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = CELL
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
cam_data.ortho_scale = CELL
cam_data.clip_end = 1000
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
cam.location = (0, -300, 0)
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
    if name in UNLIT:
        df = nt.nodes.new("ShaderNodeEmission")
        df.inputs["Strength"].default_value = 3.0
    else:
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
MESHES = []


def add(obj, mat, smooth=True):
    obj.data.materials.append(material(mat))
    if smooth:
        for p in obj.data.polygons:
            p.use_smooth = True
    MESHES.append(obj)
    return obj


def ball(loc, r, mat, scale=(1, 1, 1)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=r, location=loc)
    o = bpy.context.active_object
    o.scale = scale
    return add(o, mat)


def tube(a, b, r0, r1, mat, verts=6):
    a, b = Vector(a), Vector(b)
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r0, radius2=r1, depth=(b - a).length, location=(a + b) / 2)
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


# ---------------------------------------------------------------- the bat (facing +X, built level)
body = [ball((0, 0, 0), 1, "fur", scale=(3.2, 2.3, 2.5)),
        ball((0.4, -0.5, -0.6), 1, "fur_light", scale=(2.5, 1.8, 1.9)),            # paler belly
        ball((3.3, 0, 0.6), 1.9, "fur"),                                             # head
        ball((5.0, 0, 0.25), 0.85, "skin", scale=(1.2, 0.9, 0.8))]                    # snout
for side in (NEAR, FAR):
    body.append(tube((3.1, side * 0.9, 1.9), (2.5, side * 1.3, 4.3), 0.9, 0.1, "fur"))        # ears
    body.append(tube((3.25, side * 1.05, 1.95), (2.7, side * 1.35, 3.9), 0.45, 0.05, "ear_in"))
    body.append(tube((-2.9, side * 0.8, -1.2), (-3.9, side * 0.8, -1.9), 0.4, 0.05, "claw", 4))  # feet
EYES = [ball((4.55, side * 0.95, 0.95), 0.78, "eye") for side in (NEAR, FAR)]
FEET_TIP = Vector((-3.9, 0, -1.9))       # where the hanging bat grips the ceiling

# wing outline in its own plane: (along the body, out along the span); a fan from the root
WING = [(1.2, 0), (1.9, 4.5), (2.3, 7.0), (1.5, 10.0), (0.4, 7.2), (-0.6, 10.4), (-1.0, 6.4),
        (-2.8, 8.6), (-2.0, 4.6), (-3.4, 3.4), (-2.6, 0)]          # deep scallops between fingers
WRIST = (1.9, 4.5)
FINGER_TIPS = [(1.5, 9.8), (-0.6, 10.2), (-2.7, 8.4)]


def build_wing(side):
    """A wing joint pair at the shoulder: roll (wingbeat) -> sweep (spread / fold) -> membrane."""
    shoulder = (0.9, side * 1.5, 0.9)
    pt = lambda x, s: Vector((shoulder[0] + x, shoulder[1] + side * s, shoulder[2]))    # noqa: E731
    bm = bmesh.new()
    root = bm.verts.new(pt(-0.7, 0))
    ring = [bm.verts.new(pt(x, s)) for x, s in WING]
    for a, b in zip(ring, ring[1:]):
        bm.faces.new((root, a, b))
    me = bpy.data.meshes.new("wing")
    bm.to_mesh(me)
    wing = bpy.data.objects.new("wing", me)
    scene.collection.objects.link(wing)
    parts = [add(wing, "membrane" if side == NEAR else "membrane_far")]
    parts.append(tube(pt(1.2, 0), pt(*WRIST), 0.4, 0.3, "bone"))                       # forearm
    for tip in FINGER_TIPS:
        parts.append(tube(pt(*WRIST), pt(*tip), 0.45, 0.2, "bone"))                    # fingers
    parts.append(tube(pt(*WRIST), pt(WRIST[0] + 0.9, WRIST[1] + 0.3), 0.3, 0.02, "claw", 4))  # thumb claw
    roll = empty(shoulder)
    sweep = empty(shoulder)
    parent_to(parts, sweep)
    parent_to([sweep], roll)
    return roll, sweep


WINGS = {side: build_wing(side) for side in (NEAR, FAR)}
YAW, TILT = -60, 0           # nose turned toward the viewer, so the wings spread across the screen
VIEW_ELEVATION = 32
bat = empty()
parent_to(body + EYES + [WINGS[s][0] for s in WINGS], bat)
view = empty()                # we look at the bat a little from above, so the membranes show
parent_to([bat], view)
view.rotation_euler.x = math.radians(VIEW_ELEVATION)


def pose(p):
    """p: roll (wingbeat, 90 = wings straight up, 0 = level, negative = down), sweep (degrees
    swept back in the wing plane), fold (span shrink when folded), pitch (nose down +), roll_body,
    x / z (body offset), eyes, then either ground=True (rest on the cell floor) or hang=True
    (feet gripping the cell's top centre)."""
    for side, (roll, sweep) in WINGS.items():
        roll.rotation_euler.x = math.radians(side * p.get("roll", 0))
        sweep.rotation_euler.z = math.radians(side * p.get("sweep", 0))
        f = p.get("fold", 1.0)
        sweep.scale = (1.0, f, 1.0)
    bat.rotation_euler = (math.radians(TILT + p.get("roll_body", 0)), math.radians(p.get("pitch", 0)),
                          math.radians(YAW))
    bat.location = (p.get("x", 0.0), 0, p.get("z", 0.0))
    for e in EYES:
        e.hide_render = not p.get("eyes", True)
    bpy.context.view_layer.update()
    if p.get("hang"):
        feet = bat.matrix_world @ FEET_TIP
        bat.location += Vector((0 - feet.x, 0, CELL / 2 - 1.2 - feet.z))
    if p.get("ground"):
        low = min((o.matrix_world @ v.co).z for o in MESHES if not o.hide_render for v in o.data.vertices)
        bat.location.z += -CELL / 2 + 1.2 - low
    bpy.context.view_layer.update()


ANIMS = {}
# fly: one full wingbeat in 6 frames; the body lifts on the downstroke, wings sweep back rising
ANIMS["fly"] = [{"roll": 15 + 55 * math.cos(2 * math.pi * i / 6), "sweep": 10 - 12 * math.sin(2 * math.pi * i / 6),
                 "z": -0.7 * math.cos(2 * math.pi * i / 6), "pitch": 4 * math.sin(2 * math.pi * i / 6)}
                for i in range(6)]
# dive: nose down, wings swept hard back
ANIMS["dive"] = [{"pitch": 35, "roll": 60, "sweep": 70, "fold": 0.8},
                 {"pitch": 40, "roll": 50, "sweep": 80, "fold": 0.75, "z": -0.5}]
# hang: upside down from the ceiling, wings folded round the body like a cloak, swaying
ANIMS["hang"] = [{"pitch": 90 + s, "roll": 80, "sweep": 160, "fold": 0.55, "hang": True} for s in (-5, 5)]
# die: knocked tumbling with the wings crumpled, then lying on its back on the floor, eyes out
ANIMS["die"] = [{"roll_body": 140, "pitch": 30, "roll": -20, "sweep": 45, "fold": 0.8},
                {"roll_body": 180, "pitch": 6, "roll": -40, "sweep": 30, "fold": 0.85, "ground": True, "eyes": False}]

ORDER = ["fly", "dive", "hang", "die"]
for name in ORDER:
    for i, p in enumerate(ANIMS[name]):
        pose(p)
        for mode in PASSES:
            set_mode(mode)
            scene.render.filepath = os.path.join(OUT, f"{name}_{i}_{mode}.png")
            bpy.ops.render.render(write_still=True)
print("BAT_DONE", OUT)
