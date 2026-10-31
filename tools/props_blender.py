"""Models the cave props in Blender and renders flat + clay passes for each.

Run headless:
  blender -b --factory-startup -P tools/props_blender.py -- <out_dir>
Same scale as the miner (22 px per unit). tools/props_sheet.py makes the sprites.
"""
import math
import os
import random
import sys

import bpy
from mathutils import Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/props"
os.makedirs(OUT, exist_ok=True)
PX_PER_UNIT = 80 / 3.625
random.seed(5)

COLORS = {
    "wood": "#6b4a2e", "wood_dark": "#4a3220", "iron": "#5d636e", "iron_dark": "#3a3e46",
    "rust": "#6e4632", "glass": "#ffb347", "bone": "#d8cfb8", "bone_dark": "#a89d85",
    "root": "#3a2616", "cryst_p": "#b06cff", "cryst_p_dark": "#5a2d8a", "cryst_t": "#4ff0d0",
    "cryst_t_dark": "#1f7a72", "rock": "#3f4858", "plank": "#7a5636", "chain": "#4a4e57",
    "boulder": "#6e6359", "hemp": "#a8875a", "hemp_dark": "#5e4528", "steel": "#878e99",
    "canvas_a": "#8c3a2e", "canvas_b": "#bfae88", "canvas_back": "#3e2622", "ore_rock": "#4b4f58",
    "gold": "#c9a227", "copper": "#b5653a", "paint": "#d6b85a",
}
GLOW = {"glass", "cryst_p", "cryst_t"}   # these stay bright (emissive) in the clay pass too

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 24
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
    if name in GLOW:
        df = nt.nodes.new("ShaderNodeEmission")
        df.inputs["Strength"].default_value = 3.0
    else:
        df = nt.nodes.new("ShaderNodeBsdfDiffuse")
        df.inputs["Color"].default_value = (0.8, 0.8, 0.8, 1)
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    MATS[name] = (m, nt, out, em, df)
    return m


def set_mode(clay):
    for m, nt, out, em, df in MATS.values():
        for l in list(out.inputs["Surface"].links):
            nt.links.remove(l)
        nt.links.new((df if clay else em).outputs[0], out.inputs["Surface"])
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0 if clay else 0.0
    sun_data.energy = 1.4 if clay else 0.0


PROPS = {}   # name -> (objects, w_px, h_px, centre)
current = []


def add(obj, mat, smooth=False):
    obj.data.materials.append(material(mat))
    if smooth:
        for p in obj.data.polygons:
            p.use_smooth = True
    current.append(obj)
    return obj


def box(loc, size, mat, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.scale = size
    return add(o, mat)


def cyl(loc, r, depth, mat, rot=(0, 0, 0), verts=8):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth, location=loc, rotation=rot)
    return add(bpy.context.active_object, mat)


def cone(loc, r, depth, mat, rot=(0, 0, 0), verts=6):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r, radius2=0, depth=depth, location=loc, rotation=rot)
    return add(bpy.context.active_object, mat)


def ball(loc, r, mat, scale=(1, 1, 1)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=10, ring_count=6, radius=r, location=loc)
    o = bpy.context.active_object
    o.scale = scale
    return add(o, mat, smooth=True)


