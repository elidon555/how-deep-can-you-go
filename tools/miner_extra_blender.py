"""Extra miner animations for crew rescue: down, carried, carry, throw (side view, facing +X).

Reuses the exact rig, materials, camera and pose helpers of tools/miner_blender.py (it is run
first with no animations selected, so it only builds the scene), then renders the new rows.
Run headless:
  blender -b --factory-startup -P tools/miner_extra_blender.py -- <out_dir> [anim,anim,...]
tools/miner_extra_sheet.py appends them to assets/sprites/miner.png / miner_n.png / miner.json,
leaving the existing rows untouched.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT_DIR = ARGS[0] if ARGS else "/tmp/miner_extra"
WANT = set(ARGS[1].split(",")) if len(ARGS) > 1 else None

# build the miner scene only: the base script renders nothing for an anim name it doesn't have
sys.argv = [sys.argv[0], "--", OUT_DIR, "__build_only__"]
_g = {"__name__": "miner_base", "__file__": os.path.join(HERE, "miner_blender.py")}
exec(compile(open(_g["__file__"]).read(), _g["__file__"], "exec"), _g)

bpy = _g["bpy"]
P, cloth, pose, reach, wave = _g["P"], _g["cloth"], _g["pose"], _g["reach"], _g["wave"]
PASSES, set_mode, scene = _g["PASSES"], _g["set_mode"], _g["scene"]
NEAR, FAR = _g["NEAR"], _g["FAR"]

ANIMS = {}

# down: flat on his back on the floor (head toward the back, -X), backpack under his shoulders,
# near knee up, the far hand on his chest rising and falling with slow breaths, head lolled back,
# the near arm limp along his side. No pickaxe drawn (dropped).
down = []
for i in range(4):
    b = wave(i, 4)                     # breath: in on frame 1, out on frame 3
    down.append(P(nopick=True, ground=True, spin=92 + 1.2 * b, lean=-2 - 2.5 * b, look=12 + 4 * b,
                  thigh_n=62, knee_n=-100, ankle_n=36, thigh_f=12, knee_f=-16, ankle_f=8,
                  shoulder_n=8, elbow_n=6,
                  shoulder_f=34 + 7 * b, elbow_f=105 - 8 * b))
ANIMS["down"] = cloth(down, scarf=(-90, 4), coat=(-80, 2), cycles=1, sway=2)

# carried: face down and limp across someone's shoulders: body level, head lolling down in
# front, arms dangling under the head, legs dangling from the hips behind, everything swaying a
# little with the carrier's steps. Centred in the cell (the game puts it above the carrier).
carried = []
for i in range(4):
    s = wave(i, 4)
    c = wave(i, 4, lag=1.0)
    carried.append(P(nopick=True, centre=True, float_z=1.2, spin=-90 + 2 * s, lean=6, look=-40 + 5 * c,
                     shoulder_n=88 + 10 * c, elbow_n=12 + 6 * s, shoulder_f=80 + 10 * s, elbow_f=18,
                     thigh_n=78 + 7 * c, knee_n=-24 - 8 * s, ankle_n=-35,
                     thigh_f=68 + 7 * s, knee_f=-18 - 8 * c, ankle_f=-35))
ANIMS["carried"] = cloth(carried, scarf=(-150, 6), coat=(-150, 4), cycles=1, sway=8)

# carry: the run cycle (12 frames, same legs and bob), body more upright under the weight,
# both hands up at head height steadying a load across the shoulders (load not drawn),
# pickaxe stowed on the back
carry = []
for i in range(12):
    ph = i / 12 * 2 * math.pi
    s = math.sin(ph)
    p = P(stowed=True, bob=0.045 * abs(math.cos(ph)) - 0.035, lean=-4 + 1.5 * math.cos(2 * ph), look=4,
          thigh_n=36 * s, thigh_f=-36 * s,
          knee_n=-(15 + 55 * max(0, -math.cos(ph + 0.6))),
          knee_f=-(15 + 55 * max(0, math.cos(ph + 0.6))))
    sway = 0.02 * math.cos(2 * ph)
    reach(p, NEAR, 0.24, 1.70 + sway)
    reach(p, FAR, -0.20, 1.76 + sway)
    carry.append(p)
ANIMS["carry"] = cloth(carry, scarf=(-70, 10), coat=(-35, 8), cycles=2, sway=8)

# throw: overhand with the near arm (pick stowed): wind-up back and low, cock the arm high
# behind the head, whip it over the top (release, frame 3), follow through down across the body,
# recover. Weight shifts from the back foot to the front one.
THROW = [  # lean, look, shoulder_n, elbow_n, shoulder_f, elbow_f, thigh_n, knee_n, thigh_f, knee_f
    (10, 4, -40, 30, 45, 40, 22, -20, -18, -14),
    (16, 12, 205, 110, 70, 60, 26, -24, -26, -20),
    (6, 10, 200, 60, 55, 50, 24, -28, -20, -18),
    (-12, 0, 140, 8, 10, 40, 34, -38, -24, -10),
    (-20, -10, 40, 15, -25, 35, 38, -48, -28, -8),
    (-6, 0, 10, 25, 0, 30, 24, -26, -16, -10),
]
ANIMS["throw"] = cloth([_g["grounded"](P(stowed=True, lean=a, look=b, shoulder_n=c, elbow_n=d, shoulder_f=e,
                                         elbow_f=f, thigh_n=g, knee_n=h, thigh_f=k, knee_f=m))
                        for a, b, c, d, e, f, g, h, k, m in THROW],
                       scarf=(-40, 14), coat=(-12, 8), loop=False, sway=12)



def fit(p):
    """pose()'s ground / centre / float_z, measured on the visible meshes only."""
    bpy.context.view_layer.update()
    pts = [o.matrix_world @ v.co for o in bpy.data.objects
           if o.type == "MESH" and not o.hide_render for v in o.data.vertices]
    xs, zs = [v.x for v in pts], [v.z for v in pts]
    root = _g["J"]["root"]
    if p.get("centre"):
        root.location.x -= (min(xs) + max(xs)) / 2
    if p.get("ground"):
        root.location.z -= min(zs)
    if "float_z" in p:
        root.location.z += p["float_z"] - (min(zs) + max(zs)) / 2


ORDER = ["down", "carried", "carry", "throw"]
for name in ORDER:
    if WANT and name not in WANT:
        continue
    for i, p in enumerate(ANIMS[name]):
        if p.get("nopick"):            # no pickaxe at all (dropped / limp): fit the body without it
            pose({k: v for k, v in p.items() if k not in ("ground", "centre", "float_z")})
            for o in _g["HAND_PICK"] + _g["BACK_PICK"]:
                o.hide_render = True
            fit(p)
        else:
            pose(p)
        bpy.context.view_layer.update()
        for mode in PASSES:
            set_mode(mode)
            scene.render.filepath = os.path.join(OUT_DIR, f"{name}_{i}_{mode}.png")
            bpy.ops.render.render(write_still=True)
print("MINER_EXTRA_DONE", OUT_DIR)
