"""Models the cave props in Blender and renders flat + clay + normal passes for each.

Run headless:
  blender -b --factory-startup -P tools/props_blender.py -- <out_dir>
Same scale as the miner (22 px per unit). tools/props_sheet.py makes the sprites.
"""
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_pass import PASSES, normal_shader, set_view  # noqa: E402

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
    "canvas_old": "#8a7a5e", "canvas_dark": "#5e5240", "wax": "#d8d0b4", "paper": "#d6c890",
    "ink": "#3a2e22", "straw": "#b49a52", "leather": "#6e4028", "leather_dark": "#3a2016",
    "lava": "#ff7a1a", "lava_hot": "#ffd060", "lava_crust": "#4a1c10", "lava_rock": "#3a3034",
}
GLOW = {"glass", "cryst_p", "cryst_t", "lava", "lava_hot"}   # these stay bright (emissive) in the clay pass too

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

# ================================================================ abandoned mine camp (anchor: bottom centre)
U = 1 / PX_PER_UNIT          # one game px in world units
rng2 = random.Random(41)     # own stream: the props above keep their shapes


def ground(name, w, h, samples=96):
    """Close a prop whose sprite bottom row is the ground line (z = 0)."""
    prop(name, w, h, (0, h / 2 * U), samples)


def sheet_mesh(name, nx, ny, x0, x1, y0, y1, height, mats, holes=0.0, rng=None):
    """A cloth sheet: grid over x/y with z = height(x, y); faces randomly use one of mats and a
    fraction `holes` of them is torn out."""
    rng = rng or rng2
    bm = bmesh.new()
    vs = [[bm.verts.new((x0 + (x1 - x0) * i / nx, y0 + (y1 - y0) * j / ny,
                         height(x0 + (x1 - x0) * i / nx, y0 + (y1 - y0) * j / ny)))
           for j in range(ny + 1)] for i in range(nx + 1)]
    faces = []
    for i in range(nx):
        for j in range(ny):
            if rng.random() < holes:
                continue
            faces.append(bm.faces.new((vs[i][j], vs[i + 1][j], vs[i + 1][j + 1], vs[i][j + 1])))
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    add(ob, mats[0], smooth=True)
    for m in mats[1:]:
        ob.data.materials.append(material(m))
    for p in ob.data.polygons:
        if len(mats) > 1 and rng.random() > 0.7:
            p.material_index = rng.randrange(1, len(mats))
    return ob


# ---- collapsed tent: one pole still standing, the other snapped, canvas sagging to the ground
cyl((-0.56, 0, 0.55), 0.035, 1.1, "wood", rot=(0, math.radians(8), 0))
cyl((0.62, 0, 0.17), 0.035, 0.34, "wood", rot=(0, math.radians(-12), 0))           # snapped stump
cyl((0.45, -0.15, 0.04), 0.03, 0.5, "wood_dark", rot=(0, math.radians(84), math.radians(20)))
sheet_mesh("canvas", 14, 6, -0.88, 0.86, -0.32, 0.32,
           lambda x, y: max(0.02, (0.98 * math.exp(-3.2 * (x + 0.6) ** 2) + 0.28 * math.exp(-8 * (x - 0.6) ** 2))
                            * (1 - 0.75 * abs(y) / 0.32) + rng2.uniform(-0.025, 0.025)),
           ["canvas_old", "canvas_dark"], holes=0.08)
for sx, top in ((-0.88, (-0.62, 0.98)), (0.86, (0.62, 0.32))):                       # guy ropes + stakes
    a, b = Vector((top[0], -0.05, top[1])), Vector((sx, -0.1, 0.03))
    bpy.ops.mesh.primitive_cylinder_add(vertices=5, radius=0.012, depth=(b - a).length, location=(a + b) / 2)
    o = bpy.context.active_object
    o.rotation_euler = (b - a).to_track_quat("Z", "Y").to_euler()
    add(o, "hemp")
    cyl((sx, -0.1, 0.04), 0.022, 0.1, "wood_dark", verts=5)
ground("tent_ruin", 40, 26)

# ---- rough table with a candle stub and loose papers
box((0, 0, 0.46), (0.86, 0.4, 0.06), "plank", rot=(0, math.radians(1.5), 0))
for sx in (-0.36, 0.36):
    box((sx, -0.12, 0.22), (0.06, 0.06, 0.44), "wood_dark")
