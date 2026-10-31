"""Models the final boss, THE EYE, and its feeding vein nodes in Blender, poses them and renders
flat + clay + normal passes. tools/eye_sheet.py turns them into assets/sprites/eye*.png and
vein*.png.

Run headless:
  blender -b --factory-startup -P tools/eye_blender.py -- <out_dir>

Units: 1 Blender unit = 1 game px; z = 0 is the floor surface (the sprites' bottom row).
The eye is a colossal eyeball sunk in the floor up to its middle, gazing up and out at the
viewer (the drill comes from above), ringed by carved stones. It sits in an "eye frame" tilted
up 40 degrees: the globe (sclera, veins, iris, slit pupil) turns inside it to look left and
right, the thick lids open and close about its horizontal axis.
"""
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_pass import PASSES, normal_shader, set_view  # noqa: E402

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/eye"
os.makedirs(OUT, exist_ok=True)
EYE_W, EYE_H = 160, 96
VEIN_W, VEIN_H = 36, 30
R = 64.0                 # eyeball radius; its centre sits just above the floor
EYE_Z = 6.0
LID_R = R + 3.5
GAZE_UP = 40             # the eye looks up and out at this angle

COLORS = {
    "sclera": "#d8ccb8", "vein": "#9a2a3a", "crack": "#24161a", "pupil": "#120810",
    "iris": "#d8c878", "ring": "#8a44b8", "iris_deep": "#a8963e", "iris_mid": "#b0a25e", "ring_mid": "#6a3890",
    "iris_dim": "#857a4a", "ring_dim": "#4e2e66", "iris_dead": "#5e584a", "ring_dead": "#3a3040",
    "sheen": "#fff8ec", "lid": "#6a5256", "lid_dark": "#4a3a40", "lid_edge": "#8a5a60",
    "stone": "#4e4a52", "stone_dark": "#383440", "rune": "#5e3a78",
    # vein node
    "flesh": "#7a2a4a", "flesh_dark": "#4e1a32", "crystal": "#c070ff", "crystal_dim": "#8a50b8",
    "core": "#ff5a8a", "husk": "#3a2a30", "crystal_dead": "#5a5060",
}
UNLIT = {"iris", "ring", "iris_deep", "iris_mid", "ring_mid", "iris_dim", "ring_dim", "sheen",
         "crystal", "crystal_dim", "core"}
rng = random.Random(13)

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
cam_data.clip_end = 2000
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
current = []


def add(obj, mat, smooth=True):
    obj.data.materials.append(material(mat))
    if smooth:
        for p in obj.data.polygons:
            p.use_smooth = True
    current.append(obj)
    return obj


def mesh_from(name, verts, faces, mat, smooth=True):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    return add(ob, mat, smooth)


def ball(loc, r, mat, scale=(1, 1, 1), segs=24):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=segs // 2, radius=r, location=loc)
    o = bpy.context.active_object
    o.scale = scale
    return add(o, mat)


def box(loc, size, mat, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = size
    return add(o, mat, smooth=False)


def tube(a, b, r0, r1, mat, verts=8):
    a, b = Vector(a), Vector(b)
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r0, radius2=r1, depth=(b - a).length, location=(a + b) / 2)
    o = bpy.context.active_object
    o.rotation_euler = (b - a).to_track_quat("Z", "Y").to_euler()
    return add(o, mat)


