"""Builds the borer in Blender, poses it, and renders sprite frames (side view, facing +X).

An armoured burrowing insect: overlapping rust-bronze plates, six short stubby legs, and a
head that ends in a fluted drill-like mandible (it spins: a double helix of ridges round a
cone) clasped by an upper and a lower pincer. Two small amber eyes.
Run headless:
  blender -b --factory-startup -P tools/borer_blender.py -- <out_dir> [anim,anim,...]
tools/critter_sheet.py borer <out_dir> turns the renders into the sheet + an eye glow sheet.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from critter_rig import FAR, NEAR, Rig  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "/tmp/borer"
ONLY = set(ARGS[1].split(",")) if len(ARGS) > 1 else None
os.makedirs(OUT, exist_ok=True)
CELL_W, CELL_H, FEET_BELOW_CENTER = 80, 48, 16

COLORS = {
    "plate": "#8c6448", "plate_b": "#a07858", "edge": "#4e3426", "belly": "#4a3530",
    "leg": "#3c2c25", "leg_far": "#261c18", "claw": "#2a1e1a",
    "drill": "#d8c8a2", "ridge": "#4a3628", "pincer": "#8a7258", "spike": "#3e2a20", "maw": "#5c1a18",
    "eye": "#ffb020", "eye_dead": "#3a2a20",
}
R = Rig(CELL_W, CELL_H, FEET_BELOW_CENTER, COLORS, glow={"eye"}, cam_x=0.05)
J = {}
BODY_Z = 0.56
root = J["root"] = R.joint("root", None, (0, 0, 0))
body = J["body"] = R.joint("body", root, (0, 0, BODY_Z))

# spine segments: (joint, parent, pivot x, centre x, half sizes x/y/z, plate colour)
SPINE = [
    ("mid", "body", 0.0, 0.0, (0.22, 0.30, 0.30), "plate"),
    ("f1", "mid", 0.16, 0.30, (0.19, 0.28, 0.28), "plate_b"),
    ("b1", "mid", -0.16, -0.32, (0.21, 0.30, 0.29), "plate_b"),
    ("b2", "b1", -0.42, -0.58, (0.19, 0.27, 0.25), "plate"),
    ("b3", "b2", -0.68, -0.80, (0.15, 0.22, 0.20), "plate_b"),
    ("tail", "b3", -0.88, -0.97, (0.11, 0.15, 0.13), "plate"),
]
for name, parent, px, cx, (rx, ry, rz), plate in SPINE:
    j = J[name] = R.joint(name, J[parent], (px, 0, BODY_Z))
    R.ball(f"{name}_core", (cx, 0, BODY_Z - 0.04), 1, "belly", j, scale=(rx, ry * 0.92, rz * 0.85))
    sgn = 1 if cx >= 0 else -1
    R.ball(f"{name}_plate", (cx - 0.03 * sgn, 0, BODY_Z + 0.06), 1, plate, j, scale=(rx * 1.1, ry * 1.06, rz * 0.86))
    # dark lip on the trailing edge of each plate (reads as overlapping armour)
    R.ball(f"{name}_edge", (cx - sgn * rx * 0.75, 0, BODY_Z + 0.06), 1, "edge", j,
           scale=(rx * 0.32, ry * 1.04, rz * 0.8))
    # a stubby dorsal spike on each plate, raked back
    if name != "tail":
        R.cone(f"{name}_spike", (cx - sgn * 0.02 - 0.04, 0, BODY_Z + 0.06 + rz * 0.86 + 0.04), 0.05, 0.14, "spike", j,
               rot=(0, math.radians(200), 0))
tail = J["tail"]
R.cone("tail_spike", (-1.1, 0, BODY_Z + 0.02), 0.06, 0.2, "edge", tail, rot=(0, math.radians(90), 0))

# head: armoured capsule, eyes, the drill on a spinning joint, upper / lower pincers
HX = 0.52
head = J["head"] = R.joint("head", J["f1"], (0.44, 0, BODY_Z))
R.ball("head_core", (HX, 0, BODY_Z - 0.02), 1, "belly", head, scale=(0.2, 0.25, 0.24))
R.ball("head_plate", (HX - 0.02, 0, BODY_Z + 0.05), 1, "plate", head, scale=(0.21, 0.26, 0.22))
R.ball("maw", (HX + 0.15, 0, BODY_Z - 0.05), 0.09, "maw", head)
EYES = [R.ball("eye_n", (HX + 0.1, NEAR * 0.17, BODY_Z + 0.13), 0.042, "eye", head),
        R.ball("eye_f", (HX + 0.15, FAR * 0.1, BODY_Z + 0.14), 0.036, "eye", head)]

DX0, DLEN, DRAD = HX + 0.14, 0.68, 0.25
drill = J["drill"] = R.joint("drill", head, (DX0, 0, BODY_Z))
R.cone("drill_cone", (DX0 + DLEN / 2, 0, BODY_Z), DRAD, DLEN, "drill", drill, rot=(0, math.radians(-90), 0),
       verts=10)
R.cyl("drill_collar", (DX0 + 0.02, 0, BODY_Z), DRAD * 1.08, 0.07, "ridge", drill, verts=10,
      rot=(0, math.radians(90), 0))
for start in (0.0, math.pi):          # double helix of ridges: 180 degree symmetry when spinning
    for k in range(16):
        t = 0.05 + k * 0.058
        r = DRAD * (1 - t) + 0.01
        a = start + t * 3.0 * math.pi
        R.ball(f"ridge_{start:.0f}_{k}", (DX0 + t * DLEN, r * math.cos(a), BODY_Z + r * math.sin(a)),
               0.058 * (1 - 0.6 * t), "ridge", drill, segs=6, rings=4)

PINCER_REST = {"pin_up": 102, "pin_lo": 80}   # pointing forward, hugging the drill
for name, dz in (("pin_up", 0.17), ("pin_lo", -0.18)):
    j = J[name] = R.joint(name, head, (HX + 0.1, NEAR * 0.12, BODY_Z + dz))
    R.cone(f"{name}_m", (HX + 0.1, NEAR * 0.12, BODY_Z + dz - 0.19), 0.075, 0.38, "pincer", j, tip=0.012)

# legs: short and thick, hip under the flank, femur out to a knee, tibia down to a claw
FEM, TIB = 0.24, 0.33
HIP_Z = BODY_Z - 0.2
LEGS = {}
for key, seg, hx, foot, bend in (("f", "f1", 0.28, 0.16, -1), ("m", "mid", 0.0, 0.04, -1),
                                 ("r", "b1", -0.36, -0.14, +1)):
    for side, sn in ((NEAR, "n"), (FAR, "f")):
        mat = "leg" if side == NEAR else "leg_far"
        y = side * 0.3
        hip = R.joint(f"hip_{key}{sn}", J[seg], (hx, y, HIP_Z))
        R.cyl(f"femur_{key}{sn}", (hx, y, HIP_Z - FEM / 2), 0.065, FEM, mat, hip, 6)
        knee = R.joint(f"knee_{key}{sn}", hip, (hx, y, HIP_Z - FEM))
        R.ball(f"kneeb_{key}{sn}", (hx, y, HIP_Z - FEM), 0.066, mat, knee)
        R.cone(f"tibia_{key}{sn}", (hx, y, HIP_Z - FEM - TIB / 2), 0.06, TIB, mat, knee, tip=0.028)
        LEGS[key + sn] = (hip, knee, hx, foot + (0.06 if side == FAR else 0.0), bend)

HUNCH = {"f1": -4, "head": -6, "b1": 4, "b2": 6, "b3": 8, "tail": 10}


def foot_home(leg):
    _, _, hx, foot, _ = LEGS[leg]
    return hx + foot


def feet(**off):
    return {leg: (foot_home(leg) + dx, dz) for leg, (dx, dz) in off.items()}


def pose(p):
    """p keys: x, z, roll (degrees about the long axis: 180 = on its back), spine joints (added
    to the hunch), spin (drill angle), pin (pincer opening), feet {leg: (x, z)},
    fold {leg: (hip, knee)}, dead (eyes dark), ground."""
    root.rotation_euler = (math.radians(p.get("roll", 0.0)), 0, 0)
    # roll about the body's axis line (z = BODY_Z), not the floor
    r = math.radians(p.get("roll", 0.0))
    root.location = (p.get("x", 0.0), BODY_Z * math.sin(r), p.get("z", 0.0) + BODY_Z * (1 - math.cos(r)))
    for name in ("f1", "head", "b1", "b2", "b3", "tail", "mid"):
        R.setrot(J[name], HUNCH.get(name, 0) + p.get(name, 0))
    J["drill"].rotation_euler = (math.radians(p.get("spin", 0.0)), 0, 0)
    R.setrot(J["pin_up"], PINCER_REST["pin_up"] + p.get("pin", 0))
    R.setrot(J["pin_lo"], PINCER_REST["pin_lo"] - p.get("pin", 0))
    for e in EYES:
        R.swap(e, "eye_dead" if p.get("dead") else "eye")
    bpy.context.view_layer.update()
    ft, fold = p.get("feet", {}), p.get("fold", {})
    for leg, (hip, knee, hx, foot, bend) in LEGS.items():
        if leg in fold:
            R.setrot(hip, fold[leg][0])
            R.setrot(knee, fold[leg][1])
            continue
        fx, fz = ft.get(leg, (foot_home(leg) + p.get("x", 0.0), 0.0))
        h = hip.matrix_world.translation
        a, k = R.two_bone(fx - h.x, fz - h.z, FEM, TIB, bend)
        R.setrot(hip, a - R.world_angle(hip.parent))
        R.setrot(knee, k)
    bpy.context.view_layer.update()
    if p.get("ground"):
        root.location.z -= R.low_z()
        bpy.context.view_layer.update()


ANIMS = {}
# walk: alternating tripods, short scuttling steps, plates rippling, drill idling round
TRIPOD = {"fn": 0, "mf": 0, "rn": 0, "ff": 0.5, "mn": 0.5, "rf": 0.5}
STRIDE, LIFT = 0.12, 0.1
walk = []
for i in range(8):
    f = {}
    for leg, off in TRIPOD.items():
        t = (i / 8 + off) % 1
        if t < 0.5:
            f[leg] = (STRIDE * (1 - 4 * t), 0.0)
        else:
            u = (t - 0.5) * 2
            f[leg] = (STRIDE * (2 * u * u * (3 - 2 * u) - 1), LIFT * math.sin(math.pi * u))
    ph = i / 8 * 2 * math.pi
    walk.append({"z": 0.02 * math.cos(2 * ph), "mid": 1.5 * math.sin(2 * ph), "head": 3 * math.sin(ph),
                 "b2": 3 * math.sin(ph + 1), "tail": 5 * math.sin(ph + 2), "spin": 22.5 * i,
                 "pin": 3 + 3 * math.sin(2 * ph), "feet": feet(**f)})
ANIMS["walk"] = walk

# burrow: legs planted wide, the body heaving forward in pulses while the drill spins fast
# and the head grinds up and down into the rock in front
planted = {"fn": (0.12, 0), "ff": (0.12, 0), "mn": (0.0, 0), "mf": (0.02, 0), "rn": (-0.14, 0), "rf": (-0.12, 0)}
burrow = []
for i in range(6):
    ph = i / 6 * 2 * math.pi
    push = 0.06 * math.sin(ph)
    burrow.append({"x": push, "z": -0.05 + 0.02 * math.cos(2 * ph), "f1": -6 + 3 * math.sin(ph),
                   "head": -12 + 5 * math.sin(2 * ph), "mid": 2 * math.sin(ph + 1), "b1": 2 * math.sin(ph),
                   "b2": 3 * math.sin(ph - 1), "tail": 8 + 4 * math.sin(ph - 2), "spin": 30 * i,
                   "pin": 22 + 6 * math.sin(2 * ph),
                   "feet": {leg: (foot_home(leg) + dx, dz) for leg, (dx, dz) in planted.items()}})
ANIMS["burrow"] = burrow

# bite: rear back with the pincers wide, lunge, snap them shut over the drill, recover
base = {"fn": (0, 0), "ff": (0, 0), "mn": (0, 0), "mf": (0, 0), "rn": (0, 0), "rf": (0, 0)}
ANIMS["bite"] = [
    {"x": -0.1, "z": 0.04, "f1": 8, "head": 16, "b1": -3, "pin": 40, "spin": 0,
     "feet": feet(**base)},
    {"x": 0.24, "z": 0.02, "f1": -4, "head": -2, "pin": 55, "spin": 40,
     "feet": feet(**{**base, "fn": (0.3, 0.12), "ff": (0.28, 0.14), "mn": (0.14, 0)})},
    {"x": 0.28, "z": -0.04, "f1": -8, "head": -12, "pin": -8, "spin": 80,
     "feet": feet(**{**base, "fn": (0.32, 0), "ff": (0.3, 0), "mn": (0.16, 0), "mf": (0.12, 0)})},
    {"x": 0.08, "z": 0.0, "head": 2, "pin": 8, "spin": 100,
     "feet": feet(**{**base, "fn": (0.1, 0), "ff": (0.1, 0), "mn": (0.04, 0)})},
]

# die: jolted up with the pincers gaping, topples over onto its side, ends on its back with the
# legs curled up and the eyes gone dark
ANIMS["die"] = [
    {"x": -0.06, "z": 0.06, "f1": 10, "head": 22, "b2": -6, "tail": -12, "pin": 50, "spin": 20,
     "feet": feet(fn=(0.1, 0.12), ff=(0.1, 0.1), rn=(-0.08, 0), rf=(-0.08, 0))},
    {"roll": -70, "head": 8, "f1": 4, "tail": 4, "pin": 30, "spin": 24, "ground": True,
     "fold": {l: (40 if l[0] == "f" else 10 if l[0] == "m" else -20, -40) for l in LEGS}},
    {"roll": -160, "head": -4, "tail": -6, "pin": 12, "spin": 26, "ground": True, "dead": True,
     "fold": {l: (30 if l[0] == "f" else 0 if l[0] == "m" else -25, -95) for l in LEGS}},
    {"roll": -180, "head": -8, "tail": -10, "b2": -4, "pin": 4, "spin": 26, "ground": True, "dead": True,
     "fold": {l: (20 if l[0] == "f" else 0 if l[0] == "m" else -18, -130) for l in LEGS}},
]

for name in ["walk", "burrow", "bite", "die"]:
    if ONLY and name not in ONLY:
        continue
    for i, p in enumerate(ANIMS[name]):
        pose(p)
        R.render(OUT, name, i)
print("BORER_DONE", OUT)