def torus(loc, r, t, mat, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_torus_add(major_radius=r, minor_radius=t, major_segments=10, minor_segments=4,
                                     location=loc, rotation=rot)
    return add(bpy.context.active_object, mat)


def prop(name, w, h, centre, samples=24):
    """Close the current prop: w x h px sprite with the camera centred on world (x, z) `centre`.
    More samples give a cleaner clay pass (less speckle in the shading bands)."""
    global current
    PROPS[name] = (current, w, h, centre, samples)
    current = []


def chain(x, top, links, mat="chain"):
    for i in range(links):
        torus((x, 0, top - 0.09 - i * 0.13), 0.06, 0.016, mat, rot=(0 if i % 2 else math.radians(90), math.radians(90), 0))
    return top - 0.09 - links * 0.13


# ---- lantern hanging on a chain (anchor: top centre)
y = chain(0, 0, 5)
box((0, 0, y - 0.04), (0.22, 0.22, 0.05), "iron_dark")
box((0, 0, y - 0.22), (0.17, 0.17, 0.3), "glass")
for sx in (-1, 1):
    box((sx * 0.1, -0.1, y - 0.22), (0.03, 0.03, 0.32), "iron")
box((0, 0, y - 0.39), (0.22, 0.22, 0.05), "iron_dark")
cone((0, 0, y + 0.02), 0.12, 0.1, "iron_dark")
prop("lantern", 24, 40, (0, -0.85))

# ---- mine support beams (anchor: bottom centre)
for sx in (-1, 1):
    box((sx * 1.05, 0, 1.3), (0.2, 0.2, 2.6), "wood")
    box((sx * 0.75, 0, 2.3), (0.55, 0.12, 0.1), "wood_dark", rot=(0, math.radians(sx * 40), 0))
box((0, 0, 2.62), (2.6, 0.24, 0.22), "wood")
for sx in (-0.6, 0.0, 0.6):
    cyl((sx, -0.13, 2.62), 0.025, 0.05, "iron", rot=(math.radians(90), 0, 0), verts=6)
prop("beam", 64, 72, (0, 1.4))

# ---- crystal clusters (anchor: bottom centre), purple + teal
for nm, c, cd in (("crystal_p", "cryst_p", "cryst_p_dark"), ("crystal_t", "cryst_t", "cryst_t_dark")):
    ball((0, 0, 0.02), 0.3, "rock", scale=(1.5, 1, 0.5))
    for i in range(8):
        ang = random.uniform(-0.8, 0.8)
        ln = random.uniform(0.5, 1.15) * (1.2 - abs(ang) * 0.6)
        x = math.sin(ang) * 0.12 + random.uniform(-0.12, 0.12)
        mid = (x + math.sin(ang) * ln / 2, random.uniform(-0.05, 0.05), math.cos(ang) * ln / 2 + 0.05)
        cone(mid, random.uniform(0.08, 0.14), ln, c if i % 3 else cd, rot=(0, ang, 0), verts=5)
    prop(nm, 48, 48, (0, 0.9))

# ---- skeleton lying on the floor (anchor: bottom centre)
ball((-0.75, 0, 0.13), 0.13, "bone", scale=(1.1, 1, 1))
ball((-0.66, -0.1, 0.13), 0.03, "iron_dark")
box((-0.45, 0, 0.08), (0.25, 0.06, 0.05), "bone_dark")
for i in range(5):
    torus((-0.3 + i * 0.09, 0, 0.11), 0.09, 0.015, "bone", rot=(0, math.radians(90), 0))
cyl((0.2, 0, 0.07), 0.035, 0.45, "bone", rot=(0, math.radians(84), 0))
cyl((0.55, 0, 0.06), 0.03, 0.4, "bone", rot=(0, math.radians(95), 0))
cyl((0.05, -0.12, 0.05), 0.03, 0.4, "bone_dark", rot=(0, math.radians(70), math.radians(20)))
box((0.15, 0, 0.12), (0.18, 0.2, 0.1), "bone_dark")
prop("skeleton", 48, 24, (0, 0.3))

# ---- hanging roots (anchor: top centre)
for r in range(6):
    x = random.uniform(-0.45, 0.45)
    z = 0.0
    a = random.uniform(-0.3, 0.3)
    for s in range(random.randint(3, 7)):
        ln = random.uniform(0.12, 0.22)
        cyl((x + math.sin(a) * ln / 2, random.uniform(-0.05, 0.05), z - math.cos(a) * ln / 2),
            0.035 * (1 - s * 0.1), ln + 0.02, "root", rot=(0, a, 0), verts=5)
        x += math.sin(a) * ln
        z -= math.cos(a) * ln
        a += random.uniform(-0.5, 0.5)
prop("roots", 32, 48, (0, -0.9))

# ---- abandoned mine cart (anchor: bottom centre)
bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=0.62, radius2=0.85, depth=0.5, location=(0, 0, 0.5),
                                rotation=(0, 0, math.radians(45)))
