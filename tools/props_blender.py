"""Models the cave props in Blender and renders flat + clay + normal passes for each.

Run headless:
  blender -b --factory-startup -P tools/props_blender.py -- <out_dir> [name,name,...]
(the optional list renders only those props; an animated prop by its base name, e.g. fire).
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

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "/tmp/props"
ONLY = set(ARGS[1].split(",")) if len(ARGS) > 1 else None   # optional: render just these props
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
    # crew tools and hazards
    "dyn": "#b8322a", "dyn_end": "#d8b48a", "tape": "#2e2a28", "spark": "#fff4c8",
    "flare_body": "#a8342c", "flare_cap": "#2a2628", "flare": "#ff3a2a", "flare_hot": "#ffc8a8",
    "ext_red": "#c0302a", "rubber": "#2a2628", "fire_r": "#e8401a",
    # fungal layer
    "cap": "#22384a", "cap_m": "#3e2244", "stem": "#b4c0b8", "leaf": "#1e3a3a", "pod": "#203440",
    "glow_c": "#5ae8f0", "glow_m": "#f060d8",
    # ice layer
    "ice": "#a8d4ec", "ice_dark": "#6894b8", "ice_lit": "#d4ecf8", "ice_glow": "#9ff8ff",
    # ruins layer
    "ruin": "#464a56", "ruin_dark": "#2c2e38", "ruin_void": "#121418", "rune": "#4ff0d0",
}
GLOW = {"glass", "cryst_p", "cryst_t", "lava", "lava_hot", "spark", "flare", "flare_hot", "fire_r",
        "glow_c", "glow_m", "ice_glow", "rune"}   # these stay bright (emissive) in the clay pass too

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


# ================================================================ crew tools, hazards and layer props
# Modelled in game px: x right, z up from the floor, d = depth (smaller = nearer the viewer).
# Thin features (runes, seams) sit on whole px so they land on single pixels.
rng3 = random.Random(77)     # own stream: the props above keep their shapes


def pbox(x0, z0, x1, z1, mat, d0=-2.0, d1=2.0, rot=0.0):
    """Box over the px rect x0..x1, z0..z1, from depth d0 to d1, turned rot degrees (top toward +x)."""
    return box(((x0 + x1) / 2 * U, (d0 + d1) / 2 * U, (z0 + z1) / 2 * U),
               ((x1 - x0) * U, (d1 - d0) * U, (z1 - z0) * U), mat, rot=(0, math.radians(rot), 0))


def prod(x0, z0, x1, z1, r, mat, d=0.0, verts=10, r2=None, smooth=True):
    """Cylinder (or a cone tapering to r2) from px point (x0, z0) to (x1, z1) at depth d."""
    a, b = Vector((x0 * U, d * U, z0 * U)), Vector((x1 * U, d * U, z1 * U))
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r * U, radius2=(r if r2 is None else r2) * U,
                                    depth=(b - a).length, location=(a + b) / 2)
    o = bpy.context.active_object
    o.rotation_euler = (b - a).to_track_quat("Z", "Y").to_euler()
    return add(o, mat, smooth=smooth)


def pball(x, z, r, mat, d=0.0, scale=(1, 1, 1)):
    return ball((x * U, d * U, z * U), r * U, mat, scale=scale)


def pdisc(x, z, r, mat, d0=-1.0, d1=0.0, verts=16):
    """Round plate facing the viewer."""
    return cyl((x * U, (d0 + d1) / 2 * U, z * U), r * U, (d1 - d0) * U, mat, rot=(math.radians(90), 0, 0), verts=verts)


def pring(x, z, r, t, mat, d=0.0, segs=20):
    """Ring facing the viewer."""
    bpy.ops.mesh.primitive_torus_add(major_radius=r * U, minor_radius=t * U, major_segments=segs, minor_segments=4,
                                     location=(x * U, d * U, z * U), rotation=(math.radians(90), 0, 0))
    return add(bpy.context.active_object, mat, smooth=True)


def pcurve(points, r, mat, d=0.0):
    """Thick poly line through px points (fuses, hoses, hooks)."""
    cu = bpy.data.curves.new("c", "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = r * U
    cu.bevel_resolution = 2
    sp = cu.splines.new("POLY")
    sp.points.add(len(points) - 1)
    for p, (x, z) in zip(sp.points, points):
        p.co = (x * U, d * U, z * U, 1)
    ob = bpy.data.objects.new("c", cu)
    scene.collection.objects.link(ob)
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.convert(target="MESH")
    return add(ob, mat, smooth=True)


def prock(x, z, r, mat, flat=0.8, rng=None):
    """Chunky faceted stone (like the boulder), r px, squashed by flat."""
    rng = rng or rng3
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=r * U, location=(x * U, 0, z * U))
    o = bpy.context.active_object
    for v in o.data.vertices:
        v.co *= rng.uniform(0.8, 1.12)
    o.scale = (1.0, 0.9, flat)
    o.rotation_euler = (rng.uniform(-0.4, 0.4), rng.uniform(0, 6.28), rng.uniform(-0.3, 0.3))
    return add(o, mat)


def hang(name, w, h, samples=96):
    """Close a prop that hangs from a ceiling: the sprite's top row is the ceiling (z = 0)."""
    prop(name, w, h, (0, -h / 2 * U), samples)


