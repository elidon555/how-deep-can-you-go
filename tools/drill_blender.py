"""Models the drilling machine (cutaway hull, back wall, drill head, stations) in Blender and
renders flat + clay + normal passes for each sprite. tools/drill_sheet.py makes the pixel art.

Run headless:
  blender -b --factory-startup -P tools/drill_blender.py -- <out_dir>

Units: 1 Blender unit = 1 game px, in the drill's local space. Every helper takes game
coordinates (x right, y DOWN, as in src/drill/drill.gd); Blender z is -y. The camera looks
along +Y, so a smaller Blender y is nearer the viewer.
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

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/drill"
os.makedirs(OUT, exist_ok=True)
rng = random.Random(7)

COLORS = {
    "steel": "#59606b", "steel_lit": "#7d8591", "steel_dark": "#3a3f47", "rust": "#6e4632",
    "rust_dark": "#4a3024", "soot": "#2a2a2e", "bolt": "#8d949f", "grate": "#4a5058",
    "hole": "#16181c", "hazard_y": "#e0b23a", "hazard_k": "#1a1714", "glass_red": "#7a1a14",
    "lens": "#e8e0c0", "rubber": "#1e1c1e",
    # back wall: dark and low contrast
    "back_steel": "#34373c", "back_rust": "#3a2f29", "back_wood": "#3a2c22", "back_wood_b": "#33271e",
    "back_seam": "#1e1b18", "pipe": "#5e4630", "pipe_band": "#7a5c3a", "cable": "#1a1a1d",
    "gauge_face": "#8f8874", "brass": "#8a7442", "needle": "#5a1810", "lamp": "#ffe2a8",
    # drill head
    "head": "#6f757e", "flute": "#3c4149", "carbide": "#c9ccd1",
    # stations
    "console": "#3b4048", "screen": "#0c1a1c", "slot": "#121316", "knob_r": "#c8322a",
    "knob_g": "#3fae5a", "knob_y": "#d0a03f", "furnace": "#2c2a2c", "furnace_lit": "#4a4446",
    "fire": "#ff8a2a", "fire_hot": "#ffd27a", "coal": "#242228", "bench": "#6b4a2e",
    "bench_dark": "#4a3320", "iron": "#7d8591", "tool": "#9aa3b2", "handle": "#7a5636",
    "cabinet": "#d8d4cc", "cross": "#c8322a",
}
RUSTY = {"steel": ("rust", 0.63), "steel_dark": ("rust_dark", 0.62), "back_steel": ("back_rust", 0.68),
         "furnace": ("rust_dark", 0.66), "soot": ("rust_dark", 0.7)}
STRIPES = {"hazard": ("hazard_y", "hazard_k", 6.0)}     # 45 degree stripes, period in px
UNLIT = {"lamp", "fire", "fire_hot", "screen"}          # stay at full colour in the clay pass

# ---------------------------------------------------------------- scene setup
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 64
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

# ---------------------------------------------------------------- materials (albedo / clay switch)
MATS = {}


def hex_rgb(h):
    h = h.lstrip("#")
    return [(int(h[i:i + 2], 16) / 255) ** 2.2 for i in (0, 2, 4)] + [1.0]


def material(name):
    """Flat colour, or rust patches (noise) / hazard stripes mixed in for the albedo pass."""
    if name in MATS:
        return MATS[name][0]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    N = nt.nodes.new
    out = N("ShaderNodeOutputMaterial")
    em = N("ShaderNodeEmission")
    if name in RUSTY or name in STRIPES:
        pos = N("ShaderNodeNewGeometry").outputs["Position"]
        mix = N("ShaderNodeMixRGB")
        if name in RUSTY:
            spot, thr = RUSTY[name]
            noise = N("ShaderNodeTexNoise")
            noise.inputs["Scale"].default_value = 0.09       # patches ~10 px across
            noise.inputs["Detail"].default_value = 3.0
            nt.links.new(pos, noise.inputs["Vector"])
            ramp = N("ShaderNodeValToRGB")
            ramp.color_ramp.interpolation = "CONSTANT"
            ramp.color_ramp.elements[1].position = thr
            nt.links.new(noise.outputs[0], ramp.inputs[0])
            nt.links.new(ramp.outputs[0], mix.inputs[0])
            a, b = COLORS[name], COLORS[spot]
        else:
            ca, cb, period = STRIPES[name]
            sep = N("ShaderNodeSeparateXYZ")
            nt.links.new(pos, sep.inputs[0])
            add = N("ShaderNodeMath"); add.operation = "ADD"
            nt.links.new(sep.outputs["X"], add.inputs[0]); nt.links.new(sep.outputs["Z"], add.inputs[1])
            div = N("ShaderNodeMath"); div.operation = "DIVIDE"; div.inputs[1].default_value = period
            nt.links.new(add.outputs[0], div.inputs[0])
            fr = N("ShaderNodeMath"); fr.operation = "FRACT"
            nt.links.new(div.outputs[0], fr.inputs[0])
            gt = N("ShaderNodeMath"); gt.operation = "GREATER_THAN"; gt.inputs[1].default_value = 0.5
            nt.links.new(fr.outputs[0], gt.inputs[0])
            nt.links.new(gt.outputs[0], mix.inputs[0])
            a, b = COLORS[ca], COLORS[cb]
        mix.inputs[1].default_value = hex_rgb(a)
        mix.inputs[2].default_value = hex_rgb(b)
        nt.links.new(mix.outputs[0], em.inputs["Color"])
    else:
        em.inputs["Color"].default_value = hex_rgb(COLORS[name])
    if name in UNLIT:
        df = N("ShaderNodeEmission")
        df.inputs["Strength"].default_value = 3.0
    else:
        df = N("ShaderNodeBsdfDiffuse")
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


# ---------------------------------------------------------------- modelling helpers (game px coords)
SPRITES = {}   # name -> (objects, left, top, w, h)
current = []


def add(obj, mat, smooth=False):
    obj.data.materials.append(material(mat))
    if smooth:
        for p in obj.data.polygons:
            p.use_smooth = True
    current.append(obj)
    return obj


def rect(x0, y0, x1, y1, mat, d0=-6.0, d1=6.0, bevel=0.0):
    """Box covering the game rect x0..x1, y0..y1, from depth d0 (front) to d1 (back)."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=((x0 + x1) / 2, (d0 + d1) / 2, -(y0 + y1) / 2))
    o = bpy.context.active_object
    o.scale = (x1 - x0, d1 - d0, y1 - y0)
    if bevel:
        bpy.ops.object.transform_apply(scale=True)
        b = o.modifiers.new("b", "BEVEL")
        b.width = bevel
        b.segments = 1
    return add(o, mat)


