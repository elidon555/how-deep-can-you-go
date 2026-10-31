#!/usr/bin/env python3
"""Turns the drill renders (flat + clay) into pixel art in assets/drill/: same stepped shading
and 1 px outline as the miner and props.

Every sprite also gets a normal map X_n.png (see tools/normal_maps.py). The hull frame keeps its interior and door openings fully transparent (the outline is drawn
inward there), the back wall is toned down, the furnace gets a _glow image of its fire, and
the six drill head frames are packed left to right into drill_head.png + drill_head.json, and
the side braces' 8 gripper frames (retracted -> extended) into drill_braces_l.png / _r.png +
drill_braces.json, and the hull turrets' aim frames into turret_r.png / turret_l.png + turret.json.
Run:  python3 tools/drill_sheet.py <render_dir>
"""
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_maps import BAKED_CONTRAST, cel_mult, normal_map  # noqa: E402

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "drill")
os.makedirs(OUT, exist_ok=True)
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
UNLIT = [np.array(c) for c in ([255, 226, 168], [12, 26, 28])]            # lamps, helm screen
GLOW = [np.array(c) for c in ([255, 138, 42], [255, 210, 122])]           # furnace fire
# game rects (x0, y0, x1, y1) that must stay empty, per sprite, and each sprite's top-left
CLEAR = {"drill_frame": [(-88, -48, 88, 40), (-96, -6, -88, 40), (88, -6, 96, 40)]}
ORIGIN = {"drill_frame": (-124, -76)}
CONTRAST = {"drill_back": 0.55}     # extra softening of the tone bands: the crew stands in front of it
HEAD_FRAMES = 6
BRACE_FRAMES = 8
for _i in range(BRACE_FRAMES):      # braces: keep only what is outside the hull's sides
    CLEAR[f"drill_braces_{_i}"] = [(-96, -76, 96, 92)]
    ORIGIN[f"drill_braces_{_i}"] = (-124, -76)


def near(flat, keys):
    m = np.zeros(flat.shape[:2], bool)
    for k in keys:
        m |= np.abs(flat[..., :3] - k).sum(-1) < 40
    return m


def convert(name):
    flat = np.array(Image.open(f"{SRC}/{name}_flat.png").convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    lum = clay.mean(-1)
    mult = cel_mult(lum, BAKED_CONTRAST * CONTRAST.get(name, 1.0))
    rgb = flat[..., :3] * mult[..., None]
    keep = (near(flat, UNLIT) | near(flat, GLOW)) & solid
    rgb[keep] = flat[..., :3][keep]
    h, w = solid.shape
    clear = np.zeros_like(solid)
    for x0, y0, x1, y1 in CLEAR.get(name, []):
        ox, oy = ORIGIN[name]
        clear[y0 - oy:y1 - oy, x0 - ox:x1 - ox] = True
    solid &= ~clear
    out = np.zeros((h, w, 4), np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255)
    out[..., 3] = np.where(solid, 255, 0)
    n = np.zeros_like(solid)
    n[1:] |= solid[:-1]; n[:-1] |= solid[1:]; n[:, 1:] |= solid[:, :-1]; n[:, :-1] |= solid[:, 1:]
    out[n & ~solid & ~clear] = OUTLINE
    # next to a cleared area the outline goes on the inside edge instead
    c = np.zeros_like(clear)
    c[1:] |= clear[:-1]; c[:-1] |= clear[1:]; c[:, 1:] |= clear[:, :-1]; c[:, :-1] |= clear[:, 1:]
    out[c & solid] = OUTLINE
    glow = near(flat, GLOW) & solid
    return out, glow, flat, normal_map(f"{SRC}/{name}_normal.png", out)


for name in ("drill_back", "drill_frame", "helm", "furnace", "workbench", "medkit", "sonar", "gunner"):
    out, glow, flat, normals = convert(name)
    Image.fromarray(out, "RGBA").save(f"{OUT}/{name}.png")
    Image.fromarray(normals, "RGBA").save(f"{OUT}/{name}_n.png")
    if glow.any():
        g = np.zeros_like(out)
        g[glow, :3] = flat[..., :3][glow]
        g[glow, 3] = 255
        Image.fromarray(g, "RGBA").save(f"{OUT}/{name}_glow.png")
    print("wrote", name, out.shape[1::-1], "(+glow)" if glow.any() else "")

heads = [convert(f"drill_head_{i}") for i in range(HEAD_FRAMES)]
frames = [h[0] for h in heads]
Image.fromarray(np.concatenate(frames, axis=1), "RGBA").save(f"{OUT}/drill_head.png")
Image.fromarray(np.concatenate([h[3] for h in heads], axis=1), "RGBA").save(f"{OUT}/drill_head_n.png")
fh, fw = frames[0].shape[:2]
meta = {"frame_w": fw, "frame_h": fh, "frames": HEAD_FRAMES, "top_left": [-88, 54],
        "note": "frames left to right; one loop = 1/8 turn of the head"}
json.dump(meta, open(f"{OUT}/drill_head.json", "w"), indent=1)
print("wrote drill_head", (fw * HEAD_FRAMES, fh))

# side braces: two strips of 8 frames, each frame the outer 36 px of one side
braces = [convert(f"drill_braces_{i}") for i in range(BRACE_FRAMES)]
for tag, cols in (("l", np.s_[:, 0:36]), ("r", np.s_[:, 212:248])):
    Image.fromarray(np.concatenate([b[0][cols] for b in braces], axis=1), "RGBA").save(f"{OUT}/drill_braces_{tag}.png")
    Image.fromarray(np.concatenate([b[3][cols] for b in braces], axis=1), "RGBA").save(f"{OUT}/drill_braces_{tag}_n.png")
meta = {"frames": BRACE_FRAMES, "frame_w": 36, "frame_h": 168, "left_top_left": [-124, -76], "right_top_left": [88, -76]}
json.dump(meta, open(f"{OUT}/drill_braces.json", "w"), indent=1)
print("wrote drill_braces_l/_r", (36 * BRACE_FRAMES, 168))

# hull turrets: per side a 16 x 2 grid of 40 px frames (aim angles; row 1 = recoiled, bolt fired)
TURRET_FRAMES, TURRET_CELL = 16, 40
MUZZLE_LEN = 14.5           # MUZZLE - pivot x in drill_blender.py
for tag in ("r", "l"):
    grid = [[convert(f"turret_{tag}_{row}_{i}") for i in range(TURRET_FRAMES)] for row in range(2)]
    for k, suffix in ((0, ""), (3, "_n")):
        rows = [np.concatenate([f[k] for f in r], axis=1) for r in grid]
        Image.fromarray(np.concatenate(rows, axis=0), "RGBA").save(f"{OUT}/turret_{tag}{suffix}.png")
meta = {"frames": TURRET_FRAMES, "frame": TURRET_CELL, "first_angle_deg": -90, "step_deg": 12,
        "pivot_px": [20, 20], "right_pivot_local": [102, -30], "left_pivot_local": [-102, -30],
        "muzzle_len_px": MUZZLE_LEN, "recoil_row": 1,
        "note": "row 0 loaded, row 1 recoiled (barrel 3 px back, bolt fired); angles y-down, "
                "0 = straight out from the hull (right for turret_r, left for turret_l)"}
json.dump(meta, open(f"{OUT}/turret.json", "w"), indent=1)
print("wrote turret_r/_l", (TURRET_CELL * TURRET_FRAMES, TURRET_CELL * 2))