def place(objs, pivot, rot):
    """Turn objects (modelled around pivot, unrotated) about pivot by the 3x3 matrix rot."""
    for o in objs:
        o.location = rot @ (o.location - pivot) + pivot
        o.rotation_euler = (rot @ o.rotation_euler.to_matrix()).to_euler()


# 4 x 5 rune glyphs (top row first) and 3 x 4 small ones for narrow stones
GLYPHS = [["####", "#...", "###.", "#...", "#..."], [".##.", "#..#", ".##.", "..#.", "..#."],
          ["#..#", "#.#.", "##..", "#.#.", "#..#"], ["#.##", "#.#.", "###.", "..#.", "..#."],
          ["...#", "..#.", ".#..", "####", "#..."], ["##.#", ".#.#", ".###", ".#..", "##.."],
          ["#..#", "####", ".#..", ".#..", ".###"], [".#..", "###.", ".#.#", ".###", "...#"]]
GLYPHS_S = [["#.#", ".#.", "#.#", "..#"], ["##.", "#.#", "##.", "#.."], [".#.", "###", ".#.", "#.#"],
            ["#..", "###", "..#", ".##"], ["#.#", "###", "#.#", ".#."]]


def glyph(x, z, pattern, d, mat="rune"):
    """Carved rune: one 1 px block per '#'; (x, z) is its top-left px corner."""
    for row, line in enumerate(pattern):
        for col, c in enumerate(line):
            if c == "#":
                pbox(x + col, z - row - 1, x + col + 1, z - row, mat, d - 0.4, d)


def dome(r, flat, mat, segs=16):
    """Upper half of a sphere (a mushroom cap), base at its origin."""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=8, radius=r * U, location=(0, 0, 0))
    o = bpy.context.active_object
    bm = bmesh.new()
    bm.from_mesh(o.data)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-6], context="VERTS")
    bm.to_mesh(o.data)
    bm.free()
    o.scale = (1, 1, flat)
    return add(o, mat, smooth=True)


def mushroom(x, h, cap_r, cap_mat, gill_mat, stem_r, lean=0.0, tilt=-9, spots=(), rng=None, flat=0.62):
    """Stem curving up to (x + lean, h), a domed cap tipped toward the viewer so its glowing gills show,
    and glowing spots [(mat, size)] scattered over the front of the cap."""
    rng = rng or rng3
    n = 4
    pts = [(x + lean * (i / n) ** 2 + 0.25 * stem_r * math.sin(i / n * math.pi), h * i / n) for i in range(n + 1)]
    for i in range(n):
        r0, r1 = stem_r * (1.2 - 0.35 * i / n), stem_r * (1.2 - 0.35 * (i + 1) / n)
        prod(*pts[i], *pts[i + 1], r0, "stem", r2=r1)
        pball(*pts[i + 1], r1, "stem")
    pball(x, stem_r * 0.4, stem_r * 1.5, "stem", scale=(1, 1, 0.45))            # foot
    cx, cz = pts[-1]
    pivot = Vector((cx * U, 0, (cz + 0.12 * cap_r) * U))
    cap = dome(cap_r, flat, cap_mat)
    depth = 0.28 * cap_r
    bpy.ops.mesh.primitive_cone_add(vertices=16, radius1=stem_r * U, radius2=cap_r * 0.97 * U, depth=depth * U,
                                    location=(0, 0, -depth / 2 * U))
    gills = add(bpy.context.active_object, gill_mat)
    parts = [cap, gills]
    for mat, size in spots:
        th = rng.uniform(math.pi * 1.15, math.pi * 1.85)                         # front half of the cap
        ph = rng.uniform(0.3, 1.1)
        loc = Vector((cap_r * math.cos(ph) * math.cos(th), cap_r * math.cos(ph) * math.sin(th),
                      flat * cap_r * math.sin(ph))) * U
        parts.append(ball(loc, size * U, mat, scale=(1, 1, 0.6)))
    for o in parts:
        o.location = o.location + pivot
    rot = Matrix.Rotation(math.radians(tilt), 3, "X") @ Matrix.Rotation(math.radians(lean * 4), 3, "Y")
    place(parts, pivot, rot)