def polyline(points, r, mat):
    """A smooth tube through 3D points (veins, cracks, lid folds)."""
    cu = bpy.data.curves.new("c", "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = r
    cu.bevel_resolution = 2
    sp = cu.splines.new("POLY")
    sp.points.add(len(points) - 1)
    for p, v in zip(sp.points, points):
        p.co = (v[0], v[1], v[2], 1)
    ob = bpy.data.objects.new("c", cu)
    scene.collection.objects.link(ob)
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.convert(target="MESH")
    return add(ob, mat)


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


def on_globe(r, phi, psi):
    """Point on a sphere of radius r around the eye centre, phi degrees off the gaze axis
    (local -Y), psi round it (0 = toward +X)."""
    f, s = math.radians(phi), math.radians(psi)
    return Vector((r * math.sin(f) * math.cos(s), -r * math.cos(f), EYE_Z + r * math.sin(f) * math.sin(s)))


def band(r, phi0, phi1, mat, n=48, m=6):
    """A spherical band phi0..phi1 degrees round the gaze axis (a cap when phi0 = 0)."""
    verts, faces = [], []
    rings = []
    for j in range(m + 1):
        phi = phi0 + (phi1 - phi0) * j / m
        if phi == 0:
            verts.append(tuple(on_globe(r, 0, 0)))
            rings.append([len(verts) - 1] * n)
            continue
        rings.append(list(range(len(verts), len(verts) + n)))
        verts += [tuple(on_globe(r, phi, 360 * i / n)) for i in range(n)]
    for a, b in zip(rings, rings[1:]):
        for i in range(n):
            q = [a[i], a[(i + 1) % n], b[(i + 1) % n], b[i]]
            faces.append(tuple(dict.fromkeys(q)))     # a cap's centre ring collapses to triangles
    return mesh_from("band", verts, faces, mat)


def lid_shell(r, a0, a1, mat, n=32, m=12):
    """A lid: part of a sphere wrapping the eye, from a0 to a1 degrees round its horizontal axis
    (0 = the line across the front of the eye, + upward over the top)."""
    verts, faces = [], []
    for i in range(n + 1):
        b = math.pi * i / n
        for j in range(m + 1):
            a = math.radians(a0 + (a1 - a0) * j / m)
            verts.append((r * math.cos(b), -r * math.sin(b) * math.cos(a), EYE_Z + r * math.sin(b) * math.sin(a)))
    for i in range(n):
        for j in range(m):
            k = i * (m + 1) + j
            faces.append((k, k + m + 1, k + m + 2, k + 1))
    return mesh_from("lid", verts, faces, mat)


def lid_arc(r, a, rad, mat, n=24):
    """A tube along the lid at angle a (the thick fleshy lid edge, or a fold)."""
    pts = []
    for i in range(n + 1):
        b = math.pi * (0.04 + 0.92 * i / n)
        pts.append((r * math.cos(b), -r * math.sin(b) * math.cos(math.radians(a)),
                    EYE_Z + r * math.sin(b) * math.sin(math.radians(a))))
    return polyline(pts, rad, mat)


SPRITES = {}


def sprite(name, w, h):
    global current
    SPRITES[name] = (current, w, h)
    current = []


# ================================================================ THE EYE
# carved stones ringing the eye's base in front (static: they are the floor's lip)
stones = []
for k in range(11):
    th = math.radians(-78 + 156 * k / 10)
    rs = R + 9
    h = rng.uniform(7, 13)
    w = rng.uniform(13, 17)
    stones.append(box((rs * math.sin(th), -rs * math.cos(th), h / 2 - 1), (w, 10, h),
                      "stone" if k % 2 else "stone_dark", rot=(0, 0, th)))
    for g in range(2):                                     # carved glyphs on the stone's face
        gx = (g - 0.5) * 5
        gp = Vector((gx * math.cos(th), gx * math.sin(th), 0)) + Vector(((rs - 5.2) * math.sin(th), -(rs - 5.2) * math.cos(th), h * 0.55))
        stones.append(box(tuple(gp), (2.2, 1, h * 0.45 if g else h * 0.3), "rune", rot=(0, 0, th)))

eye_frame = empty((0, 0, EYE_Z))        # tilted up: the eye gazes up and out
globe = empty((0, 0, EYE_Z))            # turns inside the frame to look left / right
globe_parts = [ball((0, 0, EYE_Z), R, "sclera", segs=48)]
IRIS = band(R + 0.4, 0, 20, "iris")
RING = band(R + 0.35, 20, 25, "ring")
IRIS_DETAIL = [band(R + 0.55, 3, 7, "iris_deep")]          # darker ring round the pupil
for k in range(14):                                       # radial streaks in the iris
    psi = 360 * k / 14 + rng.uniform(-6, 6)
    IRIS_DETAIL.append(polyline([tuple(on_globe(R + 0.6, phi, psi + rng.uniform(-3, 3))) for phi in (8, 12, 16, 19)],
                                0.45, "iris_deep"))
globe_parts += [IRIS, RING, ball((0, -(R + 0.3), EYE_Z), 1, "pupil", scale=(3.2, 2.2, 15))] + IRIS_DETAIL
for k in range(10):                                      # bloodshot veins creeping toward the iris
    psi = rng.uniform(0, 360)
    pts = []
    for j in range(9):
        phi = 88 - 56 * j / 8
        psi += rng.uniform(-9, 9)
        pts.append(tuple(on_globe(R + 0.5, phi, psi)))
    globe_parts.append(polyline(pts, 0.9 if k % 3 else 1.3, "vein"))
CRACKS = []                                              # appear while the eye dies
for k in range(5):
    psi = rng.uniform(0, 360)
    phi = rng.uniform(10, 30)
    pts = []
    for j in range(7):
        phi += rng.uniform(5, 9)
        psi += rng.uniform(-14, 14)
        pts.append(tuple(on_globe(R + 0.7, phi, psi)))
    CRACKS.append(polyline(pts, 1.1, "crack"))
globe_parts += CRACKS
sheen = ball(tuple(on_globe(R + 0.6, 34, 145)), 1, "sheen", scale=(5, 2, 3))     # wet highlight, fixed to the light

# thick lids: upper and lower shells, each with a fleshy edge and a couple of folds
lids = {}
for name, (a0, a1, sgn) in {"upper": (0, 185, 1), "lower": (-185, 0, -1)}.items():
    parts = [lid_shell(LID_R, a0, a1, "lid"),
             lid_arc(LID_R + 0.5, 0, 4.2, "lid_edge"),
             lid_arc(LID_R + 1.2, sgn * 14, 1.8, "lid_dark"),
             lid_arc(LID_R + 1.0, sgn * 30, 1.4, "lid_dark")]
    for k in range(4):                                   # veins over the lid
        b0 = rng.uniform(0.25, 0.75) * math.pi
        a = sgn * rng.uniform(40, 80)
        pts = []
        for j in range(6):
            b = b0 + rng.uniform(-0.05, 0.05)
            aa = math.radians(a - sgn * j * 7)
            pts.append((LID_R * 1.01 * math.cos(b), -LID_R * 1.01 * math.sin(b) * math.cos(aa),
                        EYE_Z + LID_R * 1.01 * math.sin(b) * math.sin(aa)))
        parts.append(polyline(pts, 1.0, "vein"))
    pivot = empty((0, 0, EYE_Z))
    parent_to(parts, pivot)
    lids[name] = pivot
parent_to(globe_parts, globe)
parent_to([globe, sheen, lids["upper"], lids["lower"]], eye_frame)
eye_frame.rotation_euler.x = math.radians(-GAZE_UP)
EYE_OBJS = list(current)
sprite("eye", EYE_W, EYE_H)

IRIS_STATES = [("iris", "ring", "iris_deep"), ("iris_mid", "ring_mid", "iris_dim"),
               ("iris_dim", "ring_dim", "iris_dead"), ("iris_dead", "ring_dead", "ring_dead")]


def pose_eye(p):
    """p: upper / lower (lid opening angles: + opens), look (degrees, + = toward screen right),
    iris (0 bright .. 3 dead), cracks (how many show), sag (eye sinks / deflates, 0..1)."""
    lids["upper"].rotation_euler.x = math.radians(-p.get("upper", 0))
    lids["lower"].rotation_euler.x = math.radians(p.get("lower", 0))
    globe.rotation_euler.z = math.radians(p.get("look", 0))
    i, r, d = IRIS_STATES[p.get("iris", 0)]
    IRIS.data.materials[0] = material(i)
    RING.data.materials[0] = material(r)
    for o in IRIS_DETAIL:
        o.data.materials[0] = material(d)
    for k, c in enumerate(CRACKS):
        c.hide_render = k >= p.get("cracks", 0)
    sag = p.get("sag", 0.0)
    eye_frame.location.z = EYE_Z - 10 * sag
    eye_frame.scale = (1 + 0.04 * sag, 1, 1 - 0.18 * sag)


OPEN_U, OPEN_L = 52, 28        # lid angles when the eye is wide open
EYE_ANIMS = {
    "closed": [dict(upper=0, lower=0), dict(upper=5, lower=2)],
    "opening": [dict(upper=OPEN_U * k, lower=OPEN_L * k) for k in (0.06, 0.18, 0.36, 0.58, 0.8, 1.0)],
    "open_look": [dict(upper=OPEN_U, lower=OPEN_L, look=a) for a in (-48, -24, 0, 24, 48)],
    "hurt": [dict(upper=22, lower=12, look=-6), dict(upper=-2, lower=-2)],
    "dying": [dict(upper=OPEN_U, lower=OPEN_L, iris=1, cracks=1, sag=0.0),
              dict(upper=44, lower=24, iris=1, cracks=2, sag=0.15),
              dict(upper=36, lower=20, iris=2, cracks=3, sag=0.35),
              dict(upper=28, lower=14, iris=2, cracks=4, sag=0.55),
              dict(upper=18, lower=8, iris=3, cracks=5, sag=0.75),
              dict(upper=8, lower=3, iris=3, cracks=5, sag=1.0)],
    "blink": [dict(upper=OPEN_U * 0.45, lower=OPEN_L * 0.45), dict(upper=0, lower=0),
              dict(upper=OPEN_U * 0.55, lower=OPEN_L * 0.55)],
}

# ================================================================ vein node (rendered off to the side)
VX = 400                                                 # build it away from the eye
VEIN_PARTS, CRYSTALS, BURST = [], [], {}
bulb = empty((VX, 0, 9))
bulb_parts = [ball((VX, 0, 8.5), 7.5, "flesh"), ball((VX + 2, -3, 11), 3.6, "flesh_dark", scale=(1, 1, 0.7)),
              ball((VX - 1.5, -6.6, 7.5), 2.6, "core", scale=(0.8, 0.6, 1.5))]   # glowing core in a split
for k in range(5):                                       # veins wrapping the bulb
    a = 2 * math.pi * k / 5
    pts = [(VX + 7.6 * math.cos(a + t * 0.6) * math.sin(math.pi * (0.15 + 0.7 * t)), -7.6 * math.sin(a + t * 0.6) * math.sin(math.pi * (0.15 + 0.7 * t)),
            8.5 + 7.6 * math.cos(math.pi * (0.15 + 0.7 * t))) for t in (j / 6 for j in range(7))]
    bulb_parts.append(polyline(pts, 0.8, "flesh_dark"))
for a, h, lean in ((-50, 9, -25), (10, 11, 5), (55, 8, 30), (160, 7, -10)):     # crystal shards
    base = Vector((VX + 5 * math.sin(math.radians(a)), -5 * math.cos(math.radians(a)) * 0.6, 10.5))
    tip = base + Vector((h * math.sin(math.radians(lean)), -1, h * math.cos(math.radians(lean))))
    CRYSTALS.append(tube(base, tip, 1.8, 0.1, "crystal", 5))
bulb_parts += CRYSTALS
parent_to(bulb_parts, bulb)
for k in range(5):                                       # roots spreading over the floor
    a = math.radians(-160 + 320 * k / 4)
    pts = [(VX + r * math.cos(a), -r * math.sin(a) * 0.5, max(0.8, 5 - r * 0.3)) for r in (4, 7, 10, 13, 15)]
    polyline(pts, 1.6 if k % 2 else 1.3, "flesh_dark")
# burst: torn flaps, spatter, flying shards, and the flattened husk left behind
BURST["flaps"] = [tube((VX, 0, 6), (VX + 10 * math.cos(a), -4 * math.sin(a), 6 + 9 * abs(math.sin(a + 1))), 3, 0.3, "flesh", 5)
                  for a in (0.3, 1.5, 2.8, 4.0, 5.2)]
BURST["spatter"] = [ball((VX + rng.uniform(-15, 15), -3, rng.uniform(10, 26)), rng.uniform(0.9, 1.6), "core", segs=8)
                    for _ in range(9)]
BURST["shards"] = [tube((VX + x, -2, z), (VX + x + dx, -2, z + dz), 1.2, 0.1, "crystal_dim", 5)
                   for x, z, dx, dz in ((-11, 16, -4, 4), (9, 19, 5, 3), (-3, 24, 1, 5), (13, 9, 4, -1))]
BURST["husk"] = [ball((VX, 0, 2.5), 9, "husk", scale=(1.2, 1, 0.35)),
                 tube((VX - 3, 0, 4), (VX - 7, -1, 7), 1.2, 0.1, "crystal_dead", 5),
                 tube((VX + 4, 0, 4), (VX + 6, -1, 8), 1.2, 0.1, "crystal_dead", 5)]
VEIN_OBJS = list(current)
sprite("vein", VEIN_W, VEIN_H)


def pose_vein(p):
    """p: pulse (0..1 swell), bright (crystals lit), show: which parts are visible."""
    s = 1 + 0.12 * p.get("pulse", 0)
    bulb.scale = (s, s, s * (1 + 0.04 * p.get("pulse", 0)))
    for c in CRYSTALS:
        c.data.materials[0] = material("crystal" if p.get("bright", True) else "crystal_dim")
    show = p.get("show", {"bulb"})
    for o in bulb.children:
        o.hide_render = "bulb" not in show
    for k, objs in BURST.items():
        for o in objs:
            o.hide_render = k not in show


VEIN_ANIMS = {
    "pulse": [dict(pulse=0.0, bright=False), dict(pulse=0.55), dict(pulse=1.0), dict(pulse=0.5, bright=False)],
    "burst": [dict(pulse=1.4), dict(pulse=0.6, show={"flaps", "spatter", "shards"}),
              dict(show={"husk"})],
}


# ---------------------------------------------------------------- render
def render(name, w, h, cx):
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    cam_data.ortho_scale = max(w, h)
    cam.location = (cx, -800, h / 2)
    for mode in PASSES:
        set_mode(mode)
        scene.render.filepath = os.path.join(OUT, f"{name}_{mode}.png")
        bpy.ops.render.render(write_still=True)


for name, anims, pose, objs, others, cx, w, h in (("eye", EYE_ANIMS, pose_eye, EYE_OBJS, VEIN_OBJS, 0, EYE_W, EYE_H),
                                                  ("vein", VEIN_ANIMS, pose_vein, VEIN_OBJS, EYE_OBJS, VX, VEIN_W, VEIN_H)):
    for o in others:
        o.hide_render = True
    for o in objs:
        o.hide_render = False
    for anim, frames in anims.items():
        for i, p in enumerate(frames):
            pose(p)
            render(f"{name}_{anim}_{i}", w, h, cx)
print("EYE_DONE")
