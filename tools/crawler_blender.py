"""Builds the pale cave crawler in Blender, poses it, and renders sprite frames (side view).

Run headless:
  blender -b --factory-startup -P tools/crawler_blender.py -- <out_dir> [anim,anim,...]
Same scale, camera and flat + clay + normal passes as the miner (tools/miner_blender.py);
tools/crawler_sheet.py turns them into the sprite sheet + an eye glow sheet.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_pass import PASSES, normal_shader, set_view  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "/tmp/crawler"
ONLY = set(ARGS[1].split(",")) if len(ARGS) > 1 else None   # optional: render just these anims
os.makedirs(OUT, exist_ok=True)
PX_PER_UNIT = 80 / 3.625      # the miner's scale
CELL_W, CELL_H = 64, 48
FEET_BELOW_CENTER = 20        # px from the cell centre down to the floor
CAM_X = 0.1                   # body sits a little left of centre: lunges reach forward

COLORS = {
    "plate": "#c9bfc8", "plate_b": "#b8adb9", "belly": "#6d5f72", "leg": "#574862",
    "leg_far": "#382d42", "jaw": "#3e2f3a", "maw": "#5c1820", "eye": "#ff5a1e",
}

# ---------------------------------------------------------------- scene setup
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 48
scene.cycles.use_denoising = False
scene.cycles.filter_width = 0.01           # no anti-aliasing: crisp pixels
scene.render.film_transparent = True
scene.render.resolution_x = CELL_W
scene.render.resolution_y = CELL_H
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
cam_data.ortho_scale = CELL_W / PX_PER_UNIT
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
cam.location = (CAM_X, -10, FEET_BELOW_CENTER / PX_PER_UNIT)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam

sun_data = bpy.data.lights.new("Sun", "SUN")
sun_data.energy = 1.4
sun_data.angle = math.radians(2)
sun = bpy.data.objects.new("Sun", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = (-Vector((0.55, 0.75, -0.8)).normalized()).to_track_quat("Z", "Y").to_euler()

# ---------------------------------------------------------------- materials (albedo / clay switch)
MATS = {}


def hex_rgb(h):
    h = h.lstrip("#")
    return [(int(h[i:i + 2], 16) / 255) ** 2.2 for i in (0, 2, 4)] + [1.0]


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
    df = nt.nodes.new("ShaderNodeBsdfDiffuse")
    df.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
    if name == "eye":   # eyes glow: stay bright in the clay pass too
        df = nt.nodes.new("ShaderNodeEmission")
        df.inputs["Strength"].default_value = 3.0
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


# ---------------------------------------------------------------- modelling helpers (as the miner's)
MESHES = []


def finish(obj, mat, smooth=False):
    obj.data.materials.append(material(mat)[0])
    if smooth:
        for p in obj.data.polygons:
            p.use_smooth = True
    MESHES.append(obj)
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


def cyl(name, loc, radius, depth, mat, parent, verts=8):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius, depth=depth, location=loc)
    o = bpy.context.active_object
    o.name = name
    finish(o, mat)
    attach(o, parent)
    return o


def cone(name, loc, r1, depth, mat, parent, rot=(0, 0, 0), verts=6, tip=0.0):
    """Cone with its point (radius `tip`) down (-Z) unless rotated."""
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=tip, radius2=r1, depth=depth, location=loc,
                                    rotation=rot)
    o = bpy.context.active_object
    o.name = name
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


# ---------------------------------------------------------------- the crawler
# Built straight along +X at BODY_Z; the hunch comes from the pose. Every joint turns about Y
# with the miner's convention: degrees counter-clockwise on screen (0 = pointing down).
NEAR, FAR = -1, 1
BODY_Z = 0.70
root = joint("root", None, (0, 0, 0))
body = joint("body", root, (0, 0, BODY_Z))

# spine: (joint, parent, pivot x, centre x, half-size x/y/z, plate colour)
SPINE = [
    ("mid", "body", 0.0, 0.0, (0.17, 0.28, 0.30), "plate"),
    ("f1", "mid", 0.12, 0.23, (0.15, 0.27, 0.27), "plate_b"),
    ("f2", "f1", 0.34, 0.43, (0.13, 0.24, 0.23), "plate"),
    ("head", "f2", 0.52, 0.64, (0.17, 0.21, 0.17), None),
    ("b1", "mid", -0.12, -0.23, (0.15, 0.27, 0.27), "plate_b"),
    ("b2", "b1", -0.33, -0.42, (0.13, 0.23, 0.21), "plate"),
    ("b3", "b2", -0.51, -0.57, (0.10, 0.18, 0.15), "plate_b"),
    ("tail", "b3", -0.64, -0.69, (0.08, 0.13, 0.10), "plate"),
]
J = {"root": root, "body": body}
for name, parent, px, cx, (rx, ry, rz), plate in SPINE:
    J[name] = j = joint(name, J[parent], (px, 0, BODY_Z))
    ball(f"{name}_core", (cx, 0, BODY_Z - 0.03), 1, "belly", j, scale=(rx, ry * 0.9, rz * 0.8))
    if plate:   # pale armour plate on top, overlapping the next one back like an isopod
        ball(f"{name}_plate", (cx - 0.03 * (1 if cx >= 0 else -1), 0, BODY_Z + 0.05), 1, plate, j,
             scale=(rx * 1.08, ry * 1.04, rz * 0.82))

# head: pale dome, dark mandibles (upper / lower so they read from the side), red maw, 3 eye dots
head = J["head"]
HX, HZ = 0.64, BODY_Z
ball("head_dome", (HX - 0.01, 0, HZ + 0.02), 1, "plate_b", head, scale=(0.17, 0.21, 0.17))
ball("maw", (HX + 0.13, 0, HZ - 0.06), 0.08, "maw", head)
JAW_REST = {"jaw_up": 100, "jaw_lo": 70}   # closed: pointing forward, crossing at the tips
for name in JAW_REST:
    J[name] = jw = joint(name, head, (HX + 0.12, 0, HZ - 0.05))
    cone(f"{name}_m", (HX + 0.12, 0, HZ - 0.05 - 0.11), 0.05, 0.22, "jaw", jw)
EYES = []
for ex, ez in ((0.10, 0.08), (-0.02, 0.07), (0.11, -0.05)):   # ~2.5 px apart: separate dots
    ey = -0.21 * math.sqrt(max(0.0, 1 - (ex / 0.17) ** 2 - (ez / 0.17) ** 2))
    EYES.append(ball("eye", (HX - 0.01 + ex, ey - 0.012, HZ + 0.02 + ez), 0.037, "eye", head))
# feelers: two segments each, swept forward over the jaws
for side in (NEAR, FAR):
    a1 = J[f"ant_{side}"] = joint(f"ant_{side}", head, (HX + 0.06, side * 0.1, HZ + 0.12))
    mat = "leg" if side == NEAR else "leg_far"
    cyl(f"ant1_{side}", (HX + 0.06, side * 0.1, HZ + 0.12 - 0.12), 0.018, 0.24, mat, a1, 5)
    a2 = J[f"ant2_{side}"] = joint(f"ant2_{side}", a1, (HX + 0.06, side * 0.1, HZ + 0.12 - 0.24))
    cyl(f"ant2_{side}", (HX + 0.06, side * 0.1, HZ + 0.12 - 0.36), 0.016, 0.24, mat, a2, 5)
# tail spikes
tail = J["tail"]
for side in (NEAR, FAR):
    t = joint(f"cerc_{side}", tail, (-0.74, side * 0.05, BODY_Z + 0.02))
    t.rotation_euler.y = math.radians(150 if side == NEAR else 165)   # swept back and up
    cone(f"cerc_{side}_m", (-0.74, side * 0.05, BODY_Z + 0.02 - 0.1), 0.028, 0.2, "jaw", t)

# legs: hip low on the flank, femur up to a high knee, long thin tibia down to a point
FEM, TIB = 0.38, 0.7
HIP_Z = BODY_Z - 0.22
LEGS = {}   # name -> (hip, knee, rest hip x, foot x offset, knee bend)
for key, seg, hx, foot, bend in (("f", "f1", 0.20, 0.50, -1), ("m", "mid", 0.0, 0.12, -1),
                                 ("r", "b1", -0.28, -0.52, +1)):
    for side, sname in ((NEAR, "n"), (FAR, "f")):
        mat = "leg" if side == NEAR else "leg_far"
        y = side * 0.33          # just outside the body so the near legs draw over its flank
        hip = joint(f"hip_{key}{sname}", J[seg], (hx, y, HIP_Z))
        cyl(f"femur_{key}{sname}", (hx, y, HIP_Z - FEM / 2), 0.05, FEM, mat, hip, 6)
        knee = joint(f"knee_{key}{sname}", hip, (hx, y, HIP_Z - FEM))
        ball(f"kneeb_{key}{sname}", (hx, y, HIP_Z - FEM), 0.05, mat, knee)
        cone(f"tibia_{key}{sname}", (hx, y, HIP_Z - FEM - TIB / 2), 0.05, TIB, mat, knee, tip=0.024)
        # far legs plant a bit further forward so they peek out from behind the near ones
        LEGS[key + sname] = (hip, knee, hx, foot + (0.07 if side == FAR else 0.0), bend)


# ---------------------------------------------------------------- posing
HUNCH = {"f1": -14, "f2": -18, "head": -20, "b1": 14, "b2": 16, "b3": 18, "tail": 18}


def setrot(obj, deg):
    obj.rotation_euler = (0, math.radians(-deg), 0)


def world_angle(obj):
    """The joint's total turn on screen (same convention as pose angles)."""
    m = obj.matrix_world
    return -math.degrees(math.atan2(m[0][2], m[0][0]))


