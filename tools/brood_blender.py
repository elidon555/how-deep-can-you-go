"""Builds the Broodmother in Blender, poses it, and renders sprite frames (side view, facing +X).

The mid-boss: a big pale cave spider / crab with a domed, spiky carapace, a cluster of green
eyes, heavy fangs, eight long jointed legs (the front pair thicker, crab-like, for slamming)
and behind them a huge swollen egg sac, veined and lumpy with eggs, that glows sickly green.
Run headless:
  blender -b --factory-startup -P tools/brood_blender.py -- <out_dir> [anim,anim,...]
tools/critter_sheet.py brood <out_dir> turns the renders into the sheet + the glow sheet
(eyes unshaded, egg sac shaded).
"""
import math
import os
import random
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from critter_rig import FAR, NEAR, Rig  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "/tmp/brood"
ONLY = set(ARGS[1].split(",")) if len(ARGS) > 1 else None
os.makedirs(OUT, exist_ok=True)
CELL_W, CELL_H, FEET_BELOW_CENTER = 192, 128, 54

COLORS = {
    "shell": "#d6ccc0", "shell_b": "#bdb1a6", "rim": "#968882", "under": "#6a5c62",
    "leg": "#cbbfb2", "leg_far": "#7c7076", "claw": "#2e2428", "claw_far": "#221a1e",
    "fang": "#3a2a2e", "maw": "#4a1a22", "spike": "#a49690",
    "sac": "#a6dc56", "egg": "#e0fa96", "vein": "#4e6e30", "eye": "#c8ff60",
    "sac_dead": "#7a8a5a", "egg_dead": "#9aa070", "eye_dead": "#3a4030",
}
R = Rig(CELL_W, CELL_H, FEET_BELOW_CENTER, COLORS, glow={"eye"}, cam_x=0.45, samples=48)
J = {}
BODY_Z = 1.45
root = J["root"] = R.joint("root", None, (0, 0, 0))
body = J["body"] = R.joint("body", root, (0.3, 0, BODY_Z))       # pitch pivot at the waist

# carapace (cephalothorax): domed shell over a wide crab-like rim, spikes along the front edge
CX = 0.95
ceph = J["ceph"] = R.joint("ceph", body, (0.3, 0, BODY_Z))
R.ball("under", (CX, 0, BODY_Z - 0.12), 1, "under", ceph, scale=(0.95, 0.85, 0.42))
R.ball("rim", (CX, 0, BODY_Z + 0.02), 1, "rim", ceph, scale=(1.08, 1.0, 0.3))
DOME_C, DOME_R = Vector((CX - 0.02, 0, BODY_Z + 0.12)), (1.0, 0.85, 0.68)
R.ball("dome", tuple(DOME_C), 1, "shell", ceph, scale=DOME_R)
for k, (x, z, r) in enumerate(((0.7, 0.74, 0.17), (1.15, 0.66, 0.14), (0.3, 0.62, 0.15))):
    R.ball(f"knob{k}", (x, 0, BODY_Z + z), r, "shell_b", ceph)
for k, (x, z, a) in enumerate(((1.95, 0.2, 60), (1.85, 0.42, 40), (1.6, 0.6, 20), (0.15, 0.6, -25))):
    R.cone(f"cspike{k}", (x, NEAR * 0.2, BODY_Z + z), 0.07, 0.3, "spike", ceph,
           rot=(0, math.radians(180 + a), 0))
# a blunt face jutting out of the front of the carapace, in the gap between the front legs'
# high knees and their tibias, with the eyes (two big, four small) clustered on it
FACE_C, FACE_R = Vector((2.02, 0, BODY_Z + 0.22)), (0.4, 0.98, 0.38)   # wide: the eyes sit out over the legs
R.ball("face", tuple(FACE_C), 1, "shell_b", ceph, scale=FACE_R)
EYES = []
for az, el, r in ((-62, 22, 0.11), (-78, 30, 0.095), (-40, 12, 0.08), (-85, 5, 0.075), (-52, 50, 0.07),
                  (-25, 38, 0.065)):
    a, e = math.radians(az), math.radians(el)
    d = Vector((math.cos(e) * math.cos(a), math.cos(e) * math.sin(a), math.sin(e)))
    pos = FACE_C + Vector((d.x * FACE_R[0], d.y * FACE_R[1], d.z * FACE_R[2])) * 0.97
    EYES.append(R.ball("eye", tuple(pos), r, "eye", ceph))