box((0, -0.12, 0.12), (0.72, 0.04, 0.04), "wood_dark")                               # stretcher
cyl((-0.22, 0, 0.53), 0.045, 0.09, "wax")
cyl((-0.22, 0, 0.59), 0.01, 0.04, "iron_dark", verts=4)                              # burnt wick
cyl((-0.22, 0, 0.495), 0.08, 0.012, "iron_dark", verts=10)                           # drip dish
box((0.14, -0.02, 0.505), (0.24, 0.18, 0.03), "paper", rot=(0, math.radians(3), 0))   # a stack of papers
box((0.44, -0.08, 0.41), (0.16, 0.14, 0.01), "paper", rot=(0, math.radians(72), 0))   # one slipping off the edge
ground("table", 22, 14)

# ---- broken bunk: posts, a lower bed with a mattress, the upper bunk caved in
for sx in (-0.6, 0.6):
    box((sx, 0, 0.38 if sx < 0 else 0.28), (0.07, 0.07, 0.76 if sx < 0 else 0.56), "wood")
box((0, 0, 0.22), (1.26, 0.36, 0.06), "wood_dark")                                   # lower frame
box((0, 0, 0.29), (1.12, 0.34, 0.08), "straw", rot=(0, math.radians(1), 0))         # mattress
box((-0.28, 0, 0.6), (0.66, 0.34, 0.05), "wood_dark", rot=(0, math.radians(-4), 0))  # upper rail, still up
box((0.3, -0.05, 0.42), (0.62, 0.3, 0.04), "plank", rot=(0, math.radians(-28), 0))    # upper planks caved in
box((0.62, 0.05, 0.05), (0.3, 0.08, 0.04), "plank", rot=(0, math.radians(12), math.radians(25)))
ground("bunk", 30, 18)

# ---- opened loot crate: lid off and leaning on it, straw spilling over the rim
box((0, 0, 0.21), (0.46, 0.42, 0.42), "plank")
box((0, -0.215, 0.05), (0.48, 0.02, 0.06), "wood_dark")
box((0, -0.215, 0.38), (0.48, 0.02, 0.06), "wood_dark")
box((-0.06, -0.218, 0.21), (0.05, 0.02, 0.36), "wood_dark")
for k in range(6):
    cyl((rng2.uniform(-0.18, 0.18), rng2.uniform(-0.15, 0.15), 0.44 + rng2.uniform(0, 0.04)), 0.012,
        rng2.uniform(0.1, 0.18), "straw", rot=(rng2.uniform(-0.8, 0.8), rng2.uniform(-1.2, 1.2), 0), verts=4)
box((0.31, 0.05, 0.2), (0.05, 0.4, 0.42), "plank", rot=(0, math.radians(-14), 0))     # lid against the side
ground("crate_open", 16, 14)

# ---- yellowed note nailed to a wall (anchor: bottom centre of the sprite)
sheet_mesh("note", 3, 4, -0.13, 0.13, -0.17, 0.17, lambda x, z: 0.0, ["paper"])
o = current[-1]
o.rotation_euler = (math.radians(90), 0, math.radians(3))
o.location = (0, 0, 0.2)
for v in o.data.vertices:                                                           # curled lower corner
    if v.co.x > 0.08 and v.co.y < -0.1:
        v.co.z += 0.05
for k in range(3):                                                                  # scrawled lines
    box((-0.02, -0.01, 0.25 - k * 0.09), (0.17 - 0.05 * (k % 2), 0.005, 0.03), "ink")
cyl((0, -0.025, 0.335), 0.034, 0.03, "iron", rot=(math.radians(90), 0, 0), verts=8)    # nail head
ground("note", 8, 10)

# ---- small leather journal lying on the floor, tipped a little toward the viewer
jr = []
for dz in (-0.03, 0.03):                                                              # front and back cover
    jr.append(box((0, 0, 0.12 + dz), (0.38, 0.27, 0.018), "leather"))
jr.append(box((0.015, -0.005, 0.12), (0.35, 0.27, 0.045), "paper"))                    # cream page block
jr.append(box((-0.185, 0, 0.12), (0.02, 0.27, 0.078), "leather"))                     # spine
jr.append(box((0.1, 0, 0.12), (0.035, 0.285, 0.085), "leather_dark"))                 # strap
tilt = Matrix.Rotation(math.radians(55), 3, "X")                                    # turn the whole book
for o in jr:                                                                         # about one pivot
    o.location = tilt @ (o.location - Vector((0, 0, 0.12))) + Vector((0, 0, 0.16))
    o.rotation_euler = (math.radians(55), 0, 0)
ground("journal", 10, 8)

# ---- barrel: bulging staves with iron hoops
bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.2, depth=0.62, location=(0, 0, 0.31))
o = bpy.context.active_object
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.subdivide(number_cuts=3)
bpy.ops.object.mode_set(mode="OBJECT")
for v in o.data.vertices:                                                           # bulge in the middle
    v.co.x *= 1 + 0.22 * (1 - (v.co.z / 0.31) ** 2)
    v.co.y *= 1 + 0.22 * (1 - (v.co.z / 0.31) ** 2)