def two_bone(dx, dz, l1, l2, bend):
    """(first bone angle, joint bend) reaching offset (dx, dz). bend=-1 bends like a knee."""
    d = max(min(math.hypot(dx, dz), l1 + l2 - 1e-4), abs(l1 - l2) + 1e-4)
    phi = math.degrees(math.atan2(dx, -dz))
    alpha = math.degrees(math.acos((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d)))
    inner = math.degrees(math.acos((l1 * l1 + l2 * l2 - d * d) / (2 * l1 * l2)))
    return phi - bend * alpha, bend * (180 - inner)


def foot_home(leg):
    _, _, hx, foot, _ = LEGS[leg]
    return hx + foot


def pose(p):
    """p keys: x, z (whole body shift), spine joints (added to the hunch), jaw (opening),
    ant (feeler wiggle), feet {leg: (x, z) world target}, fold {leg: (hip, knee)},
    eyes (False = dead), ground (True = drop the body until it rests on the floor)."""
    root.location = (p.get("x", 0.0), 0, p.get("z", 0.0))
    for name in ("f1", "f2", "head", "b1", "b2", "b3", "tail"):
        setrot(J[name], HUNCH[name] + p.get(name, 0))
    setrot(J["mid"], p.get("mid", 0))
    setrot(J["jaw_up"], JAW_REST["jaw_up"] + p.get("jaw", 0))
    setrot(J["jaw_lo"], JAW_REST["jaw_lo"] - p.get("jaw", 0))
    w = p.get("ant", 0)
    setrot(J[f"ant_{NEAR}"], 178 + w)        # up and forward, tips curling down
    setrot(J[f"ant2_{NEAR}"], -50 - w)
    setrot(J[f"ant_{FAR}"], 170 - w)
    setrot(J[f"ant2_{FAR}"], -42 + w)
    for e in EYES:
        e.hide_render = not p.get("eyes", True)
    bpy.context.view_layer.update()
    feet = p.get("feet", {})
    fold = p.get("fold", {})
    for leg, (hip, knee, hx, foot, bend) in LEGS.items():
        if leg in fold:
            setrot(hip, fold[leg][0])
            setrot(knee, fold[leg][1])
            continue
        fx, fz = feet.get(leg, (foot_home(leg), 0.0))
        h = hip.matrix_world.translation
        a, k = two_bone(fx - h.x, fz - h.z, FEM, TIB, bend)
        setrot(hip, a - world_angle(hip.parent))
        setrot(knee, k)
    bpy.context.view_layer.update()
    if p.get("ground"):
        low = min((o.matrix_world @ v.co).z for o in MESHES if not o.hide_render for v in o.data.vertices)
        root.location.z -= low
        bpy.context.view_layer.update()