def rod(x0, y0, x1, y1, r, mat, d=0.0, verts=10):
    """Cylinder from game point (x0, y0) to (x1, y1) at depth d."""
    a, b = Vector((x0, d, -y0)), Vector((x1, d, -y1))
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=(b - a).length, location=(a + b) / 2)
    o = bpy.context.active_object
    o.rotation_euler = (b - a).to_track_quat("Z", "Y").to_euler()
    return add(o, mat, smooth=True)


def disc(cx, cy, r, mat, d0=-2.0, d1=0.0, verts=16):
    """Round plate facing the viewer (gauges, gear housings, bolts)."""
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=d1 - d0, location=(cx, (d0 + d1) / 2, -cy),
                                        rotation=(math.radians(90), 0, 0))
    return add(bpy.context.active_object, mat)


def stud(cx, cy, r, mat, d=-6.0):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=8, ring_count=5, radius=r, location=(cx, d, -cy))
    return add(bpy.context.active_object, mat, smooth=True)


def curve(points, r, mat, d=0.0):
    """Thick poly line through game points (cables)."""
    cu = bpy.data.curves.new("c", "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = r
    cu.bevel_resolution = 2
    sp = cu.splines.new("POLY")
    sp.points.add(len(points) - 1)
    for p, (x, y) in zip(sp.points, points):
        p.co = (x, d, -y, 1)
    ob = bpy.data.objects.new("c", cu)
    scene.collection.objects.link(ob)
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.convert(target="MESH")
    return add(ob, mat, smooth=True)


def sag(x0, x1, y, drop, n=12):
    return [(x0 + (x1 - x0) * i / n, y + drop * (1 - (2 * i / n - 1) ** 2)) for i in range(n + 1)]


def sprite(name, left, top, w, h):
    """Close the current sprite: a w x h image whose top-left pixel is game point (left, top)."""
    global current
    SPRITES[name] = (current, left, top, w, h)
    current = []


# ================================================================ back wall: 176x88 at (-88, -48)
X0, X1, Y0, Y1 = -88, 88, -48, 40
rect(X0, Y0, X1, Y1, "back_seam", 10, 12)
for i, x in enumerate(range(X0, X1, 24)):                       # riveted steel plates, upper wall
    rect(x + 0.5, Y0, min(x + 24, X1) - 0.5, 10, "back_steel", 6, 10)
    for y in (-42, 4):
        for k in range(3):
            stud(x + 4 + k * 8, y, 0.7, "back_steel", 6)
for k, y in enumerate(range(10, Y1, 6)):                         # dark plank wainscot, lower wall
    rect(X0, y + 0.5, X1, min(y + 6, Y1), "back_wood" if k % 2 == 0 else "back_wood_b", 7, 10)
rect(X0, 9, X1, 11, "back_steel", 5, 7)                           # rail between steel and wood
for x in range(X0 + 12, X1, 24):
    rect(x, 10, x + 1.5, Y1, "back_seam", 6.5, 7)                 # plank battens
# pipe run under the ceiling, brackets and flanges
rod(X0, -44, X1, -44, 2.2, "pipe", d=2)
rod(X0, -39.5, X1, -39.5, 1.4, "pipe", d=3)
for x in range(X0 + 14, X1, 36):
    rod(x, -47, x, -38, 0.9, "back_steel", d=1)
    disc(x + 10, -44, 2.9, "pipe_band", -0.8, 4.8, 10)
# chimney flue down from the roof to the furnace (furnace stands at x -62, its pipe tops out at y -10)
rod(-62, -48, -62, -9, 3.6, "back_steel", d=4)
for y in (-36, -22):
    disc(-62, y, 4.6, "pipe_band", 0.6, 7.4, 12)
# sagging cables between brackets
curve(sag(-40, 6, -37, 7), 0.8, "cable", d=2)
curve(sag(6, 40, -37, 5), 0.8, "cable", d=2.5)
curve(sag(-88, -70, -36, 6), 0.8, "cable", d=2)
curve([(80, -38), (80, -10), (78, -4), (78, 8)], 0.9, "cable", d=3)
rect(75, 0, 83, 8, "back_steel", 2, 6, 0.6)                      # junction box for that cable
# gauges (brass bezel, pale face, needle)
for gx, gy, r, ang in ((-30, -24, 4.0, 40), (-20, -27, 3.0, -30), (34, -22, 3.5, 70), (62, -6, 4.0, -60)):
    disc(gx, gy, r + 0.8, "brass", 3, 6, 14)
    disc(gx, gy, r, "gauge_face", 2.4, 3, 14)
    a = math.radians(ang)
    rod(gx, gy, gx + math.sin(a) * r * 0.8, gy - math.cos(a) * r * 0.8, 0.45, "needle", d=2.2, verts=5)
# caged ceiling lamp (the interior light hangs here in game)
rod(0, -48, 0, -42, 0.7, "cable", d=3)
rect(-4, -42, 4, -40, "back_steel", 1, 5)
stud(0, -37.5, 2.6, "lamp", 3)
for dx in (-3, 0, 3):
    rod(dx, -40, dx * 0.6, -34, 0.4, "back_steel", d=0.5, verts=5)
sprite("drill_back", -88, -48, 176, 88)

# ================================================================ hull frame: 248x168 at (-124, -76)
rect(-96, -56, 96, -48, "steel", -12, 12, 0.8)                       # roof
rect(-96, -51, 96, -50, "steel_dark", -12.4, -11)                    # plate seam
for x in range(-92, 96, 8):
    stud(x, -53.5, 0.8, "bolt", -12.2)
for side in (-1, 1):                                                 # walls above the doors
    xa, xb = sorted((side * 88, side * 96))
    rect(xa, -56, xb, -6, "steel", -12, 12, 0.8)
    rect(xa, -12, xb, -6, "hazard", -12.6, -11)                      # door lintel stripes
    for y in range(-44, -14, 8):
        stud((xa + xb) / 2, y, 0.8, "bolt", -12.2)
    rect(xa + 1, -47, xb - 1, -46, "steel_dark", -12.5, -11)
# floor + machinery band, walkable grating on top
rect(-96, 43, 96, 56, "steel_dark", -12, 12, 0.8)
rect(-96, 40, 96, 43.5, "hole", -11, 12)
for x in range(-95, 96, 3):
    rect(x, 40, x + 1.6, 43, "grate", -12, 12)
rect(-96, 43, 96, 44, "steel", -12.4, 12)
for side in (-1, 1):                                                 # striped door sills
    xa, xb = sorted((side * 88, side * 96))
    rect(xa, 44, xb, 50, "hazard", -12.6, -11)
for gx in (-36, 0, 36):                                              # gear housings
    disc(gx, 50, 4.6, "steel", -13.6, -12, 16)
    disc(gx, 50, 1.6, "bolt", -14.4, -13.4, 8)
    for k in range(6):
        a = k * math.pi / 3
        stud(gx + math.cos(a) * 3.2, 50 + math.sin(a) * 3.2, 0.6, "steel_lit", -13.8)
for vx in (-80, -20, 18, 72):                                        # vents
    for k in range(3):
        rect(vx + k * 3, 47, vx + k * 3 + 1.5, 53, "hole", -12.5, -11)
for side in (-1, 1):                                                 # headlight housings
    rect(side * 60 - 4, 53, side * 60 + 4, 57, "steel", -14, -8, 0.5)
    rect(side * 60 - 2.5, 55.5, side * 60 + 2.5, 57, "lens", -14.5, -9)
for x in range(-92, 96, 8):
    stud(x, 54.5, 0.7, "bolt", -12.2)
# braces out to the shaft walls: hydraulic cylinder, rod and a gripping pad
for side in (-1, 1):
    for y in (-36, 20):
        rod(side * 96, y, side * 110, y, 3.2, "steel_dark", d=0)
        rod(side * 110, y, side * 117, y, 1.7, "steel_lit", d=0)
        xa, xb = sorted((side * 116, side * 120))
        rect(xa, y - 7, xb, y + 7, "steel", -5, 5, 0.5)
        ra, rb = sorted((side * 119, side * 120.5))
        rect(ra, y - 6, rb, y + 6, "rubber", -5.5, 4.5)
        ma, mb = sorted((side * 96, side * 100))
        rect(ma, y - 5, mb, y + 5, "steel", -6, 6, 0.5)             # mount block on the hull
    # the low brace sits beside the open door, so a strut carries it from the floor band
    rod(side * 97, 42, side * 106, 23, 1.8, "steel_dark", d=-1)
# exhaust stack and beacon on the roof
rod(-62, -56, -62, -72, 4.0, "soot", d=0, verts=12)
rod(-62, -72, -62, -76, 6.0, "soot", d=0, verts=12)
rod(-62, -57.5, -62, -59.5, 5.5, "steel", d=0, verts=12)
rect(-7, -59, 7, -56, "steel", -6, 6, 0.4)
stud(0, -61.5, 3.8, "glass_red", 0)
for dx in (-3.5, 0, 3.5):
    rod(dx, -59, dx * 0.4, -65.5, 0.5, "steel_dark", d=-3.5, verts=5)
rect(-2, -66, 2, -65, "steel_dark", -2, 2)
rect(30, -60, 50, -56, "steel", -8, 8, 0.6)                          # roof vent box
for k in range(4):
    rect(32 + k * 4.5, -59, 34 + k * 4.5, -57, "hole", -8.5, -7)
sprite("drill_frame", -124, -76, 248, 168)

# ================================================================ drill head: 6 frames of 176x56 at (-88, 54)
HEAD_PROFILE = [(55, 84), (62, 84), (63, 81), (92, 34), (97, 18), (98, 9), (106, 0)]   # (y, radius)
FLUTES, TEETH_PER_FLUTE, TWIST = 8, 7, 70.0       # 8-fold symmetric, so 1/8 turn loops


def lathe(profile, segs, mat):
    bm = bmesh.new()
    rings = []
    for y, r in profile:
        if r == 0:
            rings.append([bm.verts.new((0, 0, -y))])
            continue
        rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / segs), r * math.sin(2 * math.pi * i / segs), -y))
                      for i in range(segs)])
    bm.faces.new(rings[0])
    for a, b in zip(rings, rings[1:]):
        for i in range(segs):
            if len(b) == 1:
                bm.faces.new((a[i], a[(i + 1) % segs], b[0]))
            else:
                bm.faces.new((a[i], a[(i + 1) % segs], b[(i + 1) % segs], b[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("lathe")
    bm.to_mesh(me)
    ob = bpy.data.objects.new("lathe", me)
    scene.collection.objects.link(ob)
    return add(ob, mat, smooth=True)


def radius_at(y):
    for (ya, ra), (yb, rb) in zip(HEAD_PROFILE, HEAD_PROFILE[1:]):
        if ya <= y <= yb:
            return ra + (rb - ra) * (y - ya) / (yb - ya)
    return 0.0


head_pivot = bpy.data.objects.new("head_pivot", None)
scene.collection.objects.link(head_pivot)
head_parts = [lathe(HEAD_PROFILE, 48, "head")]
collar = lathe([(54.5, 85.5), (61, 85.5), (61, 0)], 48, "steel_dark")
head_parts.append(collar)
for k in range(24):                                              # collar bolts (24: also 8-fold)
    a = 2 * math.pi * k / 24
    bolt = stud(0, 58, 1.0, "bolt", 0)
    bolt.location = (85.6 * math.cos(a), 85.6 * math.sin(a), -58)
    head_parts.append(bolt)
for f in range(FLUTES):                                          # spiral flutes studded with teeth
    for t in range(TEETH_PER_FLUTE + 6):
        u = t / (TEETH_PER_FLUTE + 5)
        y = 64 + u * 31
        a = 2 * math.pi * f / FLUTES + math.radians(TWIST * u)
        r = radius_at(y)
        # ridge segment
        bpy.ops.mesh.primitive_cube_add(size=1, location=((r + 0.6) * math.cos(a), (r + 0.6) * math.sin(a), -y))
        o = bpy.context.active_object
        o.scale = (3.4, 5.2, 2.8)
        o.rotation_euler = (0, 0, a)
        head_parts.append(add(o, "flute"))
    for t in range(TEETH_PER_FLUTE):
        u = (t + 0.5) / TEETH_PER_FLUTE
        y = 64 + u * 31
        a = 2 * math.pi * f / FLUTES + math.radians(TWIST * u) - math.radians(5)
        r = radius_at(y)
        bpy.ops.mesh.primitive_cone_add(vertices=4, radius1=2.6, radius2=0, depth=5.5,
                                        location=((r + 2.8) * math.cos(a), (r + 2.8) * math.sin(a), -y))
        o = bpy.context.active_object
        o.rotation_euler = (0, math.radians(90), a)
        head_parts.append(add(o, "carbide"))
# pilot bit
bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=7, radius2=0, depth=12, location=(0, 0, -102),
                                rotation=(math.radians(180), 0, 0))
head_parts.append(add(bpy.context.active_object, "carbide"))
for o in head_parts:
    o.parent = head_pivot
sprite("drill_head", -88, 54, 176, 56)
HEAD_FRAMES = 6

# ================================================================ stations (anchor: bottom centre at 0, 0)
# helm: console with a clear dark screen at (-9..9, -19..-10) and a lever slot on the right
rect(-12, -22, 12, 0, "console", -6, 6, 0.6)
rect(-13, -24, 13, -22, "steel_dark", -7, 6, 0.4)                  # hood over the screen
rect(-10, -20, 10, -9, "steel_dark", -6.6, -5)                     # screen bezel
rect(-9, -19, 9, -10, "screen", -7, -5.5)
rect(6, -8, 10, -1, "slot", -6.8, -5)                              # lever slot (lever drawn in game)
rect(5, -9, 11, -8, "steel_lit", -7, -5.5)
for i, (kx, km) in enumerate(((-8, "knob_r"), (-4, "knob_y"), (0, "knob_g"))):
    stud(kx, -5, 1.3, km, -6.4)
rect(-13, -1.5, 13, 0, "steel_dark", -7, 7)
for x in (-10, 10):
    stud(x, -12, 0.6, "bolt", -6.3)
sprite("helm", -14, -28, 28, 28)

# furnace: riveted iron boiler, chimney to the top of the image, fire mouth low, coal at its foot
rect(-12, -30, 12, -2, "furnace", -9, 9, 1.2)
rect(-13, -2, 13, 0, "steel_dark", -10, 10)
rod(-12.5, -26, 12.5, -26, 1.0, "furnace_lit", d=-9.5)
rod(-12.5, -6, 12.5, -6, 1.0, "furnace_lit", d=-9.5)
rod(0, -30, 0, -50.5, 3.6, "furnace", d=0, verts=12)
rod(0, -41, 0, -39, 4.4, "furnace_lit", d=0, verts=12)               # damper collar
rect(-6, -33, 6, -30, "furnace_lit", -6, 6, 0.4)
rect(-9, -18, 9, -5, "steel_dark", -10.2, -8.6, 0.4)              # mouth frame
rect(-7, -16, 7, -7, "fire", -10.6, -9)
rect(-4, -14, 4, -9, "fire_hot", -10.8, -10.4)
for x in range(-6, 7, 3):
    rect(x, -16, x + 1, -7, "soot", -11, -10.6)                   # grate bars over the fire
for y in (-28, -22, -20):
    for x in (-10, 10):
        stud(x, y, 0.7, "bolt", -9.2)
for cx, cy, r in ((-13, -1.8, 2.4), (-10, -1.5, 2.1), (-11.8, -4, 2.1), (-14.6, -1.2, 1.6)):
    stud(cx, cy, r, "coal", -11)
sprite("furnace", -15, -50, 30, 50)

# workbench: thick top, legs, a shelf, vice, tools and a little lamp
rect(-15, -14, 15, -10, "bench", -8, 8, 0.6)
for x in (-13, 10):
    rect(x, -10, x + 3, 0, "bench_dark", -7, 7)
rect(-13, -4, 13, -3, "bench_dark", -6, 6)                         # shelf
rect(-6, -7, 2, -4, "steel_dark", -5, 3, 0.4)                       # toolbox on the shelf
rect(-11, -19, -3, -14, "iron", -4, 4, 0.5)                         # vice
rect(-11, -20, -9, -14, "steel_dark", -4.5, 4.5)
rod(-12, -17, -15, -17, 0.6, "tool", d=-2)
rod(2, -15, 9, -19.5, 0.9, "tool", d=-3)                            # wrench
rod(-1, -15, 4, -15, 0.7, "handle", d=-5)                           # hammer
rect(3.5, -16.5, 5, -14, "tool", -6, -4)
rod(13, -14, 13, -20, 0.6, "steel_dark", d=4)                       # lamp arm + shade
rod(13, -20, 9, -21, 0.6, "steel_dark", d=4)
rect(7, -22, 11, -20.5, "steel_dark", 1, 6)
stud(9, -19.8, 1.0, "lamp", 2)
sprite("workbench", -17, -22, 34, 22)

# medkit: wall cabinet with a red cross (anchor: its centre)
rect(-7, -6, 7, 6, "cabinet", -3, 3, 0.6)
rect(-7, -1, 7, 0, "steel_dark", -3.2, 3)                          # door seam
rect(-1.5, -4, 1.5, 4, "cross", -3.4, -2.6)
rect(-4, -1.5, 4, 1.5, "cross", -3.4, -2.6)
rect(5, -2, 6, 2, "steel_dark", -3.6, -2.8)                       # latch
sprite("medkit", -8, -7, 16, 14)


# ---------------------------------------------------------------- render each sprite alone
def render(name, left, top, w, h):
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    cam_data.ortho_scale = max(w, h)
    cam.location = (left + w / 2, -300, -(top + h / 2))
    for mode in PASSES:
        set_mode(mode)
        scene.render.filepath = os.path.join(OUT, f"{name}_{mode}.png")
        bpy.ops.render.render(write_still=True)


all_objs = [o for objs, *_ in SPRITES.values() for o in objs]
for name, (objs, left, top, w, h) in SPRITES.items():
    for o in all_objs:
        o.hide_render = o not in objs
    if name == "drill_head":
        for i in range(HEAD_FRAMES):            # 1/8 turn over the cycle: the 8 flutes line up again
            head_pivot.rotation_euler.z = math.radians(-45 * i / HEAD_FRAMES)
            render(f"drill_head_{i}", left, top, w, h)
    else:
        render(name, left, top, w, h)
print("DRILL_DONE", list(SPRITES))