# ---- dynamite: three red sticks taped together, a fuse with a spark (anchor: bottom centre)
for x, d in ((-2.6, 0.8), (2.6, 0.8), (0, -1.2)):
    prod(x, 0.4, x, 9.4, 1.45, "dyn", d=d, verts=12)
    prod(x, 9.4, x, 9.9, 1.3, "dyn_end", d=d, verts=12)
for z in (2.2, 6.6):
    pbox(-4.2, z, 4.2, z + 1.1, "tape", -2.9, 2.6)
pcurve([(0, 9.8), (0.3, 11.0), (1.2, 11.9), (2.3, 12.2)], 0.45, "hemp_dark", d=-1.2)
pball(2.6, 12.4, 0.95, "spark", d=-1.6)
for dx, dz in ((1.2, 0.4), (-0.6, 0.9), (0.9, -0.8)):
    pball(2.6 + dx, 12.4 + dz, 0.45, "lava_hot", d=-1.4)
ground("dynamite", 10, 14)

# ---- road flare: paper stick with a cap at the foot, burning red tip (anchor: bottom centre)
prod(0, 0.3, 0, 1.8, 2.1, "flare_cap", verts=12)
prod(0, 1.8, 0, 6.8, 1.95, "flare_body", verts=12)
prod(0, 3.6, 0, 4.6, 2.02, "wax", verts=12)                                       # label band
prod(0, 6.8, 0, 8.4, 1.9, "flare", verts=12)                                     # burning end
prod(-0.1, 8.0, 0.4, 10.9, 1.6, "flare", r2=0.2, verts=10)                        # flame tongue
pball(0, 8.6, 0.95, "flare_hot", d=-1.9)                                          # white-hot core
ground("flare", 6, 12)

# ---- grappling hook head: shank with an eye, two curved barbed prongs (anchor: bottom centre)
prod(0, 2.4, 0, 9.0, 0.85, "iron")
pring(0, 10.1, 1.25, 0.5, "steel")
pball(0, 2.3, 1.5, "iron_dark")
for s in (-1, 1):
    pcurve([(0, 2.3), (s * 2.2, 1.2), (s * 3.7, 1.5), (s * 4.5, 3.0), (s * 4.6, 4.8)], 0.65, "iron")
    prod(s * 4.6, 4.7, s * 4.2, 6.9, 0.8, "steel", r2=0.05, verts=6)               # barb tip
pcurve([(0, 2.3), (0, 1.2), (0.4, 1.0)], 0.6, "iron", d=-1.6)                       # third prong, toward the viewer
prod(0.4, 1.0, 0.9, 3.6, 0.75, "steel", d=-3.0, r2=0.05, verts=6)
ground("grapple", 12, 12)

# ---- ore sled: iron-shod runners curling up at the front, plank deck, a box of ore (anchor: bottom centre)
for d, mat in ((2.6, "iron_dark"), (-2.6, "iron")):
    pcurve([(-12.3, 1.0), (8.8, 1.0), (11.3, 1.6), (12.5, 3.3), (12.2, 5.2)], 0.7, mat, d=d)
for x in (-10, -3, 4, 9.5):
    pbox(x - 0.6, 1.4, x + 0.6, 3.1, "wood_dark", -3.2, 3.2)