# mouth and fangs (chelicerae) under the front edge, palps either side
head = J["head"] = R.joint("head", ceph, (1.95, 0, BODY_Z - 0.05))
R.ball("maw", (2.25, 0, BODY_Z - 0.1), 0.15, "maw", head)
for side in (NEAR, FAR):
    R.ball(f"chel_{side}", (2.25, side * 0.22, BODY_Z - 0.12), 0.18, "shell_b" if side == NEAR else "rim", head,
           scale=(0.9, 0.8, 1.15))
FANGS = {}
for side, sn in ((NEAR, "n"), (FAR, "f")):
    j = J[f"fang_{sn}"] = R.joint(f"fang_{sn}", head, (2.3, side * 0.22, BODY_Z - 0.22))
    R.cone(f"fang_{sn}_m", (2.3, side * 0.22, BODY_Z - 0.22 - 0.3), 0.1, 0.6,
           "fang" if side == NEAR else "claw_far", j, tip=0.01)
    p1 = J[f"palp_{sn}"] = R.joint(f"palp_{sn}", head, (2.05, side * 0.42, BODY_Z - 0.05))
    R.cyl(f"palp1_{sn}", (2.05, side * 0.42, BODY_Z - 0.05 - 0.2), 0.05, 0.4,
          "leg" if side == NEAR else "leg_far", p1, 6)
    p2 = J[f"palp2_{sn}"] = R.joint(f"palp2_{sn}", p1, (2.05, side * 0.42, BODY_Z - 0.45))
    R.cone(f"palp2_{sn}_m", (2.05, side * 0.42, BODY_Z - 0.45 - 0.15), 0.05, 0.3,
           "claw" if side == NEAR else "claw_far", p2, tip=0.015)

# egg sac on the abdomen joint: swollen, veined, lumpy with eggs; a pale plated neck joins it on
SAC_C = Vector((-1.2, 0, BODY_Z + 0.6))
sac = J["sac"] = R.joint("sac", body, (-0.05, 0, BODY_Z + 0.1))
R.ball("sac_neck", (-0.25, 0, BODY_Z + 0.15), 1, "shell_b", sac, scale=(0.5, 0.6, 0.45))
R.ball("sac_plate", (-0.45, 0, BODY_Z + 0.42), 1, "shell", sac, scale=(0.42, 0.68, 0.5))
SAC_R = (1.2, 0.95, 0.95)
sac_mesh = R.ball("sac_m", tuple(SAC_C), 1, "sac", sac, scale=SAC_R, segs=20, rings=14)
SAC_PARTS = [sac_mesh]
rnd = random.Random(7)
for k in range(30):           # eggs pushing out of the near half of the sac
    u = rnd.uniform(-0.85, 0.85)
    v = rnd.uniform(-0.75, 0.9)
    w = -math.sqrt(max(0.05, 1 - u * u - v * v))      # near (-Y) side
    pos = SAC_C + Vector((u * SAC_R[0], w * SAC_R[1] * 0.97, v * SAC_R[2]))
    SAC_PARTS.append(R.ball(f"egg{k}", tuple(pos), rnd.uniform(0.09, 0.15), "egg", sac, segs=8, rings=6))
for k, fx in enumerate((-0.62, -0.1, 0.42)):     # veins: bands round the sac, tilted so they curve
    f = math.sqrt(1 - fx * fx) * 1.01
    bpy.ops.mesh.primitive_torus_add(major_radius=1.0, minor_radius=0.04, major_segments=28, minor_segments=4,
                                     location=(SAC_C.x + fx * SAC_R[0], 0, SAC_C.z),
                                     rotation=(0, math.radians(90), math.radians(-28)))
    o = bpy.context.active_object
    o.scale = (SAC_R[2] * f, SAC_R[1] * f, 1)
    o.name = f"vein{k}"
    R.finish(o, "vein")
    R.attach(o, sac)
R.cone("sac_spinner", (-2.5, 0, BODY_Z + 0.45), 0.12, 0.28, "rim", sac, rot=(0, math.radians(90), 0))