add(o, "wood")
for z, r in ((0.07, 0.215), (0.55, 0.215), (0.2, 0.235), (0.42, 0.235)):
    torus((0, 0, z), r, 0.024, "iron")
cyl((0, 0, 0.62), 0.18, 0.01, "wood_dark", verts=12)
ground("barrel", 12, 16)

# ---- lamp post: wooden post, an arm with a hook, a lantern hanging from it
box((0, 0, 0.62), (0.08, 0.08, 1.24), "wood")
box((0.07, 0, 1.2), (0.2, 0.06, 0.05), "wood_dark")                                   # arm
torus((0.13, 0, 1.13), 0.025, 0.008, "iron_dark", rot=(math.radians(90), 0, 0))       # hook
box((0.13, 0, 1.07), (0.08, 0.08, 0.02), "iron_dark")
box((0.13, 0, 1.01), (0.06, 0.06, 0.09), "glass")
box((0.13, 0, 0.955), (0.08, 0.08, 0.02), "iron_dark")
box((0, 0, 0.03), (0.14, 0.14, 0.06), "wood_dark")                                   # foot
ground("lamp_post", 8, 30)

# ---- lava pool: 8 frames of a bubbling pool in a rocky basin (anchor: bottom centre). Seen
# from the side, so the pool's glowing face shows between rocks at its ends. Each frame is
# modelled separately: the surface ripples, hot streaks wander, three bubbles swell and burst.
LAVA_FRAMES = 8
BUBBLES = [(-0.35, 0.0), (0.12, 0.35), (0.45, 0.7)]          # x, phase offset
STREAKS = [(-0.5, 0.0, 0.1), (-0.12, 0.4, 0.08), (0.28, 0.2, 0.12), (0.55, 0.65, 0.07)]   # x, phase, width


def lava_frame(f):
    t = f / LAVA_FRAMES
    wave = lambda ph: math.sin(2 * math.pi * (t + ph))          # noqa: E731, loops over the 8 frames

    def surface(x, y):
        return 0.19 + 0.012 * math.sin(2 * math.pi * (x * 3 - t)) + 0.008 * math.sin(2 * math.pi * (y * 5 + t))

    box((0, 0.02, 0.035), (1.62, 0.44, 0.07), "lava_rock")                            # basin floor
    box((0, 0.0, 0.125), (1.5, 0.4, 0.13), "lava")                                    # the molten body
    sheet_mesh("lava_skin", 16, 3, -0.75, 0.75, -0.2, 0.2, surface, ["lava_hot", "lava", "lava_crust"],
               rng=random.Random(3))                                                 # same patches every frame
    for x, ph, w in STREAKS:                                                         # hot streaks on its face
        box((x + 0.04 * wave(ph), -0.205, 0.13 + 0.015 * wave(ph + 0.25)), (w, 0.01, 0.035), "lava_hot")
    for x, ph in ((-0.3, 0.1), (0.4, 0.55)):                                         # cooled crust drifting
        box((x + 0.05 * wave(ph), -0.21, 0.09), (0.12, 0.012, 0.03), "lava_crust")
    for bx, ph in BUBBLES:
        k = (t + ph) % 1
        if k < 0.85:                                                                 # swells, then bursts
            r = 0.025 + 0.06 * k
            ball((bx, -0.05, 0.19 + r * 0.5), r, "lava_hot" if k > 0.5 else "lava")
        else:
            for sgn in (-1, 1):                                                      # spatter as it pops
                ball((bx + sgn * 0.06, -0.06, 0.28), 0.018, "lava_hot")
    r2 = random.Random(9)                                                            # same rocks each frame
    for x, h, r in ((-0.86, 0.3, 0.17), (-0.7, 0.2, 0.12), (0.72, 0.22, 0.13), (0.87, 0.28, 0.16),
                    (-0.45, 0.06, 0.08), (0.15, 0.05, 0.07)):
        ball((x, -0.22 + r2.uniform(-0.03, 0.03), h * 0.55), r, "lava_rock", scale=(1.3, 1, h / r))
    ground(f"lava_{f}", 40, 10)


for f in range(LAVA_FRAMES):
    lava_frame(f)


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
    for mode in PASSES:
        set_mode(mode)
        scene.render.filepath = os.path.join(OUT, f"{name}_{mode}.png")
        bpy.ops.render.render(write_still=True)
print("PROPS_DONE", list(PROPS))