pbox(-12.4, 3.0, 11.0, 4.6, "plank", -3.8, 3.8)
for x in (-6.4, -0.6, 5.2):
    pbox(x, 3.0, x + 0.4, 4.6, "wood_dark", -3.9, -3.7)                           # plank seams
pbox(-10.0, 4.6, 5.0, 10.0, "plank", -3.2, 3.2)                                   # the box
for z0, z1 in ((4.6, 5.5), (9.1, 10.0)):
    pbox(-10.2, z0, 5.2, z1, "wood_dark", -3.4, 3.4)
for x in (-10.2, 4.3):
    pbox(x, 4.6, x + 0.9, 10.0, "wood_dark", -3.4, 3.4)
pball(-2.5, 10.0, 6.0, "ore_rock", scale=(1.15, 0.5, 0.3))                             # heaped ore
for i in range(9):
    x = -8.0 + i * 1.3 + rng3.uniform(-0.4, 0.4)
    pball(x, 10.4 + 1.6 * (1 - abs(x + 2.5) / 7) + rng3.uniform(-0.3, 0.3), rng3.uniform(1.0, 1.5),
          ("gold", "ore_rock", "copper", "ore_rock", "gold", "ore_rock", "copper", "ore_rock", "gold")[i],
          d=rng3.uniform(-2, 0), scale=(1.2, 1, 0.8))
pcurve([(11.6, 4.4), (12.6, 5.6), (12.2, 6.6), (11.2, 6.2)], 0.45, "hemp")           # tow loop
ground("sled", 28, 14)

# ---- fire extinguisher: red bottle, valve head with a lever, hose down the side (anchor: bottom centre)
X = -0.6
prod(X, 0.5, X, 9.6, 2.85, "ext_red", verts=16)
pball(X, 9.6, 2.85, "ext_red", scale=(1, 1, 0.42))
prod(X, 0.3, X, 1.3, 3.0, "iron_dark", verts=16)
pbox(X - 2.0, 4.0, X + 1.6, 7.0, "wax", -3.3, -2.6)                                  # label
pbox(X - 2.0, 5.2, X + 1.6, 5.8, "ext_red", -3.4, -3.25)
prod(X, 10.6, X, 11.6, 1.0, "steel")
pbox(X - 1.5, 11.4, X + 1.8, 12.6, "iron_dark", -1.2, 1.2)
prod(X - 0.4, 12.9, X + 3.6, 13.7, 0.45, "steel")                                   # lever
prod(X + 0.4, 12.0, X + 3.6, 12.2, 0.4, "iron")                                     # handle
pcurve([(X + 1.6, 12.0), (X + 3.6, 11.3), (X + 4.2, 9.0), (X + 3.9, 5.2), (X + 3.5, 3.8)], 0.5, "rubber", d=-1.0)
prod(X + 3.5, 3.9, X + 3.4, 2.4, 0.7, "iron_dark", d=-1.0)
ground("extinguisher", 10, 16)


# ---- fire: 8 frames of licking flames (anchor: bottom centre). Each frame is modelled again:
# tongues stretch and sway on their own phases, blobs break off the tips and rise. Nested
# layers (red behind, orange, yellow, white-hot in front) make the flame's hot core.
FIRE_FRAMES = 8
TONGUES = [(0.0, 17.0, 3.8, 0.0, 0.1), (-3.4, 11.5, 2.9, 0.35, 0.6), (3.4, 12.5, 2.9, 0.7, 0.3),
           (-5.2, 6.5, 1.8, 0.15, 0.85), (5.2, 7.0, 1.8, 0.55, 0.45)]          # x, height, radius, phases
LAYERS = [("fire_r", 1.0, 1.0, 2.5), ("lava", 0.74, 0.78, 0.5), ("lava_hot", 0.5, 0.52, -1.5), ("spark", 0.28, 0.26, -3.0)]
BLOBS = [(0.6, 0.0, 1.7), (-2.6, 0.4, 1.3), (2.8, 0.75, 1.2)]                # x, phase, radius