# legs: hip on the carapace flank, a long femur up to a high knee, a long tapering tibia down
# to a dark claw. Front pair (0) thick and crab-like.
LEGS = {}       # key -> (hip, knee, home foot x, bend, femur, tibia)
SPEC = [  # hip x, foot x, femur, tibia, thickness, bend (unused: the knee always goes up)
    (1.35, 3.5, 1.4, 2.3, 0.14, -1),
    (0.95, 1.55, 1.35, 2.2, 0.1, -1),
    (0.6, -0.5, 1.35, 2.2, 0.1, 1),
    (0.25, -1.4, 1.45, 2.35, 0.1, 1),
]
HIP_Z = BODY_Z - 0.3
for k, (hx, fx, fem, tib, th, bend) in enumerate(SPEC):
    for side, sn in ((NEAR, "n"), (FAR, "f")):
        mat = "leg" if side == NEAR else "leg_far"
        claw = "claw" if side == NEAR else "claw_far"
        y = side * 0.75
        hip = R.joint(f"hip{k}{sn}", ceph, (hx, y, HIP_Z))
        R.cyl(f"fem{k}{sn}", (hx, y, HIP_Z - fem / 2), th, fem, mat, hip, 7)
        knee = R.joint(f"knee{k}{sn}", hip, (hx, y, HIP_Z - fem))
        R.ball(f"kn{k}{sn}", (hx, y, HIP_Z - fem), th * 1.25, mat, knee)
        R.cone(f"kspike{k}{sn}", (hx, y, HIP_Z - fem + 0.12), th * 0.7, 0.26, "spike" if side == NEAR else claw,
               knee, rot=(0, math.radians(180), 0))
        R.cone(f"tib{k}{sn}", (hx, y, HIP_Z - fem - tib * 0.36), th * 0.95, tib * 0.72, mat, knee,
               tip=th * 0.6)
        R.cone(f"claw{k}{sn}", (hx, y, HIP_Z - fem - tib * 0.86), th * 0.6, tib * 0.28, claw, knee, tip=0.01)
        LEGS[f"{k}{sn}"] = (hip, knee, fx + (0.22 if side == FAR else 0.0) * (1 if fx > 0.5 else -1), bend,
                            fem, tib)


def pose(p):
    """p keys: x, z, pitch (whole body, + = front up), ceph / sac / head (extra turns), fang
    (spread), palp, breathe (sac swell, 3D scale of the sac only), feet {leg: (x, z) world},
    lift {leg: (dx, dz) off home}, fold {leg: (hip, knee)}, dead, ground."""
    root.location = (p.get("x", 0.0), 0, p.get("z", 0.0))
    R.setrot(body, p.get("pitch", 0.0))
    R.setrot(ceph, p.get("ceph", 0.0))
    R.setrot(sac, p.get("sac", 0.0))
    b = 1 + p.get("breathe", 0.0)
    sac.scale = (b, b, b)
    R.setrot(J["head"], p.get("head", 0.0))
    f = p.get("fang", 0.0)
    R.setrot(J["fang_n"], 18 + f)
    R.setrot(J["fang_f"], 10 + 0.8 * f)
    pl = p.get("palp", 0.0)
    for sn, o in (("n", 0), ("f", 12)):
        R.setrot(J[f"palp_{sn}"], 60 + pl + o)
        R.setrot(J[f"palp2_{sn}"], -50 - 0.5 * pl)
    dead = p.get("dead", False)
    for e in EYES:
        R.swap(e, "eye_dead" if dead else "eye")
    for o in SAC_PARTS:
        R.swap(o, ("sac_dead" if o is sac_mesh else "egg_dead") if dead else ("sac" if o is sac_mesh else "egg"))
    bpy.context.view_layer.update()
    ft, lift, fold = p.get("feet", {}), p.get("lift", {}), p.get("fold", {})
    for leg, (hip, knee, home, bend, fem, tib) in LEGS.items():
        if leg in fold:
            R.setrot(hip, fold[leg][0])
            R.setrot(knee, fold[leg][1])
            continue
        if leg in ft:
            fx, fz = ft[leg]
        else:
            dx, dz = lift.get(leg, (0.0, 0.0))
            fx, fz = home + p.get("x", 0.0) + dx, dz
        h = hip.matrix_world.translation
        # of the two ways to bend, take the one with the knee higher (spider legs)
        best = None
        for bd in (-1, 1):
            a, kb = R.two_bone(fx - h.x, fz - h.z, fem, tib, bd)
            kz = -math.cos(math.radians(a)) * fem
            if best is None or kz > best[0]:
                best = (kz, a, kb)
        _, a, kb = best
        R.setrot(hip, a - R.world_angle(hip.parent))
        R.setrot(knee, kb)
    bpy.context.view_layer.update()
    low = R.low_z()
    if p.get("ground") or low < -0.02:      # never sink through the floor
        root.location.z -= low
        bpy.context.view_layer.update()