def feet(**off):
    """World foot targets: each leg's home spot shifted by (dx, dz)."""
    return {leg: (foot_home(leg) + dx, dz) for leg, (dx, dz) in off.items()}


ANIMS = {}
# walk: alternating tripods (near front + far mid + near rear, then the other three).
# A foot slides back STRIDE on the floor, then lifts and swings forward (eased in and out).
WALK_FRAMES = 8
STRIDE, LIFT = 0.18, 0.14
TRIPOD = {"fn": 0, "mf": 0, "rn": 0, "ff": 0.5, "mn": 0.5, "rf": 0.5}
walk = []
for i in range(WALK_FRAMES):
    f = {}
    for leg, off in TRIPOD.items():
        t = (i / WALK_FRAMES + off) % 1
        if t < 0.5:
            f[leg] = (STRIDE * (1 - 4 * t), 0.0)
        else:
            u = (t - 0.5) * 2
            ease = u * u * (3 - 2 * u)
            f[leg] = (STRIDE * (2 * ease - 1), LIFT * math.sin(math.pi * u))
    ph = i / WALK_FRAMES * 2 * math.pi
    walk.append({"z": 0.025 * math.cos(2 * ph), "mid": 1.5 * math.sin(2 * ph), "head": 4 * math.sin(ph),
                 "tail": 4 * math.sin(ph + 1), "ant": 8 * math.sin(ph), "jaw": 4 + 4 * math.sin(2 * ph),
                 "feet": feet(**f)})