def fire_frame(f):
    t = f / FIRE_FRAMES
    wave = lambda ph, k=1: math.sin(2 * math.pi * (k * t + ph))                  # noqa: E731, loops
    for x, hgt, r, ph, ph2 in TONGUES:
        h = hgt * (0.84 + 0.16 * wave(ph) + 0.05 * wave(ph2, 2))
        sway = 0.22 * wave(ph2) + 0.08 * wave(ph, 3)
        for mat, ks, kh, d in LAYERS:
            rr, hh = r * ks, h * kh
            if hh < rr * 1.6:
                continue
            pball(x, rr, rr, mat, d=d)
            prod(x, rr, x + sway * hh, hh, rr, mat, d=d, r2=0.15, verts=10)
    pball(0, 1.6, 6.6, "fire_r", d=2.5, scale=(1, 1, 0.3))                          # glowing bed
    pball(0, 1.4, 4.6, "lava", d=0.5, scale=(1, 1, 0.3))
    for x, ph, r in BLOBS:                                                           # licks that break off
        k = (t + ph) % 1
        z = 13 + k * 9.5
        rr = r * (1 - k * 0.75)
        if rr > 0.45:
            pball(x + 0.8 * math.sin(2 * math.pi * (k + ph)), z, rr, "lava" if k < 0.4 else "fire_r", d=0, scale=(0.9, 1, 1.25))
    ground(f"fire_{f}", 16, 24)


for f in range(FIRE_FRAMES):
    fire_frame(f)

# ---- rubble: a pile of broken rock (anchor: bottom centre)
for x, r, mat in ((-1.0, 5.0, "boulder"), (-7.0, 3.6, "rock"), (6.0, 4.0, "ore_rock"), (10.2, 2.0, "boulder"),
                  (-10.6, 1.8, "ore_rock")):
    prock(x, r * 0.75, r, mat)
for x, z, r, mat in ((2.6, 7.6, 3.0, "boulder"), (-4.4, 6.6, 2.7, "rock"), (7.8, 6.2, 2.0, "rock"),
                     (-8.2, 5.2, 1.6, "boulder")):
    prock(x, z, r, mat)
for i in range(7):                                                                  # grit at the foot
    x = rng3.choice((-1, 1)) * rng3.uniform(3, 11.5)
    prock(x, 0.7, rng3.uniform(0.7, 1.2), rng3.choice(("rock", "boulder", "ore_rock")))
ground("rubble", 26, 14)

# ---- fungal layer: big glowing mushroom, a small pair, a spore pod (anchor: bottom centre)
mushroom(0, 22, 11.2, "cap", "glow_c", 2.6, lean=1.2,
         spots=[("glow_c", 1.4), ("glow_c", 1.0), ("glow_c", 1.2), ("glow_m", 1.1), ("glow_c", 0.9), ("glow_m", 0.8)])
mushroom(-7.0, 4.5, 2.8, "cap_m", "glow_m", 0.8, lean=-0.6, spots=[("glow_c", 0.6)])
mushroom(7.6, 3.0, 2.1, "cap", "glow_c", 0.7, lean=0.4, spots=[])
for x in (-3.5, 3.0, -10.0, 10.5):
    pball(x, 0.4, 1.6, "leaf", scale=(1.3, 1, 0.5))
ground("mushroom_big", 26, 34)

mushroom(1.0, 8.0, 4.6, "cap_m", "glow_m", 1.25, lean=0.5, spots=[("glow_c", 0.8), ("glow_c", 0.6), ("glow_m", 0.6)])
mushroom(-3.4, 3.8, 2.3, "cap", "glow_c", 0.75, lean=-0.4, spots=[("glow_c", 0.5)])
pball(-1.2, 0.3, 1.4, "leaf", scale=(1.6, 1, 0.5))
ground("mushroom_small", 14, 16)

for a in (-1, 0, 1):                                                                 # leaves at the foot
    prod(0, 0.3, a * 3.8, 2.3 - abs(a) * 0.4, 1.2, "leaf", d=0.5 - abs(a) * 1.5, r2=0.1, verts=6)
prod(0, 0.2, 0, 2.6, 0.95, "leaf")
pball(0, 5.6, 3.2, "glow_c", scale=(1, 1, 1.15))                                     # glowing heart
for k in range(3):                                                                   # dark ribs around it
    rib = pball(0, 5.6, 3.6, "pod", scale=(0.25, 1, 1.12))
    rib.rotation_euler = (0, 0, math.radians(30 + 60 * k))