def gait(i, n, stride, lift, groups):
    out = {}
    for leg, off in groups.items():
        t = (i / n + off) % 1
        if t < 0.5:
            out[leg] = (stride * (1 - 4 * t), 0.0)
        else:
            u = (t - 0.5) * 2
            out[leg] = (stride * (2 * u * u * (3 - 2 * u) - 1), lift * math.sin(math.pi * u))
    return out


ANIMS = {}
# idle: the sac swells and settles (slow breath), body sways down and up, palps and fangs
# twitch, a front leg shifts its weight
idle = []
for i in range(6):
    ph = i / 6 * 2 * math.pi
    idle.append({"z": -0.04 + 0.04 * math.cos(ph), "pitch": 1.5 * math.sin(ph), "sac": 3 * math.sin(ph - 0.8),
                 "breathe": 0.035 * math.sin(ph - 0.5), "head": 3 * math.sin(ph + 1), "fang": 6 * math.sin(2 * ph),
                 "palp": 10 * math.sin(ph + 0.5),
                 "lift": {"0n": (0.05 * math.sin(ph), 0.0)}})
ANIMS["idle"] = idle
# walk: alternating quads (near 0+2 with far 1+3, then the others), heavy body rolling along,
# the sac lagging behind the body's bob
GROUPS = {"0n": 0, "2n": 0, "1f": 0, "3f": 0, "1n": 0.5, "3n": 0.5, "0f": 0.5, "2f": 0.5}
walk = []
for i in range(8):
    ph = i / 8 * 2 * math.pi
    walk.append({"z": 0.05 * math.cos(2 * ph), "pitch": 1.5 * math.sin(2 * ph), "sac": 4 * math.sin(2 * ph - 1.2),
                 "breathe": 0.015 * math.sin(2 * ph - 1.5), "head": 2 * math.sin(ph), "palp": 12 * math.sin(ph),
                 "fang": 4 * math.sin(2 * ph), "lift": gait(i, 8, 0.32, 0.35, GROUPS)})
