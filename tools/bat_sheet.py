#!/usr/bin/env python3
"""Turns the bat renders into its pixel-art sheet: same cel shading + 1 px outline as the
miner, red eyes unshaded and also written alone to bat_glow.png (same layout) for bloom, and
a normal map bat_n.png (tools/normal_maps.py).
Writes assets/sprites/bat.png, bat_n.png, bat_glow.png (6 columns x 4 rows of 24x24) + bat.json.
Run:  python3 tools/bat_sheet.py <render_dir>
"""
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normal_maps import FLAT, cel_mult, normal_map  # noqa: E402

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "sprites")
os.makedirs(OUT, exist_ok=True)
CELL, COLUMNS = 24, 6
ORDER = [("fly", 6), ("dive", 2), ("hang", 2), ("die", 2)]
OUTLINE = np.array([12, 9, 14, 255], dtype=np.uint8)
EYE = np.array([255, 58, 42])


def frame(name, i):
    flat = np.array(Image.open(f"{SRC}/{name}_{i}_flat.png").convert("RGBA")).astype(np.float32)
    clay = np.array(Image.open(f"{SRC}/{name}_{i}_clay.png").convert("RGB")).astype(np.float32) / 255
    solid = flat[..., 3] > 128
    rgb = flat[..., :3] * cel_mult(clay.mean(-1))[..., None]
    eye = (np.abs(flat[..., :3] - EYE).sum(-1) < 60) & solid
    rgb[eye] = EYE
    out = np.zeros((CELL, CELL, 4), np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255)
    out[..., 3] = np.where(solid, 255, 0)
    n = np.zeros_like(solid)
    n[1:] |= solid[:-1]; n[:-1] |= solid[1:]; n[:, 1:] |= solid[:, :-1]; n[:, :-1] |= solid[:, 1:]
    out[n & ~solid] = OUTLINE
    glow = np.zeros_like(out)
    glow[eye, :3] = EYE
    glow[eye, 3] = 255
    return out, glow, normal_map(f"{SRC}/{name}_{i}_normal.png", out)


sheet = np.zeros((CELL * len(ORDER), CELL * COLUMNS, 4), np.uint8)
glow_sheet = np.zeros_like(sheet)
normal_sheet = np.zeros_like(sheet)
normal_sheet[..., :3] = FLAT     # empty cells: flat, transparent
anims = {}
for row, (name, count) in enumerate(ORDER):
    anims[name] = {"row": row, "frames": count}
    for i in range(count):
        cell = np.s_[row * CELL:(row + 1) * CELL, i * CELL:(i + 1) * CELL]
        sheet[cell], glow_sheet[cell], normal_sheet[cell] = frame(name, i)
Image.fromarray(sheet, "RGBA").save(f"{OUT}/bat.png")
Image.fromarray(glow_sheet, "RGBA").save(f"{OUT}/bat_glow.png")
Image.fromarray(normal_sheet, "RGBA").save(f"{OUT}/bat_n.png")
# measured from the sheet: where the hanging feet touch the ceiling and where the corpse lies
hang = sheet[anims["hang"]["row"] * CELL:(anims["hang"]["row"] + 1) * CELL, :CELL, 3]
dead = sheet[anims["die"]["row"] * CELL:(anims["die"]["row"] + 1) * CELL, CELL:2 * CELL, 3]
meta = {"cell_w": CELL, "cell_h": CELL, "columns": COLUMNS, "anims": anims,
        "anchor": "cell centre = body centre for fly / dive / die[0]",
        "hang_feet_px": [CELL // 2, int(np.where(hang.any(1))[0].min())],
        "die_floor_px": int(np.where(dead.any(1))[0].max()) + 1,
        "note": "hang: the feet grip the ceiling at hang_feet_px (x, top row); die frame 1 lies on the floor line die_floor_px"}
json.dump(meta, open(f"{OUT}/bat.json", "w"), indent=1)
print("wrote bat.png", sheet.shape[1::-1])