prod(0, 1.9, 0, 3.3, 1.0, "pod", r2=2.6, verts=10)                                    # cup under the bulb
prod(0, 9.2, 0, 10.4, 1.2, "pod", r2=0.4, verts=8)                                    # nub on top
pball(0, 10.3, 0.75, "glow_m", d=-0.6)
ground("spore_pod", 12, 12)

# ---- ice layer: an icicle hanging from the ceiling (anchor: top centre), a crystal cluster
r4 = random.Random(12)
prod(0, -0.6, 0.0, 0.0, 3.0, "ice_dark", r2=3.2, verts=8)                            # frozen onto the rock
o = prod(0.2, -0.3, 0.4, -20.0, 2.5, "ice", r2=0.05, verts=7, smooth=False)
for v in o.data.vertices:
    v.co.x *= r4.uniform(0.85, 1.12)
    v.co.y *= r4.uniform(0.85, 1.12)
prod(-1.7, -0.3, -2.2, -8.5, 1.25, "ice_dark", r2=0.05, verts=6, d=0.6, smooth=False)
prod(1.9, -0.3, 2.1, -11.5, 1.15, "ice", r2=0.05, verts=6, d=0.8, smooth=False)
prod(-0.5, -1.0, -0.1, -14.0, 0.45, "ice_lit", d=-2.2, r2=0.1, verts=5)             # wet highlight
hang("icicle", 8, 22)

pball(0, 0.6, 5.6, "ice_dark", scale=(1.15, 0.9, 0.22))                              # frozen base
for x, ang, ln, r, mat, core in ((0.2, 3, 11.0, 2.4, "ice", True), (-3.0, -22, 7.0, 1.8, "ice_dark", False),
                                 (3.2, 19, 8.0, 1.9, "ice", True), (-5.0, -40, 3.4, 1.2, "ice", False),
                                 (5.0, 36, 3.6, 1.2, "ice_dark", False), (1.4, 8, 4.5, 1.3, "ice_lit", False)):
    a = math.radians(ang)
    dx, dz = math.sin(a), math.cos(a)
    d = -1.2 if mat == "ice_lit" else 0.0
    prod(x, 0.5, x + dx * ln, 0.5 + dz * ln, r, mat, d=d, verts=6, smooth=False)
    prod(x + dx * ln, 0.5 + dz * ln, x + dx * (ln + 1.7 * r), 0.5 + dz * (ln + 1.7 * r), r, mat, d=d,
         r2=0.05, verts=6, smooth=False)
    if core:                                                                         # faint inner light
        prod(x + dx * 1.5, 2.0, x + dx * ln * 0.85, 0.5 + dz * ln * 0.85, 0.75, "ice_glow", d=-r * 0.9, verts=6)
ground("ice_crystal", 16, 20)

# ---- ruins layer: carved dark stone with teal runes (anchor: bottom centre)
# pillar: plinth, square shaft with a recessed rune panel, a capital broken off on one side
pbox(-7, 0, 7, 2, "ruin_dark", -5, 5)
pbox(-6, 2, 6, 4, "ruin", -4.6, 4.6)
pbox(-4.5, 4, 4.5, 33, "ruin", -4, 4)
for x in (-4.6, 3.6):
    pbox(x, 4, x + 1, 33, "ruin_dark", -4.1, -3.9)                                    # edge chamfers
pbox(-3, 6, 3, 31, "ruin_dark", -4.15, -3.95)                                         # rune panel
for k, g in enumerate((0, 3, 6, 1)):
    glyph(-2, 30 - k * 6, GLYPHS[g], -4.15)
pbox(-6, 33, 6, 35, "ruin_dark", -5, 5)
pbox(-7, 35, 7, 38, "ruin", -5.5, 5.5)
pbox(-7, 38, 2.5, 40, "ruin", -5.5, 5.5)                                              # top slab, broken off
prock(4.0, 38.4, 1.6, "ruin", flat=0.7)
pbox(-1.0, 16.5, 4.0, 17.2, "ruin_void", -4.3, -4.1, rot=-28)                          # crack
prock(6.2, 0.9, 1.3, "ruin_dark")                                                    # fallen chip
ground("ruin_pillar", 16, 42)