ANIMS["walk"] = walk
# spit: rears up on the back legs with the front legs raised, fangs spread, throws the head
# forward and spits (frame 3), drops back down
front_up = lambda dx, dz: {"0n": (dx, dz), "0f": (dx - 0.1, dz - 0.1)}   # noqa: E731
ANIMS["spit"] = [
    {"pitch": 6, "z": -0.08, "head": 4, "fang": 10, "palp": 15, "sac": -4, "lift": front_up(-0.2, 0.3)},
    {"pitch": 18, "z": 0.05, "head": 12, "fang": 30, "palp": 30, "sac": -10, "lift": front_up(-0.1, 1.2)},
    {"pitch": 24, "z": 0.12, "head": 18, "fang": 45, "palp": 40, "sac": -14, "breathe": 0.03,
     "lift": {**front_up(0.1, 1.7), "1n": (-0.1, 0.4), "1f": (-0.1, 0.35)}},
    {"pitch": 14, "z": 0.06, "head": -14, "fang": 55, "palp": -10, "sac": -6, "breathe": -0.03,
     "lift": {**front_up(0.3, 1.2), "1n": (0.0, 0.2)}},
    {"pitch": 6, "z": 0.0, "head": -6, "fang": 20, "palp": 0, "sac": 0, "lift": front_up(0.15, 0.4)},
    {"pitch": 1, "z": -0.03, "head": 0, "fang": 6, "palp": 8, "sac": 2, "lift": {}},
]
# slam: the front legs rise high, the body rocks back, then whips forward slamming both front
# claws down into the floor ahead (impact frame 3), then pulls them back
ANIMS["slam"] = [
    {"pitch": 8, "z": 0.02, "x": -0.05, "fang": 15, "palp": 20, "sac": -4, "lift": front_up(-0.3, 1.0)},
    {"pitch": 16, "z": 0.1, "x": -0.15, "fang": 25, "palp": 35, "sac": -10, "head": 8,
     "lift": front_up(-0.6, 2.2)},
    {"pitch": 2, "z": 0.0, "x": 0.15, "fang": 30, "palp": 10, "sac": 4, "head": -6,
     "lift": front_up(0.4, 1.3)},
    {"pitch": -9, "z": -0.22, "x": 0.25, "fang": 40, "palp": -20, "sac": 10, "head": -10, "breathe": -0.02,
     "lift": {**front_up(0.75, 0.0), "1n": (0.2, 0), "1f": (0.2, 0)}},
    {"pitch": -6, "z": -0.15, "x": 0.2, "fang": 20, "palp": -10, "sac": 6, "head": -6,
     "lift": {**front_up(0.6, 0.0), "1n": (0.15, 0), "1f": (0.15, 0)}},
    {"pitch": 0, "z": -0.05, "x": 0.05, "fang": 8, "palp": 5, "sac": 1, "lift": front_up(0.15, 0.15)},
]
# hurt: flinches up and back with the legs splayed and fangs wide, then sags
ANIMS["hurt"] = [
    {"pitch": 12, "z": 0.08, "x": -0.15, "head": 14, "fang": 50, "palp": 45, "sac": 8, "breathe": 0.03,
     "lift": {"0n": (-0.2, 0.6), "0f": (-0.25, 0.5), "1n": (-0.1, 0.2)}},
    {"pitch": 4, "z": -0.1, "x": -0.08, "head": 4, "fang": 20, "palp": 10, "sac": 3,
     "lift": {"0n": (-0.1, 0.1)}},
]
def curl(k):
    """Dead-spider legs: femurs swung up over the body, tibias curled back in (k = 0..1)."""
    out = {}
    for l in LEGS:
        n = int(l[0])
        hip = (150 - 25 * n) if n < 2 else -(150 - 25 * (3 - n))
        knee = 115 if n < 2 else -115
        out[l] = (hip * (0.45 + 0.55 * k), knee * (0.65 + 0.35 * k))
    return out


# die: rears in a spasm, the legs buckle and the body crashes down, the sac sags to the floor
# and goes dark, the legs curl up over the body
ANIMS["die"] = [
    {"pitch": 16, "z": 0.1, "head": 16, "fang": 55, "palp": 50, "sac": -8, "breathe": 0.04,
     "lift": {"0n": (-0.3, 1.4), "0f": (-0.3, 1.2), "1n": (-0.1, 0.5)}},
    {"pitch": 4, "z": -0.5, "head": -6, "fang": 30, "palp": 10, "sac": 6,
     "lift": {"0n": (0.3, 0), "0f": (0.3, 0), "1n": (0.35, 0), "1f": (0.3, 0), "2n": (-0.3, 0), "3n": (-0.4, 0),
              "2f": (-0.3, 0), "3f": (-0.4, 0)}},
    {"pitch": -2, "z": -0.9, "head": -12, "fang": 10, "palp": -10, "sac": 12, "breathe": -0.03,
     "lift": {"0n": (0.5, 0), "0f": (0.5, 0), "1n": (0.55, 0), "1f": (0.5, 0), "2n": (-0.5, 0), "3n": (-0.6, 0),
              "2f": (-0.5, 0), "3f": (-0.6, 0)}},
    {"pitch": -4, "head": -14, "fang": 0, "palp": -20, "sac": 16, "breathe": -0.05, "ground": True, "dead": True,
     "fold": curl(0.55)},
    {"pitch": -4, "head": -16, "fang": -5, "palp": -30, "sac": 18, "breathe": -0.06, "ground": True, "dead": True,
     "fold": curl(0.8)},
    {"pitch": -4, "head": -16, "fang": -5, "palp": -30, "sac": 18, "breathe": -0.07, "ground": True, "dead": True,
     "fold": curl(1.0)},
]

for name in ["idle", "walk", "spit", "slam", "hurt", "die"]:
    if ONLY and name not in ONLY:
        continue
    for i, p in enumerate(ANIMS[name]):
        pose(p)
        R.render(OUT, name, i)
print("BROOD_DONE", OUT)