o = bpy.context.active_object
o.scale = (1.1, 0.7, 1)
add(o, "rust")
box((0, 0, 0.76), (1.25, 0.82, 0.05), "iron_dark")
for sx in (-0.42, 0.42):
    cyl((sx, -0.36, 0.17), 0.16, 0.06, "iron_dark", rot=(math.radians(90), 0, 0), verts=10)
    cyl((sx, -0.4, 0.17), 0.05, 0.04, "iron", rot=(math.radians(90), 0, 0), verts=6)
prop("cart", 48, 36, (0, 0.7))

# ---- wooden crate (anchor: bottom centre)
box((0, 0, 0.3), (0.6, 0.55, 0.6), "plank")
for z in (0.04, 0.56):
    box((0, -0.29, z), (0.62, 0.03, 0.08), "wood_dark")
box((0, -0.29, 0.3), (0.08, 0.03, 0.62), "wood_dark", rot=(0, math.radians(45), 0))
prop("crate", 24, 24, (0, 0.38))

# ---- long chain with a hook (anchor: top centre)
y = chain(0, 0, 18)
torus((0.04, 0, y - 0.1), 0.1, 0.022, "iron", rot=(math.radians(90), 0, 0))
prop("chains", 16, 64, (0, -1.4))

# ---- loose boulder (anchor: centre), chunky faceted rock
rng = random.Random(23)        # own stream so the props above keep their shapes
bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.52, location=(0, 0, 0))
o = bpy.context.active_object
for v in o.data.vertices:
    v.co *= rng.uniform(0.84, 1.1)
o.scale = (1.0, 0.95, 0.88)
o.rotation_euler = (0.4, 0.3, 0.2)
add(o, "boulder")
prop("boulder", 26, 26, (0, 0), samples=96)


