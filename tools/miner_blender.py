"""Builds a low-poly miner in Blender, poses it, and renders sprite frames (side view).

Run headless:
  blender -b --factory-startup -P tools/miner_blender.py -- <out_dir> [anim,anim,...]
Each frame is rendered twice: flat colours (albedo) and white clay (lighting).
tools/miner_sheet.py combines them into stepped pixel-art shading with outlines.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "/tmp/miner"
ONLY = set(ARGS[1].split(",")) if len(ARGS) > 1 else None   # optional: render just these anims
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


def pickaxe(parent, hx, y, hz, prefix=""):
    """Pickaxe gripped at (hx, y, hz): the handle hangs straight down, pick head at the end."""
    return [
        cyl(prefix + "handle", (hx, y, hz - 0.22), 0.025, 0.62, "handle", parent, verts=6),
        box(prefix + "pick_a", (hx + 0.13, y, hz - 0.52), (0.28, 0.05, 0.06), "iron", parent,
            rot=(0, math.radians(-20), 0)),
        box(prefix + "pick_b", (hx - 0.13, y, hz - 0.52), (0.28, 0.05, 0.06), "iron", parent,
            rot=(0, math.radians(20), 0)),
        cyl(prefix + "pick_hub", (hx, y, hz - 0.51), 0.05, 0.08, "iron", parent, verts=8,
            rot=(math.radians(90), 0, 0)),
    ]


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
    """p: joint -> forward swing in degrees (0 = hanging down). Extra keys: bob, lean, look, stowed.

    Every angle turns counter-clockwise on screen, so a positive limb swings forward but a
    positive lean / look tips the torso / head back."""
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

# ---------------------------------------------------------------- airborne, landing, climbing, hurt
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


# jump: push off the far leg with the arms swinging up, then tuck the knees while rising
ANIMS["jump"] = [
    P(lean=-12, look=8, bob=-0.03, thigh_n=50, knee_n=-75, thigh_f=-28, knee_f=-22, ankle_f=-35,
      shoulder_n=100, elbow_n=25, shoulder_f=60, elbow_f=35),
    P(lean=-6, look=10, bob=0.05, thigh_n=78, knee_n=-110, thigh_f=58, knee_f=-100,
      shoulder_n=150, elbow_n=20, shoulder_f=125, elbow_f=35),
]
# fall: legs dangling, arms thrown up and flailing (two alternating frames)
ANIMS["fall"] = [
    P(lean=4, look=14, thigh_n=22, knee_n=-30, thigh_f=-12, knee_f=-42, ankle_f=-20,
      shoulder_n=155, elbow_n=30, shoulder_f=105, elbow_f=60),
    P(lean=2, look=10, thigh_n=-8, knee_n=-45, ankle_n=-20, thigh_f=24, knee_f=-22,
      shoulder_n=128, elbow_n=58, shoulder_f=165, elbow_f=22),
]
# land: deep squash on impact (pick braced low), then half way back up
ANIMS["land"] = [
    grounded(P(lean=-28, look=18, thigh_n=70, knee_n=-120, thigh_f=62, knee_f=-118,
               shoulder_n=75, elbow_n=5, shoulder_f=10, elbow_f=50)),
    grounded(P(lean=-12, look=8, thigh_n=42, knee_n=-70, thigh_f=34, knee_f=-66,
               shoulder_n=25, elbow_n=30, shoulder_f=0, elbow_f=35)),
]

# climb: hand over hand up a vertical rope just in front of the chest, pickaxe on the back.
# The grabbing hand sinks as the body pulls up past it while the free hand reaches above.
ROPE_X = 0.30
UP_LEG, MID_LEG, HANG_LEG = (58, -95), (34, -62), (12, -28)


def climb(near_hand, far_hand, near_leg, far_leg, bob):
    p = P(lean=5, look=14, bob=bob, stowed=True, thigh_n=near_leg[0], knee_n=near_leg[1],
          thigh_f=far_leg[0], knee_f=far_leg[1], ankle_n=-20, ankle_f=-20)
    reach(p, NEAR, *near_hand)
    return reach(p, FAR, *far_hand)


ANIMS["climb"] = [
    climb((ROPE_X, 1.76), (ROPE_X, 1.28), UP_LEG, HANG_LEG, 0.0),
    climb((ROPE_X, 1.54), (ROPE_X + 0.07, 1.66), MID_LEG, MID_LEG, 0.03),
    climb((ROPE_X, 1.28), (ROPE_X, 1.76), HANG_LEG, UP_LEG, 0.0),
    climb((ROPE_X + 0.07, 1.66), (ROPE_X, 1.54), MID_LEG, MID_LEG, 0.03),
]
# hurt: flinch back shielding the face with the free arm (pick flung low behind), then a
# stunned recoil, knees buckled, head dropped and the pick dangling
ANIMS["hurt"] = [
    grounded(P(lean=22, look=20, thigh_n=26, knee_n=-34, thigh_f=-18, knee_f=-24,
               shoulder_n=-55, elbow_n=20, shoulder_f=70, elbow_f=95)),
    grounded(P(lean=12, look=-10, thigh_n=36, knee_n=-58, thigh_f=-6, knee_f=-44,
               shoulder_n=8, elbow_n=22, shoulder_f=55, elbow_f=70)),
]

ORDER = ["idle", "run", "jump", "fall", "dig_side", "dig_down", "dig_up", "land", "climb", "hurt"]
for row, name in enumerate(ORDER):
    if ONLY and name not in ONLY:
        continue
    for i, p in enumerate(ANIMS[name]):
        pose(p)
        bpy.context.view_layer.update()
        for clay in (False, True):
            set_mode(clay)
            scene.render.filepath = os.path.join(OUT, f"{name}_{i}_{'clay' if clay else 'flat'}.png")
            bpy.ops.render.render(write_still=True)
print("MINER_DONE", OUT)
