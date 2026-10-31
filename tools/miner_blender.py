"""Builds the miner in Blender, poses it, and renders sprite frames (side view).

Run headless:
  blender -b --factory-startup -P tools/miner_blender.py -- <out_dir> [anim,anim,...]
Each frame is rendered three times: flat colours (albedo), white clay (lighting) and camera
normals. tools/miner_sheet.py turns them into pixel art with outlines + a normal map sheet.

The model is detailed for its ~40 px: helmet with goggles and a headlamp, a face with nose,
brow and stubble, coat with collar, lining and rolled sleeves, belt pouches, a backpack with
a rope coil and a little lantern, laced boots and a double-headed pickaxe with a wrapped grip.
Scarf tails, coat tail, backpack and lantern are on their own joints for secondary motion.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_pass import PASSES, normal_shader, set_view  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "/tmp/miner"
ONLY = set(ARGS[1].split(",")) if len(ARGS) > 1 else None   # optional: render just these anims
os.makedirs(OUT, exist_ok=True)
CELL = 80          # sprite cell size in px
ORTHO = 3.625      # world units visible in a cell (character is ~1.8 tall -> ~40 px)

COLORS = {
    # helmet and head
    "helmet": "#e8b13a", "helmet_dark": "#a87418", "lamp": "#fff6c0", "lamp_body": "#3a3530",
    "strap": "#2e2018", "brass": "#a88a4a", "goggle": "#7fc4d6", "skin": "#d99a74",
    "skin_dark": "#b9785a", "eye": "#140c10", "brow": "#4a2e1e", "beard": "#5e3e2a", "hair": "#3e2a1c",
    # coat, scarf, arms
    "coat": "#2f5368", "coat_far": "#223d4f", "coat_collar": "#3d6a84", "coat_lining": "#16242e",
    "scarf": "#b8322a", "scarf_dark": "#86231e", "arm_skin": "#c98a64", "arm_skin_far": "#a06a4c",
    "glove": "#5a4130", "glove_cuff": "#71533a", "button": "#c9a227",
    # belt, legs, boots
    "belt": "#3a2a1c", "buckle": "#c9a227", "pouch": "#6b4f36", "pouch_dark": "#4e3a28",
    "pants": "#4a3a2e", "pants_far": "#36291f", "patch": "#5e4a38", "boot": "#2a1f18",
    "sole": "#120d0a", "lace": "#b8a27a",
    # backpack
    "pack": "#5b4a36", "pack_dark": "#46382a", "rope": "#a8875a", "lantern": "#ffb347",
    "iron_dark": "#4a4e57",
    # pickaxe
    "handle": "#7a5636", "grip": "#8a6a48", "grip_dark": "#4e3828", "iron": "#9aa3b2",
    "steel_tip": "#c9ccd1",
}
UNLIT = {"lamp", "lantern"}   # stay at full brightness in the clay pass too

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

# ---------------------------------------------------------------- materials (albedo / clay / normal)
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
    if name in UNLIT:
        df = nt.nodes.new("ShaderNodeEmission")
        df.inputs["Color"].default_value = (1, 1, 1, 1)
        df.inputs["Strength"].default_value = 3.0
    else:
        df = nt.nodes.new("ShaderNodeBsdfDiffuse")
        df.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
    MATS[name] = (m, nt, out, em, df, normal_shader(nt))
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    return MATS[name]


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
    finish(o, mat, smooth=verts > 8)
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


def cone(name, loc, radius, depth, mat, parent, rot=(0, 0, 0)):
    """Cone with its point along +Z (before rotating)."""
    bpy.ops.mesh.primitive_cone_add(vertices=6, radius1=radius, radius2=0, depth=depth, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    finish(o, mat)
    attach(o, parent)
    return o


def ring(name, loc, major, minor, mat, parent, scale=(1, 1, 1), rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_torus_add(major_radius=major, minor_radius=minor, major_segments=14,
                                     minor_segments=5, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    finish(o, mat, smooth=True)
    attach(o, parent)
    return o


# ---------------------------------------------------------------- the miner
# camera looks along +Y, so -Y is the near side; the miner faces +X
NEAR, FAR = -1, 1
R90 = math.radians(90)
root = joint("root", None, (0, 0, 0))
hips = joint("hips", root, (0, 0, 0.93))
torso = joint("torso", hips, (0, 0, 0.95))

# coat: belly and chest, hem below the belt, collar, lining showing at the front edge, buttons
box("belly", (0.0, 0, 1.05), (0.30, 0.26, 0.32), "coat", torso, bevel=0.05)
box("chest", (0.01, 0, 1.30), (0.34, 0.30, 0.30), "coat", torso, bevel=0.06)
box("lining", (0.17, 0, 1.17), (0.02, 0.2, 0.42), "coat_lining", torso)
for z in (1.33, 1.2):
    ball("button", (0.185, NEAR * 0.06, z), 0.022, "button", torso)
box("collar", (-0.06, 0, 1.49), (0.14, 0.3, 0.12), "coat_collar", torso, bevel=0.03)
box("belt", (0.0, 0, 0.94), (0.31, 0.27, 0.06), "belt", torso)
box("buckle", (0.16, 0, 0.94), (0.03, 0.09, 0.07), "buckle", torso)
box("pouch_a", (0.07, NEAR * 0.15, 0.9), (0.1, 0.05, 0.11), "pouch", torso, bevel=0.015)
box("pouch_a_lid", (0.07, NEAR * 0.17, 0.94), (0.1, 0.02, 0.04), "pouch_dark", torso)
box("pouch_b", (-0.09, NEAR * 0.15, 0.9), (0.08, 0.05, 0.09), "pouch_dark", torso, bevel=0.015)
box("strap", (0.06, NEAR * 0.15, 1.3), (0.05, 0.02, 0.3), "pack_dark", torso, rot=(0, math.radians(-8), 0))
# scarf: a wrap round the neck, a knot at the back and two tails on their own joints
cyl("scarf", (0.0, 0, 1.47), 0.135, 0.09, "scarf", torso, verts=12)
ball("knot", (-0.13, 0, 1.45), 0.055, "scarf_dark", torso, scale=(1, 3.2, 1))
for side, mat, ln in ((NEAR, "scarf", 1.0), (FAR, "scarf_dark", 0.85)):
    y = side * 0.17          # outside the backpack's width so the tails show over it
    t1 = joint(f"scarf_{'n' if side == NEAR else 'f'}1", torso, (-0.14, y, 1.45))
    box(f"scarf_t1_{side}", (-0.14, y, 1.45 - 0.08 * ln), (0.085, 0.03, 0.17 * ln), mat, t1)
    t2 = joint(f"scarf_{'n' if side == NEAR else 'f'}2", t1, (-0.14, y, 1.45 - 0.16 * ln))
    box(f"scarf_t2_{side}", (-0.14, y, 1.45 - 0.16 * ln - 0.07 * ln), (0.075, 0.03, 0.15 * ln), mat, t2)
    box(f"scarf_fringe_{side}", (-0.14, y, 1.45 - 0.31 * ln), (0.08, 0.035, 0.025), "scarf_dark", t2)
# coat tail flap at the back (dark lining along its hem)
coattail = joint("coattail", torso, (-0.12, 0, 0.92))
box("coattail_m", (-0.13, 0, 0.82), (0.07, 0.26, 0.2), "coat", coattail, bevel=0.02)
box("coattail_hem", (-0.13, 0, 0.725), (0.075, 0.265, 0.03), "coat_lining", coattail)

# backpack on its own joint (it bounces), rope coil on its side, lantern swinging under it
pack = joint("pack", torso, (-0.17, 0, 1.42))
box("pack_m", (-0.25, 0, 1.22), (0.16, 0.28, 0.36), "pack", pack, bevel=0.035)
box("pack_lid", (-0.25, 0, 1.39), (0.19, 0.3, 0.07), "pack_dark", pack, bevel=0.02)
box("pack_pocket", (-0.25, NEAR * 0.15, 1.14), (0.11, 0.04, 0.12), "pack_dark", pack, bevel=0.015)
ring("rope_coil", (-0.25, NEAR * 0.17, 1.2), 0.058, 0.021, "rope", pack, rot=(R90, 0, 0))
ring("rope_coil2", (-0.25, NEAR * 0.185, 1.2), 0.03, 0.018, "rope", pack, rot=(R90, 0, 0))
lantern = joint("lantern", pack, (-0.32, NEAR * 0.05, 1.05))
ring("lantern_hook", (-0.32, NEAR * 0.05, 1.02), 0.025, 0.008, "iron_dark", lantern, rot=(R90, 0, 0))
box("lantern_cap", (-0.32, NEAR * 0.05, 0.985), (0.07, 0.07, 0.025), "iron_dark", lantern)
box("lantern_glass", (-0.32, NEAR * 0.05, 0.935), (0.055, 0.055, 0.075), "lantern", lantern)
box("lantern_base", (-0.32, NEAR * 0.05, 0.89), (0.07, 0.07, 0.025), "iron_dark", lantern)

# head: face with nose, eye, brow, ear, stubble; hair at the nape
neck = joint("neck", torso, (0.02, 0, 1.48))
ball("head", (0.03, 0, 1.62), 0.15, "skin", neck)
ball("nose", (0.175, NEAR * 0.02, 1.6), 0.035, "skin_dark", neck)
ball("eye", (0.16, NEAR * 0.075, 1.625), 0.03, "eye", neck)
box("brow", (0.145, NEAR * 0.07, 1.675), (0.065, 0.03, 0.022), "brow", neck, rot=(0, math.radians(-10), 0))
ball("beard", (0.06, 0, 1.51), 0.1, "beard", neck, scale=(1.1, 1.3, 0.6))
ball("ear", (0.0, NEAR * 0.14, 1.61), 0.035, "skin_dark", neck)
ball("hair", (-0.09, 0, 1.6), 0.1, "hair", neck, scale=(0.9, 1.4, 1.0))
# helmet: dome, crest, brim, goggles strapped round it, headlamp housing
ball("helmet", (0.02, 0, 1.69), 0.17, "helmet", neck, scale=(1.05, 1.0, 0.75))
box("crest", (0.02, 0, 1.81), (0.3, 0.045, 0.04), "helmet_dark", neck, bevel=0.01)
cyl("brim", (0.04, 0, 1.64), 0.2, 0.03, "helmet_dark", neck, verts=14, scale=(1.15, 0.95, 1))
ring("goggle_strap", (0.02, 0, 1.765), 0.14, 0.018, "strap", neck, scale=(1.05, 1.0, 1.0))
for side in (NEAR, FAR):
    cyl(f"goggle_rim_{side}", (0.135, side * 0.065, 1.775), 0.042, 0.04, "brass", neck, verts=10,
        rot=(0, math.radians(65), 0))
    cyl(f"goggle_lens_{side}", (0.15, side * 0.065, 1.782), 0.03, 0.03, "goggle", neck, verts=10,
        rot=(0, math.radians(65), 0))
box("lamp_bracket", (0.17, 0, 1.68), (0.05, 0.06, 0.06), "lamp_body", neck)
cyl("lamp_base", (0.19, 0, 1.71), 0.058, 0.07, "lamp_body", neck, verts=10, rot=(0, R90, 0))
cyl("lamp", (0.23, 0, 1.71), 0.044, 0.02, "lamp", neck, verts=10, rot=(0, R90, 0))


def arm(side, coat, skin):
    sh = joint(f"shoulder_{side}", torso, (0.02, side * 0.19, 1.36))
    cyl(f"upper_{side}", (0.02, side * 0.19, 1.22), 0.068, 0.28, coat, sh)
    el = joint(f"elbow_{side}", sh, (0.02, side * 0.19, 1.08))
    cyl(f"cuff_{side}", (0.02, side * 0.19, 1.065), 0.074, 0.075, "coat_lining", el)      # rolled sleeve
    cyl(f"fore_{side}", (0.02, side * 0.19, 0.95), 0.052, 0.2, skin, el)
    hand = joint(f"hand_{side}", el, (0.02, side * 0.19, 0.82))
    cyl(f"glove_cuff_{side}", (0.02, side * 0.19, 0.86), 0.062, 0.06, "glove_cuff", hand)
    ball(f"glove_{side}", (0.02, side * 0.19, 0.81), 0.062, "glove", hand)
    return sh, el, hand


def leg(side, pants):
    th = joint(f"thigh_{side}", hips, (0, side * 0.09, 0.9))
    cyl(f"thighm_{side}", (0, side * 0.09, 0.69), 0.088, 0.42, pants, th)
    kn = joint(f"knee_{side}", th, (0, side * 0.09, 0.48))
    cyl(f"shin_{side}", (0, side * 0.09, 0.31), 0.077, 0.34, pants, kn)
    if side == NEAR:
        box("knee_patch", (0.06, side * 0.11, 0.46), (0.06, 0.06, 0.1), "patch", kn)
    an = joint(f"ankle_{side}", kn, (0, side * 0.09, 0.09))
    cyl(f"boot_shaft_{side}", (0, side * 0.09, 0.15), 0.087, 0.14, "boot", an)
    box(f"boot_{side}", (0.05, side * 0.09, 0.07), (0.24, 0.135, 0.1), "boot", an, bevel=0.035)
    box(f"sole_{side}", (0.055, side * 0.09, 0.0175), (0.27, 0.145, 0.035), "sole", an, bevel=0.01)
    for k in range(2):
        box(f"lace_{side}_{k}", (0.09 - k * 0.05, side * 0.09, 0.122 + k * 0.025), (0.035, 0.14, 0.02), "lace", an)
    return th, kn


arm(FAR, "coat_far", "arm_skin_far")
arm(NEAR, "coat", "arm_skin")
leg(FAR, "pants_far")
leg(NEAR, "pants")


def pickaxe(parent, hx, y, hz, prefix=""):
    """Pickaxe gripped at (hx, y, hz): the handle hangs straight down, a double-pointed head at
    the end with both picks curving back toward the handle, a wrapped grip under the hand."""
    parts = [cyl(prefix + "handle", (hx, y, hz - 0.22), 0.026, 0.62, "handle", parent, verts=8)]
    for k in range(3):
        parts.append(cyl(prefix + f"grip{k}", (hx, y, hz - 0.07 - k * 0.045), 0.032, 0.04,
                         "grip" if k % 2 == 0 else "grip_dark", parent, verts=8))
    parts.append(cyl(prefix + "ferrule", (hx, y, hz - 0.46), 0.033, 0.04, "iron_dark", parent, verts=8))
    parts.append(box(prefix + "hub", (hx, y, hz - 0.52), (0.09, 0.07, 0.1), "iron", parent, bevel=0.015))
    for s in (1, -1):
        parts.append(box(prefix + "blade1", (hx + s * 0.1, y, hz - 0.515), (0.12, 0.055, 0.066), "iron", parent,
                         rot=(0, math.radians(-s * 10), 0)))
        parts.append(box(prefix + "blade2", (hx + s * 0.195, y, hz - 0.495), (0.1, 0.045, 0.05), "iron", parent,
                         rot=(0, math.radians(-s * 24), 0)))
        tilt = math.atan2(s * math.cos(math.radians(38)), math.sin(math.radians(38)))
        parts.append(cone(prefix + "tip", (hx + s * 0.27, y, hz - 0.462), 0.026, 0.09, "steel_tip", parent,
                          rot=(0, tilt, 0)))
    return parts


# pickaxe held in the near hand: handle continues the forearm line, pick head at the end
HAND_PICK = pickaxe(bpy.data.objects[f"hand_{NEAR}"], 0.02, NEAR * 0.19, 0.82)

J = {o.name: o for o in bpy.data.objects if o.type == "EMPTY"}

# a second pickaxe strapped across the pack, shown instead of the hand one while climbing
# (built after J so pose() leaves its joint alone): head up behind the shoulder
stow = joint("pick_stow", torso, (0.02, 0, 0.82))
BACK_PICK = pickaxe(stow, 0.02, 0, 0.82, "stow_")
stow.location = (-0.12, 0, 0.92)
stow.rotation_euler.y = math.radians(-205)


def pose(p):
    """p: joint -> forward swing in degrees (0 = hanging down). Extra keys: bob, lean, look, stowed,
    and for whole-body moves: spin (turns the whole miner about his middle), ground (drop him
    until his lowest point touches the floor), centre (keep his bounding box centred on x = 0),
    float_z (put his bounding box centre at this height instead of grounding him).

    Every angle turns counter-clockwise on screen, so a positive limb swings forward but a
    positive lean / look / spin tips the torso / head / body back (a forward roll is negative)."""
    for name, e in J.items():
        e.rotation_euler = (0, 0, 0)
    for o in HAND_PICK:
        o.hide_render = p.get("stowed", False)
    for o in BACK_PICK:
        o.hide_render = not p.get("stowed", False)
    J["hips"].location.z = 0.93 + p.get("bob", 0.0)
    J["torso"].rotation_euler.y = math.radians(-p.get("lean", 0.0))
    J["neck"].rotation_euler.y = math.radians(-p.get("look", 0.0))
    for k, v in p.items():
        if k in J and k not in ("hips", "torso", "neck"):
            J[k].rotation_euler.y = math.radians(-v)
    root = J["root"]
    root.location = (0, 0, 0)
    if p.get("spin"):                       # turn about the body's middle, not the feet
        root.rotation_euler.y = math.radians(-p["spin"])
        mid = Vector((0, 0, 0.9))
        root.location = mid - root.rotation_euler.to_matrix() @ mid
    if p.get("ground") or p.get("centre") or "float_z" in p:
        bpy.context.view_layer.update()
        pts = [o.matrix_world @ v.co for o in bpy.data.objects
               if o.type == "MESH" and not o.hide_render for v in o.data.vertices]
        xs, zs = [v.x for v in pts], [v.z for v in pts]
        if p.get("centre"):
            root.location.x -= (min(xs) + max(xs)) / 2
        if p.get("ground"):
            root.location.z -= min(zs)
        if "float_z" in p:
            root.location.z += p["float_z"] - (min(zs) + max(zs)) / 2


def shoulder_pair(a, f=None):
    f = a - 12 if f is None else f
    return {f"shoulder_{NEAR}": a, f"shoulder_{FAR}": f, f"elbow_{NEAR}": 12, f"elbow_{FAR}": 18}


# ---------------------------------------------------------------- pose helpers
UPPER, FORE = 0.28, 0.26      # shoulder->elbow, elbow->hand
THIGH, SHIN = 0.42, 0.39      # hip->knee, knee->ankle
ANKLE_H = 0.095               # ankle height above the sole


def P(**kw):
    """Pose dict with short keys: thigh_n / knee_f ... name the near / far joint."""
    side = {"_n": NEAR, "_f": FAR}
    return {(f"{k[:-2]}_{side[k[-2:]]}" if k[-2:] in side else k): v for k, v in kw.items()}


def rot(x, z, deg):
    """Rotate the offset (x, z) the way a joint set to `deg` turns it."""
    a = math.radians(deg)
    return x * math.cos(a) - z * math.sin(a), x * math.sin(a) + z * math.cos(a)


def two_bone(dx, dz, l1, l2, bend):
    """(first bone angle, joint bend) reaching offset (dx, dz). bend=+1 bends like an elbow."""
    d = max(min(math.hypot(dx, dz), l1 + l2 - 1e-4), abs(l1 - l2) + 1e-4)
    phi = math.degrees(math.atan2(dx, -dz))
    alpha = math.degrees(math.acos((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d)))
    inner = math.degrees(math.acos((l1 * l1 + l2 * l2 - d * d) / (2 * l1 * l2)))
    return phi - bend * alpha, bend * (180 - inner)


def reach(p, side, x, z):
    """Set one arm of pose p so its hand lands on the world point (x, z)."""
    pivot = 0.95 + p.get("bob", 0.0)                      # torso joint height
    sx, sz = rot(0.02, 1.36 - 0.95, p.get("lean", 0.0))   # shoulder around the torso joint
    a, el = two_bone(x - sx, z - (pivot + sz), UPPER, FORE, +1)
    p[f"shoulder_{side}"] = a - p.get("lean", 0.0)
    p[f"elbow_{side}"] = el
    return p


def grounded(p):
    """Drop the hips so the lower boot stands on the floor, with both soles kept flat."""
    drop = 0.0
    for side in (NEAR, FAR):
        a, k = p.get(f"thigh_{side}", 0), p.get(f"knee_{side}", 0)
        drop = max(drop, THIGH * math.cos(math.radians(a)) + SHIN * math.cos(math.radians(a + k)))
        p[f"ankle_{side}"] = -(a + k)
    p["bob"] = drop + ANKLE_H - 0.9
    return p


def wave(i, n, cycles=1.0, lag=0.0):
    return math.sin(2 * math.pi * cycles * i / n - lag)


def cloth(frames, scarf=(-25, 6), coat=(-4, 3), cycles=1.0, loop=True, sway=5.0):
    """Secondary motion, added on top of finished body poses: scarf tails, coat tail, backpack
    and lantern. scarf / coat = (angle on screen, flutter): 0 hangs down, -90 streams straight
    back, -160 up and back. Each piece trails the one before it by a phase lag, and the body's
    vertical motion drags them (rising pulls cloth down, dropping lifts it)."""
    n = len(frames)
    for i, p in enumerate(frames):
        prev = frames[i - 1] if (loop or i > 0) else p
        dz = p.get("bob", 0.0) - prev.get("bob", 0.0)
        lean = p.get("lean", 0.0)
        spin = p.get("spin", 0.0)           # cloth hangs in the world, so it undoes a body spin too
        drag = 300 * dz
        base, amp = scarf
        p["scarf_n1"] = base + amp * wave(i, n, cycles) + drag - lean - spin
        p["scarf_n2"] = 0.8 * amp * wave(i, n, cycles, 1.3) + 0.5 * drag
        p["scarf_f1"] = base - 10 + 0.7 * amp * wave(i, n, cycles, 0.9) + drag - lean - spin
        p["scarf_f2"] = 0.7 * amp * wave(i, n, cycles, 2.0) + 0.5 * drag
        cb, ca = coat
        p["coattail"] = cb + ca * wave(i, n, cycles, 0.6) + 0.6 * drag - 0.4 * lean - spin
        p["pack"] = max(-8.0, min(8.0, 150 * dz))
        p["lantern"] = -(lean + spin + p["pack"]) + sway * wave(i, n, cycles, 0.8) - 0.8 * drag
    return frames


ANIMS = {}
# idle: 8 frames of slow breathing, a small look up and back down, scarf drifting
look = [0, 0, 3, 7, 7, 4, -1, -1]
ANIMS["idle"] = cloth([P(bob=-0.012 * wave(i, 8), lean=3 + 1.2 * wave(i, 8), look=look[i],
                         shoulder_n=8 + 3 * wave(i, 8), shoulder_f=-6 + 2 * wave(i, 8, lag=0.5),
                         elbow_n=20, elbow_f=15, thigh_n=4, thigh_f=-4) for i in range(8)],
                      scarf=(-22, 5), coat=(-3, 2), sway=4)

# run: 12 frames, leaning into it, bobbing lowest on each foot strike
run = []
for i in range(12):
    ph = i / 12 * 2 * math.pi
    s = math.sin(ph)
    run.append(P(bob=0.05 * abs(math.cos(ph)) - 0.03, lean=-8 + 2 * math.cos(2 * ph), look=6,
                 thigh_n=40 * s, thigh_f=-40 * s,
                 knee_n=-(15 + 60 * max(0, -math.cos(ph + 0.6))),
                 knee_f=-(15 + 60 * max(0, math.cos(ph + 0.6))),
                 shoulder_n=-34 * s + 12, shoulder_f=34 * s, elbow_n=55, elbow_f=45))
ANIMS["run"] = cloth(run, scarf=(-80, 10), coat=(-40, 8), cycles=2, sway=10)

# Swings: 8 frames each = lift, wind-up, peak, peak hold (anticipation), strike (fast),
# IMPACT (frame 5, the game breaks rock here), recoil, settle. Frame 7 flows back into 0.
# The body poses are unchanged from the original sheet; only cloth motion is added.
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
ANIMS["dig_side"] = cloth(swing(
    [(110, 4, 0, {}), (160, -4, 5, {}), (188, -9, 8, {}), (194, -11, 8, {}),
     (125, 8, 0, {}), (62, 17, -5, {f"elbow_{NEAR}": 0}), (74, 14, -3, {}), (96, 8, 0, {})],
    lambda i: braced if 4 <= i <= 6 else stance), scarf=(-30, 12), coat=(-6, 5))


# down: lean back with the pick high overhead, then fold forward and slam it into the
# ground right in front of the boots (deep crouch on impact)
def down_legs(i):
    k = [0.3, 0.1, 0.0, 0.0, 0.6, 1.0, 0.9, 0.6][i]
    return {f"thigh_{NEAR}": 10 + 35 * k, f"knee_{NEAR}": -10 - 50 * k,
            f"thigh_{FAR}": -8 + 20 * k, f"knee_{FAR}": -10 - 45 * k, "bob": 0.01 - 0.11 * k}


ANIMS["dig_down"] = cloth(swing(
    [(70, 12, -10, {}), (150, 0, 5, {}), (192, -8, 10, {}), (200, -10, 10, {}),
     (90, 18, -15, {}), (-16, 34, -30, {f"elbow_{NEAR}": 0, f"elbow_{FAR}": 6}),
     (-4, 30, -25, {}), (25, 22, -18, {})],
    down_legs), scarf=(-30, 10), coat=(-6, 5))


# up: pick drops low behind the hip, then stabs upward over the head
def up_legs(i):
    k = [0.3, 0.7, 1.0, 1.0, 0.4, 0.0, 0.1, 0.2][i]
    return {f"thigh_{NEAR}": 12 + 25 * k, f"knee_{NEAR}": -12 - 35 * k,
            f"thigh_{FAR}": -12 + 10 * k, f"knee_{FAR}": -8 - 30 * k, "bob": 0.02 - 0.08 * k}


ANIMS["dig_up"] = cloth(swing(
    [(40, 4, 10, {}), (-10, 8, 0, {}), (-38, 10, -5, {}), (-44, 11, -5, {}),
     (90, 0, 20, {}), (178, -12, 35, {f"elbow_{NEAR}": 0}), (166, -10, 32, {}), (125, -4, 22, {})],
    up_legs), scarf=(-30, 10), coat=(-6, 5))

# jump: push off with the arms swinging up, tuck the knees while rising, reach at the apex
ANIMS["jump"] = cloth([
    P(lean=-12, look=8, bob=-0.03, thigh_n=50, knee_n=-75, thigh_f=-28, knee_f=-22, ankle_f=-35,
      shoulder_n=100, elbow_n=25, shoulder_f=60, elbow_f=35),
    P(lean=-6, look=10, bob=0.05, thigh_n=78, knee_n=-110, thigh_f=58, knee_f=-100,
      shoulder_n=150, elbow_n=20, shoulder_f=125, elbow_f=35),
    P(lean=-2, look=8, bob=0.06, thigh_n=45, knee_n=-75, thigh_f=22, knee_f=-62, ankle_f=-15,
      shoulder_n=165, elbow_n=15, shoulder_f=140, elbow_f=28),
], scarf=(-20, 10), coat=(-10, 6), loop=False)
# fall: legs dangling, arms flailing overhead, scarf and coat streaming up (loops)
ANIMS["fall"] = cloth([
    P(lean=4, look=14, thigh_n=22, knee_n=-30, thigh_f=-12, knee_f=-42, ankle_f=-20,
      shoulder_n=155, elbow_n=30, shoulder_f=105, elbow_f=60),
    P(lean=3, look=12, thigh_n=6, knee_n=-40, ankle_n=-10, thigh_f=8, knee_f=-30,
      shoulder_n=140, elbow_n=45, shoulder_f=140, elbow_f=40),
    P(lean=2, look=10, thigh_n=-8, knee_n=-45, ankle_n=-20, thigh_f=24, knee_f=-22,
      shoulder_n=128, elbow_n=58, shoulder_f=165, elbow_f=22),
], scarf=(-160, 14), coat=(-150, 12), sway=12)
# land: deep squash on impact (pick braced low), a beat held, then half way back up
ANIMS["land"] = cloth([
    grounded(P(lean=-28, look=18, thigh_n=70, knee_n=-120, thigh_f=62, knee_f=-118,
               shoulder_n=75, elbow_n=5, shoulder_f=10, elbow_f=50)),
    grounded(P(lean=-22, look=14, thigh_n=58, knee_n=-100, thigh_f=50, knee_f=-98,
               shoulder_n=55, elbow_n=15, shoulder_f=6, elbow_f=45)),
    grounded(P(lean=-12, look=8, thigh_n=42, knee_n=-70, thigh_f=34, knee_f=-66,
               shoulder_n=25, elbow_n=30, shoulder_f=0, elbow_f=35)),
], scarf=(10, 8), coat=(5, 6), loop=False)

# climb: hand over hand up a vertical rope just in front of the chest, pickaxe on the back.
# A gripping hand sinks as the body pulls up past it, the free hand arcs up to grab higher.
ROPE_X = 0.30
CLIMB_FRAMES = 6


def climb(u):
    def hand(t):
        t %= 1
        if t < 0.5:
            return ROPE_X, 1.76 - 0.48 * t / 0.5
        k = (t - 0.5) / 0.5
        return ROPE_X + 0.08 * math.sin(math.pi * k), 1.28 + 0.48 * k

    c = math.cos(2 * math.pi * u)
    p = P(lean=5, look=14, bob=0.03 * (1 - math.cos(4 * math.pi * u)) / 2, stowed=True,
          thigh_n=35 + 23 * c, knee_n=-62 - 33 * c, thigh_f=35 - 23 * c, knee_f=-62 + 33 * c,
          ankle_n=-20, ankle_f=-20)
    reach(p, NEAR, *hand(u))
    return reach(p, FAR, *hand(u + 0.5))


ANIMS["climb"] = cloth([climb(i / CLIMB_FRAMES) for i in range(CLIMB_FRAMES)],
                       scarf=(-15, 6), coat=(0, 3), cycles=2, sway=4)
# hurt: flinch back shielding the face (pick flung low behind), a stunned recoil with the
# head dropped, then gathering himself again
ANIMS["hurt"] = cloth([
    grounded(P(lean=22, look=20, thigh_n=26, knee_n=-34, thigh_f=-18, knee_f=-24,
               shoulder_n=-55, elbow_n=20, shoulder_f=70, elbow_f=95)),
    grounded(P(lean=12, look=-10, thigh_n=36, knee_n=-58, thigh_f=-6, knee_f=-44,
               shoulder_n=8, elbow_n=22, shoulder_f=55, elbow_f=70)),
    grounded(P(lean=6, look=0, thigh_n=24, knee_n=-36, thigh_f=-8, knee_f=-24,
               shoulder_n=14, elbow_n=24, shoulder_f=20, elbow_f=40)),
], scarf=(-60, 14), coat=(-25, 8), loop=False, sway=12)

# roll: a fast forward dodge roll: tuck, over the shoulder, back up into a crouch. The body
# stays on the same spot (the game moves him), pickaxe stowed on the back
TUCK = dict(thigh_n=105, knee_n=-140, thigh_f=95, knee_f=-135, shoulder_n=70, elbow_n=115,
            shoulder_f=60, elbow_f=120, lean=-30, look=-20)
ANIMS["roll"] = cloth([
    P(stowed=True, ground=True, centre=True, spin=-20, **{**TUCK, "thigh_n": 70, "knee_n": -110,
                                                           "thigh_f": 40, "knee_f": -70}),
    P(stowed=True, ground=True, centre=True, spin=-95, **TUCK),
    P(stowed=True, ground=True, centre=True, spin=-170, **TUCK),
    P(stowed=True, ground=True, centre=True, spin=-245, **TUCK),
    P(stowed=True, ground=True, centre=True, spin=-315, **{**TUCK, "thigh_n": 90, "knee_n": -125}),
    grounded(P(stowed=True, centre=True, lean=-14, look=6, thigh_n=62, knee_n=-110, thigh_f=40, knee_f=-80,
               shoulder_n=30, elbow_n=40, shoulder_f=10, elbow_f=50)),
], scarf=(-60, 18), coat=(-30, 12), loop=False, sway=15)

# swim: horizontal breaststroke with the head up: arms sweep out and back, then shoot forward
# while the legs draw up and frog-kick; cloth drifts slowly upward as underwater
SWIM_ARMS = [(175, 5), (140, 25), (95, 70), (60, 125), (120, 60), (165, 15)]   # shoulder, elbow
SWIM_LEGS = [(4, -6), (6, -8), (40, -80), (62, -115), (24, -38), (8, -10)]    # thigh, knee
ANIMS["swim"] = cloth([
    P(stowed=True, centre=True, float_z=1.2, spin=-76 + 4 * wave(i, 6), look=45, lean=0,
      shoulder_n=SWIM_ARMS[i][0], elbow_n=SWIM_ARMS[i][1],
      shoulder_f=SWIM_ARMS[(i + 5) % 6][0] - 6, elbow_f=SWIM_ARMS[(i + 5) % 6][1],
      thigh_n=SWIM_LEGS[i][0], knee_n=SWIM_LEGS[i][1], ankle_n=-50,
      thigh_f=SWIM_LEGS[i][0] - 6, knee_f=SWIM_LEGS[i][1] + 6, ankle_f=-50)
    for i in range(6)], scarf=(-170, 8), coat=(-150, 6), cycles=1, sway=6)

ORDER = ["idle", "run", "jump", "fall", "dig_side", "dig_down", "dig_up", "land", "climb", "hurt", "roll", "swim"]
for row, name in enumerate(ORDER):
    if ONLY and name not in ONLY:
        continue
    for i, p in enumerate(ANIMS[name]):
        pose(p)
        bpy.context.view_layer.update()
        for mode in PASSES:
            set_mode(mode)
            scene.render.filepath = os.path.join(OUT, f"{name}_{i}_{mode}.png")
            bpy.ops.render.render(write_still=True)
print("MINER_DONE", OUT)