# ---- rope: two twisted hemp strands, a full twist every 8 px (a strand crossing every 4 px)
# so the 16 px tile repeats vertically without a seam.
# Rendered three tiles tall; props_sheet.py keeps the middle tile.
def helix(phase, pitch, radius, thick, z0, z1, mat):
    steps = int((z1 - z0) / pitch * 24)
    cu = bpy.data.curves.new("helix", "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = thick
    cu.bevel_resolution = 2
    sp = cu.splines.new("POLY")
    sp.points.add(steps)
    for i, pt in enumerate(sp.points):
        z = z0 + (z1 - z0) * i / steps
        a = 2 * math.pi * (z - z0) / pitch + phase
        pt.co = (radius * math.cos(a), radius * math.sin(a), z, 1)
    ob = bpy.data.objects.new("helix", cu)
    scene.collection.objects.link(ob)
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.convert(target="MESH")
    return add(ob, mat, smooth=True)


ROPE_TILE = 16 / PX_PER_UNIT
cyl((0, 0, 0), 0.06, ROPE_TILE * 5, "hemp_dark", verts=8)           # dark core shows in the grooves
for k in range(2):
    helix(k * math.pi, ROPE_TILE / 2, 0.045, 0.05, -ROPE_TILE * 2.5, ROPE_TILE * 2.5, "hemp")
prop("rope", 6, 48, (0, 0), samples=96)

# ---- rope anchor: piton head flush with the rock above, an eye, and the rope knotted on
# (anchor: top centre = rock face; the rope continues from the bottom centre)
box((0, 0, -0.035), (0.38, 0.14, 0.07), "iron_dark")
box((0, 0, -0.085), (0.08, 0.06, 0.06), "iron")
torus((0, -0.03, -0.2), 0.095, 0.026, "steel", rot=(math.radians(90), 0, 0))
ball((0, 0.02, -0.345), 0.075, "hemp", scale=(1.2, 1, 0.8))
cyl((0, 0.02, -0.41), 0.09, 0.12, "hemp")
prop("rope_anchor", 10, 10, (0, -5 / PX_PER_UNIT), samples=96)

# ---- merchant stall for the surface camp (anchor: bottom centre = ground line)
for sx in (-1.6, 1.6):
    box((sx, 0.6, 1.95), (0.14, 0.14, 4.0), "wood")                     # back posts
    box((sx, -0.6, 1.5), (0.14, 0.14, 3.1), "wood")                     # front posts
box((0, 0.66, 2.35), (3.2, 0.04, 2.9), "canvas_back")                    # back wall cloth
box((0, -0.62, 2.98), (3.5, 0.12, 0.12), "wood_dark")                    # front cross beam
# striped awning sloping down to the front, with a ragged hanging edge
slope = math.atan2(3.95 - 3.0, 1.6)
for i in range(9):
    x = -1.8 + i * 0.45
    mat = "canvas_a" if i % 2 == 0 else "canvas_b"
    box((x, -0.05, 3.48), (0.46, 1.9, 0.04), mat, rot=(-slope, 0, 0))
    for j in range(2):
        ln = rng.uniform(0.18, 0.42)
        tx = x - 0.11 + j * 0.22 + rng.uniform(-0.03, 0.03)
        cone((tx, -0.95, 3.03 - ln / 2), 0.12, ln, mat, rot=(math.radians(180), 0, rng.uniform(-0.4, 0.4)), verts=3)
# counter: plank front and top, a few lumps of ore on it
box((0, -0.3, 1.1), (3.0, 0.8, 0.1), "plank")
box((0, -0.68, 0.55), (2.9, 0.06, 1.0), "wood")
for x in (-1.0, -0.3, 0.4, 1.1):
    box((x, -0.72, 0.55), (0.05, 0.03, 1.0), "wood_dark")
for x, mat in ((-0.7, "gold"), (-0.45, "ore_rock"), (0.25, "copper"), (0.75, "ore_rock")):
    ball((x, -0.45, 1.24), rng.uniform(0.1, 0.14), mat, scale=(1.2, 1, 0.8))
# lantern hanging from the front beam
y = chain(-1.25, 2.92, 2)
box((-1.25, -0.62, y - 0.03), (0.24, 0.2, 0.05), "iron_dark")
box((-1.25, -0.62, y - 0.22), (0.19, 0.16, 0.32), "glass")
box((-1.25, -0.62, y - 0.41), (0.24, 0.2, 0.05), "iron_dark")
cone((-1.25, -0.62, y + 0.02), 0.13, 0.08, "iron_dark")
# crate of ore beside the counter
box((2.02, -0.85, 0.3), (0.6, 0.5, 0.6), "plank")
box((2.02, -1.11, 0.3), (0.62, 0.03, 0.08), "wood_dark")
for i in range(7):
    ball((2.02 + rng.uniform(-0.22, 0.22), -0.85 + rng.uniform(-0.15, 0.1), 0.62 + rng.uniform(0, 0.12)),
         rng.uniform(0.08, 0.13), ("gold", "ore_rock", "copper", "ore_rock")[i % 4])
# small sign on a stake, painted with a coin
box((-2.05, -0.2, 0.6), (0.07, 0.07, 1.25), "wood_dark")
box((-2.05, -0.26, 1.15), (0.62, 0.05, 0.42), "plank")
cyl((-2.05, -0.3, 1.15), 0.12, 0.03, "paint", rot=(math.radians(90), 0, 0), verts=10)
prop("stall", 112, 96, (0, 48 / PX_PER_UNIT), samples=96)

# ---------------------------------------------------------------- render each prop alone
all_objs = [o for objs, *_ in PROPS.values() for o in objs]
for name, (objs, w, h, centre, samples) in PROPS.items():
    scene.cycles.samples = samples
    for o in all_objs:
        o.hide_render = o not in objs
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    cam_data.ortho_scale = max(w, h) / PX_PER_UNIT
    cam.location = (centre[0], -10, centre[1])
    for clay in (False, True):
        set_mode(clay)
        scene.render.filepath = os.path.join(OUT, f"{name}_{'clay' if clay else 'flat'}.png")
        bpy.ops.render.render(write_still=True)
print("PROPS_DONE", list(PROPS))
