"""Builds the cave mite in Blender, poses it, and renders sprite frames (side view, facing +X).

A tiny tick-like swarm critter (~12x8 px of body): a fat oval shell with a pale-edged back plate,
a little beaked head and eight thin legs, two pinprick red eyes on top of the front.
Run headless:
  blender -b --factory-startup -P tools/mite_blender.py -- <out_dir> [anim,anim,...]
tools/critter_sheet.py mite <out_dir> turns the renders into the sheet + an eye glow sheet.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from critter_rig import FAR, NEAR, Rig  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "/tmp/mite"
ONLY = set(ARGS[1].split(",")) if len(ARGS) > 1 else None
os.makedirs(OUT, exist_ok=True)
CELL_W, CELL_H, FEET_BELOW_CENTER = 24, 16, 5

COLORS = {
    "shell": "#7a4238", "back": "#a0604a", "belly": "#4a2826", "head": "#3e2420",
    "leg": "#3a2220", "leg_far": "#22140f", "eye": "#ff2a24", "eye_dead": "#3a1a18",
}
R = Rig(CELL_W, CELL_H, FEET_BELOW_CENTER, COLORS, glow={"eye"}, cam_x=0.0, samples=64)
BODY_Z = 0.29
root = R.joint("root", None, (0, 0, 0))
body = R.joint("body", root, (0, 0, BODY_Z))
R.ball("belly", (0, 0, BODY_Z - 0.03), 1, "belly", body, scale=(0.25, 0.19, 0.12))
R.ball("shell", (-0.01, 0, BODY_Z), 1, "shell", body, scale=(0.27, 0.2, 0.14))
R.ball("back", (-0.03, 0, BODY_Z + 0.04), 1, "back", body, scale=(0.2, 0.16, 0.11))
head = R.joint("head", body, (0.22, 0, BODY_Z))
R.ball("headm", (0.28, 0, BODY_Z - 0.03), 0.075, "head", head)
R.cone("beak", (0.37, 0, BODY_Z - 0.05), 0.04, 0.12, "head", head, rot=(0, math.radians(-90), 0), verts=5)
EYES = [R.ball("eye1", (0.12, NEAR * 0.1, BODY_Z + 0.115), 0.024, "eye", body),
        R.ball("eye2", (0.22, NEAR * 0.09, BODY_Z + 0.085), 0.024, "eye", body)]

FEM, TIB = 0.17, 0.21
HIP_Z = BODY_Z - 0.02
LEGS = {}
for k, (hx, foot) in enumerate(((0.15, 0.2), (0.06, 0.08), (-0.05, -0.08), (-0.14, -0.2))):
    for side, sn in ((NEAR, "n"), (FAR, "f")):
        mat = "leg" if side == NEAR else "leg_far"
        y = side * 0.2
        hip = R.joint(f"hip{k}{sn}", body, (hx, y, HIP_Z))
        R.cyl(f"fem{k}{sn}", (hx, y, HIP_Z - FEM / 2), 0.026, FEM, mat, hip, 5)
        knee = R.joint(f"knee{k}{sn}", hip, (hx, y, HIP_Z - FEM))
        R.cone(f"tib{k}{sn}", (hx, y, HIP_Z - FEM - TIB / 2), 0.026, TIB, mat, knee, verts=5, tip=0.012)
        LEGS[f"{k}{sn}"] = (hip, knee, hx + foot + (0.03 if side == FAR else 0), -1 if hx > 0 else 1)


def pose(p):
    """p: x, z, pitch (body), roll (180 = on its back), head, feet {leg: (dx, dz)} off home,
    fold {leg: (hip, knee)}, dead, ground."""
    r = math.radians(p.get("roll", 0.0))
    root.rotation_euler = (r, 0, 0)
    root.location = (p.get("x", 0.0), BODY_Z * math.sin(r), p.get("z", 0.0) + BODY_Z * (1 - math.cos(r)))
    R.setrot(body, p.get("pitch", 0.0))
    R.setrot(head, p.get("head", 0.0))
    for e in EYES:
        R.swap(e, "eye_dead" if p.get("dead") else "eye")
    bpy.context.view_layer.update()
    ft, fold = p.get("feet", {}), p.get("fold", {})
    for leg, (hip, knee, home, bend) in LEGS.items():
        if leg in fold:
            R.setrot(hip, fold[leg][0])
            R.setrot(knee, fold[leg][1])
            continue
        dx, dz = ft.get(leg, (0.0, 0.0))
        h = hip.matrix_world.translation
        a, kb = R.two_bone(home + dx - h.x, dz - h.z, FEM, TIB, bend)
        R.setrot(hip, a - R.world_angle(hip.parent))
        R.setrot(knee, kb)
    bpy.context.view_layer.update()
    if p.get("ground"):
        root.location.z -= R.low_z()
        bpy.context.view_layer.update()


ANIMS = {}
# run: fast skitter, alternating tetrapods (legs 0+2 near with 1+3 far, then the others),
# the body bobbing on every step
GROUP = {"0n": 0, "2n": 0, "1f": 0, "3f": 0, "1n": 0.5, "3n": 0.5, "0f": 0.5, "2f": 0.5}
run = []
for i in range(4):
    f = {}
    for leg, off in GROUP.items():
        t = (i / 4 + off) % 1
        if t < 0.5:
            f[leg] = (0.07 * (1 - 4 * t), 0.0)
        else:
            u = (t - 0.5) * 2
            f[leg] = (0.07 * (2 * u - 1), 0.07 * math.sin(math.pi * u))
    run.append({"z": 0.02 * abs(math.cos(i / 4 * 2 * math.pi)), "pitch": 3 * math.sin(i / 4 * 4 * math.pi),
                "head": 6 * math.sin(i / 4 * 2 * math.pi), "feet": f})
ANIMS["run"] = run
# die: squashed jolt with the legs splayed, flips over, ends on its back with the legs curled in
ANIMS["die"] = [
    {"z": 0.06, "pitch": 14, "head": 14, "feet": {l: (0.06 if l[0] in "01" else -0.06, 0.05) for l in LEGS}},
    {"roll": -100, "head": -10, "ground": True, "fold": {l: (40 if int(l[0]) < 2 else -40, -50) for l in LEGS}},
    {"roll": -180, "head": -16, "ground": True, "dead": True,
     "fold": {l: (25 if int(l[0]) < 2 else -25, -120) for l in LEGS}},
]

for name in ["run", "die"]:
    if ONLY and name not in ONLY:
        continue
    for i, p in enumerate(ANIMS[name]):
        pose(p)
        R.render(OUT, name, i)
print("MITE_DONE", OUT)