ANIMS["walk"] = walk

# lunge: coil back, spring forward with the jaws wide, snap shut on the bite, settle
planted = dict(fn=(0, 0), ff=(0, 0), mn=(0, 0), mf=(0, 0), rn=(0, 0), rf=(0, 0))
ANIMS["lunge"] = [
    {"x": -0.14, "z": -0.09, "f1": 4, "f2": 8, "head": 22, "b1": 4, "b2": 4, "jaw": 15, "ant": -10,
     "feet": feet(**planted)},
    {"x": 0.30, "z": 0.12, "f1": 12, "f2": 12, "head": 26, "b1": -4, "b2": -6, "jaw": 48, "ant": 15,
     "feet": feet(**{**planted, "fn": (0.42, 0.24), "ff": (0.40, 0.3), "mn": (0.2, 0.1)})},
    {"x": 0.34, "z": -0.03, "f1": -8, "f2": -10, "head": -16, "jaw": -4, "ant": 5,
     "feet": feet(**{**planted, "fn": (0.44, 0), "ff": (0.42, 0), "mn": (0.24, 0), "mf": (0.2, 0)})},
    {"x": 0.08, "z": 0.0, "head": 4, "jaw": 10, "ant": -4,
     "feet": feet(**{**planted, "fn": (0.16, 0), "ff": (0.14, 0), "mn": (0.06, 0)})},
]
# hurt: knocked back with head and tail thrown up and the jaws gaping, then sag
ANIMS["hurt"] = [
    {"x": -0.12, "z": 0.04, "f1": 10, "f2": 12, "head": 26, "b1": -6, "b2": -8, "b3": -10, "tail": -12,
     "jaw": 38, "ant": 20, "feet": feet(fn=(0.14, 0.05), ff=(0.14, 0.08), rn=(-0.14, 0), rf=(-0.12, 0))},
    {"x": -0.06, "z": -0.03, "f1": 2, "f2": 4, "head": 8, "jaw": 16, "ant": -12,
     "feet": feet(fn=(0.08, 0), ff=(0.08, 0), rn=(-0.08, 0), rf=(-0.06, 0))},
]
# die: legs buckle and the body drops, then it rolls up into a ball, legs tucked, eyes out
ANIMS["die"] = [
    {"x": -0.04, "z": -0.15, "f1": -2, "f2": -2, "head": -6, "b1": 4, "tail": 10, "jaw": 30, "ant": -25,
     "feet": feet(fn=(0.26, 0), ff=(0.24, 0), mn=(0.16, 0), mf=(0.18, 0), rn=(-0.24, 0), rf=(-0.22, 0))},
    {"f1": -24, "f2": -28, "head": -32, "b1": 24, "b2": 28, "b3": 28, "tail": 32, "jaw": 12, "ant": -35,
     "fold": {l: (35 if l[0] == "f" else 10 if l[0] == "m" else -15, -100) for l in LEGS}, "ground": True},
    {"f1": -40, "f2": -44, "head": -48, "b1": 40, "b2": 44, "b3": 44, "tail": 48, "jaw": 0, "ant": -50,
     "fold": {l: (20, -140) for l in LEGS}, "eyes": False, "ground": True},
]

ORDER = ["walk", "lunge", "hurt", "die"]
for name in ORDER:
    if ONLY and name not in ONLY:
        continue
    for i, p in enumerate(ANIMS[name]):
        pose(p)
        for mode in PASSES:
            set_mode(mode)
            scene.render.filepath = os.path.join(OUT, f"{name}_{i}_{mode}.png")
            bpy.ops.render.render(write_still=True)
print("CRAWLER_DONE", OUT)