# statue: a hooded figure on a rune-carved plinth, hands clasped round a glowing orb, eyes in the dark hood
pbox(-10, 0, 10, 2, "ruin_dark", -6, 6)
pbox(-9, 2, 9, 9, "ruin", -5, 5)
for k, g in enumerate((2, 5, 7)):
    glyph(-7 + k * 5, 8, GLYPHS[g], -5.0)
prod(0, 9, 0, 23.5, 7.0, "ruin", r2=4.2, verts=12)                                    # robe
for x, rot in ((-3.6, 8), (-1.2, 2), (1.6, -3), (4.0, -9)):
    pbox(x - 0.3, 9.3, x + 0.3, 19, "ruin_dark", -7.3, -6.8, rot=rot)                 # folds
pball(0, 23, 5.4, "ruin", scale=(1, 0.85, 0.5))                                      # shoulders
for s in (-1, 1):
    prod(s * 4.4, 22, s * 1.4, 16.4, 1.9, "ruin", d=-3.0)                             # sleeves
pball(0, 16.0, 2.0, "ruin_dark", d=-4.4)                                              # hands
pball(0, 17.6, 1.5, "rune", d=-5.6)                                                   # orb
prod(0, 24, 0, 21.5, 4.6, "ruin", r2=5.6, verts=12)                                   # hood drape
pball(0, 27.6, 4.6, "ruin", scale=(1, 1, 1.1))                                        # hood
prod(0.0, 30.5, 0.8, 34.0, 3.0, "ruin", r2=0.3, verts=10)                             # hood peak
pball(0, 27.0, 3.0, "ruin_void", d=-3.4, scale=(0.95, 0.6, 1.1))                       # face in shadow
for x in (-2, 1):
    pbox(x, 27, x + 1, 28, "rune", -5.6, -5.2)                                        # eyes
ground("ruin_statue", 24, 36)

# door: a sealed arch, rune seal across the slab, runes up both jambs
pbox(-15, 0, 15, 2, "ruin_dark", -5, 5)
for s in (-1, 1):
    x0, x1 = sorted((s * 9, s * 14))
    pbox(x0, 2, x1, 23, "ruin", -4, 4)
    for k, g in enumerate((0, 2, 4) if s < 0 else (1, 3, 0)):
        glyph(x0 + 1, 21 - k * 6, GLYPHS_S[g], -4.0)
N_STONES = 7
for k in range(N_STONES):                                                            # arch stones
    a = math.pi * (k + 0.5) / N_STONES
    key = k == N_STONES // 2
    rr = 11.5 + (0.4 if key else 0)
    hw = 11.5 * math.pi / N_STONES / 2 - 0.25
    cx, cz = rr * math.cos(a), 23 + rr * math.sin(a)
    o = pbox(cx - hw, cz - 2.5 - (0.4 if key else 0), cx + hw, cz + 2.5 + (0.4 if key else 0),
             "ruin_dark" if key else "ruin", -4.4 if key else -4, 4, rot=math.degrees(math.pi / 2 - a))
pbox(-9, 2, 9, 23, "ruin_dark", -2.5, 3)                                              # the sealed slab
pdisc(0, 23, 9, "ruin_dark", -2.5, 3, verts=28)
pbox(0, 2, 1, 32, "ruin_void", -2.8, -2.5)                                            # seam between the leaves
pring(0, 15.5, 5.0, 0.5, "rune", d=-2.8, segs=28)                                     # the seal
glyph(-2, 18, GLYPHS[7], -2.8)
for z in (8.5, 22.5):
    pbox(0, z, 1, z + 1, "rune", -3.2, -2.8)
ground("ruin_door", 32, 38)


# ---------------------------------------------------------------- render each prop alone
all_objs = [o for objs, *_ in PROPS.values() for o in objs]
for name, (objs, w, h, centre, samples) in PROPS.items():
    if ONLY and name not in ONLY and name.rstrip("0123456789").rstrip("_") not in ONLY:
        continue
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
print("PROPS_DONE", [n for n in PROPS if not ONLY or n in ONLY or n.rstrip("0123456789").rstrip("_") in ONLY])
