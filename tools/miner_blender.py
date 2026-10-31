"""Builds a low-poly miner in Blender, poses it, and renders sprite frames (side view).

Run headless:
  blender -b --factory-startup -P tools/miner_blender.py -- <out_dir>
Each frame is rendered twice: flat colours (albedo) and white clay (lighting).
tools/miner_sheet.py combines them into stepped pixel-art shading with outlines.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/miner"
os.makedirs(OUT, exist_ok=True)
CELL = 80          # sprite cell size in px
ORTHO = 3.625      # world units visible in a cell (character is ~1.8 tall -> ~40 px)

COLORS = {
    "helmet": "#e8b13a", "helmet_dark": "#a87418", "lamp": "#fff6c0", "skin": "#d99a74",
    "coat": "#2f5368", "coat_far": "#223d4f", "scarf": "#b8322a", "pants": "#4a3a2e",
    "pants_far": "#36291f", "boot": "#2a1f18", "glove": "#5a4130", "handle": "#7a5636",
    "iron": "#9aa3b2", "belt": "#3a2a1c", "eye": "#140c10", "pack": "#5b4a36",
}

# ---------------------------------------------------------------- scene setup
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 24
scene.cycles.use_denoising = False
scene.cycles.filter_width = 0.01           # no anti-aliasing: crisp pixels
scene.render.film_transparent = True
scene.render.resolution_x = CELL
scene.render.resolution_y = CELL
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
cam_data.ortho_scale = ORTHO
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
cam.location = (0, -10, 1.2)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam

sun_data = bpy.data.lights.new("Sun", "SUN")
sun_data.energy = 1.4
sun_data.angle = math.radians(2)
sun = bpy.data.objects.new("Sun", sun_data)
scene.collection.objects.link(sun)
light_dir = Vector((0.55, 0.75, -0.8)).normalized()      # from upper-left, in front
sun.rotation_euler = (-light_dir).to_track_quat("Z", "Y").to_euler()

# ---------------------------------------------------------------- materials (albedo / clay switch)
MATS = {}


def hex_rgb(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return [x ** 2.2 for x in c] + [1.0]   # sRGB -> linear


def material(name):
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = hex_rgb(COLORS[name])
    em.inputs["Strength"].default_value = 1.0
    df = nt.nodes.new("ShaderNodeBsdfDiffuse")
    df.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
    if name == "lamp":   # lamp stays bright in the clay pass too
        df = nt.nodes.new("ShaderNodeEmission")
        df.inputs["Color"].default_value = (1, 1, 1, 1)
        df.inputs["Strength"].default_value = 3.0
    MATS[name] = (m, nt, out, em, df)
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    return MATS[name]


def set_mode(clay):
    for m, nt, out, em, df in MATS.values():
        for l in list(out.inputs["Surface"].links):
            nt.links.remove(l)
        nt.links.new((df if clay else em).outputs[0], out.inputs["Surface"])
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0 if clay else 0.0
    sun_data.energy = 1.4 if clay else 0.0


# ---------------------------------------------------------------- modelling helpers
def finish(obj, mat, smooth=False):
    obj.data.materials.append(material(mat)[0])
    if smooth:
        for p in obj.data.polygons:
            p.use_smooth = True
    return obj


def joint(name, parent, loc):
    e = bpy.data.objects.new(name, None)
    scene.collection.objects.link(e)
    e.location = loc
    e.rotation_mode = "XYZ"
    if parent:
        e.parent = parent
        e.matrix_parent_inverse = parent.matrix_world.inverted()
    bpy.context.view_layer.update()
    return e


def attach(obj, parent):
    bpy.context.view_layer.update()
    obj.parent = parent
    obj.matrix_parent_inverse = parent.matrix_world.inverted()


def cyl(name, loc, radius, depth, mat, parent, verts=10, scale=(1, 1, 1), rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius, depth=depth, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    finish(o, mat)
    attach(o, parent)
    return o


def box(name, loc, size, mat, parent, bevel=0.0, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    if bevel:
        bpy.ops.object.transform_apply(scale=True)
        mod = o.modifiers.new("b", "BEVEL")
        mod.width = bevel
        mod.segments = 2
    finish(o, mat)
    attach(o, parent)
    return o


def ball(name, loc, radius, mat, parent, scale=(1, 1, 1)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=8, radius=radius, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    finish(o, mat, smooth=True)
    attach(o, parent)
    return o


# ---------------------------------------------------------------- the miner
# camera looks along +Y, so -Y is the near side; the miner faces +X
NEAR, FAR = -1, 1
root = joint("root", None, (0, 0, 0))
hips = joint("hips", root, (0, 0, 0.93))
torso = joint("torso", hips, (0, 0, 0.95))
box("belly", (0.0, 0, 1.08), (0.30, 0.26, 0.26), "coat", torso, bevel=0.05)
box("chest", (0.01, 0, 1.30), (0.34, 0.30, 0.30), "coat", torso, bevel=0.06)
box("belt", (0.0, 0, 0.96), (0.31, 0.27, 0.06), "belt", torso)
box("pack", (-0.22, 0, 1.24), (0.14, 0.26, 0.36), "pack", torso, bevel=0.03)
cyl("scarf", (0.0, 0, 1.47), 0.13, 0.08, "scarf", torso, verts=10)
box("scarf_tail", (-0.15, NEAR * 0.05, 1.38), (0.12, 0.05, 0.16), "scarf", torso, rot=(0, math.radians(-25), 0))

neck = joint("neck", torso, (0.02, 0, 1.48))
ball("head", (0.03, 0, 1.62), 0.15, "skin", neck)
ball("eye", (0.16, NEAR * 0.05, 1.63), 0.025, "eye", neck)
ball("helmet", (0.02, 0, 1.69), 0.17, "helmet", neck, scale=(1.05, 1.0, 0.75))
cyl("brim", (0.04, 0, 1.64), 0.2, 0.03, "helmet_dark", neck, verts=14, scale=(1.15, 0.95, 1))
cyl("lamp_base", (0.17, 0, 1.71), 0.05, 0.05, "helmet_dark", neck, verts=8, rot=(0, math.radians(90), 0))
cyl("lamp", (0.2, 0, 1.71), 0.04, 0.02, "lamp", neck, verts=8, rot=(0, math.radians(90), 0))


def arm(side, coat):
    sh = joint(f"shoulder_{side}", torso, (0.02, side * 0.19, 1.36))
    cyl(f"upper_{side}", (0.02, side * 0.19, 1.22), 0.065, 0.28, coat, sh)
    el = joint(f"elbow_{side}", sh, (0.02, side * 0.19, 1.08))
    cyl(f"fore_{side}", (0.02, side * 0.19, 0.95), 0.058, 0.26, coat, el)
    hand = joint(f"hand_{side}", el, (0.02, side * 0.19, 0.82))
    ball(f"glove_{side}", (0.02, side * 0.19, 0.81), 0.06, "glove", hand)
    return sh, el, hand


def leg(side, pants):
    th = joint(f"thigh_{side}", hips, (0, side * 0.09, 0.9))
    cyl(f"thighm_{side}", (0, side * 0.09, 0.69), 0.085, 0.42, pants, th)
    kn = joint(f"knee_{side}", th, (0, side * 0.09, 0.48))
    cyl(f"shin_{side}", (0, side * 0.09, 0.29), 0.075, 0.38, pants, kn)
    an = joint(f"ankle_{side}", kn, (0, side * 0.09, 0.09))
    box(f"boot_{side}", (0.05, side * 0.09, 0.05), (0.24, 0.13, 0.11), "boot", an, bevel=0.03)
    return th, kn


arm(FAR, "coat_far")
arm(NEAR, "coat")
leg(FAR, "pants_far")
leg(NEAR, "pants")

# pickaxe held in the near hand: handle continues the forearm line, pick head at the end
hand = bpy.data.objects[f"hand_{NEAR}"]
hx, hz = 0.02, 0.82
cyl("handle", (hx, NEAR * 0.19, hz - 0.22), 0.025, 0.62, "handle", hand, verts=6)
box("pick_a", (hx + 0.13, NEAR * 0.19, hz - 0.52), (0.28, 0.05, 0.06), "iron", hand, rot=(0, math.radians(-20), 0))
box("pick_b", (hx - 0.13, NEAR * 0.19, hz - 0.52), (0.28, 0.05, 0.06), "iron", hand, rot=(0, math.radians(20), 0))
cyl("pick_hub", (hx, NEAR * 0.19, hz - 0.51), 0.05, 0.08, "iron", hand, verts=8, rot=(math.radians(90), 0, 0))

J = {o.name: o for o in bpy.data.objects if o.type == "EMPTY"}


def pose(p):
    """p: joint -> forward swing in degrees (0 = hanging down). Extra keys: bob, lean."""
    for name, e in J.items():
        e.rotation_euler = (0, 0, 0)
    J["hips"].location.z = 0.93 + p.get("bob", 0.0)
    J["torso"].rotation_euler.y = math.radians(-p.get("lean", 0.0))
    J["neck"].rotation_euler.y = math.radians(-p.get("look", 0.0))
    for k, v in p.items():
        if k in J and k not in ("hips", "torso", "neck"):
            J[k].rotation_euler.y = math.radians(-v)


def shoulder_pair(a, f=None):
    f = a - 12 if f is None else f
    return {f"shoulder_{NEAR}": a, f"shoulder_{FAR}": f, f"elbow_{NEAR}": 12, f"elbow_{FAR}": 18}


ANIMS = {}
# idle: slow breathing
ANIMS["idle"] = [dict(bob=-0.01 * math.sin(i / 4 * 2 * math.pi), **{
    f"shoulder_{NEAR}": 8 + 3 * math.sin(i / 4 * 2 * math.pi), f"shoulder_{FAR}": -6, f"elbow_{NEAR}": 20,
    f"elbow_{FAR}": 15, f"thigh_{NEAR}": 4, f"thigh_{FAR}": -4, "lean": 3}) for i in range(4)]
# run: 8 frames
run = []
for i in range(8):
    ph = i / 8 * 2 * math.pi
    s = math.sin(ph)
    run.append({
        "bob": 0.04 * abs(math.cos(ph)) - 0.02, "lean": 12,
        f"thigh_{NEAR}": 38 * s, f"thigh_{FAR}": -38 * s,
        f"knee_{NEAR}": -(15 + 55 * max(0, -math.cos(ph + 0.6))),
        f"knee_{FAR}": -(15 + 55 * max(0, math.cos(ph + 0.6))),
        f"shoulder_{NEAR}": -34 * s + 10, f"shoulder_{FAR}": 34 * s, f"elbow_{NEAR}": 55, f"elbow_{FAR}": 45,
    })
ANIMS["run"] = run
ANIMS["jump"] = [{"lean": 6, f"thigh_{NEAR}": 45, f"knee_{NEAR}": -70, f"thigh_{FAR}": 10, f"knee_{FAR}": -40,
                  f"shoulder_{NEAR}": 120, f"elbow_{NEAR}": 30, f"shoulder_{FAR}": 140, f"elbow_{FAR}": 20}]
ANIMS["fall"] = [{"lean": -4, f"thigh_{NEAR}": 20, f"knee_{NEAR}": -15, f"thigh_{FAR}": -15, f"knee_{FAR}": -25,
                  f"shoulder_{NEAR}": 70, f"elbow_{NEAR}": 10, f"shoulder_{FAR}": 100, f"elbow_{FAR}": 10}]
# Swings: 8 frames each = lift, wind-up, peak, peak hold (anticipation), strike (fast),
# IMPACT (frame 5, the game breaks rock here), recoil, settle. Frame 7 flows back into 0.
stance = {f"thigh_{NEAR}": 18, f"knee_{NEAR}": -18, f"thigh_{FAR}": -16, f"knee_{FAR}": -8}
braced = {f"thigh_{NEAR}": 30, f"knee_{NEAR}": -30, f"thigh_{FAR}": -22, f"knee_{FAR}": -6, "bob": -0.04}


def swing(frames, legs_at):
    """frames: (shoulder, lean, look, extra); legs_at(i) gives the leg pose per frame."""
    out = []
    for i, (a, l, lk, extra) in enumerate(frames):
        p = dict(lean=l, look=lk, **legs_at(i), **shoulder_pair(a))
        p.update(extra)
        out.append(p)
    return out


# side: pick goes back over the shoulder, then whips forward into the wall at waist height
ANIMS["dig_side"] = swing(
    [(110, 4, 0, {}), (160, -4, 5, {}), (188, -9, 8, {}), (194, -11, 8, {}),
     (125, 8, 0, {}), (62, 17, -5, {f"elbow_{NEAR}": 0}), (74, 14, -3, {}), (96, 8, 0, {})],
    lambda i: braced if 4 <= i <= 6 else stance)

# down: lean back with the pick high overhead, then fold forward and slam it into the
# ground right in front of the boots (deep crouch on impact)
def down_legs(i):
    k = [0.3, 0.1, 0.0, 0.0, 0.6, 1.0, 0.9, 0.6][i]
    return {f"thigh_{NEAR}": 10 + 35 * k, f"knee_{NEAR}": -10 - 50 * k,
            f"thigh_{FAR}": -8 + 20 * k, f"knee_{FAR}": -10 - 45 * k, "bob": 0.01 - 0.11 * k}


ANIMS["dig_down"] = swing(
    [(70, 12, -10, {}), (150, 0, 5, {}), (192, -8, 10, {}), (200, -10, 10, {}),
     (90, 18, -15, {}), (-16, 34, -30, {f"elbow_{NEAR}": 0, f"elbow_{FAR}": 6}),
     (-4, 30, -25, {}), (25, 22, -18, {})],
    down_legs)

# up: pick drops low behind the hip, then stabs upward over the head
def up_legs(i):
    k = [0.3, 0.7, 1.0, 1.0, 0.4, 0.0, 0.1, 0.2][i]
    return {f"thigh_{NEAR}": 12 + 25 * k, f"knee_{NEAR}": -12 - 35 * k,
            f"thigh_{FAR}": -12 + 10 * k, f"knee_{FAR}": -8 - 30 * k, "bob": 0.02 - 0.08 * k}


ANIMS["dig_up"] = swing(
    [(40, 4, 10, {}), (-10, 8, 0, {}), (-38, 10, -5, {}), (-44, 11, -5, {}),
     (90, 0, 20, {}), (178, -12, 35, {f"elbow_{NEAR}": 0}), (166, -10, 32, {}), (125, -4, 22, {})],
    up_legs)

ORDER = ["idle", "run", "jump", "fall", "dig_side", "dig_down", "dig_up"]
for row, name in enumerate(ORDER):
    for i, p in enumerate(ANIMS[name]):
        pose(p)
        bpy.context.view_layer.update()
        for clay in (False, True):
            set_mode(clay)
            scene.render.filepath = os.path.join(OUT, f"{name}_{i}_{'clay' if clay else 'flat'}.png")
            bpy.ops.render.render(write_still=True)
print("MINER_DONE", OUT)
